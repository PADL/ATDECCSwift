//
// Copyright (c) 2023-2026 PADL Software Pty Ltd
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

import ATDECC
import IEEE802
import XCTest

final class ModelTests: XCTestCase {
  // MARK: - StreamFormat

  func test61883_6FormatString() {
    let format = StreamFormat(format: 0x00A0_0208_4000_0800)
    XCTAssertEqual(format.version, .version_0)
    XCTAssertEqual(format.subtype, .iec61883iidc)
    XCTAssertEqual(format.isFloatingPoint, false)
    XCTAssertEqual(format.sampleRate, 48000)
    XCTAssertEqual(format.bitDepth, 24)
    XCTAssertEqual(format.channelsPerFrame, 8)
  }

  func test61883_6FloatFormat() {
    // sf 1, fmt 0x10, fdf_evt 0b00100 (32-bit floating point), fdf_sfc 48 kHz, dbs 8, nb
    let format = StreamFormat(format: 0x00A0_2208_4000_0000)
    XCTAssertEqual(format.isFloatingPoint, true)
    XCTAssertEqual(format.sampleRate, 48000)
    XCTAssertEqual(format.bitDepth, 32)
    XCTAssertEqual(format.channelsPerFrame, 8)
  }

  func test61883_6Int32Format() {
    // sf 1, fmt 0x10, fdf_evt 0b00110 (32-bit fixed point), fdf_sfc 96 kHz, dbs 2, nb
    let format = StreamFormat(format: 0x00A0_3402_4000_0000)
    XCTAssertEqual(format.isFloatingPoint, false)
    XCTAssertEqual(format.sampleRate, 96000)
    XCTAssertEqual(format.bitDepth, 32)
    XCTAssertEqual(format.channelsPerFrame, 2)
  }

  func testAafReservedFormat() {
    // format is an octet: 0x11 and 0x12 are reserved, not FLOAT_32BIT and INT_32BIT
    let reservedFloat = StreamFormat(format: 0x0205_1120_0040_6000)
    XCTAssertEqual(reservedFloat.isFloatingPoint, false)
    XCTAssertNil(reservedFloat.bitDepth)
    let reservedInt = StreamFormat(format: 0x0205_1220_0040_6000)
    XCTAssertNil(reservedInt.bitDepth)
  }

  func testAafFormatString() {
    let format = StreamFormat(format: 0x0205_0220_0040_6000)
    XCTAssertEqual(format.version, .version_0)
    XCTAssertEqual(format.subtype, .aaf)
    XCTAssertEqual(format.isFloatingPoint, false)
    XCTAssertEqual(format.sampleRate, 48000)
    XCTAssertEqual(format.bitDepth, 32)
    XCTAssertEqual(format.channelsPerFrame, 1)
    XCTAssertEqual(format.samplesPerFrame, 6)
  }

  // MARK: - UniqueIdentifier

  func testUniqueIdentifierDescription() {
    let id = UniqueIdentifier(0x0011_2233_4455_6677)
    XCTAssertEqual(id.rawValue, 0x0011_2233_4455_6677)
    XCTAssertEqual(id.description, "0011223344556677")
  }

  func testUniqueIdentifierHashable() {
    let a = UniqueIdentifier(0x1)
    let b = UniqueIdentifier(0x1)
    let c = UniqueIdentifier(0x2)
    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, c)
    XCTAssertEqual(Set([a, b, c]).count, 2)
  }

  // MARK: - SamplingRate

  func testSamplingRatePullZero() {
    let rate = SamplingRate(pull: 0, baseFrequency: 48000)
    XCTAssertEqual(rate.pull, 0)
    XCTAssertEqual(rate.baseFrequency, 48000)
    XCTAssertEqual(rate.nominalSampleRate, 48000.0)
    XCTAssertTrue(rate.isValid)
  }

  func testSamplingRatePullOne() {
    let rate = SamplingRate(pull: 1, baseFrequency: 48000)
    XCTAssertEqual(rate.pull, 1)
    XCTAssertEqual(rate.nominalSampleRate, 48000.0 / 1.001, accuracy: 1e-6)
  }

  func testSamplingRateRawRoundTrip() {
    let rate = SamplingRate(pull: 0b011, baseFrequency: 0x0100_0000)
    XCTAssertEqual(rate.rawValue, (UInt32(0b011) << 29) | 0x0100_0000)
    XCTAssertEqual(SamplingRate(rate.rawValue).pull, 0b011)
    XCTAssertEqual(SamplingRate(rate.rawValue).baseFrequency, 0x0100_0000)
  }

  func testSamplingRateInvalid() {
    XCTAssertFalse(SamplingRate(0).isValid)
    XCTAssertFalse(SamplingRate(pull: 7, baseFrequency: 0).isValid)
  }

  // MARK: - Streams and connections

  func testStreamIdentification() {
    let a = StreamIdentification(entityID: UniqueIdentifier(0x1), streamIndex: 0)
    let b = StreamIdentification(entityID: UniqueIdentifier(0x1), streamIndex: 0)
    let c = StreamIdentification(entityID: UniqueIdentifier(0x1), streamIndex: 1)
    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, c)
    XCTAssertEqual(
      StreamIdentification(entityID: UniqueIdentifier(0xDEAD_BEEF_FEED_FACE), streamIndex: 7)
        .description,
      "deadbeeffeedface:7"
    )
  }

  func testConnectionFlags() {
    let flags: ConnectionFlags = [.classB, .fastConnect, .savedState]
    XCTAssertTrue(flags.contains(.fastConnect))
    XCTAssertFalse(flags.contains(.streamingWait))
    XCTAssertEqual(ConnectionFlags.talkerFailed, .srpRegistrationFailed)
    XCTAssertEqual(flags.rawValue, 0b0000_0111)
  }

  // IEEE 1722.1-2021 numbers these bits MSB-first: bit N is 1 << (31 - N)
  func testFlagsAddedIn2021WireValues() {
    XCTAssertEqual(EntityCapabilities.acmpAcquireWithAem.rawValue, 0x0004_0000) // bit 13
    XCTAssertEqual(EntityCapabilities.multiplePtpInstances.rawValue, 0x0100_0000) // bit 7
    XCTAssertEqual(StreamInfoFlags.noSrp.rawValue, 0x0000_0100) // bit 23
    XCTAssertEqual(StreamInfoFlags.ipSrcAddrValid.rawValue, 0x0040_0000) // bit 9
    XCTAssertEqual(StreamInfoFlags.ipDstAddrValid.rawValue, 0x0080_0000) // bit 8
    XCTAssertEqual(StreamInfoFlags.notRegisteringSrp.rawValue, 0x0100_0000) // bit 7
    XCTAssertEqual(EntityAvailableFlags.entityAcquired.rawValue, 0x0000_0001) // bit 31
    XCTAssertEqual(EntityAvailableFlags.subentityLocked.rawValue, 0x0000_0008) // bit 28
  }

  func testAudioMappingEquality() {
    let a = AudioMapping(streamIndex: 0, streamChannel: 1, clusterOffset: 2, clusterChannel: 3)
    let b = AudioMapping(streamIndex: 0, streamChannel: 1, clusterOffset: 2, clusterChannel: 3)
    XCTAssertEqual(a, b)
    XCTAssertEqual(Set([a, b]).count, 1)
  }

  func testStreamInfoDefaultsAndMutation() {
    var info = StreamInfo()
    XCTAssertEqual(info.streamFormat.format, 0)
    XCTAssertEqual(UInt64(eui48: info.streamDestMac), 0)
    XCTAssertNil(info.streamInfoFlagsEx)

    info.streamID = UniqueIdentifier(0x1234)
    info.streamVlanID = 2
    info.streamInfoFlags = [.classB, .fastConnect]
    XCTAssertEqual(info.streamID.rawValue, 0x1234)
    XCTAssertEqual(info.streamVlanID, 2)
    XCTAssertTrue(info.streamInfoFlags.contains(.fastConnect))
  }

  // MARK: - Counters

  func testDescriptorCountersIndexing() {
    let counters = DescriptorCounters((0..<UInt32(DescriptorCounters.count)).map { $0 })
    XCTAssertEqual(counters[15], 15)
    XCTAssertEqual(counters[31], 31)
  }

  func testCounterValidFlags() {
    let streamFlags: StreamInputCounterValidFlags = [.mediaLocked, .framesRx]
    XCTAssertTrue(streamFlags.contains(.framesRx))
    XCTAssertFalse(streamFlags.contains(.streamInterrupted))
    let interfaceFlags: AvbInterfaceCounterValidFlags = [.linkUp, .framesTx]
    XCTAssertTrue(interfaceFlags.contains(.linkUp))
    XCTAssertFalse(interfaceFlags.contains(.linkDown))
  }

  // MARK: - Milan

  func testMilanVersion() {
    let v = MilanVersion(rawValue: 0x0102_0304)
    XCTAssertEqual(v.major, 1)
    XCTAssertEqual(v.minor, 2)
    XCTAssertEqual(v.patch, 3)
    XCTAssertEqual(v.build, 4)
    XCTAssertEqual(v.description, "1.2.3.4")
    XCTAssertEqual(MilanVersion(major: 1, minor: 2, build: 42).rawValue, 0x0102_002A)
  }

  func testBindStreamFlags() {
    var flags: BindStreamFlags = []
    flags.insert(.streamingWait)
    XCTAssertEqual(flags.rawValue, 1)
  }

  func testProbingStatusReservedCodes() {
    XCTAssertEqual(ProbingStatus(rawValue: 2), .active)
    XCTAssertNil(ProbingStatus(rawValue: 4))
  }

  func testDefaultMediaClockReferencePriority() {
    // Milan 1.3 §5.4.4.4
    XCTAssertEqual(DefaultMediaClockReferencePriority.highest.rawValue, 255)
    XCTAssertEqual(DefaultMediaClockReferencePriority.amplifiers.rawValue, 160)
    XCTAssertEqual(DefaultMediaClockReferencePriority.default.rawValue, 128)
    XCTAssertEqual(DefaultMediaClockReferencePriority.lowest.rawValue, 0)
    XCTAssertNil(DefaultMediaClockReferencePriority(rawValue: 0x10))
  }

  func testMediaClockReferenceInfoOptionals() {
    let info = MediaClockReferenceInfo(userMediaClockPriority: 5, mediaClockDomainName: "primary")
    XCTAssertEqual(info.userMediaClockPriority, 5)
    XCTAssertEqual(info.mediaClockDomainName, "primary")
    XCTAssertNil(MediaClockReferenceInfo().userMediaClockPriority)
  }

  // MARK: - Status codes

  func testStatusFromUnknownRaw() {
    XCTAssertEqual(AemStatus(0xBEEF), .internalError)
    XCTAssertEqual(AemStatus(7), .badArguments)
    XCTAssertEqual(AcmpStatus(0xBEEF), .internalError)
    XCTAssertEqual(AcmpStatus(8), .listenerExclusive)
    XCTAssertEqual(MvuStatus(0xBEEF), .internalError)
    XCTAssertEqual(MvuStatus(13), .payloadTooShort)
  }

  func testMemoryObjectOperationType() {
    XCTAssertEqual(MemoryObjectOperationType(rawValue: 0), .store)
    XCTAssertEqual(MemoryObjectOperationType.upload.rawValue, 4)
    XCTAssertNil(MemoryObjectOperationType(rawValue: 0x1000))
  }
}

/// Checks that each mutation changes both the equality and the hash of `value`: that every field
/// takes part in a hand-written Hashable conformance.
func assertEveryFieldIsCompared<T: Hashable>(
  _ value: T,
  _ mutations: [(String, (inout T) -> ())],
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let copy = value
  XCTAssertEqual(copy, value, file: file, line: line)
  XCTAssertEqual(copy.hashValue, value.hashValue, file: file, line: line)
  for (field, mutate) in mutations {
    var mutated = value
    mutate(&mutated)
    XCTAssertNotEqual(mutated, value, "\(field) is not compared", file: file, line: line)
    XCTAssertNotEqual(mutated.hashValue, value.hashValue, "\(field) is not hashed", file: file, line: line)
  }
}

// Types holding an EUI48 or InlineArray, which is not Hashable, write out their conformances.
final class HashableConformanceTests: XCTestCase {
  func testAcmpduComparesEveryField() {
    let acmpdu = Acmpdu(
      messageType: .connectRxCommand,
      status: 1,
      streamID: UniqueIdentifier(2),
      controllerEntityID: UniqueIdentifier(3),
      talkerEntityID: UniqueIdentifier(4),
      listenerEntityID: UniqueIdentifier(5),
      talkerUniqueID: 6,
      listenerUniqueID: 7,
      streamDestAddress: [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x08],
      connectionCount: 9,
      sequenceID: 10,
      flags: [.classB],
      streamVlanID: 11
    )
    let mutations: [(String, (inout Acmpdu) -> ())] = [
      ("messageType", { $0.messageType = .connectRxResponse }),
      ("status", { $0.status = 0 }),
      ("streamID", { $0.streamID = UniqueIdentifier(0) }),
      ("controllerEntityID", { $0.controllerEntityID = UniqueIdentifier(0) }),
      ("talkerEntityID", { $0.talkerEntityID = UniqueIdentifier(0) }),
      ("listenerEntityID", { $0.listenerEntityID = UniqueIdentifier(0) }),
      ("talkerUniqueID", { $0.talkerUniqueID = 0 }),
      ("listenerUniqueID", { $0.listenerUniqueID = 0 }),
      ("streamDestAddress", { $0.streamDestAddress[5] = 0 }),
      ("connectionCount", { $0.connectionCount = 0 }),
      ("sequenceID", { $0.sequenceID = 0 }),
      ("flags", { $0.flags = [] }),
      ("streamVlanID", { $0.streamVlanID = 0 }),
    ]
    assertEveryFieldIsCompared(acmpdu, mutations)
  }

  func testStreamInfoComparesEveryField() {
    let info = StreamInfo(
      streamFormat: StreamFormat(format: 0x0205_0220_0040_6000),
      streamID: UniqueIdentifier(1),
      msrpAccumulatedLatency: 2,
      streamVlanID: 3,
      streamInfoFlags: [.connected],
      streamDestMac: [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x04],
      msrpFailureCode: 5,
      msrpFailureBridgeID: 6,
      streamInfoFlagsEx: .registering,
      probingStatusRaw: 7,
      acmpStatusRaw: 8
    )
    let mutations: [(String, (inout StreamInfo) -> ())] = [
      ("streamFormat", { $0.streamFormat = StreamFormat(format: 0) }),
      ("streamID", { $0.streamID = UniqueIdentifier(0) }),
      ("msrpAccumulatedLatency", { $0.msrpAccumulatedLatency = 0 }),
      ("streamVlanID", { $0.streamVlanID = 0 }),
      ("streamInfoFlags", { $0.streamInfoFlags = [] }),
      ("streamDestMac", { $0.streamDestMac[5] = 0 }),
      ("msrpFailureCode", { $0.msrpFailureCode = 0 }),
      ("msrpFailureBridgeID", { $0.msrpFailureBridgeID = 0 }),
      ("streamInfoFlagsEx", { $0.streamInfoFlagsEx = nil }),
      ("probingStatusRaw", { $0.probingStatusRaw = nil }),
      ("acmpStatusRaw", { $0.acmpStatusRaw = nil }),
    ]
    assertEveryFieldIsCompared(info, mutations)
  }

  func testInterfaceInformationComparesEveryField() {
    let interface = Entity.InterfaceInformation(
      macAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x01],
      validTime: 2,
      availableIndex: 3,
      gptpGrandmasterID: UniqueIdentifier(4),
      gptpDomainNumber: 5
    )
    let mutations: [(String, (inout Entity.InterfaceInformation) -> ())] = [
      ("macAddress", { $0.macAddress[5] = 0 }),
      ("validTime", { $0.validTime = 0 }),
      ("availableIndex", { $0.availableIndex = 0 }),
      ("gptpGrandmasterID", { $0.gptpGrandmasterID = nil }),
      ("gptpDomainNumber", { $0.gptpDomainNumber = nil }),
    ]
    assertEveryFieldIsCompared(interface, mutations)
  }

  func testDescriptorCountersComparesEveryCounter() {
    let values = (0..<UInt32(DescriptorCounters.count)).map { 100 + $0 }
    let counters = DescriptorCounters(values)
    let mutations: [(String, (inout DescriptorCounters) -> ())] = (0..<DescriptorCounters.count).map { index in
      ("counter \(index)", { counters in
        var changed = values
        changed[index] = 0
        counters = DescriptorCounters(changed)
      })
    }
    assertEveryFieldIsCompared(counters, mutations)
    XCTAssertEqual(counters[31], 131)
  }
}
