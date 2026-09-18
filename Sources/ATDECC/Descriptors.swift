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

// Every descriptor begins with descriptor_type and descriptor_index (IEEE 1722.1-2021 §7.2);
// the *_offset fields of variable-length descriptors count from the start of descriptor_type.
// Descriptor bodies are parsed from a span whose absolute position 0 is that start, so
// offsets can be sought to directly.
private let _descriptorHeaderLength = 4

// MARK: - Descriptor flags

/// STREAM_INPUT / STREAM_OUTPUT stream_flags (IEEE 1722.1-2021 §7.2.6.1).
public struct StreamFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let clockSyncSource = StreamFlags(rawValue: 1 << 0)
  public static let classA = StreamFlags(rawValue: 1 << 1)
  public static let classB = StreamFlags(rawValue: 1 << 2)
  public static let supportsEncrypted = StreamFlags(rawValue: 1 << 3)
  public static let primaryBackupSupported = StreamFlags(rawValue: 1 << 4)
  public static let primaryBackupValid = StreamFlags(rawValue: 1 << 5)
  public static let secondaryBackupSupported = StreamFlags(rawValue: 1 << 6)
  public static let secondaryBackupValid = StreamFlags(rawValue: 1 << 7)
  public static let tertiaryBackupSupported = StreamFlags(rawValue: 1 << 8)
  public static let tertiaryBackupValid = StreamFlags(rawValue: 1 << 9)
  public static let supportsAvtpUdpV4 = StreamFlags(rawValue: 1 << 10)
  public static let supportsAvtpUdpV6 = StreamFlags(rawValue: 1 << 11)
  public static let noSupportAvtpNative = StreamFlags(rawValue: 1 << 12)
  public static let timingFieldValid = StreamFlags(rawValue: 1 << 13)
  public static let noMediaClock = StreamFlags(rawValue: 1 << 14)
  public static let supportsNoSrp = StreamFlags(rawValue: 1 << 15)
}

/// JACK_INPUT / JACK_OUTPUT jack_flags (IEEE 1722.1-2021 §7.2.7.1).
public struct JackFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let clockSyncSource = JackFlags(rawValue: 1 << 0)
  public static let captive = JackFlags(rawValue: 1 << 1)
}

/// AVB_INTERFACE interface_flags (IEEE 1722.1-2021 §7.2.8.1).
public struct AvbInterfaceFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let gptpGrandmasterSupported = AvbInterfaceFlags(rawValue: 1 << 0)
  public static let gptpSupported = AvbInterfaceFlags(rawValue: 1 << 1)
  public static let srpSupported = AvbInterfaceFlags(rawValue: 1 << 2)
  public static let fqtssNotSupported = AvbInterfaceFlags(rawValue: 1 << 3)
  public static let scheduledTrafficSupported = AvbInterfaceFlags(rawValue: 1 << 4)
  public static let canListenToSelf = AvbInterfaceFlags(rawValue: 1 << 5)
  public static let canListenToOtherSelf = AvbInterfaceFlags(rawValue: 1 << 6)
}

/// CLOCK_SOURCE clock_source_flags (IEEE 1722.1-2021 §7.2.9.1).
public struct ClockSourceFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let streamID = ClockSourceFlags(rawValue: 1 << 0)
  public static let localID = ClockSourceFlags(rawValue: 1 << 1)
}

/// STREAM_PORT, EXTERNAL_PORT and INTERNAL_PORT port_flags (IEEE 1722.1-2021 §7.2.13.1).
public struct PortFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let clockSyncSource = PortFlags(rawValue: 1 << 0)
  public static let asyncSampleRateConv = PortFlags(rawValue: 1 << 1)
  public static let syncSampleRateConv = PortFlags(rawValue: 1 << 2)
}

/// PTP_INSTANCE flags (IEEE 1722.1-2021 Table 7-66).
public struct PtpInstanceFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let canSetInstanceEnable = PtpInstanceFlags(rawValue: 1 << 0)
  public static let canSetPriority1 = PtpInstanceFlags(rawValue: 1 << 1)
  public static let canSetPriority2 = PtpInstanceFlags(rawValue: 1 << 2)
  public static let canSetDomainNumber = PtpInstanceFlags(rawValue: 1 << 3)
  public static let canSetExternalPortConfiguration = PtpInstanceFlags(rawValue: 1 << 4)
  public static let canSetSlaveOnly = PtpInstanceFlags(rawValue: 1 << 5)
  public static let canEnablePerformance = PtpInstanceFlags(rawValue: 1 << 6)
  public static let performanceMonitoring = PtpInstanceFlags(rawValue: 1 << 30)
  public static let grandmasterCapable = PtpInstanceFlags(rawValue: 1 << 31)
}

/// PTP_PORT flags (IEEE 1722.1-2021 Table 7-69, which misnumbers CAN_OVERRIDE_COMPUTE_LINK_DELAY
/// as bit 29; it lies between bits 21 and 19).
public struct PtpPortFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let canSetEnable = PtpPortFlags(rawValue: 1 << 0)
  public static let canSetLinkDelayThreshold = PtpPortFlags(rawValue: 1 << 1)
  public static let canSetDelayMechanism = PtpPortFlags(rawValue: 1 << 2)
  public static let canSetDelayAsymmetry = PtpPortFlags(rawValue: 1 << 3)
  public static let canSetInitialMessageIntervals = PtpPortFlags(rawValue: 1 << 4)
  public static let canSetTimeouts = PtpPortFlags(rawValue: 1 << 5)
  public static let canOverrideAnnounceInterval = PtpPortFlags(rawValue: 1 << 6)
  public static let canOverrideSyncInterval = PtpPortFlags(rawValue: 1 << 7)
  public static let canOverridePdelayInterval = PtpPortFlags(rawValue: 1 << 8)
  public static let canOverrideGptpCapableInterval = PtpPortFlags(rawValue: 1 << 9)
  public static let canOverrideComputeNeighbor = PtpPortFlags(rawValue: 1 << 10)
  public static let canOverrideComputeLinkDelay = PtpPortFlags(rawValue: 1 << 11)
  public static let canOverrideOnestep = PtpPortFlags(rawValue: 1 << 12)
  public static let supportsRemoteIntervalSignal = PtpPortFlags(rawValue: 1 << 28)
  public static let supportsOnestepTransmit = PtpPortFlags(rawValue: 1 << 29)
  public static let supportsOnestepReceive = PtpPortFlags(rawValue: 1 << 30)
  public static let supportsUnicastNegotiate = PtpPortFlags(rawValue: 1 << 31)
}

// MARK: - Descriptor value types

// These keep values their tables do not define, as DescriptorType does.

/// JACK_INPUT / JACK_OUTPUT jack_type (IEEE 1722.1-2021 Table 7-12).
public struct JackType: RawRepresentable, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let speaker = JackType(rawValue: 0x0000)
  public static let headphone = JackType(rawValue: 0x0001)
  public static let analogMicrophone = JackType(rawValue: 0x0002)
  public static let spdif = JackType(rawValue: 0x0003)
  public static let adat = JackType(rawValue: 0x0004)
  public static let tdif = JackType(rawValue: 0x0005)
  public static let madi = JackType(rawValue: 0x0006)
  public static let unbalancedAnalog = JackType(rawValue: 0x0007)
  public static let balancedAnalog = JackType(rawValue: 0x0008)
  public static let digital = JackType(rawValue: 0x0009)
  public static let midi = JackType(rawValue: 0x000A)
  public static let aesEbu = JackType(rawValue: 0x000B)
  public static let compositeVideo = JackType(rawValue: 0x000C)
  public static let sVhsVideo = JackType(rawValue: 0x000D)
  public static let componentVideo = JackType(rawValue: 0x000E)
  public static let dvi = JackType(rawValue: 0x000F)
  public static let hdmi = JackType(rawValue: 0x0010)
  public static let udi = JackType(rawValue: 0x0011)
  public static let displayPort = JackType(rawValue: 0x0012)
  public static let antenna = JackType(rawValue: 0x0013)
  public static let analogTuner = JackType(rawValue: 0x0014)
  public static let ethernet = JackType(rawValue: 0x0015)
  public static let wifi = JackType(rawValue: 0x0016)
  public static let usb = JackType(rawValue: 0x0017)
  public static let pci = JackType(rawValue: 0x0018)
  public static let pciE = JackType(rawValue: 0x0019)
  public static let scsi = JackType(rawValue: 0x001A)
  public static let ata = JackType(rawValue: 0x001B)
  public static let imager = JackType(rawValue: 0x001C)
  public static let ir = JackType(rawValue: 0x001D)
  public static let thunderbolt = JackType(rawValue: 0x001E)
  public static let sata = JackType(rawValue: 0x001F)
  public static let smpteLtc = JackType(rawValue: 0x0020)
  public static let digitalMicrophone = JackType(rawValue: 0x0021)
  public static let audioMediaClock = JackType(rawValue: 0x0022)
  public static let videoMediaClock = JackType(rawValue: 0x0023)
  public static let gnssClock = JackType(rawValue: 0x0024)
  public static let pps = JackType(rawValue: 0x0025)
  public static let expansion = JackType(rawValue: 0xFFFF)
}

/// MEMORY_OBJECT memory_object_type (IEEE 1722.1-2021 Table 7-19).
public struct MemoryObjectType: RawRepresentable, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let firmwareImage = MemoryObjectType(rawValue: 0x0000)
  public static let vendorSpecific = MemoryObjectType(rawValue: 0x0001)
  public static let crashDump = MemoryObjectType(rawValue: 0x0002)
  public static let logObject = MemoryObjectType(rawValue: 0x0003)
  public static let autostartSettings = MemoryObjectType(rawValue: 0x0004)
  public static let snapshotSettings = MemoryObjectType(rawValue: 0x0005)
  public static let svgManufacturer = MemoryObjectType(rawValue: 0x0006)
  public static let svgEntity = MemoryObjectType(rawValue: 0x0007)
  public static let svgGeneric = MemoryObjectType(rawValue: 0x0008)
  public static let pngManufacturer = MemoryObjectType(rawValue: 0x0009)
  public static let pngEntity = MemoryObjectType(rawValue: 0x000A)
  public static let pngGeneric = MemoryObjectType(rawValue: 0x000B)
  public static let daeManufacturer = MemoryObjectType(rawValue: 0x000C)
  public static let daeEntity = MemoryObjectType(rawValue: 0x000D)
  public static let daeGeneric = MemoryObjectType(rawValue: 0x000E)
}

/// AUDIO_CLUSTER format (IEEE 1722.1-2021 Table 7-28).
public struct AudioClusterFormat: RawRepresentable, Sendable, Hashable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let iec60958 = AudioClusterFormat(rawValue: 0x00)
  public static let mbla = AudioClusterFormat(rawValue: 0x40)
  public static let midi = AudioClusterFormat(rawValue: 0x80)
  public static let smpte = AudioClusterFormat(rawValue: 0x88)
}

/// TIMING algorithm (IEEE 1722.1-2021 Table 7-64).
public struct TimingAlgorithm: RawRepresentable, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let single = TimingAlgorithm(rawValue: 0x0000)
  public static let fallback = TimingAlgorithm(rawValue: 0x0001)
  public static let combined = TimingAlgorithm(rawValue: 0x0002)
}

/// PTP_PORT port_type (IEEE 1722.1-2021 Table 7-68).
public struct PtpPortType: RawRepresentable, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let p2pLinkLayer = PtpPortType(rawValue: 0x0000)
  public static let p2pMulticastUdpV4 = PtpPortType(rawValue: 0x0001)
  public static let p2pMulticastUdpV6 = PtpPortType(rawValue: 0x0002)
  public static let timingMeasurement = PtpPortType(rawValue: 0x0003)
  public static let fineTimingMeasurement = PtpPortType(rawValue: 0x0004)
  public static let e2eLinkLayer = PtpPortType(rawValue: 0x0005)
  public static let e2eMulticastUdpV4 = PtpPortType(rawValue: 0x0006)
  public static let e2eMulticastUdpV6 = PtpPortType(rawValue: 0x0007)
  public static let p2pUnicastUdpV4 = PtpPortType(rawValue: 0x0008)
  public static let p2pUnicastUdpV6 = PtpPortType(rawValue: 0x0009)
  public static let e2eUnicastUdpV4 = PtpPortType(rawValue: 0x000A)
  public static let e2eUnicastUdpV6 = PtpPortType(rawValue: 0x000B)
}

/// CONTROL control_value_type (IEEE 1722.1-2021 §7.3.6.1): the read only and unknown value flags,
/// then a 14-bit value type.
public struct ControlValueType: RawRepresentable, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public init(_ kind: Kind, isReadOnly: Bool = false, isValueUnknown: Bool = false) {
    rawValue = kind.rawValue & 0x3FFF | (isReadOnly ? 0x8000 : 0) | (isValueUnknown ? 0x4000 : 0)
  }

  public var isReadOnly: Bool { rawValue & 0x8000 != 0 }
  public var isValueUnknown: Bool { rawValue & 0x4000 != 0 }
  public var kind: Kind { Kind(rawValue: rawValue & 0x3FFF) }

  /// value_type (IEEE 1722.1-2021 Table 7-121).
  public struct Kind: RawRepresentable, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let linearInt8 = Kind(rawValue: 0x0000)
    public static let linearUInt8 = Kind(rawValue: 0x0001)
    public static let linearInt16 = Kind(rawValue: 0x0002)
    public static let linearUInt16 = Kind(rawValue: 0x0003)
    public static let linearInt32 = Kind(rawValue: 0x0004)
    public static let linearUInt32 = Kind(rawValue: 0x0005)
    public static let linearInt64 = Kind(rawValue: 0x0006)
    public static let linearUInt64 = Kind(rawValue: 0x0007)
    public static let linearFloat = Kind(rawValue: 0x0008)
    public static let linearDouble = Kind(rawValue: 0x0009)
    public static let selectorInt8 = Kind(rawValue: 0x000A)
    public static let selectorUInt8 = Kind(rawValue: 0x000B)
    public static let selectorInt16 = Kind(rawValue: 0x000C)
    public static let selectorUInt16 = Kind(rawValue: 0x000D)
    public static let selectorInt32 = Kind(rawValue: 0x000E)
    public static let selectorUInt32 = Kind(rawValue: 0x000F)
    public static let selectorInt64 = Kind(rawValue: 0x0010)
    public static let selectorUInt64 = Kind(rawValue: 0x0011)
    public static let selectorFloat = Kind(rawValue: 0x0012)
    public static let selectorDouble = Kind(rawValue: 0x0013)
    public static let selectorString = Kind(rawValue: 0x0014)
    public static let arrayInt8 = Kind(rawValue: 0x0015)
    public static let arrayUInt8 = Kind(rawValue: 0x0016)
    public static let arrayInt16 = Kind(rawValue: 0x0017)
    public static let arrayUInt16 = Kind(rawValue: 0x0018)
    public static let arrayInt32 = Kind(rawValue: 0x0019)
    public static let arrayUInt32 = Kind(rawValue: 0x001A)
    public static let arrayInt64 = Kind(rawValue: 0x001B)
    public static let arrayUInt64 = Kind(rawValue: 0x001C)
    public static let arrayFloat = Kind(rawValue: 0x001D)
    public static let arrayDouble = Kind(rawValue: 0x001E)
    public static let utf8 = Kind(rawValue: 0x001F)
    public static let bodePlot = Kind(rawValue: 0x0020)
    public static let smpteTime = Kind(rawValue: 0x0021)
    public static let sampleRate = Kind(rawValue: 0x0022)
    public static let gptpTime = Kind(rawValue: 0x0023)
    public static let vendor = Kind(rawValue: 0x3FFE)
    public static let expansion = Kind(rawValue: 0x3FFF)
  }
}

// MARK: - Descriptors

/// ENTITY descriptor (IEEE 1722.1-2021 §7.2.1).
public struct EntityDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 308

  public var entityID: UniqueIdentifier
  public var entityModelID: UniqueIdentifier
  public var entityCapabilities: EntityCapabilities
  public var talkerStreamSources: UInt16
  public var talkerCapabilities: TalkerCapabilities
  public var listenerStreamSinks: UInt16
  public var listenerCapabilities: ListenerCapabilities
  public var controllerCapabilities: ControllerCapabilities
  public var availableIndex: UInt32
  public var associationID: UniqueIdentifier
  public var entityName: String
  public var vendorNameString: LocalizedStringReference
  public var modelNameString: LocalizedStringReference
  public var firmwareVersion: String
  public var groupName: String
  public var serialNumber: String
  public var configurationsCount: UInt16
  public var currentConfiguration: UInt16

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    entityID = try UniqueIdentifier(parsing: &input)
    entityModelID = try UniqueIdentifier(parsing: &input)
    entityCapabilities = try EntityCapabilities(rawValue: UInt32(parsingBigEndian: &input))
    talkerStreamSources = try UInt16(parsingBigEndian: &input)
    talkerCapabilities = try TalkerCapabilities(rawValue: UInt16(parsingBigEndian: &input))
    listenerStreamSinks = try UInt16(parsingBigEndian: &input)
    listenerCapabilities = try ListenerCapabilities(rawValue: UInt16(parsingBigEndian: &input))
    controllerCapabilities =
      try ControllerCapabilities(rawValue: UInt32(parsingBigEndian: &input))
    availableIndex = try UInt32(parsingBigEndian: &input)
    associationID = try UniqueIdentifier(parsing: &input)
    entityName = try String(parsingAvdeccFixedString: &input)
    vendorNameString = try LocalizedStringReference(parsing: &input)
    modelNameString = try LocalizedStringReference(parsing: &input)
    firmwareVersion = try String(parsingAvdeccFixedString: &input)
    groupName = try String(parsingAvdeccFixedString: &input)
    serialNumber = try String(parsingAvdeccFixedString: &input)
    configurationsCount = try UInt16(parsingBigEndian: &input)
    currentConfiguration = try UInt16(parsingBigEndian: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    try context.serialize(entityID)
    try context.serialize(entityModelID)
    context.serialize(uint32: entityCapabilities.rawValue)
    context.serialize(uint16: talkerStreamSources)
    context.serialize(uint16: talkerCapabilities.rawValue)
    context.serialize(uint16: listenerStreamSinks)
    context.serialize(uint16: listenerCapabilities.rawValue)
    context.serialize(uint32: controllerCapabilities.rawValue)
    context.serialize(uint32: availableIndex)
    try context.serialize(associationID)
    context.serialize(avdeccFixedString: entityName)
    try context.serialize(vendorNameString)
    try context.serialize(modelNameString)
    context.serialize(avdeccFixedString: firmwareVersion)
    context.serialize(avdeccFixedString: groupName)
    context.serialize(avdeccFixedString: serialNumber)
    context.serialize(uint16: configurationsCount)
    context.serialize(uint16: currentConfiguration)
  }

  public var description: String {
    "EntityDescriptor(id: \(entityID), modelID: \(entityModelID)" +
      ", name: \"\(entityName)\"" +
      ", firmware: \"\(firmwareVersion)\"" +
      ", group: \"\(groupName)\"" +
      ", serial: \"\(serialNumber)\"" +
      ", talkerSources: \(talkerStreamSources)" +
      ", listenerSinks: \(listenerStreamSinks)" +
      ", availableIndex: \(availableIndex)" +
      ", configurations: \(configurationsCount)" +
      ", currentConfiguration: \(currentConfiguration))"
  }
}

/// CONFIGURATION descriptor (IEEE 1722.1-2021 §7.2.2).
public struct ConfigurationDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 70

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  /// Number of descriptors of each type in the configuration.
  public var descriptorCounts: [DescriptorType: UInt16]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    let descriptorCountsCount = try UInt16(parsingBigEndian: &input)
    let descriptorCountsOffset = try UInt16(parsingBigEndian: &input)
    var counts = try input.seeking(toAbsoluteOffset: input.descriptorOffset(descriptorCountsOffset))
    // descriptor_type, count
    try counts.requireRemaining(descriptorCountsCount, of: 2 * MemoryLayout<UInt16>.size)
    descriptorCounts = [:]
    for _ in 0..<descriptorCountsCount {
      let descriptorType = try DescriptorType(parsing: &counts)
      descriptorCounts[descriptorType] = try UInt16(parsingBigEndian: &counts)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    try context.serialize(count: descriptorCounts.count)
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    for (descriptorType, count) in descriptorCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
      try context.serialize(descriptorType)
      context.serialize(uint16: count)
    }
  }

  /// Number of child descriptors of `type` declared by this configuration.
  public func descriptorCount(_ type: DescriptorType) -> UInt16 {
    descriptorCounts[type] ?? 0
  }

  public var audioUnitCount: UInt16 { descriptorCount(.audioUnit) }
  public var videoUnitCount: UInt16 { descriptorCount(.videoUnit) }
  public var sensorUnitCount: UInt16 { descriptorCount(.sensorUnit) }
  public var streamInputCount: UInt16 { descriptorCount(.streamInput) }
  public var streamOutputCount: UInt16 { descriptorCount(.streamOutput) }
  public var jackInputCount: UInt16 { descriptorCount(.jackInput) }
  public var jackOutputCount: UInt16 { descriptorCount(.jackOutput) }
  public var avbInterfaceCount: UInt16 { descriptorCount(.avbInterface) }
  public var clockSourceCount: UInt16 { descriptorCount(.clockSource) }
  public var memoryObjectCount: UInt16 { descriptorCount(.memoryObject) }
  public var localeCount: UInt16 { descriptorCount(.locale) }
  public var controlCount: UInt16 { descriptorCount(.control) }
  public var clockDomainCount: UInt16 { descriptorCount(.clockDomain) }
  public var timingCount: UInt16 { descriptorCount(.timing) }
  public var ptpInstanceCount: UInt16 { descriptorCount(.ptpInstance) }

  public var description: String {
    "ConfigurationDescriptor(name: \"\(objectName)\"" +
      ", audioUnits: \(audioUnitCount)" +
      ", streamInputs: \(streamInputCount)" +
      ", streamOutputs: \(streamOutputCount)" +
      ", clockDomains: \(clockDomainCount))"
  }
}

/// AUDIO_UNIT descriptor (IEEE 1722.1-2021 §7.2.3).
public struct AudioUnitDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 140

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var clockDomainIndex: UInt16
  public var numberOfStreamInputPorts: UInt16
  public var baseStreamInputPort: UInt16
  public var numberOfStreamOutputPorts: UInt16
  public var baseStreamOutputPort: UInt16
  public var numberOfExternalInputPorts: UInt16
  public var baseExternalInputPort: UInt16
  public var numberOfExternalOutputPorts: UInt16
  public var baseExternalOutputPort: UInt16
  public var numberOfInternalInputPorts: UInt16
  public var baseInternalInputPort: UInt16
  public var numberOfInternalOutputPorts: UInt16
  public var baseInternalOutputPort: UInt16
  public var numberOfControls: UInt16
  public var baseControl: UInt16
  public var numberOfSignalSelectors: UInt16
  public var baseSignalSelector: UInt16
  public var numberOfMixers: UInt16
  public var baseMixer: UInt16
  public var numberOfMatrices: UInt16
  public var baseMatrix: UInt16
  public var numberOfSplitters: UInt16
  public var baseSplitter: UInt16
  public var numberOfCombiners: UInt16
  public var baseCombiner: UInt16
  public var numberOfDemultiplexers: UInt16
  public var baseDemultiplexer: UInt16
  public var numberOfMultiplexers: UInt16
  public var baseMultiplexer: UInt16
  public var numberOfTranscoders: UInt16
  public var baseTranscoder: UInt16
  public var numberOfControlBlocks: UInt16
  public var baseControlBlock: UInt16
  public var currentSamplingRate: SamplingRate
  /// Sampling rates this audio unit can be switched to with SET_SAMPLING_RATE, in wire order.
  public var samplingRates: [SamplingRate]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    clockDomainIndex = try UInt16(parsingBigEndian: &input)
    numberOfStreamInputPorts = try UInt16(parsingBigEndian: &input)
    baseStreamInputPort = try UInt16(parsingBigEndian: &input)
    numberOfStreamOutputPorts = try UInt16(parsingBigEndian: &input)
    baseStreamOutputPort = try UInt16(parsingBigEndian: &input)
    numberOfExternalInputPorts = try UInt16(parsingBigEndian: &input)
    baseExternalInputPort = try UInt16(parsingBigEndian: &input)
    numberOfExternalOutputPorts = try UInt16(parsingBigEndian: &input)
    baseExternalOutputPort = try UInt16(parsingBigEndian: &input)
    numberOfInternalInputPorts = try UInt16(parsingBigEndian: &input)
    baseInternalInputPort = try UInt16(parsingBigEndian: &input)
    numberOfInternalOutputPorts = try UInt16(parsingBigEndian: &input)
    baseInternalOutputPort = try UInt16(parsingBigEndian: &input)
    numberOfControls = try UInt16(parsingBigEndian: &input)
    baseControl = try UInt16(parsingBigEndian: &input)
    numberOfSignalSelectors = try UInt16(parsingBigEndian: &input)
    baseSignalSelector = try UInt16(parsingBigEndian: &input)
    numberOfMixers = try UInt16(parsingBigEndian: &input)
    baseMixer = try UInt16(parsingBigEndian: &input)
    numberOfMatrices = try UInt16(parsingBigEndian: &input)
    baseMatrix = try UInt16(parsingBigEndian: &input)
    numberOfSplitters = try UInt16(parsingBigEndian: &input)
    baseSplitter = try UInt16(parsingBigEndian: &input)
    numberOfCombiners = try UInt16(parsingBigEndian: &input)
    baseCombiner = try UInt16(parsingBigEndian: &input)
    numberOfDemultiplexers = try UInt16(parsingBigEndian: &input)
    baseDemultiplexer = try UInt16(parsingBigEndian: &input)
    numberOfMultiplexers = try UInt16(parsingBigEndian: &input)
    baseMultiplexer = try UInt16(parsingBigEndian: &input)
    numberOfTranscoders = try UInt16(parsingBigEndian: &input)
    baseTranscoder = try UInt16(parsingBigEndian: &input)
    numberOfControlBlocks = try UInt16(parsingBigEndian: &input)
    baseControlBlock = try UInt16(parsingBigEndian: &input)
    currentSamplingRate = try SamplingRate(parsing: &input)
    let samplingRatesOffset = try UInt16(parsingBigEndian: &input)
    let numberOfSamplingRates = try UInt16(parsingBigEndian: &input)
    var rates = try input.seeking(toAbsoluteOffset: input.descriptorOffset(samplingRatesOffset))
    try rates.requireRemaining(numberOfSamplingRates, of: MemoryLayout<UInt32>.size)
    samplingRates = try (0..<numberOfSamplingRates).map { _ in
      try SamplingRate(parsing: &rates)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    for value in [
      clockDomainIndex,
      numberOfStreamInputPorts, baseStreamInputPort,
      numberOfStreamOutputPorts, baseStreamOutputPort,
      numberOfExternalInputPorts, baseExternalInputPort,
      numberOfExternalOutputPorts, baseExternalOutputPort,
      numberOfInternalInputPorts, baseInternalInputPort,
      numberOfInternalOutputPorts, baseInternalOutputPort,
      numberOfControls, baseControl,
      numberOfSignalSelectors, baseSignalSelector,
      numberOfMixers, baseMixer,
      numberOfMatrices, baseMatrix,
      numberOfSplitters, baseSplitter,
      numberOfCombiners, baseCombiner,
      numberOfDemultiplexers, baseDemultiplexer,
      numberOfMultiplexers, baseMultiplexer,
      numberOfTranscoders, baseTranscoder,
      numberOfControlBlocks, baseControlBlock,
    ] {
      context.serialize(uint16: value)
    }
    try context.serialize(currentSamplingRate)
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    try context.serialize(count: samplingRates.count)
    for rate in samplingRates {
      try context.serialize(rate)
    }
  }

  public var description: String {
    "AudioUnitDescriptor(name: \"\(objectName)\"" +
      ", clockDomain: \(clockDomainIndex)" +
      ", inputPorts: \(numberOfStreamInputPorts), outputPorts: \(numberOfStreamOutputPorts)" +
      ", controls: \(numberOfControls)" +
      ", currentSamplingRate: \(currentSamplingRate)" +
      ", samplingRates: \(samplingRates.count))"
  }
}

/// STREAM_INPUT / STREAM_OUTPUT descriptor (IEEE 1722.1-2021 §7.2.6), including the Milan
/// redundancy extension when present.
public struct StreamDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 128
  // redundant_offset and number_of_redundant_streams (Milan 1.3 Annex C, Table C.1)
  static let redundancyFieldsLength = 4

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var clockDomainIndex: UInt16
  public var streamFlags: StreamFlags
  public var currentFormat: StreamFormat
  public var backupTalkerEntityID0: UniqueIdentifier
  public var backupTalkerUniqueID0: UInt16
  public var backupTalkerEntityID1: UniqueIdentifier
  public var backupTalkerUniqueID1: UInt16
  public var backupTalkerEntityID2: UniqueIdentifier
  public var backupTalkerUniqueID2: UInt16
  public var backedupTalkerEntityID: UniqueIdentifier
  public var backedupTalkerUniqueID: UInt16
  public var avbInterfaceIndex: UInt16
  /// Buffer length in nanoseconds.
  public var bufferLength: UInt32
  /// Stream formats this stream supports, in wire order.
  public var formats: [StreamFormat]
  /// Indices of streams that form a redundant set with this one (Milan).
  public var redundantStreams: [UInt16]
  /// The TIMING descriptor that is the source of the stream's gPTP time (IEEE 1722.1-2021
  /// Table 7-8); nil when the descriptor has no timing field.
  public var timing: DescriptorIndex?

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    clockDomainIndex = try UInt16(parsingBigEndian: &input)
    streamFlags = try StreamFlags(rawValue: UInt16(parsingBigEndian: &input))
    currentFormat = try StreamFormat(parsing: &input)
    let formatsOffset = try UInt16(parsingBigEndian: &input)
    let numberOfFormats = try UInt16(parsingBigEndian: &input)
    backupTalkerEntityID0 = try UniqueIdentifier(parsing: &input)
    backupTalkerUniqueID0 = try UInt16(parsingBigEndian: &input)
    backupTalkerEntityID1 = try UniqueIdentifier(parsing: &input)
    backupTalkerUniqueID1 = try UInt16(parsingBigEndian: &input)
    backupTalkerEntityID2 = try UniqueIdentifier(parsing: &input)
    backupTalkerUniqueID2 = try UInt16(parsingBigEndian: &input)
    backedupTalkerEntityID = try UniqueIdentifier(parsing: &input)
    backedupTalkerUniqueID = try UInt16(parsingBigEndian: &input)
    avbInterfaceIndex = try UInt16(parsingBigEndian: &input)
    bufferLength = try UInt32(parsingBigEndian: &input)

    // the redundancy fields are present when formats do not immediately follow buffer_length
    if Int(formatsOffset) - input.startPosition >= Self.redundancyFieldsLength {
      let redundantOffset = try UInt16(parsingBigEndian: &input)
      let numberOfRedundantStreams = try UInt16(parsingBigEndian: &input)
      // as la_avdecc does, reject formats that run into the redundant streams following them
      if redundantOffset >= formatsOffset,
         Int(numberOfFormats) * MemoryLayout<UInt64>.size > Int(redundantOffset - formatsOffset)
      {
        throw AvdeccCodecError.invalidOffset(Int(redundantOffset))
      }
      var redundant = try input.seeking(toAbsoluteOffset: input.descriptorOffset(redundantOffset))
      try redundant.requireRemaining(numberOfRedundantStreams, of: MemoryLayout<UInt16>.size)
      redundantStreams = try (0..<numberOfRedundantStreams).map { _ in
        try UInt16(parsingBigEndian: &redundant)
      }
      // IEEE 1722.1-2021 adds timing after the redundancy fields
      timing = Int(formatsOffset) - input.startPosition >= MemoryLayout<UInt16>.size
        ? try UInt16(parsingBigEndian: &input) : nil
    } else {
      redundantStreams = []
      timing = nil
    }

    var formatsSpan = try input.seeking(toAbsoluteOffset: input.descriptorOffset(formatsOffset))
    try formatsSpan.requireRemaining(numberOfFormats, of: MemoryLayout<UInt64>.size)
    formats = try (0..<numberOfFormats).map { _ in
      try StreamFormat(parsing: &formatsSpan)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    // timing follows the redundancy fields, which are written for it even with no redundant streams
    let hasRedundancyFields = !redundantStreams.isEmpty || timing != nil
    let formatsOffset = _descriptorHeaderLength + Self.bodyLength +
      (hasRedundancyFields ? Self.redundancyFieldsLength : 0) +
      (timing == nil ? 0 : MemoryLayout<UInt16>.size)
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint16: clockDomainIndex)
    context.serialize(uint16: streamFlags.rawValue)
    try context.serialize(currentFormat)
    context.serialize(uint16: UInt16(formatsOffset))
    try context.serialize(count: formats.count)
    try context.serialize(backupTalkerEntityID0)
    context.serialize(uint16: backupTalkerUniqueID0)
    try context.serialize(backupTalkerEntityID1)
    context.serialize(uint16: backupTalkerUniqueID1)
    try context.serialize(backupTalkerEntityID2)
    context.serialize(uint16: backupTalkerUniqueID2)
    try context.serialize(backedupTalkerEntityID)
    context.serialize(uint16: backedupTalkerUniqueID)
    context.serialize(uint16: avbInterfaceIndex)
    context.serialize(uint32: bufferLength)
    if hasRedundancyFields {
      try context.serialize(count: formatsOffset + formats.count * 8)
      try context.serialize(count: redundantStreams.count)
    }
    if let timing {
      context.serialize(uint16: timing)
    }
    for format in formats {
      try context.serialize(format)
    }
    for index in redundantStreams {
      context.serialize(uint16: index)
    }
  }

  public var description: String {
    "StreamDescriptor(name: \"\(objectName)\"" +
      ", currentFormat: \(currentFormat)" +
      ", clockDomain: \(clockDomainIndex)" +
      ", avbInterface: \(avbInterfaceIndex)" +
      ", buffer: \(bufferLength) ns" +
      ", formats: \(formats.count))"
  }
}

/// JACK_INPUT / JACK_OUTPUT descriptor (IEEE 1722.1-2021 §7.2.7).
public struct JackDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 74

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var jackFlags: JackFlags
  public var jackType: JackType
  public var numberOfControls: UInt16
  public var baseControl: UInt16

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    jackFlags = try JackFlags(rawValue: UInt16(parsingBigEndian: &input))
    jackType = try JackType(rawValue: UInt16(parsingBigEndian: &input))
    numberOfControls = try UInt16(parsingBigEndian: &input)
    baseControl = try UInt16(parsingBigEndian: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint16: jackFlags.rawValue)
    context.serialize(uint16: jackType.rawValue)
    context.serialize(uint16: numberOfControls)
    context.serialize(uint16: baseControl)
  }

  public var description: String {
    "JackDescriptor(name: \"\(objectName)\", controls: \(numberOfControls))"
  }
}

/// AVB_INTERFACE descriptor (IEEE 1722.1-2021 §7.2.8).
public struct AvbInterfaceDescriptor: Sendable, Hashable, CustomStringConvertible {
  /// Up to port_number; number_of_controls and base_control follow when present (Table 7-13).
  static let bodyLength = 94

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var macAddress: EUI48
  public var interfaceFlags: AvbInterfaceFlags
  public var clockIdentity: UniqueIdentifier
  public var priority1: UInt8
  public var clockClass: UInt8
  public var offsetScaledLogVariance: UInt16
  public var clockAccuracy: UInt8
  public var priority2: UInt8
  public var domainNumber: UInt8
  public var logSyncInterval: UInt8
  public var logAnnounceInterval: UInt8
  public var logPDelayInterval: UInt8
  public var portNumber: UInt16
  /// The interface's controls (IEEE 1722.1-2021 Table 7-16); nil in an IEEE 1722.1-2013
  /// descriptor, which ends at `portNumber` and is written back as it was read.
  public var numberOfControls: UInt16?
  public var baseControl: DescriptorIndex?

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    macAddress = try _eui48(parsing: &input)
    interfaceFlags = try AvbInterfaceFlags(rawValue: UInt16(parsingBigEndian: &input))
    clockIdentity = try UniqueIdentifier(parsing: &input)
    priority1 = try UInt8(parsing: &input)
    clockClass = try UInt8(parsing: &input)
    offsetScaledLogVariance = try UInt16(parsingBigEndian: &input)
    clockAccuracy = try UInt8(parsing: &input)
    priority2 = try UInt8(parsing: &input)
    domainNumber = try UInt8(parsing: &input)
    logSyncInterval = try UInt8(parsing: &input)
    logAnnounceInterval = try UInt8(parsing: &input)
    logPDelayInterval = try UInt8(parsing: &input)
    portNumber = try UInt16(parsingBigEndian: &input)
    if input.count >= 4 {
      numberOfControls = try UInt16(parsingBigEndian: &input)
      baseControl = try UInt16(parsingBigEndian: &input)
    } else {
      numberOfControls = nil
      baseControl = nil
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(eui48: macAddress)
    context.serialize(uint16: interfaceFlags.rawValue)
    try context.serialize(clockIdentity)
    context.serialize(uint8: priority1)
    context.serialize(uint8: clockClass)
    context.serialize(uint16: offsetScaledLogVariance)
    context.serialize(uint8: clockAccuracy)
    context.serialize(uint8: priority2)
    context.serialize(uint8: domainNumber)
    context.serialize(uint8: logSyncInterval)
    context.serialize(uint8: logAnnounceInterval)
    context.serialize(uint8: logPDelayInterval)
    context.serialize(uint16: portNumber)
    guard numberOfControls != nil || baseControl != nil else { return }
    context.serialize(uint16: numberOfControls ?? 0)
    context.serialize(uint16: baseControl ?? 0)
  }

  public var description: String {
    "AvbInterfaceDescriptor(name: \"\(objectName)\"" +
      ", mac: \(_macAddressToString(macAddress))" +
      ", clockIdentity: \(clockIdentity)" +
      ", priority1: \(priority1), priority2: \(priority2)" +
      ", clockClass: \(clockClass), domain: \(domainNumber))"
  }

  // written out, as EUI48 (an InlineArray) is not Hashable
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.objectName == rhs.objectName &&
      lhs.localizedDescription == rhs.localizedDescription &&
      _isEqualMacAddress(lhs.macAddress, rhs.macAddress) &&
      lhs.interfaceFlags == rhs.interfaceFlags &&
      lhs.clockIdentity == rhs.clockIdentity &&
      lhs.priority1 == rhs.priority1 &&
      lhs.clockClass == rhs.clockClass &&
      lhs.offsetScaledLogVariance == rhs.offsetScaledLogVariance &&
      lhs.clockAccuracy == rhs.clockAccuracy &&
      lhs.priority2 == rhs.priority2 &&
      lhs.domainNumber == rhs.domainNumber &&
      lhs.logSyncInterval == rhs.logSyncInterval &&
      lhs.logAnnounceInterval == rhs.logAnnounceInterval &&
      lhs.logPDelayInterval == rhs.logPDelayInterval &&
      lhs.portNumber == rhs.portNumber &&
      lhs.numberOfControls == rhs.numberOfControls &&
      lhs.baseControl == rhs.baseControl
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(objectName)
    hasher.combine(localizedDescription)
    _hashMacAddress(macAddress, into: &hasher)
    hasher.combine(interfaceFlags)
    hasher.combine(clockIdentity)
    hasher.combine(priority1)
    hasher.combine(clockClass)
    hasher.combine(offsetScaledLogVariance)
    hasher.combine(clockAccuracy)
    hasher.combine(priority2)
    hasher.combine(domainNumber)
    hasher.combine(logSyncInterval)
    hasher.combine(logAnnounceInterval)
    hasher.combine(logPDelayInterval)
    hasher.combine(portNumber)
    hasher.combine(numberOfControls)
    hasher.combine(baseControl)
  }
}

/// CLOCK_SOURCE descriptor (IEEE 1722.1-2021 §7.2.9).
public struct ClockSourceDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 82

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var clockSourceFlags: ClockSourceFlags
  public var clockSourceTypeRaw: UInt16
  public var clockSourceIdentifier: UniqueIdentifier
  public var clockSourceLocationType: DescriptorType
  public var clockSourceLocationIndex: UInt16

  public var clockSourceType: ClockSourceType {
    ClockSourceType(rawValue: clockSourceTypeRaw) ?? .expansion
  }

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    clockSourceFlags = try ClockSourceFlags(rawValue: UInt16(parsingBigEndian: &input))
    clockSourceTypeRaw = try UInt16(parsingBigEndian: &input)
    clockSourceIdentifier = try UniqueIdentifier(parsing: &input)
    clockSourceLocationType = try DescriptorType(parsing: &input)
    clockSourceLocationIndex = try UInt16(parsingBigEndian: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint16: clockSourceFlags.rawValue)
    context.serialize(uint16: clockSourceTypeRaw)
    try context.serialize(clockSourceIdentifier)
    try context.serialize(clockSourceLocationType)
    context.serialize(uint16: clockSourceLocationIndex)
  }

  public var description: String {
    "ClockSourceDescriptor(name: \"\(objectName)\"" +
      ", identifier: \(clockSourceIdentifier)" +
      ", locationIndex: \(clockSourceLocationIndex))"
  }
}

/// MEMORY_OBJECT descriptor (IEEE 1722.1-2021 §7.2.10).
public struct MemoryObjectDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 96

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var memoryObjectType: MemoryObjectType
  public var targetDescriptorType: DescriptorType
  public var targetDescriptorIndex: UInt16
  public var startAddress: UInt64
  public var maximumLength: UInt64
  public var length: UInt64
  /// The largest segment an operation on the object may use (IEEE 1722.1-2021 Table 7-18); nil
  /// in an IEEE 1722.1-2013 descriptor, which ends at `length` and is written back as it was read.
  public var maximumSegmentLength: UInt64?

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    memoryObjectType = try MemoryObjectType(rawValue: UInt16(parsingBigEndian: &input))
    targetDescriptorType = try DescriptorType(parsing: &input)
    targetDescriptorIndex = try UInt16(parsingBigEndian: &input)
    startAddress = try UInt64(parsingBigEndian: &input)
    maximumLength = try UInt64(parsingBigEndian: &input)
    length = try UInt64(parsingBigEndian: &input)
    maximumSegmentLength = input.count >= 8 ? try UInt64(parsingBigEndian: &input) : nil
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint16: memoryObjectType.rawValue)
    try context.serialize(targetDescriptorType)
    context.serialize(uint16: targetDescriptorIndex)
    context.serialize(uint64: startAddress)
    context.serialize(uint64: maximumLength)
    context.serialize(uint64: length)
    if let maximumSegmentLength {
      context.serialize(uint64: maximumSegmentLength)
    }
  }

  public var description: String {
    "MemoryObjectDescriptor(name: \"\(objectName)\"" +
      ", startAddress: 0x\(String(startAddress, radix: 16))" +
      ", maxLength: \(maximumLength))"
  }
}

/// LOCALE descriptor (IEEE 1722.1-2021 §7.2.11).
public struct LocaleDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 68

  public var localeID: String
  public var numberOfStringDescriptors: UInt16
  public var baseStringDescriptorIndex: UInt16

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    localeID = try String(parsingAvdeccFixedString: &input)
    numberOfStringDescriptors = try UInt16(parsingBigEndian: &input)
    baseStringDescriptorIndex = try UInt16(parsingBigEndian: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: localeID)
    context.serialize(uint16: numberOfStringDescriptors)
    context.serialize(uint16: baseStringDescriptorIndex)
  }

  public var description: String {
    "LocaleDescriptor(localeID: \"\(localeID)\"" +
      ", strings: \(numberOfStringDescriptors)" +
      ", baseStringIndex: \(baseStringDescriptorIndex))"
  }
}

/// STRINGS descriptor (IEEE 1722.1-2021 §7.2.12): seven fixed strings.
public struct StringsDescriptor: Sendable, Hashable, CustomStringConvertible {
  public static let stringCount = 7
  static let bodyLength = stringCount * AvdeccFixedStringLength

  public var strings: [String]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    strings = try (0..<Self.stringCount).map { _ in
      try String(parsingAvdeccFixedString: &input)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    for index in 0..<Self.stringCount {
      context.serialize(avdeccFixedString: index < strings.count ? strings[index] : "")
    }
  }

  public var description: String { "StringsDescriptor(\(strings))" }
}

/// STREAM_PORT_INPUT / STREAM_PORT_OUTPUT descriptor (IEEE 1722.1-2021 §7.2.13).
public struct StreamPortDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 16

  public var clockDomainIndex: UInt16
  public var portFlags: PortFlags
  public var numberOfControls: UInt16
  public var baseControl: UInt16
  public var numberOfClusters: UInt16
  public var baseCluster: UInt16
  public var numberOfMaps: UInt16
  public var baseMap: UInt16

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    clockDomainIndex = try UInt16(parsingBigEndian: &input)
    portFlags = try PortFlags(rawValue: UInt16(parsingBigEndian: &input))
    numberOfControls = try UInt16(parsingBigEndian: &input)
    baseControl = try UInt16(parsingBigEndian: &input)
    numberOfClusters = try UInt16(parsingBigEndian: &input)
    baseCluster = try UInt16(parsingBigEndian: &input)
    numberOfMaps = try UInt16(parsingBigEndian: &input)
    baseMap = try UInt16(parsingBigEndian: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(uint16: clockDomainIndex)
    context.serialize(uint16: portFlags.rawValue)
    context.serialize(uint16: numberOfControls)
    context.serialize(uint16: baseControl)
    context.serialize(uint16: numberOfClusters)
    context.serialize(uint16: baseCluster)
    context.serialize(uint16: numberOfMaps)
    context.serialize(uint16: baseMap)
  }

  public var description: String {
    "StreamPortDescriptor(clockDomain: \(clockDomainIndex)" +
      ", clusters: \(numberOfClusters)@\(baseCluster)" +
      ", maps: \(numberOfMaps)@\(baseMap)" +
      ", controls: \(numberOfControls)@\(baseControl))"
  }
}

/// EXTERNAL_PORT_INPUT / EXTERNAL_PORT_OUTPUT descriptor (IEEE 1722.1-2021 §7.2.14).
public struct ExternalPortDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 20

  public var clockDomainIndex: UInt16
  public var portFlags: PortFlags
  public var numberOfControls: UInt16
  public var baseControl: UInt16
  public var signalType: DescriptorType
  public var signalIndex: UInt16
  public var signalOutput: UInt16
  public var blockLatency: UInt32
  public var jackIndex: UInt16

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    clockDomainIndex = try UInt16(parsingBigEndian: &input)
    portFlags = try PortFlags(rawValue: UInt16(parsingBigEndian: &input))
    numberOfControls = try UInt16(parsingBigEndian: &input)
    baseControl = try UInt16(parsingBigEndian: &input)
    signalType = try DescriptorType(parsing: &input)
    signalIndex = try UInt16(parsingBigEndian: &input)
    signalOutput = try UInt16(parsingBigEndian: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    jackIndex = try UInt16(parsingBigEndian: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(uint16: clockDomainIndex)
    context.serialize(uint16: portFlags.rawValue)
    context.serialize(uint16: numberOfControls)
    context.serialize(uint16: baseControl)
    try context.serialize(signalType)
    context.serialize(uint16: signalIndex)
    context.serialize(uint16: signalOutput)
    context.serialize(uint32: blockLatency)
    context.serialize(uint16: jackIndex)
  }

  public var description: String {
    "ExternalPortDescriptor(clockDomain: \(clockDomainIndex)" +
      ", jack: \(jackIndex), signalIndex: \(signalIndex)" +
      ", blockLatency: \(blockLatency))"
  }
}

/// INTERNAL_PORT_INPUT / INTERNAL_PORT_OUTPUT descriptor (IEEE 1722.1-2021 §7.2.15).
public struct InternalPortDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 20

  public var clockDomainIndex: UInt16
  public var portFlags: PortFlags
  public var numberOfControls: UInt16
  public var baseControl: UInt16
  public var signalType: DescriptorType
  public var signalIndex: UInt16
  public var signalOutput: UInt16
  public var blockLatency: UInt32
  public var internalIndex: UInt16

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    clockDomainIndex = try UInt16(parsingBigEndian: &input)
    portFlags = try PortFlags(rawValue: UInt16(parsingBigEndian: &input))
    numberOfControls = try UInt16(parsingBigEndian: &input)
    baseControl = try UInt16(parsingBigEndian: &input)
    signalType = try DescriptorType(parsing: &input)
    signalIndex = try UInt16(parsingBigEndian: &input)
    signalOutput = try UInt16(parsingBigEndian: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    internalIndex = try UInt16(parsingBigEndian: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(uint16: clockDomainIndex)
    context.serialize(uint16: portFlags.rawValue)
    context.serialize(uint16: numberOfControls)
    context.serialize(uint16: baseControl)
    try context.serialize(signalType)
    context.serialize(uint16: signalIndex)
    context.serialize(uint16: signalOutput)
    context.serialize(uint32: blockLatency)
    context.serialize(uint16: internalIndex)
  }

  public var description: String {
    "InternalPortDescriptor(clockDomain: \(clockDomainIndex)" +
      ", internalIndex: \(internalIndex), signalIndex: \(signalIndex)" +
      ", blockLatency: \(blockLatency))"
  }
}

/// AUDIO_CLUSTER descriptor (IEEE 1722.1-2021 §7.2.16).
public struct AudioClusterDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 83

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var signalType: DescriptorType
  public var signalIndex: UInt16
  public var signalOutput: UInt16
  public var pathLatency: UInt32
  public var blockLatency: UInt32
  public var channelCount: UInt16
  public var format: AudioClusterFormat
  /// The AES3 data type when `format` is IEC 60958 (IEEE 1722.1-2021 Table 7-27); nil in an
  /// IEEE 1722.1-2013 descriptor, which ends at `format` and is written back as it was read.
  public var aes3DataTypeReference: UInt8?
  public var aes3DataType: UInt16?

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    signalType = try DescriptorType(parsing: &input)
    signalIndex = try UInt16(parsingBigEndian: &input)
    signalOutput = try UInt16(parsingBigEndian: &input)
    pathLatency = try UInt32(parsingBigEndian: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    channelCount = try UInt16(parsingBigEndian: &input)
    format = try AudioClusterFormat(rawValue: UInt8(parsing: &input))
    if input.count >= 3 {
      aes3DataTypeReference = try UInt8(parsing: &input)
      aes3DataType = try UInt16(parsingBigEndian: &input)
    } else {
      aes3DataTypeReference = nil
      aes3DataType = nil
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    try context.serialize(signalType)
    context.serialize(uint16: signalIndex)
    context.serialize(uint16: signalOutput)
    context.serialize(uint32: pathLatency)
    context.serialize(uint32: blockLatency)
    context.serialize(uint16: channelCount)
    context.serialize(uint8: format.rawValue)
    guard aes3DataTypeReference != nil || aes3DataType != nil else { return }
    context.serialize(uint8: aes3DataTypeReference ?? 0)
    context.serialize(uint16: aes3DataType ?? 0)
  }

  public var description: String {
    "AudioClusterDescriptor(name: \"\(objectName)\"" +
      ", signalIndex: \(signalIndex), signalOutput: \(signalOutput)" +
      ", pathLatency: \(pathLatency), blockLatency: \(blockLatency))"
  }
}

/// AUDIO_MAP descriptor (IEEE 1722.1-2021 §7.2.19).
public struct AudioMapDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 4

  public var mappings: [AudioMapping]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    let mappingsOffset = try UInt16(parsingBigEndian: &input)
    let numberOfMappings = try UInt16(parsingBigEndian: &input)
    var mappingsSpan = try input.seeking(toAbsoluteOffset: input.descriptorOffset(mappingsOffset))
    try mappingsSpan.requireRemaining(numberOfMappings, of: AudioMapping.length)
    mappings = try (0..<numberOfMappings).map { _ in
      try AudioMapping(parsing: &mappingsSpan)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    try context.serialize(count: mappings.count)
    for mapping in mappings {
      try context.serialize(mapping)
    }
  }

  public var description: String { "AudioMapDescriptor(mappings: \(mappings.count))" }
}

/// CONTROL descriptor (IEEE 1722.1-2021 §7.2.22). The static and dynamic values are kept
/// packed as `valuesData`, since their layout depends on `controlValueType`.
public struct ControlDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 100

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var blockLatency: UInt32
  public var controlLatency: UInt32
  public var controlDomain: UInt16
  public var controlValueType: ControlValueType
  public var controlType: UniqueIdentifier
  public var resetTime: UInt32
  public var numberOfValues: UInt16
  public var signalType: DescriptorType
  public var signalIndex: UInt16
  public var signalOutput: UInt16
  /// The packed value_details (IEEE 1722.1-2021 §7.3.5).
  public var valuesData: [UInt8]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    controlLatency = try UInt32(parsingBigEndian: &input)
    controlDomain = try UInt16(parsingBigEndian: &input)
    controlValueType = try ControlValueType(rawValue: UInt16(parsingBigEndian: &input))
    controlType = try UniqueIdentifier(parsing: &input)
    resetTime = try UInt32(parsingBigEndian: &input)
    let valuesOffset = try UInt16(parsingBigEndian: &input)
    numberOfValues = try UInt16(parsingBigEndian: &input)
    signalType = try DescriptorType(parsing: &input)
    signalIndex = try UInt16(parsingBigEndian: &input)
    signalOutput = try UInt16(parsingBigEndian: &input)
    var values = try input.seeking(toAbsoluteOffset: input.descriptorOffset(valuesOffset))
    valuesData = [UInt8](parsingRemainingBytes: &values)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint32: blockLatency)
    context.serialize(uint32: controlLatency)
    context.serialize(uint16: controlDomain)
    context.serialize(uint16: controlValueType.rawValue)
    try context.serialize(controlType)
    context.serialize(uint32: resetTime)
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    context.serialize(uint16: numberOfValues)
    try context.serialize(signalType)
    context.serialize(uint16: signalIndex)
    context.serialize(uint16: signalOutput)
    context.serialize(valuesData)
  }

  public var description: String {
    "ControlDescriptor(name: \"\(objectName)\"" +
      ", controlType: \(controlType), values: \(numberOfValues)" +
      ", controlLatency: \(controlLatency))"
  }
}

/// CLOCK_DOMAIN descriptor (IEEE 1722.1-2021 §7.2.32).
public struct ClockDomainDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 72

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var clockSourceIndex: UInt16
  public var clockSources: [UInt16]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    clockSourceIndex = try UInt16(parsingBigEndian: &input)
    let clockSourcesOffset = try UInt16(parsingBigEndian: &input)
    let numberOfClockSources = try UInt16(parsingBigEndian: &input)
    var sources = try input.seeking(toAbsoluteOffset: input.descriptorOffset(clockSourcesOffset))
    try sources.requireRemaining(numberOfClockSources, of: MemoryLayout<UInt16>.size)
    clockSources = try (0..<numberOfClockSources).map { _ in
      try UInt16(parsingBigEndian: &sources)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint16: clockSourceIndex)
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    try context.serialize(count: clockSources.count)
    for source in clockSources {
      context.serialize(uint16: source)
    }
  }

  public var description: String {
    "ClockDomainDescriptor(name: \"\(objectName)\"" +
      ", currentClockSource: \(clockSourceIndex)" +
      ", clockSources: \(clockSources))"
  }
}

/// TIMING descriptor (IEEE 1722.1-2021 §7.2.34).
public struct TimingDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 72

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var algorithm: TimingAlgorithm
  public var ptpInstances: [UInt16]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    algorithm = try TimingAlgorithm(rawValue: UInt16(parsingBigEndian: &input))
    let ptpInstancesOffset = try UInt16(parsingBigEndian: &input)
    let numberOfPtpInstances = try UInt16(parsingBigEndian: &input)
    var instances = try input.seeking(toAbsoluteOffset: input.descriptorOffset(ptpInstancesOffset))
    try instances.requireRemaining(numberOfPtpInstances, of: MemoryLayout<UInt16>.size)
    ptpInstances = try (0..<numberOfPtpInstances).map { _ in
      try UInt16(parsingBigEndian: &instances)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint16: algorithm.rawValue)
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    try context.serialize(count: ptpInstances.count)
    for instance in ptpInstances {
      context.serialize(uint16: instance)
    }
  }

  public var description: String {
    "TimingDescriptor(name: \"\(objectName)\", ptpInstances: \(ptpInstances))"
  }
}

/// PTP_INSTANCE descriptor (IEEE 1722.1-2021 §7.2.35).
public struct PtpInstanceDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 86

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var clockIdentity: UniqueIdentifier
  public var flags: PtpInstanceFlags
  public var numberOfControls: UInt16
  public var baseControl: UInt16
  public var numberOfPtpPorts: UInt16
  public var basePtpPort: UInt16

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    clockIdentity = try UniqueIdentifier(parsing: &input)
    flags = try PtpInstanceFlags(rawValue: UInt32(parsingBigEndian: &input))
    numberOfControls = try UInt16(parsingBigEndian: &input)
    baseControl = try UInt16(parsingBigEndian: &input)
    numberOfPtpPorts = try UInt16(parsingBigEndian: &input)
    basePtpPort = try UInt16(parsingBigEndian: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    try context.serialize(clockIdentity)
    context.serialize(uint32: flags.rawValue)
    context.serialize(uint16: numberOfControls)
    context.serialize(uint16: baseControl)
    context.serialize(uint16: numberOfPtpPorts)
    context.serialize(uint16: basePtpPort)
  }

  public var description: String {
    "PtpInstanceDescriptor(name: \"\(objectName)\"" +
      ", clockIdentity: \(clockIdentity)" +
      ", ptpPorts: \(numberOfPtpPorts)@\(basePtpPort))"
  }
}

/// PTP_PORT descriptor (IEEE 1722.1-2021 §7.2.36).
public struct PtpPortDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 82

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var portNumber: UInt16
  public var portType: PtpPortType
  public var flags: PtpPortFlags
  public var avbInterfaceIndex: UInt16
  /// The six-octet PTP profileIdentifier.
  public var profileIdentifier: EUI48

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    portNumber = try UInt16(parsingBigEndian: &input)
    portType = try PtpPortType(rawValue: UInt16(parsingBigEndian: &input))
    flags = try PtpPortFlags(rawValue: UInt32(parsingBigEndian: &input))
    avbInterfaceIndex = try UInt16(parsingBigEndian: &input)
    profileIdentifier = try _eui48(parsing: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint16: portNumber)
    context.serialize(uint16: portType.rawValue)
    context.serialize(uint32: flags.rawValue)
    context.serialize(uint16: avbInterfaceIndex)
    context.serialize(eui48: profileIdentifier)
  }

  public var description: String {
    "PtpPortDescriptor(name: \"\(objectName)\"" +
      ", portNumber: \(portNumber), avbInterface: \(avbInterfaceIndex))"
  }

  // written out, as EUI48 (an InlineArray) is not Hashable
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.objectName == rhs.objectName &&
      lhs.localizedDescription == rhs.localizedDescription &&
      lhs.portNumber == rhs.portNumber &&
      lhs.portType == rhs.portType &&
      lhs.flags == rhs.flags &&
      lhs.avbInterfaceIndex == rhs.avbInterfaceIndex &&
      _isEqualMacAddress(lhs.profileIdentifier, rhs.profileIdentifier)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(objectName)
    hasher.combine(localizedDescription)
    hasher.combine(portNumber)
    hasher.combine(portType)
    hasher.combine(flags)
    hasher.combine(avbInterfaceIndex)
    _hashMacAddress(profileIdentifier, into: &hasher)
  }
}

// MARK: - Video, sensor and signal processing descriptors

/// The output of a descriptor that a signal comes from or goes to (IEEE 1722.1-2021 Table 7-41).
public struct SignalSource: Sendable, Hashable {
  static let length = 6

  public var signalType: DescriptorType
  public var signalIndex: DescriptorIndex
  public var signalOutput: UInt16

  public init(signalType: DescriptorType, signalIndex: DescriptorIndex, signalOutput: UInt16) {
    self.signalType = signalType
    self.signalIndex = signalIndex
    self.signalOutput = signalOutput
  }

  init(parsing input: inout ParserSpan) throws {
    signalType = try DescriptorType(parsing: &input)
    signalIndex = try UInt16(parsingBigEndian: &input)
    signalOutput = try UInt16(parsingBigEndian: &input)
  }

  func serialize(into context: inout SerializationContext) throws {
    try context.serialize(signalType)
    context.serialize(uint16: signalIndex)
    context.serialize(uint16: signalOutput)
  }
}

/// A run of sub-signals and the output (of a splitter or demultiplexer) or input (of a combiner or
/// multiplexer) it maps to (IEEE 1722.1-2021 Tables 7-50, 7-52, 7-55 and 7-57).
public struct SubSignalMapping: Sendable, Hashable {
  static let length = 6

  public var subSignalStart: UInt16
  public var subSignalCount: UInt16
  public var index: UInt16

  public init(subSignalStart: UInt16, subSignalCount: UInt16, index: UInt16) {
    self.subSignalStart = subSignalStart
    self.subSignalCount = subSignalCount
    self.index = index
  }

  init(parsing input: inout ParserSpan) throws {
    subSignalStart = try UInt16(parsingBigEndian: &input)
    subSignalCount = try UInt16(parsingBigEndian: &input)
    index = try UInt16(parsingBigEndian: &input)
  }

  func serialize(into context: inout SerializationContext) {
    context.serialize(uint16: subSignalStart)
    context.serialize(uint16: subSignalCount)
    context.serialize(uint16: index)
  }
}

/// VIDEO_UNIT descriptor (IEEE 1722.1-2021 Table 7-6).
public struct VideoUnitDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 132

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var clockDomainIndex: UInt16
  public var numberOfStreamInputPorts: UInt16
  public var baseStreamInputPort: UInt16
  public var numberOfStreamOutputPorts: UInt16
  public var baseStreamOutputPort: UInt16
  public var numberOfExternalInputPorts: UInt16
  public var baseExternalInputPort: UInt16
  public var numberOfExternalOutputPorts: UInt16
  public var baseExternalOutputPort: UInt16
  public var numberOfInternalInputPorts: UInt16
  public var baseInternalInputPort: UInt16
  public var numberOfInternalOutputPorts: UInt16
  public var baseInternalOutputPort: UInt16
  public var numberOfControls: UInt16
  public var baseControl: UInt16
  public var numberOfSignalSelectors: UInt16
  public var baseSignalSelector: UInt16
  public var numberOfMixers: UInt16
  public var baseMixer: UInt16
  public var numberOfMatrices: UInt16
  public var baseMatrix: UInt16
  public var numberOfSplitters: UInt16
  public var baseSplitter: UInt16
  public var numberOfCombiners: UInt16
  public var baseCombiner: UInt16
  public var numberOfDemultiplexers: UInt16
  public var baseDemultiplexer: UInt16
  public var numberOfMultiplexers: UInt16
  public var baseMultiplexer: UInt16
  public var numberOfTranscoders: UInt16
  public var baseTranscoder: UInt16
  public var numberOfControlBlocks: UInt16
  public var baseControlBlock: UInt16

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    clockDomainIndex = try UInt16(parsingBigEndian: &input)
    numberOfStreamInputPorts = try UInt16(parsingBigEndian: &input)
    baseStreamInputPort = try UInt16(parsingBigEndian: &input)
    numberOfStreamOutputPorts = try UInt16(parsingBigEndian: &input)
    baseStreamOutputPort = try UInt16(parsingBigEndian: &input)
    numberOfExternalInputPorts = try UInt16(parsingBigEndian: &input)
    baseExternalInputPort = try UInt16(parsingBigEndian: &input)
    numberOfExternalOutputPorts = try UInt16(parsingBigEndian: &input)
    baseExternalOutputPort = try UInt16(parsingBigEndian: &input)
    numberOfInternalInputPorts = try UInt16(parsingBigEndian: &input)
    baseInternalInputPort = try UInt16(parsingBigEndian: &input)
    numberOfInternalOutputPorts = try UInt16(parsingBigEndian: &input)
    baseInternalOutputPort = try UInt16(parsingBigEndian: &input)
    numberOfControls = try UInt16(parsingBigEndian: &input)
    baseControl = try UInt16(parsingBigEndian: &input)
    numberOfSignalSelectors = try UInt16(parsingBigEndian: &input)
    baseSignalSelector = try UInt16(parsingBigEndian: &input)
    numberOfMixers = try UInt16(parsingBigEndian: &input)
    baseMixer = try UInt16(parsingBigEndian: &input)
    numberOfMatrices = try UInt16(parsingBigEndian: &input)
    baseMatrix = try UInt16(parsingBigEndian: &input)
    numberOfSplitters = try UInt16(parsingBigEndian: &input)
    baseSplitter = try UInt16(parsingBigEndian: &input)
    numberOfCombiners = try UInt16(parsingBigEndian: &input)
    baseCombiner = try UInt16(parsingBigEndian: &input)
    numberOfDemultiplexers = try UInt16(parsingBigEndian: &input)
    baseDemultiplexer = try UInt16(parsingBigEndian: &input)
    numberOfMultiplexers = try UInt16(parsingBigEndian: &input)
    baseMultiplexer = try UInt16(parsingBigEndian: &input)
    numberOfTranscoders = try UInt16(parsingBigEndian: &input)
    baseTranscoder = try UInt16(parsingBigEndian: &input)
    numberOfControlBlocks = try UInt16(parsingBigEndian: &input)
    baseControlBlock = try UInt16(parsingBigEndian: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    for value in [
      clockDomainIndex,
      numberOfStreamInputPorts, baseStreamInputPort,
      numberOfStreamOutputPorts, baseStreamOutputPort,
      numberOfExternalInputPorts, baseExternalInputPort,
      numberOfExternalOutputPorts, baseExternalOutputPort,
      numberOfInternalInputPorts, baseInternalInputPort,
      numberOfInternalOutputPorts, baseInternalOutputPort,
      numberOfControls, baseControl,
      numberOfSignalSelectors, baseSignalSelector,
      numberOfMixers, baseMixer,
      numberOfMatrices, baseMatrix,
      numberOfSplitters, baseSplitter,
      numberOfCombiners, baseCombiner,
      numberOfDemultiplexers, baseDemultiplexer,
      numberOfMultiplexers, baseMultiplexer,
      numberOfTranscoders, baseTranscoder,
      numberOfControlBlocks, baseControlBlock,
    ] {
      context.serialize(uint16: value)
    }
  }

  public var description: String {
    "VideoUnitDescriptor(name: \"\(objectName)\", clockDomain: \(clockDomainIndex))"
  }
}

/// SENSOR_UNIT descriptor (IEEE 1722.1-2021 Table 7-7).
public struct SensorUnitDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 132

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var clockDomainIndex: UInt16
  public var numberOfStreamInputPorts: UInt16
  public var baseStreamInputPort: UInt16
  public var numberOfStreamOutputPorts: UInt16
  public var baseStreamOutputPort: UInt16
  public var numberOfExternalInputPorts: UInt16
  public var baseExternalInputPort: UInt16
  public var numberOfExternalOutputPorts: UInt16
  public var baseExternalOutputPort: UInt16
  public var numberOfInternalInputPorts: UInt16
  public var baseInternalInputPort: UInt16
  public var numberOfInternalOutputPorts: UInt16
  public var baseInternalOutputPort: UInt16
  public var numberOfControls: UInt16
  public var baseControl: UInt16
  public var numberOfSignalSelectors: UInt16
  public var baseSignalSelector: UInt16
  public var numberOfMixers: UInt16
  public var baseMixer: UInt16
  public var numberOfMatrices: UInt16
  public var baseMatrix: UInt16
  public var numberOfSplitters: UInt16
  public var baseSplitter: UInt16
  public var numberOfCombiners: UInt16
  public var baseCombiner: UInt16
  public var numberOfDemultiplexers: UInt16
  public var baseDemultiplexer: UInt16
  public var numberOfMultiplexers: UInt16
  public var baseMultiplexer: UInt16
  public var numberOfTranscoders: UInt16
  public var baseTranscoder: UInt16
  public var numberOfControlBlocks: UInt16
  public var baseControlBlock: UInt16

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    clockDomainIndex = try UInt16(parsingBigEndian: &input)
    numberOfStreamInputPorts = try UInt16(parsingBigEndian: &input)
    baseStreamInputPort = try UInt16(parsingBigEndian: &input)
    numberOfStreamOutputPorts = try UInt16(parsingBigEndian: &input)
    baseStreamOutputPort = try UInt16(parsingBigEndian: &input)
    numberOfExternalInputPorts = try UInt16(parsingBigEndian: &input)
    baseExternalInputPort = try UInt16(parsingBigEndian: &input)
    numberOfExternalOutputPorts = try UInt16(parsingBigEndian: &input)
    baseExternalOutputPort = try UInt16(parsingBigEndian: &input)
    numberOfInternalInputPorts = try UInt16(parsingBigEndian: &input)
    baseInternalInputPort = try UInt16(parsingBigEndian: &input)
    numberOfInternalOutputPorts = try UInt16(parsingBigEndian: &input)
    baseInternalOutputPort = try UInt16(parsingBigEndian: &input)
    numberOfControls = try UInt16(parsingBigEndian: &input)
    baseControl = try UInt16(parsingBigEndian: &input)
    numberOfSignalSelectors = try UInt16(parsingBigEndian: &input)
    baseSignalSelector = try UInt16(parsingBigEndian: &input)
    numberOfMixers = try UInt16(parsingBigEndian: &input)
    baseMixer = try UInt16(parsingBigEndian: &input)
    numberOfMatrices = try UInt16(parsingBigEndian: &input)
    baseMatrix = try UInt16(parsingBigEndian: &input)
    numberOfSplitters = try UInt16(parsingBigEndian: &input)
    baseSplitter = try UInt16(parsingBigEndian: &input)
    numberOfCombiners = try UInt16(parsingBigEndian: &input)
    baseCombiner = try UInt16(parsingBigEndian: &input)
    numberOfDemultiplexers = try UInt16(parsingBigEndian: &input)
    baseDemultiplexer = try UInt16(parsingBigEndian: &input)
    numberOfMultiplexers = try UInt16(parsingBigEndian: &input)
    baseMultiplexer = try UInt16(parsingBigEndian: &input)
    numberOfTranscoders = try UInt16(parsingBigEndian: &input)
    baseTranscoder = try UInt16(parsingBigEndian: &input)
    numberOfControlBlocks = try UInt16(parsingBigEndian: &input)
    baseControlBlock = try UInt16(parsingBigEndian: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    for value in [
      clockDomainIndex,
      numberOfStreamInputPorts, baseStreamInputPort,
      numberOfStreamOutputPorts, baseStreamOutputPort,
      numberOfExternalInputPorts, baseExternalInputPort,
      numberOfExternalOutputPorts, baseExternalOutputPort,
      numberOfInternalInputPorts, baseInternalInputPort,
      numberOfInternalOutputPorts, baseInternalOutputPort,
      numberOfControls, baseControl,
      numberOfSignalSelectors, baseSignalSelector,
      numberOfMixers, baseMixer,
      numberOfMatrices, baseMatrix,
      numberOfSplitters, baseSplitter,
      numberOfCombiners, baseCombiner,
      numberOfDemultiplexers, baseDemultiplexer,
      numberOfMultiplexers, baseMultiplexer,
      numberOfTranscoders, baseTranscoder,
      numberOfControlBlocks, baseControlBlock,
    ] {
      context.serialize(uint16: value)
    }
  }

  public var description: String {
    "SensorUnitDescriptor(name: \"\(objectName)\", clockDomain: \(clockDomainIndex))"
  }
}

/// VIDEO_CLUSTER descriptor (IEEE 1722.1-2021 Table 7-29). The sampling rate range fields are
/// absent from an IEEE 1722.1-2013 descriptor.
public struct VideoClusterDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 117
  // current_sampling_rate_range, and the offset and count of supported_sampling_rate_ranges
  static let samplingRateRangeFieldsLength = 12

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var signalType: DescriptorType
  public var signalIndex: UInt16
  public var signalOutput: UInt16
  public var pathLatency: UInt32
  public var blockLatency: UInt32
  /// IEEE 1722.1-2021 Table 7-30.
  public var format: UInt8
  public var currentFormatSpecific: UInt32
  public var supportedFormatSpecifics: [UInt32]
  public var currentSamplingRate: SamplingRate
  public var supportedSamplingRates: [SamplingRate]
  public var currentAspectRatio: UInt16
  public var supportedAspectRatios: [UInt16]
  public var currentSize: UInt32
  public var supportedSizes: [UInt32]
  public var currentColorSpace: UInt16
  public var supportedColorSpaces: [UInt16]
  /// nil in an IEEE 1722.1-2013 descriptor.
  public var currentSamplingRateRange: UInt64?
  public var supportedSamplingRateRanges: [UInt64]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    signalType = try DescriptorType(parsing: &input)
    signalIndex = try UInt16(parsingBigEndian: &input)
    signalOutput = try UInt16(parsingBigEndian: &input)
    pathLatency = try UInt32(parsingBigEndian: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    format = try UInt8(parsing: &input)
    currentFormatSpecific = try UInt32(parsingBigEndian: &input)
    let formatSpecificsOffset = try UInt16(parsingBigEndian: &input)
    let formatSpecificsCount = try UInt16(parsingBigEndian: &input)
    currentSamplingRate = try SamplingRate(parsing: &input)
    let samplingRatesOffset = try UInt16(parsingBigEndian: &input)
    let samplingRatesCount = try UInt16(parsingBigEndian: &input)
    currentAspectRatio = try UInt16(parsingBigEndian: &input)
    let aspectRatiosOffset = try UInt16(parsingBigEndian: &input)
    let aspectRatiosCount = try UInt16(parsingBigEndian: &input)
    currentSize = try UInt32(parsingBigEndian: &input)
    let sizesOffset = try UInt16(parsingBigEndian: &input)
    let sizesCount = try UInt16(parsingBigEndian: &input)
    currentColorSpace = try UInt16(parsingBigEndian: &input)
    let colorSpacesOffset = try UInt16(parsingBigEndian: &input)
    let colorSpacesCount = try UInt16(parsingBigEndian: &input)
    // the range fields are present when the arrays do not immediately follow color spaces
    var rangesOffset = UInt16(0)
    var rangesCount = UInt16(0)
    if Int(formatSpecificsOffset) - input.startPosition >= Self.samplingRateRangeFieldsLength {
      currentSamplingRateRange = try UInt64(parsingBigEndian: &input)
      rangesOffset = try UInt16(parsingBigEndian: &input)
      rangesCount = try UInt16(parsingBigEndian: &input)
    } else {
      currentSamplingRateRange = nil
    }
    supportedFormatSpecifics = try input.descriptorArray(at: formatSpecificsOffset, count: formatSpecificsCount, length: 4) {
      try UInt32(parsingBigEndian: &$0)
    }
    supportedSamplingRates = try input.descriptorArray(at: samplingRatesOffset, count: samplingRatesCount, length: 4) {
      try SamplingRate(parsing: &$0)
    }
    supportedAspectRatios = try input.descriptorArray(at: aspectRatiosOffset, count: aspectRatiosCount, length: 2) {
      try UInt16(parsingBigEndian: &$0)
    }
    supportedSizes = try input.descriptorArray(at: sizesOffset, count: sizesCount, length: 4) {
      try UInt32(parsingBigEndian: &$0)
    }
    supportedColorSpaces = try input.descriptorArray(at: colorSpacesOffset, count: colorSpacesCount, length: 2) {
      try UInt16(parsingBigEndian: &$0)
    }
    supportedSamplingRateRanges = rangesCount == 0 ? [] :
      try input.descriptorArray(at: rangesOffset, count: rangesCount, length: 8) {
        try UInt64(parsingBigEndian: &$0)
      }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    var offset = _descriptorHeaderLength + Self.bodyLength +
      (currentSamplingRateRange == nil ? 0 : Self.samplingRateRangeFieldsLength)
    // each array follows the previous one
    func arrayOffset(_ count: Int, _ length: Int) throws -> UInt16 {
      defer { offset += count * length }
      guard let offset = UInt16(exactly: offset) else { throw AvdeccCodecError.valueTooLarge }
      return offset
    }
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    try context.serialize(signalType)
    context.serialize(uint16: signalIndex)
    context.serialize(uint16: signalOutput)
    context.serialize(uint32: pathLatency)
    context.serialize(uint32: blockLatency)
    context.serialize(uint8: format)
    context.serialize(uint32: currentFormatSpecific)
    try context.serialize(uint16: arrayOffset(supportedFormatSpecifics.count, 4))
    try context.serialize(count: supportedFormatSpecifics.count)
    try context.serialize(currentSamplingRate)
    try context.serialize(uint16: arrayOffset(supportedSamplingRates.count, 4))
    try context.serialize(count: supportedSamplingRates.count)
    context.serialize(uint16: currentAspectRatio)
    try context.serialize(uint16: arrayOffset(supportedAspectRatios.count, 2))
    try context.serialize(count: supportedAspectRatios.count)
    context.serialize(uint32: currentSize)
    try context.serialize(uint16: arrayOffset(supportedSizes.count, 4))
    try context.serialize(count: supportedSizes.count)
    context.serialize(uint16: currentColorSpace)
    try context.serialize(uint16: arrayOffset(supportedColorSpaces.count, 2))
    try context.serialize(count: supportedColorSpaces.count)
    if let currentSamplingRateRange {
      context.serialize(uint64: currentSamplingRateRange)
      try context.serialize(uint16: arrayOffset(supportedSamplingRateRanges.count, 8))
      try context.serialize(count: supportedSamplingRateRanges.count)
    }
    for value in supportedFormatSpecifics {
      context.serialize(uint32: value)
    }
    for rate in supportedSamplingRates {
      try context.serialize(rate)
    }
    for value in supportedAspectRatios {
      context.serialize(uint16: value)
    }
    for value in supportedSizes {
      context.serialize(uint32: value)
    }
    for value in supportedColorSpaces {
      context.serialize(uint16: value)
    }
    if currentSamplingRateRange != nil {
      for value in supportedSamplingRateRanges {
        context.serialize(uint64: value)
      }
    }
  }

  public var description: String {
    "VideoClusterDescriptor(name: \"\(objectName)\", format: \(format), size: 0x\(String(currentSize, radix: 16)))"
  }
}

/// SENSOR_CLUSTER descriptor (IEEE 1722.1-2021 Table 7-31).
public struct SensorClusterDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 100

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var signalType: DescriptorType
  public var signalIndex: UInt16
  public var signalOutput: UInt16
  public var pathLatency: UInt32
  public var blockLatency: UInt32
  public var currentFormat: UInt64
  public var supportedFormats: [UInt64]
  public var currentSamplingRate: SamplingRate
  public var supportedSamplingRates: [SamplingRate]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    signalType = try DescriptorType(parsing: &input)
    signalIndex = try UInt16(parsingBigEndian: &input)
    signalOutput = try UInt16(parsingBigEndian: &input)
    pathLatency = try UInt32(parsingBigEndian: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    currentFormat = try UInt64(parsingBigEndian: &input)
    let formatsOffset = try UInt16(parsingBigEndian: &input)
    let formatsCount = try UInt16(parsingBigEndian: &input)
    currentSamplingRate = try SamplingRate(parsing: &input)
    let samplingRatesOffset = try UInt16(parsingBigEndian: &input)
    let samplingRatesCount = try UInt16(parsingBigEndian: &input)
    supportedFormats = try input.descriptorArray(at: formatsOffset, count: formatsCount, length: 8) {
      try UInt64(parsingBigEndian: &$0)
    }
    supportedSamplingRates = try input.descriptorArray(at: samplingRatesOffset, count: samplingRatesCount, length: 4) {
      try SamplingRate(parsing: &$0)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    let formatsOffset = _descriptorHeaderLength + Self.bodyLength
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    try context.serialize(signalType)
    context.serialize(uint16: signalIndex)
    context.serialize(uint16: signalOutput)
    context.serialize(uint32: pathLatency)
    context.serialize(uint32: blockLatency)
    context.serialize(uint64: currentFormat)
    context.serialize(uint16: UInt16(formatsOffset))
    try context.serialize(count: supportedFormats.count)
    try context.serialize(currentSamplingRate)
    try context.serialize(count: formatsOffset + supportedFormats.count * 8)
    try context.serialize(count: supportedSamplingRates.count)
    for format in supportedFormats {
      context.serialize(uint64: format)
    }
    for rate in supportedSamplingRates {
      try context.serialize(rate)
    }
  }

  public var description: String {
    "SensorClusterDescriptor(name: \"\(objectName)\", formats: \(supportedFormats.count))"
  }
}

/// A VIDEO_MAP mapping (IEEE 1722.1-2021 Table 7-35).
public struct VideoMapping: Sendable, Hashable {
  static let length = 8

  public var streamIndex: UInt16
  public var programStream: UInt16
  public var elementaryStream: UInt16
  public var clusterOffset: UInt16

  public init(streamIndex: UInt16, programStream: UInt16, elementaryStream: UInt16, clusterOffset: UInt16) {
    self.streamIndex = streamIndex
    self.programStream = programStream
    self.elementaryStream = elementaryStream
    self.clusterOffset = clusterOffset
  }

  init(parsing input: inout ParserSpan) throws {
    streamIndex = try UInt16(parsingBigEndian: &input)
    programStream = try UInt16(parsingBigEndian: &input)
    elementaryStream = try UInt16(parsingBigEndian: &input)
    clusterOffset = try UInt16(parsingBigEndian: &input)
  }

  func serialize(into context: inout SerializationContext) {
    context.serialize(uint16: streamIndex)
    context.serialize(uint16: programStream)
    context.serialize(uint16: elementaryStream)
    context.serialize(uint16: clusterOffset)
  }
}

/// VIDEO_MAP descriptor (IEEE 1722.1-2021 Table 7-34).
public struct VideoMapDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 4

  public var mappings: [VideoMapping]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    let mappingsOffset = try UInt16(parsingBigEndian: &input)
    let numberOfMappings = try UInt16(parsingBigEndian: &input)
    mappings = try input.descriptorArray(at: mappingsOffset, count: numberOfMappings, length: VideoMapping.length) {
      try VideoMapping(parsing: &$0)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    try context.serialize(count: mappings.count)
    for mapping in mappings {
      mapping.serialize(into: &context)
    }
  }

  public var description: String { "VideoMapDescriptor(mappings: \(mappings.count))" }
}

/// A SENSOR_MAP mapping (IEEE 1722.1-2021 Table 7-37).
public struct SensorMapping: Sendable, Hashable {
  static let length = 6

  public var streamIndex: UInt16
  public var streamSignal: UInt16
  public var clusterOffset: UInt16

  public init(streamIndex: UInt16, streamSignal: UInt16, clusterOffset: UInt16) {
    self.streamIndex = streamIndex
    self.streamSignal = streamSignal
    self.clusterOffset = clusterOffset
  }

  init(parsing input: inout ParserSpan) throws {
    streamIndex = try UInt16(parsingBigEndian: &input)
    streamSignal = try UInt16(parsingBigEndian: &input)
    clusterOffset = try UInt16(parsingBigEndian: &input)
  }

  func serialize(into context: inout SerializationContext) {
    context.serialize(uint16: streamIndex)
    context.serialize(uint16: streamSignal)
    context.serialize(uint16: clusterOffset)
  }
}

/// SENSOR_MAP descriptor (IEEE 1722.1-2021 Table 7-36).
public struct SensorMapDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 4

  public var mappings: [SensorMapping]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    let mappingsOffset = try UInt16(parsingBigEndian: &input)
    let numberOfMappings = try UInt16(parsingBigEndian: &input)
    mappings = try input.descriptorArray(at: mappingsOffset, count: numberOfMappings, length: SensorMapping.length) {
      try SensorMapping(parsing: &$0)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    try context.serialize(count: mappings.count)
    for mapping in mappings {
      mapping.serialize(into: &context)
    }
  }

  public var description: String { "SensorMapDescriptor(mappings: \(mappings.count))" }
}

/// SIGNAL_SELECTOR descriptor (IEEE 1722.1-2021 Table 7-40).
public struct SignalSelectorDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 92

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var blockLatency: UInt32
  public var controlLatency: UInt32
  public var controlDomain: UInt16
  public var sources: [SignalSource]
  public var currentSource: SignalSource
  public var defaultSource: SignalSource

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    controlLatency = try UInt32(parsingBigEndian: &input)
    controlDomain = try UInt16(parsingBigEndian: &input)
    let sourcesOffset = try UInt16(parsingBigEndian: &input)
    let numberOfSources = try UInt16(parsingBigEndian: &input)
    currentSource = try SignalSource(parsing: &input)
    defaultSource = try SignalSource(parsing: &input)
    sources = try input.descriptorArray(at: sourcesOffset, count: numberOfSources, length: SignalSource.length) {
      try SignalSource(parsing: &$0)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint32: blockLatency)
    context.serialize(uint32: controlLatency)
    context.serialize(uint16: controlDomain)
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    try context.serialize(count: sources.count)
    try currentSource.serialize(into: &context)
    try defaultSource.serialize(into: &context)
    for source in sources {
      try source.serialize(into: &context)
    }
  }

  public var description: String {
    "SignalSelectorDescriptor(name: \"\(objectName)\", sources: \(sources.count))"
  }
}

/// MIXER descriptor (IEEE 1722.1-2021 Table 7-42). The value is kept packed as `valuesData`, from
/// value_offset to the end of the descriptor, since its layout depends on `controlValueType`.
public struct MixerDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 84

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var blockLatency: UInt32
  public var controlLatency: UInt32
  public var controlDomain: UInt16
  public var controlValueType: ControlValueType
  public var sources: [SignalSource]
  public var valuesData: [UInt8]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    controlLatency = try UInt32(parsingBigEndian: &input)
    controlDomain = try UInt16(parsingBigEndian: &input)
    controlValueType = try ControlValueType(rawValue: UInt16(parsingBigEndian: &input))
    let sourcesOffset = try UInt16(parsingBigEndian: &input)
    let numberOfSources = try UInt16(parsingBigEndian: &input)
    let valueOffset = try UInt16(parsingBigEndian: &input)
    sources = try input.descriptorArray(at: sourcesOffset, count: numberOfSources, length: SignalSource.length) {
      try SignalSource(parsing: &$0)
    }
    valuesData = try input.descriptorBytes(from: valueOffset)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    let sourcesOffset = _descriptorHeaderLength + Self.bodyLength
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint32: blockLatency)
    context.serialize(uint32: controlLatency)
    context.serialize(uint16: controlDomain)
    context.serialize(uint16: controlValueType.rawValue)
    context.serialize(uint16: UInt16(sourcesOffset))
    try context.serialize(count: sources.count)
    try context.serialize(count: sourcesOffset + sources.count * SignalSource.length)
    for source in sources {
      try source.serialize(into: &context)
    }
    context.serialize(valuesData)
  }

  public var description: String {
    "MixerDescriptor(name: \"\(objectName)\", sources: \(sources.count))"
  }
}

/// MATRIX descriptor (IEEE 1722.1-2021 Table 7-45). The values are kept packed as `valuesData`,
/// from values_offset to the end of the descriptor, since their layout depends on
/// `controlValueType`.
public struct MatrixDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 98

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var blockLatency: UInt32
  public var controlLatency: UInt32
  public var controlDomain: UInt16
  public var controlValueType: ControlValueType
  public var controlType: UniqueIdentifier
  public var width: UInt16
  public var height: UInt16
  public var numberOfValues: UInt16
  /// The MATRIX_SIGNAL descriptors describing the matrix's sources.
  public var numberOfSources: UInt16
  public var baseSource: UInt16
  public var valuesData: [UInt8]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    controlLatency = try UInt32(parsingBigEndian: &input)
    controlDomain = try UInt16(parsingBigEndian: &input)
    controlValueType = try ControlValueType(rawValue: UInt16(parsingBigEndian: &input))
    controlType = try UniqueIdentifier(parsing: &input)
    width = try UInt16(parsingBigEndian: &input)
    height = try UInt16(parsingBigEndian: &input)
    let valuesOffset = try UInt16(parsingBigEndian: &input)
    numberOfValues = try UInt16(parsingBigEndian: &input)
    numberOfSources = try UInt16(parsingBigEndian: &input)
    baseSource = try UInt16(parsingBigEndian: &input)
    valuesData = try input.descriptorBytes(from: valuesOffset)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint32: blockLatency)
    context.serialize(uint32: controlLatency)
    context.serialize(uint16: controlDomain)
    context.serialize(uint16: controlValueType.rawValue)
    try context.serialize(controlType)
    context.serialize(uint16: width)
    context.serialize(uint16: height)
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    context.serialize(uint16: numberOfValues)
    context.serialize(uint16: numberOfSources)
    context.serialize(uint16: baseSource)
    context.serialize(valuesData)
  }

  public var description: String {
    "MatrixDescriptor(name: \"\(objectName)\", size: \(width)x\(height))"
  }
}

/// MATRIX_SIGNAL descriptor (IEEE 1722.1-2021 Table 7-47), whose count precedes its offset.
public struct MatrixSignalDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 4

  public var signals: [SignalSource]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    let signalsCount = try UInt16(parsingBigEndian: &input)
    let signalsOffset = try UInt16(parsingBigEndian: &input)
    signals = try input.descriptorArray(at: signalsOffset, count: signalsCount, length: SignalSource.length) {
      try SignalSource(parsing: &$0)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    try context.serialize(count: signals.count)
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    for signal in signals {
      try signal.serialize(into: &context)
    }
  }

  public var description: String { "MatrixSignalDescriptor(signals: \(signals.count))" }
}

/// SIGNAL_SPLITTER descriptor (IEEE 1722.1-2021 Table 7-49).
public struct SignalSplitterDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 88

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var blockLatency: UInt32
  public var controlLatency: UInt32
  public var controlDomain: UInt16
  public var signalType: DescriptorType
  public var signalIndex: UInt16
  public var signalOutput: UInt16
  public var numberOfOutputs: UInt16
  public var splitterMap: [SubSignalMapping]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    controlLatency = try UInt32(parsingBigEndian: &input)
    controlDomain = try UInt16(parsingBigEndian: &input)
    signalType = try DescriptorType(parsing: &input)
    signalIndex = try UInt16(parsingBigEndian: &input)
    signalOutput = try UInt16(parsingBigEndian: &input)
    numberOfOutputs = try UInt16(parsingBigEndian: &input)
    let mapCount = try UInt16(parsingBigEndian: &input)
    let mapOffset = try UInt16(parsingBigEndian: &input)
    splitterMap = try input.descriptorArray(at: mapOffset, count: mapCount, length: SubSignalMapping.length) {
      try SubSignalMapping(parsing: &$0)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint32: blockLatency)
    context.serialize(uint32: controlLatency)
    context.serialize(uint16: controlDomain)
    try context.serialize(signalType)
    context.serialize(uint16: signalIndex)
    context.serialize(uint16: signalOutput)
    context.serialize(uint16: numberOfOutputs)
    try context.serialize(count: splitterMap.count)
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    for mapping in splitterMap {
      mapping.serialize(into: &context)
    }
  }

  public var description: String {
    "SignalSplitterDescriptor(name: \"\(objectName)\", outputs: \(numberOfOutputs))"
  }
}

/// SIGNAL_COMBINER descriptor (IEEE 1722.1-2021 Table 7-51).
public struct SignalCombinerDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 84

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var blockLatency: UInt32
  public var controlLatency: UInt32
  public var controlDomain: UInt16
  public var combinerMap: [SubSignalMapping]
  public var sources: [SignalSource]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    controlLatency = try UInt32(parsingBigEndian: &input)
    controlDomain = try UInt16(parsingBigEndian: &input)
    let mapCount = try UInt16(parsingBigEndian: &input)
    let mapOffset = try UInt16(parsingBigEndian: &input)
    let sourcesOffset = try UInt16(parsingBigEndian: &input)
    let numberOfSources = try UInt16(parsingBigEndian: &input)
    combinerMap = try input.descriptorArray(at: mapOffset, count: mapCount, length: SubSignalMapping.length) {
      try SubSignalMapping(parsing: &$0)
    }
    sources = try input.descriptorArray(at: sourcesOffset, count: numberOfSources, length: SignalSource.length) {
      try SignalSource(parsing: &$0)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    let mapOffset = _descriptorHeaderLength + Self.bodyLength
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint32: blockLatency)
    context.serialize(uint32: controlLatency)
    context.serialize(uint16: controlDomain)
    try context.serialize(count: combinerMap.count)
    context.serialize(uint16: UInt16(mapOffset))
    try context.serialize(count: mapOffset + combinerMap.count * SubSignalMapping.length)
    try context.serialize(count: sources.count)
    for mapping in combinerMap {
      mapping.serialize(into: &context)
    }
    for source in sources {
      try source.serialize(into: &context)
    }
  }

  public var description: String {
    "SignalCombinerDescriptor(name: \"\(objectName)\", sources: \(sources.count))"
  }
}

/// SIGNAL_DEMULTIPLEXER descriptor (IEEE 1722.1-2021 Table 7-54).
public struct SignalDemultiplexerDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 88

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var blockLatency: UInt32
  public var controlLatency: UInt32
  public var controlDomain: UInt16
  public var signalType: DescriptorType
  public var signalIndex: UInt16
  public var signalOutput: UInt16
  public var numberOfOutputs: UInt16
  public var demultiplexerMap: [SubSignalMapping]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    controlLatency = try UInt32(parsingBigEndian: &input)
    controlDomain = try UInt16(parsingBigEndian: &input)
    signalType = try DescriptorType(parsing: &input)
    signalIndex = try UInt16(parsingBigEndian: &input)
    signalOutput = try UInt16(parsingBigEndian: &input)
    numberOfOutputs = try UInt16(parsingBigEndian: &input)
    let mapCount = try UInt16(parsingBigEndian: &input)
    let mapOffset = try UInt16(parsingBigEndian: &input)
    demultiplexerMap = try input.descriptorArray(at: mapOffset, count: mapCount, length: SubSignalMapping.length) {
      try SubSignalMapping(parsing: &$0)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint32: blockLatency)
    context.serialize(uint32: controlLatency)
    context.serialize(uint16: controlDomain)
    try context.serialize(signalType)
    context.serialize(uint16: signalIndex)
    context.serialize(uint16: signalOutput)
    context.serialize(uint16: numberOfOutputs)
    try context.serialize(count: demultiplexerMap.count)
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    for mapping in demultiplexerMap {
      mapping.serialize(into: &context)
    }
  }

  public var description: String {
    "SignalDemultiplexerDescriptor(name: \"\(objectName)\", outputs: \(numberOfOutputs))"
  }
}

/// SIGNAL_MULTIPLEXER descriptor (IEEE 1722.1-2021 Table 7-56).
public struct SignalMultiplexerDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 84

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var blockLatency: UInt32
  public var controlLatency: UInt32
  public var controlDomain: UInt16
  public var multiplexerMap: [SubSignalMapping]
  public var sources: [SignalSource]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    controlLatency = try UInt32(parsingBigEndian: &input)
    controlDomain = try UInt16(parsingBigEndian: &input)
    let mapCount = try UInt16(parsingBigEndian: &input)
    let mapOffset = try UInt16(parsingBigEndian: &input)
    let sourcesOffset = try UInt16(parsingBigEndian: &input)
    let numberOfSources = try UInt16(parsingBigEndian: &input)
    multiplexerMap = try input.descriptorArray(at: mapOffset, count: mapCount, length: SubSignalMapping.length) {
      try SubSignalMapping(parsing: &$0)
    }
    sources = try input.descriptorArray(at: sourcesOffset, count: numberOfSources, length: SignalSource.length) {
      try SignalSource(parsing: &$0)
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    let mapOffset = _descriptorHeaderLength + Self.bodyLength
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint32: blockLatency)
    context.serialize(uint32: controlLatency)
    context.serialize(uint16: controlDomain)
    try context.serialize(count: multiplexerMap.count)
    context.serialize(uint16: UInt16(mapOffset))
    try context.serialize(count: mapOffset + multiplexerMap.count * SubSignalMapping.length)
    try context.serialize(count: sources.count)
    for mapping in multiplexerMap {
      mapping.serialize(into: &context)
    }
    for source in sources {
      try source.serialize(into: &context)
    }
  }

  public var description: String {
    "SignalMultiplexerDescriptor(name: \"\(objectName)\", sources: \(sources.count))"
  }
}

/// SIGNAL_TRANSCODER descriptor (IEEE 1722.1-2021 Table 7-59). The values are kept packed as
/// `valuesData`, from values_offset to the end of the descriptor, since their layout depends on
/// `controlValueType`.
public struct SignalTranscoderDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 96

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var blockLatency: UInt32
  public var controlLatency: UInt32
  public var controlDomain: UInt16
  public var controlValueType: ControlValueType
  public var numberOfValues: UInt16
  public var signalType: DescriptorType
  public var signalIndex: UInt16
  public var signalOutput: UInt16
  public var transcoderType: UniqueIdentifier
  public var valuesData: [UInt8]

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    blockLatency = try UInt32(parsingBigEndian: &input)
    controlLatency = try UInt32(parsingBigEndian: &input)
    controlDomain = try UInt16(parsingBigEndian: &input)
    controlValueType = try ControlValueType(rawValue: UInt16(parsingBigEndian: &input))
    let valuesOffset = try UInt16(parsingBigEndian: &input)
    numberOfValues = try UInt16(parsingBigEndian: &input)
    signalType = try DescriptorType(parsing: &input)
    signalIndex = try UInt16(parsingBigEndian: &input)
    signalOutput = try UInt16(parsingBigEndian: &input)
    transcoderType = try UniqueIdentifier(parsing: &input)
    valuesData = try input.descriptorBytes(from: valuesOffset)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint32: blockLatency)
    context.serialize(uint32: controlLatency)
    context.serialize(uint16: controlDomain)
    context.serialize(uint16: controlValueType.rawValue)
    context.serialize(uint16: UInt16(_descriptorHeaderLength + Self.bodyLength))
    context.serialize(uint16: numberOfValues)
    try context.serialize(signalType)
    context.serialize(uint16: signalIndex)
    context.serialize(uint16: signalOutput)
    try context.serialize(transcoderType)
    context.serialize(valuesData)
  }

  public var description: String {
    "SignalTranscoderDescriptor(name: \"\(objectName)\", type: \(transcoderType))"
  }
}

/// CONTROL_BLOCK descriptor (IEEE 1722.1-2021 Table 7-62).
public struct ControlBlockDescriptor: Sendable, Hashable, CustomStringConvertible {
  static let bodyLength = 78

  public var objectName: String
  public var localizedDescription: LocalizedStringReference
  public var numberOfControls: UInt16
  public var baseControl: UInt16
  public var finalControlIndex: UInt16
  public var signalType: DescriptorType
  public var signalIndex: UInt16
  public var signalOutput: UInt16

  init(parsingBody input: inout ParserSpan) throws {
    try input.requireRemaining(Self.bodyLength)
    objectName = try String(parsingAvdeccFixedString: &input)
    localizedDescription = try LocalizedStringReference(parsing: &input)
    numberOfControls = try UInt16(parsingBigEndian: &input)
    baseControl = try UInt16(parsingBigEndian: &input)
    finalControlIndex = try UInt16(parsingBigEndian: &input)
    signalType = try DescriptorType(parsing: &input)
    signalIndex = try UInt16(parsingBigEndian: &input)
    signalOutput = try UInt16(parsingBigEndian: &input)
  }

  func serializeBody(into context: inout SerializationContext) throws {
    context.serialize(avdeccFixedString: objectName)
    try context.serialize(localizedDescription)
    context.serialize(uint16: numberOfControls)
    context.serialize(uint16: baseControl)
    context.serialize(uint16: finalControlIndex)
    try context.serialize(signalType)
    context.serialize(uint16: signalIndex)
    context.serialize(uint16: signalOutput)
  }

  public var description: String {
    "ControlBlockDescriptor(name: \"\(objectName)\", controls: \(numberOfControls)@\(baseControl))"
  }
}

// MARK: - Descriptor

/// Any AEM descriptor (IEEE 1722.1-2021 §7.2). Types without a dedicated model are kept as
/// their undecoded body.
public enum Descriptor: Sendable, Hashable {
  case entity(EntityDescriptor)
  case configuration(ConfigurationDescriptor)
  case audioUnit(AudioUnitDescriptor)
  case streamInput(StreamDescriptor)
  case streamOutput(StreamDescriptor)
  case jackInput(JackDescriptor)
  case jackOutput(JackDescriptor)
  case avbInterface(AvbInterfaceDescriptor)
  case clockSource(ClockSourceDescriptor)
  case memoryObject(MemoryObjectDescriptor)
  case locale(LocaleDescriptor)
  case strings(StringsDescriptor)
  case streamPortInput(StreamPortDescriptor)
  case streamPortOutput(StreamPortDescriptor)
  case externalPortInput(ExternalPortDescriptor)
  case externalPortOutput(ExternalPortDescriptor)
  case internalPortInput(InternalPortDescriptor)
  case internalPortOutput(InternalPortDescriptor)
  case audioCluster(AudioClusterDescriptor)
  case audioMap(AudioMapDescriptor)
  case control(ControlDescriptor)
  case clockDomain(ClockDomainDescriptor)
  case timing(TimingDescriptor)
  case ptpInstance(PtpInstanceDescriptor)
  case ptpPort(PtpPortDescriptor)
  case videoUnit(VideoUnitDescriptor)
  case sensorUnit(SensorUnitDescriptor)
  case videoCluster(VideoClusterDescriptor)
  case sensorCluster(SensorClusterDescriptor)
  case videoMap(VideoMapDescriptor)
  case sensorMap(SensorMapDescriptor)
  case signalSelector(SignalSelectorDescriptor)
  case mixer(MixerDescriptor)
  case matrix(MatrixDescriptor)
  case matrixSignal(MatrixSignalDescriptor)
  case signalSplitter(SignalSplitterDescriptor)
  case signalCombiner(SignalCombinerDescriptor)
  case signalDemultiplexer(SignalDemultiplexerDescriptor)
  case signalMultiplexer(SignalMultiplexerDescriptor)
  case signalTranscoder(SignalTranscoderDescriptor)
  case controlBlock(ControlBlockDescriptor)
  case other(descriptorType: UInt16, body: [UInt8])

  public var descriptorType: DescriptorType {
    switch self {
    case .entity: .entity
    case .configuration: .configuration
    case .audioUnit: .audioUnit
    case .streamInput: .streamInput
    case .streamOutput: .streamOutput
    case .jackInput: .jackInput
    case .jackOutput: .jackOutput
    case .avbInterface: .avbInterface
    case .clockSource: .clockSource
    case .memoryObject: .memoryObject
    case .locale: .locale
    case .strings: .strings
    case .streamPortInput: .streamPortInput
    case .streamPortOutput: .streamPortOutput
    case .externalPortInput: .externalPortInput
    case .externalPortOutput: .externalPortOutput
    case .internalPortInput: .internalPortInput
    case .internalPortOutput: .internalPortOutput
    case .audioCluster: .audioCluster
    case .audioMap: .audioMap
    case .control: .control
    case .clockDomain: .clockDomain
    case .timing: .timing
    case .ptpInstance: .ptpInstance
    case .ptpPort: .ptpPort
    case .videoUnit: .videoUnit
    case .sensorUnit: .sensorUnit
    case .videoCluster: .videoCluster
    case .sensorCluster: .sensorCluster
    case .videoMap: .videoMap
    case .sensorMap: .sensorMap
    case .signalSelector: .signalSelector
    case .mixer: .mixer
    case .matrix: .matrix
    case .matrixSignal: .matrixSignal
    case .signalSplitter: .signalSplitter
    case .signalCombiner: .signalCombiner
    case .signalDemultiplexer: .signalDemultiplexer
    case .signalMultiplexer: .signalMultiplexer
    case .signalTranscoder: .signalTranscoder
    case .controlBlock: .controlBlock
    case let .other(descriptorType, _): DescriptorType(rawValue: descriptorType)
    }
  }

  /// Parses a descriptor body of `descriptorTypeRaw` from `input`, whose absolute position 0
  /// must be the start of the descriptor (its descriptor_type field).
  init(descriptorTypeRaw: UInt16, parsingBody input: inout ParserSpan) throws {
    switch DescriptorType(rawValue: descriptorTypeRaw) {
    case .entity: self = try .entity(EntityDescriptor(parsingBody: &input))
    case .configuration: self = try .configuration(ConfigurationDescriptor(parsingBody: &input))
    case .audioUnit: self = try .audioUnit(AudioUnitDescriptor(parsingBody: &input))
    case .streamInput: self = try .streamInput(StreamDescriptor(parsingBody: &input))
    case .streamOutput: self = try .streamOutput(StreamDescriptor(parsingBody: &input))
    case .jackInput: self = try .jackInput(JackDescriptor(parsingBody: &input))
    case .jackOutput: self = try .jackOutput(JackDescriptor(parsingBody: &input))
    case .avbInterface: self = try .avbInterface(AvbInterfaceDescriptor(parsingBody: &input))
    case .clockSource: self = try .clockSource(ClockSourceDescriptor(parsingBody: &input))
    case .memoryObject: self = try .memoryObject(MemoryObjectDescriptor(parsingBody: &input))
    case .locale: self = try .locale(LocaleDescriptor(parsingBody: &input))
    case .strings: self = try .strings(StringsDescriptor(parsingBody: &input))
    case .streamPortInput: self = try .streamPortInput(StreamPortDescriptor(parsingBody: &input))
    case .streamPortOutput:
      self = try .streamPortOutput(StreamPortDescriptor(parsingBody: &input))
    case .externalPortInput:
      self = try .externalPortInput(ExternalPortDescriptor(parsingBody: &input))
    case .externalPortOutput:
      self = try .externalPortOutput(ExternalPortDescriptor(parsingBody: &input))
    case .internalPortInput:
      self = try .internalPortInput(InternalPortDescriptor(parsingBody: &input))
    case .internalPortOutput:
      self = try .internalPortOutput(InternalPortDescriptor(parsingBody: &input))
    case .audioCluster: self = try .audioCluster(AudioClusterDescriptor(parsingBody: &input))
    case .audioMap: self = try .audioMap(AudioMapDescriptor(parsingBody: &input))
    case .control: self = try .control(ControlDescriptor(parsingBody: &input))
    case .clockDomain: self = try .clockDomain(ClockDomainDescriptor(parsingBody: &input))
    case .timing: self = try .timing(TimingDescriptor(parsingBody: &input))
    case .ptpInstance: self = try .ptpInstance(PtpInstanceDescriptor(parsingBody: &input))
    case .ptpPort: self = try .ptpPort(PtpPortDescriptor(parsingBody: &input))
    case .videoUnit: self = try .videoUnit(VideoUnitDescriptor(parsingBody: &input))
    case .sensorUnit: self = try .sensorUnit(SensorUnitDescriptor(parsingBody: &input))
    case .videoCluster: self = try .videoCluster(VideoClusterDescriptor(parsingBody: &input))
    case .sensorCluster: self = try .sensorCluster(SensorClusterDescriptor(parsingBody: &input))
    case .videoMap: self = try .videoMap(VideoMapDescriptor(parsingBody: &input))
    case .sensorMap: self = try .sensorMap(SensorMapDescriptor(parsingBody: &input))
    case .signalSelector: self = try .signalSelector(SignalSelectorDescriptor(parsingBody: &input))
    case .mixer: self = try .mixer(MixerDescriptor(parsingBody: &input))
    case .matrix: self = try .matrix(MatrixDescriptor(parsingBody: &input))
    case .matrixSignal: self = try .matrixSignal(MatrixSignalDescriptor(parsingBody: &input))
    case .signalSplitter: self = try .signalSplitter(SignalSplitterDescriptor(parsingBody: &input))
    case .signalCombiner: self = try .signalCombiner(SignalCombinerDescriptor(parsingBody: &input))
    case .signalDemultiplexer:
      self = try .signalDemultiplexer(SignalDemultiplexerDescriptor(parsingBody: &input))
    case .signalMultiplexer:
      self = try .signalMultiplexer(SignalMultiplexerDescriptor(parsingBody: &input))
    case .signalTranscoder:
      self = try .signalTranscoder(SignalTranscoderDescriptor(parsingBody: &input))
    case .controlBlock: self = try .controlBlock(ControlBlockDescriptor(parsingBody: &input))
    default:
      self = .other(
        descriptorType: descriptorTypeRaw,
        body: [UInt8](parsingRemainingBytes: &input)
      )
    }
  }

  func serializeBody(into context: inout SerializationContext) throws {
    switch self {
    case let .entity(descriptor): try descriptor.serializeBody(into: &context)
    case let .configuration(descriptor): try descriptor.serializeBody(into: &context)
    case let .audioUnit(descriptor): try descriptor.serializeBody(into: &context)
    case let .streamInput(descriptor), let .streamOutput(descriptor):
      try descriptor.serializeBody(into: &context)
    case let .jackInput(descriptor), let .jackOutput(descriptor):
      try descriptor.serializeBody(into: &context)
    case let .avbInterface(descriptor): try descriptor.serializeBody(into: &context)
    case let .clockSource(descriptor): try descriptor.serializeBody(into: &context)
    case let .memoryObject(descriptor): try descriptor.serializeBody(into: &context)
    case let .locale(descriptor): try descriptor.serializeBody(into: &context)
    case let .strings(descriptor): try descriptor.serializeBody(into: &context)
    case let .streamPortInput(descriptor), let .streamPortOutput(descriptor):
      try descriptor.serializeBody(into: &context)
    case let .externalPortInput(descriptor), let .externalPortOutput(descriptor):
      try descriptor.serializeBody(into: &context)
    case let .internalPortInput(descriptor), let .internalPortOutput(descriptor):
      try descriptor.serializeBody(into: &context)
    case let .audioCluster(descriptor): try descriptor.serializeBody(into: &context)
    case let .audioMap(descriptor): try descriptor.serializeBody(into: &context)
    case let .control(descriptor): try descriptor.serializeBody(into: &context)
    case let .clockDomain(descriptor): try descriptor.serializeBody(into: &context)
    case let .timing(descriptor): try descriptor.serializeBody(into: &context)
    case let .ptpInstance(descriptor): try descriptor.serializeBody(into: &context)
    case let .ptpPort(descriptor): try descriptor.serializeBody(into: &context)
    case let .videoUnit(descriptor): try descriptor.serializeBody(into: &context)
    case let .sensorUnit(descriptor): try descriptor.serializeBody(into: &context)
    case let .videoCluster(descriptor): try descriptor.serializeBody(into: &context)
    case let .sensorCluster(descriptor): try descriptor.serializeBody(into: &context)
    case let .videoMap(descriptor): try descriptor.serializeBody(into: &context)
    case let .sensorMap(descriptor): try descriptor.serializeBody(into: &context)
    case let .signalSelector(descriptor): try descriptor.serializeBody(into: &context)
    case let .mixer(descriptor): try descriptor.serializeBody(into: &context)
    case let .matrix(descriptor): try descriptor.serializeBody(into: &context)
    case let .matrixSignal(descriptor): try descriptor.serializeBody(into: &context)
    case let .signalSplitter(descriptor): try descriptor.serializeBody(into: &context)
    case let .signalCombiner(descriptor): try descriptor.serializeBody(into: &context)
    case let .signalDemultiplexer(descriptor): try descriptor.serializeBody(into: &context)
    case let .signalMultiplexer(descriptor): try descriptor.serializeBody(into: &context)
    case let .signalTranscoder(descriptor): try descriptor.serializeBody(into: &context)
    case let .controlBlock(descriptor): try descriptor.serializeBody(into: &context)
    case let .other(_, body): context.serialize(body)
    }
  }

  var descriptorTypeRaw: UInt16 {
    if case let .other(descriptorType, _) = self { return descriptorType }
    return descriptorType.rawValue
  }

  /// Serializes the complete descriptor: descriptor_type, `descriptorIndex`, then the body.
  public func serialize(
    descriptorIndex: DescriptorIndex,
    into context: inout SerializationContext
  ) throws {
    context.serialize(uint16: descriptorTypeRaw)
    context.serialize(uint16: descriptorIndex)
    try serializeBody(into: &context)
  }
}

extension StreamFormat: SerDes {
  public init(parsing input: inout ParserSpan) throws {
    try self.init(format: UInt64(parsingBigEndian: &input))
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint64: format)
  }
}

private extension SerializationContext {
  /// Serializes a count, or an offset that follows counted items, into its 16-bit field.
  mutating func serialize(count: Int) throws {
    guard let count = UInt16(exactly: count) else { throw AvdeccCodecError.valueTooLarge }
    serialize(uint16: count)
  }
}

extension ParserSpan {
  /// Validates an offset from the start of the descriptor (absolute position 0) before seeking
  /// to it: la_avdecc rejects offsets that point back into the fixed fields already read.
  func descriptorOffset(_ offset: UInt16) throws -> Int {
    guard Int(offset) >= startPosition else {
      throw AvdeccCodecError.invalidOffset(Int(offset))
    }
    return Int(offset)
  }

  /// The `count` elements of `length` octets at descriptor `offset`.
  func descriptorArray<Element>(
    at offset: UInt16,
    count: UInt16,
    length: Int,
    _ parse: (inout ParserSpan) throws -> Element
  ) throws -> [Element] {
    var elements = try seeking(toAbsoluteOffset: descriptorOffset(offset))
    try elements.requireRemaining(count, of: length)
    return try (0..<count).map { _ in try parse(&elements) }
  }

  /// The octets from descriptor `offset` to the end of the descriptor.
  func descriptorBytes(from offset: UInt16) throws -> [UInt8] {
    var bytes = try seeking(toAbsoluteOffset: descriptorOffset(offset))
    return [UInt8](parsingRemainingBytes: &bytes)
  }
}
