import AVFoundation
import Foundation

/// Keeps the host app alive in the background so the keyboard extension's
/// local bridge poll to `KeyboardLocalServer` always reaches a live process.
/// iOS keeps any app with `UIBackgroundModes = audio` alive while audio is
/// actively being routed; we feed an `AVAudioPlayerNode` a zero-filled
/// looping PCM buffer at 0.001 mixer volume.
///
/// Why `AVAudioEngine` instead of `AVAudioPlayer`:
/// `AVAudioPlayer.play()` returns `false` in practice when the session is
/// transitioning between categories (e.g., right after `AudioRecorder`
/// changed to voice-processing mode and the keeper is asked to resume).
/// `AVAudioPlayerNode` running on an engine is decoupled from session
/// category churn and reliably stays alive across recording sessions.
///
/// Why playback (silent) instead of TypeWhisper's continuous mic engine:
/// playback keeps the app alive without lighting the red microphone status
/// indicator and without actually capturing audio. Battery cost: ~1-2%/hr.
///
/// Critical invariant: the connection format between `player` and
/// `mainMixerNode` MUST match the format of buffers scheduled on the
/// player. A mismatch raises an Obj-C exception that Swift can't catch and
/// crashes the app on launch. We pin both sides to a single static format.
@MainActor
final class StandbyKeeper {
    private(set) var isActive = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var hasAttached = false

    /// 44.1 kHz Float32 stereo — iOS's lingua franca. `mainMixerNode`
    /// always accepts this and the hardware output node converts internally
    /// as needed.
    private static let playbackFormat: AVAudioFormat? =
        AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)

    func start() {
        guard let format = Self.playbackFormat else {
            isActive = false
            return
        }
        do {
            try setupAndPlay(format: format)
            isActive = true
        } catch {
            // Audio session conflicts, hardware unavailable, etc. — log
            // and move on rather than spamming the UI. The local bridge
            // still works while the app is in the foreground; iOS will
            // suspend after backgrounding but the next keyboard standby
            // URL open will retry.
            NSLog("StandbyKeeper.start failed: \(error)")
            isActive = false
        }
    }

    func stop() {
        if player.isPlaying {
            player.stop()
        }
        if engine.isRunning {
            engine.stop()
        }
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setupAndPlay(format: AVAudioFormat) throws {
        let session = AVAudioSession.sharedInstance()
        // Category/mode/options match `AudioRecorder` exactly so its
        // `setCategory` during recording start is a no-op — no audio
        // routing reconfigure, no first-syllable drop.
        try session.setCategory(
            IOSRecordingAudioSession.category,
            mode: IOSRecordingAudioSession.mode,
            options: IOSRecordingAudioSession.options
        )
        try session.setActive(true)

        if !hasAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.001
            hasAttached = true
        }

        if !engine.isRunning {
            try engine.start()
        }

        // Always re-schedule on start. Buffer MUST be in the same format we
        // connected with (see invariant above).
        let frameCount = AVAudioFrameCount(format.sampleRate)
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) {
            buffer.frameLength = frameCount
            // Float32 non-interleaved buffers are zero-initialized → silent.
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        }
        if !player.isPlaying {
            player.play()
        }
    }
}
