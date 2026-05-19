import Foundation

/// Coarse classification of the frontmost app, used to bias the corrector.
/// Per spec §15 — we use `appCategory`, never `field_type`.
enum AppCategory: String, Codable, Sendable {
    case chat
    case email
    case document
    case terminal
    case code
    case browser
    case unknown

    static func from(bundleID: String?) -> AppCategory {
        guard let raw = bundleID?.lowercased() else { return .unknown }

        if raw.hasPrefix("com.apple.safari")
            || raw.hasPrefix("com.google.chrome")
            || raw.hasPrefix("org.mozilla.firefox")
            || raw.hasPrefix("com.brave.browser")
            || raw.hasPrefix("company.thebrowser.browser") {  // Arc
            return .browser
        }

        switch raw {
        case "com.tinyspeck.slackmacgap",
             "com.hnc.discord",
             "ru.keepcoder.telegram",
             "com.apple.messages",
             "com.tencent.xinwechat",
             "com.tencent.wemeetapp":
            return .chat

        case "com.apple.mail",
             "com.microsoft.outlook",
             "com.readdle.smartemail-mac",
             "com.airmailapp.airmail",
             "ru.mailru.mailru":
            return .email

        case "com.apple.pages",
             "com.apple.textedit",
             "com.microsoft.word",
             "com.literatureandlatte.scrivener3",
             "md.obsidian",
             "com.notion.id",
             "notion.id":
            return .document

        case "com.apple.terminal",
             "com.googlecode.iterm2",
             "co.zeit.hyper",
             "dev.warp.warp-mac",
             "net.kovidgoyal.kitty",
             "org.alacritty":
            return .terminal

        case "com.microsoft.vscode",
             "com.apple.dt.xcode",
             "com.jetbrains.intellij",
             "com.jetbrains.intellij.ce",
             "com.jetbrains.pycharm",
             "com.jetbrains.pycharm.ce",
             "com.jetbrains.webstorm",
             "com.jetbrains.rider",
             "com.jetbrains.goland",
             "com.jetbrains.rubymine",
             "com.todesktop.230313mzl4w4u92",  // Cursor
             "com.exafunction.windsurf",
             "com.sublimetext.4":
            return .code

        default:
            return .unknown
        }
    }
}
