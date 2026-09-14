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

/// Consistent Overhead Byte Stuffing (Cheshire and Baker, 1999), which removes zero bytes from
/// a frame so that zero can delimit frames on a byte stream.
package enum Cobs {
  /// The delimiter between encoded frames.
  package static let delimiter: UInt8 = 0

  // A code byte counts the non-zero bytes that follow it, plus one; a maximal block of 254
  // non-zero bytes is not followed by an implied zero.
  private static let _maximumCode: UInt8 = 0xFF

  /// The largest encoding of `length` bytes, excluding delimiters.
  package static func maximumEncodedLength(_ length: Int) -> Int {
    length + length / Int(_maximumCode - 1) + 1
  }

  /// Encodes `bytes`, excluding delimiters.
  package static func encode(_ bytes: [UInt8]) -> [UInt8] {
    var encoded = [UInt8]()
    encoded.reserveCapacity(maximumEncodedLength(bytes.count))
    var codeIndex = encoded.count
    var code: UInt8 = 1
    encoded.append(0)

    for (index, byte) in bytes.enumerated() {
      if byte == delimiter {
        encoded[codeIndex] = code
        codeIndex = encoded.count
        code = 1
        encoded.append(0)
      } else {
        encoded.append(byte)
        code += 1
        if code == _maximumCode, index != bytes.index(before: bytes.endIndex) {
          encoded[codeIndex] = code
          codeIndex = encoded.count
          code = 1
          encoded.append(0)
        }
      }
    }
    encoded[codeIndex] = code
    return encoded
  }

  /// Decodes an encoded frame without its delimiters, returning nil if it is malformed.
  package static func decode(_ encoded: ArraySlice<UInt8>) -> [UInt8]? {
    var decoded = [UInt8]()
    decoded.reserveCapacity(encoded.count)
    var index = encoded.startIndex

    while index < encoded.endIndex {
      let code = encoded[index]
      guard code != delimiter else { return nil }
      let blockEnd = encoded.index(after: index) + Int(code) - 1
      guard blockEnd <= encoded.endIndex else { return nil }
      let block = encoded[encoded.index(after: index)..<blockEnd]
      guard !block.contains(delimiter) else { return nil }
      decoded.append(contentsOf: block)
      index = blockEnd
      if code != _maximumCode, index < encoded.endIndex {
        decoded.append(delimiter)
      }
    }
    return decoded
  }
}

/// Reassembles COBS-encoded frames from a byte stream. Every delimiter ends a frame, so a
/// receiver that starts reading part-way through a frame loses only that frame; empty,
/// malformed and oversized frames are discarded.
package struct CobsFrameDecoder {
  package let maximumFrameLength: Int
  private var _encoded = [UInt8]()
  private var _isDiscarding = false

  package init(maximumFrameLength: Int) {
    self.maximumFrameLength = maximumFrameLength
    _encoded.reserveCapacity(Cobs.maximumEncodedLength(maximumFrameLength))
  }

  /// Consumes `bytes`, returning the frames they complete.
  package mutating func decode(_ bytes: some Collection<UInt8>) -> [[UInt8]] {
    var frames = [[UInt8]]()

    for byte in bytes {
      if byte == Cobs.delimiter {
        if !_isDiscarding, !_encoded.isEmpty, let frame = Cobs.decode(_encoded[...]),
           frame.count <= maximumFrameLength
        {
          frames.append(frame)
        }
        _encoded.removeAll(keepingCapacity: true)
        _isDiscarding = false
      } else if !_isDiscarding {
        if _encoded.count == Cobs.maximumEncodedLength(maximumFrameLength) {
          _encoded.removeAll(keepingCapacity: true)
          _isDiscarding = true
        } else {
          _encoded.append(byte)
        }
      }
    }
    return frames
  }
}
