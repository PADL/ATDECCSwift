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

/// A point-to-point serial network port, for an entity reached over a UART rather than
/// Ethernet. Each AVTPDU (the AVTP control header and ADP, AECP or ACMP data, without an
/// Ethernet header or padding) is COBS encoded and delimited by zero bytes.
///
/// There is one peer, so every frame is sent to it whatever its destination address, and
/// received frames appear to come from `peerMacAddress`.
public final class SerialPort: NetworkPort {
  public let path: String
  public let macAddress: EUI48
  public let peerMacAddress: EUI48
  /// One by default. The peer answers in turn, and at UART rates the responses to several
  /// commands sent together take longer to arrive than the last of them is given to be answered.
  public let maximumInflightAecpCommands: Int

  let _fileHandle: FileHandle
  private let _link: PointToPointLink

  /// Opens the serial device at `path`, configuring it for raw 8N1 at `baudRate` without
  /// hardware flow control.
  ///
  /// The device is opened non-blocking. A terminal write that runs out of room can otherwise
  /// sleep in the kernel even when submitted to io_uring, as terminals do not support
  /// non-blocking kiocbs, stalling the thread that drives the ring and every other request on
  /// it; non-blocking, io_uring waits for room with a poll instead.
  public init(
    path: String,
    baudRate: Int = 115_200,
    macAddress: EUI48 = SerialPortLocalMacAddress,
    peerMacAddress: EUI48 = SerialPortPeerMacAddress,
    maximumInflightAecpCommands: Int = 1,
    ring: IORing = .shared
  ) throws {
    let speed = try _speed(baudRate: baudRate)
    let fileDescriptor = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK)
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
    // cfmakeraw leaves flow control as it was, and termios outlives each open of the device: a
    // previous user's CRTSCTS would stall transmission for good on a peer that never asserts CTS
    tty.c_cflag &= ~tcflag_t(CRTSCTS)
    tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
    try fileHandle.set(tty: tty)
    tcflush(fileDescriptor, TCIOFLUSH)

    self.path = path
    self.macAddress = macAddress
    self.peerMacAddress = peerMacAddress
    self.maximumInflightAecpCommands = max(maximumInflightAecpCommands, 1)
    _fileHandle = fileHandle
    _link = PointToPointLink(fileHandle: fileHandle, framing: .cobs, ring: ring) { frame in
      try await _write(frame, to: fileHandle, ring: ring)
    }
  }

  deinit {
    close()
  }

  /// Stops the port: later sends and receptions fail with EBADF, and a reception in progress
  /// ends with its next read. Frames already queued are still written. The device itself stays
  /// open until the port is released, as requests in flight hold it.
  public func close() {
    _link.close()
  }

  /// Sends a frame once those queued before it are written. Cancelling the send abandons the
  /// frame, even part-way through writing it.
  public func send(_ packet: IEEE802Packet) async throws {
    try await _link.send(packet)
  }

  public func receive(_ handler: (IEEE802Packet) async -> ()) async throws {
    try await _link.receive(macAddress: macAddress, peerMacAddress: peerMacAddress, handler)
  }
}

private func _write(_ frame: [UInt8], to fileHandle: FileHandle, ring: IORing) async throws {
  var offset = 0
  while offset < frame.count {
    try Task.checkCancellation()
    do {
      let written = try await ring.write(Array(frame[offset...]), to: fileHandle)
      guard written > 0 else { throw Errno(rawValue: EIO) }
      offset += written
    } catch let error as Errno where error.isTransient {
      // write the rest again: nothing of it was written
      await Task.yield()
    }
  }
}

// the termios speed constants import as Int32 on x86_64 but as UInt32 on aarch64
private func _speed(baudRate: Int) throws -> speed_t {
  switch baudRate {
  case 9600: speed_t(B9600)
  case 19200: speed_t(B19200)
  case 38400: speed_t(B38400)
  case 57600: speed_t(B57600)
  case 115_200: speed_t(B115200)
  case 230_400: speed_t(B230400)
  case 460_800: speed_t(B460800)
  case 500_000: speed_t(B500000)
  case 576_000: speed_t(B576000)
  case 921_600: speed_t(B921600)
  case 1_000_000: speed_t(B1000000)
  case 1_152_000: speed_t(B1152000)
  case 1_500_000: speed_t(B1500000)
  case 2_000_000: speed_t(B2000000)
  case 3_000_000: speed_t(B3000000)
  case 4_000_000: speed_t(B4000000)
  default: throw Errno(rawValue: EINVAL)
  }
}

#endif
