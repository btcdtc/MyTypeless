import Foundation

enum CommandLineHandler {
    static func exitIfHandled(arguments: [String] = CommandLine.arguments) {
        let flags = Set(arguments.dropFirst())
        guard flags.contains("--version") || flags.contains("-v") else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        print("Typeforme \(version) (\(build))")
        Foundation.exit(0)
    }
}
