import AppKit
import AVFoundation
import Foundation

enum MicrophonePermissionStatus: Equatable {
    case granted
    case notDetermined
    case denied
    case restricted
    case unknown

    static var current: MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }
}

struct LocalNetworkPermissionCheck: Equatable {
    enum Status: Equatable {
        case notChecked
        case checking
        case reachable
        case notRequired
        case noLocalTarget
        case blockedOrUnreachable
    }

    var status: Status
    var targetDescription: String
    var detail: String

    static let notChecked = LocalNetworkPermissionCheck(
        status: .notChecked,
        targetDescription: "",
        detail: "Check Local Network after configuring a LAN Bridge or LAN LM Studio URL."
    )

    static let checking = LocalNetworkPermissionCheck(
        status: .checking,
        targetDescription: "",
        detail: "Checking Local Network reachability..."
    )
}

enum AppPermissions {
    private struct LocalNetworkProbeTarget: Hashable {
        let name: String
        let url: URL
        let bearerToken: String?
    }

    static var microphoneStatus: MicrophonePermissionStatus {
        MicrophonePermissionStatus.current
    }

    static func requestMicrophone() async -> MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            return MicrophonePermissionStatus.current
        default:
            return MicrophonePermissionStatus.current
        }
    }

    static func openMicrophoneSettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    static func openLocalNetworkSettings() {
        openPrivacySettings(anchor: "Privacy_LocalNetwork")
    }

    static func checkLocalNetwork(timeout: TimeInterval = 4) async -> LocalNetworkPermissionCheck {
        let localTargets = localNetworkProbeTargets()
        if let target = localTargets.first {
            return await probe(target, timeout: timeout)
        }

        if hasOnlyLoopbackNetworkTargets() {
            return LocalNetworkPermissionCheck(
                status: .notRequired,
                targetDescription: "localhost",
                detail: "Current network targets are loopback-only, so macOS Local Network permission is not required."
            )
        }

        return LocalNetworkPermissionCheck(
            status: .noLocalTarget,
            targetDescription: "",
            detail: "No configured LAN Bridge or LAN LM Studio URL was found."
        )
    }

    private static func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func probe(_ target: LocalNetworkProbeTarget, timeout: TimeInterval) async -> LocalNetworkPermissionCheck {
        var request = URLRequest(url: target.url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let bearerToken = target.bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if (200..<500).contains(http.statusCode) {
                    return LocalNetworkPermissionCheck(
                        status: .reachable,
                        targetDescription: target.name,
                        detail: "Reached \(target.url.host ?? target.url.absoluteString) with HTTP \(http.statusCode)."
                    )
                }
                return LocalNetworkPermissionCheck(
                    status: .blockedOrUnreachable,
                    targetDescription: target.name,
                    detail: "Reached the host but got HTTP \(http.statusCode)."
                )
            }
            return LocalNetworkPermissionCheck(
                status: .reachable,
                targetDescription: target.name,
                detail: "Reached \(target.url.host ?? target.url.absoluteString)."
            )
        } catch {
            return LocalNetworkPermissionCheck(
                status: .blockedOrUnreachable,
                targetDescription: target.name,
                detail: "\(error.localizedDescription) This can mean Local Network is not granted, or the target service is unreachable."
            )
        }
    }

    private static func localNetworkProbeTargets() -> [LocalNetworkProbeTarget] {
        var targets: [LocalNetworkProbeTarget] = []

        if let target = lmStudioProbeTarget(baseURL: AppSettings.lmStudioBaseURL),
           isLocalNetworkHost(target.url.host) {
            targets.append(target)
        }

        for rawURL in AppSettings.clientLocalBridgeURLs {
            if let target = bridgeProbeTarget(baseURL: rawURL, token: AppSettings.clientBridgeToken),
               isLocalNetworkHost(target.url.host) {
                targets.append(target)
            }
        }

        if AppSettings.bridgeLANEnabled {
            let token = UserDefaults.standard.string(forKey: AppSettings.Keys.bridgeAuthToken) ?? ""
            for rawURL in BridgePairingPayload.lanBridgeURLs(port: AppSettings.bridgePort) {
                if let target = bridgeProbeTarget(baseURL: rawURL, token: token),
                   isLocalNetworkHost(target.url.host) {
                    targets.append(target)
                }
            }
        }

        var seen = Set<String>()
        return targets.filter { target in
            seen.insert("\(target.name)|\(target.url.absoluteString)").inserted
        }
    }

    private static func hasOnlyLoopbackNetworkTargets() -> Bool {
        var hosts: [String] = []
        if let host = URL(string: AppSettings.lmStudioBaseURL)?.host {
            hosts.append(host)
        }
        hosts.append(contentsOf: AppSettings.clientLocalBridgeURLs.compactMap { URL(string: $0)?.host })
        return !hosts.isEmpty && hosts.allSatisfy(isLoopbackHost)
    }

    private static func lmStudioProbeTarget(baseURL: String) -> LocalNetworkProbeTarget? {
        guard let endpoint = try? LMStudioCorrectorService.modelsEndpoint(baseURL: baseURL) else {
            return nil
        }
        return LocalNetworkProbeTarget(name: "LM Studio", url: endpoint, bearerToken: AppSettings.lmStudioAPIKey)
    }

    private static func bridgeProbeTarget(baseURL: String, token: String) -> LocalNetworkProbeTarget? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        guard let url = URL(string: normalized + "/v1/health") else { return nil }
        return LocalNetworkProbeTarget(name: "Bridge", url: url, bearerToken: token)
    }

    private static func isLocalNetworkHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty,
              !isLoopbackHost(host)
        else {
            return false
        }
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}
