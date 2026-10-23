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

@testable import ATDECC
import Glibc
import IEEE802
import Logging
import Synchronization
import XCTest
// Foundation, through XCTest, also has a FileHandle
import class IORing.FileHandle
import struct SystemPackage.Errno

private let datagramSocketType = CInt(SOCK_DGRAM.rawValue) | CInt(SOCK_CLOEXEC.rawValue)

/// An AF_UNIX datagram socket standing in for an entity: non-blocking, so that waiting for a
/// datagram polls rather than blocks a thread the port's tasks may need.
private final class FakeEntitySocket: Sendable {
  let fileDescriptor: CInt
  let path: String?

  /// One end of a connected pair; the other is returned for the port.
  static func pair() throws -> (entity: FakeEntitySocket, port: CInt) {
    var fileDescriptors: [CInt] = [-1, -1]
    guard socketpair(AF_UNIX, datagramSocketType, 0, &fileDescriptors) == 0 else {
      throw XCTSkip("socketpair failed: \(errno)")
    }
    return (FakeEntitySocket(fileDescriptor: fileDescriptors[0], path: nil), fileDescriptors[1])
  }

  /// A socket bound to `path`, which receives from any controller, as an entity does.
  convenience init(boundTo path: String) throws {
    unlink(path)
    let fileDescriptor = socket(AF_UNIX, datagramSocketType, 0)
    guard fileDescriptor >= 0 else { throw XCTSkip("socket failed: \(errno)") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else {
      Glibc.close(fileDescriptor)
      throw XCTSkip("cannot bind \(path): \(errno)")
    }
    self.init(fileDescriptor: fileDescriptor, path: path)
  }

  private init(fileDescriptor: CInt, path: String?) {
    self.fileDescriptor = fileDescriptor
    self.path = path
    _ = fcntl(fileDescriptor, F_SETFL, fcntl(fileDescriptor, F_GETFL) | O_NONBLOCK)
  }

  func close() {
    Glibc.close(fileDescriptor)
    if let path { unlink(path) }
  }

  /// The next datagram and the address it came from, or nil if none arrives within `timeout`.
  func receive(within timeout: Duration = .seconds(2)) async -> (bytes: [UInt8], from: [UInt8])? {
    let deadline = ContinuousClock.now + timeout
    var buffer = [UInt8](repeating: 0, count: 2048)
    repeat {
      var address = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let count = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          recvfrom(fileDescriptor, &buffer, buffer.count, 0, $0, &length)
        }
      }
      if count >= 0 {
        let from = withUnsafeBytes(of: &address) { Array($0.prefix(Int(length))) }
        return (Array(buffer.prefix(count)), from)
      }
      try? await Task.sleep(for: .milliseconds(2))
    } while ContinuousClock.now < deadline && !Task.isCancelled
    return nil
  }

  /// Sends a datagram to the connected peer, or to `address` as returned by `receive`.
  @discardableResult
  func send(_ bytes: [UInt8], to address: [UInt8]? = nil) -> Int {
    guard let address else { return Glibc.send(fileDescriptor, bytes, bytes.count, 0) }
    return address.withUnsafeBytes { address in
      sendto(
        fileDescriptor,
        bytes,
        bytes.count,
        0,
        address.baseAddress!.assumingMemoryBound(to: sockaddr.self),
        socklen_t(address.count)
      )
    }
  }
}

/// The first value of `stream` within `timeout`.
private func firstValue<T: Sendable>(
  of stream: AsyncStream<T>,
  within timeout: Duration = .seconds(2),
  where predicate: @escaping @Sendable (T) -> Bool = { _ in true }
) async -> T? {
  await withTaskGroup(of: T?.self) { group in
    group.addTask {
      for await value in stream where predicate(value) {
        return value
      }
      return nil
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return nil
    }
    let value = await group.next() ?? nil
    group.cancelAll()
    return value
  }
}

/// Receives on `port` into a stream, until the returned task is cancelled.
private func receiving(
  on port: UnixSocketPort
) -> (AsyncStream<IEEE802Packet>, Task<(), any Error>) {
  let (stream, continuation) = AsyncStream<IEEE802Packet>.makeStream()
  let task = Task {
    defer { continuation.finish() }
    try await port.receive { continuation.yield($0) }
  }
  return (stream, task)
}

private let socketPathCounter = Atomic(0)

/// A path for a socket that is short enough for sun_path.
private func temporarySocketPath() -> String {
  let index = socketPathCounter.add(1, ordering: .relaxed).newValue
  return "/tmp/atdecc-test-\(getpid())-\(index).sock"
}

final class UnixSocketPortTests: XCTestCase {
  private let entityID = UniqueIdentifier(0x0AE9_1BFF_FEFF_FFFF)

  private var entityDiscover: [UInt8] {
    get throws {
      try AvdeccPdu.adp(Adpdu(messageType: .entityDiscover, entityID: UniqueIdentifier(0)))
        .serialized()
    }
  }

  private var entityAvailable: [UInt8] {
    get throws {
      try AvdeccPdu.adp(Adpdu(
        messageType: .entityAvailable,
        validTime: 10,
        entityID: entityID,
        entityCapabilities: .aemSupported
      )).serialized()
    }
  }

  private var aemCommand: [UInt8] {
    get throws {
      try AvdeccPdu.aecp(.aem(AemAecpdu(
        isResponse: false,
        targetEntityID: entityID,
        controllerEntityID: UniqueIdentifier(1),
        commandType: .readDescriptor,
        commandSpecificData: [0, 0, 0, 0, 0, 0, 0, 0]
      ))).serialized()
    }
  }

  private func packet(_ payload: [UInt8]) -> IEEE802Packet {
    IEEE802Packet(
      destMacAddress: AvdeccMulticastMacAddress,
      tci: nil,
      sourceMacAddress: UnixSocketPortLocalMacAddress,
      etherType: AvtpEtherType,
      payload: payload
    )
  }

  func testSendsOneBareAvtpduPerDatagram() async throws {
    let (entity, portSocket) = try FakeEntitySocket.pair()
    defer { entity.close() }
    let port = try UnixSocketPort(fileDescriptor: portSocket)
    defer { port.close() }
    let discover = try entityDiscover
    let command = try aemCommand

    // bytes after control_data_length, such as Ethernet padding, are not sent
    try await port.send(packet(discover + [UInt8](repeating: 0, count: 8)))
    try await port.send(packet(command))

    let first = await entity.receive()
    XCTAssertEqual(first?.bytes, discover)
    let second = await entity.receive()
    XCTAssertEqual(second?.bytes, command)
  }

  func testReceivesDatagramsFromThePeer() async throws {
    let (entity, portSocket) = try FakeEntitySocket.pair()
    defer { entity.close() }
    let port = try UnixSocketPort(fileDescriptor: portSocket)
    defer { port.close() }
    let (packets, task) = receiving(on: port)
    defer { task.cancel() }

    let available = try entityAvailable
    var response = try aemCommand
    response[1] |= 0x01 // AEM_RESPONSE
    // discarded: too short for a control header, empty, and longer than an AVTPDU can be
    entity.send([0x42, 0x42])
    entity.send([])
    entity.send(available + [UInt8](repeating: 0x55, count: 1500 - available.count + 1))
    entity.send(available)
    entity.send(response)

    var iterator = packets.makeAsyncIterator()
    let multicast = await iterator.next()
    XCTAssertEqual(multicast?.payload, available)
    XCTAssertEqual(multicast?.etherType, AvtpEtherType)
    XCTAssertEqual(multicast.map { _macAddressToString($0.sourceMacAddress) }, "0a:e9:1b:ff:ff:ff")
    XCTAssertEqual(
      multicast.map { _macAddressToString($0.destMacAddress) },
      _macAddressToString(AvdeccMulticastMacAddress)
    )
    let unicast = await iterator.next()
    XCTAssertEqual(unicast?.payload, response)
    XCTAssertEqual(unicast.map { _macAddressToString($0.sourceMacAddress) }, "0a:e9:1b:ff:ff:ff")
    XCTAssertEqual(unicast.map { _macAddressToString($0.destMacAddress) }, "0a:e9:1b:01:01:01")
  }

  func testCloseEndsReceptionAndSends() async throws {
    let (entity, portSocket) = try FakeEntitySocket.pair()
    defer { entity.close() }
    let port = try UnixSocketPort(fileDescriptor: portSocket)
    let (_, task) = receiving(on: port)
    try? await Task.sleep(for: .milliseconds(20))

    port.close()
    let result = await firstValue(of: AsyncStream { continuation in
      Task {
        continuation.yield(await task.result)
        continuation.finish()
      }
    })
    guard case let .failure(error)? = result else {
      return XCTFail("closing the port should end reception, got \(String(describing: result))")
    }
    XCTAssertEqual(error as? Errno, Errno(rawValue: EBADF))
    do {
      try await port.send(packet(entityDiscover))
      XCTFail("a closed port should not send")
    } catch {}
  }

  func testRejectsAStreamSocket() throws {
    var fileDescriptors: [CInt] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, CInt(SOCK_STREAM.rawValue), 0, &fileDescriptors), 0)
    defer { close(fileDescriptors[1]) }
    // the port closes the descriptor it rejects
    XCTAssertThrowsError(try UnixSocketPort(fileDescriptor: fileDescriptors[0]))
  }

  func testRejectsAPathTooLong() {
    XCTAssertThrowsError(try UnixSocketPort(path: "/" + String(repeating: "x", count: 200)))
  }

  /// The port binds an address, so that an entity that receives with recvfrom can reply with
  /// sendto.
  func testEntityRepliesToTheAddressADatagramCameFrom() async throws {
    let path = temporarySocketPath()
    let entity = try FakeEntitySocket(boundTo: path)
    defer { entity.close() }
    let port = try UnixSocketPort(path: path)
    defer { port.close() }
    let (packets, task) = receiving(on: port)
    defer { task.cancel() }

    try await port.send(packet(entityDiscover))
    let firstDiscover = await entity.receive()
    let discover = try XCTUnwrap(firstDiscover)
    XCTAssertEqual(discover.bytes, try entityDiscover)
    // an autobound abstract address: sun_family, then a zero and five hex digits
    XCTAssertGreaterThan(discover.from.count, MemoryLayout<sa_family_t>.size)

    let available = try entityAvailable
    XCTAssertEqual(entity.send(available, to: discover.from), available.count)
    let received = await firstValue(of: packets)
    XCTAssertEqual(received?.payload, available)
  }

  func testSendsReachAnEntityThatStartsLater() async throws {
    let path = temporarySocketPath()
    unlink(path)
    let port = try UnixSocketPort(path: path)
    defer { port.close() }
    do {
      try await port.send(packet(entityDiscover))
      XCTFail("a send with no entity should fail")
    } catch let error as Errno {
      XCTAssertEqual(error, .noSuchFileOrDirectory)
    }

    let entity = try FakeEntitySocket(boundTo: path)
    defer { entity.close() }
    try await port.send(packet(entityDiscover))
    let received = await entity.receive()
    XCTAssertEqual(received?.bytes, try entityDiscover)
  }

  func testSendsReachARestartedEntity() async throws {
    let path = temporarySocketPath()
    let entity = try FakeEntitySocket(boundTo: path)
    let port = try UnixSocketPort(path: path)
    defer { port.close() }
    let (packets, task) = receiving(on: port)
    defer { task.cancel() }
    try await port.send(packet(entityDiscover))
    let first = await entity.receive()
    XCTAssertNotNil(first)

    // the entity goes away; sends fail until it is back
    entity.close()
    do {
      try await port.send(packet(entityDiscover))
      XCTFail("a send with no entity should fail")
    } catch let error as Errno {
      XCTAssertTrue(
        error == .connectionRefused || error == .noSuchFileOrDirectory,
        "unexpected \(error)"
      )
    }

    let restarted = try FakeEntitySocket(boundTo: path)
    defer { restarted.close() }
    try await port.send(packet(entityDiscover))
    let restartedDiscover = await restarted.receive()
    let discover = try XCTUnwrap(restartedDiscover)
    // and the restarted entity's replies are received
    let available = try entityAvailable
    XCTAssertEqual(restarted.send(available, to: discover.from), available.count)
    let received = await firstValue(of: packets)
    XCTAssertEqual(received?.payload, available)
  }

  func testControllerDiscoversAnEntityOverTheSocket() async throws {
    let path = temporarySocketPath()
    let entity = try FakeEntitySocket(boundTo: path)
    defer { entity.close() }
    let entityID = entityID
    let available = try entityAvailable

    // the entity answers ENTITY_DISCOVER with ENTITY_AVAILABLE, to whichever controller asked
    let responder = Task {
      while !Task.isCancelled {
        guard let (bytes, from) = await entity.receive(within: .milliseconds(100)) else { continue }
        guard case let .adp(adpdu)? = try? bytes.withParserSpan({ try AvdeccPdu(parsing: &$0) }),
              adpdu.messageType == .entityDiscover
        else { continue }
        entity.send(available, to: from)
      }
    }

    let port = try UnixSocketPort(path: path)
    let endStation = EndStation(port: port, logger: Logger(label: "UnixSocketPortTests"))
    let controller = try await Controller(
      endStation: endStation,
      entityID: endStation.makeDynamicEntityID()
    )
    let online = await firstValue(of: await controller.events()) {
      if case .entityOnline(entityID) = $0 { true } else { false }
    }
    XCTAssertNotNil(online, "entity not discovered over the socket")
    let discovered = await controller.discoveredEntity(id: entityID)
    XCTAssertEqual(
      discovered?.macAddress.map { _macAddressToString($0) },
      _macAddressToString(UnixSocketPortPeerMacAddress)
    )

    await endStation.close()
    // the entity's socket is closed only once the responder no longer reads it
    responder.cancel()
    await responder.value
  }
}

#endif
