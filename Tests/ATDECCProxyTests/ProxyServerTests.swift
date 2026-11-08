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
import ATDECCProxy
import Glibc
import IEEE802
import IORing
import IORingUtils
import Logging
import SocketAddress
import Synchronization
import XCTest

private let timeout = Duration.seconds(5)

/// An APC over loopback TCP, speaking either CONNECT or WebSocket as the Noodles controller does.
private final class TestApc {
  let socket: Socket
  private var buffer = [UInt8]()
  private var appdus = AppduStreamDecoder()
  private var decoded = [Appdu]()
  private var frames = WebSocketFrameDecoder(requiresMask: false)
  private var messages = [WebSocketMessage]()
  private let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]

  init(port: UInt16) async throws {
    socket = try Socket(ring: .shared, domain: sa_family_t(AF_INET), type: SOCK_STREAM, protocol: 0)
    try await socket.connect(to: sockaddr_in(family: sa_family_t(AF_INET), presentationAddress: "127.0.0.1:\(port)"))
  }

  func send(_ bytes: [UInt8]) async throws {
    _ = try await socket.write(bytes, count: bytes.count, awaitingAllWritten: true)
  }

  func sendMessage(_ appdu: Appdu) async throws {
    try await send(webSocketFrame(.binary, appdu.serialized(), maskingKey: mask))
  }

  private func fill() async throws {
    let bytes = try await socket.receive(count: 4096, timeout: timeout)
    guard !bytes.isEmpty else { throw POSIXError(.ECONNRESET) }
    buffer += bytes
  }

  /// The response head, as text.
  func readHead() async throws -> String {
    while AppHTTPRequestHead.endOfHead(in: buffer) == nil {
      try await fill()
    }
    let end = AppHTTPRequestHead.endOfHead(in: buffer)!
    defer { buffer.removeFirst(end) }
    return String(decoding: buffer[..<end], as: UTF8.self)
  }

  /// The next APPDU of a CONNECT stream; several may arrive in one read.
  func readAppdu() async throws -> Appdu {
    decoded += try appdus.decode(buffer)
    buffer = []
    while decoded.isEmpty {
      try await fill()
      decoded += try appdus.decode(buffer)
      buffer = []
    }
    return decoded.removeFirst()
  }

  /// The next WebSocket message; each binary one must be exactly one APPDU.
  func readMessage() async throws -> WebSocketMessage {
    while messages.isEmpty {
      messages = try frames.decode(buffer)
      buffer = []
      if messages.isEmpty { try await fill() }
    }
    return messages.removeFirst()
  }

  func readMessageAppdu() async throws -> Appdu {
    guard case let .binary(payload) = try await readMessage() else { throw POSIXError(.EPROTO) }
    return try Appdu(bytes: payload)
  }

  /// Reads until the server closes the connection.
  func readToEnd() async throws -> [UInt8] {
    var all = buffer
    while true {
      let bytes = try await socket.receive(count: 4096, timeout: timeout)
      guard !bytes.isEmpty else { return all }
      all += bytes
    }
  }
}

final class ProxyServerTests: XCTestCase {
  private var network: VirtualNetwork!
  private var entityPort: VirtualPort!
  private var server: AtdeccProxyServer<VirtualPort>!
  private var serverTask: Task<(), any Error>!
  /// The ports the server's factory made, one per connection.
  private let connectionPorts = PortList()

  override func setUp() async throws {
    network = VirtualNetwork()
    entityPort = network.makePort(macAddress: entityMacAddress)
    try startServer(maximumConnections: 8)
  }

  override func tearDown() async throws {
    serverTask.cancel()
    _ = await serverTask.result
  }

  private func startServer(maximumConnections: Int) throws {
    let configuration = AtdeccProxyServerConfiguration(port: 0, maximumConnections: maximumConnections)
    let network = network!
    server = try AtdeccProxyServer(configuration: configuration, linkMacAddress: linkMacAddress, logger: Logger(label: "test")) {
      [connectionPorts] in
      let port = network.makePort(macAddress: linkMacAddress)
      connectionPorts.ports.withLock { $0.append(port) }
      return port
    }
    serverTask = Task { [server] in try await server!.run() }
  }

  /// A frame the entity sends, as on the LAN.
  private func entitySends(_ avtpdu: [UInt8], to destination: EUI48 = AvdeccMulticastMacAddress) async throws {
    try await entityPort.send(IEEE802Packet(
      destMacAddress: destination,
      tci: nil,
      sourceMacAddress: entityMacAddress,
      etherType: AvtpEtherType,
      payload: avtpdu
    ))
  }

  /// The next frame the entity receives.
  private func entityReceives() async throws -> IEEE802Packet {
    let (stream, continuation) = AsyncStream<IEEE802Packet>.makeStream()
    let task = Task { [entityPort] in
      try await entityPort!.receive { packet in continuation.yield(packet) }
    }
    defer { task.cancel() }
    let timer = Task {
      try await Task.sleep(for: timeout)
      continuation.finish()
    }
    defer { timer.cancel() }
    for await packet in stream {
      return packet
    }
    throw POSIXError(.ETIMEDOUT)
  }

  func testAConnectApcIsServedAsInAnnexC() async throws {
    let apc = try await TestApc(port: server.port)
    try await apc.send(appConnectRequest(host: "127.0.0.1", port: server.port).serialized())
    let head = try await apc.readHead()
    XCTAssertEqual(head, "HTTP/1.1 200 OK\r\n\r\n")

    let linkUp = try await apc.readAppdu()
    XCTAssertEqual(linkUp.messageType, .linkUp)
    XCTAssertEqual(macBytes(linkUp.address), macBytes(linkMacAddress))

    try await apc.send(Appdu.entityIDRequest(apcMacAddress: apcMacAddress, entityID: UniqueIdentifier()).serialized())
    let response = try await apc.readAppdu()
    XCTAssertEqual(response.messageType, .entityIDResponse)
    XCTAssertEqual(macBytes(response.address), macBytes(apcMacAddress))
    XCTAssertEqual(response.entityID!.rawValue >> 16, UInt64(eui48: linkMacAddress))

    try await entitySends(makeAvtpdu(padding: 2))
    let fromAps = try await apc.readAppdu()
    XCTAssertEqual(fromAps.messageType, .atdeccFromAps)
    XCTAssertEqual(macBytes(fromAps.address), macBytes(entityMacAddress))
    XCTAssertEqual(fromAps.payload, makeAvtpdu())

    let command = makeAvtpdu(subtype: AvtpSubtype.aecp.rawValue, controlDataLength: 20)
    try await apc.send(Appdu.atdeccFromApc(destinationMacAddress: entityMacAddress, avtpdu: command).serialized())
    let frame = try await entityReceives()
    XCTAssertEqual(macBytes(frame.destMacAddress), macBytes(entityMacAddress))
    XCTAssertEqual(macBytes(frame.sourceMacAddress), macBytes(linkMacAddress))
    XCTAssertEqual(frame.payload, command)
  }

  func testAppdusSentWithTheRequestAreNotLost() async throws {
    let apc = try await TestApc(port: server.port)
    let request = Appdu.entityIDRequest(apcMacAddress: apcMacAddress, entityID: UniqueIdentifier(0x42))
    try await apc.send(appConnectRequest(host: "127.0.0.1", port: server.port).serialized() + request.serialized())
    _ = try await apc.readHead()
    let awaited1 = try await apc.readAppdu().messageType
    XCTAssertEqual(awaited1, .linkUp)
    let response = try await apc.readAppdu()
    XCTAssertEqual(response.entityID, UniqueIdentifier(0x42))
  }

  func testAnApcPduOutsideTableC7ClosesTheConnection() async throws {
    let apc = try await TestApc(port: server.port)
    try await apc.send(appConnectRequest(host: "127.0.0.1", port: server.port).serialized())
    _ = try await apc.readHead()
    _ = try await apc.readAppdu()
    try await apc.send(Appdu.atdeccFromApc(destinationMacAddress: entityMacAddress, avtpdu: makeAvtpdu(subtype: 0x02)).serialized())
    let awaited2 = try await apc.readToEnd()
    XCTAssertEqual(awaited2, [])
  }

  /// The exchange of the Noodles controller: GET /ws from its origin, no subprotocol, one APPDU
  /// per binary message, ENTITY_ID_REQUEST first.
  func testTheNoodlesWebSocketExchangeWorks() async throws {
    let apc = try await TestApc(port: server.port)
    var upgrade = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    upgrade += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
    upgrade += "Origin: https://noodlescontroller.com\r\n\r\n"
    try await apc.send(Array(upgrade.utf8))
    let head = try await apc.readHead()
    XCTAssertTrue(head.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
    XCTAssertTrue(head.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))

    let awaited3 = try await apc.readMessageAppdu().messageType
    XCTAssertEqual(awaited3, .linkUp)
    try await apc.sendMessage(.entityIDRequest(apcMacAddress: apcMacAddress, entityID: UniqueIdentifier(0x0211_22FF_FE33_4455)))
    let response = try await apc.readMessageAppdu()
    XCTAssertEqual(response.entityID, UniqueIdentifier(0x0211_22FF_FE33_4455))

    try await entitySends(makeAvtpdu(subtype: AvtpSubtype.acmp.rawValue, controlDataLength: 44))
    let fromAps = try await apc.readMessageAppdu()
    XCTAssertEqual(fromAps.messageType, .atdeccFromAps)
    XCTAssertEqual(fromAps.payload.first, AvtpSubtype.acmp.rawValue)

    let command = makeAvtpdu(subtype: AvtpSubtype.aecp.rawValue, controlDataLength: 20)
    try await apc.sendMessage(.atdeccFromApc(destinationMacAddress: entityMacAddress, avtpdu: command))
    let awaited4 = try await entityReceives().payload
    XCTAssertEqual(awaited4, command)

    try await apc.send(webSocketFrame(.ping, [5], maskingKey: [1, 2, 3, 4]))
    let awaited5 = try await apc.readMessage()
    XCTAssertEqual(awaited5, .pong([5]))
    try await apc.send(webSocketFrame(.close, [0x03, 0xE8], maskingKey: [1, 2, 3, 4]))
    let awaited6 = try await apc.readMessage()
    XCTAssertEqual(awaited6, .close)
  }

  func testAWebSocketFromAForeignOriginIsRefused() async throws {
    let apc = try await TestApc(port: server.port)
    var upgrade = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    upgrade += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nOrigin: https://evil.example\r\n\r\n"
    try await apc.send(Array(upgrade.utf8))
    let awaited7 = try await apc.readHead().hasPrefix("HTTP/1.1 403 Forbidden\r\n")
    XCTAssertTrue(awaited7)
  }

  func testApcsBeyondTheLimitAreRefused() async throws {
    serverTask.cancel()
    _ = await serverTask.result
    try startServer(maximumConnections: 1)
    let first = try await TestApc(port: server.port)
    try await first.send(appConnectRequest(host: "127.0.0.1", port: server.port).serialized())
    let awaited8 = try await first.readHead()
    XCTAssertEqual(awaited8, "HTTP/1.1 200 OK\r\n\r\n")
    let second = try await TestApc(port: server.port)
    try await second.send(appConnectRequest(host: "127.0.0.1", port: server.port).serialized())
    let awaited9 = try await second.readHead().hasPrefix("HTTP/1.1 503 Service Unavailable\r\n")
    XCTAssertTrue(awaited9)
  }

  func testTwoApcsAreServedAtOnceWithDistinctEntityIDs() async throws {
    let requested = UniqueIdentifier(0x0211_22FF_FE33_4455)
    var ids = [UniqueIdentifier]()
    var apcs = [TestApc]()
    for _ in 0..<2 {
      let apc = try await TestApc(port: server.port)
      try await apc.send(appConnectRequest(host: "127.0.0.1", port: server.port).serialized())
      _ = try await apc.readHead()
      _ = try await apc.readAppdu()
      try await apc.send(Appdu.entityIDRequest(apcMacAddress: apcMacAddress, entityID: requested).serialized())
      ids.append(try await apc.readAppdu().entityID!)
      apcs.append(apc)
    }
    XCTAssertEqual(ids[0], requested)
    XCTAssertNotEqual(ids[1], requested)
    try await entitySends(makeAvtpdu())
    for apc in apcs {
      let awaited10 = try await apc.readAppdu().messageType
      XCTAssertEqual(awaited10, .atdeccFromAps)
    }
  }

  func testTheLinkGoingDownIsReported() async throws {
    let apc = try await TestApc(port: server.port)
    try await apc.send(appConnectRequest(host: "127.0.0.1", port: server.port).serialized())
    _ = try await apc.readHead()
    let awaited11 = try await apc.readAppdu().messageType
    XCTAssertEqual(awaited11, .linkUp)
    connectionPorts.ports.withLock { $0.last }?.setLinkUp(false)
    let linkDown = try await apc.readAppdu()
    XCTAssertEqual(linkDown.messageType, .linkDown)
  }
}

private final class PortList: Sendable {
  let ports = Mutex([VirtualPort]())
}

#endif
