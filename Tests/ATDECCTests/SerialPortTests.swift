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

@testable import ATDECC
import IEEE802
import Synchronization
import XCTest
#if os(Linux)
import Glibc
import IORing
// Foundation, through XCTest, also has a FileHandle
import class IORing.FileHandle
#endif

final class CobsTests: XCTestCase {
  // Examples from the COBS paper and its common test vectors.
  func testEncodingVectors() {
    XCTAssertEqual(Cobs.encode([]), [0x01])
    XCTAssertEqual(Cobs.encode([0x00]), [0x01, 0x01])
    XCTAssertEqual(Cobs.encode([0x00, 0x00]), [0x01, 0x01, 0x01])
    XCTAssertEqual(Cobs.encode([0x11, 0x22, 0x00, 0x33]), [0x03, 0x11, 0x22, 0x02, 0x33])
    XCTAssertEqual(Cobs.encode([0x11, 0x22, 0x33, 0x44]), [0x05, 0x11, 0x22, 0x33, 0x44])
    XCTAssertEqual(Cobs.encode([0x11, 0x00, 0x00, 0x00]), [0x02, 0x11, 0x01, 0x01, 0x01])

    // a maximal block at the end of the frame is not followed by another code byte
    let nonZero254 = (1...254).map { UInt8($0) }
    XCTAssertEqual(Cobs.encode(nonZero254), [0xFF] + nonZero254)
    XCTAssertEqual(Cobs.encode([0x00] + nonZero254), [0x01, 0xFF] + nonZero254)
    let nonZero255 = (1...255).map { UInt8($0) }
    XCTAssertEqual(Cobs.encode(nonZero255), [0xFF] + nonZero254 + [0x02, 0xFF])
  }

  func testRoundTrip() {
    var generator = SystemRandomNumberGenerator()
    for length in [0, 1, 2, 253, 254, 255, 256, 508, 509, 1500] {
      for _ in 0..<20 {
        let bytes = (0..<length).map { _ in
          // make zeros common enough to exercise both block kinds
          Bool.random(using: &generator) ? 0 : UInt8.random(in: 0...255, using: &generator)
        }
        let encoded = Cobs.encode(bytes)
        XCTAssertFalse(encoded.contains(0))
        XCTAssertLessThanOrEqual(encoded.count, Cobs.maximumEncodedLength(length))
        XCTAssertEqual(Cobs.decode(encoded[...]), bytes)
      }
    }
  }

  func testMalformedFramesAreRejected() {
    XCTAssertNil(Cobs.decode([0x03, 0x11][...])) // block runs past the end
    XCTAssertNil(Cobs.decode([0x02, 0x00][...])) // zero inside a block
  }

  func testDecoderRecoversFromStartingMidFrame() {
    var decoder = CobsFrameDecoder(maximumFrameLength: 1500)
    let first = [UInt8](repeating: 0xAA, count: 20)
    let second: [UInt8] = [0x01, 0x00, 0x02]

    // the tail of a frame, its delimiter, then two whole delimited frames
    var stream = Array(Cobs.encode(first).suffix(5)) + [0]
    stream += [0] + Cobs.encode(first) + [0]
    stream += [0] + Cobs.encode(second) + [0]

    XCTAssertEqual(decoder.decode(stream), [first, second])
  }

  func testDecoderReassemblesAcrossReads() {
    var decoder = CobsFrameDecoder(maximumFrameLength: 1500)
    let frame = (0..<600).map { UInt8($0 % 7) }
    let stream = [0] + Cobs.encode(frame) + [0]

    var frames = [[UInt8]]()
    var index = 0
    while index < stream.count {
      let end = min(index + 37, stream.count)
      frames += decoder.decode(stream[index..<end])
      index = end
    }
    XCTAssertEqual(frames, [frame])
  }

  func testDecoderDiscardsOversizedFrames() {
    var decoder = CobsFrameDecoder(maximumFrameLength: 8)
    let oversized = [UInt8](repeating: 0x55, count: 64)
    let small: [UInt8] = [1, 2, 3]
    let stream = [0] + Cobs.encode(oversized) + [0] + Cobs.encode(small) + [0]

    XCTAssertEqual(decoder.decode(stream), [small])
  }
}

#if os(Linux)

// <asm-generic/ioctls.h>; function-like macros are not imported into Swift
private let TIOCGPTN: UInt = 0x8004_5430
private let TIOCSPTLCK: UInt = 0x4004_5431

/// A new pseudo-terminal: its controller end, and the path of its device end.
private func openPseudoTerminal() throws -> (controller: FileHandle, devicePath: String) {
  let fileDescriptor = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
  guard fileDescriptor >= 0 else { throw XCTSkip("pseudo-terminals are unavailable") }
  let controller = try FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
  var unlock: CInt = 0
  var terminalNumber: CInt = 0
  guard ioctl(fileDescriptor, TIOCSPTLCK, &unlock) == 0,
        ioctl(fileDescriptor, TIOCGPTN, &terminalNumber) == 0
  else {
    throw XCTSkip("pseudo-terminals are unavailable")
  }
  return (controller, "/dev/pts/\(terminalNumber)")
}

/// Whether a task has completed, polled so that waiting does not depend on the task, or the
/// ring it may be waiting on, making progress.
private final class Completion<Success: Sendable>: Sendable {
  private let _result = Mutex<Result<Success, any Error>?>(nil)

  init(of task: Task<Success, any Error>) {
    Task {
      let result = await task.result
      self._result.withLock { $0 = result }
    }
  }

  /// The task's result, or nil if it does not complete within `timeout`.
  func result(within timeout: Duration) async -> Result<Success, any Error>? {
    let deadline = ContinuousClock.now + timeout
    repeat {
      if let result = _result.withLock({ $0 }) {
        return result
      }
      try? await Task.sleep(for: .milliseconds(5))
    } while ContinuousClock.now < deadline
    return nil
  }
}

// A send taking this long has stalled: an unblocked write to a terminal takes microseconds.
private let stalledSendTimeout = Duration.milliseconds(250)
// Far more frames than a terminal's buffers hold.
private let maximumFramesToStall = 1000
// The most an AECPDU can carry (524-octet control data, IEEE 1722.1-2021 §9.2.2.6), so that
// a hundred or so frames fill a terminal's buffers.
private let largeCommandSpecificDataLength = 512

final class SerialPortTests: XCTestCase {
  // An ENTITY_DISCOVER for all entities (entity_id 0, §6.2.6.3), as serialized by the codec.
  private var entityDiscover: [UInt8] {
    get throws {
      try AvdeccPdu.adp(Adpdu(messageType: .entityDiscover, entityID: UniqueIdentifier(0)))
        .serialized()
    }
  }

  private var controller: FileHandle!
  private var devicePath: String!

  override func setUpWithError() throws {
    (controller, devicePath) = try openPseudoTerminal()
  }

  /// Sends frames, which the controller end never reads, until a send does not complete
  /// because the terminal's buffers are full, and returns that send.
  private func fillUntilSendStalls(_ port: SerialPort) async throws -> Task<(), any Error> {
    let pdu = try AvdeccPdu.aecp(.aem(AemAecpdu(
      isResponse: false,
      targetEntityID: UniqueIdentifier(0),
      controllerEntityID: UniqueIdentifier(0),
      commandType: .readDescriptor,
      commandSpecificData: [UInt8](repeating: 0x55, count: largeCommandSpecificDataLength)
    ))).serialized()
    let packet = IEEE802Packet(
      destMacAddress: AvdeccMulticastMacAddress,
      tci: nil,
      sourceMacAddress: port.macAddress,
      etherType: AvtpEtherType,
      payload: pdu
    )
    for _ in 0..<maximumFramesToStall {
      let send = Task { try await port.send(packet) }
      guard await Completion(of: send).result(within: stalledSendTimeout) != nil else {
        return send
      }
    }
    throw XCTSkip("sends to the pseudo-terminal never stalled")
  }

  /// Reads whatever the controller end holds, without the ring, so that a write stalled on it
  /// can finish even if the ring's thread is blocked in it.
  private func drainController(until send: Task<(), any Error>) async {
    let fileDescriptor = controller.fileDescriptor
    _ = fcntl(fileDescriptor, F_SETFL, fcntl(fileDescriptor, F_GETFL) | O_NONBLOCK)
    let completion = Completion(of: send)
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = ContinuousClock.now + .seconds(2)
    repeat {
      while read(fileDescriptor, &buffer, buffer.count) > 0 {}
    } while await completion.result(within: .milliseconds(10)) == nil && ContinuousClock.now < deadline
  }

  func testSendEncodesAvtpduWithoutPadding() async throws {
    let port = try SerialPort(path: devicePath)
    defer { port.close() }
    let pdu = try entityDiscover

    // bytes after control_data_length, such as Ethernet padding, are not sent
    try await port.send(IEEE802Packet(
      destMacAddress: AvdeccMulticastMacAddress,
      tci: nil,
      sourceMacAddress: port.macAddress,
      etherType: AvtpEtherType,
      payload: pdu + [UInt8](repeating: 0, count: 8)
    ))

    let expected = [0] + Cobs.encode(pdu) + [0]
    var received = [UInt8]()
    while received.count < expected.count {
      received += try await IORing.shared.read(count: expected.count, from: controller)
    }
    XCTAssertEqual(received, expected)
  }

  func testReceiveDecodesFrames() async throws {
    let port = try SerialPort(path: devicePath)
    defer { port.close() }
    let pdu = try entityDiscover

    let receiveTask = Task { () -> IEEE802Packet? in
      var packet: IEEE802Packet?
      let (stream, continuation) = AsyncStream<IEEE802Packet>.makeStream()
      let task = Task {
        // a reception that fails ends the wait, rather than leaving it for ever
        defer { continuation.finish() }
        try await port.receive { continuation.yield($0) }
      }
      for await received in stream {
        packet = received
        break
      }
      task.cancel()
      return packet
    }

    // a partial frame first, as if the port had opened part-way through a transmission
    let stream = [0x42, 0x42, 0] + Cobs.encode(pdu) + [0]
    _ = try await IORing.shared.write(stream, to: controller)

    let received = await receiveTask.value
    let packet = try XCTUnwrap(received)
    XCTAssertEqual(packet.payload, pdu)
    XCTAssertEqual(packet.etherType, AvtpEtherType)
    XCTAssertEqual(_macAddressToString(packet.sourceMacAddress), _macAddressToString(SerialPortPeerMacAddress))
    XCTAssertEqual(
      _macAddressToString(packet.destMacAddress),
      _macAddressToString(AvdeccMulticastMacAddress)
    )
  }

  func testClosedPortNeitherSendsNorReceives() async throws {
    let port = try SerialPort(path: devicePath)
    port.close()
    let packet = IEEE802Packet(
      destMacAddress: AvdeccMulticastMacAddress,
      tci: nil,
      sourceMacAddress: SerialPortLocalMacAddress,
      etherType: AvtpEtherType,
      payload: try entityDiscover
    )
    for result in [
      await Task { try await port.send(packet) }.result,
      await Task { try await port.receive { _ in } }.result,
    ] {
      // EBADF
      guard case .failure = result else { return XCTFail("a closed port should fail") }
    }
  }

  func testOpenClearsHardwareFlowControl() throws {
    // termios outlives an open of the device: this one is held open, and leaves CRTSCTS set
    let device = open(devicePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
    guard device >= 0 else { throw XCTSkip("cannot open \(devicePath!)") }
    defer { close(device) }
    var tty = termios()
    XCTAssertEqual(tcgetattr(device, &tty), 0)
    tty.c_cflag |= tcflag_t(CRTSCTS)
    XCTAssertEqual(tcsetattr(device, TCSANOW, &tty), 0)
    XCTAssertEqual(tcgetattr(device, &tty), 0)
    XCTAssertNotEqual(tty.c_cflag & tcflag_t(CRTSCTS), 0, "the pseudo-terminal does not hold CRTSCTS")

    let port = try SerialPort(path: devicePath)
    defer { port.close() }
    XCTAssertEqual(tcgetattr(device, &tty), 0)
    XCTAssertEqual(tty.c_cflag & tcflag_t(CRTSCTS), 0)
  }

  func testOpenIsNonBlocking() throws {
    let port = try SerialPort(path: devicePath)
    defer { port.close() }
    let flags = fcntl(port._fileHandle.fileDescriptor, F_GETFL)
    XCTAssertGreaterThanOrEqual(flags, 0)
    XCTAssertNotEqual(flags & O_NONBLOCK, 0)
  }

  // the termios speed constants are Int32 on x86_64 but UInt32 on aarch64
  func testOpenSetsBaudRate() throws {
    let device = open(devicePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
    guard device >= 0 else { throw XCTSkip("cannot open \(devicePath!)") }
    defer { close(device) }
    let speeds: [(baudRate: Int, speed: speed_t)] = [
      (9600, speed_t(B9600)),
      (115_200, speed_t(B115200)),
      (921_600, speed_t(B921600)),
      (4_000_000, speed_t(B4000000)),
    ]
    for (baudRate, speed) in speeds {
      let port = try SerialPort(path: devicePath, baudRate: baudRate)
      var tty = termios()
      XCTAssertEqual(tcgetattr(device, &tty), 0)
      XCTAssertEqual(cfgetospeed(&tty), speed, "baud rate \(baudRate)")
      port.close()
    }
    XCTAssertThrowsError(try SerialPort(path: devicePath, baudRate: 12345))
  }

  func testStalledSendDoesNotBlockTheRing() async throws {
    let port = try SerialPort(path: devicePath)
    defer { port.close() }
    let stalledSend = try await fillUntilSendStalls(port)

    // another request on the shared ring: a read of a second pseudo-terminal's controller end
    let (otherController, otherDevicePath) = try openPseudoTerminal()
    let otherDevice = open(otherDevicePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
    guard otherDevice >= 0 else { throw XCTSkip("cannot open \(otherDevicePath)") }
    defer { close(otherDevice) }
    let bytes: [UInt8] = [0x41, 0x42, 0x43]
    XCTAssertEqual(write(otherDevice, bytes, bytes.count), bytes.count)
    let read = Task {
      try await IORing.shared.read(count: bytes.count, from: otherController)
    }
    let readResult = await Completion(of: read).result(within: .seconds(1))

    stalledSend.cancel()
    await drainController(until: stalledSend)
    switch readResult {
    case let .success(received): XCTAssertEqual(received, bytes)
    case let .failure(error): XCTFail("read failed: \(error)")
    case .none: XCTFail("a stalled send blocked another request on the ring")
    }
  }

  func testStalledSendCanBeCancelled() async throws {
    let port = try SerialPort(path: devicePath)
    defer { port.close() }
    let stalledSend = try await fillUntilSendStalls(port)
    stalledSend.cancel()
    let result = await Completion(of: stalledSend).result(within: .seconds(1))
    // lets a write that was not cancelled finish, rather than leave it stalled
    await drainController(until: stalledSend)
    switch result {
    case .failure(is CancellationError): break
    case let result: XCTFail("expected CancellationError, got \(String(describing: result))")
    }
  }
}

#endif
