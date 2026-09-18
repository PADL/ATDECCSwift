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

  // IEEE 1722.1-2021 Table 7-8: timing follows the redundancy fields, at 136
  func testStreamDescriptorTiming() throws {
    let format: UInt64 = 0x0205_0220_0040_6000
    var body = fixedString("Input 1") + be16(0xFFFF) + be16(0) // name, localized, clock domain
    body += be16(StreamFlags.classA.rawValue) + be64(format)
    body += be16(138) + be16(1) // formats_offset, number_of_formats
    body += [UInt8](repeating: 0, count: 40) // backup talkers and backedup talker
    body += be16(0) + be32(2_000_000) // avb_interface_index, buffer_length
    body += be16(146) + be16(0) // redundant_offset, number_of_redundant_streams
    body += be16(3) // timing
    let bytes = be16(DescriptorType.streamInput.rawValue) + be16(0) + body + be64(format)
    guard case let (_, _, .streamInput(stream)) = try readDescriptorResponse(bytes) else {
      return XCTFail("expected STREAM_INPUT")
    }
    XCTAssertEqual(stream.timing, 3)
    XCTAssertTrue(stream.redundantStreams.isEmpty)
    XCTAssertEqual(stream.formats.map(\.format), [format])

    var context = SerializationContext()
    try Descriptor.streamInput(stream).serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes, bytes)
  }

  // counts and offsets that do not fit their 16-bit fields are refused, not trapped on
  func testOversizeDescriptorIsNotSerialized() throws {
    let bytes = redundantStreamDescriptor(redundantOffset: 152)
    guard case var (_, _, .streamInput(stream)) = try readDescriptorResponse(bytes) else {
      return XCTFail("expected STREAM_INPUT")
    }
    // the redundant streams would follow the formats at an offset past 65535
    stream.formats = [StreamFormat](repeating: stream.formats[0], count: 8192)
    var context = SerializationContext()
    XCTAssertThrowsError(try Descriptor.streamInput(stream).serialize(descriptorIndex: 0, into: &context)) {
      XCTAssertEqual($0 as? AvdeccCodecError, .valueTooLarge)
    }
    stream.redundantStreams = []
    stream.formats = [StreamFormat](repeating: stream.formats[0], count: 65536)
    XCTAssertThrowsError(try Descriptor.streamInput(stream).serialize(descriptorIndex: 0, into: &context)) {
      XCTAssertEqual($0 as? AvdeccCodecError, .valueTooLarge)
    }
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
    XCTAssertEqual(info.layout, .milanBefore1_3)
  }

  // IEEE 1722.1-2021 Figure 7-40: ip_flags replaces the reserved field, then the ports and
  // 16-octet addresses make the payload 84 octets
  func testIeee2021StreamInfoIPFields() throws {
    let destination = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 239, 1, 2, 3]
    var data = be16(DescriptorType.streamOutput.rawValue) + be16(0)
    data += be32(StreamInfoFlags([.ipDstPortValid, .ipDstAddrValid]).rawValue)
    data += be64(0) + be64(0) + be32(0) + [UInt8](repeating: 0, count: 8) + be64(0) + be16(2)
    data += be16(0) + be16(0) + be16(17220) // ip_flags, source_port, destination_port
    data += [UInt8](repeating: 0, count: 16) + destination
    XCTAssertEqual(data.count, 84)
    guard case let .getStreamInfo(_, _, info) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.getStreamInfo.rawValue, data: data)
    else { return XCTFail("expected GET_STREAM_INFO") }
    XCTAssertEqual(info.layout, .ieee1722_1_2021)
    XCTAssertEqual(info.destinationPort, 17220)
    XCTAssertEqual(info.destinationIPAddress, destination)
    XCTAssertEqual(info.streamVlanID, 2)

    // a SET that sets an IP field is sent at 84 octets; one that does not stays at 48
    let command = AemCommandPayload.setStreamInfo(
      descriptorType: .streamOutput,
      descriptorIndex: 0,
      streamInfo: StreamInfo(
        streamInfoFlags: .ipDstPortValid,
        layout: .ieee1722_1_2021,
        destinationPort: 17220
      )
    )
    let bytes = try command.serialized()
    XCTAssertEqual(bytes.count, 84)
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: command.commandTypeRaw, data: bytes), command)
    XCTAssertEqual(try AemCommandPayload.setStreamInfo(
      descriptorType: .streamOutput,
      descriptorIndex: 0,
      streamInfo: StreamInfo(streamInfoFlags: .streamVlanIDValid, destinationPort: 17220)
    ).serialized().count, 48)
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

  func testIncrementControlCommand() throws {
    let command = AemCommandPayload.incrementControl(descriptorType: .control, descriptorIndex: 2, valueIndices: [0, 3])
    let bytes = try command.serialized()
    // descriptor_type, descriptor_index, index_count, reserved, index_list (Figure 7-51)
    XCTAssertEqual(bytes, be16(DescriptorType.control.rawValue) + be16(2) + be16(2) + be16(0) + [0, 3])
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: command.commandTypeRaw, data: bytes), command)
    XCTAssertEqual(
      AemCommandPayload.decrementControl(descriptorType: .control, descriptorIndex: 2, valueIndices: []).commandTypeRaw,
      AemCommandType.decrementControl.rawValue
    )
  }

  // dynamic_info: length, reserved, status, reserved, command_type, data (Figure 7-94)
  func testGetDynamicInfoPayloads() throws {
    let command = AemCommandPayload.getDynamicInfo(commands: [
      .getConfiguration,
      .getSamplingRate(descriptorType: .audioUnit, descriptorIndex: 0),
    ])
    let commandBytes = try command.serialized()
    XCTAssertEqual(
      commandBytes,
      be16(0) + be16(0) + [0, 0] + be16(AemCommandType.getConfiguration.rawValue) +
        be16(4) + be16(0) + [0, 0] + be16(AemCommandType.getSamplingRate.rawValue) +
        be16(DescriptorType.audioUnit.rawValue) + be16(0)
    )
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: command.commandTypeRaw, data: commandBytes), command)

    let samplingRate = be16(DescriptorType.audioUnit.rawValue) + be16(0) + be32(48000)
    let responseBytes = be16(8) + be16(0) + [UInt8(AemStatus.success.rawValue), 0] +
      be16(AemCommandType.getSamplingRate.rawValue) + samplingRate +
      be16(4) + be16(0) + [UInt8(AemStatus.notSupported.rawValue), 0] +
      be16(AemCommandType.getStreamBackup.rawValue) + be16(DescriptorType.streamInput.rawValue) + be16(0)
    guard case let .getDynamicInfo(infos) =
      try AemResponsePayload(commandTypeRaw: command.commandTypeRaw, data: responseBytes)
    else { return XCTFail("expected GET_DYNAMIC_INFO") }
    XCTAssertEqual(infos.count, 2)
    guard case let .getSamplingRate(_, _, rate)? = infos.first?.response else {
      return XCTFail("expected a GET_SAMPLING_RATE response")
    }
    XCTAssertEqual(rate.rawValue, 48000)
    XCTAssertEqual(infos.last?.status, .notSupported)
    XCTAssertNil(infos.last?.response)

    // a length running past the payload is malformed
    XCTAssertThrowsError(try AemResponsePayload(
      commandTypeRaw: command.commandTypeRaw,
      data: be16(9) + be16(0) + [0, 0] + be16(AemCommandType.getSamplingRate.rawValue)
    ))
  }

  // Figure 7-92: three backup talkers and the backed up talker, each Entity ID, unique ID and
  // a reserved word
  func testStreamBackupSamplingRateRangeAndPathLatencyPayloads() throws {
    let backup = StreamBackup(
      backupTalker0: StreamIdentification(entityID: UniqueIdentifier(1), streamIndex: 2),
      backupTalker1: StreamIdentification(entityID: UniqueIdentifier(3), streamIndex: 4),
      backupTalker2: StreamIdentification(entityID: UniqueIdentifier(0), streamIndex: 0),
      backedUpTalker: StreamIdentification(entityID: UniqueIdentifier(5), streamIndex: 6)
    )
    let setBackup = AemCommandPayload.setStreamBackup(descriptorType: .streamInput, descriptorIndex: 1, backup: backup)
    let bytes = try setBackup.serialized()
    let expected = be16(DescriptorType.streamInput.rawValue) + be16(1)
      + be64(1) + be16(2) + be16(0)
      + be64(3) + be16(4) + be16(0)
      + be64(0) + be16(0) + be16(0)
      + be64(5) + be16(6) + be16(0)
    XCTAssertEqual(expected.count, 52)
    XCTAssertEqual(bytes, expected)
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: setBackup.commandTypeRaw, data: bytes), setBackup)
    guard case let .getStreamBackup(_, _, parsed) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.getStreamBackup.rawValue, data: bytes)
    else { return XCTFail("expected GET_STREAM_BACKUP") }
    XCTAssertEqual(parsed, backup)

    // Figure 7-97
    let setRange = AemCommandPayload.setSamplingRateRange(
      descriptorType: .videoCluster,
      descriptorIndex: 0,
      samplingRateRange: 0x1E
    )
    XCTAssertEqual(try setRange.serialized(), be16(DescriptorType.videoCluster.rawValue) + be16(0) + be64(0x1E))

    // Figure 7-137: a 4-octet path_latency
    guard case let .getPathLatency(_, _, pathLatency) = try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPathLatency.rawValue,
      data: be16(DescriptorType.audioCluster.rawValue) + be16(0) + be32(1500)
    ) else { return XCTFail("expected GET_PATH_LATENCY") }
    XCTAssertEqual(pathLatency, 1500)
  }

  // Figures 7-36 and 7-38: format_specific, aspect_ratio, color_space, frame_size; an 8-octet sensor_format
  func testVideoAndSensorFormatPayloads() throws {
    let videoFormat = VideoFormat(formatSpecific: 0x0102_0304, aspectRatio: 0x1009, colorSpace: 2, frameSize: 0x0780_0438)
    let setVideo = AemCommandPayload.setVideoFormat(descriptorType: .videoCluster, descriptorIndex: 1, videoFormat: videoFormat)
    let videoBytes = try setVideo.serialized()
    XCTAssertEqual(
      videoBytes,
      be16(DescriptorType.videoCluster.rawValue) + be16(1) + be32(0x0102_0304) + be16(0x1009) + be16(2) + be32(0x0780_0438)
    )
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: setVideo.commandTypeRaw, data: videoBytes), setVideo)
    guard case .getVideoFormat(_, 1, videoFormat) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.getVideoFormat.rawValue, data: videoBytes)
    else { return XCTFail("expected GET_VIDEO_FORMAT") }

    let sensorBytes = be16(DescriptorType.sensorCluster.rawValue) + be16(0) + be64(0x0011_2233_4455_6677)
    guard case .getSensorFormat(_, 0, 0x0011_2233_4455_6677) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.getSensorFormat.rawValue, data: sensorBytes)
    else { return XCTFail("expected GET_SENSOR_FORMAT") }
    let setSensor = AemCommandPayload.setSensorFormat(
      descriptorType: .sensorCluster,
      descriptorIndex: 0,
      sensorFormat: 0x0011_2233_4455_6677
    )
    XCTAssertEqual(try setSensor.serialized(), sensorBytes)
  }

  // Figures 7-69 to 7-71: 8-octet video mappings and 6-octet sensor mappings
  func testVideoAndSensorMapPayloads() throws {
    let video = VideoMapping(streamIndex: 1, programStream: 2, elementaryStream: 3, clusterOffset: 4)
    let getVideoMap = be16(DescriptorType.streamPortInput.rawValue) + be16(0) + be16(1) + be16(2) + be16(1) + be16(0) +
      be16(1) + be16(2) + be16(3) + be16(4)
    guard case let .getVideoMap(_, _, mapIndex, numberOfMaps, mappings) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.getVideoMap.rawValue, data: getVideoMap)
    else { return XCTFail("expected GET_VIDEO_MAP") }
    XCTAssertEqual(mapIndex, 1)
    XCTAssertEqual(numberOfMaps, 2)
    XCTAssertEqual(mappings, [video])
    // number_of_mappings running past the payload is malformed
    XCTAssertThrowsError(try AemResponsePayload(
      commandTypeRaw: AemCommandType.getVideoMap.rawValue,
      data: Array(getVideoMap.dropLast())
    ))

    let sensor = SensorMapping(streamIndex: 5, streamSignal: 6, clusterOffset: 7)
    let addSensor = AemCommandPayload.addSensorMappings(
      descriptorType: .streamPortOutput,
      descriptorIndex: 2,
      mappings: [sensor, sensor]
    )
    let sensorBytes = try addSensor.serialized()
    XCTAssertEqual(
      sensorBytes,
      be16(DescriptorType.streamPortOutput.rawValue) + be16(2) + be16(2) + be16(0) +
        be16(5) + be16(6) + be16(7) + be16(5) + be16(6) + be16(7)
    )
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: addSensor.commandTypeRaw, data: sensorBytes), addSensor)
    guard case .removeSensorMappings(_, 2, [sensor, sensor]) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.removeSensorMappings.rawValue, data: sensorBytes)
    else { return XCTFail("expected REMOVE_SENSOR_MAPPINGS") }

    let getSensorMap = AemCommandPayload.getSensorMap(descriptorType: .streamPortInput, descriptorIndex: 0, mapIndex: 3)
    XCTAssertEqual(try getSensorMap.serialized(), be16(DescriptorType.streamPortInput.rawValue) + be16(0) + be16(3) + be16(0))
  }

  // Figures 7-52 to 7-58: signal selector source and reserved; mixer values; matrix rep, direction, value_count
  func testSignalSelectorMixerAndMatrixPayloads() throws {
    let source = SignalSource(signalType: .audioCluster, signalIndex: 3, signalOutput: 1)
    let setSelector = AemCommandPayload.setSignalSelector(descriptorType: .signalSelector, descriptorIndex: 0, source: source)
    let selectorBytes = try setSelector.serialized()
    XCTAssertEqual(
      selectorBytes,
      be16(DescriptorType.signalSelector.rawValue) + be16(0) + be16(DescriptorType.audioCluster.rawValue) + be16(3) +
        be16(1) + be16(0)
    )
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: setSelector.commandTypeRaw, data: selectorBytes), setSelector)
    guard case .getSignalSelector(_, 0, source) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.getSignalSelector.rawValue, data: selectorBytes)
    else { return XCTFail("expected GET_SIGNAL_SELECTOR") }

    let mixerBytes = be16(DescriptorType.mixer.rawValue) + be16(1) + be32(0x7F)
    guard case .getMixer(_, 1, [0, 0, 0, 0x7F]) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.getMixer.rawValue, data: mixerBytes)
    else { return XCTFail("expected GET_MIXER") }

    let subregion = MatrixSubregion(
      column: 1, row: 2, width: 3, height: 4, repeats: true, direction: .vertical, valueCount: 0xABC, itemOffset: 5
    )
    let setMatrix = AemCommandPayload.setMatrix(
      descriptorType: .matrix,
      descriptorIndex: 0,
      subregion: subregion,
      values: [1, 2]
    )
    let matrixBytes = try setMatrix.serialized()
    let matrixHeader = be16(DescriptorType.matrix.rawValue) + be16(0) + be16(1) + be16(2) + be16(3) + be16(4)
    XCTAssertEqual(matrixBytes, matrixHeader + be16(0x9ABC) + be16(5) + [1, 2])
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: setMatrix.commandTypeRaw, data: matrixBytes), setMatrix)

    // GET_MATRIX reserves the rep bit
    let getMatrix = AemCommandPayload.getMatrix(descriptorType: .matrix, descriptorIndex: 0, subregion: subregion)
    XCTAssertEqual(try getMatrix.serialized(), matrixHeader + be16(0x1ABC) + be16(5))
    guard case let .getMatrix(_, _, parsed, values) = try AemResponsePayload(
      commandTypeRaw: AemCommandType.getMatrix.rawValue,
      data: matrixBytes
    ) else { return XCTFail("expected GET_MATRIX") }
    XCTAssertFalse(parsed.repeats)
    XCTAssertEqual(parsed.direction, .vertical)
    XCTAssertEqual(parsed.valueCount, 0xABC)
    XCTAssertEqual(values, [1, 2])

    var tooMany = subregion
    tooMany.valueCount = 0x1000
    XCTAssertThrowsError(try AemCommandPayload.setMatrix(
      descriptorType: .matrix,
      descriptorIndex: 0,
      subregion: tooMany,
      values: []
    ).serialized())
  }

  // Figures 7-99 to 7-113: flag bits are numbered MSB first, so bit 15 is the least significant
  func testPtpInstancePayloads() throws {
    let instance = be16(DescriptorType.ptpInstance.rawValue) + be16(0)
    // cv, tt, so and ie; the grandmaster's gm_cv and gm_pt
    let body = [248, 0xFE] + be16(0x436A) + [246, 248, 0, 0xA0] + be16(37) + be16(0x0100 | 0x20 | 0x04 | 0x01) +
      be64(0x0011_22FF_FE33_4455) + [6, 0x21] + be16(0x4E5D) + [1, 2, 0x20, 0x21] + be16(37) + be16(0)
    guard case let .getPtpInstanceInfo(_, _, info) = try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPtpInstanceInfo.rawValue,
      data: instance + body
    ) else { return XCTFail("expected GET_PTP_INSTANCE_INFO") }
    XCTAssertEqual(info.clockQuality, PtpClockQuality(clockClass: 248, clockAccuracy: 0xFE, offsetScaledLogVariance: 0x436A))
    XCTAssertEqual(info.priority1, 246)
    XCTAssertEqual(info.currentUtcOffset, 37)
    XCTAssertEqual(info.timeProperties, [.currentUtcOffsetValid, .timeTraceable])
    XCTAssertEqual(info.state, [.slaveOnly, .instanceEnabled])
    XCTAssertEqual(info.grandmaster.clockIdentity, UniqueIdentifier(0x0011_22FF_FE33_4455))
    XCTAssertEqual(info.grandmaster.timeSource, 0x20)
    XCTAssertEqual(info.grandmaster.timeProperties, [.currentUtcOffsetValid, .ptpTimescale])

    // Figure 7-103: parent, cumulative_rate_ratio, valid_flags, gm_timebase_indicator, then an
    // 8-octet TimeInterval, a 12-octet ScaledNs, an 8-octet Float64 and four quadlets
    let extended = body + be64(0x0011_22FF_FE66_7788) + be16(1) + be16(2) + be32(UInt32(bitPattern: -5)) +
      be16(0x0001) + be16(3) + be64(0xFFFF_FFFF_FFFF_0000) + be32(0) + be64(0x0002_8000) +
      be64((1.5).bitPattern) + be32(8) + be32(9) + be32(10) + be32(11)
    XCTAssertEqual(extended.count, 96) // 100 octets with descriptor_type and descriptor_index
    guard case let .getPtpInstanceExtendedInfo(_, _, extendedInfo) = try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPtpInstanceExtendedInfo.rawValue,
      data: instance + extended
    ) else { return XCTFail("expected GET_PTP_INSTANCE_EXTENDED_INFO") }
    XCTAssertEqual(extendedInfo.info, info)
    XCTAssertEqual(extendedInfo.stepsRemoved, 2)
    XCTAssertEqual(extendedInfo.cumulativeRateRatio, -5)
    XCTAssertEqual(extendedInfo.valid, .offsetFromMaster)
    XCTAssertEqual(extendedInfo.offsetFromMaster.nanoseconds, -1)
    XCTAssertEqual(extendedInfo.lastGmPhaseChange.nanoseconds, 2.5)
    XCTAssertEqual(extendedInfo.lastGmFreqChange, 1.5)
    XCTAssertEqual(extendedInfo.gmChangeCount, 8)
    XCTAssertEqual(extendedInfo.timeOfLastGmFreqChange, 11)
    XCTAssertThrowsError(try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPtpInstanceExtendedInfo.rawValue,
      data: instance + extended.dropLast()
    ))

    let settings = PtpInstanceSettings(flags: [.priority1, .slaveOnly], priority1: 200, state: .slaveOnly)
    let set = AemCommandPayload.setPtpInstanceInfo(descriptorType: .ptpInstance, descriptorIndex: 0, settings: settings)
    let setBytes = try set.serialized()
    XCTAssertEqual(setBytes, instance + be16(0) + be16(0x0104) + [200, 0, 0, 0x04])
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: set.commandTypeRaw, data: setBytes), set)

    let pathTrace = AemCommandPayload.getPtpInstancePathTrace(descriptorType: .ptpInstance, descriptorIndex: 0, startIndex: 1)
    XCTAssertEqual(try pathTrace.serialized(), instance + be16(1) + be16(0))
    let traceBytes = instance + be16(1) + be16(2) + be64(0xA) + be64(0xB)
    guard case .getPtpInstancePathTrace(_, _, 1, [UniqueIdentifier(0xA), UniqueIdentifier(0xB)]) = try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPtpInstancePathTrace.rawValue,
      data: traceBytes
    ) else { return XCTFail("expected GET_PTP_INSTANCE_PATH_TRACE") }
    XCTAssertThrowsError(try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPtpInstancePathTrace.rawValue,
      data: Array(traceBytes.dropLast())
    ))
    guard case .getPtpInstancePathCount(_, _, 4) = try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPtpInstancePathCount.rawValue,
      data: instance + be16(0) + be16(4)
    ) else { return XCTFail("expected GET_PTP_INSTANCE_PATH_COUNT") }

    // record_index, flags (MEASUREMENT_VALID and MASTER_SLAVE_DELAY_VALID), timestamp, 16 octlets
    var record = instance + be16(3) + be16(0x0005) + be64(1000)
    for value in 0..<UInt64(16) {
      record += be64(value)
    }
    guard case let .getPtpInstancePerfMonRecord(_, _, perfMon) = try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPtpInstancePerfMonRecord.rawValue,
      data: record
    ) else { return XCTFail("expected GET_PTP_INSTANCE_PERF_MON_RECORD") }
    XCTAssertEqual(perfMon.recordIndex, 3)
    XCTAssertEqual(perfMon.flags, [.measurementValid, .masterSlaveDelayValid])
    XCTAssertEqual(perfMon.timestamp, 1000)
    XCTAssertEqual(perfMon.slaveMasterDelay.average, 4)
    XCTAssertEqual(perfMon.offsetFromMaster.standardDeviation, 15)
  }

  // Figures 7-114 to 7-135
  func testPtpPortPayloads() throws {
    let port = be16(DescriptorType.ptpPort.rawValue) + be16(1)
    let intervals = PtpPortIntervals(flags: [.announce, .gptpCapable], logSyncInterval: -3, logGptpCapableInterval: 3)
    let setIntervals = AemCommandPayload.setPtpPortInitialIntervals(
      descriptorType: .ptpPort,
      descriptorIndex: 1,
      intervals: intervals
    )
    let intervalBytes = try setIntervals.serialized()
    XCTAssertEqual(intervalBytes, port + be16(0) + be16(0x0009) + [0x00, 0xFD, 0x00, 0x03])
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: setIntervals.commandTypeRaw, data: intervalBytes), setIntervals)
    guard case .getPtpPortCurrentIntervals(_, 1, intervals) = try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPtpPortCurrentIntervals.rawValue,
      data: intervalBytes
    ) else { return XCTFail("expected GET_PTP_PORT_CURRENT_INTERVALS") }

    let overrides = PtpPortOverrides(
      flags: [.syncInterval, .desiredState],
      booleans: [.useSyncInterval, .computeMeanLinkDelay],
      logSyncInterval: -3,
      desiredState: 9
    )
    let setOverrides = AemCommandPayload.setPtpPortOverrides(descriptorType: .ptpPort, descriptorIndex: 1, overrides: overrides)
    let overrideBytes = try setOverrides.serialized()
    XCTAssertEqual(overrideBytes, port + be16(0x0082) + be16(0x0202) + [0, 0xFD, 0, 0, 9, 0] + be16(0))
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: setOverrides.commandTypeRaw, data: overrideBytes), setOverrides)

    guard case let .getPtpPortPdelayMonCount(_, _, counts) = try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPtpPortPdelayMonCount.rawValue,
      data: port + be16(96) + be16(10) + be16(97) + be16(3)
    ) else { return XCTFail("expected GET_PTP_PORT_PDELAY_MON_COUNT") }
    XCTAssertEqual(counts.maxCountOf24h, 96)
    XCTAssertEqual(counts.maxCountOf15m, 97)
    XCTAssertEqual(counts.countOf15m, 3)

    var record = port + be16(0) + be16(0x0003) + be64(5)
    for value in 0..<UInt32(17) {
      record += be32(value)
    }
    guard case let .getPtpPortPerfMonRecord(_, _, perfMon) = try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPtpPortPerfMonRecord.rawValue,
      data: record
    ) else { return XCTFail("expected GET_PTP_PORT_PERF_MON_RECORD") }
    XCTAssertEqual(perfMon.flags, [.measurementValid, .periodComplete])
    XCTAssertEqual(perfMon.syncRx, 4)
    XCTAssertEqual(perfMon.pdelayRespFollowUpRx, 16)

    let pdelayRecord = port + be16(2) + be16(0x0001) + be64(5) + be64(10) + be64(9) + be64(11) + be64(1)
    guard case let .getPtpPortPdelayMonRecord(_, _, pdelay) = try AemResponsePayload(
      commandTypeRaw: AemCommandType.getPtpPortPdelayMonRecord.rawValue,
      data: pdelayRecord
    ) else { return XCTFail("expected GET_PTP_PORT_PDELAY_MON_RECORD") }
    XCTAssertEqual(pdelay.meanLinkDelay.maximum, 11)
    XCTAssertEqual(try AemCommandPayload.getPtpPortPdelayMonRecord(
      descriptorType: .ptpPort,
      descriptorIndex: 1,
      recordIndex: 2
    ).serialized(), port + be16(2) + be16(0))
  }

  // Figure 7-32: WRITE_DESCRIPTOR carries a whole descriptor, as READ_DESCRIPTOR's response does
  func testWriteDescriptorPayload() throws {
    let block = be16(DescriptorType.controlBlock.rawValue) + be16(2) + fixedString("Block") + be16(0xFFFF) +
      be16(4) + be16(0) + be16(3) + be16(DescriptorType.invalid.rawValue) + be16(0) + be16(0)
    let (_, descriptorIndex, descriptor) = try readDescriptorResponse(block)
    let command = AemCommandPayload.writeDescriptor(
      configurationIndex: 0,
      descriptorIndex: descriptorIndex,
      descriptor: descriptor
    )
    let bytes = try command.serialized()
    XCTAssertEqual(bytes, be16(0) + be16(0) + block)
    XCTAssertEqual(try AemCommandPayload(commandTypeRaw: command.commandTypeRaw, data: bytes), command)
    guard case let .writeDescriptor(_, writtenIndex, written) =
      try AemResponsePayload(commandTypeRaw: AemCommandType.writeDescriptor.rawValue, data: bytes)
    else { return XCTFail("expected WRITE_DESCRIPTOR") }
    XCTAssertEqual(writtenIndex, 2)
    XCTAssertEqual(written, descriptor)
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

  // IEEE 1722.1-2021 Tables 7-12, 7-19, 7-28, 7-64, 7-68 and 7-121, and control_value_type's
  // read only and unknown flags (§7.3.6.1)
  func testDescriptorValueTypes() {
    XCTAssertEqual(JackType.pps.rawValue, 0x0025)
    XCTAssertEqual(JackType(rawValue: 0x1234).rawValue, 0x1234) // undefined values are kept
    XCTAssertEqual(MemoryObjectType.daeGeneric.rawValue, 0x000E)
    XCTAssertEqual(AudioClusterFormat.smpte.rawValue, 0x88)
    XCTAssertEqual(TimingAlgorithm.combined.rawValue, 0x0002)
    XCTAssertEqual(PtpPortType.e2eUnicastUdpV6.rawValue, 0x000B)

    let valueType = ControlValueType(rawValue: 0x8014)
    XCTAssertTrue(valueType.isReadOnly)
    XCTAssertFalse(valueType.isValueUnknown)
    XCTAssertEqual(valueType.kind, .selectorString)
    XCTAssertEqual(ControlValueType(.gptpTime, isValueUnknown: true).rawValue, 0x4023)
    XCTAssertEqual(ControlValueType.Kind.vendor.rawValue, 0x3FFE)
  }

  // IEEE 1722.1-2021 Tables 7-66, 7-69 and 7-160, numbered MSB-first
  func testPtpFlagsWireValues() {
    XCTAssertEqual(PtpInstanceFlags.canSetInstanceEnable.rawValue, 0x0000_0001)
    XCTAssertEqual(PtpInstanceFlags.grandmasterCapable.rawValue, 0x8000_0000)
    XCTAssertEqual(PtpPortFlags.canOverrideComputeLinkDelay.rawValue, 0x0000_0800) // bit 20
    XCTAssertEqual(PtpPortFlags.canOverrideOnestep.rawValue, 0x0000_1000) // bit 19
    XCTAssertEqual(PtpPortFlags.supportsUnicastNegotiate.rawValue, 0x8000_0000)
    XCTAssertEqual(PtpPortCounterValidFlags.txDelayResponse.rawValue, 0x0080_0000) // bit 8
    XCTAssertEqual(PtpPortCounterValidFlags.entitySpecific1.rawValue, 0x8000_0000)
  }

  // AECP status is five bits (Table 7-141); a reserved code is kept as received
  func testReservedAemStatusIsKept() {
    XCTAssertEqual(AemStatus(20).rawValue, 20)
    XCTAssertEqual(AemStatus(31).rawValue, 31)
    XCTAssertEqual(AemStatus(200), .internalError)
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

  // IEEE 1722.1-2021 Table 7-27 adds aes3_data_type_reference and aes3_data_type after format
  func testAudioClusterDescriptorAes3DataType() throws {
    // object_name, localized_description, signal_type, signal_index, signal_output,
    // path_latency, block_latency, channel_count, format
    var body = fixedString("Cluster 1") + be16(0xFFFF) + be16(DescriptorType.invalid.rawValue) +
      be16(0) + be16(0) + be32(10) + be32(20) + be16(8) + [0x40]
    guard case let (_, _, .audioCluster(short)) =
      try readDescriptorResponse(be16(DescriptorType.audioCluster.rawValue) + be16(0) + body)
    else { return XCTFail("expected AUDIO_CLUSTER") }
    XCTAssertEqual(short.channelCount, 8)
    XCTAssertNil(short.aes3DataTypeReference)
    XCTAssertNil(short.aes3DataType)
    // an IEEE 1722.1-2013 descriptor is written back at the length it was read
    try assertDescriptorRoundTrips(be16(DescriptorType.audioCluster.rawValue) + be16(0) + body)

    body += [0x01] + be16(0x0002)
    let bytes = be16(DescriptorType.audioCluster.rawValue) + be16(0) + body
    guard case let (_, _, .audioCluster(cluster)) = try readDescriptorResponse(bytes) else {
      return XCTFail("expected AUDIO_CLUSTER")
    }
    XCTAssertEqual(cluster.aes3DataTypeReference, 1)
    XCTAssertEqual(cluster.aes3DataType, 2)
    var context = SerializationContext()
    try Descriptor.audioCluster(cluster).serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes, bytes)
  }

  // IEEE 1722.1-2021 Table 7-18 adds maximum_segment_length after length
  func testMemoryObjectDescriptorMaximumSegmentLength() throws {
    // object_name, localized_description, memory_object_type, target_descriptor_type,
    // target_descriptor_index, start_address, maximum_length, length
    var body = fixedString("Firmware") + be16(0xFFFF) + be16(0) + be16(DescriptorType.entity.rawValue) +
      be16(0) + be64(0x1000) + be64(0x10000) + be64(0x8000)
    guard case let (_, _, .memoryObject(short)) =
      try readDescriptorResponse(be16(DescriptorType.memoryObject.rawValue) + be16(0) + body)
    else { return XCTFail("expected MEMORY_OBJECT") }
    XCTAssertEqual(short.length, 0x8000)
    XCTAssertNil(short.maximumSegmentLength)
    try assertDescriptorRoundTrips(be16(DescriptorType.memoryObject.rawValue) + be16(0) + body)

    body += be64(1400)
    let bytes = be16(DescriptorType.memoryObject.rawValue) + be16(0) + body
    guard case let (_, _, .memoryObject(object)) = try readDescriptorResponse(bytes) else {
      return XCTFail("expected MEMORY_OBJECT")
    }
    XCTAssertEqual(object.maximumSegmentLength, 1400)
    var context = SerializationContext()
    try Descriptor.memoryObject(object).serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes, bytes)
  }

  private func assertDescriptorRoundTrips(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
    let (_, _, descriptor) = try readDescriptorResponse(bytes)
    if case .other = descriptor {
      XCTFail("descriptor was not decoded", file: file, line: line)
    }
    var context = SerializationContext()
    try descriptor.serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes, bytes, file: file, line: line)
  }

  // IEEE 1722.1-2021 Table 7-7: SENSOR_UNIT ends with base_control_block, at 136 octets
  func testSensorUnitDescriptor() throws {
    let counts = (0..<UInt16(33)).flatMap { be16($0) } // clock_domain_index to base_control_block
    let body = fixedString("Sensor") + be16(0xFFFF) + counts
    let bytes = be16(DescriptorType.sensorUnit.rawValue) + be16(0) + body
    XCTAssertEqual(bytes.count, 136)
    guard case let (_, _, .sensorUnit(unit)) = try readDescriptorResponse(bytes) else {
      return XCTFail("expected SENSOR_UNIT")
    }
    XCTAssertEqual(unit.clockDomainIndex, 0)
    XCTAssertEqual(unit.baseControlBlock, 32)
    try assertDescriptorRoundTrips(bytes)
  }

  // IEEE 1722.1-2021 Table 7-29: six supported arrays following a 133-octet fixed part
  func testVideoClusterDescriptor() throws {
    var body = fixedString("Video 1") + be16(0xFFFF) + be16(DescriptorType.invalid.rawValue) + be16(0) + be16(0)
    body += be32(10) + be32(20) + [0x01] + be32(0x11) // latencies, format, current_format_specific
    body += be16(133) + be16(1) + be32(30) + be16(137) + be16(2) // format specifics, sampling rates
    body += be16(0x0101) + be16(145) + be16(1) // aspect ratios
    body += be32(0x0780_0438) + be16(147) + be16(1) // sizes
    body += be16(3) + be16(151) + be16(1) // color spaces
    body += be64(0x1E) + be16(153) + be16(1) // sampling rate ranges
    body += be32(0x11) + be32(30) + be32(60) + be16(0x0101) + be32(0x0780_0438) + be16(3) + be64(0x1E)
    let bytes = be16(DescriptorType.videoCluster.rawValue) + be16(0) + body
    guard case let (_, _, .videoCluster(cluster)) = try readDescriptorResponse(bytes) else {
      return XCTFail("expected VIDEO_CLUSTER")
    }
    XCTAssertEqual(cluster.supportedSamplingRates.map(\.rawValue), [30, 60])
    XCTAssertEqual(cluster.supportedSizes, [0x0780_0438])
    XCTAssertEqual(cluster.currentSamplingRateRange, 0x1E)
    XCTAssertEqual(cluster.supportedSamplingRateRanges, [0x1E])
    try assertDescriptorRoundTrips(bytes)
  }

  // IEEE 1722.1-2021 Tables 7-51 to 7-53: the combiner map's count precedes its offset
  func testSignalCombinerDescriptor() throws {
    var body = fixedString("Combiner") + be16(0xFFFF) + be32(1) + be32(2) + be16(0)
    body += be16(1) + be16(88) + be16(94) + be16(2) // combiner_map count and offset, sources
    body += be16(0) + be16(2) + be16(1) // sub_signal_start, sub_signal_count, input_index
    body += be16(DescriptorType.audioCluster.rawValue) + be16(0) + be16(0)
    body += be16(DescriptorType.audioCluster.rawValue) + be16(1) + be16(0)
    let bytes = be16(DescriptorType.signalCombiner.rawValue) + be16(0) + body
    guard case let (_, _, .signalCombiner(combiner)) = try readDescriptorResponse(bytes) else {
      return XCTFail("expected SIGNAL_COMBINER")
    }
    XCTAssertEqual(combiner.combinerMap, [SubSignalMapping(subSignalStart: 0, subSignalCount: 2, index: 1)])
    XCTAssertEqual(combiner.sources.map(\.signalIndex), [0, 1])
    try assertDescriptorRoundTrips(bytes)
  }

  // IEEE 1722.1-2021 Table 7-42: sources, then the packed value
  func testMixerDescriptor() throws {
    var body = fixedString("Mixer") + be16(0xFFFF) + be32(1) + be32(2) + be16(0)
    body += be16(ControlValueType(.linearUInt8).rawValue) + be16(88) + be16(1) + be16(94)
    body += be16(DescriptorType.audioCluster.rawValue) + be16(0) + be16(0)
    body += [0x00, 0xFF, 0x01, 0x80, 0x00] // minimum, maximum, step, default, current
    let bytes = be16(DescriptorType.mixer.rawValue) + be16(0) + body
    guard case let (_, _, .mixer(mixer)) = try readDescriptorResponse(bytes) else {
      return XCTFail("expected MIXER")
    }
    XCTAssertEqual(mixer.controlValueType.kind, .linearUInt8)
    XCTAssertEqual(mixer.sources.count, 1)
    XCTAssertEqual(mixer.valuesData, [0x00, 0xFF, 0x01, 0x80, 0x00])
    try assertDescriptorRoundTrips(bytes)
  }

  func testMatrixSignalAndControlBlockDescriptors() throws {
    // Table 7-47: signals_count precedes signals_offset
    let signals = be16(2) + be16(8) + be16(DescriptorType.audioCluster.rawValue) + be16(0) + be16(0) +
      be16(DescriptorType.audioCluster.rawValue) + be16(1) + be16(0)
    try assertDescriptorRoundTrips(be16(DescriptorType.matrixSignal.rawValue) + be16(0) + signals)

    // Table 7-62
    let block = fixedString("Block") + be16(0xFFFF) + be16(4) + be16(0) + be16(3) +
      be16(DescriptorType.invalid.rawValue) + be16(0) + be16(0)
    try assertDescriptorRoundTrips(be16(DescriptorType.controlBlock.rawValue) + be16(0) + block)
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
    XCTAssertNil(shortDescriptor.numberOfControls)
    XCTAssertNil(shortDescriptor.baseControl)
    try assertDescriptorRoundTrips(be16(DescriptorType.avbInterface.rawValue) + be16(0) + body)
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
    // flags: CAN_SET_ENABLE and CAN_SET_LINK_DELAY_THRESHOLD (bits 31 and 30)
    let body = fixedString("PTP 1") + be16(0xFFFF) + be16(1) + be16(2) + be32(3) + be16(0) +
      [0x00, 0x80, 0xC2, 0x00, 0x01, 0x00]
    let bytes = be16(DescriptorType.ptpPort.rawValue) + be16(0) + body
    guard case let (_, _, .ptpPort(descriptor)) = try readDescriptorResponse(bytes) else {
      return XCTFail("expected PTP_PORT")
    }
    XCTAssertEqual(UInt64(eui48: descriptor.profileIdentifier), 0x0080_C200_0100)
    XCTAssertEqual(descriptor.flags, [.canSetEnable, .canSetLinkDelayThreshold])
    var context = SerializationContext()
    try Descriptor.ptpPort(descriptor).serialize(descriptorIndex: 0, into: &context)
    XCTAssertEqual(context.bytes, bytes)

    let mutations: [(String, (inout PtpPortDescriptor) -> ())] = [
      ("objectName", { $0.objectName = "" }),
      ("localizedDescription", { $0.localizedDescription = LocalizedStringReference(rawValue: 0) }),
      ("portNumber", { $0.portNumber = 0 }),
      ("portType", { $0.portType = .p2pLinkLayer }),
      ("flags", { $0.flags = [] }),
      ("avbInterfaceIndex", { $0.avbInterfaceIndex = 1 }),
      ("profileIdentifier", { $0.profileIdentifier[5] = 1 }),
    ]
    assertEveryFieldIsCompared(descriptor, mutations)
  }
}
