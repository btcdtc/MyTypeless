import Foundation

enum BridgeRouteKind: String {
    case local = "Local"
    case cloud = "Cloud"
    case unavailable = "Offline"
}

struct BridgeRouteStatus {
    var activeKind: BridgeRouteKind = .unavailable
    var activeURL: URL?
    var localOK = false
    var cloudOK = false
    var localChecked = false
    var cloudChecked = false
    var localLatencyMs: Int?
    var cloudLatencyMs: Int?
    var message = "Not checked"
}

struct BridgeRouteResolver {
    func resolve(config: PairingConfig, probeAllEndpoints: Bool = false) async -> BridgeRouteStatus {
        var status = BridgeRouteStatus()
        let localURLs = urls(from: config.localBridgeURLCandidates)
        let cloudURL = url(from: config.publicBridgeURL)
        let shouldTryLocal = !localURLs.isEmpty
        let shouldProbeLocal = (shouldTryLocal || probeAllEndpoints) && !localURLs.isEmpty

        if probeAllEndpoints {
            async let localProbe = probeLocalIfNeeded(
                urls: localURLs,
                token: config.token,
                timeout: 1.5,
                shouldProbe: shouldProbeLocal
            )
            async let cloudProbe = probeCloudIfNeeded(
                url: cloudURL,
                token: config.token,
                timeout: 3.0
            )
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

            if shouldTryLocal, let local, local.ok, let activeURL = local.url {
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

            status.activeKind = .unavailable
            status.activeURL = nil
            status.message = "Unavailable"
            return status
        }

        if shouldProbeLocal {
            let local = await probeFirstAvailable(urls: localURLs, token: config.token, timeout: 1.5)
            status.localChecked = true
            status.localOK = local.ok
            status.localLatencyMs = local.latencyMs
            if shouldTryLocal, local.ok, let activeURL = local.url {
                status.activeKind = .local
                status.activeURL = activeURL
                status.message = "Local"
                if !probeAllEndpoints {
                    return status
                }
            }
        }

        if let cloudURL {
            let cloud = await probe(url: cloudURL, token: config.token, timeout: 3.0)
            status.cloudChecked = true
            status.cloudOK = cloud.ok
            status.cloudLatencyMs = cloud.latencyMs
            if status.activeURL == nil, cloud.ok {
                status.activeKind = .cloud
                status.activeURL = cloudURL
                status.message = "Cloud"
                return status
            }
        }

        if status.activeURL != nil {
            return status
        }

        status.activeKind = .unavailable
        status.activeURL = nil
        status.message = "Unavailable"
        return status
    }

    private func probeLocalIfNeeded(
        urls: [URL],
        token: String,
        timeout: TimeInterval,
        shouldProbe: Bool
    ) async -> (url: URL?, ok: Bool, latencyMs: Int?)? {
        guard shouldProbe else { return nil }
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

    private func url(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private func urls(from rawValues: [String]) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for rawValue in rawValues {
            guard let url = url(from: rawValue) else { continue }
            let key = url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            urls.append(url)
        }
        return urls
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
        let ok = await BridgeClient(baseURL: url, token: token).health(timeout: timeout)
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        return (ok, ok ? latency : nil)
    }

}
