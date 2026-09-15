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

private func parse(_ bytes: [UInt8]) throws -> AvdeccPdu {
  try bytes.withParserSpan { try AvdeccPdu(parsing: &$0) }
}

final class PduTests: XCTestCase {
  // An ENTITY_AVAILABLE written out field by field from IEEE 1722.1-2021 §6.2.1.
  let entityAvailable: [UInt8] = [
    0xFA, 0x00, 0x50, 0x38, // subtype, sv/version/message_type, valid_time 10, cdl 56
    0x00, 0x1B, 0x92, 0xFF, 0xFE, 0x01, 0x02, 0x03, // entity_id
    0x00, 0x1B, 0x92, 0x00, 0x00, 0x00, 0x00, 0x42, // entity_model_id
    0x00, 0x00, 0x05, 0x08, // entity_capabilities: AEM | CLASS_A | GPTP
    0x00, 0x02, 0x40, 0x01, // talker_stream_sources 2, AUDIO_SOURCE | IMPLEMENTED
    0x00, 0x04, 0x40, 0x01, // listener_stream_sinks 4, AUDIO_SINK | IMPLEMENTED
    0x00, 0x00, 0x00, 0x00, // controller_capabilities
    0x00, 0x00, 0x00, 0x07, // available_index
    0x00, 0x1B, 0x92, 0xFF, 0xFE, 0xAA, 0xBB, 0xCC, // gptp_grandmaster_id
    0x05, 0x00, 0x00, 0x00, // gptp_domain_number 5, reserved0
    0x00, 0x00, 0x00, 0x01, // identify_control_index, interface_index 1
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // association_id
    0x00, 0x00, 0x00, 0x00, // reserved1
  ]

  func testAdpduParse() throws {
    guard case let .adp(adpdu) = try parse(entityAvailable) else {
      return XCTFail("expected ADPDU")
    }
    XCTAssertEqual(adpdu.messageType, .entityAvailable)
    XCTAssertEqual(adpdu.validTime, 10)
    XCTAssertEqual(adpdu.entityID, UniqueIdentifier(0x001B_92FF_FE01_0203))
    XCTAssertEqual(adpdu.entityModelID, UniqueIdentifier(0x001B_9200_0000_0042))
    XCTAssertEqual(adpdu.entityCapabilities, [.aemSupported, .classASupported, .gptpSupported])
    XCTAssertEqual(adpdu.talkerStreamSources, 2)
    XCTAssertEqual(adpdu.talkerCapabilities, [.implemented, .audioSource])
    XCTAssertEqual(adpdu.listenerStreamSinks, 4)
    XCTAssertEqual(adpdu.listenerCapabilities, [.implemented, .audioSink])
    XCTAssertEqual(adpdu.availableIndex, 7)
    XCTAssertEqual(adpdu.gptpGrandmasterID, UniqueIdentifier(0x001B_92FF_FEAA_BBCC))
    XCTAssertEqual(adpdu.gptpDomainNumber, 5)
    XCTAssertEqual(adpdu.interfaceIndex, 1)
  }

  func testAdpduRoundTrip() throws {
    guard case let .adp(adpdu) = try parse(entityAvailable) else {
      return XCTFail("expected ADPDU")
    }
    XCTAssertEqual(try adpdu.serialized(), entityAvailable)
  }

  func testAdpduCurrentConfigurationIndex() throws {
    var bytes = entityAvailable
    // entity_capabilities: AEM_CONFIGURATION_INDEX_VALID (bit 6) | AEM | CLASS_A | GPTP
    bytes[20...23] = [0x02, 0x00, 0x05, 0x08]
    // gptp_domain_number 5, reserved0, current_configuration_index 3 (IEEE 1722.1-2021 §6.2.1)
    bytes[48...51] = [0x05, 0x00, 0x00, 0x03]
    guard case let .adp(adpdu) = try parse(bytes) else {
      return XCTFail("expected ADPDU")
    }
    XCTAssertTrue(adpdu.entityCapabilities.contains(.aemConfigurationIndexValid))
    XCTAssertEqual(adpdu.gptpDomainNumber, 5)
    XCTAssertEqual(adpdu.currentConfigurationIndex, 3)
    XCTAssertEqual(try adpdu.serialized(), bytes)
  }

  func testAdpduIgnoresEthernetPadding() throws {
    // frames shorter than the Ethernet minimum are padded; control_data_length bounds the PDU
    guard case .adp = try parse(entityAvailable + [0, 0, 0, 0]) else {
      return XCTFail("expected ADPDU")
    }
  }

  func testAdpduRejectsShortControlDataLength() {
    var bytes = entityAvailable
    bytes[3] = 0x37
    XCTAssertThrowsError(try parse(bytes))
  }

  func testAcmpduRoundTrip() throws {
    let acmpdu = Acmpdu(
      messageType: .connectRxCommand,
      controllerEntityID: UniqueIdentifier(0x0200_00FF_FE00_0001),
      talkerEntityID: UniqueIdentifier(0x001B_92FF_FE01_0203),
      listenerEntityID: UniqueIdentifier(0x001B_92FF_FE04_0506),
      talkerUniqueID: 1,
      listenerUniqueID: 2,
      sequenceID: 0x1234,
      flags: [.classB]
    )
    let bytes = try acmpdu.serialized()
    XCTAssertEqual(bytes.count, AvtpduControlHeader.length + Int(Acmpdu.length))
    XCTAssertEqual(Array(bytes[0..<4]), [0xFC, 0x06, 0x00, 0x2C])
    XCTAssertEqual(try parse(bytes), .acmp(acmpdu))
  }

  // IEEE 1722.1-2021 adds connected_listeners_entries in the 2013 reserved field, and IP fields
  // that lengthen control_data_length to 84 (Figure 8-1)
  func testAcmpduIeee2021Fields() throws {
    let sourceIPAddress = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 192, 168, 1, 2]
    let acmpdu = Acmpdu(
      messageType: .getTxStateResponse,
      talkerEntityID: UniqueIdentifier(0x001B_92FF_FE01_0203),
      flags: [.clEntriesValid],
      connectedListenersEntries: 3,
      sourcePort: 17220,
      sourceIPAddress: sourceIPAddress
    )
    let bytes = try acmpdu.serialized()
    XCTAssertEqual(bytes.count, AvtpduControlHeader.length + Int(Acmpdu.ieee2021Length))
    XCTAssertEqual(Array(bytes[54..<56]), [0x00, 0x03]) // connected_listeners_entries
    XCTAssertEqual(Array(bytes[60..<62]), [0x43, 0x44]) // source_port
    XCTAssertEqual(Array(bytes[64..<80]), sourceIPAddress)
    XCTAssertEqual(try parse(bytes), .acmp(acmpdu))

    // without IP fields the 1722.1-2013 length is sent
    let short = Acmpdu(messageType: .getTxStateResponse, connectedListenersEntries: 3)
    let shortBytes = try short.serialized()
    XCTAssertEqual(shortBytes.count, AvtpduControlHeader.length + Int(Acmpdu.length))
    XCTAssertEqual(try parse(shortBytes), .acmp(short))
  }

  func testAemAecpduRoundTrip() throws {
    let aem = AemAecpdu(
      isResponse: false,
      targetEntityID: UniqueIdentifier(0x001B_92FF_FE01_0203),
      controllerEntityID: UniqueIdentifier(0x0200_00FF_FE00_0001),
      sequenceID: 7,
      commandType: .readDescriptor,
      commandSpecificData: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    )
    let bytes = try Aecpdu.aem(aem).serialized()
    // cdl = controller_entity_id + sequence_id + command_type + 8
    XCTAssertEqual(Array(bytes[0..<4]), [0xFB, 0x00, 0x00, 0x14])
    XCTAssertEqual(Array(bytes[22..<24]), [0x00, 0x04])
    XCTAssertEqual(try parse(bytes), .aecp(.aem(aem)))
  }

  func testUnsolicitedAemResponse() throws {
    var aem = AemAecpdu(
      isResponse: true,
      targetEntityID: UniqueIdentifier(1),
      controllerEntityID: UniqueIdentifier(2),
      unsolicited: true,
      commandType: .getStreamInfo
    )
    aem.commandTypeRaw = 0x000F
    let bytes = try Aecpdu.aem(aem).serialized()
    XCTAssertEqual(bytes[1], 0x01)
    XCTAssertEqual(Array(bytes[22..<24]), [0x80, 0x0F])
    guard case let .aecp(.aem(parsed)) = try parse(bytes) else {
      return XCTFail("expected AEM AECPDU")
    }
    XCTAssertTrue(parsed.unsolicited)
    XCTAssertEqual(parsed.commandType, .getStreamInfo)
  }

  func testMvuAecpduRoundTrip() throws {
    let mvu = MvuAecpdu(
      isResponse: false,
      targetEntityID: UniqueIdentifier(0x001B_92FF_FE01_0203),
      controllerEntityID: UniqueIdentifier(0x0200_00FF_FE00_0001),
      sequenceID: 9,
      commandType: .getMilanInfo,
      commandSpecificData: [0x00, 0x00]
    )
    let bytes = try Aecpdu.mvu(mvu).serialized()
    XCTAssertEqual(bytes[1], AecpMessageType.vendorUniqueCommand.rawValue)
    XCTAssertEqual(Array(bytes[22..<28]), [0x00, 0x1B, 0xC5, 0x0A, 0xC1, 0x00])
    XCTAssertEqual(try parse(bytes), .aecp(.mvu(mvu)))
  }

  func testOtherVendorUniqueAecpduKeepsProtocolIdentifier() throws {
    // a VENDOR_UNIQUE_COMMAND for a protocol other than Milan's (IEEE 1722.1-2021 §9.2.1.3)
    let bytes: [UInt8] = [
      0xFB, 0x06, 0x00, 0x12, // subtype, message_type VENDOR_UNIQUE_COMMAND, cdl 18
      0x00, 0x1B, 0x92, 0xFF, 0xFE, 0x01, 0x02, 0x03, // target_entity_id
      0x02, 0x00, 0x00, 0xFF, 0xFE, 0x00, 0x00, 0x01, // controller_entity_id
      0x00, 0x05, // sequence_id
      0x00, 0x1B, 0x92, 0x00, 0x00, 0x01, // protocol_id
      0xDE, 0xAD,
    ]
    let pdu = try parse(bytes)
    guard case let .aecp(.other(messageType, _, _, _, sequenceID, specificData)) = pdu else {
      return XCTFail("expected an undecoded AECPDU")
    }
    XCTAssertEqual(messageType, AecpMessageType.vendorUniqueCommand.rawValue)
    XCTAssertEqual(sequenceID, 5)
    XCTAssertEqual(specificData, [0x00, 0x1B, 0x92, 0x00, 0x00, 0x01, 0xDE, 0xAD])
    XCTAssertEqual(try pdu.serialized(), bytes)
  }
}

extension PduTests {
  // IEEE 1722.1-2021 Table 7-140 after GET_MAX_TRANSIT_TIME, with 0x005A reserved
  func testAemCommandTypesAfterMaxTransitTime() {
    XCTAssertEqual(AemCommandType(rawValue: 0x004E), .setSamplingRateRange)
    XCTAssertEqual(AemCommandType(rawValue: 0x0059), .getPtpPortInitialIntervals)
    XCTAssertNil(AemCommandType(rawValue: 0x005A))
    XCTAssertEqual(AemCommandType(rawValue: 0x005B), .getPtpPortCurrentIntervals)
    XCTAssertEqual(AemCommandType(rawValue: 0x0068), .authAddKeyNonce)
  }

  func testAemControllerRequestFlag() throws {
    var aem = AemAecpdu(
      isResponse: true,
      targetEntityID: UniqueIdentifier(1),
      controllerEntityID: UniqueIdentifier(2),
      unsolicited: true,
      commandType: .setName
    )
    aem.controllerRequest = true
    let bytes = try AvdeccPdu.aecp(.aem(aem)).serialized()
    // u, cr and the 14-bit command_type follow the AVTP control header, controller_entity_id and
    // sequence_id (IEEE 1722.1-2021 §9.3.2)
    XCTAssertEqual(Array(bytes[22..<24]), [0xC0, 0x10])

    guard case let .aecp(.aem(parsed)) = try parse(bytes) else { return XCTFail("not an AEM AECPDU") }
    XCTAssertEqual(parsed.commandType, .setName)
    XCTAssertTrue(parsed.unsolicited)
    XCTAssertTrue(parsed.controllerRequest)
  }
}
