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

// The client side of the wire, for the loopback tests: what an APC such as the Noodles
// controller sends and expects. The server side is FlyingFox's.

/// A WebSocket message or control frame the server sent.
enum TestWebSocketMessage: Equatable {
  case binary([UInt8])
  case pong([UInt8])
  case close(UInt16?)
}

/// One masked client frame (RFC 6455 Section 5.3).
func testWebSocketFrame(opcode: UInt8, _ payload: [UInt8], fin: Bool = true) -> [UInt8] {
  let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
  var frame: [UInt8] = [(fin ? 0x80 : 0) | opcode]
  if payload.count < 126 {
    frame.append(0x80 | UInt8(payload.count))
  } else {
    frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
  }
  return frame + mask + payload.enumerated().map { $0.element ^ mask[$0.offset & 3] }
}

/// Server frames from `buffer`, which is left with any incomplete one.
func testWebSocketMessages(_ buffer: inout [UInt8]) -> [TestWebSocketMessage] {
  var messages = [TestWebSocketMessage]()
  while buffer.count >= 2 {
    var length = Int(buffer[1] & 0x7F)
    var header = 2
    if length == 126 {
      guard buffer.count >= 4 else { break }
      length = Int(buffer[2]) << 8 | Int(buffer[3])
      header = 4
    }
    guard buffer.count >= header + length else { break }
    let payload = Array(buffer[header..<(header + length)])
    switch buffer[0] & 0x0F {
    case 0x2: messages.append(.binary(payload))
    case 0xA: messages.append(.pong(payload))
    case 0x8: messages.append(.close(payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : nil))
    default: break
    }
    buffer.removeFirst(header + length)
  }
  return messages
}

/// The index just past the blank line ending an HTTP head in `bytes`, if it has all arrived.
func testEndOfHead(in bytes: [UInt8]) -> Int? {
  guard bytes.count >= 4 else { return nil }
  for i in 0...(bytes.count - 4) where bytes[i..<(i + 4)].elementsEqual([0x0D, 0x0A, 0x0D, 0x0A]) {
    return i + 4
  }
  return nil
}

/// The CONNECT request an APC sends (IEEE 1722.1-2021 Clause C.5.3.2.7).
func testConnectRequest(port: UInt16) -> [UInt8] {
  Array("CONNECT / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
}
