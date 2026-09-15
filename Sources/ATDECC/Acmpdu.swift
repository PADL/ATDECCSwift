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

/// ACMP message_type (IEEE 1722.1-2021 §8.2.1.5). A response's value is always its
/// command's plus one.
public enum AcmpMessageType: UInt8, Sendable {
  case connectTxCommand = 0
  case connectTxResponse = 1
  case disconnectTxCommand = 2
  case disconnectTxResponse = 3
  case getTxStateCommand = 4
  case getTxStateResponse = 5
  case connectRxCommand = 6
  case connectRxResponse = 7
  case disconnectRxCommand = 8
  case disconnectRxResponse = 9
  case getRxStateCommand = 10
  case getRxStateResponse = 11
  case getTxConnectionCommand = 12
  case getTxConnectionResponse = 13

  public var isResponse: Bool { rawValue & 1 != 0 }

  /// The response that answers this command, or nil if this is a response.
  public var response: AcmpMessageType? {
    isResponse ? nil : AcmpMessageType(rawValue: rawValue + 1)
  }
}

/// ATDECC Connection Management Protocol Data Unit (IEEE 1722.1-2021 §8.2.1).
public struct Acmpdu: Sendable, Hashable, CustomStringConvertible {
  /// control_data_length of the ACMPDUs sent (IEEE 1722.1-2021 §8.2.1.6). This is the 2013
  /// length, without the fields 2021 adds, as la_avdecc sends; longer ACMPDUs are accepted and
  /// the additional fields ignored.
  public static let length: UInt16 = 44
  /// control_data_length with the IP fields IEEE 1722.1-2021 adds (§8.2.1.6), used to send an
  /// ACMPDU that sets any of them.
  public static let ieee2021Length: UInt16 = 84

  public var messageType: AcmpMessageType
  /// Five-bit ACMP status; see `AcmpStatus`.
  public var status: UInt8
  public var streamID: UniqueIdentifier
  public var controllerEntityID: UniqueIdentifier
  public var talkerEntityID: UniqueIdentifier
  public var listenerEntityID: UniqueIdentifier
  public var talkerUniqueID: UInt16
  public var listenerUniqueID: UInt16
  public var streamDestAddress: EUI48
  public var connectionCount: UInt16
  public var sequenceID: UInt16
  public var flags: ConnectionFlags
  public var streamVlanID: UInt16
  /// The number of entries in a talker's connected listeners array, when `clEntriesValid` is set
  /// (IEEE 1722.1-2021 §8.2.1.18).
  public var connectedListenersEntries: UInt16
  /// The IEEE 1722.1-2021 IP transport fields (§8.2.1.19 to §8.2.1.23); zero in a 1722.1-2013
  /// ACMPDU. The addresses are 16 octets, IPv4 being mapped as in RFC 4291 §2.5.5.2.
  public var ipFlags: UInt16
  public var sourcePort: UInt16
  public var destinationPort: UInt16
  public var sourceIPAddress: [UInt8]
  public var destinationIPAddress: [UInt8]

  public init(
    messageType: AcmpMessageType,
    status: UInt8 = 0,
    streamID: UniqueIdentifier = UniqueIdentifier(),
    controllerEntityID: UniqueIdentifier = UniqueIdentifier(),
    talkerEntityID: UniqueIdentifier = UniqueIdentifier(),
    listenerEntityID: UniqueIdentifier = UniqueIdentifier(),
    talkerUniqueID: UInt16 = 0,
    listenerUniqueID: UInt16 = 0,
    streamDestAddress: EUI48 = [0, 0, 0, 0, 0, 0],
    connectionCount: UInt16 = 0,
    sequenceID: UInt16 = 0,
    flags: ConnectionFlags = [],
    streamVlanID: UInt16 = 0,
    connectedListenersEntries: UInt16 = 0,
    ipFlags: UInt16 = 0,
    sourcePort: UInt16 = 0,
    destinationPort: UInt16 = 0,
    sourceIPAddress: [UInt8] = [UInt8](repeating: 0, count: 16),
    destinationIPAddress: [UInt8] = [UInt8](repeating: 0, count: 16)
  ) {
    self.messageType = messageType
    self.status = status
    self.streamID = streamID
    self.controllerEntityID = controllerEntityID
    self.talkerEntityID = talkerEntityID
    self.listenerEntityID = listenerEntityID
    self.talkerUniqueID = talkerUniqueID
    self.listenerUniqueID = listenerUniqueID
    self.streamDestAddress = streamDestAddress
    self.connectionCount = connectionCount
    self.sequenceID = sequenceID
    self.flags = flags
    self.streamVlanID = streamVlanID
    self.connectedListenersEntries = connectedListenersEntries
    self.ipFlags = ipFlags
    self.sourcePort = sourcePort
    self.destinationPort = destinationPort
    self.sourceIPAddress = sourceIPAddress
    self.destinationIPAddress = destinationIPAddress
  }

  /// Whether any IEEE 1722.1-2021 IP field is set, so that the longer ACMPDU is needed.
  var hasIPFields: Bool {
    ipFlags != 0 || sourcePort != 0 || destinationPort != 0 ||
      sourceIPAddress.contains { $0 != 0 } || destinationIPAddress.contains { $0 != 0 }
  }

  public var talkerStream: StreamIdentification {
    StreamIdentification(entityID: talkerEntityID, streamIndex: talkerUniqueID)
  }

  public var listenerStream: StreamIdentification {
    StreamIdentification(entityID: listenerEntityID, streamIndex: listenerUniqueID)
  }

  public var description: String {
    "Acmpdu(msgType: \(messageType), status: \(status), seq: \(sequenceID)" +
      ", controller: \(controllerEntityID)" +
      ", talker: \(talkerEntityID):\(talkerUniqueID)" +
      ", listener: \(listenerEntityID):\(listenerUniqueID)" +
      ", destMac: \(_macAddressToString(streamDestAddress)), count: \(connectionCount)" +
      ", flags: \(flags.rawValue), vlan: \(streamVlanID))"
  }

  // written out, as EUI48 (an InlineArray) is not Hashable
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.messageType == rhs.messageType &&
      lhs.status == rhs.status &&
      lhs.streamID == rhs.streamID &&
      lhs.controllerEntityID == rhs.controllerEntityID &&
      lhs.talkerEntityID == rhs.talkerEntityID &&
      lhs.listenerEntityID == rhs.listenerEntityID &&
      lhs.talkerUniqueID == rhs.talkerUniqueID &&
      lhs.listenerUniqueID == rhs.listenerUniqueID &&
      _isEqualMacAddress(lhs.streamDestAddress, rhs.streamDestAddress) &&
      lhs.connectionCount == rhs.connectionCount &&
      lhs.sequenceID == rhs.sequenceID &&
      lhs.flags == rhs.flags &&
      lhs.streamVlanID == rhs.streamVlanID &&
      lhs.connectedListenersEntries == rhs.connectedListenersEntries &&
      lhs.ipFlags == rhs.ipFlags &&
      lhs.sourcePort == rhs.sourcePort &&
      lhs.destinationPort == rhs.destinationPort &&
      lhs.sourceIPAddress == rhs.sourceIPAddress &&
      lhs.destinationIPAddress == rhs.destinationIPAddress
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(messageType)
    hasher.combine(status)
    hasher.combine(streamID)
    hasher.combine(controllerEntityID)
    hasher.combine(talkerEntityID)
    hasher.combine(listenerEntityID)
    hasher.combine(talkerUniqueID)
    hasher.combine(listenerUniqueID)
    _hashMacAddress(streamDestAddress, into: &hasher)
    hasher.combine(connectionCount)
    hasher.combine(sequenceID)
    hasher.combine(flags)
    hasher.combine(streamVlanID)
    hasher.combine(connectedListenersEntries)
    hasher.combine(ipFlags)
    hasher.combine(sourcePort)
    hasher.combine(destinationPort)
    hasher.combine(sourceIPAddress)
    hasher.combine(destinationIPAddress)
  }
}

extension Acmpdu: SerDes {
  public init(parsing input: inout ParserSpan) throws {
    let header = try input.parseAvtpduControlHeader(
      subtype: .acmp,
      minimumControlDataLength: Int(Self.length)
    )
    guard let messageType = AcmpMessageType(rawValue: header.controlData) else {
      throw AvdeccCodecError.unexpectedMessageType(header.controlData)
    }
    self.messageType = messageType
    status = header.status
    streamID = UniqueIdentifier(header.streamID)
    controllerEntityID = try UniqueIdentifier(parsing: &input)
    talkerEntityID = try UniqueIdentifier(parsing: &input)
    listenerEntityID = try UniqueIdentifier(parsing: &input)
    talkerUniqueID = try UInt16(parsingBigEndian: &input)
    listenerUniqueID = try UInt16(parsingBigEndian: &input)
    streamDestAddress = try _eui48(parsing: &input)
    connectionCount = try UInt16(parsingBigEndian: &input)
    sequenceID = try UInt16(parsingBigEndian: &input)
    flags = try ConnectionFlags(rawValue: UInt16(parsingBigEndian: &input))
    streamVlanID = try UInt16(parsingBigEndian: &input)
    connectedListenersEntries = try UInt16(parsingBigEndian: &input)
    if header.controlDataLength >= Self.ieee2021Length {
      ipFlags = try UInt16(parsingBigEndian: &input)
      _ = try UInt16(parsingBigEndian: &input) // reserved
      sourcePort = try UInt16(parsingBigEndian: &input)
      destinationPort = try UInt16(parsingBigEndian: &input)
      sourceIPAddress = try [UInt8](parsing: &input, byteCount: 16)
      destinationIPAddress = try [UInt8](parsing: &input, byteCount: 16)
    } else {
      ipFlags = 0
      sourcePort = 0
      destinationPort = 0
      sourceIPAddress = [UInt8](repeating: 0, count: 16)
      destinationIPAddress = [UInt8](repeating: 0, count: 16)
    }
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    let header = AvtpduControlHeader(
      subtype: .acmp,
      controlData: messageType.rawValue,
      status: status,
      controlDataLength: hasIPFields ? Self.ieee2021Length : Self.length,
      streamID: streamID.rawValue
    )
    try serializationContext.serialize(header)
    try serializationContext.serialize(controllerEntityID)
    try serializationContext.serialize(talkerEntityID)
    try serializationContext.serialize(listenerEntityID)
    serializationContext.serialize(uint16: talkerUniqueID)
    serializationContext.serialize(uint16: listenerUniqueID)
    serializationContext.serialize(eui48: streamDestAddress)
    serializationContext.serialize(uint16: connectionCount)
    serializationContext.serialize(uint16: sequenceID)
    serializationContext.serialize(uint16: flags.rawValue)
    serializationContext.serialize(uint16: streamVlanID)
    serializationContext.serialize(uint16: connectedListenersEntries)
    guard hasIPFields else { return }
    guard sourceIPAddress.count == 16, destinationIPAddress.count == 16 else {
      throw AvdeccCodecError.valueTooLarge
    }
    serializationContext.serialize(uint16: ipFlags)
    serializationContext.serialize(uint16: 0) // reserved
    serializationContext.serialize(uint16: sourcePort)
    serializationContext.serialize(uint16: destinationPort)
    serializationContext.serialize(sourceIPAddress)
    serializationContext.serialize(destinationIPAddress)
  }
}
