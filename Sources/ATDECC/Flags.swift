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
  /// Milan 1.3 name for bit 6.
  public static let registeringFailed = StreamInfoFlags(rawValue: 1 << 6)
  public static let noSrp = StreamInfoFlags(rawValue: 1 << 8)
  public static let ipFlagsValid = StreamInfoFlags(rawValue: 1 << 19)
  public static let ipSrcPortValid = StreamInfoFlags(rawValue: 1 << 20)
  public static let ipDstPortValid = StreamInfoFlags(rawValue: 1 << 21)
  public static let streamVlanIDValid = StreamInfoFlags(rawValue: 1 << 25)
  public static let connected = StreamInfoFlags(rawValue: 1 << 26)
  public static let msrpFailureValid = StreamInfoFlags(rawValue: 1 << 27)
  public static let streamDestMacValid = StreamInfoFlags(rawValue: 1 << 28)
  public static let msrpAccLatValid = StreamInfoFlags(rawValue: 1 << 29)
  public static let streamIDValid = StreamInfoFlags(rawValue: 1 << 30)
  public static let streamFormatValid = StreamInfoFlags(rawValue: 1 << 31)
}

/// Milan extended GET_STREAM_INFO flags (Milan 1.3 §5.4.2.9).
public struct StreamInfoFlagsEx: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let registering = StreamInfoFlagsEx(rawValue: 1 << 0)
}

// MARK: - Counters

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

/// Valid-counter flags for AVB_INTERFACE GET_COUNTERS.
public struct AvbInterfaceCounterValidFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let linkUp = AvbInterfaceCounterValidFlags(rawValue: 1 << 31)
  public static let linkDown = AvbInterfaceCounterValidFlags(rawValue: 1 << 30)
  public static let framesTx = AvbInterfaceCounterValidFlags(rawValue: 1 << 29)
  public static let framesRx = AvbInterfaceCounterValidFlags(rawValue: 1 << 28)
  public static let rxCrcError = AvbInterfaceCounterValidFlags(rawValue: 1 << 27)
  public static let gptpGmChanged = AvbInterfaceCounterValidFlags(rawValue: 1 << 26)
}

/// Valid-counter flags for CLOCK_DOMAIN GET_COUNTERS.
public struct ClockDomainCounterValidFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let locked = ClockDomainCounterValidFlags(rawValue: 1 << 31)
  public static let unlocked = ClockDomainCounterValidFlags(rawValue: 1 << 30)
}

/// Valid-counter flags for STREAM_INPUT GET_COUNTERS.
public struct StreamInputCounterValidFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let mediaLocked = StreamInputCounterValidFlags(rawValue: 1 << 31)
  public static let mediaUnlocked = StreamInputCounterValidFlags(rawValue: 1 << 30)
  public static let streamReset = StreamInputCounterValidFlags(rawValue: 1 << 29)
  public static let seqNumMismatch = StreamInputCounterValidFlags(rawValue: 1 << 28)
  public static let mediaReset = StreamInputCounterValidFlags(rawValue: 1 << 27)
  public static let timestampUncertain = StreamInputCounterValidFlags(rawValue: 1 << 26)
  public static let timestampValid = StreamInputCounterValidFlags(rawValue: 1 << 25)
  public static let timestampNotValid = StreamInputCounterValidFlags(rawValue: 1 << 24)
  public static let unsupportedFormat = StreamInputCounterValidFlags(rawValue: 1 << 23)
  public static let lateTimestamp = StreamInputCounterValidFlags(rawValue: 1 << 22)
  public static let earlyTimestamp = StreamInputCounterValidFlags(rawValue: 1 << 21)
  public static let framesRx = StreamInputCounterValidFlags(rawValue: 1 << 20)
  public static let framesTx = StreamInputCounterValidFlags(rawValue: 1 << 19)
}

/// Valid-counter flags for STREAM_OUTPUT GET_COUNTERS (Milan extension; the stock 1722.1
/// layout has no descriptor-counter assignments).
public struct StreamOutputCounterValidFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let streamStart = StreamOutputCounterValidFlags(rawValue: 1 << 31)
  public static let streamStop = StreamOutputCounterValidFlags(rawValue: 1 << 30)
  public static let mediaReset = StreamOutputCounterValidFlags(rawValue: 1 << 29)
  public static let timestampUncertain = StreamOutputCounterValidFlags(rawValue: 1 << 28)
  public static let framesTx = StreamOutputCounterValidFlags(rawValue: 1 << 27)
}

// MARK: - Milan

/// Milan protocol features (Milan 1.3 §5.4.4.1, MILAN_INFO features_flags).
public struct MilanInfoFeaturesFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let redundancy = MilanInfoFeaturesFlags(rawValue: 1 << 0)
  public static let talkerDynamicMappingsWhileRunning = MilanInfoFeaturesFlags(rawValue: 1 << 1)
  /// BIND_STREAM / UNBIND_STREAM / GET_STREAM_INPUT_INFO_EX are supported (Milan 1.3).
  public static let mvuBinding = MilanInfoFeaturesFlags(rawValue: 1 << 2)
  public static let talkerSignalPresence = MilanInfoFeaturesFlags(rawValue: 1 << 3)
}

/// BIND_STREAM flags (Milan 1.3 §5.4.4.6).
public struct BindStreamFlags: OptionSet, Sendable, Hashable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  /// Talker holds off streaming until told otherwise via control protocol.
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
