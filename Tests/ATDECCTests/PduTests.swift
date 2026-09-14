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
}
