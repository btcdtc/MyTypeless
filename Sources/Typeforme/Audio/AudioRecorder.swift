import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case engineFailedToStart(String)
    case fileSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied. Grant access in System Settings → Privacy → Microphone."
        case .engineFailedToStart(let why):
            return "AudioEngine failed to start: \(why)"
        case .fileSetupFailed(let why):
            return "Couldn't open audio file for writing: \(why)"
        }
    }
}

/// Spec §8: AVAudioEngine-based capture; handles configuration changes safely
/// (we stop on device-change and surface an error to the coordinator).
/// Marked `@unchecked Sendable` — `isRunning` / `currentURL` / observer are
/// only mutated from the main-actor coordinator's call sites. The tap closure
/// only reads its own captured locals (no shared `self.file`), so no lock is
/// needed.
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let fileWriter = MonoM4ABufferWriter()
    private var currentURL: URL?
    private var configChangeObserver: NSObjectProtocol?
    private var isRunning = false

    /// Called on the main thread with normalized [0..1] RMS values.
    var onLevel: (@MainActor (Float) -> Void)?
    /// Called on the main thread if the audio config changes mid-recording.
    var onConfigurationChanged: (@MainActor () -> Void)?

    func start() async throws -> URL {
        guard await Self.ensureMicrophonePermission() else {
            throw AudioRecorderError.permissionDenied
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let m4aURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeforme-\(UUID().uuidString).m4a")
        fileWriter.begin(url: m4aURL, sampleRate: format.sampleRate)

        let levelHandler = onLevel
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Tap closure runs on the audio thread; it only touches its own
            // buffer writer and a snapshotted level handler.
            self.fileWriter.write(buffer)
            let rms = Self.rms(buffer)
            if let levelHandler {
                Task { @MainActor in levelHandler(rms) }
            }
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.audio.notice("AVAudioEngineConfigurationChange — stopping recording")
            let url = self.currentURL
            _ = self.stop()
            if let url { try? FileManager.default.removeItem(at: url) }
            if let h = self.onConfigurationChanged {
                Task { @MainActor in h() }
            }
        }

        do {
            try engine.start()
        } catch {
            // Clean up everything we set up before throwing — otherwise the
            // tap stays installed, the observer stays registered, and the
            // temp file leaks into NSTemporaryDirectory().
            engine.inputNode.removeTap(onBus: 0)
            removeObserver()
            try? FileManager.default.removeItem(at: m4aURL)
            fileWriter.cancel()
            throw AudioRecorderError.engineFailedToStart(error.localizedDescription)
        }

        currentURL = m4aURL
        isRunning = true
        return m4aURL
    }

    @discardableResult
    func stop() -> URL? {
        guard isRunning else { return nil }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        removeObserver()
        let url = currentURL
        currentURL = nil
        guard let url else { return nil }
        do {
            try fileWriter.finish()
            return url
        } catch {
            Log.audio.notice("Mac recorder M4A write failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func removeObserver() {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let chans = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channel = chans[0]
        var sumSq: Float = 0
        for i in 0..<frames {
            let s = channel[i]
            sumSq += s * s
        }
        let rms = sqrt(sumSq / Float(max(1, frames)))
        // Square-root compression + scale; clamps loud speech to ~1.0.
        return min(1, sqrt(rms) * 2.5)
    }

    private static func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:             return false
        }
    }

}

private final class MonoM4ABufferWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var sampleRate: Double = 0
    private var frameCount: Int = 0
    private var pcm = Data()

    func begin(url: URL, sampleRate: Double) {
        lock.lock()
        self.url = url
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.frameCount = 0
        self.pcm = Data()
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        guard frames > 0 else { return }

        var chunk = Data()
        chunk.reserveCapacity(frames * MemoryLayout<Int16>.size)

        if let data = buffer.floatChannelData {
            let interleaved = buffer.format.isInterleaved
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += interleaved ? data[0][frame * channels + channel] : data[channel][frame]
                }
                chunk.appendPCM16(sum / Float(channels))
            }
        } else if let data = buffer.int16ChannelData {
            let interleaved = buffer.format.isInterleaved
            for frame in 0..<frames {
                var sum = 0
                for channel in 0..<channels {
                    let sample = interleaved ? data[0][frame * channels + channel] : data[channel][frame]
                    sum += Int(sample)
                }
                chunk.appendInt16(Int16(max(Int(Int16.min), min(Int(Int16.max), sum / channels))))
            }
        } else {
            return
        }

        lock.lock()
        if url != nil {
            pcm.append(chunk)
            frameCount += frames
            if sampleRate <= 0 {
                sampleRate = buffer.format.sampleRate
            }
        }
        lock.unlock()
    }

    func finish() throws {
        lock.lock()
        let outputURL = url
        let data = pcm
        let rate = sampleRate
        let frames = frameCount
        url = nil
        pcm = Data()
        frameCount = 0
        sampleRate = 0
        lock.unlock()

        guard let outputURL else {
            throw AudioRecorderError.fileSetupFailed("No recording file")
        }
        try Self.writeM4A(data: data, sampleRate: rate, frameCount: frames, to: outputURL)
    }

    func cancel() {
        lock.lock()
        let outputURL = url
        url = nil
        pcm = Data()
        frameCount = 0
        sampleRate = 0
        lock.unlock()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private static func writeM4A(data: Data, sampleRate: Double, frameCount: Int, to url: URL) throws {
        let sampleCount = min(frameCount, data.count / MemoryLayout<Int16>.size)
        guard sampleCount > 0 else {
            throw AudioRecorderError.fileSetupFailed("Recorded M4A contains no audio data")
        }
        let rate = max(1, sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleCount)
              )
        else {
            throw AudioRecorderError.fileSetupFailed("Could not create M4A conversion buffer")
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { rawBuffer in
            if let source = rawBuffer.baseAddress,
               let destination = buffer.int16ChannelData?[0] {
                UnsafeMutableRawPointer(destination).copyMemory(
                    from: source,
                    byteCount: sampleCount * MemoryLayout<Int16>.size
                )
            }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        try file.write(from: buffer)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = attributes[.size] as? NSNumber
        guard (byteCount?.intValue ?? 0) > 0 else {
            throw AudioRecorderError.fileSetupFailed("Recorded M4A contains no audio data")
        }
    }
}

private extension Data {
    mutating func appendInt16(_ value: Int16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendPCM16(_ sample: Float) {
        let clamped = Swift.max(-1, Swift.min(1, sample))
        appendInt16(Int16(clamped * Float(Int16.max)))
    }
}
