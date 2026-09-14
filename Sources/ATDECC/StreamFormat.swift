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

public struct StreamFormat: CustomStringConvertible, Equatable, Hashable, Sendable {
  var _format: UInt64

  public enum AvtpVersion: UInt8, Equatable, Sendable {
    case version_0 = 0
  }

  public enum AvtpSubtype: UInt8, Equatable, Sendable {
    case iec61883iidc = 0x00
    case mmaStream = 0x01
    case aaf = 0x02
    case cvf = 0x03
    case crf = 0x04
    case tscf = 0x05
    case svc = 0x06
    case rvf = 0x07
  }

  // 61883-6

  enum iec_61883_sf: UInt8, Equatable, Sendable {
    case iidc = 0
    case iec61883 = 1
  }

  enum iec_61883_cip: UInt8, Equatable, Sendable {
    case fmt_4 = 0x20
    case fmt_6 = 0x10
    case fmt_8 = 0x01
  }

  enum iec_61883_6_fdf_evt: UInt8, Equatable, Sendable {
    case am824 = 0x00
    case packed = 0x02
    case floating = 0x04
    case int32 = 0x06
  }

  enum iec_61883_6_fdf_sfc: UInt8, Equatable, Sendable {
    case fs32000 = 0x00
    case fs44100 = 0x01
    case fs48000 = 0x02
    case fs88200 = 0x03
    case fs96000 = 0x04
    case fs176400 = 0x05
    case fs192000 = 0x06
    case reserved = 0x07

    var sampleRate: Int? {
      switch self {
      case .fs32000: 32000
      case .fs44100: 44100
      case .fs48000: 48000
      case .fs88200: 88200
      case .fs96000: 96000
      case .fs176400: 176_400
      case .fs192000: 192_000
      default: nil
      }
    }
  }

  private var iec61883_sf_fmt_r: UInt8 {
    UInt8((_format >> 48) & 0xFF)
  }

  private var iec61883_sf: iec_61883_sf? {
    iec_61883_sf(rawValue: (iec61883_sf_fmt_r & 0x80) >> 7)
  }

  private var iec61883_fmt: iec_61883_cip? {
    iec_61883_cip(rawValue: (iec61883_sf_fmt_r & 0x7E) >> 1)
  }

  private var iec61883_r: Bool {
    iec61883_sf_fmt_r & 0x01 != 0
  }

  private var iec61883_6_fdf: UInt8 {
    UInt8((_format >> 40) & 0xFF)
  }

  // fdf_evt is the most-significant 5 bits of FDF, fdf_sfc the least-significant 3
  // (IEEE 1722-2016 §I.2.2.3.3)
  private var iec61883_6_fdf_evt: iec_61883_6_fdf_evt? {
    iec_61883_6_fdf_evt(rawValue: iec61883_6_fdf >> 3)
  }

  private var iec61883_6_fdf_sfc: iec_61883_6_fdf_sfc? {
    iec_61883_6_fdf_sfc(rawValue: iec61883_6_fdf & 0x07)
  }

  private var iec61883_6_dbs: UInt8 {
    UInt8((_format >> 32) & 0xFF)
  }

  private var iec61883_6_b_nb_ut_sc_rsvd: UInt8 {
    UInt8((_format >> 24) & 0xFF)
  }

  private var iec61883_6_iec_60958_cnt: UInt8 {
    UInt8((_format >> 16) & 0xFF)
  }

  private var iec61883_6_label_mbla_cnt: UInt8 {
    UInt8((_format >> 8) & 0xFF)
  }

  private var iec61883_isFloatingPoint: Bool {
    guard iec61883_sf == .iec61883, iec61883_fmt == .fmt_6 else { return false }
    return iec61883_6_fdf_evt == .floating
  }

  public var iec61883_sampleRate: Int? {
    guard iec61883_sf == .iec61883, iec61883_fmt == .fmt_6,
          let iec61883_6_fdf_sfc else { return nil }
    return iec61883_6_fdf_sfc.sampleRate
  }

  public var iec61883_channelsPerFrame: Int? {
    guard iec61883_sf == .iec61883, iec61883_fmt == .fmt_6,
          let iec61883_6_fdf_evt else { return nil }
    switch iec61883_6_fdf_evt {
    case .am824:
      return Int(iec61883_6_label_mbla_cnt)
    case .floating:
      fallthrough
    case .int32:
      return Int(iec61883_6_dbs)
    default:
      return nil
    }
  }

  public var iec61883_bitDepth: Int? {
    guard iec61883_sf == .iec61883, iec61883_fmt == .fmt_6,
          let iec61883_6_fdf_evt else { return nil }
    switch iec61883_6_fdf_evt {
    case .am824:
      return 24
    default:
      return 32
    }
  }

  public var iec61883_samplesPerFrame: Int? {
    // TODO: implement
    nil
  }

  // AAF

  public enum AafFormat: UInt8, Equatable, Sendable {
    case user = 0
    case float32Bit = 1
    case int32Bit = 2
    case int24Bit = 3
    case int16Bit = 4
    case aes3_32Bit = 5

    public var bitDepth: Int? {
      switch self {
      case .float32Bit: 32
      case .int32Bit: 32
      case .int24Bit: 24
      case .int16Bit: 16
      default: nil
      }
    }
  }

  private var aafFormat: AafFormat? {
    AafFormat(rawValue: UInt8((_format >> 40) & 0xFF))
  }

  private var aafBitDepth: Int {
    Int(UInt8((_format >> 32) & 0xFF))
  }

  private var aafIsFloatingPoint: Bool {
    aafFormat == .float32Bit
  }

  private var aafIsAES3Format: Bool {
    aafFormat == .aes3_32Bit
  }

  public enum AafNominalSampleRate: UInt8, Equatable, Sendable {
    case userSpecified = 0
    case fs8000 = 1
    case fs16000 = 2
    case fs32000 = 3
    case fs44100 = 4
    case fs48000 = 5
    case fs88200 = 6
    case fs96000 = 7
    case fs176400 = 8
    case fs192000 = 9
    case fs24000 = 10
    case reserved1 = 11
    case reserved2 = 12
    case reserved3 = 13
    case reserved4 = 14
    case reserved5 = 15

    public var sampleRate: Int? {
      switch self {
      case .fs8000: 8000
      case .fs16000: 16000
      case .fs32000: 32000
      case .fs44100: 44100
      case .fs48000: 48000
      case .fs88200: 88200
      case .fs96000: 96000
      case .fs176400: 176_400
      case .fs192000: 192_000
      case .fs24000: 24000
      default: nil
      }
    }
  }

  private var aafNominalSampleRate: AafNominalSampleRate? {
    AafNominalSampleRate(rawValue: UInt8((_format >> 48) & 0xF))
  }

  private var aafChannelsPerFrame: Int? {
    // TODO: support AES3
    guard !aafIsAES3Format else { return nil }
    return Int(_format >> 22 & 0x3FF)
  }

  private var aafSamplesPerFrame: Int? {
    // TODO: support AES3
    guard !aafIsAES3Format else { return nil }
    return Int(_format >> 12 & 0x3FF)
  }

  // AVTP common

  public var version: AvtpVersion? {
    AvtpVersion(rawValue: UInt8((_format >> 63) & 0x1))
  }

  public var subtype: AvtpSubtype? {
    AvtpSubtype(rawValue: UInt8((_format >> 56) & 0x7F))
  }

  public var sampleRate: Int? {
    switch subtype {
    case .iec61883iidc:
      return iec61883_sampleRate
    case .aaf:
      guard let nsr = aafNominalSampleRate else {
        return nil
      }
      return nsr.sampleRate
    default:
      return nil
    }
  }

  public var channelsPerFrame: Int? {
    switch subtype {
    case .iec61883iidc:
      iec61883_channelsPerFrame
    case .aaf:
      aafChannelsPerFrame
    default:
      nil
    }
  }

  public var bitDepth: Int? {
    switch subtype {
    case .iec61883iidc:
      return iec61883_bitDepth
    case .aaf:
      guard let format = aafFormat, let formatBitDepth = format.bitDepth else {
        return nil
      }
      return formatBitDepth > aafBitDepth ? aafBitDepth : formatBitDepth
    default:
      return nil
    }
  }

  public var samplesPerFrame: Int? {
    switch subtype {
    case .iec61883iidc:
      iec61883_samplesPerFrame
    case .aaf:
      aafSamplesPerFrame
    default:
      nil
    }
  }

  public var isFloatingPoint: Bool {
    switch subtype {
    case .iec61883iidc:
      iec61883_isFloatingPoint
    case .aaf:
      aafIsFloatingPoint
    default:
      false
    }
  }

  public var format: UInt64 {
    _format
  }

  public var formatBytes: [UInt8] {
    withUnsafeBytes(of: format.bigEndian, Array.init)
  }

  public init() {
    _format = 0
  }

  public init(format: UInt64) {
    _format = format
  }

  public var description: String { _format.paddedHex(width: 16) }
}
