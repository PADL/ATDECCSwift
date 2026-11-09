//
// Copyright (c) 2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#if os(Linux)

import ATDECC
import FlyingFox
import FlyingSocks
import Foundation
import Glibc
import IEEE802
import IEEE802Linux
import Logging
import Synchronization

/// How an APS serves APCs, on whichever HTTP server carries it.
public struct AtdeccProxyConfiguration: Sendable {
  /// The most APCs served at once; a further one is answered 503.
  public var maximumConnections: Int
  /// The hosts, besides the one the APC reached (its Host field), whose pages may open a
  /// WebSocket to the APS.
  public var allowedWebSocketOrigins: [String]

  public init(maximumConnections: Int = 8, allowedWebSocketOrigins: [String] = AppNoodlesWebSocketOrigins) {
    self.maximumConnections = maximumConnections
    self.allowedWebSocketOrigins = allowedWebSocketOrigins
  }
}

/// An ATDECC Proxy Server (IEEE 1722.1-2021 Annex C) as a FlyingFox handler: it accepts APCs
/// and relays ATDECC PDUs between each of them and the layer 2 network.
///
/// It can be mounted at `AppWebSocketRoute` on an HTTP server that serves other routes too, or
/// served on a port of its own by `AtdeccProxyServer`. An upgrade on `AppWebSocketPath` (an
/// extension, for browser controllers) carries one APPDU per binary message; with the
/// HTTPTunnel trait, CONNECT carries a byte stream of them. Each connection runs its own APS
/// state machine (Clause C.5.2) over its own network port, made with `makePort`, so APCs see
/// each other's frames as other controllers' on the LAN; the connection limit and the entity
/// IDs are the handler's, however many servers it is mounted on. A message longer than
/// `AppWebSocketMaximumMessageLength` is closed 1009, but each frame is read whole first, up to
/// the server's bound (FlyingFox's `webSocketMaxFrameSize`), which a host server sets. There is
/// no authentication: any host that reaches the handler can send ATDECC frames on the LAN.
public final class AtdeccProxyHandler<Port: NetworkPort>: HTTPHandler, Sendable {
  public let configuration: AtdeccProxyConfiguration
  public let entityIDs: AtdeccProxyEntityIDs
  private let slots: AtdeccProxySlots
  private let makePort: @Sendable () throws -> Port
  private let logger: Logger

  /// `linkMacAddress` is the MAC address of the ports `makePort` makes (linkMac, Clause
  /// C.5.2.1.15).
  public init(
    configuration: AtdeccProxyConfiguration = .init(),
    linkMacAddress: EUI48,
    logger: Logger,
    makePort: @escaping @Sendable () throws -> Port
  ) {
    self.configuration = configuration
    entityIDs = AtdeccProxyEntityIDs(linkMacAddress: linkMacAddress)
    slots = AtdeccProxySlots(capacity: configuration.maximumConnections)
    self.makePort = makePort
    self.logger = logger
  }

  /// WAITING_FOR_REQUEST (Clause C.5.2): every request.
  public func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
    let outcome = appRequestOutcome(on: request, allowedWebSocketOrigins: configuration.allowedWebSocketOrigins)
    guard let transport = outcome.transport else {
      logger.debug("ATDECC proxy refused \(request.method.rawValue) \(request.path): \(outcome.requestValid)")
      return outcome.refusal
    }
    guard let slot = AtdeccProxySlot(slots) else {
      logger.notice("ATDECC proxy refused an APC: \(configuration.maximumConnections) are connected")
      return AppRequestOutcome.refused(503).refusal
    }
    let port: Port
    do {
      port = try makePort()
    } catch {
      logger.warning("ATDECC proxy cannot open its network port: \(error)")
      return AppRequestOutcome.refused(503).refusal
    }
    let connection = AtdeccProxyConnection(port: port, entityIDs: entityIDs, logger: logger)
    switch transport {
    case .connect:
      #if HTTPTunnel
      return HTTPResponse(tunnel: AtdeccProxyTunnel(connection: connection, slot: slot, logger: logger))
      #else
      // appRequestOutcome refuses CONNECT without the trait
      return AppRequestOutcome.refusedConnect.refusal
      #endif
    case .webSocket:
      // the handshake is FlyingFox's: a malformed one is answered 400
      let session = AtdeccProxySession(slot: slot, connection: connection)
      let channel = AtdeccProxyWebSocket(session, logger: logger)
      return try await WebSocketHTTPHandler(handler: channel).handleRequest(request)
    }
  }
}

public extension AtdeccProxyHandler where Port == EthernetPort {
  /// An APS relaying to the Ethernet interface `interfaceName`, one AF_PACKET socket per
  /// connection; throws if there is no such interface.
  convenience init(
    interfaceName: String,
    configuration: AtdeccProxyConfiguration = .init(),
    logger: Logger
  ) throws {
    let interface = try EthernetInterface(name: interfaceName)
    self.init(configuration: configuration, linkMacAddress: interface.macAddress, logger: logger) {
      try EthernetPort(interfaceName: interfaceName)
    }
  }
}

/// An APS on a TCP port of its own: one FlyingFox `HTTPServer` on the IPv6 wildcard, which
/// accepts IPv4 too, passing the requests for `transports` to its handler.
public final class AtdeccProxyServer<Port: NetworkPort>: Sendable {
  /// The port as configured; 0 lets the kernel choose one (see `listeningPort()`).
  public let port: UInt16
  public let transports: Set<AppTransport>
  public let handler: AtdeccProxyHandler<Port>
  private let server: HTTPServer
  private let logger: Logger

  /// Listens on `port` at every address. Without `.connect` in `transports`, CONNECT is refused
  /// 501, as without the HTTPTunnel trait; without `.webSocket`, every other request is 404.
  public init(
    port: UInt16 = AppDefaultPort,
    transports: Set<AppTransport> = [.connect, .webSocket],
    handler: AtdeccProxyHandler<Port>,
    logger: Logger
  ) {
    self.port = port
    self.transports = transports
    self.handler = handler
    self.logger = logger
    #if HTTPTunnel
    // FlyingFox's main branch, which the trait needs, bounds incoming WebSocket frames
    let config = HTTPServer.Configuration(
      address: sockaddr_in6.inet6(port: port),
      webSocketMaxFrameSize: AppWebSocketMaximumMessageLength,
      logger: AtdeccProxyHTTPLogging(logger: logger)
    )
    #else
    let config = HTTPServer.Configuration(
      address: sockaddr_in6.inet6(port: port),
      logger: AtdeccProxyHTTPLogging(logger: logger)
    )
    #endif
    server = HTTPServer(config: config, handler: AtdeccProxyTransportFilter(transports: transports, handler: handler))
  }

  /// Serves APCs until the task is cancelled, then closes every connection (FINISH). Throws if
  /// the server cannot listen, or stops listening.
  public func run() async throws {
    // the port the kernel chose, if asked to choose
    let announcement = Task { [self] in
      try? await waitUntilListening()
      if let port = await listeningPort() { logger.info("ATDECC proxy listening on TCP port \(port)") }
    }
    defer { announcement.cancel() }
    try await server.run()
  }

  public func waitUntilListening(timeout: TimeInterval = 5) async throws {
    try await server.waitUntilListening(timeout: timeout)
  }

  /// The port the server listens on, once listening.
  public func listeningPort() async -> UInt16? {
    switch await server.listeningAddress {
    case let .ip4(_, port), let .ip6(_, port): port
    default: nil
    }
  }
}

//
// Requests
//

/// The requests an `AtdeccProxyServer` passes to its handler: those for its transports.
private struct AtdeccProxyTransportFilter<Port: NetworkPort>: HTTPHandler {
  let transports: Set<AppTransport>
  let handler: AtdeccProxyHandler<Port>

  func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
    if request.method == .CONNECT, !transports.contains(.connect) {
      return AppRequestOutcome.refusedConnect.refusal
    }
    if request.method != .CONNECT, !transports.contains(.webSocket) {
      return AppRequestOutcome.refused(404).refusal
    }
    return try await handler.handleRequest(request)
  }
}

/// The connections in use, against the limit; only accepted requests count.
private final class AtdeccProxySlots: Sendable {
  let capacity: Int
  let inUse = Atomic(0)

  init(capacity: Int) {
    self.capacity = capacity
  }
}

/// A connection's place against the limit, given back when the last reference to it goes:
/// however the connection ends, or if FlyingFox never starts it.
private final class AtdeccProxySlot: Sendable {
  private let slots: AtdeccProxySlots

  init?(_ slots: AtdeccProxySlots) {
    guard slots.inUse.add(1, ordering: .relaxed).newValue <= slots.capacity else {
      slots.inUse.subtract(1, ordering: .relaxed)
      return nil
    }
    self.slots = slots
  }

  deinit {
    slots.inUse.subtract(1, ordering: .relaxed)
  }
}

#if HTTPTunnel

//
// CONNECT - Clause C.1
//

/// An APC's connection after CONNECT: a byte stream of APPDUs each way.
private struct AtdeccProxyTunnel<Port: NetworkPort>: HTTPTunnelHandler {
  let connection: AtdeccProxyConnection<Port>
  let slot: AtdeccProxySlot
  let logger: Logger

  func handleTunnel(bytes: some AsyncBufferedSequence<UInt8>, socket: AsyncSocket) async throws {
    // shutting the socket down wakes a read or write waiting on it; every shutdown happens
    // before this returns, while the descriptor is still the tunnel's
    let descriptor = socket.socket.file.rawValue
    connection.onAbort { _ = Glibc.shutdown(descriptor, Int32(SHUT_RDWR)) }
    let writer = Task { [connection] in
      for await output in connection.output {
        guard case let .appdu(appdu) = output else { continue }
        guard (try? await socket.write(Data(appdu.serialized()))) != nil else { break }
      }
    }
    let reader = Task { [connection, logger] in
      var decoder = AppduStreamDecoder()
      var iterator = bytes.makeAsyncIterator()
      do {
        while let buffer = try await iterator.nextBuffer(suggested: 4096) {
          for appdu in try decoder.decode(Array(buffer)) {
            connection.deliver(appdu)
          }
        }
      } catch {
        logger.debug("ATDECC proxy closing a connection: \(error)")
      }
      await connection.apcClosed(closeCode: nil)
    }
    await connection.run()
    // closeTcpConnection() (Clause C.5.2.2.1)
    _ = Glibc.shutdown(descriptor, Int32(SHUT_RDWR))
    await writer.value
    await reader.value
    _ = slot
  }
}

#endif

//
// WebSocket - an extension, not part of Annex C
//

/// An accepted APC's slot and connection, and so its network port.
private struct AtdeccProxySession<Port: NetworkPort> {
  let slot: AtdeccProxySlot
  let connection: AtdeccProxyConnection<Port>
}

/// An APC's connection after a WebSocket upgrade: one APPDU per binary message. Messages are
/// read as one stream, as the Noodles/Sienda proxy reads them, so an APPDU split across
/// messages, or several in one, are accepted too.
private final class AtdeccProxyWebSocket<Port: NetworkPort>: WSHandler {
  /// Until `makeFrames` hands it to the task that runs it: FlyingFox keeps this handler while
  /// it holds the socket, which a client that stops reading holds indefinitely.
  private let session: Mutex<AtdeccProxySession<Port>?>
  private let logger: Logger

  init(_ session: AtdeccProxySession<Port>, logger: Logger) {
    self.session = Mutex(session)
    self.logger = logger
  }

  func makeFrames(for client: AsyncThrowingStream<WSFrame, any Error>) async throws -> AsyncStream<WSFrame> {
    let session = session.withLock { session in
      defer { session = nil }
      return session
    }
    // FlyingFox makes the frames once
    guard let session else { return AsyncStream { $0.finish() } }
    // pulled by FlyingFox one frame at a time, so a client that stops reading backs up
    // `connection.output`, which is bounded; the iterator does not hold the connection
    let output = AtdeccProxyOutputIterator(session.connection.output)
    // the session's owner: the slot and the network port go when it ends, even while
    // FlyingFox is still blocked writing to the socket
    let task = Task { [logger] in
      await withTaskGroup { group in
        group.addTask { await Self.read(client, into: session.connection, logger: logger) }
        await session.connection.run()
        // CLOSED, whoever ended it: a read still waiting on the socket would never end
        group.cancelAll()
      }
    }
    return AsyncStream(unfolding: { await output.nextFrame() }, onCancel: { task.cancel() })
  }

  private static func read(
    _ client: AsyncThrowingStream<WSFrame, any Error>,
    into connection: AtdeccProxyConnection<Port>,
    logger: Logger
  ) async {
    var decoder = AppduStreamDecoder()
    var message: Data?
    var closeCode: UInt16?
    do {
      for try await frame in client {
        switch frame.opcode {
        case .binary where message == nil, .continuation where message != nil:
          let payload = (message ?? Data()) + frame.payload
          guard payload.count <= AppWebSocketMaximumMessageLength else { throw WebSocketFailure(closeCode: 1009) }
          guard frame.fin else {
            message = payload
            continue
          }
          message = nil
          for appdu in try decoder.decode(Array(payload)) {
            connection.deliver(appdu)
          }
        case .text: throw WebSocketFailure(closeCode: 1003)
        case .ping: connection.pong(Array(frame.payload))
        case .pong: break
        case .close:
          closeCode = 1000
          break
        default: throw WebSocketFailure(closeCode: 1002)
        }
        if closeCode != nil { break }
      }
    } catch let failure as WebSocketFailure {
      closeCode = failure.closeCode
    } catch is AppduError {
      closeCode = 1007
    } catch {
      logger.debug("ATDECC proxy closing a connection: \(error)")
    }
    await connection.apcClosed(closeCode: closeCode)
  }
}

/// Why a WebSocket connection is failed, with its close status (RFC 6455 Section 7.4.1).
private struct WebSocketFailure: Error {
  let closeCode: UInt16
}

/// The frames of a connection's output, read by the one task FlyingFox writes them from.
private final class AtdeccProxyOutputIterator<Port: NetworkPort>: @unchecked Sendable {
  private var iterator: AsyncStream<AtdeccProxyConnection<Port>.Output>.AsyncIterator
  private var isClosed = false

  init(_ output: AsyncStream<AtdeccProxyConnection<Port>.Output>) {
    iterator = output.makeAsyncIterator()
  }

  func nextFrame() async -> WSFrame? {
    guard !isClosed, let output = await iterator.next() else { return nil }
    switch output {
    case let .appdu(appdu):
      return WSFrame(fin: true, opcode: .binary, mask: nil, payload: Data(appdu.serialized()))
    case let .pong(payload):
      return WSFrame(fin: true, opcode: .pong, mask: nil, payload: Data(payload))
    case let .close(closeCode):
      isClosed = true
      return closeCode.map { .close(code: WSCloseCode($0)) }
    }
  }
}

/// FlyingFox's log, through the server's logger; FlyingFox reports clients' errors as errors.
private struct AtdeccProxyHTTPLogging: FlyingSocks.Logging {
  let logger: Logger

  func logDebug(_ debug: @autoclosure () -> String) { logger.trace("\(debug())") }
  func logInfo(_ info: @autoclosure () -> String) { logger.trace("\(info())") }
  func logWarning(_ warning: @autoclosure () -> String) { logger.debug("\(warning())") }
  func logError(_ error: @autoclosure () -> String) { logger.debug("\(error())") }
  func logCritical(_ critical: @autoclosure () -> String) { logger.debug("\(critical())") }
}

#endif
