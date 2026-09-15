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

// MARK: - ADP capabilities

/// ADP Entity Capabilities (IEEE 1722.1-2021 §6.2.2.10).
public struct EntityCapabilities: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let efuMode = EntityCapabilities(rawValue: 1 << 0)
  public static let addressAccessSupported = EntityCapabilities(rawValue: 1 << 1)
  public static let gatewayEntity = EntityCapabilities(rawValue: 1 << 2)
  public static let aemSupported = EntityCapabilities(rawValue: 1 << 3)
  public static let legacyAvc = EntityCapabilities(rawValue: 1 << 4)
  public static let associationIDSupported = EntityCapabilities(rawValue: 1 << 5)
  public static let associationIDValid = EntityCapabilities(rawValue: 1 << 6)
  public static let vendorUniqueSupported = EntityCapabilities(rawValue: 1 << 7)
  public static let classASupported = EntityCapabilities(rawValue: 1 << 8)
  public static let classBSupported = EntityCapabilities(rawValue: 1 << 9)
  public static let gptpSupported = EntityCapabilities(rawValue: 1 << 10)
  public static let aemAuthenticationSupported = EntityCapabilities(rawValue: 1 << 11)
  public static let aemAuthenticationRequired = EntityCapabilities(rawValue: 1 << 12)
  public static let aemPersistentAcquireSupported = EntityCapabilities(rawValue: 1 << 13)
  public static let aemIdentifyControlIndexValid = EntityCapabilities(rawValue: 1 << 14)
  public static let aemInterfaceIndexValid = EntityCapabilities(rawValue: 1 << 15)
  public static let generalControllerIgnore = EntityCapabilities(rawValue: 1 << 16)
  public static let entityNotReady = EntityCapabilities(rawValue: 1 << 17)
  public static let acmpAcquireWithAem = EntityCapabilities(rawValue: 1 << 18)
  public static let acmpAuthenticateWithAem = EntityCapabilities(rawValue: 1 << 19)
  public static let supportsUdpV4Atdecc = EntityCapabilities(rawValue: 1 << 20)
  public static let supportsUdpV4Streaming = EntityCapabilities(rawValue: 1 << 21)
  public static let supportsUdpV6Atdecc = EntityCapabilities(rawValue: 1 << 22)
  public static let supportsUdpV6Streaming = EntityCapabilities(rawValue: 1 << 23)
  public static let multiplePtpInstances = EntityCapabilities(rawValue: 1 << 24)
  public static let aemConfigurationIndexValid = EntityCapabilities(rawValue: 1 << 25)
}

/// ADP Talker Capabilities (IEEE 1722.1-2021 §6.2.2.11).
public struct TalkerCapabilities: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let implemented = TalkerCapabilities(rawValue: 1 << 0)
  public static let otherSource = TalkerCapabilities(rawValue: 1 << 9)
  public static let controlSource = TalkerCapabilities(rawValue: 1 << 10)
  public static let mediaClockSource = TalkerCapabilities(rawValue: 1 << 11)
  public static let smpteSource = TalkerCapabilities(rawValue: 1 << 12)
  public static let midiSource = TalkerCapabilities(rawValue: 1 << 13)
  public static let audioSource = TalkerCapabilities(rawValue: 1 << 14)
  public static let videoSource = TalkerCapabilities(rawValue: 1 << 15)
}

/// ADP Listener Capabilities (IEEE 1722.1-2021 §6.2.2.13).
public struct ListenerCapabilities: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let implemented = ListenerCapabilities(rawValue: 1 << 0)
  public static let otherSink = ListenerCapabilities(rawValue: 1 << 9)
  public static let controlSink = ListenerCapabilities(rawValue: 1 << 10)
  public static let mediaClockSink = ListenerCapabilities(rawValue: 1 << 11)
  public static let smpteSink = ListenerCapabilities(rawValue: 1 << 12)
  public static let midiSink = ListenerCapabilities(rawValue: 1 << 13)
  public static let audioSink = ListenerCapabilities(rawValue: 1 << 14)
  public static let videoSink = ListenerCapabilities(rawValue: 1 << 15)
}

/// ADP Controller Capabilities (IEEE 1722.1-2021 §6.2.2.14).
public struct ControllerCapabilities: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let implemented = ControllerCapabilities(rawValue: 1 << 0)
}

// MARK: - ACMP

/// ACMP connection flags (IEEE 1722.1-2021 §8.2.1.17). Bit 6 is named `talkerFailed` in
/// 1722.1-2013 and `srpRegistrationFailed` in 1722.1-2021; both are exposed.
public struct ConnectionFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let classB = ConnectionFlags(rawValue: 1 << 0)
  public static let fastConnect = ConnectionFlags(rawValue: 1 << 1)
  public static let savedState = ConnectionFlags(rawValue: 1 << 2)
  public static let streamingWait = ConnectionFlags(rawValue: 1 << 3)
  public static let supportsEncrypted = ConnectionFlags(rawValue: 1 << 4)
  public static let encryptedPdu = ConnectionFlags(rawValue: 1 << 5)
  public static let talkerFailed = ConnectionFlags(rawValue: 1 << 6)
  public static let srpRegistrationFailed = ConnectionFlags(rawValue: 1 << 6)
  public static let clEntriesValid = ConnectionFlags(rawValue: 1 << 7)
  public static let noSrp = ConnectionFlags(rawValue: 1 << 8)
  public static let udp = ConnectionFlags(rawValue: 1 << 9)
}

// MARK: - AEM command flags

/// ACQUIRE_ENTITY flags (IEEE 1722.1-2021 §7.4.1.1).
public struct AcquireEntityFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let persistent = AcquireEntityFlags(rawValue: 0x0000_0001)
  public static let release = AcquireEntityFlags(rawValue: 0x8000_0000)
}

/// LOCK_ENTITY flags (IEEE 1722.1-2021 §7.4.2.1).
public struct LockEntityFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let unlock = LockEntityFlags(rawValue: 0x0000_0001)
}

/// ENTITY_AVAILABLE response flags (IEEE 1722.1-2021 Table 7-144).
public struct EntityAvailableFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let entityAcquired = EntityAvailableFlags(rawValue: 1 << 0)
  public static let entityLocked = EntityAvailableFlags(rawValue: 1 << 1)
  public static let subentityAcquired = EntityAvailableFlags(rawValue: 1 << 2)
  public static let subentityLocked = EntityAvailableFlags(rawValue: 1 << 3)
}

/// REGISTER_UNSOLICITED_NOTIFICATION flags (IEEE 1722.1-2021 Table 7-147).
public struct RegisterUnsolicitedNotificationFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  /// The controller re-registers every 100 seconds, and the entity removes a registration
  /// that is not renewed within 300 seconds (§7.4.37.2).
  public static let timeLimited = RegisterUnsolicitedNotificationFlags(rawValue: 0x0000_0001)
}

/// AvbInfo flags (IEEE 1722.1-2021 §7.4.40.2).
public struct AvbInfoFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let asCapable = AvbInfoFlags(rawValue: 1 << 0)
  public static let gptpEnabled = AvbInfoFlags(rawValue: 1 << 1)
  public static let srpEnabled = AvbInfoFlags(rawValue: 1 << 2)
  public static let avtpDown = AvbInfoFlags(rawValue: 1 << 3)
  public static let avtpDownValid = AvbInfoFlags(rawValue: 1 << 4)
}

/// GET_STREAM_INFO flags (IEEE 1722.1-2021 §7.4.16.2).
public struct StreamInfoFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let classB = StreamInfoFlags(rawValue: 1 << 0)
  public static let fastConnect = StreamInfoFlags(rawValue: 1 << 1)
  public static let savedState = StreamInfoFlags(rawValue: 1 << 2)
  public static let streamingWait = StreamInfoFlags(rawValue: 1 << 3)
  public static let supportsEncrypted = StreamInfoFlags(rawValue: 1 << 4)
  public static let encryptedPdu = StreamInfoFlags(rawValue: 1 << 5)
  public static let talkerFailed = StreamInfoFlags(rawValue: 1 << 6)
  /// Bit 6, which Milan 1.3 names SRP_REGISTRATION_FAILED in GET_STREAM_INFO (Tables 5.8 and 5.9).
  public static let registeringFailed = StreamInfoFlags(rawValue: 1 << 6)
  public static let noSrp = StreamInfoFlags(rawValue: 1 << 8)
  public static let ipFlagsValid = StreamInfoFlags(rawValue: 1 << 19)
  public static let ipSrcPortValid = StreamInfoFlags(rawValue: 1 << 20)
  public static let ipDstPortValid = StreamInfoFlags(rawValue: 1 << 21)
  public static let ipSrcAddrValid = StreamInfoFlags(rawValue: 1 << 22)
  public static let ipDstAddrValid = StreamInfoFlags(rawValue: 1 << 23)
  /// Not `noSrp`: a Listener registering no Talker attribute yet, or a Talker whose
  /// declaration has no matching Listener attribute.
  public static let notRegisteringSrp = StreamInfoFlags(rawValue: 1 << 24)
  public static let streamVlanIDValid = StreamInfoFlags(rawValue: 1 << 25)
  public static let connected = StreamInfoFlags(rawValue: 1 << 26)
  public static let msrpFailureValid = StreamInfoFlags(rawValue: 1 << 27)
  public static let streamDestMacValid = StreamInfoFlags(rawValue: 1 << 28)
  public static let msrpAccLatValid = StreamInfoFlags(rawValue: 1 << 29)
  public static let streamIDValid = StreamInfoFlags(rawValue: 1 << 30)
  public static let streamFormatValid = StreamInfoFlags(rawValue: 1 << 31)
}

/// Milan's GET_STREAM_INFO extension flags, reported before Milan 1.3; a Milan 1.3 GET_STREAM_INFO
/// has the IEEE 1722.1-2021 layout (§5.4.2.10) and probing moved to GET_STREAM_INPUT_INFO_EX.
public struct StreamInfoFlagsEx: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let registering = StreamInfoFlagsEx(rawValue: 1 << 0)
}

// MARK: - Counters

// The counters_valid tables number bits MSB-first, as the rest of IEEE 1722.1 does: bit 31
// (the first counter) is the least-significant bit of the quadlet, and ENTITY_SPECIFIC_1 at
// bit 0 is the most-significant.

/// Valid-counter flags for ENTITY GET_COUNTERS (IEEE 1722.1-2021 §7.4.42).
public struct EntityCounterValidFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let entitySpecific1 = EntityCounterValidFlags(rawValue: 1 << 31)
  public static let entitySpecific2 = EntityCounterValidFlags(rawValue: 1 << 30)
  public static let entitySpecific3 = EntityCounterValidFlags(rawValue: 1 << 29)
  public static let entitySpecific4 = EntityCounterValidFlags(rawValue: 1 << 28)
  public static let entitySpecific5 = EntityCounterValidFlags(rawValue: 1 << 27)
  public static let entitySpecific6 = EntityCounterValidFlags(rawValue: 1 << 26)
  public static let entitySpecific7 = EntityCounterValidFlags(rawValue: 1 << 25)
  public static let entitySpecific8 = EntityCounterValidFlags(rawValue: 1 << 24)
}

/// Valid-counter flags for AVB_INTERFACE GET_COUNTERS (IEEE 1722.1-2021 §7.4.42.2.2).
public struct AvbInterfaceCounterValidFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let linkUp = AvbInterfaceCounterValidFlags(rawValue: 1 << 0)
  public static let linkDown = AvbInterfaceCounterValidFlags(rawValue: 1 << 1)
  public static let framesTx = AvbInterfaceCounterValidFlags(rawValue: 1 << 2)
  public static let framesRx = AvbInterfaceCounterValidFlags(rawValue: 1 << 3)
  public static let rxCrcError = AvbInterfaceCounterValidFlags(rawValue: 1 << 4)
  public static let gptpGmChanged = AvbInterfaceCounterValidFlags(rawValue: 1 << 5)
  public static let entitySpecific8 = AvbInterfaceCounterValidFlags(rawValue: 1 << 24)
  public static let entitySpecific7 = AvbInterfaceCounterValidFlags(rawValue: 1 << 25)
  public static let entitySpecific6 = AvbInterfaceCounterValidFlags(rawValue: 1 << 26)
  public static let entitySpecific5 = AvbInterfaceCounterValidFlags(rawValue: 1 << 27)
  public static let entitySpecific4 = AvbInterfaceCounterValidFlags(rawValue: 1 << 28)
  public static let entitySpecific3 = AvbInterfaceCounterValidFlags(rawValue: 1 << 29)
  public static let entitySpecific2 = AvbInterfaceCounterValidFlags(rawValue: 1 << 30)
  public static let entitySpecific1 = AvbInterfaceCounterValidFlags(rawValue: 1 << 31)
}

/// Valid-counter flags for CLOCK_DOMAIN GET_COUNTERS (IEEE 1722.1-2021 §7.4.42.2.3).
public struct ClockDomainCounterValidFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let locked = ClockDomainCounterValidFlags(rawValue: 1 << 0)
  public static let unlocked = ClockDomainCounterValidFlags(rawValue: 1 << 1)
  public static let entitySpecific8 = ClockDomainCounterValidFlags(rawValue: 1 << 24)
  public static let entitySpecific7 = ClockDomainCounterValidFlags(rawValue: 1 << 25)
  public static let entitySpecific6 = ClockDomainCounterValidFlags(rawValue: 1 << 26)
  public static let entitySpecific5 = ClockDomainCounterValidFlags(rawValue: 1 << 27)
  public static let entitySpecific4 = ClockDomainCounterValidFlags(rawValue: 1 << 28)
  public static let entitySpecific3 = ClockDomainCounterValidFlags(rawValue: 1 << 29)
  public static let entitySpecific2 = ClockDomainCounterValidFlags(rawValue: 1 << 30)
  public static let entitySpecific1 = ClockDomainCounterValidFlags(rawValue: 1 << 31)
}

/// Valid-counter flags for STREAM_INPUT GET_COUNTERS (IEEE 1722.1-2021 §7.4.42.2.4).
public struct StreamInputCounterValidFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let mediaLocked = StreamInputCounterValidFlags(rawValue: 1 << 0)
  public static let mediaUnlocked = StreamInputCounterValidFlags(rawValue: 1 << 1)
  public static let streamInterrupted = StreamInputCounterValidFlags(rawValue: 1 << 2)
  @available(*, deprecated, renamed: "streamInterrupted")
  public static let streamReset = streamInterrupted // IEEE 1722.1-2013 name
  public static let seqNumMismatch = StreamInputCounterValidFlags(rawValue: 1 << 3)
  public static let mediaReset = StreamInputCounterValidFlags(rawValue: 1 << 4)
  public static let timestampUncertain = StreamInputCounterValidFlags(rawValue: 1 << 5)
  public static let timestampValid = StreamInputCounterValidFlags(rawValue: 1 << 6)
  public static let timestampNotValid = StreamInputCounterValidFlags(rawValue: 1 << 7)
  public static let unsupportedFormat = StreamInputCounterValidFlags(rawValue: 1 << 8)
  public static let lateTimestamp = StreamInputCounterValidFlags(rawValue: 1 << 9)
  public static let earlyTimestamp = StreamInputCounterValidFlags(rawValue: 1 << 10)
  public static let framesRx = StreamInputCounterValidFlags(rawValue: 1 << 11)
  /// IEEE 1722.1-2013 only; reserved in IEEE 1722.1-2021, but still decoded by la_avdecc.
  public static let framesTx = StreamInputCounterValidFlags(rawValue: 1 << 12)
  public static let entitySpecific8 = StreamInputCounterValidFlags(rawValue: 1 << 24)
  public static let entitySpecific7 = StreamInputCounterValidFlags(rawValue: 1 << 25)
  public static let entitySpecific6 = StreamInputCounterValidFlags(rawValue: 1 << 26)
  public static let entitySpecific5 = StreamInputCounterValidFlags(rawValue: 1 << 27)
  public static let entitySpecific4 = StreamInputCounterValidFlags(rawValue: 1 << 28)
  public static let entitySpecific3 = StreamInputCounterValidFlags(rawValue: 1 << 29)
  public static let entitySpecific2 = StreamInputCounterValidFlags(rawValue: 1 << 30)
  public static let entitySpecific1 = StreamInputCounterValidFlags(rawValue: 1 << 31)
}

/// Valid-counter flags for STREAM_OUTPUT GET_COUNTERS (IEEE 1722.1-2021 §7.4.42.2.5), which
/// Milan 1.3 also uses.
///
/// Milan 1.2 §5.3.7.7 laid the counters out without STREAM_INTERRUPTED and the timestamp
/// validity counters; like la_avdecc, decode a Milan 1.2 entity's `counters_valid` with
/// `StreamOutputCounterValidFlagsMilan12` instead.
public struct StreamOutputCounterValidFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let streamStart = StreamOutputCounterValidFlags(rawValue: 1 << 0)
  public static let streamStop = StreamOutputCounterValidFlags(rawValue: 1 << 1)
  public static let streamInterrupted = StreamOutputCounterValidFlags(rawValue: 1 << 2)
  public static let mediaReset = StreamOutputCounterValidFlags(rawValue: 1 << 3)
  public static let timestampUncertain = StreamOutputCounterValidFlags(rawValue: 1 << 4)
  public static let timestampValid = StreamOutputCounterValidFlags(rawValue: 1 << 5)
  public static let timestampNotValid = StreamOutputCounterValidFlags(rawValue: 1 << 6)
  public static let framesTx = StreamOutputCounterValidFlags(rawValue: 1 << 7)
  /// Milan's signal presence on channels 0 to 31 and 32 to 59 (Milan 1.3 Table 5.14); see
  /// `DescriptorCounters.signalPresentChannels(valid:)`.
  public static let entitySpecific10 = StreamOutputCounterValidFlags(rawValue: 1 << 22)
  public static let entitySpecific9 = StreamOutputCounterValidFlags(rawValue: 1 << 23)
  public static let entitySpecific8 = StreamOutputCounterValidFlags(rawValue: 1 << 24)
  public static let entitySpecific7 = StreamOutputCounterValidFlags(rawValue: 1 << 25)
  public static let entitySpecific6 = StreamOutputCounterValidFlags(rawValue: 1 << 26)
  public static let entitySpecific5 = StreamOutputCounterValidFlags(rawValue: 1 << 27)
  public static let entitySpecific4 = StreamOutputCounterValidFlags(rawValue: 1 << 28)
  public static let entitySpecific3 = StreamOutputCounterValidFlags(rawValue: 1 << 29)
  public static let entitySpecific2 = StreamOutputCounterValidFlags(rawValue: 1 << 30)
  public static let entitySpecific1 = StreamOutputCounterValidFlags(rawValue: 1 << 31)
}

public extension DescriptorCounters {
  /// The STREAM_OUTPUT channels carrying an audio signal (Milan 1.3 §5.3.7.7.1): channel 0 is the
  /// most significant bit of ENTITY_SPECIFIC_9, and channels 32 to 59 follow in ENTITY_SPECIFIC_10.
  /// nil when neither counter is valid.
  func signalPresentChannels(valid: StreamOutputCounterValidFlags) -> [Int]? {
    let slots: [(flag: StreamOutputCounterValidFlags, firstChannel: Int, channels: Int)] = [
      (.entitySpecific9, 0, 32),
      (.entitySpecific10, 32, 28),
    ]
    var present: [Int]?
    for slot in slots where valid.contains(slot.flag) {
      // a counter is at the index of its valid flag's bit (IEEE 1722.1-2021 §7.4.42.2)
      let bits = self[slot.flag.rawValue.trailingZeroBitCount]
      present = (present ?? []) + (0..<slot.channels).filter { bits & (0x8000_0000 >> UInt32($0)) != 0 }
        .map { slot.firstChannel + $0 }
    }
    return present
  }
}

/// Valid-counter flags for STREAM_OUTPUT GET_COUNTERS from a Milan 1.2 entity
/// (Milan 1.2 §5.3.7.7).
public struct StreamOutputCounterValidFlagsMilan12: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let streamStart = StreamOutputCounterValidFlagsMilan12(rawValue: 1 << 0)
  public static let streamStop = StreamOutputCounterValidFlagsMilan12(rawValue: 1 << 1)
  public static let mediaReset = StreamOutputCounterValidFlagsMilan12(rawValue: 1 << 2)
  public static let timestampUncertain = StreamOutputCounterValidFlagsMilan12(rawValue: 1 << 3)
  public static let framesTx = StreamOutputCounterValidFlagsMilan12(rawValue: 1 << 4)
}

/// Valid-counter flags for PTP_PORT GET_COUNTERS (IEEE 1722.1-2021 Table 7-160).
public struct PtpPortCounterValidFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let rxSync = PtpPortCounterValidFlags(rawValue: 1 << 0)
  public static let rxOneStepSync = PtpPortCounterValidFlags(rawValue: 1 << 1)
  public static let rxFollowUp = PtpPortCounterValidFlags(rawValue: 1 << 2)
  public static let rxPdelayRequest = PtpPortCounterValidFlags(rawValue: 1 << 3)
  public static let rxPdelayResponse = PtpPortCounterValidFlags(rawValue: 1 << 4)
  public static let rxPdelayResponseFollowUp = PtpPortCounterValidFlags(rawValue: 1 << 5)
  public static let rxAnnounce = PtpPortCounterValidFlags(rawValue: 1 << 6)
  public static let rxSignal = PtpPortCounterValidFlags(rawValue: 1 << 7)
  public static let rxPacketDiscard = PtpPortCounterValidFlags(rawValue: 1 << 8)
  public static let rxDelayRequest = PtpPortCounterValidFlags(rawValue: 1 << 9)
  public static let rxDelayResponse = PtpPortCounterValidFlags(rawValue: 1 << 10)
  public static let syncReceiptTimeout = PtpPortCounterValidFlags(rawValue: 1 << 11)
  public static let announceReceiptTimeout = PtpPortCounterValidFlags(rawValue: 1 << 12)
  public static let pdelayAllowedExceeded = PtpPortCounterValidFlags(rawValue: 1 << 13)
  public static let txSync = PtpPortCounterValidFlags(rawValue: 1 << 14)
  public static let txOneStepSync = PtpPortCounterValidFlags(rawValue: 1 << 15)
  public static let txFollowUp = PtpPortCounterValidFlags(rawValue: 1 << 16)
  public static let txPdelayRequest = PtpPortCounterValidFlags(rawValue: 1 << 17)
  public static let txPdelayResponse = PtpPortCounterValidFlags(rawValue: 1 << 18)
  public static let txPdelayResponseFollowUp = PtpPortCounterValidFlags(rawValue: 1 << 19)
  public static let txAnnounce = PtpPortCounterValidFlags(rawValue: 1 << 20)
  public static let txSignal = PtpPortCounterValidFlags(rawValue: 1 << 21)
  public static let txDelayRequest = PtpPortCounterValidFlags(rawValue: 1 << 22)
  public static let txDelayResponse = PtpPortCounterValidFlags(rawValue: 1 << 23)
  public static let entitySpecific8 = PtpPortCounterValidFlags(rawValue: 1 << 24)
  public static let entitySpecific7 = PtpPortCounterValidFlags(rawValue: 1 << 25)
  public static let entitySpecific6 = PtpPortCounterValidFlags(rawValue: 1 << 26)
  public static let entitySpecific5 = PtpPortCounterValidFlags(rawValue: 1 << 27)
  public static let entitySpecific4 = PtpPortCounterValidFlags(rawValue: 1 << 28)
  public static let entitySpecific3 = PtpPortCounterValidFlags(rawValue: 1 << 29)
  public static let entitySpecific2 = PtpPortCounterValidFlags(rawValue: 1 << 30)
  public static let entitySpecific1 = PtpPortCounterValidFlags(rawValue: 1 << 31)
}

// MARK: - Milan

/// Milan protocol features (Milan 1.3 §5.4.4.1, MILAN_INFO features_flags).
public struct MilanInfoFeaturesFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let redundancy = MilanInfoFeaturesFlags(rawValue: 1 << 0)
  public static let talkerDynamicMappingsWhileRunning = MilanInfoFeaturesFlags(rawValue: 1 << 1)
  /// BIND_STREAM and UNBIND_STREAM are supported (Milan 1.3 Table 5.17).
  public static let mvuBinding = MilanInfoFeaturesFlags(rawValue: 1 << 2)
  public static let talkerSignalPresence = MilanInfoFeaturesFlags(rawValue: 1 << 3)
}

/// BIND_STREAM flags (Milan 1.3 §5.4.4.6).
public struct BindStreamFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  /// Binds the listener's STREAM_INPUT in the stopped state (Milan 1.3 Table 5.19).
  public static let streamingWait = BindStreamFlags(rawValue: 1 << 0)
}

/// SET/GET_MEDIA_CLOCK_REFERENCE_INFO flags (Milan 1.3 §5.4.4.4).
public struct MediaClockReferenceInfoFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let userMediaClockReferencePriorityValid =
    MediaClockReferenceInfoFlags(rawValue: 1 << 0)
  public static let mediaClockDomainNameValid = MediaClockReferenceInfoFlags(rawValue: 1 << 1)
}
