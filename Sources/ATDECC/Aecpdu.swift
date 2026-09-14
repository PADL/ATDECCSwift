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

/// AECP message_type (IEEE 1722.1-2021 §9.2.1.1.5).
public enum AecpMessageType: UInt8, Sendable {
  case aemCommand = 0
  case aemResponse = 1
  case addressAccessCommand = 2
  case addressAccessResponse = 3
  case avcCommand = 4
  case avcResponse = 5
  case vendorUniqueCommand = 6
  case vendorUniqueResponse = 7
  case hdcpAemCommand = 8
  case hdcpAemResponse = 9
  case extendedCommand = 14
  case extendedResponse = 15

  public var isResponse: Bool { rawValue & 1 != 0 }
}

/// AEM command_type (IEEE 1722.1-2021 Table 7-126).
public enum AemCommandType: UInt16, Sendable, CaseIterable {
  case acquireEntity = 0x0000
  case lockEntity = 0x0001
  case entityAvailable = 0x0002
  case controllerAvailable = 0x0003
  case readDescriptor = 0x0004
  case writeDescriptor = 0x0005
  case setConfiguration = 0x0006
  case getConfiguration = 0x0007
  case setStreamFormat = 0x0008
  case getStreamFormat = 0x0009
  case setVideoFormat = 0x000A
  case getVideoFormat = 0x000B
  case setSensorFormat = 0x000C
  case getSensorFormat = 0x000D
  case setStreamInfo = 0x000E
  case getStreamInfo = 0x000F
  case setName = 0x0010
  case getName = 0x0011
  case setAssociationID = 0x0012
  case getAssociationID = 0x0013
  case setSamplingRate = 0x0014
  case getSamplingRate = 0x0015
  case setClockSource = 0x0016
  case getClockSource = 0x0017
  case setControl = 0x0018
  case getControl = 0x0019
  case incrementControl = 0x001A
  case decrementControl = 0x001B
  case setSignalSelector = 0x001C
  case getSignalSelector = 0x001D
  case setMixer = 0x001E
  case getMixer = 0x001F
  case setMatrix = 0x0020
  case getMatrix = 0x0021
  case startStreaming = 0x0022
  case stopStreaming = 0x0023
  case registerUnsolicitedNotification = 0x0024
  case deregisterUnsolicitedNotification = 0x0025
  case identifyNotification = 0x0026
  case getAvbInfo = 0x0027
  case getAsPath = 0x0028
  case getCounters = 0x0029
  case reboot = 0x002A
  case getAudioMap = 0x002B
  case addAudioMappings = 0x002C
  case removeAudioMappings = 0x002D
  case getVideoMap = 0x002E
  case addVideoMappings = 0x002F
  case removeVideoMappings = 0x0030
  case getSensorMap = 0x0031
  case addSensorMappings = 0x0032
  case removeSensorMappings = 0x0033
  case startOperation = 0x0034
  case abortOperation = 0x0035
  case operationStatus = 0x0036
  case authAddKey = 0x0037
  case authDeleteKey = 0x0038
  case authGetKeyList = 0x0039
  case authGetKey = 0x003A
  case authAddKeyToChain = 0x003B
  case authDeleteKeyFromChain = 0x003C
  case authGetKeychainList = 0x003D
  case authGetIdentity = 0x003E
  case authAddToken = 0x003F
  case authDeleteToken = 0x0040
  case authenticate = 0x0041
  case deauthenticate = 0x0042
  case enableTransportSecurity = 0x0043
  case disableTransportSecurity = 0x0044
  case enableStreamEncryption = 0x0045
  case disableStreamEncryption = 0x0046
  case setMemoryObjectLength = 0x0047
  case getMemoryObjectLength = 0x0048
  case setStreamBackup = 0x0049
  case getStreamBackup = 0x004A
  case getDynamicInfo = 0x004B
  case setMaxTransitTime = 0x004C
  case getMaxTransitTime = 0x004D
  case expansion = 0x3FFF
  case invalidCommandType = 0xFFFF
}

/// Milan Vendor Unique command_type (Milan 1.3 §5.4.4).
public enum MvuCommandType: UInt16, Sendable, CaseIterable {
  case getMilanInfo = 0x0000
  case setSystemUniqueID = 0x0001
  case getSystemUniqueID = 0x0002
  case setMediaClockReferenceInfo = 0x0003
  case getMediaClockReferenceInfo = 0x0004
  case bindStream = 0x0005
  case unbindStream = 0x0006
  case getStreamInputInfoEx = 0x0007
  case invalidCommandType = 0xFFFF
}

/// controller_entity_id of an IDENTIFY notification (IEEE 1722.1-2021 §7.5.1).
public let IdentifyNotificationControllerEntityID = UniqueIdentifier(0x90E0_F0FF_FE01_0001)

/// protocol_id of Milan Vendor Unique AECPDUs: Avnu OUI-36 00-1B-C5-0A-C plus 0x100
/// (Milan 1.3 §5.4.3.1).
public let MvuProtocolIdentifier: UInt64 = 0x001B_C50A_C100

// AECP common header following the AVTP control header: controller_entity_id, sequence_id.
private let _aecpduHeaderLength = 10
// u (unsolicited) and cr (controller request) flags and command_type.
private let _commandTypeLength = 2
private let _unsolicitedFlag: UInt16 = 0x8000
private let _controllerRequestFlag: UInt16 = 0x4000
// AEM command_type is 14 bits (IEEE 1722.1-2021 §9.3.2); MVU command_type is 15
private let _aemCommandTypeMask: UInt16 = 0x3FFF
private let _mvuCommandTypeMask: UInt16 = 0x7FFF
// Vendor Unique protocol_id.
private let _protocolIdentifierLength = 6

/// An AEM AECPDU (IEEE 1722.1-2021 §9.2.1.2).
public struct AemAecpdu: Sendable, Hashable, CustomStringConvertible {
  public var isResponse: Bool
  /// Five-bit AEM status; see `AemStatus`.
  public var status: UInt8
  public var targetEntityID: UniqueIdentifier
  public var controllerEntityID: UniqueIdentifier
  public var sequenceID: UInt16
  public var unsolicited: Bool
  /// The cr flag (IEEE 1722.1-2021 §9.3.2.2): set in an unsolicited response that asks the
  /// controller to execute its command on the entity, as when a user changes the entity's
  /// sampling rate from its front panel.
  public var controllerRequest = false
  /// The raw 14-bit command_type, preserved when it isn't a known `AemCommandType`.
  public var commandTypeRaw: UInt16
  public var commandSpecificData: [UInt8]

  public init(
    isResponse: Bool,
    status: UInt8 = 0,
    targetEntityID: UniqueIdentifier,
    controllerEntityID: UniqueIdentifier,
    sequenceID: UInt16 = 0,
    unsolicited: Bool = false,
    commandType: AemCommandType,
    commandSpecificData: [UInt8] = []
  ) {
    self.isResponse = isResponse
    self.status = status
    self.targetEntityID = targetEntityID
    self.controllerEntityID = controllerEntityID
    self.sequenceID = sequenceID
    self.unsolicited = unsolicited
    commandTypeRaw = commandType.rawValue
    self.commandSpecificData = commandSpecificData
  }

  /// Decoded AEM command type; `.invalidCommandType` for unrecognised values.
  public var commandType: AemCommandType {
    AemCommandType(rawValue: commandTypeRaw) ?? .invalidCommandType
  }

  public var messageType: AecpMessageType {
    isResponse ? .aemResponse : .aemCommand
  }

  public var description: String {
    "AemAecpdu(target: \(targetEntityID), controller: \(controllerEntityID)" +
      ", seq: \(sequenceID), commandType: \(commandType), status: \(status)" +
      (unsolicited ? ", unsolicited" : "") + (controllerRequest ? ", controller request" : "") + ")"
  }
}

/// A Milan Vendor Unique AECPDU (Milan 1.3 §5.4.3).
public struct MvuAecpdu: Sendable, Hashable, CustomStringConvertible {
  public var isResponse: Bool
  /// Five-bit MVU status; see `MvuStatus`.
  public var status: UInt8
  public var targetEntityID: UniqueIdentifier
  public var controllerEntityID: UniqueIdentifier
  public var sequenceID: UInt16
  public var unsolicited: Bool
  public var commandTypeRaw: UInt16
  public var commandSpecificData: [UInt8]

  public init(
    isResponse: Bool,
    status: UInt8 = 0,
    targetEntityID: UniqueIdentifier,
    controllerEntityID: UniqueIdentifier,
    sequenceID: UInt16 = 0,
    unsolicited: Bool = false,
    commandType: MvuCommandType,
    commandSpecificData: [UInt8] = []
  ) {
    self.isResponse = isResponse
    self.status = status
    self.targetEntityID = targetEntityID
    self.controllerEntityID = controllerEntityID
    self.sequenceID = sequenceID
    self.unsolicited = unsolicited
    commandTypeRaw = commandType.rawValue
    self.commandSpecificData = commandSpecificData
  }

  public var commandType: MvuCommandType {
    MvuCommandType(rawValue: commandTypeRaw) ?? .invalidCommandType
  }

  public var messageType: AecpMessageType {
    isResponse ? .vendorUniqueResponse : .vendorUniqueCommand
  }

  public var description: String {
    "MvuAecpdu(target: \(targetEntityID), controller: \(controllerEntityID)" +
      ", seq: \(sequenceID), commandType: \(commandType), status: \(status)" +
      (unsolicited ? ", unsolicited" : "") + ")"
  }
}

/// ATDECC Enumeration and Control Protocol Data Unit (IEEE 1722.1-2021 §9.2.1).
public enum Aecpdu: Sendable, Hashable {
  case aem(AemAecpdu)
  case mvu(MvuAecpdu)
  /// Any other AECP message (address access, AV/C, other vendors), kept undecoded.
  case other(
    messageType: UInt8,
    status: UInt8,
    targetEntityID: UniqueIdentifier,
    controllerEntityID: UniqueIdentifier,
    sequenceID: UInt16,
    specificData: [UInt8]
  )

  public var targetEntityID: UniqueIdentifier {
    switch self {
    case let .aem(aem): aem.targetEntityID
    case let .mvu(mvu): mvu.targetEntityID
    case let .other(_, _, targetEntityID, _, _, _): targetEntityID
    }
  }

  public var controllerEntityID: UniqueIdentifier {
    switch self {
    case let .aem(aem): aem.controllerEntityID
    case let .mvu(mvu): mvu.controllerEntityID
    case let .other(_, _, _, controllerEntityID, _, _): controllerEntityID
    }
  }

  public var sequenceID: UInt16 {
    switch self {
    case let .aem(aem): aem.sequenceID
    case let .mvu(mvu): mvu.sequenceID
    case let .other(_, _, _, _, sequenceID, _): sequenceID
    }
  }

  public var messageTypeRaw: UInt8 {
    switch self {
    case let .aem(aem): aem.messageType.rawValue
    case let .mvu(mvu): mvu.messageType.rawValue
    case let .other(messageType, _, _, _, _, _): messageType
    }
  }

  public var isResponse: Bool {
    messageTypeRaw & 1 != 0
  }
}

extension Aecpdu: SerDes {
  public init(parsing input: inout ParserSpan) throws {
    let header = try input.parseAvtpduControlHeader(
      subtype: .aecp,
      minimumControlDataLength: _aecpduHeaderLength
    )
    let targetEntityID = UniqueIdentifier(header.streamID)
    let controllerEntityID = try UniqueIdentifier(parsing: &input)
    let sequenceID = try UInt16(parsingBigEndian: &input)
    var specificDataLength = Int(header.controlDataLength) - _aecpduHeaderLength

    switch AecpMessageType(rawValue: header.controlData) {
    case .aemCommand, .aemResponse:
      guard specificDataLength >= _commandTypeLength else {
        throw AvdeccCodecError.invalidControlDataLength(header.controlDataLength)
      }
      let flagsCommandType = try UInt16(parsingBigEndian: &input)
      specificDataLength -= _commandTypeLength
      var aem = try AemAecpdu(
        isResponse: header.controlData == AecpMessageType.aemResponse.rawValue,
        status: header.status,
        targetEntityID: targetEntityID,
        controllerEntityID: controllerEntityID,
        sequenceID: sequenceID,
        unsolicited: flagsCommandType & _unsolicitedFlag != 0,
        commandTypeRaw: flagsCommandType & _aemCommandTypeMask,
        commandSpecificData: [UInt8](parsing: &input, byteCount: specificDataLength)
      )
      aem.controllerRequest = flagsCommandType & _controllerRequestFlag != 0
      self = .aem(aem)
    case .vendorUniqueCommand, .vendorUniqueResponse:
      guard specificDataLength >= _protocolIdentifierLength else {
        throw AvdeccCodecError.invalidControlDataLength(header.controlDataLength)
      }
      let protocolIdentifier = try UInt64(parsingBigEndian: &input, byteCount: 6)
      specificDataLength -= _protocolIdentifierLength
      if protocolIdentifier == MvuProtocolIdentifier {
        guard specificDataLength >= _commandTypeLength else {
          throw AvdeccCodecError.invalidControlDataLength(header.controlDataLength)
        }
        let unsolicitedCommandType = try UInt16(parsingBigEndian: &input)
        specificDataLength -= _commandTypeLength
        self = try .mvu(MvuAecpdu(
          isResponse: header.controlData == AecpMessageType.vendorUniqueResponse.rawValue,
          status: header.status,
          targetEntityID: targetEntityID,
          controllerEntityID: controllerEntityID,
          sequenceID: sequenceID,
          unsolicited: unsolicitedCommandType & _unsolicitedFlag != 0,
          commandTypeRaw: unsolicitedCommandType & _mvuCommandTypeMask,
          commandSpecificData: [UInt8](parsing: &input, byteCount: specificDataLength)
        ))
      } else {
        var specificData = [UInt8]()
        var context = SerializationContext()
        context.serialize(uint64: protocolIdentifier)
        specificData = Array(context.bytes.suffix(_protocolIdentifierLength))
        specificData += try [UInt8](parsing: &input, byteCount: specificDataLength)
        self = .other(
          messageType: header.controlData,
          status: header.status,
          targetEntityID: targetEntityID,
          controllerEntityID: controllerEntityID,
          sequenceID: sequenceID,
          specificData: specificData
        )
      }
    default:
      self = try .other(
        messageType: header.controlData,
        status: header.status,
        targetEntityID: targetEntityID,
        controllerEntityID: controllerEntityID,
        sequenceID: sequenceID,
        specificData: [UInt8](parsing: &input, byteCount: specificDataLength)
      )
    }
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    let messageType: UInt8
    let status: UInt8
    var specificData = SerializationContext()

    switch self {
    case let .aem(aem):
      messageType = aem.messageType.rawValue
      status = aem.status
      specificData.serialize(
        uint16: (aem.unsolicited ? _unsolicitedFlag : 0) |
          (aem.controllerRequest ? _controllerRequestFlag : 0) |
          (aem.commandTypeRaw & _aemCommandTypeMask)
      )
      specificData.serialize(aem.commandSpecificData)
    case let .mvu(mvu):
      messageType = mvu.messageType.rawValue
      status = mvu.status
      var protocolIdentifier = SerializationContext()
      protocolIdentifier.serialize(uint64: MvuProtocolIdentifier)
      specificData.serialize(Array(protocolIdentifier.bytes.suffix(_protocolIdentifierLength)))
      specificData.serialize(
        uint16: (mvu.unsolicited ? _unsolicitedFlag : 0) | (mvu.commandTypeRaw & _mvuCommandTypeMask)
      )
      specificData.serialize(mvu.commandSpecificData)
    case let .other(otherMessageType, otherStatus, _, _, _, data):
      messageType = otherMessageType
      status = otherStatus
      specificData.serialize(data)
    }

    let controlDataLength = _aecpduHeaderLength + specificData.bytes.count
    guard controlDataLength <= 0x07FF else { throw AvdeccCodecError.valueTooLarge }

    let header = AvtpduControlHeader(
      subtype: .aecp,
      controlData: messageType,
      status: status,
      controlDataLength: UInt16(controlDataLength),
      streamID: targetEntityID.rawValue
    )
    try serializationContext.serialize(header)
    try serializationContext.serialize(controllerEntityID)
    serializationContext.serialize(uint16: sequenceID)
    serializationContext.serialize(specificData.bytes)
  }
}

private extension AemAecpdu {
  init(
    isResponse: Bool,
    status: UInt8,
    targetEntityID: UniqueIdentifier,
    controllerEntityID: UniqueIdentifier,
    sequenceID: UInt16,
    unsolicited: Bool,
    commandTypeRaw: UInt16,
    commandSpecificData: [UInt8]
  ) {
    self.init(
      isResponse: isResponse,
      status: status,
      targetEntityID: targetEntityID,
      controllerEntityID: controllerEntityID,
      sequenceID: sequenceID,
      unsolicited: unsolicited,
      commandType: .invalidCommandType,
      commandSpecificData: commandSpecificData
    )
    self.commandTypeRaw = commandTypeRaw
  }
}

private extension MvuAecpdu {
  init(
    isResponse: Bool,
    status: UInt8,
    targetEntityID: UniqueIdentifier,
    controllerEntityID: UniqueIdentifier,
    sequenceID: UInt16,
    unsolicited: Bool,
    commandTypeRaw: UInt16,
    commandSpecificData: [UInt8]
  ) {
    self.init(
      isResponse: isResponse,
      status: status,
      targetEntityID: targetEntityID,
      controllerEntityID: controllerEntityID,
      sequenceID: sequenceID,
      unsolicited: unsolicited,
      commandType: .invalidCommandType,
      commandSpecificData: commandSpecificData
    )
    self.commandTypeRaw = commandTypeRaw
  }
}
