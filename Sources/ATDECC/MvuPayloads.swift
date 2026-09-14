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

// Milan 1.2 GET/SET_SYSTEM_UNIQUE_ID payloads carry a 32-bit identifier and no name.
private let _milan12SystemUniqueIDLength = 6
// Milan 1.3 added specification_version to GET_MILAN_INFO.
private let _milan13MilanInfoLength = 18
// protocol_version of Milan 1.2 entities, which predate specification_version.
private let _milan12ProtocolVersion: UInt32 = 1

/// Milan Vendor Unique command_specific_data of a command (Milan 1.3 §5.4.4).
public enum MvuCommandPayload: Sendable, Hashable {
  case getMilanInfo
  case setSystemUniqueID(systemUniqueID: UniqueIdentifier, systemName: String)
  case getSystemUniqueID
  case setMediaClockReferenceInfo(
    clockDomainIndex: UInt16,
    flags: MediaClockReferenceInfoFlags,
    defaultPriority: MediaClockReferencePriority,
    userPriority: MediaClockReferencePriority,
    domainName: String
  )
  case getMediaClockReferenceInfo(clockDomainIndex: UInt16)
  case bindStream(
    flags: BindStreamFlags,
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    talkerStream: StreamIdentification
  )
  case unbindStream(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getStreamInputInfoEx(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  /// A command without a dedicated model.
  case other(commandType: UInt16, data: [UInt8])

  public var commandTypeRaw: UInt16 {
    switch self {
    case .getMilanInfo: MvuCommandType.getMilanInfo.rawValue
    case .setSystemUniqueID: MvuCommandType.setSystemUniqueID.rawValue
    case .getSystemUniqueID: MvuCommandType.getSystemUniqueID.rawValue
    case .setMediaClockReferenceInfo: MvuCommandType.setMediaClockReferenceInfo.rawValue
    case .getMediaClockReferenceInfo: MvuCommandType.getMediaClockReferenceInfo.rawValue
    case .bindStream: MvuCommandType.bindStream.rawValue
    case .unbindStream: MvuCommandType.unbindStream.rawValue
    case .getStreamInputInfoEx: MvuCommandType.getStreamInputInfoEx.rawValue
    case let .other(commandType, _): commandType
    }
  }

  public var commandType: MvuCommandType {
    MvuCommandType(rawValue: commandTypeRaw) ?? .invalidCommandType
  }

  /// The encoded command_specific_data.
  public func serialized() throws -> [UInt8] {
    var context = SerializationContext()

    switch self {
    case .getMilanInfo, .getSystemUniqueID:
      context.serialize(uint16: 0) // reserved
    case let .setSystemUniqueID(systemUniqueID, systemName):
      try _serializeSystemUniqueID(systemUniqueID, systemName, into: &context)
    case let .setMediaClockReferenceInfo(
      clockDomainIndex,
      flags,
      defaultPriority,
      userPriority,
      domainName
    ):
      _serializeMediaClockReferenceInfo(
        clockDomainIndex, flags, defaultPriority, userPriority, domainName, into: &context
      )
    case let .getMediaClockReferenceInfo(clockDomainIndex):
      context.serialize(uint16: clockDomainIndex)
    case let .bindStream(flags, descriptorType, descriptorIndex, talkerStream):
      try _serializeBindStream(flags, descriptorType, descriptorIndex, talkerStream, into: &context)
    case let .unbindStream(descriptorType, descriptorIndex),
         let .getStreamInputInfoEx(descriptorType, descriptorIndex):
      context.serialize(uint16: 0) // reserved
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
    case let .other(_, data):
      context.serialize(data)
    }

    return context.bytes
  }

  /// Decodes the command_specific_data of a received command.
  public init(commandTypeRaw: UInt16, data: [UInt8]) throws {
    self = try data.withParserSpan { input in
      switch MvuCommandType(rawValue: commandTypeRaw) {
      case .getMilanInfo:
        return .getMilanInfo
      case .setSystemUniqueID:
        let (systemUniqueID, systemName) = try _parseSystemUniqueID(&input)
        return .setSystemUniqueID(systemUniqueID: systemUniqueID, systemName: systemName)
      case .getSystemUniqueID:
        return .getSystemUniqueID
      case .setMediaClockReferenceInfo:
        let fields = try _parseMediaClockReferenceInfo(&input)
        return .setMediaClockReferenceInfo(
          clockDomainIndex: fields.clockDomainIndex,
          flags: fields.flags,
          defaultPriority: fields.defaultPriority,
          userPriority: fields.userPriority,
          domainName: fields.domainName
        )
      case .getMediaClockReferenceInfo:
        return try .getMediaClockReferenceInfo(clockDomainIndex: UInt16(parsingBigEndian: &input))
      case .bindStream:
        let fields = try _parseBindStream(&input)
        return .bindStream(
          flags: fields.flags,
          descriptorType: fields.descriptorType,
          descriptorIndex: fields.descriptorIndex,
          talkerStream: fields.talkerStream
        )
      case .unbindStream:
        _ = try UInt16(parsingBigEndian: &input) // reserved
        return try .unbindStream(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input)
        )
      case .getStreamInputInfoEx:
        _ = try UInt16(parsingBigEndian: &input) // reserved
        return try .getStreamInputInfoEx(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input)
        )
      default:
        return .other(commandType: commandTypeRaw, data: [UInt8](parsingRemainingBytes: &input))
      }
    }
  }
}

/// Milan Vendor Unique command_specific_data of a successful response (Milan 1.3 §5.4.4).
public enum MvuResponsePayload: Sendable, Hashable {
  case getMilanInfo(MilanInfo)
  case setSystemUniqueID(systemUniqueID: UniqueIdentifier, systemName: String)
  case getSystemUniqueID(systemUniqueID: UniqueIdentifier, systemName: String)
  case setMediaClockReferenceInfo(
    clockDomainIndex: UInt16,
    defaultPriority: MediaClockReferencePriority,
    info: MediaClockReferenceInfo
  )
  case getMediaClockReferenceInfo(
    clockDomainIndex: UInt16,
    defaultPriority: MediaClockReferencePriority,
    info: MediaClockReferenceInfo
  )
  case bindStream(
    flags: BindStreamFlags,
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    talkerStream: StreamIdentification
  )
  case unbindStream(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getStreamInputInfoEx(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    info: StreamInputInfoEx
  )
  /// A response without a dedicated model.
  case other(commandType: UInt16, data: [UInt8])

  /// Decodes the command_specific_data of a successful response.
  public init(commandTypeRaw: UInt16, data: [UInt8]) throws {
    self = try data.withParserSpan { input in
      switch MvuCommandType(rawValue: commandTypeRaw) {
      case .getMilanInfo:
        let payloadLength = input.count
        _ = try UInt16(parsingBigEndian: &input) // reserved
        let protocolVersion = try UInt32(parsingBigEndian: &input)
        let featuresFlags = try MilanInfoFeaturesFlags(rawValue: UInt32(parsingBigEndian: &input))
        let certificationVersion = try MilanVersion(rawValue: UInt32(parsingBigEndian: &input))
        let specificationVersion: MilanVersion = if payloadLength >= _milan13MilanInfoLength {
          try MilanVersion(rawValue: UInt32(parsingBigEndian: &input))
        } else if protocolVersion == _milan12ProtocolVersion {
          MilanVersion(major: 1, minor: 2)
        } else {
          MilanVersion(rawValue: 0)
        }
        return .getMilanInfo(MilanInfo(
          protocolVersion: protocolVersion,
          featuresFlags: featuresFlags,
          certificationVersion: certificationVersion,
          specificationVersion: specificationVersion
        ))
      case .setSystemUniqueID:
        let (systemUniqueID, systemName) = try _parseSystemUniqueID(&input)
        return .setSystemUniqueID(systemUniqueID: systemUniqueID, systemName: systemName)
      case .getSystemUniqueID:
        let (systemUniqueID, systemName) = try _parseSystemUniqueID(&input)
        return .getSystemUniqueID(systemUniqueID: systemUniqueID, systemName: systemName)
      case .setMediaClockReferenceInfo:
        let fields = try _parseMediaClockReferenceInfo(&input)
        return .setMediaClockReferenceInfo(
          clockDomainIndex: fields.clockDomainIndex,
          defaultPriority: fields.defaultPriority,
          info: fields.info
        )
      case .getMediaClockReferenceInfo:
        let fields = try _parseMediaClockReferenceInfo(&input)
        return .getMediaClockReferenceInfo(
          clockDomainIndex: fields.clockDomainIndex,
          defaultPriority: fields.defaultPriority,
          info: fields.info
        )
      case .bindStream:
        let fields = try _parseBindStream(&input)
        return .bindStream(
          flags: fields.flags,
          descriptorType: fields.descriptorType,
          descriptorIndex: fields.descriptorIndex,
          talkerStream: fields.talkerStream
        )
      case .unbindStream:
        _ = try UInt16(parsingBigEndian: &input) // reserved
        return try .unbindStream(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input)
        )
      case .getStreamInputInfoEx:
        _ = try UInt16(parsingBigEndian: &input) // reserved
        let descriptorType = try DescriptorType(parsing: &input)
        let descriptorIndex = try UInt16(parsingBigEndian: &input)
        let talkerStream = try StreamIdentification(
          entityID: UniqueIdentifier(parsing: &input),
          streamIndex: UInt16(parsingBigEndian: &input)
        )
        let probingAcmpStatus = try UInt8(parsing: &input)
        _ = try UInt8(parsing: &input) // reserved
        return .getStreamInputInfoEx(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          info: StreamInputInfoEx(
            talkerStream: talkerStream,
            probingStatus: ProbingStatus(probingAcmpStatus >> 5),
            acmpStatus: AcmpStatus(UInt16(probingAcmpStatus & 0x1F))
          )
        )
      default:
        return .other(commandType: commandTypeRaw, data: [UInt8](parsingRemainingBytes: &input))
      }
    }
  }
}

// MARK: - Shared layouts

private func _parseSystemUniqueID(
  _ input: inout ParserSpan
) throws -> (UniqueIdentifier, String) {
  let payloadLength = input.count
  _ = try UInt16(parsingBigEndian: &input) // reserved
  if payloadLength == _milan12SystemUniqueIDLength {
    return try (UniqueIdentifier(UInt64(UInt32(parsingBigEndian: &input))), "")
  }
  return try (UniqueIdentifier(parsing: &input), String(parsingAvdeccFixedString: &input))
}

private func _serializeSystemUniqueID(
  _ systemUniqueID: UniqueIdentifier,
  _ systemName: String,
  into context: inout SerializationContext
) throws {
  context.serialize(uint16: 0) // reserved
  try context.serialize(systemUniqueID)
  context.serialize(avdeccFixedString: systemName)
}

private struct _MediaClockReferenceInfoFields {
  let clockDomainIndex: UInt16
  let flags: MediaClockReferenceInfoFlags
  let defaultPriority: MediaClockReferencePriority
  let userPriority: MediaClockReferencePriority
  let domainName: String

  var info: MediaClockReferenceInfo {
    MediaClockReferenceInfo(
      userMediaClockPriority: flags.contains(.userMediaClockReferencePriorityValid)
        ? userPriority : nil,
      mediaClockDomainName: flags.contains(.mediaClockDomainNameValid) ? domainName : nil
    )
  }
}

private func _parseMediaClockReferenceInfo(
  _ input: inout ParserSpan
) throws -> _MediaClockReferenceInfoFields {
  let clockDomainIndex = try UInt16(parsingBigEndian: &input)
  let flags = try MediaClockReferenceInfoFlags(rawValue: UInt8(parsing: &input))
  _ = try UInt8(parsing: &input) // reserved
  let defaultPriority = try UInt8(parsing: &input)
  let userPriority = try UInt8(parsing: &input)
  _ = try UInt32(parsingBigEndian: &input) // reserved
  let domainName = try String(parsingAvdeccFixedString: &input)
  return _MediaClockReferenceInfoFields(
    clockDomainIndex: clockDomainIndex,
    flags: flags,
    defaultPriority: defaultPriority,
    userPriority: userPriority,
    domainName: domainName
  )
}

private func _serializeMediaClockReferenceInfo(
  _ clockDomainIndex: UInt16,
  _ flags: MediaClockReferenceInfoFlags,
  _ defaultPriority: MediaClockReferencePriority,
  _ userPriority: MediaClockReferencePriority,
  _ domainName: String,
  into context: inout SerializationContext
) {
  context.serialize(uint16: clockDomainIndex)
  context.serialize(uint8: flags.rawValue)
  context.serialize(uint8: 0) // reserved
  context.serialize(uint8: defaultPriority)
  context.serialize(uint8: userPriority)
  context.serialize(uint32: 0) // reserved
  context.serialize(avdeccFixedString: domainName)
}

private struct _BindStreamFields {
  let flags: BindStreamFlags
  let descriptorType: DescriptorType
  let descriptorIndex: DescriptorIndex
  let talkerStream: StreamIdentification
}

private func _parseBindStream(_ input: inout ParserSpan) throws -> _BindStreamFields {
  let flags = try BindStreamFlags(rawValue: UInt16(parsingBigEndian: &input))
  let descriptorType = try DescriptorType(parsing: &input)
  let descriptorIndex = try UInt16(parsingBigEndian: &input)
  let talkerStream = try StreamIdentification(
    entityID: UniqueIdentifier(parsing: &input),
    streamIndex: UInt16(parsingBigEndian: &input)
  )
  _ = try UInt16(parsingBigEndian: &input) // reserved
  return _BindStreamFields(
    flags: flags,
    descriptorType: descriptorType,
    descriptorIndex: descriptorIndex,
    talkerStream: talkerStream
  )
}

private func _serializeBindStream(
  _ flags: BindStreamFlags,
  _ descriptorType: DescriptorType,
  _ descriptorIndex: DescriptorIndex,
  _ talkerStream: StreamIdentification,
  into context: inout SerializationContext
) throws {
  context.serialize(uint16: flags.rawValue)
  try context.serialize(descriptorType)
  context.serialize(uint16: descriptorIndex)
  try context.serialize(talkerStream.entityID)
  context.serialize(uint16: talkerStream.streamIndex)
  context.serialize(uint16: 0) // reserved
}
