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

// Stream formats as comma-separated specs, such as `aaf,48k,int32/24,8ch,6spf`,
// `crf,48k` or `iec61883-6,48k,8ch`; `streamFormatSpec` and `parseStreamFormat` are inverses.

/// A sample rate as a spec token: `48k`, `44.1k`, or hertz when neither fits.
func sampleRateToken(_ rate: Int) -> String {
  if rate % 1000 == 0 { return "\(rate / 1000)k" }
  if rate % 100 == 0 { return "\(rate / 1000).\(rate % 1000 / 100)k" }
  return "\(rate)"
}

/// Parses `48k`, `44.1k` or `48000` as hertz.
func parseSampleRate(_ token: String) -> Int? {
  guard token.hasSuffix("k") else { return Int(token).flatMap { $0 > 0 ? $0 : nil } }
  guard let kilohertz = Double(token.dropLast()), kilohertz > 0, kilohertz < 1_000_000 else {
    return nil
  }
  return Int((kilohertz * 1000).rounded())
}

private let aafFormatTokens: [(StreamFormat.AafFormat, String)] = [
  (.user, "user"), (.float32Bit, "float32"), (.int32Bit, "int32"), (.int24Bit, "int24"),
  (.int16Bit, "int16"), (.aes3_32Bit, "aes3"),
]

private let iec61883EventTokens: [UInt8: String] = [
  0x00: "am824",
  0x02: "packed",
  0x04: "float32",
  0x06: "int32",
]

/// `format` as a spec, or nil if it is not one a spec can describe.
func streamFormatSpec(_ format: StreamFormat) -> String? {
  let value = format.format
  guard value >> 63 == 0 else { return nil }
  switch format.subtype {
  case .aaf:
    let nsr = StreamFormat.AafNominalSampleRate(rawValue: UInt8((value >> 48) & 0xF))
    guard let rate = nsr?.sampleRate,
          let aafFormat = StreamFormat.AafFormat(rawValue: UInt8((value >> 40) & 0xFF)),
          let token = aafFormatTokens.first(where: { $0.0 == aafFormat })?.1
    else { return nil }
    let depth = Int((value >> 32) & 0xFF)
    let channels = Int((value >> 22) & 0x3FF)
    let samples = Int((value >> 12) & 0x3FF)
    let depthSuffix = depth == (aafFormat.bitDepth ?? 32) ? "" : "/\(depth)"
    return "aaf,\(sampleRateToken(rate)),\(token)\(depthSuffix),\(channels)ch,\(samples)spf" +
      (format.isUpToChannelsCount ? ",ut" : "")
  case .crf:
    guard let type = format.crfType, let interval = format.crfTimestampInterval,
          let perPdu = format.crfTimestampsPerPdu, let pull = format.crfPull,
          let baseFrequency = format.crfBaseFrequency, baseFrequency > 0
    else { return nil }
    var spec = "crf,\(sampleRateToken(Int(baseFrequency)))"
    if type != 1 { spec += ",type=\(type)" }
    if interval != 96 { spec += ",interval=\(interval)" }
    if perPdu != 1 { spec += ",tpp=\(perPdu)" }
    if pull != 0 { spec += ",pull=\(pull)" }
    return spec
  case .iec61883iidc:
    // sf = 1 and fmt = 0x10 (IEC 61883-6)
    guard (value >> 48) & 0xFE == 0xA0, let rate = format.iec61883_sampleRate,
          let event = iec61883EventTokens[UInt8((value >> 43) & 0x1F)],
          let channels = format.channelsPerFrame
    else { return nil }
    return "iec61883-6,\(sampleRateToken(rate)),\(event == "am824" ? "" : event + ",")\(channels)ch" +
      (format.isUpToChannelsCount ? ",ut" : "")
  default:
    return nil
  }
}

/// `format` in hex, followed by its spec when it has one.
func streamFormatDescription(_ format: StreamFormat) -> String {
  let value = hex(format.format, width: 16)
  return streamFormatSpec(format).map { "\(value) (\($0))" } ?? value
}

/// Parses a stream format given in hex (`0x` and up to 16 digits, or exactly 16 digits) or as
/// a spec.
func parseStreamFormat(_ text: String) throws(UsageError) -> StreamFormat {
  if let value = parseHex64(text) {
    return StreamFormat(format: value)
  }
  let tokens = text.lowercased().split(separator: ",", omittingEmptySubsequences: false)
    .map(String.init)
  guard let subtype = tokens.first else { throw UsageError("empty stream format") }
  var rate: Int?
  var channels: Int?
  var samples: Int?
  var aafFormat: StreamFormat.AafFormat?
  var depth: Int?
  var isUpToChannelsCount = false
  var keyed = [String: Int]()
  for token in tokens.dropFirst() {
    if token == "ut" {
      isUpToChannelsCount = true
    } else if token.hasSuffix("spf"), let value = Int(token.dropLast(3)) {
      samples = value
    } else if token.hasSuffix("ch"), let value = Int(token.dropLast(2)) {
      channels = value
    } else if let equals = token.firstIndex(of: "="),
              let value = Int(token[token.index(after: equals)...])
    {
      keyed[String(token[..<equals])] = value
    } else if let parsed = parseAafFormatToken(token) {
      aafFormat = parsed.0
      depth = parsed.1
    } else if token == "am824" {
      continue
    } else if let value = parseSampleRate(token) {
      rate = value
    } else {
      throw UsageError("unknown token '\(token)' in stream format '\(text)'")
    }
  }

  switch subtype {
  case "aaf":
    guard let rate, let channels, let aafFormat else {
      throw UsageError(
        "an AAF format needs a rate, a sample format and a channel count, as in aaf,48k,int32/24,8ch,6spf"
      )
    }
    guard let nsr = (1...10).lazy
      .compactMap({ StreamFormat.AafNominalSampleRate(rawValue: UInt8($0)) })
      .first(where: { $0.sampleRate == rate })
    else { throw UsageError("AAF has no nominal sample rate of \(rate) Hz") }
    guard keyed.isEmpty
    else { throw UsageError("unknown AAF parameter '\(keyed.keys.sorted()[0])'") }
    // one class A observation interval of 125 µs by default
    let samplesPerFrame = samples ?? max(rate / 8000, 1)
    guard (1...1023).contains(channels), (1...1023).contains(samplesPerFrame),
          (depth ?? 0) <= 255
    else {
      throw UsageError("channel count, samples per frame or bit depth out of range in '\(text)'")
    }
    return .aaf(
      sampleRate: nsr,
      format: aafFormat,
      bitDepth: depth,
      channelsPerFrame: channels,
      samplesPerFrame: samplesPerFrame,
      isUpToChannelsCount: isUpToChannelsCount
    )
  case "crf":
    guard let rate else { throw UsageError("a CRF format needs a base frequency, as in crf,48k") }
    let known = ["type": 0xF, "interval": 0xFFF, "tpp": 0xFF, "pull": 0x7]
    for (key, value) in keyed {
      guard let maximum = known[key] else { throw UsageError("unknown CRF parameter '\(key)'") }
      guard (0...maximum).contains(value) else { throw UsageError("CRF \(key) out of range") }
    }
    guard channels == nil, samples == nil, aafFormat == nil, !isUpToChannelsCount,
          rate <= 0x1FFF_FFFF
    else {
      throw UsageError("unexpected parameters in CRF format '\(text)'")
    }
    return .crf(
      type: UInt8(keyed["type"] ?? 1),
      timestampInterval: UInt16(keyed["interval"] ?? 96),
      timestampsPerPdu: UInt8(keyed["tpp"] ?? 1),
      pull: UInt8(keyed["pull"] ?? 0),
      baseFrequency: UInt32(rate)
    )
  case "iec61883-6", "61883-6":
    guard let rate, let channels, (1...255).contains(channels) else {
      throw UsageError(
        "an IEC 61883-6 format needs a rate and a channel count, as in iec61883-6,48k,8ch"
      )
    }
    guard aafFormat == nil, samples == nil, keyed.isEmpty else {
      throw UsageError("only IEC 61883-6 AM824 formats can be given as a spec; give others in hex")
    }
    guard let format = StreamFormat.iec61883_6AM824(
      sampleRate: rate,
      channelsPerFrame: channels,
      isUpToChannelsCount: isUpToChannelsCount
    ) else { throw UsageError("IEC 61883-6 has no sample rate of \(rate) Hz") }
    return format
  default:
    throw UsageError(
      "unknown stream format '\(text)': give it in hex, or as aaf,…, crf,… or iec61883-6,…"
    )
  }
}

/// `int32`, or `int32/24` for 24 significant bits in a 32-bit sample.
private func parseAafFormatToken(_ token: String) -> (StreamFormat.AafFormat, Int?)? {
  let parts = token.split(separator: "/", maxSplits: 1).map(String.init)
  guard let format = aafFormatTokens.first(where: { $0.1 == parts[0] })?.0 else { return nil }
  guard parts.count == 2 else { return (format, nil) }
  guard let depth = Int(parts[1]) else { return nil }
  return (format, depth)
}

/// `0x` and 1 to 16 hex digits, or exactly 16 hex digits.
func parseHex64(_ text: String) -> UInt64? {
  let lowercased = text.lowercased()
  if lowercased.hasPrefix("0x") {
    let digits = lowercased.dropFirst(2)
    guard (1...16).contains(digits.count) else { return nil }
    return UInt64(digits, radix: 16)
  }
  guard lowercased.count == 16 else { return nil }
  return UInt64(lowercased, radix: 16)
}
