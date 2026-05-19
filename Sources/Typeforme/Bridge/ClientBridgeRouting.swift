import Foundation

enum ClientBridgeRouteKind: String, Sendable {
    case local = "Local"
    case cloud = "Cloud"
    case unavailable = "Offline"
}

struct ClientBridgeRouteStatus: Sendable, Equatable {
    var activeKind: ClientBridgeRouteKind = .unavailable
    var activeURL: URL?
    var localOK = false
    var cloudOK = false
    var localChecked = false
    var cloudChecked = false
    var localLatencyMs: Int?
    var cloudLatencyMs: Int?
    var message = "Not checked"
}

struct ClientBridgeConfiguration: Sendable, Equatable {
    var localBridgeURLs: [String]
    var cloudBridgeURL: String
    var token: String

    var hasAnyBridgeURL: Bool {
        !localBridgeURLs.isEmpty || !cloudBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isConfigured: Bool {
        hasAnyBridgeURL && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var current: ClientBridgeConfiguration {
        ClientBridgeConfiguration(
            localBridgeURLs: AppSettings.clientLocalBridgeURLs,
            cloudBridgeURL: AppSettings.clientCloudBridgeURL,
            token: AppSettings.clientBridgeToken
        )
    }

    static func uniqueBridgeURLs(_ rawValues: [String]) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        for rawValue in rawValues {
            let trimmed = normalizedBaseURL(rawValue)
            guard !trimmed.isEmpty, URL(string: trimmed) != nil else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            urls.append(trimmed)
        }
        return urls
    }

    static func rawValue(for urls: [String]) -> String {
        uniqueBridgeURLs(urls).joined(separator: "\n")
    }

    static func normalizedBaseURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        if trimmed.hasPrefix("localhost")
            || trimmed.hasPrefix("127.")
            || trimmed.hasPrefix("192.168.")
            || trimmed.hasPrefix("10.")
            || trimmed.range(of: #"^172\.(1[6-9]|2[0-9]|3[0-1])\."#, options: .regularExpression) != nil
            || trimmed.contains(":") {
            return "http://\(trimmed)"
        }
        return "https://\(trimmed)"
    }

    static func fromPairingPayload(_ payload: BridgePairingPayload) -> ClientBridgeConfiguration {
        let localCandidates = uniqueBridgeURLs(
            [payload.lanBridgeURL].compactMap { $0 } + (payload.lanBridgeURLs ?? [])
        )
        return ClientBridgeConfiguration(
            localBridgeURLs: localCandidates,
            cloudBridgeURL: normalizedBaseURL(payload.publicBridgeURL ?? ""),
            token: payload.token
        )
    }
}

struct ClientBridgeRouteResolver {
    func resolve(
        config: ClientBridgeConfiguration = .current,
        probeAllEndpoints: Bool = false
    ) async -> ClientBridgeRouteStatus {
        var status = ClientBridgeRouteStatus()
        let localURLs = urls(from: config.localBridgeURLs)
        let cloudURL = url(from: config.cloudBridgeURL)
        let token = config.token.trimmingCharacters(in: .whitespacesAndNewlines)

        if probeAllEndpoints {
            async let localProbe = probeLocalIfNeeded(urls: localURLs, token: token, timeout: 1.5)
            async let cloudProbe = probeCloudIfNeeded(url: cloudURL, token: token, timeout: 3.0)
            let (local, cloud) = await (localProbe, cloudProbe)

            if let local {
                status.localChecked = true
                status.localOK = local.ok
                status.localLatencyMs = local.latencyMs
            }
            if let cloud {
                status.cloudChecked = true
                status.cloudOK = cloud.ok
                status.cloudLatencyMs = cloud.latencyMs
            }

            if let local, local.ok, let activeURL = local.url {
                status.activeKind = .local
                status.activeURL = activeURL
                status.message = "Local"
                return status
            }
            if let cloudURL, let cloud, cloud.ok {
                status.activeKind = .cloud
                status.activeURL = cloudURL
                status.message = "Cloud"
                return status
            }

            status.message = "Unavailable"
            return status
        }

        if !localURLs.isEmpty {
            let local = await probeFirstAvailable(urls: localURLs, token: token, timeout: 1.5)
            status.localChecked = true
            status.localOK = local.ok
            status.localLatencyMs = local.latencyMs
            if local.ok, let activeURL = local.url {
                status.activeKind = .local
                status.activeURL = activeURL
                status.message = "Local"
                return status
            }
        }

        if let cloudURL {
            let cloud = await probe(url: cloudURL, token: token, timeout: 3.0)
            status.cloudChecked = true
            status.cloudOK = cloud.ok
            status.cloudLatencyMs = cloud.latencyMs
            if cloud.ok {
                status.activeKind = .cloud
                status.activeURL = cloudURL
                status.message = "Cloud"
                return status
            }
        }

        status.message = "Unavailable"
        return status
    }

    private func probeLocalIfNeeded(
        urls: [URL],
        token: String,
        timeout: TimeInterval
    ) async -> (url: URL?, ok: Bool, latencyMs: Int?)? {
        guard !urls.isEmpty else { return nil }
        return await probeFirstAvailable(urls: urls, token: token, timeout: timeout)
    }

    private func probeCloudIfNeeded(
        url: URL?,
        token: String,
        timeout: TimeInterval
    ) async -> (ok: Bool, latencyMs: Int?)? {
        guard let url else { return nil }
        return await probe(url: url, token: token, timeout: timeout)
    }

    private func probeFirstAvailable(
        urls: [URL],
        token: String,
        timeout: TimeInterval
    ) async -> (url: URL?, ok: Bool, latencyMs: Int?) {
        await withTaskGroup(of: (URL, Bool, Int?).self) { group in
            for url in urls {
                group.addTask {
                    let result = await probe(url: url, token: token, timeout: timeout)
                    return (url, result.ok, result.latencyMs)
                }
            }

            while let result = await group.next() {
                if result.1 {
                    group.cancelAll()
                    return (result.0, true, result.2)
                }
            }
            return (nil, false, nil)
        }
    }

    private func probe(url: URL, token: String, timeout: TimeInterval) async -> (ok: Bool, latencyMs: Int?) {
        let start = Date()
        do {
            let client = try RemoteBridgeClient(baseURLString: url.absoluteString, token: token)
            let health = try await client.health(timeout: timeout)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return (health.ok, health.ok ? latency : nil)
        } catch {
            return (false, nil)
        }
    }

    private func url(from rawValue: String) -> URL? {
        let normalized = ClientBridgeConfiguration.normalizedBaseURL(rawValue)
        guard !normalized.isEmpty else { return nil }
        return URL(string: normalized)
    }

    private func urls(from rawValues: [String]) -> [URL] {
        ClientBridgeConfiguration.uniqueBridgeURLs(rawValues).compactMap { URL(string: $0) }
    }
}
