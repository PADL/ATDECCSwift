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

  func testAudioMappingEquality() {
    let a = AudioMapping(streamIndex: 0, streamChannel: 1, clusterOffset: 2, clusterChannel: 3)
    let b = AudioMapping(streamIndex: 0, streamChannel: 1, clusterOffset: 2, clusterChannel: 3)
    XCTAssertEqual(a, b)
    XCTAssertEqual(Set([a, b]).count, 1)
  }

  func testStreamInfoDefaultsAndMutation() {
    var info = StreamInfo()
    XCTAssertEqual(info.streamFormat.format, 0)
    XCTAssertEqual(info.streamDestMac, [0, 0, 0, 0, 0, 0])
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
    XCTAssertFalse(streamFlags.contains(.streamReset))
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

  func testProbingStatusUnknownDefaults() {
    XCTAssertEqual(ProbingStatus(99), .disabled)
    XCTAssertEqual(ProbingStatus(2), .active)
  }

  func testDefaultMediaClockReferencePriority() {
    XCTAssertEqual(DefaultMediaClockReferencePriority(0xF8), .default)
    XCTAssertEqual(DefaultMediaClockReferencePriority(0xFF), .userVariableExternal)
    XCTAssertEqual(DefaultMediaClockReferencePriority(0x10), .default)
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
