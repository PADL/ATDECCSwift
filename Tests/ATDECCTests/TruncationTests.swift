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

// an ENTITY_AVAILABLE: the AVTP control header and entity_id, then control_data_length octets
private let entityAvailable: [UInt8] = [0xFA, 0x00, 0x50, 0x38, 0x00, 0x1B, 0x92, 0xFF, 0xFE, 0x01, 0x02, 0x03] +
  [UInt8](repeating: 0, count: 56)

/// PDUs arrive from the network, so a short or inconsistent one has to throw: a trap in a
/// parser ends the test process, which is how these tests fail.
final class TruncationTests: XCTestCase {
  private func validPdus() throws -> [[UInt8]] {
    let target = UniqueIdentifier(0x001B_92FF_FE01_0203), controller = UniqueIdentifier(0x0200_00FF_FE00_0001)
    let ipAddress = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 192, 168, 1, 2]
    return try [
      entityAvailable,
      Acmpdu(messageType: .connectRxCommand, controllerEntityID: controller, talkerEntityID: target).serialized(),
      Acmpdu(messageType: .getTxStateResponse, talkerEntityID: target, sourceIPAddress: ipAddress).serialized(),
      Aecpdu.aem(AemAecpdu(
        isResponse: false, targetEntityID: target, controllerEntityID: controller, sequenceID: 7,
        commandType: .readDescriptor, commandSpecificData: [UInt8](repeating: 0, count: 8)
      )).serialized(),
      Aecpdu.mvu(MvuAecpdu(
        isResponse: false, targetEntityID: target, controllerEntityID: controller, sequenceID: 9,
        commandType: .getMilanInfo, commandSpecificData: [0, 0]
      )).serialized(),
    ]
  }

  func testEveryPrefixOfAPduIsRejected() throws {
    for pdu in try validPdus() {
      XCTAssertNoThrow(try parse(pdu))
      for length in 0..<pdu.count {
        XCTAssertThrowsError(try parse(Array(pdu[..<length])), "\(length) of \(pdu.count) octets")
      }
    }
  }

  func testEveryControlDataLengthIsHandled() throws {
    for pdu in try validPdus() {
      // the 11-bit control_data_length, shorter and longer than the octets that follow
      for controlDataLength in 0...0x7FF {
        var bytes = pdu
        bytes[2] = (bytes[2] & 0xF8) | UInt8(controlDataLength >> 8)
        bytes[3] = UInt8(controlDataLength & 0xFF)
        _ = try? parse(bytes)
        if controlDataLength > pdu.count - AvtpduControlHeader.length {
          XCTAssertThrowsError(try parse(bytes), "control_data_length \(controlDataLength)")
        }
      }
    }
  }

  /// Zeros, counts and offsets of two, and counts and offsets of 65535, at every length.
  func testEveryPayloadLengthIsHandled() {
    let patterns: [[UInt8]] = [[0x00], [0x00, 0x02], [0xFF]]
    for pattern in patterns {
      let buffer = (0..<524).map { pattern[$0 % pattern.count] }
      for length in Array(0...200) + [524] {
        let data = Array(buffer[..<length])
        for commandType in UInt16(0)...0x0070 {
          _ = try? AemCommandPayload(commandTypeRaw: commandType, data: data)
          _ = try? AemResponsePayload(commandTypeRaw: commandType, data: data)
        }
        for commandType in UInt16(0)...0x0010 {
          _ = try? MvuCommandPayload(commandTypeRaw: commandType, data: data)
          _ = try? MvuResponsePayload(commandTypeRaw: commandType, data: data)
        }
      }
    }
  }

  // counts that run past the payload: GET_AS_PATH, GET_AVB_INFO and GET_COUNTERS
  func testCountsPastThePayloadAreRejected() {
    let asPath: [UInt8] = [0, 0, 0, 100] + [UInt8](repeating: 0, count: 8)
    XCTAssertThrowsError(try AemResponsePayload(commandTypeRaw: AemCommandType.getAsPath.rawValue, data: asPath))
    // descriptor, gptp_grandmaster_id, propagation_delay, gptp_domain_number, flags, 100 mappings
    let avbInfo: [UInt8] = [0, 9, 0, 0] + [UInt8](repeating: 0, count: 12) + [0, 0, 0, 100, 0, 0, 0, 0]
    XCTAssertThrowsError(try AemResponsePayload(commandTypeRaw: AemCommandType.getAvbInfo.rawValue, data: avbInfo))
    let counters = [UInt8](repeating: 0, count: 135)
    XCTAssertThrowsError(try AemResponsePayload(commandTypeRaw: AemCommandType.getCounters.rawValue, data: counters))
  }
}
