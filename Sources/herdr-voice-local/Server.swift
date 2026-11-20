import Foundation
import HerdrVoiceLocal
import Network

/// The authenticated loopback WebSocket the app connects to. One client at a time, text messages only, 2 MiB max.
@MainActor
final class LoopbackServer {
    private let token: String
    private let makeSession: (_ emit: @escaping @MainActor ([String: Any]) -> Void) -> BridgeSession
    private var listener: NWListener?
    private var active: NWConnection?
    private var session: BridgeSession?

    init(token: String, makeSession: @escaping (_ emit: @escaping @MainActor ([String: Any]) -> Void) -> BridgeSession) {
        self.token = token
        self.makeSession = makeSession
    }

    /// Binds an ephemeral port on 127.0.0.1 and returns it.
    func start() async throws -> UInt16 {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 2 * 1024 * 1024
        let token = token
        websocket.setClientRequestHandler(.main) { _, headers in
            // The connection handler has already refused any peer that isn't loopback.
            let allowed = LocalSecurity.authorizeUpgrade(headers: headers, remoteAddress: "127.0.0.1", token: token)
            return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            final class Once: @unchecked Sendable { var done = false } // only touched on the main queue
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    once.done = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() {
        active?.cancel()
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard active == nil, Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        active = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.active === connection else { return }
                switch state {
                case .ready:
                    self.session = self.makeSession { [weak self] event in self?.send(event, on: connection) }
                    self.receive(on: connection)
                case .failed, .cancelled:
                    self.active = nil
                    self.session?.close()
                    self.session = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback || "\(address)" == "::ffff:127.0.0.1"
        default: return false
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, self.active === connection else { return }
                if error != nil {
                    connection.cancel()
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close {
                    connection.cancel()
                    return
                }
                if let data, metadata?.opcode == .text {
                    self.handle(data, on: connection)
                } else if metadata?.opcode == .binary {
                    self.send(["type": "error", "error": ["message": "text message required"]], on: connection)
                }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) {
        guard let session else { return }
        var epoch: Int?
        do {
            let message = try JSONValue.parse(data)
            epoch = message["epoch"]?.safeInteger
            guard let task = try session.handle(message) else { return }
            Task { [weak self] in
                do { try await task.value } catch { self?.reportError(error, epoch: epoch, on: connection) }
            }
        } catch {
            reportError(error, epoch: epoch, on: connection)
        }
    }

    private func reportError(_ error: Error, epoch: Int?, on connection: NWConnection) {
        var event: [String: Any] = ["type": "error", "error": ["message": error.localizedDescription]]
        if let epoch { event["epoch"] = epoch }
        send(event, on: connection)
    }

    private func send(_ event: [String: Any], on connection: NWConnection) {
        guard active === connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "event", metadata: [metadata])
        connection.send(content: Data(jsonLine(event).utf8), contentContext: context, isComplete: true,
                        completion: .idempotent)
    }
}
