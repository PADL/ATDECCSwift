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

/// ADP message_type (IEEE 1722.1-2021 §6.2.1.5).
public enum AdpMessageType: UInt8, Sendable {
  case entityAvailable = 0
  case entityDeparting = 1
  case entityDiscover = 2
}

/// ATDECC Discovery Protocol Data Unit (IEEE 1722.1-2021 §6.2.1).
public struct Adpdu: Sendable, Hashable {
  /// control_data_length of an ADPDU (IEEE 1722.1-2021 §6.2.1.7).
  public static let length: UInt16 = 56

  public var messageType: AdpMessageType
  /// Validity of this advertisement, in units of 2 seconds (five bits).
  public var validTime: UInt8
  public var entityID: UniqueIdentifier
  public var entityModelID: UniqueIdentifier
  public var entityCapabilities: EntityCapabilities
  public var talkerStreamSources: UInt16
  public var talkerCapabilities: TalkerCapabilities
  public var listenerStreamSinks: UInt16
  public var listenerCapabilities: ListenerCapabilities
  public var controllerCapabilities: ControllerCapabilities
  public var availableIndex: UInt32
  public var gptpGrandmasterID: UniqueIdentifier
  public var gptpDomainNumber: UInt8
  public var identifyControlIndex: UInt16
  public var interfaceIndex: UInt16
  public var associationID: UniqueIdentifier

  public init(
    messageType: AdpMessageType,
    validTime: UInt8 = 31,
    entityID: UniqueIdentifier,
    entityModelID: UniqueIdentifier = UniqueIdentifier(),
    entityCapabilities: EntityCapabilities = [],
    talkerStreamSources: UInt16 = 0,
    talkerCapabilities: TalkerCapabilities = [],
    listenerStreamSinks: UInt16 = 0,
    listenerCapabilities: ListenerCapabilities = [],
    controllerCapabilities: ControllerCapabilities = [],
    availableIndex: UInt32 = 0,
    gptpGrandmasterID: UniqueIdentifier = UniqueIdentifier(),
    gptpDomainNumber: UInt8 = 0,
    identifyControlIndex: UInt16 = 0,
    interfaceIndex: UInt16 = 0,
    associationID: UniqueIdentifier = UniqueIdentifier()
  ) {
    self.messageType = messageType
    self.validTime = validTime
    self.entityID = entityID
    self.entityModelID = entityModelID
    self.entityCapabilities = entityCapabilities
    self.talkerStreamSources = talkerStreamSources
    self.talkerCapabilities = talkerCapabilities
    self.listenerStreamSinks = listenerStreamSinks
    self.listenerCapabilities = listenerCapabilities
    self.controllerCapabilities = controllerCapabilities
    self.availableIndex = availableIndex
    self.gptpGrandmasterID = gptpGrandmasterID
    self.gptpDomainNumber = gptpDomainNumber
    self.identifyControlIndex = identifyControlIndex
    self.interfaceIndex = interfaceIndex
    self.associationID = associationID
  }
}

extension Adpdu: SerDes {
  public init(parsing input: inout ParserSpan) throws {
    let header = try input.parseAvtpduControlHeader(
      subtype: .adp,
      minimumControlDataLength: Int(Self.length)
    )
    guard let messageType = AdpMessageType(rawValue: header.controlData) else {
      throw AvdeccCodecError.unexpectedMessageType(header.controlData)
    }
    self.messageType = messageType
    validTime = header.status
    entityID = UniqueIdentifier(header.streamID)
    entityModelID = try UniqueIdentifier(parsing: &input)
    entityCapabilities = try EntityCapabilities(rawValue: UInt32(parsingBigEndian: &input))
    talkerStreamSources = try UInt16(parsingBigEndian: &input)
    talkerCapabilities = try TalkerCapabilities(rawValue: UInt16(parsingBigEndian: &input))
    listenerStreamSinks = try UInt16(parsingBigEndian: &input)
    listenerCapabilities = try ListenerCapabilities(rawValue: UInt16(parsingBigEndian: &input))
    controllerCapabilities =
      try ControllerCapabilities(rawValue: UInt32(parsingBigEndian: &input))
    availableIndex = try UInt32(parsingBigEndian: &input)
    gptpGrandmasterID = try UniqueIdentifier(parsing: &input)
    let gptpDomainNumberReserved = try UInt32(parsingBigEndian: &input)
    gptpDomainNumber = UInt8(gptpDomainNumberReserved >> 24)
    identifyControlIndex = try UInt16(parsingBigEndian: &input)
    interfaceIndex = try UInt16(parsingBigEndian: &input)
    associationID = try UniqueIdentifier(parsing: &input)
    _ = try UInt32(parsingBigEndian: &input) // reserved1
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    let header = AvtpduControlHeader(
      subtype: .adp,
      controlData: messageType.rawValue,
      status: validTime,
      controlDataLength: Self.length,
      streamID: entityID.rawValue
    )
    try serializationContext.serialize(header)
    try serializationContext.serialize(entityModelID)
    serializationContext.serialize(uint32: entityCapabilities.rawValue)
    serializationContext.serialize(uint16: talkerStreamSources)
    serializationContext.serialize(uint16: talkerCapabilities.rawValue)
    serializationContext.serialize(uint16: listenerStreamSinks)
    serializationContext.serialize(uint16: listenerCapabilities.rawValue)
    serializationContext.serialize(uint32: controllerCapabilities.rawValue)
    serializationContext.serialize(uint32: availableIndex)
    try serializationContext.serialize(gptpGrandmasterID)
    serializationContext.serialize(uint32: UInt32(gptpDomainNumber) << 24)
    serializationContext.serialize(uint16: identifyControlIndex)
    serializationContext.serialize(uint16: interfaceIndex)
    try serializationContext.serialize(associationID)
    serializationContext.serialize(uint32: 0) // reserved1
  }
}
