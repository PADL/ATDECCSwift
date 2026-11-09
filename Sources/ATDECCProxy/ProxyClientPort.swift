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

#if canImport(Network)

import ATDECC
import Foundation
import IEEE802
import Network
import Synchronization

/// Why an APC could not use an APS.
public enum AtdeccProxyClientError: Error, Equatable, Sendable {
  /// The APS refused CONNECT with this status, and a WebSocket too if it was tried.
  case refused(Int)
  /// The APS closed the connection, or sent something that is not APP.
  case connectionClosed
  /// The APS refused or ignored ENTITY_ID_REQUEST (Clause C.5.2.2.5).
  case noEntityID
  /// Nothing is connected to send on.
  case notConnected
}

/// A network port that reaches the LAN through an ATDECC Proxy Server (IEEE 1722.1-2021
/// Annex C), as an APC: for a controller with no layer 2 access of its own, such as one on
/// another network or on iOS.
///
/// It speaks CONNECT, as Annex C has it, or a WebSocket on `AppWebSocketPath`, which is all this
/// package's APS speaks without its HTTPTunnel trait. DNS-SD doesn't say which an APS takes, so
/// unless told, it tries CONNECT, and a WebSocket if the APS refuses it.
///
/// The connection made by `init` is the first `receive(onReady:_:)`'s; each later one connects
/// afresh, so the end station's retries reconnect to an APS that went away. The APS assigns
/// the controller's entity ID, and is asked for the same one again on each reconnection.
public final class AtdeccProxyClientPort: NetworkPort {
  /// The APS's network port (linkMac, Clause C.5.2.1.15), which frames to the LAN come from, if
  /// the APS reports its link status; zeros if it doesn't, as some don't.
  public let macAddress: EUI48
  /// The entity ID the APS assigned, for this port's controller.
  public let entityID: UniqueIdentifier

  private let endpoint: Endpoint
  private let state: Mutex<State>

  private struct Endpoint {
    let host: String
    let port: UInt16
    let path: String

    /// host:port, with an IPv6 literal in brackets.
    var authority: String {
      host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
  }

  private struct State {
    /// The connection `init` made, waiting for the first receive.
    var pending: Link?
    /// The connection being received from, which sends go out on.
    var current: Link?
    /// How the APS is reached; nil until it's found.
    var transport: AppTransport?
  }

  /// Connects to the APS at `host` and `port` by `transport`, or whichever it takes if nil, and
  /// has it assign an entity ID. `path` is what CONNECT asks for, the TXT record's path (Clause
  /// C.3.5) if DNS-SD found it.
  public init(
    host: String,
    port: UInt16 = AppDefaultPort,
    path: String = "/",
    transport: AppTransport? = nil
  ) async throws {
    endpoint = Endpoint(host: host, port: port, path: path)
    let (link, transport) = try await Self.connect(to: endpoint, by: transport)
    do {
      (entityID, macAddress) = try await link.requestEntityID(UniqueIdentifier(0))
    } catch {
      link.cancel()
      throw error
    }
    state = Mutex(State(pending: link, current: nil, transport: transport))
  }

  deinit {
    state.withLock {
      $0.pending?.cancel()
      $0.current?.cancel()
    }
  }

  public func send(_ packet: IEEE802Packet) async throws {
    guard let link = state.withLock({ $0.current }) else {
      throw AtdeccProxyClientError.notConnected
    }
    try await link.send(.atdeccFromApc(destinationMacAddress: packet.destMacAddress, avtpdu: packet.payload))
  }

  public func receive(_ handler: (IEEE802Packet) async -> ()) async throws {
    try await receive(onReady: {}, handler)
  }

  public func receive(
    onReady: () async -> (),
    _ handler: (IEEE802Packet) async -> ()
  ) async throws {
    let link = try await nextLink()
    state.withLock { $0.current = link }
    defer {
      state.withLock { if $0.current === link { $0.current = nil } }
      link.cancel()
    }
    try await withTaskCancellationHandler {
      await onReady()
      while true {
        let appdu = try await link.receive()
        // NOPs only keep the connection alive, and link status is the APS's to report
        guard appdu.messageType == .atdeccFromAps else { continue }
        await handler(IEEE802Packet(
          destMacAddress: macAddress,
          tci: nil,
          sourceMacAddress: appdu.address,
          etherType: AvtpEtherType,
          payload: appdu.payload
        ))
      }
    } onCancel: {
      link.cancel()
    }
  }

  /// The connection `init` made, or a new one that has asked for this port's entity ID again.
  private func nextLink() async throws -> Link {
    let (pending, transport) = state.withLock { state in
      defer { state.pending = nil }
      return (state.pending, state.transport)
    }
    if let pending { return pending }
    let (link, _) = try await Self.connect(to: endpoint, by: transport)
    do {
      // another APC may hold the ID by now, and the controller can't take another
      guard try await link.requestEntityID(entityID).0 == entityID else {
        throw AtdeccProxyClientError.noEntityID
      }
    } catch {
      link.cancel()
      throw error
    }
    return link
  }

  /// A connection by `transport`, ready for APPDUs, and the transport. With none, CONNECT is
  /// tried, then a WebSocket if the APS refuses it.
  private static func connect(to endpoint: Endpoint, by transport: AppTransport?) async throws -> (Link, AppTransport) {
    if transport == .webSocket { return try await (connectByWebSocket(to: endpoint), .webSocket) }
    let link = Link(connection: NWConnection(
      host: NWEndpoint.Host(endpoint.host),
      port: NWEndpoint.Port(rawValue: endpoint.port) ?? .any,
      using: tcpParameters
    ), isWebSocket: false)
    let status: Int
    do {
      status = try await link.connect(path: endpoint.path, authority: endpoint.authority)
    } catch {
      link.cancel()
      throw error
    }
    if status == 200 { return (link, .connect) }
    link.cancel()
    guard transport == nil else { throw AtdeccProxyClientError.refused(status) }
    do {
      return try await (connectByWebSocket(to: endpoint), .webSocket)
    } catch {
      // a refused upgrade says less than a refused CONNECT does
      throw AtdeccProxyClientError.refused(status)
    }
  }

  private static func connectByWebSocket(to endpoint: Endpoint) async throws -> Link {
    var components = URLComponents()
    components.scheme = "ws"
    components.host = endpoint.host
    components.port = Int(endpoint.port)
    components.path = AppWebSocketPath
    guard let url = components.url else { throw AtdeccProxyClientError.connectionClosed }
    let parameters = tcpParameters
    let webSocket = NWProtocolWebSocket.Options()
    webSocket.autoReplyPing = true
    webSocket.maximumMessageSize = AppWebSocketMaximumMessageLength
    parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
    let link = Link(connection: NWConnection(to: .url(url), using: parameters), isWebSocket: true)
    do {
      try await link.start()
    } catch {
      link.cancel()
      throw error
    }
    return link
  }

  /// TCP with keepalives: an APS sends a NOP to an idle APC every ten seconds (Figure C.2),
  /// but one that has gone silently says nothing at all. A connection that isn't made in a few
  /// seconds fails, as one now and then sits preparing, and the end station's retry makes another.
  private static var tcpParameters: NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.connectionTimeout = 5
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 10
    tcp.keepaliveInterval = 5
    tcp.keepaliveCount = 3
    return NWParameters(tls: nil, tcp: tcp)
  }
}

/// One connection to an APS, carrying APPDUs as a byte stream after CONNECT, or one per binary
/// WebSocket message.
private final class Link: Sendable {
  private let connection: NWConnection
  private let isWebSocket: Bool
  private let queue = DispatchQueue(label: "com.padl.ATDECCProxy.Link")
  private let reception = Mutex(Reception())

  private struct Reception {
    var decoder = AppduStreamDecoder()
    var received = [Appdu]()
    /// Octets after the CONNECT response's header, which begin the APPDU stream.
    var header = [UInt8]()
  }

  init(connection: NWConnection, isWebSocket: Bool) {
    self.connection = connection
    self.isWebSocket = isWebSocket
  }

  func cancel() {
    connection.cancel()
  }

  /// Waits for the connection to be ready.
  func start() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(), any Error>) in
      let pending = Mutex<CheckedContinuation<(), any Error>?>(continuation)
      connection.stateUpdateHandler = { state in
        let result: Result<(), any Error>
        switch state {
        case .ready: result = .success(())
        // waiting is how Network says the APS can't be reached yet; the end station retries
        case let .waiting(error), let .failed(error): result = .failure(error)
        case .cancelled: result = .failure(AtdeccProxyClientError.connectionClosed)
        default: return
        }
        pending.withLock { pending in
          defer { pending = nil }
          return pending
        }?.resume(with: result)
      }
      connection.start(queue: queue)
    }
  }

  /// Starts the connection and sends CONNECT (Clause C.1), returning the status of the reply.
  func connect(path: String, authority: String) async throws -> Int {
    try await start()
    try await sendBytes(Array("CONNECT \(path) HTTP/1.1\r\nHost: \(authority)\r\n\r\n".utf8))
    var response = [UInt8]()
    let terminator: [UInt8] = Array("\r\n\r\n".utf8)
    while true {
      response += try await receiveBytes()
      guard let end = response.firstRange(of: terminator) else {
        guard response.count < 8192 else { throw AtdeccProxyClientError.connectionClosed }
        continue
      }
      reception.withLock { $0.header = Array(response[end.upperBound...]) }
      let statusLine = String(decoding: response[..<end.lowerBound], as: UTF8.self)
        .split(separator: "\r\n").first ?? ""
      let fields = statusLine.split(separator: " ")
      guard fields.count >= 2, fields[0].hasPrefix("HTTP/"), let status = Int(fields[1]) else {
        throw AtdeccProxyClientError.connectionClosed
      }
      return status
    }
  }

  /// Asks for `requested`, or zero for any, and returns what the APS assigns (Clause C.5.1.2),
  /// with the linkMac of any link status it reported first. What arrives meanwhile is kept for
  /// `receive()`.
  func requestEntityID(_ requested: UniqueIdentifier) async throws -> (UniqueIdentifier, EUI48) {
    // an APC without a MAC address of its own gives zero, as a browser APC does
    try await send(.entityIDRequest(apcMacAddress: [0, 0, 0, 0, 0, 0], entityID: requested))
    var kept = [Appdu]()
    var linkMacAddress: EUI48 = [0, 0, 0, 0, 0, 0]
    defer { reception.withLock { $0.received.insert(contentsOf: kept, at: 0) } }
    while true {
      let appdu = try await receiveAppdu()
      switch appdu.messageType {
      case .entityIDResponse:
        guard let entityID = appdu.entityID else { throw AtdeccProxyClientError.noEntityID }
        return (entityID, linkMacAddress)
      case .linkUp, .linkDown:
        linkMacAddress = appdu.address
      default:
        kept.append(appdu)
      }
    }
  }

  /// The next APPDU from the APS.
  func receive() async throws -> Appdu {
    try await receiveAppdu()
  }

  func send(_ appdu: Appdu) async throws {
    if isWebSocket {
      let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
      let context = NWConnection.ContentContext(identifier: "APPDU", metadata: [metadata])
      try await sendBytes(appdu.serialized(), context: context)
    } else {
      try await sendBytes(appdu.serialized())
    }
  }

  private func receiveAppdu() async throws -> Appdu {
    while true {
      let next: Appdu? = try reception.withLock {
        if !$0.received.isEmpty { return $0.received.removeFirst() }
        guard !$0.header.isEmpty else { return nil }
        $0.received = try $0.decoder.decode($0.header)
        $0.header = []
        return $0.received.isEmpty ? nil : $0.received.removeFirst()
      }
      if let next { return next }
      let bytes = try await receiveBytes()
      if isWebSocket {
        do {
          return try Appdu(bytes: bytes)
        } catch {
          throw AtdeccProxyClientError.connectionClosed
        }
      }
      try reception.withLock {
        $0.received = try $0.decoder.decode(bytes)
      }
    }
  }

  private func sendBytes(_ bytes: [UInt8], context: NWConnection.ContentContext = .defaultMessage) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(), any Error>) in
      connection.send(content: Data(bytes), contentContext: context, isComplete: true, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }

  /// The next bytes received: a WebSocket message whole, or what the stream has.
  private func receiveBytes() async throws -> [UInt8] {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], any Error>) in
      let completion: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> () = { data, _, isComplete, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, !data.isEmpty {
          continuation.resume(returning: Array(data))
        } else if isComplete {
          continuation.resume(throwing: AtdeccProxyClientError.connectionClosed)
        } else {
          continuation.resume(returning: [])
        }
      }
      if isWebSocket {
        connection.receiveMessage(completion: completion)
      } else {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: completion)
      }
    }
  }
}

#endif
