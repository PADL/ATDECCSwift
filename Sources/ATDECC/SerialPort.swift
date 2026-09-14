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
import Synchronization
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
  /// A frame queued for the writer task. Cancelling its send stops it being written, or stops
  /// the write in progress; the peer discards a frame cut short, as the next one begins with a
  /// delimiter.
  private final class Transmission: Sendable {
    private enum State {
      case queued
      case writing(Task<(), any Error>)
      case cancelled
    }

    let frame: [UInt8]
    let promise = Promise<()>()
    private let _state = Mutex(State.queued)

    init(frame: [UInt8]) {
      self.frame = frame
    }

    /// Starts writing the frame with `write`, unless its send has been cancelled.
    func startWriting(
      _ write: @escaping @Sendable ([UInt8]) async throws -> ()
    ) -> Task<(), any Error>? {
      _state.withLock { state in
        guard case .queued = state else { return nil }
        let frame = frame
        let task = Task { try await write(frame) }
        state = .writing(task)
        return task
      }
    }

    func cancel() {
      promise.resolve(.failure(CancellationError()))
      let write = _state.withLock { state -> Task<(), any Error>? in
        defer { state = .cancelled }
        guard case let .writing(task) = state else { return nil }
        return task
      }
      write?.cancel()
    }
  }

  public let path: String
  public let macAddress: EUI48
  public let peerMacAddress: EUI48

  let _fileHandle: FileHandle
  private let _ring: IORing
  // frames are written by one task so that concurrent sends, and short writes, never interleave
  private let _transmissions: AsyncStream<Transmission>.Continuation

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
    _fileHandle = fileHandle
    _ring = ring

    let (transmissions, continuation) = AsyncStream<Transmission>.makeStream()
    _transmissions = continuation
    Task {
      for await transmission in transmissions {
        guard let write = transmission.startWriting({ frame in
          try await _write(frame, to: fileHandle, ring: ring)
        }) else { continue }
        await transmission.promise.resolve(write.result)
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

  /// Sends a frame once those queued before it are written. Cancelling the send abandons the
  /// frame, even part-way through writing it.
  public func send(_ packet: IEEE802Packet) async throws {
    let transmission = try Transmission(frame: _encodeFrame(payload: packet.payload))
    guard case .enqueued = _transmissions.yield(transmission) else {
      throw Errno(rawValue: EBADF)
    }
    try await withTaskCancellationHandler {
      try await transmission.promise.value
    } onCancel: {
      transmission.cancel()
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
    try Task.checkCancellation()
    let written = try await ring.write(Array(frame[offset...]), to: fileHandle)
    guard written > 0 else { throw Errno(rawValue: EIO) }
    offset += written
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
