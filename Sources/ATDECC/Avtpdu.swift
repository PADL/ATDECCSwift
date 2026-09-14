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

import BinaryParsing
import IEEE802

/// AVTP subtypes of the AVDECC control protocols (IEEE 1722-2016 Table 6).
public enum AvtpSubtype: UInt8, Sendable {
  case adp = 0xFA
  case aecp = 0xFB
  case acmp = 0xFC
  case maap = 0xFE
}

/// The AVTP control header shared by ADP, AECP and ACMP (IEEE 1722-2016 §4.4.3,
/// IEEE 1722.1-2021 §6.2.1, §8.2.1, §9.2.1). The meaning of `controlData`, `status` and
/// `streamID` depends on the protocol: for example ADP carries message_type, valid_time and
/// entity_id in them.
public struct AvtpduControlHeader: Sendable, Hashable {
  public static let length = 12

  public var subtype: UInt8
  /// The `sv` (stream_valid) / header-specific bit.
  public var streamValid: Bool
  public var version: UInt8
  /// Four-bit control_data; the message_type in AVDECC protocols.
  public var controlData: UInt8
  /// Five-bit status.
  public var status: UInt8
  /// Eleven-bit control_data_length: the octets following `streamID`.
  public var controlDataLength: UInt16
  public var streamID: UInt64

  public init(
    subtype: AvtpSubtype,
    controlData: UInt8,
    status: UInt8,
    controlDataLength: UInt16,
    streamID: UInt64
  ) {
    self.subtype = subtype.rawValue
    streamValid = false
    version = 0
    self.controlData = controlData
    self.status = status
    self.controlDataLength = controlDataLength
    self.streamID = streamID
  }
}

extension AvtpduControlHeader: SerDes {
  public init(parsing input: inout ParserSpan) throws {
    subtype = try UInt8(parsing: &input)
    let svVersionControlData = try UInt8(parsing: &input)
    streamValid = svVersionControlData & 0x80 != 0
    version = (svVersionControlData & 0x70) >> 4
    controlData = svVersionControlData & 0x0F
    let statusControlDataLength = try UInt16(parsingBigEndian: &input)
    status = UInt8(statusControlDataLength >> 11)
    controlDataLength = statusControlDataLength & 0x07FF
    streamID = try UInt64(parsingBigEndian: &input)
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint8: subtype)
    serializationContext.serialize(
      uint8: (streamValid ? 0x80 : 0) | ((version & 0x07) << 4) | (controlData & 0x0F)
    )
    serializationContext.serialize(
      uint16: (UInt16(status & 0x1F) << 11) | (controlDataLength & 0x07FF)
    )
    serializationContext.serialize(uint64: streamID)
  }
}

/// Any AVDECC PDU carried in an AVTP frame.
public enum AvdeccPdu: Sendable, Hashable {
  case adp(Adpdu)
  case aecp(Aecpdu)
  case acmp(Acmpdu)
}

extension AvdeccPdu: SerDes {
  public init(parsing input: inout ParserSpan) throws {
    var probe = ParserSpan(input.bytes)
    let subtype = try UInt8(parsing: &probe)

    switch AvtpSubtype(rawValue: subtype) {
    case .adp:
      self = try .adp(Adpdu(parsing: &input))
    case .aecp:
      self = try .aecp(Aecpdu(parsing: &input))
    case .acmp:
      self = try .acmp(Acmpdu(parsing: &input))
    default:
      throw AvdeccCodecError.unexpectedSubtype(subtype)
    }
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    switch self {
    case let .adp(adpdu):
      try adpdu.serialize(into: &serializationContext)
    case let .aecp(aecpdu):
      try aecpdu.serialize(into: &serializationContext)
    case let .acmp(acmpdu):
      try acmpdu.serialize(into: &serializationContext)
    }
  }
}

extension ParserSpan {
  /// Parses an AVTP control header, verifying its subtype and that its control_data_length is
  /// at least `minimumControlDataLength` and fits within the remaining bytes.
  mutating func parseAvtpduControlHeader(
    subtype: AvtpSubtype,
    minimumControlDataLength: Int
  ) throws -> AvtpduControlHeader {
    let header = try AvtpduControlHeader(parsing: &self)
    guard header.subtype == subtype.rawValue else {
      throw AvdeccCodecError.unexpectedSubtype(header.subtype)
    }
    // la_avdecc rejects PDUs that under-report their length, and those that claim more than
    // was received; trailing octets (Ethernet padding) beyond control_data_length are ignored
    guard Int(header.controlDataLength) >= minimumControlDataLength,
          Int(header.controlDataLength) <= count
    else {
      throw AvdeccCodecError.invalidControlDataLength(header.controlDataLength)
    }
    return header
  }
}
