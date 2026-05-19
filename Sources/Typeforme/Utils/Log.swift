import Foundation
import os

/// Per spec §25: never log full user text. Use these categories from services;
/// log provider, latency, text length, hash, error code only.
enum Log {
    private static let subsystem = "com.typeforme.mac"
    static let app          = Logger(subsystem: subsystem, category: "app")
    static let coordinator  = Logger(subsystem: subsystem, category: "coordinator")
    static let audio        = Logger(subsystem: subsystem, category: "audio")
    static let asr          = Logger(subsystem: subsystem, category: "asr")
    static let llm          = Logger(subsystem: subsystem, category: "llm")
    static let textCommit   = Logger(subsystem: subsystem, category: "textCommit")
    static let hotkey       = Logger(subsystem: subsystem, category: "hotkey")
    static let ui           = Logger(subsystem: subsystem, category: "ui")
    static let bridge       = Logger(subsystem: subsystem, category: "bridge")
    static let store        = Logger(subsystem: subsystem, category: "store")
}
