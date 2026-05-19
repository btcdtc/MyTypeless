import Foundation
import Network

final class KeyboardLocalServer {
    static let port: UInt16 = 18082
    private static let maxMessageBytes = 1 * 1024 * 1024

    var onCommand: ((KeyboardBridgeCommand) async -> KeyboardBridgeStatus)?
    var statusProvider: (() async -> KeyboardBridgeStatus)?

    private let queue = DispatchQueue(label: "com.typeforme.keyboard-server")
    private var listener: NWListener?

    var isRunning: Bool {
        listener != nil
    }

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.listener?.cancel()
                self?.listener = nil
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receiveMessage(from: connection)
    }

    private func receiveMessage(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            guard error == nil,
                  let data,
                  data.count <= Self.maxMessageBytes
            else {
                self.send(
                    KeyboardBridgeStatus(state: .error, message: "Bad keyboard bridge request"),
                    connection: connection
                )
                return
            }

            let request: KeyboardLocalBridgeRequest
            do {
                request = try JSONDecoder().decode(KeyboardLocalBridgeRequest.self, from: data)
            } catch {
                self.send(
                    KeyboardBridgeStatus(state: .error, message: "Invalid keyboard bridge request"),
                    connection: connection
                )
                return
            }

            Task {
                let status = await self.status(for: request)
                self.send(status, connection: connection)
            }
        }
    }

    private func status(for request: KeyboardLocalBridgeRequest) async -> KeyboardBridgeStatus {
        switch request.action {
        case .status:
            return await statusProvider?() ?? .idle
        case .command:
            guard let command = request.command else {
                return KeyboardBridgeStatus(state: .error, message: "Missing keyboard command")
            }
            return await onCommand?(command)
                ?? KeyboardBridgeStatus(state: .error, message: "Keyboard command handler is unavailable")
        }
    }

    private func send(_ status: KeyboardBridgeStatus, connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(status) else {
            connection.cancel()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "keyboard-bridge-status", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return true }
        switch host {
        case .ipv4(let address):
            return String(describing: address) == "127.0.0.1"
        case .ipv6(let address):
            return String(describing: address) == "::1"
        case .name(let name, _):
            let normalized = name.lowercased()
            return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
        @unknown default:
            return false
        }
    }
}
