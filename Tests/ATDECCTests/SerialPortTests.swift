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
    let fileDescriptor = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
    guard fileDescriptor >= 0 else { throw XCTSkip("pseudo-terminals are unavailable") }
    controller = try FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    var unlock: CInt = 0
    var terminalNumber: CInt = 0
    guard ioctl(fileDescriptor, TIOCSPTLCK, &unlock) == 0,
          ioctl(fileDescriptor, TIOCGPTN, &terminalNumber) == 0
    else {
      throw XCTSkip("pseudo-terminals are unavailable")
    }
    devicePath = "/dev/pts/\(terminalNumber)"
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
}

#endif
