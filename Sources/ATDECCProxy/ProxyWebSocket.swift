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

// APP over WebSocket is an extension, not part of IEEE 1722.1-2021 Annex C: it lets browser
// controllers reach an APS. It follows the Noodles/Sienda ATDECC proxy: the upgrade is a GET of
// /ws on the APP port, without a subprotocol, and messages are binary, each one APPDU.

/// The request target on which an APS accepts WebSocket upgrades.
public let AppWebSocketPath = "/ws"

/// The largest WebSocket message an APS accepts: a little more than the largest APPDU.
public let AppWebSocketMaximumMessageLength = 4096

/// A WebSocket opcode (RFC 6455 Section 5.2).
public enum WebSocketOpcode: UInt8, Sendable {
  case continuation = 0x0
  case text = 0x1
  case binary = 0x2
  case close = 0x8
  case ping = 0x9
  case pong = 0xA

  var isControl: Bool { rawValue & 0x8 != 0 }
}

/// Why WebSocket input is refused; the connection is then failed (RFC 6455 Section 7.1.7).
public enum WebSocketError: Error, Equatable, Sendable {
  case protocolError
  case unmaskedClientFrame
  case messageTooLong
}

/// A WebSocket message or control frame received from a client.
public enum WebSocketMessage: Sendable, Equatable {
  case binary([UInt8])
  case text([UInt8])
  case ping([UInt8])
  case pong([UInt8])
  case close
}

/// Splits the octets a client sends into messages (RFC 6455 Section 5): client frames are
/// masked, data messages may be fragmented and control frames interleaved.
public struct WebSocketFrameDecoder: Sendable {
  private var buffer = [UInt8]()
  private var fragments: (opcode: WebSocketOpcode, payload: [UInt8])?
  private let requiresMask: Bool

  /// A server's decoder requires masked frames; a client's refuses them.
  public init(requiresMask: Bool = true) {
    self.requiresMask = requiresMask
  }

  public mutating func decode(_ bytes: [UInt8]) throws(WebSocketError) -> [WebSocketMessage] {
    buffer.append(contentsOf: bytes)
    var messages = [WebSocketMessage]()
    var start = 0
    while let (frame, length) = try parseFrame(at: start) {
      start += length
      if let message = try assemble(frame) {
        messages.append(message)
      }
    }
    buffer.removeFirst(start)
    return messages
  }

  private typealias Frame = (fin: Bool, opcode: WebSocketOpcode, payload: [UInt8])

  private func parseFrame(at start: Int) throws(WebSocketError) -> (Frame, Int)? {
    let available = buffer.count - start
    guard available >= 2 else { return nil }
    let first = buffer[start], second = buffer[start + 1]
    guard first & 0x70 == 0, let opcode = WebSocketOpcode(rawValue: first & 0x0F) else { throw .protocolError }
    let masked = second & 0x80 != 0
    guard masked == requiresMask else { throw requiresMask ? .unmaskedClientFrame : .protocolError }
    var headerLength = 2
    var payloadLength = Int(second & 0x7F)
    if payloadLength == 126 {
      guard available >= 4 else { return nil }
      payloadLength = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
      headerLength = 4
    } else if payloadLength == 127 {
      guard available >= 10 else { return nil }
      guard buffer[start + 2] == 0, buffer[start + 3] == 0, buffer[start + 4] == 0, buffer[start + 5] == 0 else {
        throw .messageTooLong
      }
      payloadLength = (2...5).reduce(0) { $0 << 8 | Int(buffer[start + 4 + $1]) }
      headerLength = 10
    }
    guard payloadLength <= AppWebSocketMaximumMessageLength else { throw .messageTooLong }
    guard !opcode.isControl || (payloadLength <= 125 && first & 0x80 != 0) else { throw .protocolError }
    let maskLength = masked ? 4 : 0
    let length = headerLength + maskLength + payloadLength
    guard available >= length else { return nil }
    let payloadStart = start + headerLength + maskLength
    var payload = Array(buffer[payloadStart..<(payloadStart + payloadLength)])
    if masked {
      let mask = buffer[(start + headerLength)..<(start + headerLength + 4)].map(\.self)
      for i in payload.indices {
        payload[i] ^= mask[i & 3]
      }
    }
    return ((first & 0x80 != 0, opcode, payload), length)
  }

  private mutating func assemble(_ frame: Frame) throws(WebSocketError) -> WebSocketMessage? {
    switch frame.opcode {
    case .ping: return .ping(frame.payload)
    case .pong: return .pong(frame.payload)
    case .close: return .close
    case .continuation:
      guard var fragments else { throw .protocolError }
      fragments.payload += frame.payload
      guard fragments.payload.count <= AppWebSocketMaximumMessageLength else { throw .messageTooLong }
      self.fragments = frame.fin ? nil : fragments
      return frame.fin ? Self.message(fragments.opcode, fragments.payload) : nil
    case .binary, .text:
      guard fragments == nil else { throw .protocolError }
      guard frame.fin else {
        fragments = (frame.opcode, frame.payload)
        return nil
      }
      return Self.message(frame.opcode, frame.payload)
    }
  }

  private static func message(_ opcode: WebSocketOpcode, _ payload: [UInt8]) -> WebSocketMessage {
    opcode == .text ? .text(payload) : .binary(payload)
  }
}

/// One unfragmented WebSocket frame; `maskingKey` is given by a client and nil for a server.
public func webSocketFrame(_ opcode: WebSocketOpcode, _ payload: [UInt8], maskingKey: [UInt8]? = nil) -> [UInt8] {
  var frame: [UInt8] = [0x80 | opcode.rawValue]
  let maskBit: UInt8 = maskingKey == nil ? 0 : 0x80
  if payload.count < 126 {
    frame.append(maskBit | UInt8(payload.count))
  } else if payload.count <= 0xFFFF {
    frame += [maskBit | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
  } else {
    frame.append(maskBit | 127)
    frame += (0..<8).map { UInt8(truncatingIfNeeded: payload.count >> (56 - 8 * $0)) }
  }
  guard let maskingKey else { return frame + payload }
  frame += maskingKey
  return frame + payload.enumerated().map { $0.element ^ maskingKey[$0.offset & 3] }
}

/// The Sec-WebSocket-Accept value for a client's Sec-WebSocket-Key (RFC 6455 Section 4.2.2).
public func webSocketAcceptValue(forKey key: String) -> String {
  base64Encode(sha1(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
}

//
// Origins
//

/// The origins of the Noodles controller, which the Noodles/Sienda proxy always allows.
public let AppNoodlesWebSocketOrigins = ["noodlescontroller.com", "app.noodlescontroller.com", "noodles-controller.web.app"]

/// Whether a WebSocket upgrade from a page at `origin` (its Origin field) is allowed: no Origin
/// (not a browser), the APS's own `host`, or one of `allowedHosts`, each a host or host:port.
public func isAllowedWebSocketOrigin(_ origin: String?, host: String?, allowedHosts: [String]) -> Bool {
  guard let origin else { return true }
  guard let schemeEnd = origin.range(of: "://") else { return false }
  let authority = origin[schemeEnd.upperBound...].lowercased()
  let hostOnly = authority.split(separator: ":").first.map(String.init) ?? authority
  if let host, authority == host.lowercased() { return true }
  return allowedHosts.contains { $0.lowercased() == authority || $0.lowercased() == hostOnly }
}

//
// SHA-1 (FIPS 180-4) and base64 (RFC 4648), for the opening handshake only
//

func sha1(_ message: [UInt8]) -> [UInt8] {
  var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
  var padded = message + [0x80]
  while padded.count % 64 != 56 {
    padded.append(0)
  }
  padded += UInt64(message.count * 8).bigEndianBytes
  var w = [UInt32](repeating: 0, count: 80)
  for chunk in stride(from: 0, to: padded.count, by: 64) {
    for i in 0..<16 {
      w[i] = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(padded[chunk + 4 * i + $1]) }
    }
    for i in 16..<80 {
      w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotatedLeft(1)
    }
    sha1Compress(&h, w)
  }
  return h.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (24 - 8 * $0)) } }
}

private func sha1Compress(_ h: inout [UInt32], _ w: [UInt32]) {
  var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
  for i in 0..<80 {
    let (f, k): (UInt32, UInt32) = switch i {
    case 0..<20: ((b & c) | (~b & d), 0x5A82_7999)
    case 20..<40: (b ^ c ^ d, 0x6ED9_EBA1)
    case 40..<60: ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
    default: (b ^ c ^ d, 0xCA62_C1D6)
    }
    let temp = a.rotatedLeft(5) &+ f &+ e &+ k &+ w[i]
    (e, d, c, b, a) = (d, c, b.rotatedLeft(30), a, temp)
  }
  h[0] &+= a
  h[1] &+= b
  h[2] &+= c
  h[3] &+= d
  h[4] &+= e
}

private extension UInt32 {
  func rotatedLeft(_ count: UInt32) -> UInt32 { self << count | self >> (32 - count) }
}

func base64Encode(_ bytes: [UInt8]) -> String {
  let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
  var text = ""
  for chunk in stride(from: 0, to: bytes.count, by: 3) {
    let group = Array(bytes[chunk..<min(chunk + 3, bytes.count)])
    let value = (0..<3).reduce(UInt32(0)) { $0 << 8 | UInt32($1 < group.count ? group[$1] : 0) }
    for i in 0..<4 {
      text.append(i <= group.count ? alphabet[Int(value >> (18 - 6 * UInt32(i))) & 0x3F] : "=")
    }
  }
  return text
}
