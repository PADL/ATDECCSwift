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
import Glibc
import IEEE802
import IEEE802Linux
import IORing
import IORingUtils
import Logging
import Synchronization
import struct SystemPackage.Errno

/// How an APS is run.
public struct AtdeccProxyServerConfiguration: Sendable {
  /// The TCP port to listen on, both for CONNECT and WebSocket upgrades; 0 lets the kernel
  /// choose one (see `AtdeccProxyServer.port`).
  public var port: UInt16
  /// The most APCs served at once; a further one is answered 503 once its request is read.
  public var maximumConnections: Int
  /// The hosts, besides the APS's own, whose pages may open a WebSocket to it.
  public var allowedWebSocketOrigins: [String]
  /// How long an APC may spend sending its whole HTTP request, from connecting.
  public var requestTimeout: Duration
  /// How long one write to an APC may wait for it to read; a write that waits longer ends the
  /// connection.
  public var writeTimeout: Duration

  public init(
    port: UInt16 = AppDefaultPort,
    maximumConnections: Int = 8,
    allowedWebSocketOrigins: [String] = AppNoodlesWebSocketOrigins,
    requestTimeout: Duration = .seconds(10),
    writeTimeout: Duration = .seconds(10)
  ) {
    self.port = port
    self.maximumConnections = maximumConnections
    self.allowedWebSocketOrigins = allowedWebSocketOrigins
    self.requestTimeout = requestTimeout
    self.writeTimeout = writeTimeout
  }
}

/// Messages queued for an APC beyond which it is not keeping up, and its connection is closed.
private let _apcOutputCapacity = 256
/// Frames queued for the network port, or events for a connection, beyond which more are
/// dropped, as a congested LAN drops them.
private let _layer2OutputCapacity = 256
private let _eventCapacity = 1024
/// How long what is queued for an APC may still be written once its connection closes.
private let _drainTimeout = Duration.seconds(2)

/// An ATDECC Proxy Server (IEEE 1722.1-2021 Annex C): accepts APCs on a TCP port and relays
/// ATDECC PDUs between each of them and the layer 2 network.
///
/// Each connection runs its own APS state machine (Clause C.5.2) over its own network port,
/// made with `makePort`, so APCs see each other's frames as they would other controllers'
/// on the LAN. Besides HTTP CONNECT, the port accepts WebSocket upgrades on
/// `AppWebSocketPath`, an extension for browser controllers. Advertising it with DNS-SD
/// (Clause C.2) is the caller's: see `appServiceTXTRecord`. There is no authentication: any
/// host that reaches the port can send ATDECC frames on the LAN.
public final class AtdeccProxyServer<Port: NetworkPort>: Sendable {
  public let configuration: AtdeccProxyServerConfiguration
  public let entityIDs: AtdeccProxyEntityIDs
  /// The port the server listens on.
  public let port: UInt16
  private let listener: Socket
  private let makePort: @Sendable () throws -> Port
  private let logger: Logger
  private let connectionCount = Atomic(0)

  /// Listens on `configuration.port` on every address, IPv6 and IPv4. `linkMacAddress` is the
  /// MAC address of the ports `makePort` makes (linkMac, Clause C.5.2.1.15).
  public init(
    configuration: AtdeccProxyServerConfiguration = .init(),
    linkMacAddress: EUI48,
    logger: Logger,
    ring: IORing = .shared,
    entityIDs: AtdeccProxyEntityIDs? = nil,
    makePort: @escaping @Sendable () throws -> Port
  ) throws {
    self.configuration = configuration
    self.entityIDs = entityIDs ?? AtdeccProxyEntityIDs(linkMacAddress: linkMacAddress)
    self.makePort = makePort
    self.logger = logger
    listener = try Self.listen(on: configuration.port, ring: ring)
    port = try listener.localAddress.port
  }

  private static func listen(on port: UInt16, ring: IORing) throws -> Socket {
    let socket: Socket
    do {
      socket = try Socket(ring: ring, domain: sa_family_t(AF_INET6), type: SOCK_STREAM, protocol: 0)
      try socket.setBooleanOption(level: CInt(IPPROTO_IPV6), option: IPV6_V6ONLY, to: false)
    } catch {
      // a host without IPv6, or without dual-stack sockets
      return try listen(on: port, ring: ring, domain: AF_INET)
    }
    try socket.setReuseAddr()
    try socket.setTcpNoDelay()
    try socket.bind(port: port)
    try socket.listen()
    return socket
  }

  private static func listen(on port: UInt16, ring: IORing, domain: CInt) throws -> Socket {
    let socket = try Socket(ring: ring, domain: sa_family_t(domain), type: SOCK_STREAM, protocol: 0)
    try socket.setReuseAddr()
    try socket.setTcpNoDelay()
    try socket.bind(port: port)
    try socket.listen()
    return socket
  }

  /// Serves APCs until the task is cancelled, then closes every connection (FINISH). A failed
  /// accept, for want of descriptors or memory say, is logged and the server goes on.
  public func run() async throws {
    logger.info("ATDECC proxy listening on TCP port \(port)")
    defer { try? listener.shutdown() }
    await withDiscardingTaskGroup { group in
      while !Task.isCancelled {
        guard let client = await accept() else { continue }
        group.addTask { [self] in await serve(client) }
      }
    }
  }

  private func accept() async -> Socket? {
    do {
      return try await listener.accept()
    } catch is CancellationError {
      return nil
    } catch let error as Errno where error == .canceled || error == .interrupted {
      return nil
    } catch {
      guard !Task.isCancelled else { return nil }
      logger.warning("ATDECC proxy could not accept a connection: \(error)")
      try? await Task.sleep(for: .milliseconds(100))
      return nil
    }
  }

  private func serve(_ socket: Socket) async {
    let peer = (try? socket.peerName) ?? "unknown"
    defer { try? socket.shutdown() }
    do {
      try Self.configureLiveness(socket)
      try await serveRequest(socket)
    } catch {
      logger.debug("ATDECC proxy connection from \(peer) ended: \(error)")
    }
  }

  /// A peer that stops answering is noticed within about half a minute, idle or not: keepalive
  /// probes for an idle connection, TCP_USER_TIMEOUT for data it does not acknowledge.
  private static func configureLiveness(_ socket: Socket) throws {
    try socket.setBooleanOption(option: SO_KEEPALIVE, to: true)
    try socket.setIntegerOption(level: CInt(IPPROTO_TCP), option: TCP_KEEPIDLE, to: 10)
    try socket.setIntegerOption(level: CInt(IPPROTO_TCP), option: TCP_KEEPINTVL, to: 5)
    try socket.setIntegerOption(level: CInt(IPPROTO_TCP), option: TCP_KEEPCNT, to: 3)
    try socket.setIntegerOption(level: CInt(IPPROTO_TCP), option: TCP_USER_TIMEOUT, to: 30000)
  }

  private func serveRequest(_ socket: Socket) async throws {
    let (head, leftover) = try await readRequestHead(socket)
    var outcome = head.map { appRequestOutcome(on: $0, allowedWebSocketOrigins: configuration.allowedWebSocketOrigins) }
      ?? .refused(400)
    // only accepted connections count towards the limit
    var isCounted = false
    if outcome.transport != nil {
      isCounted = connectionCount.add(1, ordering: .relaxed).newValue <= configuration.maximumConnections
      if !isCounted {
        connectionCount.subtract(1, ordering: .relaxed)
        outcome = .refused(503)
      }
    }
    defer { if isCounted { connectionCount.subtract(1, ordering: .relaxed) } }
    var port: Port?
    if isCounted {
      do {
        port = try makePort()
      } catch {
        logger.warning("ATDECC proxy cannot open its network port: \(error)")
        outcome = .refused(503)
      }
    }
    guard let transport = outcome.transport, let port else {
      logger.debug("ATDECC proxy refused \(head?.method ?? "a malformed request") \(head?.target ?? ""): \(outcome.requestValid)")
      let response = outcome.response
      _ = try await socket.write(response, count: response.count, awaitingAllWritten: true, timeout: configuration.writeTimeout)
      return
    }
    let connection = AtdeccProxyConnection(
      socket: socket,
      transport: transport,
      outcome: outcome,
      leftover: leftover,
      port: port,
      entityIDs: entityIDs,
      writeTimeout: configuration.writeTimeout,
      logger: logger
    )
    await connection.run()
  }

  /// The request head and whatever followed it, or a nil head if it is malformed or too long;
  /// throws if it has not all arrived within `requestTimeout` of connecting.
  private func readRequestHead(_ socket: Socket) async throws -> (AppHTTPRequestHead?, [UInt8]) {
    let deadline = ContinuousClock.now + configuration.requestTimeout
    var bytes = [UInt8]()
    while bytes.count <= AppMaximumRequestHeadLength {
      if let end = AppHTTPRequestHead.endOfHead(in: bytes) {
        return (AppHTTPRequestHead(bytes: bytes[..<end]), Array(bytes[end...]))
      }
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else { throw Errno.timedOut }
      let chunk = try await socket.receive(count: 1024, timeout: remaining)
      guard !chunk.isEmpty else { throw Errno.connectionReset }
      bytes += chunk
    }
    return (nil, [])
  }
}

public extension AtdeccProxyServer where Port == EthernetPort {
  /// An APS on the Ethernet interface `interfaceName`, one AF_PACKET socket per connection.
  convenience init(
    interfaceName: String,
    configuration: AtdeccProxyServerConfiguration = .init(),
    logger: Logger,
    ring: IORing = .shared
  ) throws {
    let interface = try EthernetInterface(name: interfaceName)
    try self.init(configuration: configuration, linkMacAddress: interface.macAddress, logger: logger, ring: ring) {
      try EthernetPort(interfaceName: interfaceName)
    }
  }
}

//
// Connections
//

/// One APC's connection: its state machine, driven by events from the APC, the network port,
/// the port's link and a one-second clock (Clause C.5.2.1.4), handled one at a time.
private final class AtdeccProxyConnection<Port: NetworkPort>: Sendable {
  private enum Event: Sendable {
    case apc(Appdu)
    /// The APC's end has closed; for a WebSocket, the close status to answer with, if any.
    case apcClosed(closeCode: UInt16?)
    case layer2(IEEE802Packet)
    case link(Bool)
    case tick
  }

  private let socket: Socket
  private let transport: AppTransport
  private let outcome: AppRequestOutcome
  private let leftover: [UInt8]
  private let port: Port
  private let entityIDs: AtdeccProxyEntityIDs
  private let writeTimeout: Duration
  private let logger: Logger

  init(
    socket: Socket,
    transport: AppTransport,
    outcome: AppRequestOutcome,
    leftover: [UInt8],
    port: Port,
    entityIDs: AtdeccProxyEntityIDs,
    writeTimeout: Duration,
    logger: Logger
  ) {
    self.socket = socket
    self.transport = transport
    self.outcome = outcome
    self.leftover = leftover
    self.port = port
    self.entityIDs = entityIDs
    self.writeTimeout = writeTimeout
    self.logger = logger
  }

  private typealias Outputs = (apc: AsyncStream<[UInt8]>.Continuation, layer2: AsyncStream<IEEE802Packet>.Continuation)

  func run() async {
    let (events, eventSink) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(_eventCapacity))
    let (apcOutput, apcSink) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .bufferingOldest(_apcOutputCapacity))
    let (layer2Output, layer2Sink) = AsyncStream<IEEE802Packet>.makeStream(bufferingPolicy: .bufferingOldest(_layer2OutputCapacity))
    let key = entityIDs.makeConnection()
    defer { entityIDs.release(key) }
    // unstructured so that, once the connection closes, what is queued for the APC (a refusal,
    // a WebSocket close) is still written while the producers are cancelled
    let writer = Task { [self] in await writeApc(apcOutput) }
    await withTaskGroup { group in
      group.addTask { [self] in await writeLayer2(layer2Output) }
      group.addTask { [self] in await monitorLink(eventSink) }
      group.addTask { [self] in await receiveLayer2(eventSink) }
      group.addTask { [self] in await tick(eventSink) }
      group.addTask { [self] in await readApc(eventSink, apcSink) }
      await drive(events, key: key, (apcSink, layer2Sink))
      apcSink.finish()
      layer2Sink.finish()
      eventSink.finish()
      group.cancelAll()
      // ends a read in progress, which may not notice cancellation
      try? socket.shutdown(.read)
      await drain(writer)
    }
  }

  /// Waits a little for what is queued for the APC to be written, then ends the connection,
  /// which fails a write still waiting.
  private func drain(_ writer: Task<(), Never>) async {
    let deadline = Task { [socket] in
      try await Task.sleep(for: _drainTimeout)
      try? socket.shutdown()
    }
    await writer.value
    deadline.cancel()
  }

  /// The state machine, from the request on; ends at CLOSED.
  private func drive(_ events: AsyncStream<Event>, key: Int, _ outputs: Outputs) async {
    let start = ContinuousClock.now
    var currentTime: UInt64 { UInt64(max((ContinuousClock.now - start).components.seconds, 0)) }
    var iterator = events.makeAsyncIterator()
    // START_TRANSFER reports the link status, so learn it before answering the request
    var linkStatus = false
    var pending = [Event]()
    while let event = await iterator.next() {
      if case .apcClosed = event { return }
      if case let .link(isUp) = event {
        linkStatus = isUp
        break
      }
      pending.append(event)
    }
    var machine = AtdeccProxyServerStateMachine(linkMacAddress: port.macAddress, linkStatus: linkStatus) {
      [entityIDs] _, requested in entityIDs.assign(key, requested: requested)
    }
    var closeCode: UInt16? = 1000
    guard perform(machine.requestReceived(outcome.requestValid, at: currentTime), key: key, closeCode, outputs) else {
      return
    }
    for event in pending {
      guard perform(handle(event, &machine, &closeCode, at: currentTime), key: key, closeCode, outputs) else { return }
    }
    while let event = await iterator.next() {
      guard perform(handle(event, &machine, &closeCode, at: currentTime), key: key, closeCode, outputs) else { return }
    }
  }

  private func handle(
    _ event: Event,
    _ machine: inout AtdeccProxyServerStateMachine,
    _ closeCode: inout UInt16?,
    at currentTime: UInt64
  ) -> [AtdeccProxyServerStateMachine.Action] {
    switch event {
    case let .apc(appdu):
      let actions = machine.apcMessageReceived(appdu, at: currentTime)
      if appdu.messageType == .entityIDRequest, let id = machine.assignedEntityID {
        logger.debug("ATDECC proxy assigned entity ID \(id)")
      }
      return actions
    case let .apcClosed(code):
      closeCode = code
      return machine.close()
    case let .layer2(packet):
      entityIDs.observe(packet.payload)
      return machine.layer2FrameReceived(packet, at: currentTime)
    case let .link(isUp):
      return machine.linkStatusChanged(isUp, at: currentTime)
    case .tick:
      return machine.timeAdvanced(to: currentTime)
    }
  }

  /// Performs `actions`; false once the connection is to close. An APC whose messages back up
  /// is not reading them, and its connection is closed.
  private func perform(
    _ actions: [AtdeccProxyServerStateMachine.Action],
    key: Int,
    _ closeCode: UInt16?,
    _ outputs: Outputs
  ) -> Bool {
    for action in actions {
      switch action {
      case .sendHttpResponse:
        outputs.apc.yield(outcome.response)
      case let .sendToApc(appdu):
        if case .dropped = outputs.apc.yield(encode(appdu)) {
          logger.notice("ATDECC proxy closing a connection whose APC is not reading")
          return false
        }
      case let .sendToLayer2(packet):
        entityIDs.observe(packet.payload, sentBy: key)
        if case .dropped = outputs.layer2.yield(packet) {
          logger.trace("ATDECC proxy dropped a frame for the LAN")
        }
      case .closeConnection:
        if case .webSocket = transport, let closeCode {
          outputs.apc.yield(webSocketFrame(.close, [UInt8(closeCode >> 8), UInt8(closeCode & 0xFF)]))
        }
        return false
      }
    }
    return true
  }

  private func encode(_ appdu: Appdu) -> [UInt8] {
    switch transport {
    case .connect: appdu.serialized()
    case .webSocket: webSocketFrame(.binary, appdu.serialized())
    }
  }

  /// The one writer of the socket, so that what is sent is never interleaved. A write the APC
  /// does not read within `writeTimeout`, or that fails, ends the connection: reading it ends
  /// too.
  private func writeApc(_ output: AsyncStream<[UInt8]>) async {
    do {
      for await bytes in output {
        _ = try await socket.write(bytes, count: bytes.count, awaitingAllWritten: true, timeout: writeTimeout)
      }
    } catch {
      logger.debug("ATDECC proxy could not write to an APC: \(error)")
      try? socket.shutdown()
    }
  }

  /// Frames for the network port, sent in order; one that fails is dropped, as on a LAN.
  private func writeLayer2(_ output: AsyncStream<IEEE802Packet>) async {
    for await packet in output {
      do {
        try await port.send(packet)
      } catch {
        logger.debug("ATDECC proxy could not send a frame: \(error)")
      }
    }
  }

  // MARK: - Producers

  private func readApc(_ events: AsyncStream<Event>.Continuation, _ output: AsyncStream<[UInt8]>.Continuation) async {
    let closeCode = await readUntilClosed(events, output)
    // the end must not be lost to a full queue while the connection is still driven
    while case .dropped = events.yield(.apcClosed(closeCode: closeCode)) {
      await Task.yield()
    }
  }

  /// Reads the APC until its end closes; for a WebSocket, the close status to answer with.
  private func readUntilClosed(
    _ events: AsyncStream<Event>.Continuation,
    _ output: AsyncStream<[UInt8]>.Continuation
  ) async -> UInt16? {
    var reader = AppChannelReader(transport: transport)
    do {
      var bytes = leftover
      while !Task.isCancelled {
        for item in try reader.read(bytes) {
          switch item {
          case let .appdu(appdu): events.yield(.apc(appdu))
          case let .reply(frame): output.yield(frame)
          case .closed: return 1000
          }
        }
        bytes = try await socket.receive(count: 4096)
        guard !bytes.isEmpty else { return nil }
      }
    } catch let error as AppChannelReader.Error {
      logger.debug("ATDECC proxy closing a connection: \(error)")
      return error.webSocketCloseCode
    } catch {
      logger.debug("ATDECC proxy closing a connection: \(error)")
    }
    return nil
  }

  private func receiveLayer2(_ events: AsyncStream<Event>.Continuation) async {
    while !Task.isCancelled {
      do {
        try await port.receive { packet in events.yield(.layer2(packet)) }
      } catch {
        logger.trace("ATDECC proxy reception ended: \(error)")
      }
      // a port whose link is down fails until it comes up again
      try? await Task.sleep(for: .seconds(1))
    }
  }

  private func monitorLink(_ events: AsyncStream<Event>.Continuation) async {
    do {
      try await port.monitorLinkState { isUp in events.yield(.link(isUp)) }
    } catch {
      logger.warning("ATDECC proxy cannot follow the link state: \(error)")
      events.yield(.link(true))
    }
  }

  private func tick(_ events: AsyncStream<Event>.Continuation) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      events.yield(.tick)
    }
  }
}

#endif
