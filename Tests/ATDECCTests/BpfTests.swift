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
import struct SystemPackage.Errno
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let portMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]
private let peerMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
private let otherMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x03]
private let peerEntityID = UniqueIdentifier(0x0200_00FF_FE00_0002)
private let controllerEntityID = UniqueIdentifier(0x0200_00FF_FE00_0001)

/// The bytes of a frame with `payload`: an AVTP subtype byte, then a `marker`.
private func makeFrame(
  to destination: EUI48 = AvdeccMulticastMacAddress,
  etherType: UInt16 = AvtpEtherType,
  subtype: UInt8 = AvtpSubtype.adp.rawValue,
  marker: UInt8 = 0,
  payloadLength: Int = 46,
  vlan: Bool = false
) throws -> [UInt8] {
  var payload = [UInt8](repeating: marker, count: payloadLength)
  payload[0] = subtype
  return try IEEE802Packet(
    destMacAddress: destination,
    tci: vlan ? IEEE802Packet.TCI(0x6002) : nil,
    sourceMacAddress: peerMacAddress,
    etherType: etherType,
    payload: payload
  ).serialized()
}

/// Appends a record to `buffer` as bpf_catchpacket() does.
private func appendRecord(
  _ frame: [UInt8],
  to buffer: inout [UInt8],
  headerLength: Int = 18,
  capturedLength: Int? = nil,
  originalLength: Int? = nil
) {
  buffer += [UInt8](repeating: 0, count: _bpfWordAlign(buffer.count) - buffer.count)
  withUnsafeBytes(of: UInt64(0x1234_5678_9ABC_DEF0)) { buffer += $0 } // bh_tstamp
  withUnsafeBytes(of: UInt32(capturedLength ?? frame.count)) { buffer += $0 }
  withUnsafeBytes(of: UInt32(originalLength ?? frame.count)) { buffer += $0 }
  withUnsafeBytes(of: UInt16(headerLength)) { buffer += $0 }
  buffer += [UInt8](repeating: 0xEE, count: headerLength - _bpfMinimumHeaderLength)
  buffer += frame
}

private func packets(
  in buffer: [UInt8],
  for macAddress: EUI48 = portMacAddress
) -> [IEEE802Packet] {
  buffer.withUnsafeBytes { _avdeccPackets(in: $0, for: macAddress) }
}

final class BpfBufferTests: XCTestCase {
  func testWordAlignment() {
    XCTAssertEqual([0, 1, 2, 3, 4, 5, 63, 64].map(_bpfWordAlign), [0, 4, 4, 4, 4, 8, 64, 64])
  }

  func testEmptyBuffer() {
    XCTAssertEqual(BpfRecords(UnsafeRawBufferPointer(start: nil, count: 0)).underestimatedCount, 0)
    XCTAssertTrue(packets(in: []).isEmpty)
  }

  func testSingleRecord() throws {
    let frame = try makeFrame(marker: 7, payloadLength: 68)
    var buffer = [UInt8]()
    appendRecord(frame, to: &buffer)

    let records = buffer.withUnsafeBytes { Array(BpfRecords($0)) }
    XCTAssertEqual(records, [BpfRecord(
      capturedLength: frame.count,
      originalLength: frame.count,
      frame: 18..<(18 + frame.count)
    )])
    let received = packets(in: buffer)
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received.first?.payload.count, 68)
    XCTAssertEqual(received.first?.payload.last, 7)
    XCTAssertTrue(received.first
      .map { _isEqualMacAddress($0.sourceMacAddress, peerMacAddress) } ?? false)
  }

  /// Each length leaves a different amount of padding before the next record.
  func testMultiplePacketsInOneReadAreAlignedPerRecord() throws {
    var buffer = [UInt8]()
    let lengths = [46, 47, 48, 49, 50, 51, 1486, 53]
    for (i, length) in lengths.enumerated() {
      try appendRecord(makeFrame(marker: UInt8(i + 1), payloadLength: length), to: &buffer)
    }

    let offsets = buffer.withUnsafeBytes { BpfRecords($0).map(\.frame.lowerBound) }
    XCTAssertEqual(offsets.count, lengths.count)
    XCTAssertTrue(offsets.allSatisfy { ($0 - 18) % 4 == 0 })
    let received = packets(in: buffer)
    XCTAssertEqual(received.map(\.payload.count), lengths)
    XCTAssertEqual(received.compactMap(\.payload.last), lengths.indices.map { UInt8($0 + 1) })
  }

  /// bh_hdrlen includes padding the kernel chose, which isn't to be assumed.
  func testHeaderLengthIsHonoured() throws {
    var buffer = [UInt8]()
    try appendRecord(makeFrame(marker: 1), to: &buffer, headerLength: 20)
    try appendRecord(makeFrame(marker: 2), to: &buffer, headerLength: 18)
    try appendRecord(makeFrame(marker: 3), to: &buffer, headerLength: 26)
    XCTAssertEqual(packets(in: buffer).compactMap(\.payload.last), [1, 2, 3])
  }

  func testBufferNeedNotBeAligned() throws {
    var buffer = [UInt8]()
    try appendRecord(makeFrame(marker: 1), to: &buffer)
    try appendRecord(makeFrame(marker: 2), to: &buffer)
    let shifted = [0] + buffer
    let received = shifted.withUnsafeBytes {
      _avdeccPackets(in: UnsafeRawBufferPointer(rebasing: $0[1...]), for: portMacAddress)
    }
    XCTAssertEqual(received.compactMap(\.payload.last), [1, 2])
  }

  func testTruncatedFrameIsDroppedAndTheNextKept() throws {
    var buffer = [UInt8]()
    var frame = try makeFrame(marker: 1, payloadLength: 100)
    frame.removeLast(50)
    appendRecord(frame, to: &buffer, originalLength: frame.count + 50)
    try appendRecord(makeFrame(marker: 2), to: &buffer)
    XCTAssertEqual(packets(in: buffer).compactMap(\.payload.last), [2])
  }

  func testRecordOverrunningTheBufferEndsTheRead() throws {
    var buffer = [UInt8]()
    try appendRecord(makeFrame(marker: 1), to: &buffer)
    try appendRecord(makeFrame(marker: 2), to: &buffer, capturedLength: 100_000)
    try appendRecord(makeFrame(marker: 3), to: &buffer)
    XCTAssertEqual(packets(in: buffer).compactMap(\.payload.last), [1])
  }

  func testCapturedLengthAtTheLimitOfUInt32EndsTheRead() throws {
    var buffer = [UInt8]()
    appendRecord([], to: &buffer, capturedLength: Int(UInt32.max))
    XCTAssertTrue(buffer.withUnsafeBytes { Array(BpfRecords($0)) }.isEmpty)
  }

  func testImpossibleHeaderLengthEndsTheRead() throws {
    var buffer = [UInt8]()
    try appendRecord(makeFrame(marker: 1), to: &buffer)
    let second = _bpfWordAlign(buffer.count)
    try appendRecord(makeFrame(marker: 2), to: &buffer)
    buffer[second + 16] = 4
    buffer[second + 17] = 0
    XCTAssertEqual(packets(in: buffer).compactMap(\.payload.last), [1])
  }

  func testPartialHeaderAtTheEndIsIgnored() throws {
    var buffer = [UInt8]()
    try appendRecord(makeFrame(marker: 1), to: &buffer)
    buffer += [UInt8](repeating: 0xFF, count: _bpfWordAlign(buffer.count) - buffer.count + 17)
    XCTAssertEqual(packets(in: buffer).compactMap(\.payload.last), [1])
  }

  func testRuntFrameIsDropped() {
    var buffer = [UInt8]()
    appendRecord([0x91, 0xE0], to: &buffer)
    XCTAssertTrue(packets(in: buffer).isEmpty)
  }

  func testFramesAreSelectedByAddressEtherTypeAndSubtype() throws {
    var buffer = [UInt8]()
    try appendRecord(makeFrame(marker: 1), to: &buffer)
    try appendRecord(makeFrame(to: AvdeccIdentifyMulticastMacAddress, marker: 2), to: &buffer)
    try appendRecord(
      makeFrame(to: portMacAddress, subtype: AvtpSubtype.aecp.rawValue, marker: 3),
      to: &buffer
    )
    try appendRecord(makeFrame(subtype: AvtpSubtype.acmp.rawValue, marker: 4), to: &buffer)
    try appendRecord(makeFrame(to: portMacAddress, marker: 5, vlan: true), to: &buffer)
    // addressed to another station, as a promiscuous interface delivers
    try appendRecord(makeFrame(to: otherMacAddress, marker: 0x10), to: &buffer)
    // another multicast group
    try appendRecord(makeFrame(to: [0x91, 0xE0, 0xF0, 0x00, 0x12, 0x34], marker: 0x11), to: &buffer)
    // stream data, MAAP and other protocols
    try appendRecord(makeFrame(subtype: 0x02, marker: 0x12), to: &buffer)
    try appendRecord(makeFrame(subtype: AvtpSubtype.maap.rawValue, marker: 0x13), to: &buffer)
    try appendRecord(makeFrame(etherType: 0x0800, marker: 0x14), to: &buffer)
    XCTAssertEqual(packets(in: buffer).compactMap(\.payload.last), [1, 2, 3, 4, 5])
  }
}

/// A classic BPF interpreter, for the instructions a filter here uses: a frame is accepted if it
/// returns other than zero. A load beyond the frame rejects it, as it does in the kernel.
private func evaluate(_ program: [BpfInstruction], on frame: [UInt8]) -> UInt32 {
  var accumulator = UInt32(0)
  var pc = 0
  while pc < program.count {
    let instruction = program[pc]
    pc += 1
    func branch(_ condition: Bool) {
      pc += Int(condition ? instruction.jumpIfTrue : instruction.jumpIfFalse)
    }
    switch instruction.code {
    case 0x28:
      let offset = Int(instruction.operand)
      guard offset + 2 <= frame.count else { return 0 }
      accumulator = UInt32(frame[offset]) << 8 | UInt32(frame[offset + 1])
    case 0x30:
      let offset = Int(instruction.operand)
      guard offset < frame.count else { return 0 }
      accumulator = UInt32(frame[offset])
    case 0x05: pc += Int(instruction.operand)
    case 0x15: branch(accumulator == instruction.operand)
    case 0x25: branch(accumulator > instruction.operand)
    case 0x35: branch(accumulator >= instruction.operand)
    case 0x06: return instruction.operand
    default:
      XCTFail("unexpected instruction \(instruction.code)")
      return 0
    }
  }
  XCTFail("the program ran off its end")
  return 0
}

final class BpfProgramTests: XCTestCase {
  func testAcceptsWholeAtdeccFrames() throws {
    for subtype in [AvtpSubtype.adp, .aecp, .acmp] {
      XCTAssertEqual(try evaluate(AvdeccBpfProgram, on: makeFrame(subtype: subtype.rawValue)), .max)
      XCTAssertEqual(
        try evaluate(AvdeccBpfProgram, on: makeFrame(subtype: subtype.rawValue, vlan: true)),
        .max
      )
    }
  }

  func testRejectsEverythingElse() throws {
    // AVTP subtypes either side of the ATDECC ones, AAF, CRF and MAAP
    for subtype: UInt8 in [0xF9, 0xFD, 0xFE, 0x02, 0x04, 0x00] {
      XCTAssertEqual(try evaluate(AvdeccBpfProgram, on: makeFrame(subtype: subtype)), 0)
      XCTAssertEqual(try evaluate(AvdeccBpfProgram, on: makeFrame(subtype: subtype, vlan: true)), 0)
    }
    // the EtherType of IPv4, and of MVRP, tagged and not
    for etherType: UInt16 in [0x0800, 0x88F5] {
      XCTAssertEqual(try evaluate(AvdeccBpfProgram, on: makeFrame(etherType: etherType)), 0)
      XCTAssertEqual(
        try evaluate(AvdeccBpfProgram, on: makeFrame(etherType: etherType, vlan: true)),
        0
      )
    }
  }

  func testRejectsFramesTooShortToHoldTheFields() throws {
    let frame = try makeFrame()
    XCTAssertEqual(evaluate(AvdeccBpfProgram, on: Array(frame[..<14])), 0)
    XCTAssertEqual(evaluate(AvdeccBpfProgram, on: Array(frame[..<13])), 0)
    let tagged = try makeFrame(vlan: true)
    XCTAssertEqual(evaluate(AvdeccBpfProgram, on: Array(tagged[..<18])), 0)
  }

  func testBranchesStayInsideTheProgramWhichEndsInReturn() {
    XCTAssertEqual(AvdeccBpfProgram.last?.code, 0x06)
    for (i, instruction) in AvdeccBpfProgram.enumerated() where instruction.code & 0x07 == 0x05 {
      let targets = instruction.code == 0x05
        ? [Int(instruction.operand)]
        : [Int(instruction.jumpIfTrue), Int(instruction.jumpIfFalse)]
      for target in targets {
        XCTAssertLessThan(i + 1 + target, AvdeccBpfProgram.count)
      }
    }
  }
}

final class BpfReceiveLoopTests: XCTestCase {
  /// Runs the loop over `reads`, each the bytes of a read or its failure; it stops when they run
  /// out.
  private func runLoop(_ reads: [Result<[UInt8], Errno>])
    -> (received: [IEEE802Packet], failure: Errno?)
  {
    var remaining = reads[...]
    var received = [IEEE802Packet]()
    let failure = _runBpfReceiveLoop(
      bufferLength: 4096,
      macAddress: portMacAddress,
      read: { buffer in
        XCTAssertEqual(buffer.count, 4096)
        return remaining.removeFirst().map { bytes in
          buffer.copyBytes(from: bytes)
          return bytes.count
        }
      },
      isStopped: { remaining.isEmpty },
      deliver: { received.append($0) }
    )
    return (received, failure)
  }

  func testTimeoutsAndInterruptionsDoNotEndReception() throws {
    var first = [UInt8]()
    try appendRecord(makeFrame(marker: 1), to: &first)
    try appendRecord(makeFrame(marker: 2), to: &first)
    var second = [UInt8]()
    try appendRecord(makeFrame(marker: 3), to: &second)

    let (received, failure) = runLoop([
      .success([]),
      .success(first),
      .failure(.interrupted),
      .failure(.resourceTemporarilyUnavailable),
      .success(second),
    ])
    XCTAssertNil(failure)
    XCTAssertEqual(received.compactMap(\.payload.last), [1, 2, 3])
  }

  /// As a read does when the interface is removed.
  func testFailureEndsReception() throws {
    var buffer = [UInt8]()
    try appendRecord(makeFrame(marker: 1), to: &buffer)
    let (received, failure) = runLoop([
      .success(buffer),
      .failure(.noSuchAddressOrDevice),
      .success(buffer),
    ])
    XCTAssertEqual(failure, .noSuchAddressOrDevice)
    XCTAssertEqual(received.count, 1)
  }

  func testStoppedLoopDoesNotRead() {
    let failure = _runBpfReceiveLoop(
      bufferLength: 64,
      macAddress: portMacAddress,
      read: { _ in
        XCTFail("read")
        return .success(0)
      },
      isStopped: { true },
      deliver: { _ in }
    )
    XCTAssertNil(failure)
  }
}

/// Frames as a read presents them, through a virtual network, to a controller: the codecs and
/// state machines see what they would have from a BPF device.
final class BpfToControllerTests: XCTestCase {
  func testAdvertisementInABpfBufferBringsAnEntityOnline() async throws {
    let network = VirtualNetwork()
    let controllerPort = network.makePort(macAddress: portMacAddress)
    let bridge = network.makePort(macAddress: peerMacAddress)
    let endStation = EndStation(port: controllerPort)
    let controller = try await Controller(endStation: endStation, entityID: controllerEntityID)
    let events = await controller.events()

    let advertisement = AvdeccPdu.adp(Adpdu(
      messageType: .entityAvailable,
      entityID: peerEntityID,
      entityCapabilities: .aemSupported
    ))
    let frame = try IEEE802Packet(
      destMacAddress: AvdeccMulticastMacAddress,
      tci: nil,
      sourceMacAddress: peerMacAddress,
      etherType: AvtpEtherType,
      payload: advertisement.serialized()
    ).serialized()
    var buffer = [UInt8]()
    try appendRecord(makeFrame(subtype: 0x02), to: &buffer) // AAF, which is not for the controller
    appendRecord(frame, to: &buffer)

    let received = packets(in: buffer)
    XCTAssertEqual(received.count, 1)
    for packet in received {
      try await bridge.send(packet)
    }

    var isOnline = false
    for await event in events {
      if case .entityOnline(peerEntityID) = event {
        isOnline = true
        break
      }
    }
    XCTAssertTrue(isOnline)
    let entity = await controller.discoveredEntity(id: peerEntityID)
    XCTAssertNotNil(entity)
    await controller.close()
    await endStation.close()
  }
}

#if os(macOS)

/// Stands in for a BPF device, with a datagram socket pair: each write of the peer is a read of
/// the device, and a device read times out, as a device's does.
private final class FakeBpfDevices: Sendable {
  private struct State {
    var peers = [CInt]()
    var isDeviceClosed = [Bool]()
    var openFailure: (any Error)?
  }

  private let _state = Mutex(State())

  deinit {
    _state.withLock { state in
      for peer in state.peers {
        close(peer)
      }
    }
  }

  var openCount: Int {
    _state.withLock { $0.peers.count }
  }

  func isClosed(_ index: Int) -> Bool {
    _state.withLock { $0.isDeviceClosed[index] }
  }

  func failOpens(with error: any Error) {
    _state.withLock { $0.openFailure = error }
  }

  func open() throws -> BpfDevice {
    var descriptors = [CInt](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
      throw Errno(rawValue: errno)
    }
    var timeout = timeval(tv_sec: 0, tv_usec: 20000)
    setsockopt(
      descriptors[0],
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size)
    )
    // a test that waits for a write fails rather than hangs
    var writeTimeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(
      descriptors[1],
      SOL_SOCKET,
      SO_RCVTIMEO,
      &writeTimeout,
      socklen_t(MemoryLayout<timeval>.size)
    )
    let index = try _state.withLock { state in
      if let failure = state.openFailure { throw failure }
      state.peers.append(descriptors[1])
      state.isDeviceClosed.append(false)
      return state.peers.count - 1
    }
    return BpfDevice(descriptor: descriptors[0], bufferLength: 4096) { [self] in
      _state.withLock { $0.isDeviceClosed[index] = true }
    }
  }

  /// What device `index` reads next.
  func deliver(_ bytes: [UInt8], to index: Int = 0) {
    let peer = _state.withLock { $0.peers[index] }
    XCTAssertEqual(write(peer, bytes, bytes.count), bytes.count)
  }

  /// The next frame written to device `index`.
  func nextWrite(from index: Int = 0) -> [UInt8] {
    let peer = _state.withLock { $0.peers[index] }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = read(peer, &buffer, buffer.count)
    return count >= 0 ? Array(buffer[..<count]) : []
  }
}

private func makePort(
  _ devices: FakeBpfDevices,
  access: EthernetPort.Access = .readWrite,
  isRunning: @escaping @Sendable () throws -> Bool? = { true }
) throws -> EthernetPort {
  try EthernetPort(
    interfaceName: "fake0",
    macAddress: portMacAddress,
    access: access,
    open: devices.open,
    isRunning: isRunning
  )
}

private func eventually(_ condition: () -> Bool) async throws {
  for _ in 0..<500 where !condition() {
    try await Task.sleep(for: .milliseconds(10))
  }
  XCTAssertTrue(condition())
}

final class EthernetPortTests: XCTestCase {
  /// From clang, on arm64 and x86_64 alike: the macros aren't imported into Swift.
  func testRequestNumbersMatchTheSystemHeaders() {
    XCTAssertEqual(BIOCGBLEN, 0x4004_4266)
    XCTAssertEqual(BIOCSBLEN, 0xC004_4266)
    XCTAssertEqual(BIOCSETF, 0x8010_4267)
    XCTAssertEqual(BIOCFLUSH, 0x2000_4268)
    XCTAssertEqual(BIOCPROMISC, 0x2000_4269)
    XCTAssertEqual(BIOCGDLT, 0x4004_426A)
    XCTAssertEqual(BIOCSETIF, 0x8020_426C)
    XCTAssertEqual(BIOCSRTIMEOUT, 0x8010_426D)
    XCTAssertEqual(BIOCIMMEDIATE, 0x8004_4270)
    XCTAssertEqual(BIOCSHDRCMPLT, 0x8004_4275)
    XCTAssertEqual(BIOCSSEESENT, 0x8004_4277)
    XCTAssertEqual(SIOCADDMULTI, 0x8020_6931)
    XCTAssertEqual(SIOCDELMULTI, 0x8020_6932)
    XCTAssertEqual(SIOCGIFFLAGS, 0xC020_6911)
    XCTAssertEqual(SIOCGIFMEDIA, 0xC02C_6938)
  }

  func testInstructionLayoutMatchesTheSystemHeader() {
    XCTAssertEqual(MemoryLayout<BpfInstruction>.size, MemoryLayout<bpf_insn>.size)
    XCTAssertEqual(MemoryLayout<BpfInstruction>.offset(of: \.operand), 4)
  }

  func testUnknownInterfaceIsReportedBeforeAnyDeviceIsOpened() {
    XCTAssertThrowsError(try EthernetPort(interfaceName: "nonexistent0")) { error in
      XCTAssertEqual(error as? EthernetPortError, .interfaceNotFound("nonexistent0"))
    }
  }

  func testInterfaceWithoutAnEthernetAddressIsRefusedBeforeAnyDeviceIsOpened() {
    XCTAssertThrowsError(try EthernetPort(interfaceName: "lo0", access: .receiveOnly)) { error in
      XCTAssertEqual(error as? EthernetPortError, .notEthernet("lo0"))
    }
  }

  func testLoopbackIsRunningAndAnUnknownInterfaceIsAbsent() throws {
    XCTAssertEqual(try _isInterfaceRunning(name: "lo0"), true)
    XCTAssertNil(try _isInterfaceRunning(name: "nonexistent0"))
  }

  func testErrorsSayWhatToDo() {
    XCTAssertTrue(EthernetPortError.bpfPermissionDenied(path: "/dev/bpf0").description
      .contains("/dev/bpf0"))
    XCTAssertTrue(EthernetPortError.multicastMembershipDenied(interfaceName: "en0").description
      .contains("promiscuous"))
  }

  func testSendWritesOneSerializedFrame() async throws {
    let devices = FakeBpfDevices()
    let port = try makePort(devices)
    let frame = try makeFrame(to: peerMacAddress, subtype: AvtpSubtype.aecp.rawValue, marker: 9)
    try await port.send(IEEE802Packet(
      destMacAddress: peerMacAddress,
      tci: nil,
      sourceMacAddress: peerMacAddress,
      etherType: AvtpEtherType,
      payload: Array(frame[14...])
    ))
    XCTAssertEqual(devices.nextWrite(), frame)
  }

  func testReceiveOnlyPortRefusesToSendAndStillReceives() async throws {
    let devices = FakeBpfDevices()
    let port = try makePort(devices, access: .receiveOnly)
    do {
      try await port.send(IEEE802Packet(
        destMacAddress: AvdeccMulticastMacAddress,
        tci: nil,
        sourceMacAddress: portMacAddress,
        etherType: AvtpEtherType,
        payload: [AvtpSubtype.adp.rawValue]
      ))
      XCTFail("sent")
    } catch {
      XCTAssertEqual(error as? EthernetPortError, .sendOnReceiveOnlyPort)
    }

    var buffer = [UInt8]()
    try appendRecord(makeFrame(marker: 1), to: &buffer)
    let received = Mutex([UInt8]())
    let reception = Task {
      try await port.receive { packet in
        received.withLock { $0.append(packet.payload.last ?? 0) }
      }
    }
    devices.deliver(buffer)
    try await eventually { received.withLock { $0 == [1] } }
    reception.cancel()
    try await reception.value
  }

  func testAllFramesOfAReadReachTheHandlerAfterOnReady() async throws {
    let devices = FakeBpfDevices()
    let port = try makePort(devices)
    var buffer = [UInt8]()
    for marker in UInt8(1)...3 {
      try appendRecord(makeFrame(marker: marker, payloadLength: 45 + Int(marker)), to: &buffer)
    }
    try appendRecord(makeFrame(to: otherMacAddress, marker: 4), to: &buffer)

    let received = Mutex([UInt8]())
    let reception = Task {
      try await port.receive {
        devices.deliver(buffer)
      } _: { packet in
        received.withLock { $0.append(packet.payload.last ?? 0) }
      }
    }
    try await eventually { received.withLock { $0.count == 3 } }
    XCTAssertEqual(received.withLock { $0 }, [1, 2, 3])
    reception.cancel()
    try await reception.value
    XCTAssertEqual(devices.openCount, 1)
  }

  /// A stopped reception releases its device once a read times out, and the next opens another.
  func testReceivingAgainUsesANewDeviceAndClosesTheOld() async throws {
    let devices = FakeBpfDevices()
    let port = try _makeReopeningPort(devices)
    let first = Task { try await port.receive { _ in } }
    try await Task.sleep(for: .milliseconds(50))
    first.cancel()
    try await first.value

    let received = Mutex(0)
    let second = Task {
      try await port.receive { _ in
        received.withLock { $0 += 1 }
      }
    }
    try await eventually { devices.openCount == 2 }
    try await eventually { devices.isClosed(0) }
    var buffer = [UInt8]()
    try appendRecord(makeFrame(), to: &buffer)
    devices.deliver(buffer, to: 1)
    try await eventually { received.withLock { $0 == 1 } }
    second.cancel()
    try await second.value
  }

  private func _makeReopeningPort(_ devices: FakeBpfDevices) throws -> EthernetPort {
    // the reopening path reads the interface's address, so needs a name that has one
    let interfaceName = try XCTUnwrap(_firstInterfaceWithAddress())
    return try EthernetPort(
      interfaceName: interfaceName,
      macAddress: _linkLayerAddress(interfaceName: interfaceName),
      access: .readWrite,
      open: devices.open,
      isRunning: { true }
    )
  }

  private func _firstInterfaceWithAddress() -> String? {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0 else { return nil }
    defer { freeifaddrs(addresses) }
    var entry = addresses
    while let current = entry {
      entry = current.pointee.ifa_next
      let name = String(cString: current.pointee.ifa_name)
      if (try? _linkLayerAddress(interfaceName: name)) != nil { return name }
    }
    return nil
  }

  func testAFailedReadEndsReceptionWithItsError() async throws {
    // reading a descriptor that isn't open for reading fails as a removed interface's would
    let failing = BpfDevice(descriptor: open("/dev/null", O_WRONLY), bufferLength: 4096)
    let port = try EthernetPort(
      interfaceName: "fake0",
      macAddress: portMacAddress,
      access: .readWrite,
      open: { failing },
      isRunning: { true }
    )
    do {
      try await port.receive { _ in }
      XCTFail("received")
    } catch {
      XCTAssertEqual(error as? Errno, .badFileDescriptor)
    }
  }

  func testLinkStateIsReportedOnChange() async throws {
    let devices = FakeBpfDevices()
    let state = Mutex<Bool?>(true)
    let port = try makePort(devices, isRunning: { state.withLock { $0 } })
    let reported = Mutex([Bool]())
    let monitor = Task {
      try await port.monitorLinkState { isUp in
        reported.withLock { $0.append(isUp) }
      }
    }
    try await eventually { reported.withLock { $0 == [true] } }
    state.withLock { $0 = nil } // gone
    try await eventually { reported.withLock { $0 == [true, false] } }
    monitor.cancel()
    try await monitor.value
  }

  /// The whole stack, down to the bytes a device writes: the controller's ENTITY_DISCOVER goes out
  /// when reception begins, and a read holding an advertisement brings the entity online.
  func testControllerOverTheBpfPort() async throws {
    let devices = FakeBpfDevices()
    let port = try makePort(devices)
    let endStation = EndStation(port: port)
    let controller = try await Controller(endStation: endStation, entityID: controllerEntityID)
    let events = await controller.events()

    let discover = devices.nextWrite()
    XCTAssertGreaterThanOrEqual(discover.count, 60)
    XCTAssertEqual(Array(discover[0..<6]), [0x91, 0xE0, 0xF0, 0x01, 0x00, 0x00])
    XCTAssertEqual(Array(discover[6..<12]), [0x02, 0, 0, 0, 0, 1])
    XCTAssertEqual(Array(discover[12..<14]), [0x22, 0xF0])
    XCTAssertEqual(discover[14], AvtpSubtype.adp.rawValue)
    XCTAssertEqual(discover[15] & 0x0F, AdpMessageType.entityDiscover.rawValue)

    var buffer = [UInt8]()
    try appendRecord(
      IEEE802Packet(
        destMacAddress: AvdeccMulticastMacAddress,
        tci: nil,
        sourceMacAddress: peerMacAddress,
        etherType: AvtpEtherType,
        payload: AvdeccPdu.adp(Adpdu(
          messageType: .entityAvailable,
          entityID: peerEntityID,
          entityCapabilities: .aemSupported
        )).serialized()
      ).serialized(),
      to: &buffer
    )
    devices.deliver(buffer)

    for await event in events {
      if case .entityOnline(peerEntityID) = event { break }
    }
    let entity = await controller.discoveredEntity(id: peerEntityID)
    XCTAssertNotNil(entity)
    await controller.close()
    await endStation.close()
  }
}

#endif
