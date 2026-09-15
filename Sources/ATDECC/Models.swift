//
// Copyright (c) 2023-2026 PADL Software Pty Ltd
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

// MARK: - Streams and connections

/// `{entityID, streamIndex}` pair identifying one end of an ACMP connection
/// (IEEE 1722.1-2021 §8.2.1).
public struct StreamIdentification: Sendable, Hashable, CustomStringConvertible {
  public let entityID: UniqueIdentifier
  public let streamIndex: UInt16

  public init(entityID: UniqueIdentifier, streamIndex: UInt16) {
    self.entityID = entityID
    self.streamIndex = streamIndex
  }

  public var description: String {
    "\(entityID):\(streamIndex)"
  }
}

/// State of an ACMP connection, as returned by every connection-management command.
public struct StreamConnectionState: Sendable, Hashable {
  public let talkerStream: StreamIdentification
  public let listenerStream: StreamIdentification
  public let connectionCount: UInt16
  public let flags: ConnectionFlags
  /// The number of entries in a talker's connected listeners array, when the response carries
  /// it (CL_ENTRIES_VALID, IEEE 1722.1-2021 §8.2.1.18).
  public let connectedListenersEntries: UInt16?

  public init(
    talkerStream: StreamIdentification, listenerStream: StreamIdentification,
    connectionCount: UInt16, flags: ConnectionFlags, connectedListenersEntries: UInt16? = nil
  ) {
    self.talkerStream = talkerStream
    self.listenerStream = listenerStream
    self.connectionCount = connectionCount
    self.flags = flags
    self.connectedListenersEntries = connectedListenersEntries
  }

  init(_ acmpdu: Acmpdu) {
    self.init(
      talkerStream: acmpdu.talkerStream,
      listenerStream: acmpdu.listenerStream,
      connectionCount: acmpdu.connectionCount,
      flags: acmpdu.flags,
      connectedListenersEntries: acmpdu.flags.contains(.clEntriesValid) ? acmpdu.connectedListenersEntries : nil
    )
  }
}

/// One audio map entry, pairing a stream channel with a cluster channel
/// (IEEE 1722.1-2021 §7.2.19.1).
public struct AudioMapping: Sendable, Hashable {
  public let streamIndex: UInt16
  public let streamChannel: UInt16
  public let clusterOffset: UInt16
  public let clusterChannel: UInt16

  public init(
    streamIndex: UInt16, streamChannel: UInt16,
    clusterOffset: UInt16, clusterChannel: UInt16
  ) {
    self.streamIndex = streamIndex
    self.streamChannel = streamChannel
    self.clusterOffset = clusterOffset
    self.clusterChannel = clusterChannel
  }
}

extension AudioMapping: SerDes {
  static let length = 8

  public init(parsing input: inout ParserSpan) throws {
    streamIndex = try UInt16(parsingBigEndian: &input)
    streamChannel = try UInt16(parsingBigEndian: &input)
    clusterOffset = try UInt16(parsingBigEndian: &input)
    clusterChannel = try UInt16(parsingBigEndian: &input)
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint16: streamIndex)
    serializationContext.serialize(uint16: streamChannel)
    serializationContext.serialize(uint16: clusterOffset)
    serializationContext.serialize(uint16: clusterChannel)
  }
}

/// Probing status of a Milan listener stream (Milan 1.3 §5.3.8.6). Codes 4 to 7 are reserved.
public enum ProbingStatus: UInt8, Sendable {
  case disabled = 0
  case passive = 1
  case active = 2
  case completed = 3
}

/// The octet holding a 3-bit probing_status and a 5-bit acmp_status, in GET_STREAM_INFO responses
/// from before Milan 1.3 and GET_STREAM_INPUT_INFO_EX (Milan 1.3 §5.4.4.8) responses. The
/// codes are kept as received, since either may be reserved.
struct ProbingAcmpStatus {
  static let probingStatusShift = 5
  static let acmpStatusMask: UInt8 = 0x1F

  let probingStatusRaw: UInt8
  let acmpStatusRaw: UInt8

  init(_ octet: UInt8) {
    probingStatusRaw = octet >> Self.probingStatusShift
    acmpStatusRaw = octet & Self.acmpStatusMask
  }
}

/// GET_STREAM_INFO / SET_STREAM_INFO dynamic information (IEEE 1722.1-2021 §7.4.16.2), with
/// the pre-1.3 Milan extension fields when the entity reports them.
///
/// A SET carries only the fields its flags mark valid, so build it from an empty value rather
/// than a GET response, which reports state such as CONNECTED and MSRP_ACC_LAT_VALID; Milan
/// entities reject MSRP_ACC_LAT_VALID, and set a presentation time with SET_MAX_TRANSIT_TIME.
public struct StreamInfo: Sendable, Hashable, CustomStringConvertible {
  public var streamFormat: StreamFormat
  public var streamID: UniqueIdentifier
  public var msrpAccumulatedLatency: UInt32
  public var streamVlanID: UInt16
  public var streamInfoFlags: StreamInfoFlags
  public var streamDestMac: EUI48
  /// MSRP failure code and bridge ID, valid when `msrpFailureValid` is set.
  public var msrpFailureCode: UInt8
  public var msrpFailureBridgeID: UInt64
  public var streamInfoFlagsEx: StreamInfoFlagsEx?
  /// probing_status as received, reserved codes included; nil when the entity does not report
  /// it.
  public var probingStatusRaw: UInt8?
  /// acmp_status as received, reserved codes included; nil when the entity does not report it.
  public var acmpStatusRaw: UInt8?

  /// `probingStatusRaw`, or nil when that is not reported or is a reserved code.
  public var probingStatus: ProbingStatus? {
    probingStatusRaw.flatMap { ProbingStatus(rawValue: $0) }
  }

  /// `acmpStatusRaw`, which `AcmpStatus` represents for every five-bit code, reserved codes
  /// included; nil when that is not reported.
  public var acmpStatus: AcmpStatus? {
    acmpStatusRaw.flatMap { AcmpStatus(rawValue: UInt16($0)) }
  }

  public init(
    streamFormat: StreamFormat = StreamFormat(format: 0),
    streamID: UniqueIdentifier = UniqueIdentifier(0),
    msrpAccumulatedLatency: UInt32 = 0,
    streamVlanID: UInt16 = 0,
    streamInfoFlags: StreamInfoFlags = [],
    streamDestMac: EUI48 = [0, 0, 0, 0, 0, 0],
    msrpFailureCode: UInt8 = 0,
    msrpFailureBridgeID: UInt64 = 0,
    streamInfoFlagsEx: StreamInfoFlagsEx? = nil,
    probingStatusRaw: UInt8? = nil,
    acmpStatusRaw: UInt8? = nil
  ) {
    self.streamFormat = streamFormat
    self.streamID = streamID
    self.msrpAccumulatedLatency = msrpAccumulatedLatency
    self.streamVlanID = streamVlanID
    self.streamInfoFlags = streamInfoFlags
    self.streamDestMac = streamDestMac
    self.msrpFailureCode = msrpFailureCode
    self.msrpFailureBridgeID = msrpFailureBridgeID
    self.streamInfoFlagsEx = streamInfoFlagsEx
    self.probingStatusRaw = probingStatusRaw
    self.acmpStatusRaw = acmpStatusRaw
  }

  public var description: String {
    "StreamInfo(streamID: \(streamID)" +
      ", format: \(streamFormat)" +
      ", destMac: \(_macAddressToString(streamDestMac))" +
      ", vlan: \(streamVlanID)" +
      ", latency: \(msrpAccumulatedLatency) ns" +
      ", flags: \(streamInfoFlags.rawValue))"
  }

  // written out, as EUI48 (an InlineArray) is not Hashable
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.streamFormat == rhs.streamFormat &&
      lhs.streamID == rhs.streamID &&
      lhs.msrpAccumulatedLatency == rhs.msrpAccumulatedLatency &&
      lhs.streamVlanID == rhs.streamVlanID &&
      lhs.streamInfoFlags == rhs.streamInfoFlags &&
      _isEqualMacAddress(lhs.streamDestMac, rhs.streamDestMac) &&
      lhs.msrpFailureCode == rhs.msrpFailureCode &&
      lhs.msrpFailureBridgeID == rhs.msrpFailureBridgeID &&
      lhs.streamInfoFlagsEx == rhs.streamInfoFlagsEx &&
      lhs.probingStatusRaw == rhs.probingStatusRaw &&
      lhs.acmpStatusRaw == rhs.acmpStatusRaw
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(streamFormat)
    hasher.combine(streamID)
    hasher.combine(msrpAccumulatedLatency)
    hasher.combine(streamVlanID)
    hasher.combine(streamInfoFlags)
    _hashMacAddress(streamDestMac, into: &hasher)
    hasher.combine(msrpFailureCode)
    hasher.combine(msrpFailureBridgeID)
    hasher.combine(streamInfoFlagsEx)
    hasher.combine(probingStatusRaw)
    hasher.combine(acmpStatusRaw)
  }
}

/// Milan GET_STREAM_INPUT_INFO_EX information (Milan 1.3 §5.4.4.8): the talker a listener
/// stream is bound to, and the probing and ACMP states it has reached.
public struct StreamInputInfoEx: Sendable, Hashable, CustomStringConvertible {
  public let talkerStream: StreamIdentification
  /// probing_status as received, reserved codes included.
  public let probingStatusRaw: UInt8
  /// acmp_status as received, reserved codes included.
  public let acmpStatusRaw: UInt8

  /// `probingStatusRaw`, or nil for a reserved code.
  public var probingStatus: ProbingStatus? {
    ProbingStatus(rawValue: probingStatusRaw)
  }

  /// `acmpStatusRaw`, which `AcmpStatus` represents for every five-bit code, reserved codes
  /// included.
  public var acmpStatus: AcmpStatus? {
    AcmpStatus(rawValue: UInt16(acmpStatusRaw))
  }

  public init(
    talkerStream: StreamIdentification,
    probingStatusRaw: UInt8,
    acmpStatusRaw: UInt8
  ) {
    self.talkerStream = talkerStream
    self.probingStatusRaw = probingStatusRaw
    self.acmpStatusRaw = acmpStatusRaw
  }

  public var description: String {
    "StreamInputInfoEx(talker: \(talkerStream)" +
      ", probing: \(probingStatusRaw)" +
      ", acmp: \(acmpStatusRaw))"
  }
}

// MARK: - AVB interface

/// One MSRP traffic class mapping reported by GET_AVB_INFO (IEEE 1722.1-2021 §7.4.40.2).
public struct MsrpMapping: Sendable, Hashable {
  public let trafficClass: UInt8
  public let priority: UInt8
  public let vlanID: UInt16

  public init(trafficClass: UInt8, priority: UInt8, vlanID: UInt16) {
    self.trafficClass = trafficClass
    self.priority = priority
    self.vlanID = vlanID
  }
}

/// GET_AVB_INFO dynamic information (IEEE 1722.1-2021 §7.4.40.2).
public struct AvbInfo: Sendable, Hashable, CustomStringConvertible {
  public var gptpGrandmasterID: UniqueIdentifier
  /// Propagation delay to the link partner, in nanoseconds.
  public var propagationDelay: UInt32
  public var gptpDomainNumber: UInt8
  public var flags: AvbInfoFlags
  public var mappings: [MsrpMapping]

  public init(
    gptpGrandmasterID: UniqueIdentifier,
    propagationDelay: UInt32,
    gptpDomainNumber: UInt8,
    flags: AvbInfoFlags,
    mappings: [MsrpMapping] = []
  ) {
    self.gptpGrandmasterID = gptpGrandmasterID
    self.propagationDelay = propagationDelay
    self.gptpDomainNumber = gptpDomainNumber
    self.flags = flags
    self.mappings = mappings
  }

  public var description: String {
    "AvbInfo(gmID: \(gptpGrandmasterID)" +
      ", domain: \(gptpDomainNumber)" +
      ", flags: \(flags.rawValue)" +
      ", propagationDelay: \(propagationDelay) ns)"
  }
}

/// GET_AS_PATH dynamic information (IEEE 1722.1-2021 §7.4.41.2): the chain of gPTP clock
/// identities from the grandmaster to this interface.
public struct AsPath: Sendable, Hashable, CustomStringConvertible {
  public var sequence: [UniqueIdentifier]

  public init(sequence: [UniqueIdentifier]) {
    self.sequence = sequence
  }

  public var description: String {
    "AsPath([\(sequence.map(\.description).joined(separator: " -> "))])"
  }
}

/// The 32 counters returned by GET_COUNTERS (IEEE 1722.1-2021 §7.4.42.2); the valid flags,
/// typed per descriptor, say which are meaningful.
/// An ENTITY_AVAILABLE response (IEEE 1722.1-2021 §7.4.3.2); an IEEE 1722.1-2013 entity reports
/// no flags and no controllers.
public struct EntityAvailability: Sendable, Hashable {
  public var flags: EntityAvailableFlags
  /// Zero when the entity is not acquired.
  public var acquiredControllerID: UniqueIdentifier
  /// Zero when the entity is not locked.
  public var lockedControllerID: UniqueIdentifier

  public init(
    flags: EntityAvailableFlags = [],
    acquiredControllerID: UniqueIdentifier = UniqueIdentifier(0),
    lockedControllerID: UniqueIdentifier = UniqueIdentifier(0)
  ) {
    self.flags = flags
    self.acquiredControllerID = acquiredControllerID
    self.lockedControllerID = lockedControllerID
  }
}

public struct DescriptorCounters: Sendable, Hashable {
  public typealias Counters = InlineArray<32, UInt32>

  public static let count = Counters.count

  public let counters: Counters

  public init(_ counters: Counters) {
    self.counters = counters
  }

  /// Takes exactly `count` counters.
  public init(_ counters: [UInt32]) {
    precondition(counters.count == Self.count, "GET_COUNTERS returns \(Self.count) counters")
    self.counters = Counters { counters[$0] }
  }

  public subscript(index: Int) -> UInt32 { counters[index] }

  // written out, as InlineArray is not Hashable
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.counters.indices.allSatisfy { lhs.counters[$0] == rhs.counters[$0] }
  }

  public func hash(into hasher: inout Hasher) {
    for index in counters.indices {
      hasher.combine(counters[index])
    }
  }
}

// MARK: - Clocks

/// CLOCK_SOURCE descriptor clock_source_type (IEEE 1722.1-2021 Table 7-17).
public enum ClockSourceType: UInt16, Sendable {
  case `internal` = 0
  case external = 1
  case inputStream = 2
  case expansion = 0xFFFF
}

// MARK: - Operations

/// Operation type for START_OPERATION on a MEMORY_OBJECT (IEEE 1722.1-2021 Table 7-20).
public enum MemoryObjectOperationType: UInt16, Sendable {
  case store = 0x0000
  case storeAndReboot = 0x0001
  case read = 0x0002
  case erase = 0x0003
  case upload = 0x0004
}

/// Result of START_OPERATION. The entity assigns `operationID`; OPERATION_STATUS
/// notifications and ABORT_OPERATION refer to it.
public struct OperationResult: Sendable, Hashable, CustomStringConvertible {
  public let descriptorType: UInt16
  public let descriptorIndex: UInt16
  public let operationID: UInt16
  public let operationType: MemoryObjectOperationType
  public let payload: [UInt8]

  public init(
    descriptorType: UInt16,
    descriptorIndex: UInt16,
    operationID: UInt16,
    operationType: MemoryObjectOperationType,
    payload: [UInt8]
  ) {
    self.descriptorType = descriptorType
    self.descriptorIndex = descriptorIndex
    self.operationID = operationID
    self.operationType = operationType
    self.payload = payload
  }

  public var description: String {
    "OperationResult(descType: \(descriptorType), descIdx: \(descriptorIndex)" +
      ", opID: \(operationID), opType: \(operationType)" +
      ", payload: \(payload.count) bytes)"
  }
}

// MARK: - Milan

/// Packed `major.minor.patch.build` Milan version word, one byte each (Milan 1.3 §5.4.4.1).
public struct MilanVersion: Sendable, Hashable, CustomStringConvertible {
  public let rawValue: UInt32

  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public init(major: UInt8, minor: UInt8, patch: UInt8 = 0, build: UInt8 = 0) {
    rawValue = (UInt32(major) << 24) | (UInt32(minor) << 16) |
      (UInt32(patch) << 8) | UInt32(build)
  }

  public var major: UInt8 { UInt8((rawValue >> 24) & 0xFF) }
  public var minor: UInt8 { UInt8((rawValue >> 16) & 0xFF) }
  public var patch: UInt8 { UInt8((rawValue >> 8) & 0xFF) }
  public var build: UInt8 { UInt8(rawValue & 0xFF) }

  public var description: String { "\(major).\(minor).\(patch).\(build)" }
}

/// GET_MILAN_INFO response (Milan 1.3 §5.4.4.1).
public struct MilanInfo: Sendable, Hashable {
  public let protocolVersion: UInt32
  public let featuresFlags: MilanInfoFeaturesFlags
  public let certificationVersion: MilanVersion
  public let specificationVersion: MilanVersion

  public init(
    protocolVersion: UInt32,
    featuresFlags: MilanInfoFeaturesFlags,
    certificationVersion: MilanVersion,
    specificationVersion: MilanVersion
  ) {
    self.protocolVersion = protocolVersion
    self.featuresFlags = featuresFlags
    self.certificationVersion = certificationVersion
    self.specificationVersion = specificationVersion
  }
}

/// Media clock reference priority, from 0 to 255 (Milan 1.3 §7.6.1.2).
public typealias MediaClockReferencePriority = UInt8

/// Default media clock reference priorities by device category (Milan 1.3 §7.6.1.1, Table 7.3).
/// An entity may report any `MediaClockReferencePriority`, so responses carry the raw value.
public enum DefaultMediaClockReferencePriority: MediaClockReferencePriority, Sendable {
  /// The top of the range (§7.6.1.2), not a Table 7.3 category.
  case highest = 255
  case dedicatedGenerators = 240
  case matrixMixingDevices = 224
  case mixingConsoles = 208
  case stageboxes = 192
  case processors = 176
  case amplifiers = 160
  case recordingDevices = 144
  /// The priority of an entity that provides no data.
  case `default` = 128
  case effectProcessingDevices = 112
  case wirelessReceivers = 80
  case microphones = 64
  case instruments = 48
  /// The bottom of the range (§7.6.1.2), not a Table 7.3 category.
  case lowest = 0
}

/// SET/GET_MEDIA_CLOCK_REFERENCE_INFO fields (Milan 1.3 §5.4.4.4). `nil` means the field is
/// not valid: not being changed on a set, or not reported on a get.
public struct MediaClockReferenceInfo: Sendable, Hashable, CustomStringConvertible {
  public let userMediaClockPriority: MediaClockReferencePriority?
  public let mediaClockDomainName: String?

  public init(
    userMediaClockPriority: MediaClockReferencePriority? = nil,
    mediaClockDomainName: String? = nil
  ) {
    self.userMediaClockPriority = userMediaClockPriority
    self.mediaClockDomainName = mediaClockDomainName
  }

  public var description: String {
    var parts: [String] = []
    if let p = userMediaClockPriority { parts.append("userPriority: \(p)") }
    if let n = mediaClockDomainName { parts.append("domain: \"\(n)\"") }
    return "MediaClockReferenceInfo(\(parts.joined(separator: ", ")))"
  }
}

// MARK: - Discovered entities

/// An entity known through ADP (IEEE 1722.1-2021 §6.2.1). Fields common to every interface
/// are held once; per-interface fields are keyed by AVB interface index.
public struct Entity: Sendable, Hashable, CustomStringConvertible {
  /// Interface index used when the entity does not report `aemInterfaceIndexValid`.
  public static let globalAvbInterfaceIndex: UInt16 = 0xFFFF

  public struct InterfaceInformation: Sendable, Hashable {
    public var macAddress: EUI48
    /// Validity of the advertisement, in units of 2 seconds.
    public var validTime: UInt8
    public var availableIndex: UInt32
    public var gptpGrandmasterID: UniqueIdentifier?
    public var gptpDomainNumber: UInt8?

    public init(
      macAddress: EUI48,
      validTime: UInt8,
      availableIndex: UInt32,
      gptpGrandmasterID: UniqueIdentifier? = nil,
      gptpDomainNumber: UInt8? = nil
    ) {
      self.macAddress = macAddress
      self.validTime = validTime
      self.availableIndex = availableIndex
      self.gptpGrandmasterID = gptpGrandmasterID
      self.gptpDomainNumber = gptpDomainNumber
    }

    // written out, as EUI48 (an InlineArray) is not Hashable
    public static func == (lhs: Self, rhs: Self) -> Bool {
      _isEqualMacAddress(lhs.macAddress, rhs.macAddress) &&
        lhs.validTime == rhs.validTime &&
        lhs.availableIndex == rhs.availableIndex &&
        lhs.gptpGrandmasterID == rhs.gptpGrandmasterID &&
        lhs.gptpDomainNumber == rhs.gptpDomainNumber
    }

    public func hash(into hasher: inout Hasher) {
      _hashMacAddress(macAddress, into: &hasher)
      hasher.combine(validTime)
      hasher.combine(availableIndex)
      hasher.combine(gptpGrandmasterID)
      hasher.combine(gptpDomainNumber)
    }
  }

  public var entityID: UniqueIdentifier
  public var entityModelID: UniqueIdentifier
  public var entityCapabilities: EntityCapabilities
  public var talkerStreamSources: UInt16
  public var talkerCapabilities: TalkerCapabilities
  public var listenerStreamSinks: UInt16
  public var listenerCapabilities: ListenerCapabilities
  public var controllerCapabilities: ControllerCapabilities
  public var identifyControlIndex: UInt16?
  public var associationID: UniqueIdentifier?
  /// The current CONFIGURATION, when the entity advertises it (IEEE 1722.1-2021 Table 6-2,
  /// AEM_CONFIGURATION_INDEX_VALID).
  public var currentConfigurationIndex: UInt16?
  public var interfacesInformation: [UInt16: InterfaceInformation]

  /// Builds an entity with the single interface described by `adpdu`, received from
  /// `macAddress`. Optional fields are only populated when the matching capability says they
  /// are valid.
  public init(adpdu: Adpdu, macAddress: EUI48) {
    let capabilities = adpdu.entityCapabilities
    entityID = adpdu.entityID
    entityModelID = adpdu.entityModelID
    entityCapabilities = capabilities
    talkerStreamSources = adpdu.talkerStreamSources
    talkerCapabilities = adpdu.talkerCapabilities
    listenerStreamSinks = adpdu.listenerStreamSinks
    listenerCapabilities = adpdu.listenerCapabilities
    controllerCapabilities = adpdu.controllerCapabilities
    identifyControlIndex = capabilities.contains(.aemIdentifyControlIndexValid)
      ? adpdu.identifyControlIndex : nil
    associationID = capabilities.contains(.associationIDValid) ? adpdu.associationID : nil
    currentConfigurationIndex = capabilities.contains(.aemConfigurationIndexValid)
      ? adpdu.currentConfigurationIndex : nil

    let gptpSupported = capabilities.contains(.gptpSupported)
    let interfaceIndex = capabilities.contains(.aemInterfaceIndexValid)
      ? adpdu.interfaceIndex : Self.globalAvbInterfaceIndex
    interfacesInformation = [interfaceIndex: InterfaceInformation(
      macAddress: macAddress,
      validTime: adpdu.validTime,
      availableIndex: adpdu.availableIndex,
      gptpGrandmasterID: gptpSupported ? adpdu.gptpGrandmasterID : nil,
      gptpDomainNumber: gptpSupported ? adpdu.gptpDomainNumber : nil
    )]
  }

  /// Number of AVB interfaces on which this entity has been discovered.
  public var interfaceInformationCount: Int {
    interfacesInformation.count
  }

  /// A MAC address through which the entity can be reached, preferring the lowest interface.
  public var macAddress: EUI48? {
    interfacesInformation.min { $0.key < $1.key }?.value.macAddress
  }

  public var description: String {
    "Entity(id: \(entityID)" +
      ", modelID: \(entityModelID)" +
      ", talkerSources: \(talkerStreamSources)" +
      ", listenerSinks: \(listenerStreamSinks)" +
      (associationID.map { ", associationID: \($0)" } ?? "") +
      ")"
  }
}
