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

/// How an APS is run.
public struct AtdeccProxyServerConfiguration: Sendable {
  /// The TCP port to listen on, both for CONNECT and WebSocket upgrades; 0 lets the kernel
  /// choose one (see `AtdeccProxyServer.listeningPorts()`).
  public var port: UInt16
  /// The IP addresses to listen on, as literals ("10.10.32.8", "::1"); "::" is every address.
  public var addresses: [String]
  /// The most APCs served at once; a further one is answered 503 once its request is read.
  public var maximumConnections: Int
  /// The hosts, besides the APS's own, whose pages may open a WebSocket to it.
  public var allowedWebSocketOrigins: [String]
  /// How long a CONNECT peer may leave data unacknowledged, or an idle one go unheard, before
  /// its connection fails (TCP_USER_TIMEOUT, and keepalive probes).
  public var peerTimeout: Duration
  /// How long one write to a CONNECT APC may wait for it to read; a write that waits longer
  /// ends the connection.
  public var writeTimeout: Duration

  public init(
    port: UInt16 = AppDefaultPort,
    addresses: [String] = ["::"],
    maximumConnections: Int = 8,
    allowedWebSocketOrigins: [String] = AppNoodlesWebSocketOrigins,
    peerTimeout: Duration = .seconds(30),
    writeTimeout: Duration = .seconds(10)
  ) {
    self.port = port
    self.addresses = addresses
    self.maximumConnections = maximumConnections
    self.allowedWebSocketOrigins = allowedWebSocketOrigins
    self.peerTimeout = peerTimeout
    self.writeTimeout = writeTimeout
  }
}

/// The kernel send buffer of a CONNECT APC's socket: some hundreds of APPDUs.
private let _sendBufferSize: Int32 = 65536
/// How long what is queued for a CONNECT APC may still be written once its connection closes.
private let _drainTimeout = Duration.seconds(2)

/// An ATDECC Proxy Server (IEEE 1722.1-2021 Annex C): accepts APCs on a TCP port and relays
/// ATDECC PDUs between each of them and the layer 2 network.
///
/// HTTP is FlyingFox's, one `HTTPServer` per address on its own FlyingSocks socket pool. A
/// CONNECT request is answered 200 and its connection handed to the APS as a tunnel; an upgrade
/// on `AppWebSocketPath` (an extension, for browser controllers) is FlyingFox's WebSocket
/// handshake, one APPDU per binary message. Each connection runs its own APS state machine
/// (Clause C.5.2) over its own network port, made with `makePort`, so APCs see each other's
/// frames as other controllers' on the LAN. There is no authentication: any host that reaches
/// the addresses can send ATDECC frames on the LAN. Advertising it with DNS-SD (Clause C.2)
/// is the caller's: see `appServiceTXTRecord`.
public final class AtdeccProxyServer<Port: NetworkPort>: Sendable {
  public let configuration: AtdeccProxyServerConfiguration
  public let entityIDs: AtdeccProxyEntityIDs
  /// Each listener's server, and for the IPv6 wildcard, the IPv4 one to use if IPv6 is off.
  private let servers: [(server: HTTPServer, ipv4Fallback: HTTPServer?)]
  private let logger: Logger

  /// Listens on `configuration.port` at each of `configuration.addresses` once run.
  /// `linkMacAddress` is the MAC address of the ports `makePort` makes (linkMac, Clause
  /// C.5.2.1.15). Throws if an address is not an IP literal.
  public init(
    configuration: AtdeccProxyServerConfiguration = .init(),
    linkMacAddress: EUI48,
    logger: Logger,
    entityIDs: AtdeccProxyEntityIDs? = nil,
    makePort: @escaping @Sendable () throws -> Port
  ) throws {
    self.configuration = configuration
    self.logger = logger
    let entityIDs = entityIDs ?? AtdeccProxyEntityIDs(linkMacAddress: linkMacAddress)
    self.entityIDs = entityIDs
    let handler = AtdeccProxyRequestHandler(
      configuration: configuration,
      entityIDs: entityIDs,
      slots: AtdeccProxySlots(capacity: configuration.maximumConnections),
      makePort: makePort,
      logger: logger
    )
    let makeServer = { (address: any SocketAddress) in
      HTTPServer(config: Self.serverConfiguration(address, logger: logger), handler: handler)
    }
    servers = try Self.addresses(configuration).map { address in
      let isWildcard = address is sockaddr_in6 && configuration.addresses.contains("::")
      let fallback = isWildcard ? makeServer(sockaddr_in.inet(port: configuration.port)) : nil
      return (makeServer(address), fallback)
    }
  }

  private static func serverConfiguration(_ address: some SocketAddress, logger: Logger) -> HTTPServer.Configuration {
    #if HTTPTunnel
    // FlyingFox's main branch, which the trait needs, bounds incoming WebSocket frames
    HTTPServer.Configuration(
      address: address,
      webSocketMaxFrameSize: AppWebSocketMaximumMessageLength,
      logger: AtdeccProxyHTTPLogging(logger: logger)
    )
    #else
    HTTPServer.Configuration(address: address, logger: AtdeccProxyHTTPLogging(logger: logger))
    #endif
  }

  /// One socket address per listening address; with a wildcard, that alone, since an IPv6
  /// wildcard listener also accepts IPv4.
  private static func addresses(_ configuration: AtdeccProxyServerConfiguration) throws -> [any SocketAddress] {
    let literals = configuration.addresses.contains("::") ? ["::"] : configuration.addresses
    return try literals.map { literal -> any SocketAddress in
      literal.contains(":")
        ? try sockaddr_in6.inet6(ip6: literal, port: configuration.port)
        : try sockaddr_in.inet(ip4: literal, port: configuration.port)
    }
  }

  /// Serves APCs until the task is cancelled, then closes every connection (FINISH). A listener
  /// that fails, because accepting failed for want of descriptors say, or its address is not
  /// yet configured, is logged (again when its error changes) and started again; one on the
  /// IPv6 wildcard that cannot bind for want of IPv6 listens on the IPv4 wildcard instead.
  /// FlyingFox ends a listener, and the connections it serves, when an accept fails.
  public func run() async throws {
    logger.info("ATDECC proxy listening on TCP port \(configuration.port) at \(configuration.addresses.joined(separator: ", "))")
    await withDiscardingTaskGroup { group in
      for (server, ipv4Fallback) in servers {
        group.addTask { [logger] in
          await Self.serve(server, ipv4Fallback: ipv4Fallback, logger: logger)
        }
      }
    }
  }

  private static func serve(_ server: HTTPServer, ipv4Fallback: HTTPServer?, logger: Logger) async {
    var server = server
    var ipv4Fallback = ipv4Fallback
    var lastError: String?
    while !Task.isCancelled {
      do {
        try await server.run()
      } catch {
        guard !Task.isCancelled else { return }
        if let fallback = ipv4Fallback, Self.isIPv6Unavailable(error) {
          logger.notice("ATDECC proxy listening on the IPv4 wildcard: IPv6 is unavailable (\(error))")
          server = fallback
          ipv4Fallback = nil
          continue
        }
        let description = "\(error)"
        if description != lastError {
          logger.warning("ATDECC proxy listener failed, restarting it: \(error)")
          lastError = description
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private static func isIPv6Unavailable(_ error: any Error) -> Bool {
    guard case let .failed(_, errno, _) = error as? SocketError else { return false }
    return errno == EAFNOSUPPORT || errno == EADDRNOTAVAIL || errno == EPROTONOSUPPORT
  }

  /// Waits until every address is listening.
  public func waitUntilListening(timeout: TimeInterval = 5) async throws {
    for (server, _) in servers {
      try await server.waitUntilListening(timeout: timeout)
    }
  }

  /// The port each address listens on, once listening.
  public func listeningPorts() async -> [UInt16] {
    var ports = [UInt16]()
    for (server, _) in servers {
      switch await server.listeningAddress {
      case let .ip4(_, port), let .ip6(_, port): ports.append(port)
      default: break
      }
    }
    return ports
  }
}

public extension AtdeccProxyServer where Port == EthernetPort {
  /// An APS relaying to the Ethernet interface `interfaceName`, one AF_PACKET socket per
  /// connection.
  convenience init(
    interfaceName: String,
    configuration: AtdeccProxyServerConfiguration = .init(),
    logger: Logger
  ) throws {
    let interface = try EthernetInterface(name: interfaceName)
    try self.init(configuration: configuration, linkMacAddress: interface.macAddress, logger: logger) {
      try EthernetPort(interfaceName: interfaceName)
    }
  }
}

//
// Requests
//

/// The connections in use, against the limit; only accepted requests count.
private final class AtdeccProxySlots: Sendable {
  let capacity: Int
  let inUse = Atomic(0)

  init(capacity: Int) {
    self.capacity = capacity
  }
}

/// A connection's place against the limit, given back when the last reference to it goes,
/// however the connection ends (or if FlyingFox never starts it).
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

/// WAITING_FOR_REQUEST (Clause C.5.2): every request on every address.
private struct AtdeccProxyRequestHandler<Port: NetworkPort>: HTTPHandler {
  let configuration: AtdeccProxyServerConfiguration
  let entityIDs: AtdeccProxyEntityIDs
  let slots: AtdeccProxySlots
  let makePort: @Sendable () throws -> Port
  let logger: Logger

  func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
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
      return HTTPResponse(tunnel: AtdeccProxyTunnel(connection: connection, slot: slot, configuration: configuration, logger: logger))
      #else
      // appRequestOutcome refuses CONNECT without the trait
      return AppRequestOutcome.refusedConnect.refusal
      #endif
    case .webSocket:
      // the handshake is FlyingFox's: a malformed one is answered 400
      let channel = AtdeccProxyWebSocket(connection: connection, slot: slot, logger: logger)
      return try await WebSocketHTTPHandler(handler: channel).handleRequest(request)
    }
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
  let configuration: AtdeccProxyServerConfiguration
  let logger: Logger

  func handleTunnel(bytes: some AsyncBufferedSequence<UInt8>, socket: AsyncSocket) async throws {
    configureLiveness(socket.socket)
    let shutter = AtdeccProxySocketShutter(socket.socket)
    // shut down after this returns, a descriptor FlyingFox has closed may belong to another
    defer { shutter.invalidate() }
    // ending the connection at once fails a write waiting on an APC that has stopped reading
    connection.onAbort { shutter.shutdown(SHUT_RDWR) }
    let writer = Task { [connection, configuration, logger] in
      do {
        for await output in connection.output {
          guard case let .appdu(appdu) = output else { continue }
          try await Self.write(Data(appdu.serialized()), to: socket, shutter: shutter, within: configuration.writeTimeout)
        }
      } catch {
        logger.debug("ATDECC proxy could not write to an APC: \(error)")
        shutter.shutdown(SHUT_RDWR)
      }
    }
    let reader = Task { [connection, logger] in
      await Self.read(bytes, into: connection, logger: logger)
    }
    await connection.run()
    // what is queued is written for a little while, then the connection is ended
    let deadline = Task {
      try await Task.sleep(for: _drainTimeout)
      shutter.shutdown(SHUT_RDWR)
    }
    await writer.value
    deadline.cancel()
    shutter.shutdown(SHUT_RD)
    await reader.value
    _ = slot
  }

  /// Writes `data`, ending the connection if the APC has not read enough of it within
  /// `timeout`, which fails the write.
  private static func write(
    _ data: Data,
    to socket: AsyncSocket,
    shutter: AtdeccProxySocketShutter,
    within timeout: Duration
  ) async throws {
    let deadline = Task {
      try await Task.sleep(for: timeout)
      shutter.shutdown(SHUT_RDWR)
    }
    defer { deadline.cancel() }
    try await socket.write(data)
  }

  /// A peer that stops answering is noticed within `peerTimeout`, idle or not: keepalive
  /// probes for an idle connection, TCP_USER_TIMEOUT for data it does not acknowledge. The
  /// send buffer is fixed rather than autotuned (up to megabytes), so what one that stops
  /// reading holds stays small and a write soon waits on it.
  private func configureLiveness(_ socket: Socket) {
    let seconds = Int32(configuration.peerTimeout.components.seconds)
    try? socket.setValue(_sendBufferSize, for: Int32SocketOption(name: SO_SNDBUF))
    try? socket.setValue(true, for: BoolSocketOption(name: SO_KEEPALIVE))
    try? socket.setValue(max(seconds / 3, 1), for: Int32SocketOption(level: Int32(IPPROTO_TCP), name: TCP_KEEPIDLE))
    try? socket.setValue(max(seconds / 6, 1), for: Int32SocketOption(level: Int32(IPPROTO_TCP), name: TCP_KEEPINTVL))
    try? socket.setValue(3, for: Int32SocketOption(level: Int32(IPPROTO_TCP), name: TCP_KEEPCNT))
    try? socket.setValue(seconds * 1000, for: Int32SocketOption(level: Int32(IPPROTO_TCP), name: TCP_USER_TIMEOUT))
  }

  private static func read(_ bytes: some AsyncBufferedSequence<UInt8>, into connection: AtdeccProxyConnection<Port>, logger: Logger) async {
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
}


/// Shuts a tunnel's socket down, which wakes a read or write waiting on it, for as long as the
/// tunnel has it: once the handler returns FlyingFox closes the descriptor, and its number may
/// be another's.
private final class AtdeccProxySocketShutter: Sendable {
  private let descriptor: Mutex<Int32?>

  init(_ socket: Socket) {
    descriptor = Mutex(socket.file.rawValue)
  }

  func shutdown(_ how: Int) {
    descriptor.withLock { descriptor in
      if let descriptor { _ = Glibc.shutdown(descriptor, Int32(how)) }
    }
  }

  func invalidate() {
    descriptor.withLock { $0 = nil }
  }
}

#endif

//
// WebSocket - an extension, not part of Annex C
//

/// An APC's connection after a WebSocket upgrade: one APPDU per binary message. Messages are
/// read as one stream, as the Noodles/Sienda proxy reads them, so an APPDU split across
/// messages, or several in one, are accepted too.
private struct AtdeccProxyWebSocket<Port: NetworkPort>: WSHandler {
  let connection: AtdeccProxyConnection<Port>
  let slot: AtdeccProxySlot
  let logger: Logger

  func makeFrames(for client: AsyncThrowingStream<WSFrame, any Error>) async throws -> AsyncStream<WSFrame> {
    let task = Task { [connection, slot, logger] in
      await withTaskGroup { group in
        group.addTask { await connection.run() }
        group.addTask { await Self.read(client, into: connection, logger: logger) }
      }
      _ = slot
    }
    // pulled by FlyingFox one frame at a time, so a client that stops reading backs up
    // `connection.output`, which is bounded
    let output = AtdeccProxyOutputIterator(connection.output)
    return AsyncStream(unfolding: { await output.nextFrame() }, onCancel: { task.cancel() })
  }

  private static func read(
    _ client: AsyncThrowingStream<WSFrame, any Error>,
    into connection: AtdeccProxyConnection<Port>,
    logger: Logger
  ) async {
    var decoder = AppduStreamDecoder()
    var message: Data?
    let closeCode: UInt16?
    do {
      closeCode = try await readMessages(client, into: connection, decoder: &decoder, message: &message)
    } catch let error as AppduError {
      logger.debug("ATDECC proxy closing a connection: \(error)")
      closeCode = 1007
    } catch let error as AtdeccProxyWebSocketError {
      logger.debug("ATDECC proxy closing a connection: \(error)")
      closeCode = error.closeCode
    } catch {
      logger.debug("ATDECC proxy closing a connection: \(error)")
      closeCode = nil
    }
    await connection.apcClosed(closeCode: closeCode)
  }

  /// Reads until the client closes (1000) or its stream ends (nil).
  private static func readMessages(
    _ client: AsyncThrowingStream<WSFrame, any Error>,
    into connection: AtdeccProxyConnection<Port>,
    decoder: inout AppduStreamDecoder,
    message: inout Data?
  ) async throws -> UInt16? {
    for try await frame in client {
      switch frame.opcode {
      case .binary where message == nil, .continuation where message != nil:
        var payload = (message ?? Data()) + frame.payload
        guard payload.count <= AppWebSocketMaximumMessageLength else { throw AtdeccProxyWebSocketError.messageTooLong }
        guard frame.fin else {
          message = payload
          continue
        }
        message = nil
        for appdu in try decoder.decode(Array(payload)) {
          connection.deliver(appdu)
        }
        payload = Data()
      case .text:
        throw AtdeccProxyWebSocketError.textMessage
      case .ping:
        connection.pong(Array(frame.payload))
      case .pong:
        break
      case .close:
        return 1000
      default:
        throw AtdeccProxyWebSocketError.protocolError
      }
    }
    return nil
  }
}

/// Why a WebSocket connection is failed, with its close status (RFC 6455 Section 7.4.1).
private enum AtdeccProxyWebSocketError: Error {
  case textMessage
  case messageTooLong
  case protocolError

  var closeCode: UInt16 {
    switch self {
    case .textMessage: 1003
    case .messageTooLong: 1009
    case .protocolError: 1002
    }
  }
}

/// The frames of a connection's output, read by the one task FlyingFox writes them from.
private final class AtdeccProxyOutputIterator<Port: NetworkPort>: @unchecked Sendable {
  private var iterator: AsyncStream<AtdeccProxyConnection<Port>.Output>.AsyncIterator
  private var isClosed = false

  init(_ output: AsyncStream<AtdeccProxyConnection<Port>.Output>) {
    iterator = output.makeAsyncIterator()
  }

  func nextFrame() async -> WSFrame? {
    while !isClosed, let output = await iterator.next() {
      switch output {
      case let .appdu(appdu):
        return WSFrame(fin: true, opcode: .binary, mask: nil, payload: Data(appdu.serialized()))
      case let .pong(payload):
        return WSFrame(fin: true, opcode: .pong, mask: nil, payload: Data(payload))
      case let .close(closeCode):
        isClosed = true
        guard let closeCode else { return nil }
        return .close(code: WSCloseCode(closeCode))
      }
    }
    return nil
  }
}

/// FlyingFox's log, through the server's logger; FlyingFox reports clients' errors as errors.
private struct AtdeccProxyHTTPLogging: FlyingSocks.Logging {
  let logger: Logger

  func logDebug(_ debug: @autoclosure () -> String) { logger.trace("\(debug())") }
  func logInfo(_ info: @autoclosure () -> String) { logger.trace("\(info())") }
  func logWarning(_ warning: @autoclosure () -> String) { logger.debug("\(warning())") }
  func logError(_ error: @autoclosure () -> String) { logger.debug("\(error())") }
  // including a listener ending because it was stopped; one that fails is logged by `run()`
  func logCritical(_ critical: @autoclosure () -> String) { logger.debug("\(critical())") }
}

#endif
