import Foundation

enum KeyboardDarwinNotificationName {
    static let transcriptionReady = "com.typeforme.keyboard.transcriptionReady"
    static let dictationStarted = "com.typeforme.keyboard.dictationStarted"
    static let dictationStopped = "com.typeforme.keyboard.dictationStopped"
    static let sessionStarted = "com.typeforme.keyboard.sessionStarted"
    static let sessionEnded = "com.typeforme.keyboard.sessionEnded"
    static let requestSessionStatus = "com.typeforme.keyboard.requestSessionStatus"
    static let requestStartDictation = "com.typeforme.keyboard.requestStartDictation"
    static let requestStopDictation = "com.typeforme.keyboard.requestStopDictation"
    static let requestCancelDictation = "com.typeforme.keyboard.requestCancelDictation"
}

enum KeyboardDarwinBridge {
    static func post(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    static func observe(_ name: String, callback: @escaping () -> Void) -> KeyboardDarwinNotificationObserver {
        KeyboardDarwinNotificationObserver(name: name, callback: callback)
    }
}

final class KeyboardDarwinNotificationObserver {
    private let name: String
    private let callback: () -> Void
    private var isObserving = false

    init(name: String, callback: @escaping () -> Void) {
        self.name = name
        self.callback = callback

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passRetained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let object = Unmanaged<KeyboardDarwinNotificationObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                object.callback()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
        isObserving = true
    }

    deinit {
        stopObserving()
    }

    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(name as CFString), nil)
        Unmanaged.passUnretained(self).release()
    }
}

enum VoiceInputMode: String, CaseIterable, Identifiable, Codable {
    case hold
    case tap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: return "Hold"
        case .tap: return "Tap"
        }
    }

    var idleTitle: String {
        switch self {
        case .hold: return "Hold to Speak"
        case .tap: return "Tap to Speak"
        }
    }

    var recordingTitle: String {
        switch self {
        case .hold: return "Release to Send"
        case .tap: return "Tap to Finish"
        }
    }

    var idleDetail: String {
        switch self {
        case .hold: return "Press and hold, then release to transcribe."
        case .tap: return "Tap once to record, tap again to send."
        }
    }
}

enum KeyboardBridgeCommandAction: String, Codable {
    case start
    case stop
    case cancel
    case configure
    case restyleText = "restyle_text"
}

enum KeyboardTextEditIntent: String, Codable {
    case repairSelection = "repair_selection"
    case command = "command"
}

struct KeyboardTextEditContext: Codable, Equatable {
    let intent: KeyboardTextEditIntent
    let contextBefore: String
    let targetText: String
    let contextAfter: String

    enum CodingKeys: String, CodingKey {
        case intent
        case contextBefore = "context_before"
        case targetText = "target_text"
        case contextAfter = "context_after"
    }
}

struct KeyboardDictationContext: Codable, Equatable {
    let contextBefore: String
    let contextAfter: String

    enum CodingKeys: String, CodingKey {
        case contextBefore = "context_before"
        case contextAfter = "context_after"
    }
}

struct KeyboardBridgeCommand: Codable, Equatable {
    let id: String
    let action: KeyboardBridgeCommandAction
    let correctionMode: String
    let text: String?
    let textEditContext: KeyboardTextEditContext?
    let dictationContext: KeyboardDictationContext?
    let createdAt: TimeInterval

    init(
        id: String = UUID().uuidString,
        action: KeyboardBridgeCommandAction,
        correctionMode: String,
        text: String? = nil,
        textEditContext: KeyboardTextEditContext? = nil,
        dictationContext: KeyboardDictationContext? = nil,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.action = action
        self.correctionMode = correctionMode
        self.text = text
        self.textEditContext = textEditContext
        self.dictationContext = dictationContext
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case correctionMode
        case text
        case textEditContext = "text_edit_context"
        case dictationContext = "dictation_context"
        case createdAt
    }
}

struct KeyboardLocalBridgeRequest: Codable, Equatable {
    enum Action: String, Codable {
        case status
        case command
    }

    let action: Action
    let command: KeyboardBridgeCommand?

    static func status() -> KeyboardLocalBridgeRequest {
        KeyboardLocalBridgeRequest(action: .status, command: nil)
    }

    static func command(_ command: KeyboardBridgeCommand) -> KeyboardLocalBridgeRequest {
        KeyboardLocalBridgeRequest(action: .command, command: command)
    }
}

enum KeyboardBridgeState: String, Codable {
    case idle
    case standby
    case recording
    case sending
    case result
    case error
}

struct KeyboardBridgeStatus: Codable, Equatable {
    let commandID: String?
    let state: KeyboardBridgeState
    let message: String
    let resultText: String?
    let audioDurationSeconds: Double?
    let audioByteCount: Int?
    let rawTranscriptLength: Int?
    let defaultCorrectionMode: String?
    /// Normalized 0...1 RMS-ish microphone level captured by the host app's
    /// `AudioRecorder` and surfaced on every `/status` poll. `nil` when the
    /// host can't sample (e.g. before recording starts).
    let audioLevel: Float?
    let updatedAt: TimeInterval

    init(
        commandID: String? = nil,
        state: KeyboardBridgeState,
        message: String,
        resultText: String? = nil,
        audioDurationSeconds: Double? = nil,
        audioByteCount: Int? = nil,
        rawTranscriptLength: Int? = nil,
        defaultCorrectionMode: String? = nil,
        audioLevel: Float? = nil,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.commandID = commandID
        self.state = state
        self.message = message
        self.resultText = resultText
        self.audioDurationSeconds = audioDurationSeconds
        self.audioByteCount = audioByteCount
        self.rawTranscriptLength = rawTranscriptLength
        self.defaultCorrectionMode = defaultCorrectionMode
        self.audioLevel = audioLevel
        self.updatedAt = updatedAt
    }

    func withAudioLevel(_ level: Float?) -> KeyboardBridgeStatus {
        KeyboardBridgeStatus(
            commandID: commandID,
            state: state,
            message: message,
            resultText: resultText,
            audioDurationSeconds: audioDurationSeconds,
            audioByteCount: audioByteCount,
            rawTranscriptLength: rawTranscriptLength,
            defaultCorrectionMode: defaultCorrectionMode,
            audioLevel: level,
            updatedAt: updatedAt
        )
    }

    static let idle = KeyboardBridgeStatus(state: .idle, message: "Keyboard standby is off")
}
