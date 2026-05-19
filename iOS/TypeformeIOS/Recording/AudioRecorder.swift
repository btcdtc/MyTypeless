import AVFoundation
import Foundation

enum IOSRecordingAudioSession {
    static let category: AVAudioSession.Category = .playAndRecord
    static let mode: AVAudioSession.Mode = .voiceChat
    static let options: AVAudioSession.CategoryOptions =
        [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]

    static func activate(reuseActiveSession: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(category, mode: mode, options: options)
        do {
            try session.setActive(true)
            try? session.setPreferredInputNumberOfChannels(1)
        } catch {
            if !reuseActiveSession {
                throw error
            }
        }
    }
}

enum VoiceProcessingError: LocalizedError {
    case notEnabled

    var errorDescription: String? {
        "iOS voice processing could not be enabled"
    }
}

final class AudioTapFileWriter {
    private let lock = NSLock()
    private var audioData = Data()
    private var currentURL: URL?
    private var recordedFrameCount: AVAudioFramePosition = 0
    private var currentSampleRate: Double = 0

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentURL != nil
    }

    func begin(format: AVAudioFormat) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-keyboard-\(UUID().uuidString).m4a")

        lock.lock()
        if let oldURL = currentURL {
            try? FileManager.default.removeItem(at: oldURL)
        }
        audioData = Data()
        currentURL = url
        recordedFrameCount = 0
        currentSampleRate = format.sampleRate
        lock.unlock()
        return url
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        guard frameLength > 0 else { return }

        var chunk = Data()
        chunk.reserveCapacity(frameLength * MemoryLayout<Int16>.size)
        if let channels = buffer.floatChannelData {
            let interleaved = buffer.format.isInterleaved
            for frame in 0..<frameLength {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += interleaved
                        ? channels[0][frame * channelCount + channel]
                        : channels[channel][frame]
                }
                chunk.appendPCM16(sum / Float(channelCount))
            }
        } else if let channels = buffer.int16ChannelData {
            let interleaved = buffer.format.isInterleaved
            for frame in 0..<frameLength {
                var sum = 0
                for channel in 0..<channelCount {
                    let sample = interleaved
                        ? channels[0][frame * channelCount + channel]
                        : channels[channel][frame]
                    sum += Int(sample)
                }
                chunk.appendInt16(Int16(max(Int(Int16.min), min(Int(Int16.max), sum / channelCount))))
            }
        } else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        guard currentURL != nil else { return }
        if currentSampleRate <= 0 {
            currentSampleRate = buffer.format.sampleRate
        }
        audioData.append(chunk)
        recordedFrameCount += AVAudioFramePosition(buffer.frameLength)
    }

    func finish() -> URL? {
        lock.lock()
        let url = currentURL
        let data = audioData
        let duration = currentSampleRate > 0 ? Double(recordedFrameCount) / currentSampleRate : 0
        let sampleRate = currentSampleRate
        let frames = Int(recordedFrameCount)
        audioData = Data()
        currentURL = nil
        recordedFrameCount = 0
        currentSampleRate = 0
        lock.unlock()
        if duration < 0.35, let url {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if let url {
            do {
                try Self.writeM4A(data: data, sampleRate: sampleRate, frameCount: frames, to: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        return url
    }

    func cancel() -> URL? {
        let url = finish()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private static func writeM4A(
        data: Data,
        sampleRate: Double,
        frameCount: Int,
        to url: URL
    ) throws {
        let sampleCount = min(frameCount, data.count / MemoryLayout<Int16>.size)
        guard sampleCount > 0 else {
            throw NSError(domain: "Typeforme", code: 6, userInfo: [NSLocalizedDescriptionKey: "Recorded M4A contains no audio data"])
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
            throw NSError(domain: "Typeforme", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not create M4A conversion buffer"])
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

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    /// Normalized 0...1 RMS-ish microphone level, refreshed while recording.
    /// Drives the keyboard extension's voiceprint visualization via the local
    /// status bridge. Stays at 0 when not recording.
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var meteringTimer: Timer?
    /// Pre-allocated recorder ready to record on first `start()`. The expensive
    /// work — permission, session config, encoder warm-up — happens once at
    /// app launch or right after the previous recording finishes, so the
    /// `record()` call from the press gesture is ~10ms instead of ~400ms.
    /// Without this the first ~1 syllable of speech is dropped because the
    /// mic isn't actually capturing yet.
    private var preparedRecorder: AVAudioRecorder?
    private var preparedURL: URL?

    /// Session category/mode/options must MATCH `StandbyKeeper` so that
    /// `setCategory` during `start()` is a no-op and doesn't reconfigure
    /// audio routing (which would add 100-300ms of latency).
    /// `.voiceChat` is intentional: it routes capture through iOS voice
    /// processing instead of raw mic input.

    /// Prime the AVAudioRecorder so the next `start()` is instant. Safe to
    /// call multiple times; only does the work once until the prepared
    /// recorder is consumed.
    func preWarm() async {
        guard preparedRecorder == nil else { return }
        let granted = await requestPermission()
        guard granted else { return }

        do {
            try IOSRecordingAudioSession.activate()
        } catch {
            return
        }

        let session = AVAudioSession.sharedInstance()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-\(UUID().uuidString).m4a")
        let sampleRate = session.sampleRate > 0 ? session.sampleRate : 44_100
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        preparedRecorder = recorder
        preparedURL = url
    }

    func start(reuseActiveSession: Bool = false) async throws {
        // Fast path: use the pre-warmed recorder. record() is ~10ms.
        if let recorder = preparedRecorder, let url = preparedURL {
            preparedRecorder = nil
            preparedURL = nil
            guard recorder.record() else {
                try? FileManager.default.removeItem(at: url)
                // Fall through to cold path — pre-warm may have gone stale.
                try await coldStart(reuseActiveSession: reuseActiveSession)
                return
            }
            self.recorder = recorder
            self.currentURL = url
            self.isRecording = true
            startMetering()
            return
        }

        try await coldStart(reuseActiveSession: reuseActiveSession)
    }

    private func coldStart(reuseActiveSession: Bool) async throws {
        let granted = await requestPermission()
        guard granted else {
            throw NSError(domain: "Typeforme", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission is required"])
        }

        try IOSRecordingAudioSession.activate(reuseActiveSession: reuseActiveSession)

        let session = AVAudioSession.sharedInstance()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-\(UUID().uuidString).m4a")
        let sampleRate = session.sampleRate > 0 ? session.sampleRate : 44_100
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: url)
            throw NSError(domain: "Typeforme", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not start microphone recording"])
        }
        self.recorder = recorder
        self.currentURL = url
        self.isRecording = true
        startMetering()
    }

    func stop(deactivateSession: Bool = true) -> URL? {
        guard isRecording else { return nil }
        stopMetering()
        recorder?.stop()
        recorder = nil
        isRecording = false
        let url = currentURL
        currentURL = nil
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        return url
    }

    private func startMetering() {
        stopMetering()
        level = 0
        // 20Hz sampling — fine-grained enough that the keyboard, which polls
        // ~8Hz during recording, always has a recent reading without spending
        // CPU on a CADisplayLink-rate update.
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleLevel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meteringTimer = timer
    }

    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        level = 0
    }

    private func sampleLevel() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        level = Self.normalizedLevel(fromDecibels: db)
    }

    /// Convert AVAudioRecorder dB into 0...1. iPhone mic typical ranges:
    /// silence -50 to -55dB, normal speech -25 to -15dB, loud -10 to 0dB.
    /// We clamp to a -45dB floor and use a `^0.55` curve to *expand* quiet
    /// signals (root-curve), the opposite of the prior `^1.6` which crushed
    /// them. Speech around -25dB now lands at ~0.66 instead of ~0.28, so the
    /// voiceprint actually moves visibly.
    private static func normalizedLevel(fromDecibels db: Float) -> Float {
        guard db.isFinite else { return 0 }
        let floor: Float = -45
        let clamped = max(floor, min(0, db))
        let linear = (clamped - floor) / -floor
        return pow(linear, 0.55)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

@MainActor
final class StandbyAudioSession: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private let fileWriter = AudioTapFileWriter()
    private let levelThrottler = LevelUpdateThrottler(interval: 1.0 / 20.0)
    private var hasInstalledTap = false
    private var currentFormat: AVAudioFormat?

    var isRecording: Bool {
        fileWriter.isRecording
    }

    func start(reuseActiveSession: Bool = false) async throws {
        if isActive {
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
            return
        }

        let granted = await requestPermission()
        guard granted else {
            throw NSError(domain: "Typeforme", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission is required"])
        }

        try IOSRecordingAudioSession.activate(reuseActiveSession: reuseActiveSession)

        try enableVoiceProcessing()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        currentFormat = format
        if !hasInstalledTap {
            let levelThrottler = levelThrottler
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self, fileWriter, levelThrottler] buffer, _ in
                guard fileWriter.isRecording else { return }
                let level = Self.normalizedLevel(from: buffer)
                fileWriter.write(buffer)
                guard levelThrottler.shouldPublish() else { return }
                Task { @MainActor [weak self] in
                    self?.level = level
                }
            }
            hasInstalledTap = true
        }
        engine.prepare()
        try engine.start()
        isActive = true
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
    }

    private func enableVoiceProcessing() throws {
        try engine.inputNode.setVoiceProcessingEnabled(true)
        try engine.outputNode.setVoiceProcessingEnabled(true)
        engine.inputNode.isVoiceProcessingBypassed = false
        engine.inputNode.isVoiceProcessingAGCEnabled = true
        guard engine.inputNode.isVoiceProcessingEnabled else {
            throw VoiceProcessingError.notEnabled
        }
    }

    func stop(deactivateSession: Bool = true) {
        if hasInstalledTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        _ = fileWriter.cancel()
        engine.stop()
        isActive = false
        level = 0
        currentFormat = nil
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionEnded)
    }

    func beginRecording() throws -> URL {
        guard isActive else {
            throw NSError(domain: "Typeforme", code: 3, userInfo: [NSLocalizedDescriptionKey: "Keyboard standby is not active"])
        }
        guard !fileWriter.isRecording else {
            throw NSError(domain: "Typeforme", code: 5, userInfo: [NSLocalizedDescriptionKey: "Keyboard dictation is already recording"])
        }
        let format = currentFormat ?? engine.inputNode.outputFormat(forBus: 0)
        return try fileWriter.begin(format: format)
    }

    func finishRecording() -> URL? {
        level = 0
        return fileWriter.finish()
    }

    func cancelRecording() {
        level = 0
        _ = fileWriter.cancel()
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private nonisolated static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        var sampleCount = 0
        if let channels = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            for channel in 0..<channelCount {
                let data = channels[channel]
                for frame in 0..<frameLength {
                    let sample = data[frame]
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        } else if let channels = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let scale = Float(Int16.max)
            for channel in 0..<channelCount {
                let data = channels[channel]
                for frame in 0..<frameLength {
                    let sample = Float(data[frame]) / scale
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        }
        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sum / Float(sampleCount))
        guard rms.isFinite, rms > 0 else { return 0 }

        // The standby keyboard path runs through iOS voice processing / AGC,
        // so raw RMS can sit near a constant "loud" value. Convert to dB and
        // apply the same floor curve as the host recorder to keep normal
        // speech below saturation and preserve visible dynamics.
        let db = 20 * log10f(max(rms, 0.00001))
        let floor: Float = -45
        let clamped = max(floor, min(0, db))
        let linear = (clamped - floor) / -floor
        return min(1, max(0, pow(linear, 0.55)))
    }
}

private final class LevelUpdateThrottler: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastUpdateAt: TimeInterval = 0

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func shouldPublish(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastUpdateAt >= interval else { return false }
        lastUpdateAt = now
        return true
    }
}
