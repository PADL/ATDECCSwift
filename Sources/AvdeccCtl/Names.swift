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

import ATDECC
import IEEE802

// The names IEEE 1722.1-2021 gives statuses, flags and counters, for printing.

/// `camelCase` as `CAMEL_CASE`, as the standard spells status and flag names.
func upperSnakeCase(_ name: String) -> String {
  let characters = Array(name)
  var result = ""
  for (index, character) in characters.enumerated() {
    if index > 0, character.isUppercase {
      let previous = characters[index - 1]
      let next = index + 1 < characters.count ? characters[index + 1] : nil
      if previous.isLowercase || previous
        .isNumber || (previous.isUppercase && next?.isLowercase == true)
      {
        result.append("_")
      }
    }
    result.append(contentsOf: character.uppercased())
  }
  return result
}

/// The name of an AEM, ACMP or MVU status, such as `ACQUIRED_BY_OTHER`.
func statusName(_ status: some Error) -> String {
  upperSnakeCase(String(describing: status))
}

/// The names of the bits set in `rawValue`, indexed by bit number; unnamed bits are given in
/// hex.
func flagNames(_ rawValue: some FixedWidthInteger, _ names: [Int: String]) -> [String] {
  var result = [String]()
  var unnamed = UInt64(0)
  for bit in 0..<rawValue.bitWidth where rawValue & (1 << bit) != 0 {
    if let name = names[bit] { result.append(name) } else { unnamed |= 1 << UInt64(bit) }
  }
  if unnamed != 0 { result.append("0x" + String(unnamed, radix: 16)) }
  return result
}

let entityCapabilityNames: [Int: String] = [
  0: "EFU_MODE", 1: "ADDRESS_ACCESS_SUPPORTED", 2: "GATEWAY_ENTITY", 3: "AEM_SUPPORTED",
  4: "LEGACY_AVC", 5: "ASSOCIATION_ID_SUPPORTED", 6: "ASSOCIATION_ID_VALID",
  7: "VENDOR_UNIQUE_SUPPORTED", 8: "CLASS_A_SUPPORTED", 9: "CLASS_B_SUPPORTED",
  10: "GPTP_SUPPORTED", 11: "AEM_AUTHENTICATION_SUPPORTED", 12: "AEM_AUTHENTICATION_REQUIRED",
  13: "AEM_PERSISTENT_ACQUIRE_SUPPORTED", 14: "AEM_IDENTIFY_CONTROL_INDEX_VALID",
  15: "AEM_INTERFACE_INDEX_VALID", 16: "GENERAL_CONTROLLER_IGNORE", 17: "ENTITY_NOT_READY",
  18: "ACMP_ACQUIRE_WITH_AEM", 19: "ACMP_AUTHENTICATE_WITH_AEM", 20: "SUPPORTS_UDPV4_ATDECC",
  21: "SUPPORTS_UDPV4_STREAMING", 22: "SUPPORTS_UDPV6_ATDECC", 23: "SUPPORTS_UDPV6_STREAMING",
  24: "MULTIPLE_PTP_INSTANCES", 25: "AEM_CONFIGURATION_INDEX_VALID",
]

let talkerCapabilityNames: [Int: String] = [
  0: "IMPLEMENTED", 9: "OTHER_SOURCE", 10: "CONTROL_SOURCE", 11: "MEDIA_CLOCK_SOURCE",
  12: "SMPTE_SOURCE", 13: "MIDI_SOURCE", 14: "AUDIO_SOURCE", 15: "VIDEO_SOURCE",
]

let listenerCapabilityNames: [Int: String] = [
  0: "IMPLEMENTED", 9: "OTHER_SINK", 10: "CONTROL_SINK", 11: "MEDIA_CLOCK_SINK",
  12: "SMPTE_SINK", 13: "MIDI_SINK", 14: "AUDIO_SINK", 15: "VIDEO_SINK",
]

let connectionFlagNames: [Int: String] = [
  0: "CLASS_B", 1: "FAST_CONNECT", 2: "SAVED_STATE", 3: "STREAMING_WAIT",
  4: "SUPPORTS_ENCRYPTED", 5: "ENCRYPTED_PDU", 6: "SRP_REGISTRATION_FAILED",
  7: "CL_ENTRIES_VALID", 8: "NO_SRP", 9: "UDP",
]

let streamInfoFlagNames: [Int: String] = [
  0: "CLASS_B", 1: "FAST_CONNECT", 2: "SAVED_STATE", 3: "STREAMING_WAIT",
  4: "SUPPORTS_ENCRYPTED", 5: "ENCRYPTED_PDU", 6: "SRP_REGISTRATION_FAILED", 8: "NO_SRP",
  19: "IP_FLAGS_VALID", 20: "IP_SRC_PORT_VALID", 21: "IP_DST_PORT_VALID",
  22: "IP_SRC_ADDR_VALID", 23: "IP_DST_ADDR_VALID", 24: "NOT_REGISTERING_SRP",
  25: "STREAM_VLAN_ID_VALID", 26: "CONNECTED", 27: "MSRP_FAILURE_VALID",
  28: "STREAM_DEST_MAC_VALID", 29: "MSRP_ACC_LAT_VALID", 30: "STREAM_ID_VALID",
  31: "STREAM_FORMAT_VALID",
]

let streamFlagNames: [Int: String] = [
  0: "CLOCK_SYNC_SOURCE", 1: "CLASS_A", 2: "CLASS_B", 3: "SUPPORTS_ENCRYPTED",
  4: "PRIMARY_BACKUP_SUPPORTED", 5: "PRIMARY_BACKUP_VALID", 6: "SECONDARY_BACKUP_SUPPORTED",
  7: "SECONDARY_BACKUP_VALID", 8: "TERTIARY_BACKUP_SUPPORTED", 9: "TERTIARY_BACKUP_VALID",
  10: "SUPPORTS_AVTP_UDP_V4", 11: "SUPPORTS_AVTP_UDP_V6", 12: "NO_SUPPORT_AVTP_NATIVE",
  13: "TIMING_FIELD_VALID", 14: "NO_MEDIA_CLOCK", 15: "SUPPORTS_NO_SRP",
]

let avbInterfaceFlagNames: [Int: String] = [
  0: "GPTP_GRANDMASTER_SUPPORTED", 1: "GPTP_SUPPORTED", 2: "SRP_SUPPORTED",
  3: "FQTSS_NOT_SUPPORTED", 4: "SCHEDULED_TRAFFIC_SUPPORTED", 5: "CAN_LISTEN_TO_SELF",
  6: "CAN_LISTEN_TO_OTHER_SELF",
]

let clockSourceFlagNames: [Int: String] = [0: "STREAM_ID", 1: "LOCAL_ID"]

/// The counters of `descriptorType` by index, which is the bit number of its counters_valid
/// flag (IEEE 1722.1-2021 §7.4.42.2); the last eight are ENTITY_SPECIFIC_8 down to _1.
func counterNames(_ descriptorType: DescriptorType) -> [Int: String] {
  var names = [Int: String]()
  for index in 24..<32 {
    names[index] = "ENTITY_SPECIFIC_\(32 - index)"
  }
  let specific: [String] = switch descriptorType {
  case .avbInterface:
    ["LINK_UP", "LINK_DOWN", "FRAMES_TX", "FRAMES_RX", "RX_CRC_ERROR", "GPTP_GM_CHANGED"]
  case .clockDomain:
    ["LOCKED", "UNLOCKED"]
  case .streamInput:
    [
      "MEDIA_LOCKED", "MEDIA_UNLOCKED", "STREAM_INTERRUPTED", "SEQ_NUM_MISMATCH", "MEDIA_RESET",
      "TIMESTAMP_UNCERTAIN", "TIMESTAMP_VALID", "TIMESTAMP_NOT_VALID", "UNSUPPORTED_FORMAT",
      "LATE_TIMESTAMP", "EARLY_TIMESTAMP", "FRAMES_RX", "FRAMES_TX",
    ]
  case .streamOutput:
    [
      "STREAM_START", "STREAM_STOP", "STREAM_INTERRUPTED", "MEDIA_RESET", "TIMESTAMP_UNCERTAIN",
      "TIMESTAMP_VALID", "TIMESTAMP_NOT_VALID", "FRAMES_TX",
    ]
  case .ptpPort:
    [
      "RX_SYNC", "RX_ONE_STEP_SYNC", "RX_FOLLOW_UP", "RX_PDELAY_REQUEST", "RX_PDELAY_RESPONSE",
      "RX_PDELAY_RESPONSE_FOLLOW_UP", "RX_ANNOUNCE", "RX_SIGNAL", "RX_PACKET_DISCARD",
      "RX_DELAY_REQUEST", "RX_DELAY_RESPONSE", "SYNC_RECEIPT_TIMEOUT", "ANNOUNCE_RECEIPT_TIMEOUT",
      "PDELAY_ALLOWED_EXCEEDED", "TX_SYNC", "TX_ONE_STEP_SYNC", "TX_FOLLOW_UP",
      "TX_PDELAY_REQUEST", "TX_PDELAY_RESPONSE", "TX_PDELAY_RESPONSE_FOLLOW_UP", "TX_ANNOUNCE",
      "TX_SIGNAL", "TX_DELAY_REQUEST", "TX_DELAY_RESPONSE",
    ]
  default:
    []
  }
  for (index, name) in specific.enumerated() {
    names[index] = name
  }
  return names
}

/// A descriptor type's name as Table 7-1 spells it, such as `STREAM_INPUT`.
func descriptorTypeName(_ descriptorType: DescriptorType) -> String {
  let name = descriptorType.description
  return name.hasPrefix("0x") ? name : upperSnakeCase(name)
}

/// Lowercase hex, zero-padded to `width` digits, with a `0x` prefix.
func hex(_ value: some BinaryInteger, width: Int) -> String {
  let digits = String(value, radix: 16)
  return "0x" + String(repeating: "0", count: max(width - digits.count, 0)) + digits
}

func hex(_ id: UniqueIdentifier) -> String {
  hex(id.rawValue, width: 16)
}

/// A MAC address as six colon-separated hex octets.
func macAddressString(_ address: EUI48) -> String {
  (0..<6).map { index in
    let digits = String(address[index], radix: 16)
    return digits.count == 1 ? "0" + digits : digits
  }.joined(separator: ":")
}

let avbInfoFlagNames: [Int: String] = [
  0: "AS_CAPABLE", 1: "GPTP_ENABLED", 2: "SRP_ENABLED", 3: "AVTP_DOWN", 4: "AVTP_DOWN_VALID",
]
