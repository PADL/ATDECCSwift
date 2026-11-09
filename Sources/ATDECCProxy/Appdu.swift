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

/// The APP version this implementation speaks (IEEE 1722.1-2021 Clause C.4.1).
public let AppVersion: UInt8 = 0

/// The message_type of an APPDU (IEEE 1722.1-2021 Clause C.4.2, Table C.4). Values 0x07 to
/// 0xFD are reserved.
public struct AppMessageType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let nop = AppMessageType(rawValue: 0x00)
  public static let entityIDRequest = AppMessageType(rawValue: 0x01)
  public static let entityIDResponse = AppMessageType(rawValue: 0x02)
  public static let linkUp = AppMessageType(rawValue: 0x03)
  public static let linkDown = AppMessageType(rawValue: 0x04)
  public static let atdeccFromAps = AppMessageType(rawValue: 0x05)
  public static let atdeccFromApc = AppMessageType(rawValue: 0x06)
  public static let vendor = AppMessageType(rawValue: 0xFF)

  public var description: String {
    switch self {
    case .nop: "NOP"
    case .entityIDRequest: "ENTITY_ID_REQUEST"
    case .entityIDResponse: "ENTITY_ID_RESPONSE"
    case .linkUp: "LINK_UP"
    case .linkDown: "LINK_DOWN"
    case .atdeccFromAps: "ATDECC_FROM_APS"
    case .atdeccFromApc: "ATDECC_FROM_APC"
    case .vendor: "VENDOR"
    default: "RESERVED(0x\(String(rawValue, radix: 16)))"
    }
  }
}

/// Why bytes are not an APPDU.
public enum AppduError: Error, Equatable, Sendable {
  /// The version field is not one this implementation speaks (Clause C.4.1).
  case unsupportedVersion(UInt8)
  /// payload_length exceeds 1500 (Clause C.4.3).
  case payloadTooLong(Int)
  /// A message whose payload has a fixed length has another (Clause C.4.5, Table C.6).
  case invalidPayloadLength(AppMessageType, Int)
  /// Fewer octets than the header and its payload.
  case truncated
}

/// An ATDECC Proxy Protocol data unit (IEEE 1722.1-2021 Clause C.4, Figure C.1): a 12-octet
/// header, then up to 1500 octets of payload.
public struct Appdu: Sendable, CustomStringConvertible {
  public static let headerLength = 12
  public static let maximumPayloadLength = 1500

  public var version: UInt8
  public var messageType: AppMessageType
  /// What the address means depends on the message type (Clause C.4.4, Table C.5).
  public var address: EUI48
  public var payload: [UInt8]

  public init(
    version: UInt8 = AppVersion,
    messageType: AppMessageType,
    address: EUI48 = [0, 0, 0, 0, 0, 0],
    payload: [UInt8] = []
  ) {
    self.version = version
    self.messageType = messageType
    self.address = address
    self.payload = payload
  }

  /// A NOP (Clause C.5.1.1).
  public static var nop: Appdu { Appdu(messageType: .nop) }

  /// An ENTITY_ID_REQUEST from an APC whose primary MAC address is `apcMacAddress`, for
  /// `entityID`, or zero for none (Clause C.5.1.2).
  public static func entityIDRequest(apcMacAddress: EUI48, entityID: UniqueIdentifier) -> Appdu {
    Appdu(messageType: .entityIDRequest, address: apcMacAddress, payload: entityIDPayload(entityID))
  }

  /// An ENTITY_ID_RESPONSE assigning `entityID` to the APC at `apcMacAddress` (Clause C.5.1.3).
  public static func entityIDResponse(apcMacAddress: EUI48, entityID: UniqueIdentifier) -> Appdu {
    Appdu(messageType: .entityIDResponse, address: apcMacAddress, payload: entityIDPayload(entityID))
  }

  /// The payload of ENTITY_ID_REQUEST and ENTITY_ID_RESPONSE (Table C.6).
  private static func entityIDPayload(_ entityID: UniqueIdentifier) -> [UInt8] {
    var context = SerializationContext()
    context.serialize(uint64: entityID.rawValue)
    return context.bytes
  }

  /// LINK_UP or LINK_DOWN for the network port at `linkMacAddress` (Clauses C.5.1.4, C.5.1.5).
  public static func linkStatus(_ isUp: Bool, linkMacAddress: EUI48) -> Appdu {
    Appdu(messageType: isUp ? .linkUp : .linkDown, address: linkMacAddress)
  }

  /// ATDECC_FROM_APS carrying `avtpdu`, received from `sourceMacAddress` (Clause C.5.1.6).
  public static func atdeccFromAps(sourceMacAddress: EUI48, avtpdu: [UInt8]) -> Appdu {
    Appdu(messageType: .atdeccFromAps, address: sourceMacAddress, payload: avtpdu)
  }

  /// ATDECC_FROM_APC carrying `avtpdu`, for `destinationMacAddress` (Clause C.5.1.7).
  public static func atdeccFromApc(destinationMacAddress: EUI48, avtpdu: [UInt8]) -> Appdu {
    Appdu(messageType: .atdeccFromApc, address: destinationMacAddress, payload: avtpdu)
  }

  /// The entity ID in an ENTITY_ID_REQUEST or ENTITY_ID_RESPONSE.
  public var entityID: UniqueIdentifier? {
    guard messageType == .entityIDRequest || messageType == .entityIDResponse, payload.count == 8 else {
      return nil
    }
    return try? payload.withParserSpan { try UniqueIdentifier(parsing: &$0) }
  }

  /// The APPDU's octets. The payload must not exceed `maximumPayloadLength`: what arrives from
  /// the LAN is checked before it is put in an APPDU.
  public func serialized() -> [UInt8] {
    precondition(payload.count <= Self.maximumPayloadLength)
    var context = SerializationContext()
    serialize(into: &context)
    return context.bytes
  }

  /// The length of the APPDU at the start of `header`, the first `headerLength` octets of
  /// one, validating its version and payload_length.
  public static func length(ofHeader header: some Collection<UInt8>) throws(AppduError) -> Int {
    let header = try parse(Array(header.prefix(headerLength))) { try Header(parsing: &$0) }
    return headerLength + header.payloadLength
  }

  /// Parses one whole APPDU from `bytes`, which holds exactly its header and payload.
  public init(bytes: [UInt8]) throws(AppduError) {
    self = try Self.parse(bytes) { input in
      let appdu = try Appdu(parsing: &input)
      guard input.count == 0 else { throw AppduError.truncated }
      return appdu
    }
  }

  /// `body` over a parser of `bytes`, running out of which is `.truncated`.
  private static func parse<T>(_ bytes: [UInt8], _ body: (inout ParserSpan) throws -> T) throws(AppduError) -> T {
    do {
      return try bytes.withParserSpan(body)
    } catch let error as AppduError {
      throw error
    } catch {
      throw .truncated
    }
  }

  /// The payload lengths Table C.6 fixes.
  private func validatePayloadLength() throws(AppduError) {
    let expected: Int? = switch messageType {
    case .nop, .linkUp, .linkDown: 0
    case .entityIDRequest, .entityIDResponse: 8
    default: nil
    }
    if let expected, payload.count != expected {
      throw .invalidPayloadLength(messageType, payload.count)
    }
  }

  public var description: String {
    "Appdu(\(messageType), address: \(_macAddressToString(address)), payloadLength: \(payload.count))"
  }
}

extension Appdu {
  /// The APP header (Figure C.1), validated: version 0 and a payload of at most 1500 octets.
  private struct Header {
    var messageType: AppMessageType
    var payloadLength: Int
    var address: EUI48

    init(parsing input: inout ParserSpan) throws {
      let version = try UInt8(parsing: &input)
      guard version == AppVersion else { throw AppduError.unsupportedVersion(version) }
      messageType = try AppMessageType(rawValue: UInt8(parsing: &input))
      payloadLength = try Int(UInt16(parsingBigEndian: &input))
      guard payloadLength <= Appdu.maximumPayloadLength else { throw AppduError.payloadTooLong(payloadLength) }
      address = try _eui48(parsing: &input)
      _ = try UInt16(parsingBigEndian: &input) // reserved
    }
  }

  public init(parsing input: inout ParserSpan) throws {
    let header = try Header(parsing: &input)
    guard input.count >= header.payloadLength else { throw AppduError.truncated }
    self.init(
      messageType: header.messageType,
      address: header.address,
      payload: try Array(parsing: &input, byteCount: header.payloadLength)
    )
    try validatePayloadLength()
  }

  public func serialize(into context: inout SerializationContext) {
    context.serialize(uint8: version)
    context.serialize(uint8: messageType.rawValue)
    context.serialize(uint16: UInt16(payload.count))
    context.serialize(eui48: address)
    context.serialize(uint16: 0) // reserved
    context.serialize(payload)
  }
}

/// Splits a TCP byte stream into APPDUs.
public struct AppduStreamDecoder: Sendable {
  private var buffer = [UInt8]()

  public init() {}

  /// Octets received but not yet part of a whole APPDU.
  public var bufferedCount: Int { buffer.count }

  /// Appends `bytes` and returns the APPDUs now complete, in order. A malformed APPDU throws;
  /// the stream cannot be resynchronised after one, so the connection should be closed.
  public mutating func decode(_ bytes: [UInt8]) throws(AppduError) -> [Appdu] {
    buffer.append(contentsOf: bytes)
    var appdus = [Appdu]()
    var start = 0
    while buffer.count - start >= Appdu.headerLength {
      let length = try Appdu.length(ofHeader: buffer[start..<(start + Appdu.headerLength)])
      guard buffer.count - start >= length else { break }
      try appdus.append(Appdu(bytes: Array(buffer[start..<(start + length)])))
      start += length
    }
    buffer.removeFirst(start)
    return appdus
  }
}

//
// AVTPDUs - Clause C.4.5, Table C.7
//

/// The AVTPDU subtypes an APS transfers (IEEE 1722.1-2021 Clause C.4.5, Table C.7): ADP, AECP
/// and ACMP.
public let AppAvtpduSubtypes: ClosedRange<UInt8> = AvtpSubtype.adp.rawValue...AvtpSubtype.acmp.rawValue

/// Whether `avtpdu` is an AVTP control PDU with one of the subtypes of Table C.7.
public func isAppAvtpdu(_ avtpdu: some Collection<UInt8>) -> Bool {
  guard avtpdu.count >= AvtpduControlHeader.length, let subtype = avtpdu.first else { return false }
  return AppAvtpduSubtypes.contains(subtype)
}
