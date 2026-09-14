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

#if os(Linux)

import BinaryParsing
import Glibc
import IEEE802
import IORing
import IORingUtils
import struct SystemPackage.Errno

/// The address of the host end of a serial link. Frames carry no addresses on the wire; entity
/// firmware sends frames addressed to this proxy address, and all multicast frames, to its UART.
public let SerialPortLocalMacAddress: EUI48 = [0x0A, 0xE9, 0x1B, 0x00, 0x00, 0x00]

/// The source address given to frames received on a serial link.
public let SerialPortPeerMacAddress: EUI48 = [0x0A, 0xE9, 0x1B, 0xFF, 0xFF, 0xFF]

// The largest AVTPDU carried on a serial link, as on Ethernet.
private let _serialMaximumPayloadLength = 1500
private let _serialReadLength = 256

/// A point-to-point serial network port, for an entity reached over a UART rather than
/// Ethernet. Each AVTPDU (the AVTP control header and ADP, AECP or ACMP data, without an
/// Ethernet header or padding) is COBS encoded and delimited by zero bytes.
///
/// There is one peer, so every frame is sent to it whatever its destination address, and
/// received frames appear to come from `peerMacAddress`.
public final class SerialPort: NetworkPort {
  private typealias Transmission = (
    frame: [UInt8],
    continuation: CheckedContinuation<(), any Error>
  )

  public let path: String
  public let macAddress: EUI48
  public let peerMacAddress: EUI48

  private let _fileHandle: FileHandle
  private let _ring: IORing
  // frames are written by one task so that concurrent sends, and short writes, never interleave
  private let _transmissions: AsyncStream<Transmission>.Continuation

  /// Opens the serial device at `path`, configuring it for raw 8N1 at `baudRate`.
  public init(
    path: String,
    baudRate: Int = 115_200,
    macAddress: EUI48 = SerialPortLocalMacAddress,
    peerMacAddress: EUI48 = SerialPortPeerMacAddress,
    ring: IORing = .shared
  ) throws {
    let speed = try _speed(baudRate: baudRate)
    let fileDescriptor = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC)
    guard fileDescriptor >= 0 else { throw Errno(rawValue: errno) }
    let fileHandle: FileHandle
    do {
      fileHandle = try FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    } catch {
      Glibc.close(fileDescriptor)
      throw error
    }

    var tty = try fileHandle.getTty()
    try tty.setN81(speed: speed)
    tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
    try fileHandle.set(tty: tty)
    tcflush(fileDescriptor, TCIOFLUSH)

    self.path = path
    self.macAddress = macAddress
    self.peerMacAddress = peerMacAddress
    _fileHandle = fileHandle
    _ring = ring

    let (transmissions, continuation) = AsyncStream<Transmission>.makeStream()
    _transmissions = continuation
    Task {
      for await transmission in transmissions {
        do {
          try await _write(transmission.frame, to: fileHandle, ring: ring)
          transmission.continuation.resume()
        } catch {
          transmission.continuation.resume(throwing: error)
        }
      }
    }
  }

  deinit {
    close()
  }

  /// Stops transmission; the device is closed once pending frames are written.
  public func close() {
    _transmissions.finish()
  }

  public func send(_ packet: IEEE802Packet) async throws {
    let frame = try _encodeFrame(payload: packet.payload)
    try await withCheckedThrowingContinuation { continuation in
      if case .terminated = _transmissions.yield((frame: frame, continuation: continuation)) {
        continuation.resume(throwing: Errno(rawValue: EBADF))
      }
    }
  }

  public func receive(_ handler: (IEEE802Packet) async -> ()) async throws {
    var decoder = CobsFrameDecoder(maximumFrameLength: _serialMaximumPayloadLength)

    while !Task.isCancelled {
      let bytes = try await _ring.read(count: _serialReadLength, from: _fileHandle)
      guard !bytes.isEmpty else { throw Errno(rawValue: EIO) }

      for payload in decoder.decode(bytes) {
        guard let header = try? payload.withParserSpan({
          try AvtpduControlHeader(parsing: &$0)
        }) else { continue }
        let isMulticast = header.subtype == AvtpSubtype.adp.rawValue ||
          header.subtype == AvtpSubtype.acmp.rawValue
        await handler(IEEE802Packet(
          destMacAddress: isMulticast ? AvdeccMulticastMacAddress : macAddress,
          tci: nil,
          sourceMacAddress: peerMacAddress,
          etherType: AvtpEtherType,
          payload: payload
        ))
      }
    }
  }
}

// Removes any Ethernet padding, which the serial encoding does not carry.
private func _encodeFrame(payload: [UInt8]) throws -> [UInt8] {
  let header = try payload.withParserSpan { try AvtpduControlHeader(parsing: &$0) }
  let length = AvtpduControlHeader.length + Int(header.controlDataLength)
  guard length <= payload.count, length <= _serialMaximumPayloadLength else {
    throw AvdeccCodecError.invalidControlDataLength(header.controlDataLength)
  }
  return [Cobs.delimiter] + Cobs.encode(Array(payload.prefix(length))) + [Cobs.delimiter]
}

private func _write(_ frame: [UInt8], to fileHandle: FileHandle, ring: IORing) async throws {
  var offset = 0
  while offset < frame.count {
    let written = try await ring.write(Array(frame[offset...]), to: fileHandle)
    guard written > 0 else { throw Errno(rawValue: EIO) }
    offset += written
  }
}

private func _speed(baudRate: Int) throws -> speed_t {
  let speed: Int32 = switch baudRate {
  case 9600: B9600
  case 19200: B19200
  case 38400: B38400
  case 57600: B57600
  case 115_200: B115200
  case 230_400: B230400
  case 460_800: B460800
  case 500_000: B500000
  case 576_000: B576000
  case 921_600: B921600
  case 1_000_000: B1000000
  case 1_152_000: B1152000
  case 1_500_000: B1500000
  case 2_000_000: B2000000
  case 3_000_000: B3000000
  case 4_000_000: B4000000
  default: throw Errno(rawValue: EINVAL)
  }
  return speed_t(speed)
}

#endif
