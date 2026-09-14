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

// MARK: - Constants

/// EtherType of IEEE 1722 AVTP frames, which carry ADP, AECP and ACMP (IEEE 1722-2016 §5.1).
public let AvtpEtherType: UInt16 = 0x22F0

/// Destination of ADP and ACMP messages (IEEE 1722.1-2021 Annex B).
public let AvdeccMulticastMacAddress: EUI48 = [0x91, 0xE0, 0xF0, 0x01, 0x00, 0x00]

/// Destination of IDENTIFY notifications (IEEE 1722.1-2021 Annex B, §7.5.1).
public let AvdeccIdentifyMulticastMacAddress: EUI48 = [0x91, 0xE0, 0xF0, 0x01, 0x00, 0x01]

/// Length in octets of the fixed-size UTF-8 strings used throughout AEM (IEEE 1722.1-2021 §7.3.5).
public let AvdeccFixedStringLength = 64

// MARK: - Errors

/// Reasons a received AVDECC PDU could not be decoded.
public enum AvdeccCodecError: Error, Sendable, Hashable {
  case unexpectedSubtype(UInt8)
  case unexpectedMessageType(UInt8)
  case invalidControlDataLength(UInt16)
  case payloadTooShort(expected: Int, actual: Int)
  case invalidOffset(Int)
  case valueTooLarge
}

// MARK: - UniqueIdentifier

/// An EUI-64 identifying an entity, entity model, stream or clock (IEEE 1722.1-2021 §6.2.1.8).
public struct UniqueIdentifier: RawRepresentable, Sendable, Hashable, Comparable,
  CustomStringConvertible
{
  public let rawValue: UInt64

  /// The zero identifier.
  public init() {
    rawValue = 0
  }

  public init(_ rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  /// The all-ones EUI-64, used on the wire to mean "no entity".
  public static let null = UniqueIdentifier(0xFFFF_FFFF_FFFF_FFFF)

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// IEEE EUI-64 in lowercase hex, zero-padded to 16 digits.
  public var description: String { rawValue.paddedHex(width: 16) }
}

extension UniqueIdentifier: SerDes {
  public init(parsing input: inout ParserSpan) throws {
    try self.init(UInt64(parsingBigEndian: &input))
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint64: rawValue)
  }
}

// MARK: - Descriptor type and index

/// 16-bit AEM descriptor index (IEEE 1722.1-2021 §7.2).
public typealias DescriptorIndex = UInt16

/// AEM descriptor type codes (IEEE 1722.1-2021 Table 7-1). Codes outside this set decode to
/// `.invalid`.
public enum DescriptorType: UInt16, Sendable, CaseIterable {
  case entity = 0x0000
  case configuration = 0x0001
  case audioUnit = 0x0002
  case videoUnit = 0x0003
  case sensorUnit = 0x0004
  case streamInput = 0x0005
  case streamOutput = 0x0006
  case jackInput = 0x0007
  case jackOutput = 0x0008
  case avbInterface = 0x0009
  case clockSource = 0x000A
  case memoryObject = 0x000B
  case locale = 0x000C
  case strings = 0x000D
  case streamPortInput = 0x000E
  case streamPortOutput = 0x000F
  case externalPortInput = 0x0010
  case externalPortOutput = 0x0011
  case internalPortInput = 0x0012
  case internalPortOutput = 0x0013
  case audioCluster = 0x0014
  case videoCluster = 0x0015
  case sensorCluster = 0x0016
  case audioMap = 0x0017
  case videoMap = 0x0018
  case sensorMap = 0x0019
  case control = 0x001A
  case signalSelector = 0x001B
  case mixer = 0x001C
  case matrix = 0x001D
  case matrixSignal = 0x001E
  case signalSplitter = 0x001F
  case signalCombiner = 0x0020
  case signalDemultiplexer = 0x0021
  case signalMultiplexer = 0x0022
  case signalTranscoder = 0x0023
  case clockDomain = 0x0024
  case controlBlock = 0x0025
  case timing = 0x0026
  case ptpInstance = 0x0027
  case ptpPort = 0x0028
  case invalid = 0xFFFF
}

extension DescriptorType: SerDes {
  public init(parsing input: inout ParserSpan) throws {
    self = try DescriptorType(rawValue: UInt16(parsingBigEndian: &input)) ?? .invalid
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint16: rawValue)
  }
}

// MARK: - Localized strings

/// A reference into a locale's STRINGS descriptors (IEEE 1722.1-2021 §7.3.6): bits 15..3
/// select the STRINGS descriptor relative to the locale's base, bits 2..0 the string.
public struct LocalizedStringReference: Sendable, Hashable {
  public let rawValue: UInt16

  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let none = LocalizedStringReference(rawValue: 0xFFFF)
  public var isValid: Bool { rawValue != 0xFFFF }
  /// Index across the locale's strings, seven per STRINGS descriptor.
  public var globalOffset: UInt16 { (rawValue >> 3) * 7 + (rawValue & 0x7) }
}

extension LocalizedStringReference: SerDes {
  public init(parsing input: inout ParserSpan) throws {
    try self.init(rawValue: UInt16(parsingBigEndian: &input))
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint16: rawValue)
  }
}

// MARK: - Sampling rate

/// Sampling rate (IEEE 1722.1-2021 §7.3.1). Upper 3 bits are the "pull" multiplier; lower 29
/// bits are the base frequency in Hz.
public struct SamplingRate: Sendable, Hashable, CustomStringConvertible {
  public let rawValue: UInt32

  public init(_ rawValue: UInt32) { self.rawValue = rawValue }
  public init(pull: UInt8, baseFrequency: UInt32) {
    rawValue = (UInt32(pull) << 29) | (baseFrequency & 0x1FFF_FFFF)
  }

  public var pull: UInt8 { UInt8(rawValue >> 29) }
  public var baseFrequency: UInt32 { rawValue & 0x1FFF_FFFF }
  public var isValid: Bool { baseFrequency != 0 }

  public var nominalSampleRate: Double {
    let f = Double(baseFrequency)
    switch pull {
    case 0: return f
    case 1: return f * 1.0 / 1.001
    case 2: return f * 1.001
    case 3: return f * 24.0 / 25.0
    case 4: return f * 25.0 / 24.0
    default: return f
    }
  }

  public var description: String {
    "SamplingRate(\(nominalSampleRate) Hz)"
  }
}

extension SamplingRate: SerDes {
  public init(parsing input: inout ParserSpan) throws {
    try self.init(UInt32(parsingBigEndian: &input))
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint32: rawValue)
  }
}

// MARK: - Serialization helpers

extension FixedWidthInteger {
  /// Lowercase, zero-padded hex without Foundation's `String(format:)`.
  func paddedHex(width: Int) -> String {
    let s = String(self, radix: 16)
    return s.count >= width
      ? s
      : String(repeating: "0", count: width - s.count) + s
  }
}

func _macAddressString(_ bytes: [UInt8]) -> String {
  bytes.map { $0.paddedHex(width: 2) }.joined(separator: ":")
}

extension String {
  /// Parses a NUL-padded 64-octet UTF-8 string (IEEE 1722.1-2021 §7.3.5).
  init(parsingAvdeccFixedString input: inout ParserSpan) throws {
    let bytes = try [UInt8](parsing: &input, byteCount: AvdeccFixedStringLength)
    let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
    self = String(decoding: bytes[..<end], as: UTF8.self)
  }
}

extension SerializationContext {
  /// Serializes `string` as a NUL-padded 64-octet UTF-8 string, truncating longer strings.
  mutating func serialize(avdeccFixedString string: String) {
    var bytes = Array(string.utf8.prefix(AvdeccFixedStringLength))
    bytes += [UInt8](repeating: 0, count: AvdeccFixedStringLength - bytes.count)
    serialize(bytes)
  }

  mutating func serialize(_ value: some Serializable) throws {
    try value.serialize(into: &self)
  }

  mutating func serialize(macAddress: [UInt8]) {
    var bytes = Array(macAddress.prefix(6))
    bytes += [UInt8](repeating: 0, count: 6 - bytes.count)
    serialize(bytes)
  }
}

extension ParserSpan {
  /// Throws unless at least `count` bytes remain.
  func requireRemaining(_ count: Int) throws {
    guard self.count >= count else {
      throw AvdeccCodecError.payloadTooShort(expected: count, actual: self.count)
    }
  }
}

func _parseMacAddress(_ input: inout ParserSpan) throws -> [UInt8] {
  try [UInt8](parsing: &input, byteCount: 6)
}
