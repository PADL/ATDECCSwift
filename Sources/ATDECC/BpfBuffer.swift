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

import IEEE802
import struct SystemPackage.Errno

// The parts of a Berkeley Packet Filter port that need no system calls, so that they build on every
// platform and are tested with in-memory buffers: the layout of a read, the filter program, which
// frames a port takes, and the read loop.

/// One `bpf_hdr` as a read delivers it, and the place in the buffer of the frame it precedes.
struct BpfRecord: Equatable, Sendable {
  /// bh_caplen: the bytes of the frame in the buffer.
  let capturedLength: Int
  /// bh_datalen: the length of the frame on the wire.
  let originalLength: Int
  /// Where the frame's bytes are in the buffer.
  let frame: Range<Int>

  var isTruncated: Bool {
    capturedLength < originalLength
  }
}

/// `bpf_hdr` is in host byte order: bh_tstamp (a timeval32), bh_caplen, bh_datalen, bh_hdrlen. The
/// kernel writes SIZEOF_BPF_HDR octets, which is less than the size of the C struct.
private let _bpfCapturedLengthOffset = 8
private let _bpfOriginalLengthOffset = 12
private let _bpfHeaderLengthOffset = 16
let _bpfMinimumHeaderLength = 18

/// BPF_WORDALIGN. Records begin on a multiple of BPF_ALIGNMENT, which is four octets on Darwin,
/// from the start of the buffer.
func _bpfWordAlign(_ offset: Int) -> Int {
  (offset + 3) & ~3
}

/// The records in the bytes of a read: a read can hold several frames. A record is found from the
/// bh_hdrlen and bh_caplen of the one before it, so a record that doesn't fit in the buffer ends
/// the sequence, as nothing after it can be trusted.
struct BpfRecords: Sequence, IteratorProtocol {
  private let _buffer: UnsafeRawBufferPointer
  private var _offset = 0

  init(_ buffer: UnsafeRawBufferPointer) {
    _buffer = buffer
  }

  mutating func next() -> BpfRecord? {
    guard _offset <= _buffer.count - _bpfMinimumHeaderLength else { return nil }
    let capturedLength = Int(_buffer.loadUnaligned(
      fromByteOffset: _offset + _bpfCapturedLengthOffset,
      as: UInt32.self
    ))
    let originalLength = Int(_buffer.loadUnaligned(
      fromByteOffset: _offset + _bpfOriginalLengthOffset,
      as: UInt32.self
    ))
    // the kernel pads this so that the frame's network header is aligned, so it is read, not
    // assumed
    let headerLength = Int(_buffer.loadUnaligned(
      fromByteOffset: _offset + _bpfHeaderLengthOffset,
      as: UInt16.self
    ))
    let frameStart = _offset + headerLength
    guard headerLength >= _bpfMinimumHeaderLength,
          capturedLength <= _buffer.count - frameStart
    else {
      _offset = _buffer.count
      return nil
    }
    _offset = _bpfWordAlign(frameStart + capturedLength)
    return BpfRecord(
      capturedLength: capturedLength,
      originalLength: originalLength,
      frame: frameStart..<(frameStart + capturedLength)
    )
  }
}

/// One instruction of a classic BPF program; the layout of `struct bpf_insn`.
struct BpfInstruction: Equatable, Sendable {
  var code: UInt16
  var jumpIfTrue: UInt8
  var jumpIfFalse: UInt8
  var operand: UInt32

  init(code: UInt16, jumpIfTrue: UInt8 = 0, jumpIfFalse: UInt8 = 0, operand: UInt32 = 0) {
    self.code = code
    self.jumpIfTrue = jumpIfTrue
    self.jumpIfFalse = jumpIfFalse
    self.operand = operand
  }

  // BPF_LD|BPF_H|BPF_ABS, BPF_LD|BPF_B|BPF_ABS
  static func loadHalfword(at offset: UInt32) -> Self { Self(code: 0x28, operand: offset) }
  static func loadByte(at offset: UInt32) -> Self { Self(code: 0x30, operand: offset) }
  // BPF_JMP|BPF_JA
  static func jump(over count: UInt32) -> Self { Self(code: 0x05, operand: count) }
  // BPF_JMP|BPF_JEQ|BPF_K, BPF_JMP|BPF_JGE|BPF_K, BPF_JMP|BPF_JGT|BPF_K
  static func jumpIfEqual(_ value: UInt32, skipIfTrue: UInt8 = 0, skipIfFalse: UInt8 = 0) -> Self {
    Self(code: 0x15, jumpIfTrue: skipIfTrue, jumpIfFalse: skipIfFalse, operand: value)
  }

  static func jumpIfAtLeast(
    _ value: UInt32,
    skipIfTrue: UInt8 = 0,
    skipIfFalse: UInt8 = 0
  ) -> Self {
    Self(code: 0x35, jumpIfTrue: skipIfTrue, jumpIfFalse: skipIfFalse, operand: value)
  }

  static func jumpIfAbove(_ value: UInt32, skipIfTrue: UInt8 = 0, skipIfFalse: UInt8 = 0) -> Self {
    Self(code: 0x25, jumpIfTrue: skipIfTrue, jumpIfFalse: skipIfFalse, operand: value)
  }

  // BPF_RET|BPF_K: the bytes of the frame to capture
  static func accept(_ length: UInt32) -> Self { Self(code: 0x06, operand: length) }
}

private let _ieee8021QEtherType = UInt32(IEEE802Packet.IEEE8021QTagged)

/// Accepts AVTP frames carrying ADP, AECP or ACMP, tagged with a VLAN or not. Stream data shares
/// the EtherType, and would crowd ATDECC out of the read buffer, so the subtype is checked too.
let AvdeccBpfProgram: [BpfInstruction] = [
  /* 0 */ .loadHalfword(at: 12),
  /* 1 */ .jumpIfEqual(UInt32(AvtpEtherType), skipIfTrue: 5),
  /* 2 */ .jumpIfEqual(_ieee8021QEtherType, skipIfFalse: 8),
  /* 3 */ .loadHalfword(at: 16),
  /* 4 */ .jumpIfEqual(UInt32(AvtpEtherType), skipIfFalse: 6),
  /* 5 */ .loadByte(at: 18),
  /* 6 */ .jump(over: 1),
  /* 7 */ .loadByte(at: 14),
  /* 8 */ .jumpIfAtLeast(UInt32(AvtpSubtype.adp.rawValue), skipIfFalse: 2),
  /* 9 */ .jumpIfAbove(UInt32(AvtpSubtype.acmp.rawValue), skipIfTrue: 1),
  /* 10 */ .accept(UInt32.max),
  /* 11 */ .accept(0),
]

/// Whether a port with address `macAddress` takes `packet`: `NetworkPort.receive(_:)` promises
/// AVTP frames addressed to the port or to the AVDECC groups, and a promiscuous interface also
/// delivers those addressed to others.
func _isAvdeccFrame(_ packet: IEEE802Packet, for macAddress: EUI48) -> Bool {
  guard packet.etherType == AvtpEtherType,
        let subtype = packet.payload.first,
        (AvtpSubtype.adp.rawValue...AvtpSubtype.acmp.rawValue).contains(subtype)
  else { return false }
  return _isEqualMacAddress(packet.destMacAddress, macAddress) ||
    _isEqualMacAddress(packet.destMacAddress, AvdeccMulticastMacAddress) ||
    _isEqualMacAddress(packet.destMacAddress, AvdeccIdentifyMulticastMacAddress)
}

/// The frames in the bytes of a read that are for `macAddress`, in order. Truncated and malformed
/// frames are dropped: they can only have been damaged on the way here.
func _avdeccPackets(in buffer: UnsafeRawBufferPointer, for macAddress: EUI48) -> [IEEE802Packet] {
  BpfRecords(buffer).compactMap { record in
    guard !record.isTruncated,
          let packet = try? IEEE802Packet(
            hwHeader: [],
            payload: Array(buffer[record.frame])
          ),
          _isAvdeccFrame(packet, for: macAddress)
    else { return nil }
    return packet
  }
}

/// Reads a BPF device until `isStopped` returns true or a read fails, delivering the frames for
/// `macAddress`, and returns the failure, if any. `read` is called with a buffer of exactly
/// `bufferLength` bytes, as the device requires, and returns the bytes read or the failure; none
/// means its timeout expired, which is when `isStopped` is looked at while the network is quiet.
func _runBpfReceiveLoop(
  bufferLength: Int,
  macAddress: EUI48,
  read: (UnsafeMutableRawBufferPointer) -> Result<Int, Errno>,
  isStopped: () -> Bool,
  deliver: (IEEE802Packet) -> ()
) -> Errno? {
  let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferLength, alignment: 4)
  defer { buffer.deallocate() }
  while !isStopped() {
    switch read(buffer) {
    case let .success(count):
      let bytes = UnsafeRawBufferPointer(rebasing: buffer[..<count])
      for packet in _avdeccPackets(in: bytes, for: macAddress) {
        deliver(packet)
      }
    case .failure(.interrupted), .failure(.resourceTemporarilyUnavailable):
      continue
    case let .failure(error):
      return error
    }
  }
  return nil
}
