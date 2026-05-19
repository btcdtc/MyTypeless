import Foundation

struct KeyboardLocalClient {
    private let url = URL(string: "ws://127.0.0.1:18082/keyboard")!

    func status(timeout: TimeInterval = 0.45) async throws -> KeyboardBridgeStatus {
        try await send(.status(), timeout: timeout)
    }

    func send(_ command: KeyboardBridgeCommand, timeout: TimeInterval) async throws -> KeyboardBridgeStatus {
        try await send(.command(command), timeout: timeout)
    }

    private func send(
        _ request: KeyboardLocalBridgeRequest,
        timeout: TimeInterval
    ) async throws -> KeyboardBridgeStatus {
        let session = URLSession(configuration: configuration(timeout: timeout))
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1 * 1024 * 1024
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        return try await withThrowingTaskGroup(of: KeyboardBridgeStatus.self) { group in
            group.addTask {
                let payload = try JSONEncoder().encode(request)
                try await task.send(.data(payload))
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let responseData):
                    data = responseData
                case .string(let responseString):
                    data = Data(responseString.utf8)
                @unknown default:
                    throw URLError(.cannotDecodeContentData)
                }
                return try JSONDecoder().decode(KeyboardBridgeStatus.self, from: data)
            }
            group.addTask {
                let seconds = max(timeout, 0.05)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }

            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }
            group.cancelAll()
            return result
        }
    }

    private func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }
}

extension KeyboardBridgeCommandAction {
    var requestTimeout: TimeInterval {
        switch self {
        case .start:
            return 6.0
        case .configure, .cancel:
            return 1.2
        case .stop:
            return 90
        case .restyleText:
            return 30
        }
    }
}
