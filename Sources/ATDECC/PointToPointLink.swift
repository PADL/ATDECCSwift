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
import Synchronization
import struct SystemPackage.Errno

/// The largest AVTPDU carried on a point-to-point link, as on Ethernet.
let PointToPointMaximumPayloadLength = 1500

/// A link to one peer that carries AVTPDUs, each the AVTP control header and ADP, AECP or ACMP
/// data, without an Ethernet header or padding: a serial device, on which each is COBS encoded
/// and delimited by zero bytes, or a datagram socket, which carries one per datagram.
///
/// There is one peer, so every frame is sent to it whatever its destination address, and
/// received frames appear to come from the peer's address.
final class PointToPointLink: Sendable {
  enum Framing: Sendable {
    /// A byte stream, on which each AVTPDU is COBS encoded and sent between zero bytes. A read
    /// of nothing is the end of the stream, which ends reception with EIO.
    case cobs
    /// A datagram socket, which carries each AVTPDU, unencoded, as one datagram. Longer
    /// datagrams, and those too short for an AVTP control header, are discarded.
    case datagram
  }

  /// A frame queued for the writer task. Cancelling its send stops it being written, or stops
  /// the write in progress; the peer discards a COBS frame cut short, as the next one begins
  /// with a delimiter.
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

  let fileHandle: FileHandle
  private let _framing: Framing
  private let _ring: IORing
  // frames are written by one task so that concurrent sends, and short writes, never interleave
  private let _transmissions: AsyncStream<Transmission>.Continuation
  private let _isClosed = Atomic(false)

  /// Receives frames on `fileHandle`, and sends them with `write`, which is given each frame
  /// as it is to be written (COBS encoded and delimited, or a bare AVTPDU) in turn. The link
  /// holds `fileHandle` open until it and the requests in flight on it are released.
  init(
    fileHandle: FileHandle,
    framing: Framing,
    ring: IORing,
    write: @escaping @Sendable ([UInt8]) async throws -> ()
  ) {
    self.fileHandle = fileHandle
    _framing = framing
    _ring = ring

    let (transmissions, continuation) = AsyncStream<Transmission>.makeStream()
    _transmissions = continuation
    Task {
      for await transmission in transmissions {
        guard let task = transmission.startWriting(write) else { continue }
        await transmission.promise.resolve(task.result)
      }
    }
  }

  var isClosed: Bool {
    _isClosed.load(ordering: .relaxed)
  }

  /// Stops the link: later sends and receptions fail with EBADF, and a reception in progress
  /// ends with its next read. Frames already queued are still written.
  func close() {
    _isClosed.store(true, ordering: .relaxed)
    _transmissions.finish()
  }

  /// Sends a frame once those queued before it are written. Cancelling the send abandons the
  /// frame, even part-way through writing it.
  func send(_ packet: IEEE802Packet) async throws {
    let avtpdu = try _avtpdu(packet.payload)
    let frame = switch _framing {
    case .cobs: [Cobs.delimiter] + Cobs.encode(avtpdu) + [Cobs.delimiter]
    case .datagram: avtpdu
    }
    let transmission = Transmission(frame: frame)
    guard case .enqueued = _transmissions.yield(transmission) else {
      throw Errno(rawValue: EBADF)
    }
    try await withTaskCancellationHandler {
      try await transmission.promise.value
    } onCancel: {
      transmission.cancel()
    }
  }

  /// Receives frames until the task is cancelled, the link is closed (EBADF) or fails, as a
  /// byte stream does at its end (EIO). Frames addressed to the group (ADP and ACMP) are given
  /// `AvdeccMulticastMacAddress` as their destination, and AECP frames `macAddress`; all come
  /// from `peerMacAddress`.
  func receive(
    macAddress: EUI48,
    peerMacAddress: EUI48,
    _ handler: (IEEE802Packet) async -> ()
  ) async throws {
    var decoder = CobsFrameDecoder(maximumFrameLength: PointToPointMaximumPayloadLength)
    let readLength = switch _framing {
    case .cobs: _cobsReadLength
    // one more than the longest frame, so that a longer datagram, cut short, is seen to be
    case .datagram: PointToPointMaximumPayloadLength + 1
    }

    while !Task.isCancelled {
      guard !isClosed else { throw Errno(rawValue: EBADF) }
      let bytes: [UInt8]
      do {
        bytes = try await _ring.read(count: readLength, from: fileHandle)
      } catch let error as Errno where error.isTransient {
        // read again, keeping the frame the decoder has part of
        await Task.yield()
        continue
      }
      guard !isClosed else { throw Errno(rawValue: EBADF) }

      let payloads: [[UInt8]]
      switch _framing {
      case .cobs:
        guard !bytes.isEmpty else { throw Errno(rawValue: EIO) }
        payloads = decoder.decode(bytes)
      case .datagram:
        guard bytes.count <= PointToPointMaximumPayloadLength else { continue }
        payloads = [bytes]
      }

      for payload in payloads {
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

private let _cobsReadLength = 256

// The AVTPDU without any Ethernet padding, which a point-to-point link does not carry.
private func _avtpdu(_ payload: [UInt8]) throws -> [UInt8] {
  let header = try payload.withParserSpan { try AvtpduControlHeader(parsing: &$0) }
  let length = AvtpduControlHeader.length + Int(header.controlDataLength)
  guard length <= payload.count, length <= PointToPointMaximumPayloadLength else {
    throw AvdeccCodecError.invalidControlDataLength(header.controlDataLength)
  }
  return Array(payload.prefix(length))
}

extension Errno {
  /// An interrupted system call, or one that would block, has done nothing and is made again.
  var isTransient: Bool {
    self == .interrupted || self == .resourceTemporarilyUnavailable || self == .wouldBlock
  }
}

#endif
