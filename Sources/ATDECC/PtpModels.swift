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

// Payloads of the PTP_INSTANCE and PTP_PORT commands (IEEE 1722.1-2021 §7.4.81 to §7.4.101),
// which carry IEEE 802.1AS-2020 data set members. Flag bits are numbered MSB first, so bit 15
// of a 16-bit field is its least significant bit.

/// A clockQuality (IEEE 802.1AS-2020 §8.6.2.2 to §8.6.2.4).
public struct PtpClockQuality: Sendable, Hashable {
  public var clockClass: UInt8
  public var clockAccuracy: UInt8
  public var offsetScaledLogVariance: UInt16

  public init(clockClass: UInt8, clockAccuracy: UInt8, offsetScaledLogVariance: UInt16) {
    self.clockClass = clockClass
    self.clockAccuracy = clockAccuracy
    self.offsetScaledLogVariance = offsetScaledLogVariance
  }
}

/// The cv, l59, l61, tt, ft and pt bits of a defaultDS or timePropertiesDS.
public struct PtpTimeProperties: OptionSet, Sendable, Hashable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let currentUtcOffsetValid = PtpTimeProperties(rawValue: 1 << 5)
  public static let leap59 = PtpTimeProperties(rawValue: 1 << 4)
  public static let leap61 = PtpTimeProperties(rawValue: 1 << 3)
  public static let timeTraceable = PtpTimeProperties(rawValue: 1 << 2)
  public static let frequencyTraceable = PtpTimeProperties(rawValue: 1 << 1)
  public static let ptpTimescale = PtpTimeProperties(rawValue: 1 << 0)
}

/// The so, ee and ie bits of a PTP Instance's defaultDS.
public struct PtpInstanceStateFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let slaveOnly = PtpInstanceStateFlags(rawValue: 1 << 2)
  public static let externalPortConfigurationEnabled = PtpInstanceStateFlags(rawValue: 1 << 1)
  public static let instanceEnabled = PtpInstanceStateFlags(rawValue: 1 << 0)
}

/// Which SET_PTP_INSTANCE_INFO fields are to be set (IEEE 1722.1-2021 Table 7-165).
public struct SetPtpInstanceInfoFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let instanceEnabled = SetPtpInstanceInfoFlags(rawValue: 1 << 0)
  public static let externalPortConfigurationEnabled = SetPtpInstanceInfoFlags(rawValue: 1 << 1)
  public static let slaveOnly = SetPtpInstanceInfoFlags(rawValue: 1 << 2)
  public static let priority1 = SetPtpInstanceInfoFlags(rawValue: 1 << 8)
  public static let priority2 = SetPtpInstanceInfoFlags(rawValue: 1 << 9)
  public static let domainNumber = SetPtpInstanceInfoFlags(rawValue: 1 << 10)
}

/// The writable members of a PTP Instance's defaultDS (SET_PTP_INSTANCE_INFO, IEEE 1722.1-2021
/// Figure 7-99). Entities ignore `flags` in responses.
public struct PtpInstanceSettings: Sendable, Hashable {
  public var flags: SetPtpInstanceInfoFlags
  public var priority1: UInt8
  public var priority2: UInt8
  public var domainNumber: UInt8
  public var state: PtpInstanceStateFlags

  public init(
    flags: SetPtpInstanceInfoFlags,
    priority1: UInt8 = 0,
    priority2: UInt8 = 0,
    domainNumber: UInt8 = 0,
    state: PtpInstanceStateFlags = []
  ) {
    self.flags = flags
    self.priority1 = priority1
    self.priority2 = priority2
    self.domainNumber = domainNumber
    self.state = state
  }
}

/// A grandmaster as a PTP Instance's parentDS and timePropertiesDS describe it.
public struct PtpGrandmaster: Sendable, Hashable {
  public let clockIdentity: UniqueIdentifier
  public let clockQuality: PtpClockQuality
  public let priority1: UInt8
  public let priority2: UInt8
  public let timeSource: UInt8
  public let timeProperties: PtpTimeProperties
  public let currentUtcOffset: Int16
}

/// GET_PTP_INSTANCE_INFO (IEEE 1722.1-2021 Figure 7-101).
public struct PtpInstanceInfo: Sendable, Hashable {
  public let clockQuality: PtpClockQuality
  public let priority1: UInt8
  public let priority2: UInt8
  public let domainNumber: UInt8
  public let timeSource: UInt8
  public let currentUtcOffset: Int16
  public let timeProperties: PtpTimeProperties
  public let state: PtpInstanceStateFlags
  public let grandmaster: PtpGrandmaster
}

/// GET_PTP_INSTANCE_GRANDMASTER_INFO (IEEE 1722.1-2021 Figure 7-105).
public struct PtpGrandmasterInfo: Sendable, Hashable {
  public let grandmaster: PtpGrandmaster
  public let parentClockIdentity: UniqueIdentifier
  public let parentPortNumber: UInt16
  public let stepsRemoved: UInt16
}

/// An IEEE 802.1AS-2020 ScaledNs: a signed 96-bit count of 2^-16 nanoseconds.
public struct PtpScaledNanoseconds: Sendable, Hashable {
  public let upper: Int32
  public let lower: UInt64

  public init(upper: Int32, lower: UInt64) {
    self.upper = upper
    self.lower = lower
  }

  public var nanoseconds: Double {
    (Double(upper) * 18_446_744_073_709_551_616 + Double(lower)) / 65536
  }
}

/// Which optional GET_PTP_INSTANCE_EXTENDED_INFO fields hold values (IEEE 1722.1-2021 Table 7-166).
public struct PtpInstanceExtendedInfoValidFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let offsetFromMaster = PtpInstanceExtendedInfoValidFlags(rawValue: 1 << 0)
  public static let lastGmPhaseChange = PtpInstanceExtendedInfoValidFlags(rawValue: 1 << 1)
  public static let lastGmFreqChange = PtpInstanceExtendedInfoValidFlags(rawValue: 1 << 2)
  public static let gmChangeCount = PtpInstanceExtendedInfoValidFlags(rawValue: 1 << 3)
  public static let timeOfLastGmChange = PtpInstanceExtendedInfoValidFlags(rawValue: 1 << 4)
  public static let timeOfLastGmPhaseChange = PtpInstanceExtendedInfoValidFlags(rawValue: 1 << 5)
  public static let timeOfLastGmFreqChange = PtpInstanceExtendedInfoValidFlags(rawValue: 1 << 6)
}

/// GET_PTP_INSTANCE_EXTENDED_INFO (IEEE 1722.1-2021 Figure 7-103), which gives
/// last_gm_freq_change 4 octets, kept here as received.
public struct PtpInstanceExtendedInfo: Sendable, Hashable {
  public let info: PtpInstanceInfo
  public let parentClockIdentity: UniqueIdentifier
  public let parentPortNumber: UInt16
  public let stepsRemoved: UInt16
  public let cumulativeRateRatio: Int32
  public let valid: PtpInstanceExtendedInfoValidFlags
  public let gmTimebaseIndicator: UInt16
  public let offsetFromMaster: PtpScaledNanoseconds
  public let lastGmPhaseChange: PtpScaledNanoseconds
  public let lastGmFreqChange: UInt32
  public let gmChangeCount: UInt32
  public let timeOfLastGmChange: UInt32
  public let timeOfLastGmPhaseChange: UInt32
  public let timeOfLastGmFreqChange: UInt32
}

/// Performance monitoring record list sizes (IEEE 1722.1-2021 Figures 7-111, 7-129 and 7-133).
public struct PtpPerfMonCounts: Sendable, Hashable {
  public let maxCountOf24h: UInt16
  public let countOf24h: UInt16
  public let maxCountOf15m: UInt16
  public let countOf15m: UInt16
}

/// Performance monitoring record flags (IEEE 1722.1-2021 Tables 7-167, 7-178 and 7-179); PTP_PORT
/// records carry only `measurementValid` and `periodComplete`.
public struct PtpPerfMonRecordFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let measurementValid = PtpPerfMonRecordFlags(rawValue: 1 << 0)
  public static let periodComplete = PtpPerfMonRecordFlags(rawValue: 1 << 1)
  public static let masterSlaveDelayValid = PtpPerfMonRecordFlags(rawValue: 1 << 2)
  public static let slaveMasterDelayValid = PtpPerfMonRecordFlags(rawValue: 1 << 3)
  public static let meanPathDelayValid = PtpPerfMonRecordFlags(rawValue: 1 << 4)
  public static let offsetFromMasterValid = PtpPerfMonRecordFlags(rawValue: 1 << 5)
}

/// Statistics of one delay over a monitoring period, as 8-octet values.
public struct PtpDelayStatistics: Sendable, Hashable {
  public let average: Int64
  public let minimum: Int64
  public let maximum: Int64
  public let standardDeviation: Int64
}

/// GET_PTP_INSTANCE_PERF_MON_RECORD (IEEE 1722.1-2021 Figure 7-113). `timestamp` is in
/// nanoseconds since an entity-defined epoch.
public struct PtpInstancePerfMonRecord: Sendable, Hashable {
  public let recordIndex: UInt16
  public let flags: PtpPerfMonRecordFlags
  public let timestamp: UInt64
  public let masterSlaveDelay: PtpDelayStatistics
  public let slaveMasterDelay: PtpDelayStatistics
  public let meanPathDelay: PtpDelayStatistics
  public let offsetFromMaster: PtpDelayStatistics
}

/// GET_PTP_PORT_PDELAY_MON_RECORD (IEEE 1722.1-2021 Figure 7-131).
public struct PtpPortPdelayMonRecord: Sendable, Hashable {
  public let recordIndex: UInt16
  public let flags: PtpPerfMonRecordFlags
  public let timestamp: UInt64
  public let meanLinkDelay: PtpDelayStatistics
}

/// GET_PTP_PORT_PERF_MON_RECORD (IEEE 1722.1-2021 Figure 7-135): message counts over the period.
public struct PtpPortPerfMonRecord: Sendable, Hashable {
  public let recordIndex: UInt16
  public let flags: PtpPerfMonRecordFlags
  public let timestamp: UInt64
  public let announceTx: UInt32
  public let announceRx: UInt32
  public let announceForeignMasterRx: UInt32
  public let syncTx: UInt32
  public let syncRx: UInt32
  public let followUpTx: UInt32
  public let followUpRx: UInt32
  public let delayReqTx: UInt32
  public let delayReqRx: UInt32
  public let delayRespTx: UInt32
  public let delayRespRx: UInt32
  public let pdelayReqTx: UInt32
  public let pdelayReqRx: UInt32
  public let pdelayRespTx: UInt32
  public let pdelayRespRx: UInt32
  public let pdelayRespFollowUpTx: UInt32
  public let pdelayRespFollowUpRx: UInt32
}

/// Which PTP_PORT message interval fields are set or hold values (IEEE 1722.1-2021 Tables 7-168
/// to 7-172).
public struct PtpPortIntervalFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let announce = PtpPortIntervalFlags(rawValue: 1 << 0)
  public static let sync = PtpPortIntervalFlags(rawValue: 1 << 1)
  public static let pdelay = PtpPortIntervalFlags(rawValue: 1 << 2)
  public static let gptpCapable = PtpPortIntervalFlags(rawValue: 1 << 3)
}

/// A PTP Port's log message intervals (the initial, current and remote interval commands, IEEE
/// 1722.1-2021 Figures 7-114 to 7-121).
public struct PtpPortIntervals: Sendable, Hashable {
  public var flags: PtpPortIntervalFlags
  public var logAnnounceInterval: Int8
  public var logSyncInterval: Int8
  public var logPdelayRequestInterval: Int8
  public var logGptpCapableInterval: Int8

  public init(
    flags: PtpPortIntervalFlags,
    logAnnounceInterval: Int8 = 0,
    logSyncInterval: Int8 = 0,
    logPdelayRequestInterval: Int8 = 0,
    logGptpCapableInterval: Int8 = 0
  ) {
    self.flags = flags
    self.logAnnounceInterval = logAnnounceInterval
    self.logSyncInterval = logSyncInterval
    self.logPdelayRequestInterval = logPdelayRequestInterval
    self.logGptpCapableInterval = logGptpCapableInterval
  }
}

/// Which SET_PTP_PORT_OVERRIDES fields are to be set (IEEE 1722.1-2021 Table 7-175).
public struct SetPtpPortOverridesFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let announceInterval = SetPtpPortOverridesFlags(rawValue: 1 << 0)
  public static let syncInterval = SetPtpPortOverridesFlags(rawValue: 1 << 1)
  public static let pdelayInterval = SetPtpPortOverridesFlags(rawValue: 1 << 2)
  public static let gptpCapableInterval = SetPtpPortOverridesFlags(rawValue: 1 << 3)
  public static let computeNeighbor = SetPtpPortOverridesFlags(rawValue: 1 << 4)
  public static let computeMeanDelay = SetPtpPortOverridesFlags(rawValue: 1 << 5)
  public static let oneStepTxOper = SetPtpPortOverridesFlags(rawValue: 1 << 6)
  public static let desiredState = SetPtpPortOverridesFlags(rawValue: 1 << 7)
}

/// A PTP Port's management override booleans (IEEE 1722.1-2021 Tables 7-176 and 7-177).
public struct PtpPortOverrideBooleans: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let useAnnounceInterval = PtpPortOverrideBooleans(rawValue: 1 << 0)
  public static let useSyncInterval = PtpPortOverrideBooleans(rawValue: 1 << 1)
  public static let usePdelayInterval = PtpPortOverrideBooleans(rawValue: 1 << 2)
  public static let useGptpCapableInterval = PtpPortOverrideBooleans(rawValue: 1 << 3)
  public static let useComputeNeighbor = PtpPortOverrideBooleans(rawValue: 1 << 4)
  public static let useComputeMeanDelay = PtpPortOverrideBooleans(rawValue: 1 << 5)
  public static let useOneStepTxOper = PtpPortOverrideBooleans(rawValue: 1 << 6)
  public static let computeNeighborRate = PtpPortOverrideBooleans(rawValue: 1 << 8)
  public static let computeMeanLinkDelay = PtpPortOverrideBooleans(rawValue: 1 << 9)
  public static let oneStepTxOper = PtpPortOverrideBooleans(rawValue: 1 << 10)
}

/// A PTP Port's management overrides (IEEE 1722.1-2021 Figures 7-125 and 7-127). `flags` is
/// reserved in GET_PTP_PORT_OVERRIDES responses.
public struct PtpPortOverrides: Sendable, Hashable {
  public var flags: SetPtpPortOverridesFlags
  public var booleans: PtpPortOverrideBooleans
  public var logAnnounceInterval: Int8
  public var logSyncInterval: Int8
  public var logPdelayRequestInterval: Int8
  public var logGptpCapableInterval: Int8
  public var desiredState: UInt8

  public init(
    flags: SetPtpPortOverridesFlags,
    booleans: PtpPortOverrideBooleans = [],
    logAnnounceInterval: Int8 = 0,
    logSyncInterval: Int8 = 0,
    logPdelayRequestInterval: Int8 = 0,
    logGptpCapableInterval: Int8 = 0,
    desiredState: UInt8 = 0
  ) {
    self.flags = flags
    self.booleans = booleans
    self.logAnnounceInterval = logAnnounceInterval
    self.logSyncInterval = logSyncInterval
    self.logPdelayRequestInterval = logPdelayRequestInterval
    self.logGptpCapableInterval = logGptpCapableInterval
    self.desiredState = desiredState
  }
}

// MARK: - Layouts

private extension Int8 {
  init(parsingOctet input: inout ParserSpan) throws {
    self = try Int8(bitPattern: UInt8(parsing: &input))
  }
}

extension PtpClockQuality {
  // clock_class, clock_accuracy, offset_scaled_log_variance
  init(parsing input: inout ParserSpan) throws {
    clockClass = try UInt8(parsing: &input)
    clockAccuracy = try UInt8(parsing: &input)
    offsetScaledLogVariance = try UInt16(parsingBigEndian: &input)
  }
}

extension PtpInstanceSettings {
  static let length = 8

  // reserved1, flags, priority1, priority2, domain_number, reserved2 and so/ee/ie
  init(parsing input: inout ParserSpan) throws {
    try input.requireRemaining(Self.length)
    _ = try UInt16(parsingBigEndian: &input) // reserved1
    flags = try SetPtpInstanceInfoFlags(rawValue: UInt16(parsingBigEndian: &input))
    priority1 = try UInt8(parsing: &input)
    priority2 = try UInt8(parsing: &input)
    domainNumber = try UInt8(parsing: &input)
    state = try PtpInstanceStateFlags(rawValue: UInt8(parsing: &input) & 0x07)
  }

  func serialize(into context: inout SerializationContext) {
    context.serialize(uint16: 0) // reserved1
    context.serialize(uint16: flags.rawValue)
    context.serialize(uint8: priority1)
    context.serialize(uint8: priority2)
    context.serialize(uint8: domainNumber)
    context.serialize(uint8: state.rawValue & 0x07)
  }
}

extension PtpGrandmaster {
  static let length = 20

  // gm_clock_identity, quality, gm_priority1, gm_priority2, gm_time_source, rsvd2 and the gm_*
  // time property bits, gm_current_utc_offset, reserved3
  init(parsing input: inout ParserSpan) throws {
    try input.requireRemaining(Self.length)
    clockIdentity = try UniqueIdentifier(parsing: &input)
    clockQuality = try PtpClockQuality(parsing: &input)
    priority1 = try UInt8(parsing: &input)
    priority2 = try UInt8(parsing: &input)
    timeSource = try UInt8(parsing: &input)
    timeProperties = try PtpTimeProperties(rawValue: UInt8(parsing: &input) & 0x3F)
    currentUtcOffset = try Int16(bitPattern: UInt16(parsingBigEndian: &input))
    _ = try UInt16(parsingBigEndian: &input) // reserved3
  }
}

extension PtpInstanceInfo {
  static let length = 32

  init(parsing input: inout ParserSpan) throws {
    try input.requireRemaining(Self.length)
    clockQuality = try PtpClockQuality(parsing: &input)
    priority1 = try UInt8(parsing: &input)
    priority2 = try UInt8(parsing: &input)
    domainNumber = try UInt8(parsing: &input)
    timeSource = try UInt8(parsing: &input)
    currentUtcOffset = try Int16(bitPattern: UInt16(parsingBigEndian: &input))
    // reserved1 (7 bits), cv, l59, l61, tt, ft, pt, so, ee, ie
    let bits = try UInt16(parsingBigEndian: &input)
    timeProperties = PtpTimeProperties(rawValue: UInt8((bits >> 3) & 0x3F))
    state = PtpInstanceStateFlags(rawValue: UInt8(bits & 0x07))
    grandmaster = try PtpGrandmaster(parsing: &input)
  }
}

extension PtpGrandmasterInfo {
  init(parsing input: inout ParserSpan) throws {
    try input.requireRemaining(PtpGrandmaster.length + 12)
    grandmaster = try PtpGrandmaster(parsing: &input)
    parentClockIdentity = try UniqueIdentifier(parsing: &input)
    parentPortNumber = try UInt16(parsingBigEndian: &input)
    stepsRemoved = try UInt16(parsingBigEndian: &input)
  }
}

extension PtpScaledNanoseconds {
  init(parsing input: inout ParserSpan) throws {
    upper = try Int32(bitPattern: UInt32(parsingBigEndian: &input))
    lower = try UInt64(parsingBigEndian: &input)
  }
}

extension PtpInstanceExtendedInfo {
  init(parsing input: inout ParserSpan) throws {
    try input.requireRemaining(PtpInstanceInfo.length + 64)
    info = try PtpInstanceInfo(parsing: &input)
    parentClockIdentity = try UniqueIdentifier(parsing: &input)
    parentPortNumber = try UInt16(parsingBigEndian: &input)
    stepsRemoved = try UInt16(parsingBigEndian: &input)
    cumulativeRateRatio = try Int32(bitPattern: UInt32(parsingBigEndian: &input))
    valid = try PtpInstanceExtendedInfoValidFlags(rawValue: UInt16(parsingBigEndian: &input))
    gmTimebaseIndicator = try UInt16(parsingBigEndian: &input)
    offsetFromMaster = try PtpScaledNanoseconds(parsing: &input)
    lastGmPhaseChange = try PtpScaledNanoseconds(parsing: &input)
    lastGmFreqChange = try UInt32(parsingBigEndian: &input)
    gmChangeCount = try UInt32(parsingBigEndian: &input)
    timeOfLastGmChange = try UInt32(parsingBigEndian: &input)
    timeOfLastGmPhaseChange = try UInt32(parsingBigEndian: &input)
    timeOfLastGmFreqChange = try UInt32(parsingBigEndian: &input)
  }
}

extension PtpPerfMonCounts {
  init(parsing input: inout ParserSpan) throws {
    maxCountOf24h = try UInt16(parsingBigEndian: &input)
    countOf24h = try UInt16(parsingBigEndian: &input)
    maxCountOf15m = try UInt16(parsingBigEndian: &input)
    countOf15m = try UInt16(parsingBigEndian: &input)
  }
}

extension PtpDelayStatistics {
  init(parsing input: inout ParserSpan) throws {
    average = try Int64(bitPattern: UInt64(parsingBigEndian: &input))
    minimum = try Int64(bitPattern: UInt64(parsingBigEndian: &input))
    maximum = try Int64(bitPattern: UInt64(parsingBigEndian: &input))
    standardDeviation = try Int64(bitPattern: UInt64(parsingBigEndian: &input))
  }
}

/// record_index, flags and timestamp, common to the performance monitoring records.
private func _parsePerfMonRecordHeader(
  _ input: inout ParserSpan
) throws -> (UInt16, PtpPerfMonRecordFlags, UInt64) {
  try (
    UInt16(parsingBigEndian: &input),
    PtpPerfMonRecordFlags(rawValue: UInt16(parsingBigEndian: &input)),
    UInt64(parsingBigEndian: &input)
  )
}

extension PtpInstancePerfMonRecord {
  init(parsing input: inout ParserSpan) throws {
    try input.requireRemaining(12 + 4 * 32)
    (recordIndex, flags, timestamp) = try _parsePerfMonRecordHeader(&input)
    masterSlaveDelay = try PtpDelayStatistics(parsing: &input)
    slaveMasterDelay = try PtpDelayStatistics(parsing: &input)
    meanPathDelay = try PtpDelayStatistics(parsing: &input)
    offsetFromMaster = try PtpDelayStatistics(parsing: &input)
  }
}

extension PtpPortPdelayMonRecord {
  init(parsing input: inout ParserSpan) throws {
    try input.requireRemaining(12 + 32)
    (recordIndex, flags, timestamp) = try _parsePerfMonRecordHeader(&input)
    meanLinkDelay = try PtpDelayStatistics(parsing: &input)
  }
}

extension PtpPortPerfMonRecord {
  init(parsing input: inout ParserSpan) throws {
    try input.requireRemaining(12 + 17 * 4)
    (recordIndex, flags, timestamp) = try _parsePerfMonRecordHeader(&input)
    announceTx = try UInt32(parsingBigEndian: &input)
    announceRx = try UInt32(parsingBigEndian: &input)
    announceForeignMasterRx = try UInt32(parsingBigEndian: &input)
    syncTx = try UInt32(parsingBigEndian: &input)
    syncRx = try UInt32(parsingBigEndian: &input)
    followUpTx = try UInt32(parsingBigEndian: &input)
    followUpRx = try UInt32(parsingBigEndian: &input)
    delayReqTx = try UInt32(parsingBigEndian: &input)
    delayReqRx = try UInt32(parsingBigEndian: &input)
    delayRespTx = try UInt32(parsingBigEndian: &input)
    delayRespRx = try UInt32(parsingBigEndian: &input)
    pdelayReqTx = try UInt32(parsingBigEndian: &input)
    pdelayReqRx = try UInt32(parsingBigEndian: &input)
    pdelayRespTx = try UInt32(parsingBigEndian: &input)
    pdelayRespRx = try UInt32(parsingBigEndian: &input)
    pdelayRespFollowUpTx = try UInt32(parsingBigEndian: &input)
    pdelayRespFollowUpRx = try UInt32(parsingBigEndian: &input)
  }
}

extension PtpPortIntervals {
  static let length = 8

  // reserved1, flags, then the four log intervals
  init(parsing input: inout ParserSpan) throws {
    try input.requireRemaining(Self.length)
    _ = try UInt16(parsingBigEndian: &input) // reserved1
    flags = try PtpPortIntervalFlags(rawValue: UInt16(parsingBigEndian: &input))
    logAnnounceInterval = try Int8(parsingOctet: &input)
    logSyncInterval = try Int8(parsingOctet: &input)
    logPdelayRequestInterval = try Int8(parsingOctet: &input)
    logGptpCapableInterval = try Int8(parsingOctet: &input)
  }

  func serialize(into context: inout SerializationContext) {
    context.serialize(uint16: 0) // reserved1
    context.serialize(uint16: flags.rawValue)
    context.serialize(uint8: UInt8(bitPattern: logAnnounceInterval))
    context.serialize(uint8: UInt8(bitPattern: logSyncInterval))
    context.serialize(uint8: UInt8(bitPattern: logPdelayRequestInterval))
    context.serialize(uint8: UInt8(bitPattern: logGptpCapableInterval))
  }
}

extension PtpPortOverrides {
  static let length = 12

  // flags (reserved1 in GET responses), booleans, the four log intervals, desired_state, reserved
  init(parsing input: inout ParserSpan) throws {
    try input.requireRemaining(Self.length)
    flags = try SetPtpPortOverridesFlags(rawValue: UInt16(parsingBigEndian: &input))
    booleans = try PtpPortOverrideBooleans(rawValue: UInt16(parsingBigEndian: &input))
    logAnnounceInterval = try Int8(parsingOctet: &input)
    logSyncInterval = try Int8(parsingOctet: &input)
    logPdelayRequestInterval = try Int8(parsingOctet: &input)
    logGptpCapableInterval = try Int8(parsingOctet: &input)
    desiredState = try UInt8(parsing: &input)
    _ = try UInt8(parsing: &input)
    _ = try UInt16(parsingBigEndian: &input) // reserved
  }

  func serialize(into context: inout SerializationContext) {
    context.serialize(uint16: flags.rawValue)
    context.serialize(uint16: booleans.rawValue)
    context.serialize(uint8: UInt8(bitPattern: logAnnounceInterval))
    context.serialize(uint8: UInt8(bitPattern: logSyncInterval))
    context.serialize(uint8: UInt8(bitPattern: logPdelayRequestInterval))
    context.serialize(uint8: UInt8(bitPattern: logGptpCapableInterval))
    context.serialize(uint8: desiredState)
    context.serialize(uint8: 0)
    context.serialize(uint16: 0) // reserved
  }
}
