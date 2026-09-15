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

import ATDECC
import BinaryParsing
import IEEE802
import XCTest

private func fixedString(_ string: String) -> [UInt8] {
  let bytes = Array(string.utf8)
  return bytes + [UInt8](repeating: 0, count: AvdeccFixedStringLength - bytes.count)
}

private func be16(_ value: UInt16) -> [UInt8] {
  [UInt8(value >> 8), UInt8(value & 0xFF)]
}

private func be32(_ value: UInt32) -> [UInt8] {
  be16(UInt16(value >> 16)) + be16(UInt16(value & 0xFFFF))
}

private func be64(_ value: UInt64) -> [UInt8] {
  be32(UInt32(value >> 32)) + be32(UInt32(value & 0xFFFF_FFFF))
}

private func readDescriptorResponse(
  configurationIndex: UInt16 = 0,
  _ descriptor: [UInt8]
) throws -> (UInt16, DescriptorIndex, Descriptor) {
  let data = be16(configurationIndex) + be16(0) + descriptor
  guard case let .readDescriptor(configurationIndex, descriptorIndex, descriptor) =
    try AemResponsePayload(commandTypeRaw: AemCommandType.readDescriptor.rawValue, data: data)
  else {
    throw AvdeccCodecError.unexpectedMessageType(0)
  }
  return (configurationIndex, descriptorIndex, descriptor)
}

final class PayloadTests: XCTestCase {
  // MARK: - Descriptors

  func testConfigurationDescriptorCounts() throws {
    // descriptor_counts_offset is 74: descriptor_type/index (4) + object_name (64) +
    // localized_description (2) + count (2) + offset (2)
    let bytes = be16(DescriptorType.configuration.rawValue) + be16(0) +
      fixedString("Default") + be16(0xFFFF) + be16(2) + be16(74) +
      be16(DescriptorType.streamInput.rawValue) + be16(4) +
      be16(DescriptorType.audioUnit.rawValue) + be16(1)
    let (_, descriptorIndex, descriptor) = try readDescriptorResponse(bytes)
    XCTAssertEqual(descriptorIndex, 0)
    guard case let .configuration(configuration) = descriptor else {
      return XCTFail("expected CONFIGURATION")
    }
    XCTAssertEqual(configuration.objectName, "Default")
    XCTAssertEqual(configuration.streamInputCount, 4)
    XCTAssertEqual(configuration.audioUnitCount, 1)
    XCTAssertEqual(configuration.clockDomainCount, 0)

    var context = SerializationContext()
    try descriptor.serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes.count, bytes.count)
  }

  func testConfigurationDescriptorVendorCounts() throws {
    let bytes: [UInt8] = [0x00, 0x01, 0x00, 0x00] + // CONFIGURATION 0
      fixedString("Vendor") + [0xFF, 0xFF] + // object_name, localized_description
      [0x00, 0x03, 0x00, 0x4A] + // descriptor_counts_count 3, descriptor_counts_offset 74
      [0x00, 0x05, 0x00, 0x02] + // STREAM_INPUT: 2
      [0x01, 0x00, 0x00, 0x07] + // 0x0100: 7
      [0x01, 0x01, 0x00, 0x09] // 0x0101: 9
    let (_, _, descriptor) = try readDescriptorResponse(bytes)
    guard case let .configuration(configuration) = descriptor else {
      return XCTFail("expected CONFIGURATION")
    }
    XCTAssertEqual(configuration.descriptorCounts.count, 3)
    XCTAssertEqual(configuration.descriptorCount(DescriptorType(rawValue: 0x0005)), 2)
    XCTAssertEqual(configuration.descriptorCount(DescriptorType(rawValue: 0x0100)), 7)
    XCTAssertEqual(configuration.descriptorCount(DescriptorType(rawValue: 0x0101)), 9)

    var context = SerializationContext()
    try descriptor.serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes, bytes)
  }

  func testClockSourceDescriptorVendorLocationType() throws {
    let bytes: [UInt8] = [0x00, 0x0A, 0x00, 0x00] + // CLOCK_SOURCE 0
      fixedString("Word Clock") + [0xFF, 0xFF] + // object_name, localized_description
      [0x00, 0x00, 0x00, 0x01] + // clock_source_flags, clock_source_type EXTERNAL
      [0, 0, 0, 0, 0, 0, 0, 0] + // clock_source_identifier
      [0x80, 0x01, 0x00, 0x02] // clock_source_location_type 0x8001, index 2
    let (_, _, descriptor) = try readDescriptorResponse(bytes)
    guard case let .clockSource(clockSource) = descriptor else {
      return XCTFail("expected CLOCK_SOURCE")
    }
    XCTAssertEqual(clockSource.clockSourceLocationType.rawValue, 0x8001)

    var context = SerializationContext()
    try descriptor.serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes, bytes)
  }

  func testStreamDescriptorFormatsAtOffset() throws {
    let formats: [UInt64] = [0x0205_0220_0040_6000, 0x00A0_0208_4000_0800]
    var body = fixedString("Input 1") + be16(0xFFFF) + be16(0) // name, localized, clock domain
    body += be16(StreamFlags.classA.rawValue) + be64(formats[0])
    body += be16(132) + be16(UInt16(formats.count)) // formats_offset, number_of_formats
    body += [UInt8](repeating: 0, count: 40) // backup talkers and backedup talker
    body += be16(0) + be32(2_000_000) // avb_interface_index, buffer_length
    let bytes = be16(DescriptorType.streamInput.rawValue) + be16(3) + body +
      be64(formats[0]) + be64(formats[1])

    let (_, descriptorIndex, descriptor) = try readDescriptorResponse(bytes)
    XCTAssertEqual(descriptorIndex, 3)
    guard case let .streamInput(stream) = descriptor else {
      return XCTFail("expected STREAM_INPUT")
    }
    XCTAssertEqual(stream.objectName, "Input 1")
    XCTAssertEqual(stream.streamFlags, .classA)
    XCTAssertEqual(stream.formats.map(\.format), formats)
    XCTAssertEqual(stream.bufferLength, 2_000_000)
    XCTAssertTrue(stream.redundantStreams.isEmpty)

    var context = SerializationContext()
    try descriptor.serialize(descriptorIndex: 3, into: &context)
    XCTAssertEqual(context.bytes, bytes)
  }

  private func redundantStreamDescriptor(redundantOffset: UInt16) -> [UInt8] {
    var body = fixedString("Input 1") + be16(0xFFFF) + be16(0) // name, localized, clock domain
    body += be16(0x0002) + be64(0x0205_0220_0040_6000) // stream_flags CLASS_A, current_format
    body += be16(136) + be16(2) // formats_offset, number_of_formats
    body += [UInt8](repeating: 0, count: 40) // backup talkers and backedup talker
    body += be16(0) + be32(2_000_000) // avb_interface_index, buffer_length
    body += be16(redundantOffset) + be16(1) // redundant_offset, number_of_redundant_streams
    return be16(0x0005) + be16(0) + body + // STREAM_INPUT 0
      be64(0x0205_0220_0040_6000) + be64(0x00A0_0208_4000_0800) + be16(1)
  }

  func testStreamDescriptorRedundantStreams() throws {
    // two formats at 136..<152, then the redundant stream index at 152
    let bytes = redundantStreamDescriptor(redundantOffset: 152)
    let (_, _, descriptor) = try readDescriptorResponse(bytes)
    guard case let .streamInput(stream) = descriptor else {
      return XCTFail("expected STREAM_INPUT")
    }
    XCTAssertEqual(stream.formats.map(\.format), [0x0205_0220_0040_6000, 0x00A0_0208_4000_0800])
    XCTAssertEqual(stream.redundantStreams, [1])

    var context = SerializationContext()
    try descriptor.serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes, bytes)
  }

  func testStreamDescriptorFormatsOverlappingRedundantStreamsRejected() {
    // redundant_offset 144 falls inside the formats at 136..<152
    XCTAssertThrowsError(try readDescriptorResponse(redundantStreamDescriptor(redundantOffset: 144))) {
      XCTAssertEqual($0 as? AvdeccCodecError, .invalidOffset(144))
    }
  }

  func testDescriptorOffsetIntoFixedFieldsRejected() {
    let bytes = be16(DescriptorType.audioMap.rawValue) + be16(0) + be16(2) + be16(1) +
      [0, 0, 0, 1, 0, 0, 0, 1]
    XCTAssertThrowsError(try readDescriptorResponse(bytes))
  }

  func testEntityDescriptorRoundTrip() throws {
    var body = be64(0x001B_92FF_FE01_0203) + be64(0x001B_9200_0000_0042)
    body += be32(EntityCapabilities.aemSupported.rawValue) + be16(1) + be16(0x4001) +
      be16(2) + be16(0x4001) + be32(0) + be32(9) + be64(0)
    body += fixedString("Monitor Two") + be16(0) + be16(1) + fixedString("1.0.0") +
      fixedString("") + fixedString("0001") + be16(1) + be16(0)
    let bytes = be16(DescriptorType.entity.rawValue) + be16(0) + body

    let (_, _, descriptor) = try readDescriptorResponse(bytes)
    guard case let .entity(entity) = descriptor else {
      return XCTFail("expected ENTITY")
    }
    XCTAssertEqual(entity.entityName, "Monitor Two")
    XCTAssertEqual(entity.firmwareVersion, "1.0.0")
    XCTAssertEqual(entity.availableIndex, 9)
    XCTAssertEqual(entity.modelNameString.rawValue, 1)

    var context = SerializationContext()
    try descriptor.serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes, bytes)
  }

  // MARK: - AEM payloads

  func testMilanGetStreamInfoResponse() throws {
    var data = be16(DescriptorType.streamInput.rawValue) + be16(0)
    data += be32(StreamInfoFlags([.connected, .streamIDValid]).rawValue)
    data += be64(0x0205_0220_0040_6000) + be64(0x001B_92FF_FE01_0000)
    data += be32(1000) + [0x91, 0xE0, 0xF0, 0x00, 0x12, 0x34, 0, 0] + be64(0) + be16(2)
    data += be16(0) + be32(StreamInfoFlagsEx.registering.rawValue)
    data += [0x60, 0] + be16(0) // probing_status COMPLETED, acmp_status SUCCESS
    XCTAssertEqual(data.count, 56)

    guard case let .getStreamInfo(descriptorType, _, info) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.getStreamInfo.rawValue, data: data)
    else {
      return XCTFail("expected GET_STREAM_INFO")
    }
    XCTAssertEqual(descriptorType, .streamInput)
    XCTAssertTrue(info.streamInfoFlags.contains(.connected))
    XCTAssertEqual(info.streamVlanID, 2)
    XCTAssertEqual(UInt64(eui48: info.streamDestMac), 0x91E0_F000_1234)
    XCTAssertEqual(info.streamInfoFlagsEx, .registering)
    XCTAssertEqual(info.probingStatus, .completed)
    XCTAssertEqual(info.acmpStatus, .success)
  }

  func testMilanGetStreamInfoReservedStatus() throws {
    var data = be16(DescriptorType.streamInput.rawValue) + be16(0)
    data += be32(0) + be64(0) + be64(0) + be32(0) + [UInt8](repeating: 0, count: 8) +
      be64(0) + be16(0)
    data += be16(0) + be32(0)
    data += [0xF4, 0] + be16(0) // probing_status 7 and acmp_status 20, both reserved
    XCTAssertEqual(data.count, 56)

    guard case let .getStreamInfo(_, _, info) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.getStreamInfo.rawValue, data: data)
    else {
      return XCTFail("expected GET_STREAM_INFO")
    }
    XCTAssertEqual(info.probingStatusRaw, 7)
    XCTAssertNil(info.probingStatus)
    XCTAssertEqual(info.acmpStatusRaw, 20)
    XCTAssertEqual(info.acmpStatus, .reserved20)
  }

  func testSetStreamInfoCommandLength() throws {
    let command = AemCommandPayload.setStreamInfo(
      descriptorType: .streamOutput,
      descriptorIndex: 1,
      streamInfo: StreamInfo(streamVlanID: 2, streamInfoFlags: .streamVlanIDValid)
    )
    let bytes = try command.serialized()
    XCTAssertEqual(bytes.count, 48)
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: command.commandTypeRaw, data: bytes), command)
  }

  // response-only flags, MSRP failure fields and an unflagged latency stay off the wire (§7.4.15.1)
  func testSetStreamInfoCommandDropsResponseState() throws {
    let command = AemCommandPayload.setStreamInfo(
      descriptorType: .streamOutput,
      descriptorIndex: 1,
      streamInfo: StreamInfo(
        msrpAccumulatedLatency: 1000,
        streamVlanID: 2,
        streamInfoFlags: [
          .streamVlanIDValid, .noSrp, .encryptedPdu, .connected, .registeringFailed, .msrpFailureValid,
          .savedState, .streamingWait,
        ],
        msrpFailureCode: 4,
        msrpFailureBridgeID: 5
      )
    )
    let bytes = try command.serialized()
    // STREAM_VLAN_ID_VALID, NO_SRP and ENCRYPTED_PDU
    XCTAssertEqual(Array(bytes[4..<8]), [0x02, 0x00, 0x01, 0x20])
    guard case let .setStreamInfo(_, _, info) =
      try AemCommandPayload(commandTypeRaw: command.commandTypeRaw, data: bytes)
    else { return XCTFail("not a SET_STREAM_INFO") }
    XCTAssertEqual(info.msrpAccumulatedLatency, 0)
    XCTAssertEqual(info.msrpFailureCode, 0)
    XCTAssertEqual(info.msrpFailureBridgeID, 0)
    XCTAssertEqual(info.streamVlanID, 2)
  }

  func testMemoryObjectLengthFieldOrder() throws {
    let command = AemCommandPayload.setMemoryObjectLength(
      configurationIndex: 1,
      memoryObjectIndex: 2,
      length: 0x1000
    )
    // memory_object_index precedes configuration_index on the wire
    XCTAssertEqual(try command.serialized(), be16(2) + be16(1) + be64(0x1000))
  }

  func testGetAudioMapResponse() throws {
    let data = be16(DescriptorType.streamPortInput.rawValue) + be16(0) + be16(0) + be16(1) +
      be16(2) + be16(0) + be16(0) + be16(0) + be16(0) + be16(0) + be16(0) + be16(1) +
      be16(0) + be16(1)
    guard case let .getAudioMap(_, _, mapIndex, numberOfMaps, mappings) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.getAudioMap.rawValue, data: data)
    else {
      return XCTFail("expected GET_AUDIO_MAP")
    }
    XCTAssertEqual(mapIndex, 0)
    XCTAssertEqual(numberOfMaps, 1)
    XCTAssertEqual(mappings, [
      AudioMapping(streamIndex: 0, streamChannel: 0, clusterOffset: 0, clusterChannel: 0),
      AudioMapping(streamIndex: 0, streamChannel: 1, clusterOffset: 0, clusterChannel: 1),
    ])
  }

  func testTruncatedGetAudioMapResponseRejected() {
    let data: [UInt8] = [
      0x00, 0x0E, 0x00, 0x00, // STREAM_PORT_INPUT 0
      0x00, 0x00, 0x00, 0x01, // map_index 0, number_of_maps 1
      0xFF, 0xFF, 0x00, 0x00, // number_of_mappings 65535, reserved
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // the only mapping present
    ]
    XCTAssertThrowsError(
      try AemResponsePayload(commandTypeRaw: AemCommandType.getAudioMap.rawValue, data: data)
    ) { error in
      XCTAssertEqual(error as? AvdeccCodecError, .payloadTooShort(expected: 0xFFFF * 8, actual: 8))
    }
  }

  func testTruncatedAudioMapDescriptorRejected() {
    let bytes: [UInt8] = [
      0x00, 0x17, 0x00, 0x00, // AUDIO_MAP 0
      0x00, 0x08, 0xFF, 0xFF, // mappings_offset 8, number_of_mappings 65535
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // the only mapping present
    ]
    XCTAssertThrowsError(try readDescriptorResponse(bytes)) { error in
      XCTAssertEqual(error as? AvdeccCodecError, .payloadTooShort(expected: 0xFFFF * 8, actual: 8))
    }
  }

  func testGetCountersResponse() throws {
    var data = be16(DescriptorType.avbInterface.rawValue) + be16(0)
    data += [0x00, 0x00, 0x00, 0x01] // counters_valid: LINK_UP (bit 31, MSB-first)
    for counter in 0..<UInt32(DescriptorCounters.count) {
      data += be32(counter)
    }
    guard case let .getCounters(_, _, countersValid, counters) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.getCounters.rawValue, data: data)
    else {
      return XCTFail("expected GET_COUNTERS")
    }
    XCTAssertEqual(AvbInterfaceCounterValidFlags(rawValue: countersValid), .linkUp)
    XCTAssertEqual(counters[31], 31)
  }

  // an IEEE 1722.1-2021 entity reports its acquiring and locking controllers (§7.4.3.2); an
  // IEEE 1722.1-2013 one sends no payload
  func testEntityAvailableResponse() throws {
    let lockingController = UniqueIdentifier(0x0011_22FF_FE33_4455)
    let data = be32(EntityAvailableFlags.entityLocked.rawValue) + be64(0) + be64(lockingController.rawValue)
    guard case let .entityAvailable(availability) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.entityAvailable.rawValue, data: data)
    else { return XCTFail("expected ENTITY_AVAILABLE") }
    XCTAssertEqual(availability, EntityAvailability(flags: .entityLocked, lockedControllerID: lockingController))
    XCTAssertEqual(
      try AemResponsePayload(commandTypeRaw: AemCommandType.entityAvailable.rawValue, data: []),
      .entityAvailable(EntityAvailability())
    )
  }

  func testCounterValidFlagsWireValues() {
    // Milan 1.3 Table 5.14: signal presence counters
    XCTAssertEqual(StreamOutputCounterValidFlags.entitySpecific9.rawValue, 0x0080_0000)
    XCTAssertEqual(StreamOutputCounterValidFlags.entitySpecific10.rawValue, 0x0040_0000)
    // IEEE 1722.1-2021 Tables 7-150 to 7-158 number bits MSB-first: bit 31 is 0x0000_0001
    XCTAssertEqual(EntityCounterValidFlags.entitySpecific1.rawValue, 0x8000_0000)
    XCTAssertEqual(AvbInterfaceCounterValidFlags.linkUp.rawValue, 0x0000_0001)
    XCTAssertEqual(AvbInterfaceCounterValidFlags.gptpGmChanged.rawValue, 0x0000_0020)
    XCTAssertEqual(AvbInterfaceCounterValidFlags.entitySpecific8.rawValue, 0x0100_0000)
    XCTAssertEqual(AvbInterfaceCounterValidFlags.entitySpecific1.rawValue, 0x8000_0000)
    XCTAssertEqual(ClockDomainCounterValidFlags.locked.rawValue, 0x0000_0001)
    XCTAssertEqual(ClockDomainCounterValidFlags.unlocked.rawValue, 0x0000_0002)
    XCTAssertEqual(ClockDomainCounterValidFlags.entitySpecific1.rawValue, 0x8000_0000)
    XCTAssertEqual(StreamInputCounterValidFlags.mediaLocked.rawValue, 0x0000_0001)
    XCTAssertEqual(StreamInputCounterValidFlags.streamInterrupted.rawValue, 0x0000_0004)
    XCTAssertEqual(StreamInputCounterValidFlags.framesRx.rawValue, 0x0000_0800)
    XCTAssertEqual(StreamInputCounterValidFlags.framesTx.rawValue, 0x0000_1000)
    XCTAssertEqual(StreamInputCounterValidFlags.entitySpecific1.rawValue, 0x8000_0000)
    XCTAssertEqual(StreamOutputCounterValidFlags.streamStart.rawValue, 0x0000_0001)
    XCTAssertEqual(StreamOutputCounterValidFlags.streamInterrupted.rawValue, 0x0000_0004)
    XCTAssertEqual(StreamOutputCounterValidFlags.mediaReset.rawValue, 0x0000_0008)
    XCTAssertEqual(StreamOutputCounterValidFlags.framesTx.rawValue, 0x0000_0080)
    XCTAssertEqual(StreamOutputCounterValidFlags.entitySpecific1.rawValue, 0x8000_0000)
    // Milan 1.2 §5.3.7.7 has no STREAM_INTERRUPTED
    XCTAssertEqual(StreamOutputCounterValidFlagsMilan12.mediaReset.rawValue, 0x0000_0004)
    XCTAssertEqual(StreamOutputCounterValidFlagsMilan12.framesTx.rawValue, 0x0000_0010)
  }

  // MARK: - MVU payloads

  func testMilan12GetMilanInfoFallback() throws {
    let data = be16(0) + be32(1) + be32(0) + be32(MilanVersion(major: 1, minor: 2).rawValue)
    guard case let .getMilanInfo(info) =
      try MvuResponsePayload(commandTypeRaw: MvuCommandType.getMilanInfo.rawValue, data: data)
    else {
      return XCTFail("expected GET_MILAN_INFO")
    }
    XCTAssertEqual(info.specificationVersion, MilanVersion(major: 1, minor: 2))
  }

  func testBindStreamRoundTrip() throws {
    let command = MvuCommandPayload.bindStream(
      flags: .streamingWait,
      descriptorType: .streamInput,
      descriptorIndex: 0,
      talkerStream: StreamIdentification(entityID: UniqueIdentifier(0x1234), streamIndex: 1)
    )
    let bytes = try command.serialized()
    XCTAssertEqual(bytes.count, 18)
    XCTAssertEqual(try MvuCommandPayload(commandTypeRaw: command.commandTypeRaw, data: bytes), command)

    guard case let .bindStream(flags, _, _, talkerStream) =
      try MvuResponsePayload(commandTypeRaw: command.commandTypeRaw, data: bytes)
    else {
      return XCTFail("expected BIND_STREAM")
    }
    XCTAssertEqual(flags, .streamingWait)
    XCTAssertEqual(talkerStream.streamIndex, 1)
  }

  func testMediaClockReferenceInfoValidity() throws {
    let command = MvuCommandPayload.setMediaClockReferenceInfo(
      clockDomainIndex: 0,
      flags: .mediaClockDomainNameValid,
      defaultPriority: DefaultMediaClockReferencePriority.default.rawValue,
      userPriority: 7,
      domainName: "primary"
    )
    let bytes = try command.serialized()
    XCTAssertEqual(bytes.count, 74)
    guard case let .setMediaClockReferenceInfo(_, defaultPriority, info) =
      try MvuResponsePayload(commandTypeRaw: command.commandTypeRaw, data: bytes)
    else {
      return XCTFail("expected SET_MEDIA_CLOCK_REFERENCE_INFO")
    }
    XCTAssertEqual(defaultPriority, 128)
    XCTAssertNil(info.userMediaClockPriority)
    XCTAssertEqual(info.mediaClockDomainName, "primary")
  }
}

extension PayloadTests {
  func testGetStreamInputInfoExReservedStatus() throws {
    let data: [UInt8] = [
      0x00, 0x00, 0x00, 0x05, 0x00, 0x01, // reserved, STREAM_INPUT 1
      0x00, 0x1B, 0x92, 0xFF, 0xFE, 0x01, 0x02, 0x03, 0x00, 0x02, // talker stream
      0xAF, 0x00, // probing_status 5 (reserved), acmp_status 15 (reserved); reserved
    ]
    guard case let .getStreamInputInfoEx(_, descriptorIndex, info) = try MvuResponsePayload(
      commandTypeRaw: MvuCommandType.getStreamInputInfoEx.rawValue,
      data: data
    ) else {
      return XCTFail("expected GET_STREAM_INPUT_INFO_EX")
    }
    XCTAssertEqual(descriptorIndex, 1)
    XCTAssertEqual(info.talkerStream.streamIndex, 2)
    XCTAssertEqual(info.probingStatusRaw, 5)
    XCTAssertNil(info.probingStatus)
    XCTAssertEqual(info.acmpStatusRaw, 15)
    XCTAssertEqual(info.acmpStatus, .reserved15)

    let active: [UInt8] = Array(data.prefix(16)) + [0x47, 0x00] // ACTIVE, LISTENER_TALKER_TIMEOUT
    guard case let .getStreamInputInfoEx(_, _, activeInfo) = try MvuResponsePayload(
      commandTypeRaw: MvuCommandType.getStreamInputInfoEx.rawValue,
      data: active
    ) else {
      return XCTFail("expected GET_STREAM_INPUT_INFO_EX")
    }
    XCTAssertEqual(activeInfo.probingStatus, .active)
    XCTAssertEqual(activeInfo.acmpStatus, .listenerTalkerTimeout)
  }

  func testMediaClockReferenceInfoDefaultPriority() throws {
    // SET_MEDIA_CLOCK_REFERENCE_INFO with the default priority of an entity providing no data
    let command = MvuCommandPayload.setMediaClockReferenceInfo(
      clockDomainIndex: 0,
      flags: [],
      defaultPriority: DefaultMediaClockReferencePriority.default.rawValue,
      userPriority: 0,
      domainName: ""
    )
    // clock_domain_index, flags, reserved, default_media_clock_priority
    XCTAssertEqual(Array(try command.serialized().prefix(5)), [0x00, 0x00, 0x00, 0x00, 0x80])

    // a priority without a named category (0x9A) is reported as is
    let data: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x9A, 0x00] + [0, 0, 0, 0] +
      [UInt8](repeating: 0, count: AvdeccFixedStringLength)
    guard case let .getMediaClockReferenceInfo(clockDomainIndex, defaultPriority, _) =
      try MvuResponsePayload(
        commandTypeRaw: MvuCommandType.getMediaClockReferenceInfo.rawValue,
        data: data
      )
    else {
      return XCTFail("expected GET_MEDIA_CLOCK_REFERENCE_INFO")
    }
    XCTAssertEqual(clockDomainIndex, 1)
    XCTAssertEqual(defaultPriority, 0x9A)
  }

  func testRegisterUnsolicitedNotificationFlags() throws {
    let command = AemCommandPayload.registerUnsolicitedNotification(flags: .timeLimited)
    XCTAssertEqual(try command.serialized(), [0x00, 0x00, 0x00, 0x01])

    let commandType = AemCommandType.registerUnsolicitedNotification.rawValue
    guard case let .registerUnsolicitedNotification(flags) =
      try AemCommandPayload(commandTypeRaw: commandType, data: [0x00, 0x00, 0x00, 0x01])
    else { return XCTFail("not REGISTER_UNSOLICITED_NOTIFICATION") }
    XCTAssertEqual(flags, .timeLimited)

    // a command from an entity predating IEEE 1722.1-2021 has no flags (§7.4.37.1)
    guard case let .registerUnsolicitedNotification(noFlags) =
      try AemCommandPayload(commandTypeRaw: commandType, data: [])
    else { return XCTFail("not REGISTER_UNSOLICITED_NOTIFICATION") }
    XCTAssertEqual(noFlags, [])
  }

  func testFixedStringTruncatesAtCharacterBoundary() throws {
    let setName = AemCommandType.setName.rawValue
    // descriptor_type, descriptor_index, name_index, configuration_index precede the name
    let nameOffset = 8
    func serializedName(_ name: String) throws -> [UInt8] {
      let command = AemCommandPayload.setName(
        descriptorType: .entity,
        descriptorIndex: 0,
        nameIndex: 0,
        configurationIndex: 0,
        name: name
      )
      return Array(try command.serialized()[nameOffset..<(nameOffset + AvdeccFixedStringLength)])
    }

    let sixtyThree = [UInt8](repeating: 0x61, count: 63) // "a" × 63
    let sixtyTwo = [UInt8](repeating: 0x61, count: 62)
    // U+00E9 (C3 A9) straddles the end of the field
    XCTAssertEqual(try serializedName(String(repeating: "a", count: 63) + "\u{E9}"), sixtyThree + [0x00])
    // U+1F44D (F0 9F 91 8D) straddles the end of the field
    XCTAssertEqual(
      try serializedName(String(repeating: "a", count: 62) + "\u{1F44D}"),
      sixtyTwo + [0x00, 0x00]
    )
    // "e" and U+0301 (CC 81) are one character, which does not fit, so neither is kept
    XCTAssertEqual(
      try serializedName(String(repeating: "a", count: 62) + "e\u{301}"),
      sixtyTwo + [0x00, 0x00]
    )
    // a string that fills the field exactly is kept whole, without a NUL
    let sixtyFour = [UInt8](repeating: 0x61, count: 62) + [0xC3, 0xA9]
    XCTAssertEqual(try serializedName(String(repeating: "a", count: 62) + "\u{E9}"), sixtyFour)

    // and parsed whole, the field ending at 64 octets
    let data = [0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03] + sixtyFour
    guard case let .setName(_, descriptorIndex, nameIndex, configurationIndex, name) =
      try AemCommandPayload(commandTypeRaw: setName, data: data)
    else { return XCTFail("not SET_NAME") }
    XCTAssertEqual([descriptorIndex, nameIndex, configurationIndex], [1, 2, 3])
    XCTAssertEqual(name, String(repeating: "a", count: 62) + "\u{E9}")
  }

  func testFixedStringParsingIgnoresOctetsAfterNul() throws {
    // SET_NAME command: the name ends the payload, so a mis-sized field would fail to parse
    var field = Array("Input 1".utf8) + [0x00] + [0x42, 0x43]
    field += [UInt8](repeating: 0x00, count: AvdeccFixedStringLength - field.count)
    let data = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] + field
    guard case let .setName(_, _, _, _, name) =
      try AemCommandPayload(commandTypeRaw: AemCommandType.setName.rawValue, data: data)
    else { return XCTFail("not SET_NAME") }
    XCTAssertEqual(name, "Input 1")

    // too short a field is rejected
    XCTAssertThrowsError(try AemCommandPayload(
      commandTypeRaw: AemCommandType.setName.rawValue,
      data: Array(data.dropLast())
    ))
  }

  func testAvbInterfaceDescriptorComparesEveryField() throws {
    var body = fixedString("AVB 1") + be16(0xFFFF) + [0x00, 0x1B, 0x92, 0x00, 0x00, 0x01] // mac_address
    body += be16(0x0007) + be64(0x001B_92FF_FE00_0001) // interface_flags, clock_identity
    body += [0xF6, 0xF8] + be16(0x436A) // priority1, clock_class, offset_scaled_log_variance
    // clock_accuracy, priority2, domain_number, log_sync_interval, log_announce_interval,
    // log_pdelay_interval, port_number
    body += [0x21, 0xF7, 0x00, 0xFD, 0x00, 0x00] + be16(1)
    // an IEEE 1722.1-2013 descriptor ends at port_number
    guard case let (_, _, .avbInterface(shortDescriptor)) =
      try readDescriptorResponse(be16(DescriptorType.avbInterface.rawValue) + be16(0) + body)
    else { return XCTFail("expected AVB_INTERFACE") }
    XCTAssertEqual(shortDescriptor.numberOfControls, 0)
    body += be16(2) + be16(3) // number_of_controls, base_control
    let bytes = be16(DescriptorType.avbInterface.rawValue) + be16(0) + body
    guard case let (_, _, .avbInterface(descriptor)) = try readDescriptorResponse(bytes) else {
      return XCTFail("expected AVB_INTERFACE")
    }
    XCTAssertEqual(UInt64(eui48: descriptor.macAddress), 0x001B_9200_0001)
    XCTAssertEqual(descriptor.numberOfControls, 2)
    XCTAssertEqual(descriptor.baseControl, 3)
    var context = SerializationContext()
    try Descriptor.avbInterface(descriptor).serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes, bytes)

    let mutations: [(String, (inout AvbInterfaceDescriptor) -> ())] = [
      ("objectName", { $0.objectName = "" }),
      ("localizedDescription", { $0.localizedDescription = LocalizedStringReference(rawValue: 0) }),
      ("macAddress", { $0.macAddress[5] = 0 }),
      ("interfaceFlags", { $0.interfaceFlags = [] }),
      ("clockIdentity", { $0.clockIdentity = UniqueIdentifier(0) }),
      ("priority1", { $0.priority1 = 0 }),
      ("clockClass", { $0.clockClass = 0 }),
      ("offsetScaledLogVariance", { $0.offsetScaledLogVariance = 0 }),
      ("clockAccuracy", { $0.clockAccuracy = 0 }),
      ("priority2", { $0.priority2 = 0 }),
      ("domainNumber", { $0.domainNumber = 1 }),
      ("logSyncInterval", { $0.logSyncInterval = 0 }),
      ("logAnnounceInterval", { $0.logAnnounceInterval = 1 }),
      ("logPDelayInterval", { $0.logPDelayInterval = 1 }),
      ("portNumber", { $0.portNumber = 0 }),
      ("numberOfControls", { $0.numberOfControls = 0 }),
      ("baseControl", { $0.baseControl = 0 }),
    ]
    assertEveryFieldIsCompared(descriptor, mutations)
  }

  func testPtpPortDescriptorComparesEveryField() throws {
    // object_name, localized_description, port_number, port_type, flags, avb_interface_index,
    // profile_identifier
    let body = fixedString("PTP 1") + be16(0xFFFF) + be16(1) + be16(2) + be32(3) + be16(0) +
      [0x00, 0x80, 0xC2, 0x00, 0x01, 0x00]
    let bytes = be16(DescriptorType.ptpPort.rawValue) + be16(0) + body
    guard case let (_, _, .ptpPort(descriptor)) = try readDescriptorResponse(bytes) else {
      return XCTFail("expected PTP_PORT")
    }
    XCTAssertEqual(UInt64(eui48: descriptor.profileIdentifier), 0x0080_C200_0100)
    var context = SerializationContext()
    try Descriptor.ptpPort(descriptor).serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes, bytes)

    let mutations: [(String, (inout PtpPortDescriptor) -> ())] = [
      ("objectName", { $0.objectName = "" }),
      ("localizedDescription", { $0.localizedDescription = LocalizedStringReference(rawValue: 0) }),
      ("portNumber", { $0.portNumber = 0 }),
      ("portType", { $0.portType = 0 }),
      ("flags", { $0.flags = 0 }),
      ("avbInterfaceIndex", { $0.avbInterfaceIndex = 1 }),
      ("profileIdentifier", { $0.profileIdentifier[5] = 1 }),
    ]
    assertEveryFieldIsCompared(descriptor, mutations)
  }
}
