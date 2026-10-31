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

#if os(macOS)

import Darwin
import Dispatch
import IEEE802
import Synchronization
import struct SystemPackage.Errno

// <sys/ioccom.h>; function-like macros are not imported into Swift
private func _ioctlRequest(
  _ direction: UInt,
  _ group: Character,
  _ number: UInt,
  _ length: Int
) -> UInt {
  direction | (UInt(length) & 0x1FFF) << 16 | UInt(group.asciiValue!) << 8 | number
}

private let _iocVoid: UInt = 0x2000_0000
private let _iocOut: UInt = 0x4000_0000
private let _iocIn: UInt = 0x8000_0000
private let _iocInOut = _iocIn | _iocOut

private let _uintLength = MemoryLayout<UInt32>.size
private let _ifreqLength = MemoryLayout<ifreq>.size

let BIOCGBLEN = _ioctlRequest(_iocOut, "B", 102, _uintLength)
let BIOCSBLEN = _ioctlRequest(_iocInOut, "B", 102, _uintLength)
let BIOCSETF = _ioctlRequest(_iocIn, "B", 103, MemoryLayout<bpf_program>.size)
let BIOCFLUSH = _ioctlRequest(_iocVoid, "B", 104, 0)
let BIOCPROMISC = _ioctlRequest(_iocVoid, "B", 105, 0)
let BIOCGDLT = _ioctlRequest(_iocOut, "B", 106, _uintLength)
let BIOCSETIF = _ioctlRequest(_iocIn, "B", 108, _ifreqLength)
let BIOCSRTIMEOUT = _ioctlRequest(_iocIn, "B", 109, MemoryLayout<timeval>.size)
let BIOCIMMEDIATE = _ioctlRequest(_iocIn, "B", 112, _uintLength)
let BIOCSHDRCMPLT = _ioctlRequest(_iocIn, "B", 117, _uintLength)
let BIOCSSEESENT = _ioctlRequest(_iocIn, "B", 119, _uintLength)
let SIOCADDMULTI = _ioctlRequest(_iocIn, "i", 49, _ifreqLength)
let SIOCDELMULTI = _ioctlRequest(_iocIn, "i", 50, _ifreqLength)
let SIOCGIFFLAGS = _ioctlRequest(_iocInOut, "i", 17, _ifreqLength)
let SIOCGIFMEDIA = _ioctlRequest(_iocInOut, "i", 56, MemoryLayout<ifmediareq>.size)

/// The size of a read. A jumbo frame fits; the filter makes the buffer's contents sparse.
private let _bpfBufferLength: CUnsignedInt = 64 * 1024
/// How long a read waits for a frame, which bounds how long a stopped reception holds its device.
private let _bpfReadTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
/// Frames waiting for the handler; beyond this the oldest are dropped, as a socket's queue would.
private let _receiveQueueLength = 1024
/// There is no notification of carrier from a BPF device, so link state is polled.
private let _linkStatePollInterval = Duration.seconds(1)

/// Why a macOS Ethernet port could not be opened or used.
public enum EthernetPortError: Error, Equatable, CustomStringConvertible {
  case interfaceNotFound(String)
  /// The interface has no 48-bit link-layer address, or BPF doesn't see it as Ethernet.
  case notEthernet(String)
  /// The process may not open the BPF device. Stock macOS allows only root; access is commonly
  /// granted through a group, but an application cannot assume it has been.
  case bpfPermissionDenied(path: String)
  /// Every BPF device is in use.
  case bpfDeviceUnavailable
  /// Joining a multicast group needs root (SIOCADDMULTI); see `MulticastReception.promiscuous`.
  case multicastMembershipDenied(interfaceName: String)
  /// The port was opened with `Access.receiveOnly`.
  case sendOnReceiveOnlyPort
  /// A system call failed.
  case systemCallFailed(operation: String, Errno)

  public var description: String {
    switch self {
    case let .interfaceNotFound(name):
      "no network interface named \(name)"
    case let .notEthernet(name):
      "\(name) is not an Ethernet interface"
    case let .bpfPermissionDenied(path):
      "permission denied opening \(path): needs read and write access to the BPF devices"
    case .bpfDeviceUnavailable:
      "no BPF device is available"
    case let .multicastMembershipDenied(name):
      "joining the AVDECC multicast groups on \(name) needs root; run as root, or use promiscuous reception"
    case .sendOnReceiveOnlyPort:
      "the port is receive-only"
    case let .systemCallFailed(operation, errno):
      "\(operation) failed: \(errno)"
    }
  }
}

private func _lastError(_ operation: String) -> EthernetPortError {
  .systemCallFailed(operation: operation, Errno(rawValue: errno))
}

private func _makeInterfaceRequest(name: String) -> ifreq {
  var request = ifreq()
  withUnsafeMutableBytes(of: &request.ifr_name) { buffer in
    for (i, byte) in name.utf8.prefix(Int(IFNAMSIZ) - 1).enumerated() {
      buffer[i] = byte
    }
  }
  return request
}

/// The interface's Ethernet address, from its AF_LINK entry.
func _linkLayerAddress(interfaceName: String) throws -> EUI48 {
  var addresses: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&addresses) == 0 else { throw _lastError("getifaddrs") }
  defer { freeifaddrs(addresses) }

  var isFound = false
  var entry = addresses
  while let current = entry {
    entry = current.pointee.ifa_next
    guard String(cString: current.pointee.ifa_name) == interfaceName else { continue }
    isFound = true
    guard let address = current.pointee.ifa_addr,
          CInt(address.pointee.sa_family) == AF_LINK
    else { continue }
    let linkAddress = UnsafeRawPointer(address)
    let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
    let link = linkAddress.loadUnaligned(as: sockaddr_dl.self)
    guard link.sdl_alen == 6 else { continue }
    let bytes = UnsafeRawBufferPointer(
      start: linkAddress + dataOffset + Int(link.sdl_nlen),
      count: 6
    )
    return EUI48 { bytes[$0] }
  }
  throw isFound ? EthernetPortError.notEthernet(interfaceName) : .interfaceNotFound(interfaceName)
}

/// Whether the interface is up with carrier, or nil if there is no such interface. IFF_RUNNING
/// says nothing of the carrier here, which an Ethernet interface reports as its media status.
func _isInterfaceRunning(name: String) throws -> Bool? {
  let fd = socket(AF_INET, SOCK_DGRAM, 0)
  guard fd >= 0 else { throw Errno(rawValue: errno) }
  defer { close(fd) }

  var flagsRequest = _makeInterfaceRequest(name: name)
  guard ioctl(fd, SIOCGIFFLAGS, &flagsRequest) == 0 else {
    guard errno != ENXIO else { return nil }
    throw Errno(rawValue: errno)
  }
  let flags = CInt(flagsRequest.ifr_ifru.ifru_flags)
  guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { return false }

  var mediaRequest = ifmediareq()
  withUnsafeMutableBytes(of: &mediaRequest.ifm_name) { buffer in
    for (i, byte) in name.utf8.prefix(Int(IFNAMSIZ) - 1).enumerated() {
      buffer[i] = byte
    }
  }
  // an interface without media, such as a virtual one, has no carrier to lose
  guard ioctl(fd, SIOCGIFMEDIA, &mediaRequest) == 0,
        mediaRequest.ifm_status & IFM_AVALID != 0
  else { return true }
  return mediaRequest.ifm_status & IFM_ACTIVE != 0
}

/// A BPF device bound to an interface, or a stand-in for one in tests. The descriptor is closed
/// when the last reader and sender have released it.
final class BpfDevice: Sendable {
  let descriptor: CInt
  /// The size of buffer every read must use.
  let bufferLength: Int
  private let _onClose: @Sendable () -> ()
  private let _hasReceiver = Atomic(false)

  init(descriptor: CInt, bufferLength: Int, onClose: @escaping @Sendable () -> () = {}) {
    self.descriptor = descriptor
    self.bufferLength = bufferLength
    _onClose = onClose
  }

  deinit {
    _onClose()
    close(descriptor)
  }

  /// A device's frames can go to only one reader, so a reception claims it.
  func claimForReception() -> Bool {
    !_hasReceiver.exchange(true, ordering: .relaxed)
  }

  func write(_ frame: [UInt8]) throws {
    let written = frame.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    // a frame is written whole or not at all
    guard written >= 0 else { throw Errno(rawValue: errno) }
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) -> Result<Int, Errno> {
    let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
    return count >= 0 ? .success(count) : .failure(Errno(rawValue: errno))
  }
}

/// Opens the first free /dev/bpf device: each can be open only once.
private func _openBpfDevice(access: EthernetPort.Access) throws -> CInt {
  let flags = (access == .receiveOnly ? O_RDONLY : O_RDWR) | O_CLOEXEC
  for index in 0..<256 {
    let path = "/dev/bpf\(index)"
    let fd = open(path, flags)
    if fd >= 0 { return fd }
    switch errno {
    case EBUSY:
      continue
    case EACCES, EPERM:
      throw EthernetPortError.bpfPermissionDenied(path: path)
    case ENOENT:
      throw EthernetPortError.bpfDeviceUnavailable
    default:
      throw _lastError("open \(path)")
    }
  }
  throw EthernetPortError.bpfDeviceUnavailable
}

private func _setBpfFlag(
  _ fd: CInt,
  _ request: UInt,
  _ value: CUnsignedInt,
  _ name: String
) throws {
  var value = value
  guard ioctl(fd, request, &value) == 0 else { throw _lastError(name) }
}

/// Attaches an open BPF device to an interface, for ATDECC frames only.
private func _configureBpfDevice(_ fd: CInt, interfaceName: String) throws -> Int {
  // the size must be set before the device is attached, and is the kernel's to adjust
  var bufferLength = _bpfBufferLength
  guard ioctl(fd, BIOCSBLEN, &bufferLength) == 0 else { throw _lastError("BIOCSBLEN") }

  var request = _makeInterfaceRequest(name: interfaceName)
  guard ioctl(fd, BIOCSETIF, &request) == 0 else {
    if errno == ENXIO { throw EthernetPortError.interfaceNotFound(interfaceName) }
    throw _lastError("BIOCSETIF")
  }
  guard ioctl(fd, BIOCGBLEN, &bufferLength) == 0 else { throw _lastError("BIOCGBLEN") }

  var linkType = CUnsignedInt(0)
  guard ioctl(fd, BIOCGDLT, &linkType) == 0 else { throw _lastError("BIOCGDLT") }
  guard linkType == DLT_EN10MB else { throw EthernetPortError.notEthernet(interfaceName) }

  // each frame is delivered as it arrives, rather than when the buffer is full
  try _setBpfFlag(fd, BIOCIMMEDIATE, 1, "BIOCIMMEDIATE")
  // frames this host transmits are not received
  try _setBpfFlag(fd, BIOCSSEESENT, 0, "BIOCSSEESENT")
  // frames keep the source address they were given
  try _setBpfFlag(fd, BIOCSHDRCMPLT, 1, "BIOCSHDRCMPLT")

  var timeout = _bpfReadTimeout
  guard ioctl(fd, BIOCSRTIMEOUT, &timeout) == 0 else { throw _lastError("BIOCSRTIMEOUT") }

  var instructions = AvdeccBpfProgram.map {
    bpf_insn(code: $0.code, jt: $0.jumpIfTrue, jf: $0.jumpIfFalse, k: $0.operand)
  }
  try instructions.withUnsafeMutableBufferPointer { instructions in
    var program = bpf_program(
      bf_len: CUnsignedInt(instructions.count),
      bf_insns: instructions.baseAddress
    )
    guard ioctl(fd, BIOCSETF, &program) == 0 else { throw _lastError("BIOCSETF") }
  }
  // what arrived before the filter was set
  guard ioctl(fd, BIOCFLUSH) == 0 else { throw _lastError("BIOCFLUSH") }
  return Int(bufferLength)
}

private func _makeMulticastRequest(interfaceName: String, group: EUI48) -> ifreq {
  var request = _makeInterfaceRequest(name: interfaceName)
  var address = sockaddr()
  address.sa_len = UInt8(MemoryLayout<sockaddr>.size)
  address.sa_family = sa_family_t(AF_UNSPEC)
  withUnsafeMutableBytes(of: &address.sa_data) { buffer in
    for i in group.indices {
      buffer[i] = group[i]
    }
  }
  request.ifr_ifru.ifru_addr = address
  return request
}

private func _leaveMulticastGroups(_ groups: [EUI48], interfaceName: String) {
  let fd = socket(AF_INET, SOCK_DGRAM, 0)
  guard fd >= 0 else { return }
  defer { close(fd) }
  for group in groups {
    var request = _makeMulticastRequest(interfaceName: interfaceName, group: group)
    _ = ioctl(fd, SIOCDELMULTI, &request)
  }
}

/// Joins `groups`, or none of them.
private func _joinMulticastGroups(_ groups: [EUI48], interfaceName: String) throws {
  let fd = socket(AF_INET, SOCK_DGRAM, 0)
  guard fd >= 0 else { throw _lastError("socket") }
  defer { close(fd) }
  var joined = [EUI48]()
  for group in groups {
    var request = _makeMulticastRequest(interfaceName: interfaceName, group: group)
    guard ioctl(fd, SIOCADDMULTI, &request) == 0 else {
      let error = errno
      _leaveMulticastGroups(joined, interfaceName: interfaceName)
      if error == EPERM || error == EACCES {
        throw EthernetPortError.multicastMembershipDenied(interfaceName: interfaceName)
      }
      throw EthernetPortError.systemCallFailed(operation: "SIOCADDMULTI", Errno(rawValue: error))
    }
    joined.append(group)
  }
}

private func _openBpfDevice(
  interfaceName: String,
  access: EthernetPort.Access,
  multicastReception: EthernetPort.MulticastReception
) throws -> BpfDevice {
  let fd = try _openBpfDevice(access: access)
  do {
    let bufferLength = try _configureBpfDevice(fd, interfaceName: interfaceName)
    switch multicastReception {
    case .joinGroups:
      let groups = [AvdeccMulticastMacAddress, AvdeccIdentifyMulticastMacAddress]
      try _joinMulticastGroups(groups, interfaceName: interfaceName)
      return BpfDevice(descriptor: fd, bufferLength: bufferLength) {
        _leaveMulticastGroups(groups, interfaceName: interfaceName)
      }
    case .promiscuous:
      guard ioctl(fd, BIOCPROMISC) == 0 else { throw _lastError("BIOCPROMISC") }
      return BpfDevice(descriptor: fd, bufferLength: bufferLength)
    }
  } catch {
    close(fd)
    throw error
  }
}

/// An Ethernet network port on macOS, using a Berkeley Packet Filter device. As on Linux, it has
/// `init(interfaceName:)` and receives ADP, AECP and ACMP frames addressed to it or to the AVDECC
/// multicast groups; frames this host transmits are not received.
///
/// BPF devices are root's on stock macOS. A process that can open them but isn't root can't join
/// a multicast group, so must choose `MulticastReception.promiscuous`.
public struct EthernetPort: NetworkPort {
  public enum Access: Sendable {
    case readWrite
    /// The BPF device is opened read-only, so that the kernel refuses to transmit on it, and
    /// `send(_:)` throws. A `Controller` can't work on such a port, as it needs to transmit.
    case receiveOnly
  }

  /// How frames sent to the AVDECC multicast groups are let in by the interface's address filter.
  public enum MulticastReception: Sendable {
    /// Joins the groups, as the Linux port does, for as long as the port is open. This needs root,
    /// and a process that exits without closing the port leaves the interface in the groups.
    case joinGroups
    /// Puts the interface in promiscuous mode for as long as the port is open, which needs only
    /// access to the BPF device. The kernel filter still passes only ATDECC frames to this port.
    case promiscuous
  }

  /// The most recently opened device. Sends go to it.
  private final class Resolution: Sendable {
    let device: Mutex<BpfDevice>

    init(_ device: BpfDevice) {
      self.device = Mutex(device)
    }
  }

  public let interfaceName: String
  /// The interface's address when the port was opened.
  public let macAddress: EUI48
  public let access: Access
  private let _resolution: Resolution
  private let _open: @Sendable () throws -> BpfDevice
  private let _isRunning: @Sendable () throws -> Bool?

  /// Opens the port, throwing `EthernetPortError`.
  public init(
    interfaceName: String,
    access: Access = .readWrite,
    multicastReception: MulticastReception = .joinGroups
  ) throws {
    // first, so that a name that is wrong is reported as that whatever the BPF permissions
    let macAddress = try _linkLayerAddress(interfaceName: interfaceName)
    try self.init(
      interfaceName: interfaceName,
      macAddress: macAddress,
      access: access,
      open: {
        try _openBpfDevice(
          interfaceName: interfaceName,
          access: access,
          multicastReception: multicastReception
        )
      },
      isRunning: { try _isInterfaceRunning(name: interfaceName) }
    )
  }

  /// A port on the devices `open` returns, which tests supply.
  init(
    interfaceName: String,
    macAddress: EUI48,
    access: Access,
    open: @escaping @Sendable () throws -> BpfDevice,
    isRunning: @escaping @Sendable () throws -> Bool?
  ) throws {
    self.interfaceName = interfaceName
    self.macAddress = macAddress
    self.access = access
    _open = open
    _isRunning = isRunning
    _resolution = try Resolution(open())
  }

  public func send(_ packet: IEEE802Packet) async throws {
    guard access == .readWrite else { throw EthernetPortError.sendOnReceiveOnlyPort }
    try _resolution.device.withLock { $0 }.write(packet.serialized())
  }

  public func receive(_ handler: (IEEE802Packet) async -> ()) async throws {
    try await receive(onReady: {}, handler)
  }

  /// The device the port was opened with, if it is unclaimed; otherwise another. Once a reception
  /// has failed its device is done for, and a new reception can overlap the end of the last.
  private func _deviceForReception() throws -> BpfDevice {
    let current = _resolution.device.withLock { $0 }
    if current.claimForReception() { return current }
    let macAddress = try _linkLayerAddress(interfaceName: interfaceName)
    // frames are sent from, and entity IDs derived from, the address the port was opened with;
    // under another, unicast responses would never arrive, so fail where it can be seen
    guard _isEqualMacAddress(macAddress, self.macAddress) else {
      throw Errno.addressNotAvailable
    }
    let device = try _open()
    _ = device.claimForReception()
    _resolution.device.withLock { $0 = device }
    return device
  }

  public func receive(
    onReady: () async -> (),
    _ handler: (IEEE802Packet) async -> ()
  ) async throws {
    let device = try _deviceForReception()
    let macAddress = macAddress
    let (packets, continuation) = AsyncThrowingStream<IEEE802Packet, any Error>
      .makeStream(bufferingPolicy: .bufferingNewest(_receiveQueueLength))
    let isStopped = StopFlag()
    defer { isStopped.set() }

    // reads block, so they have a thread of their own rather than one of the concurrency pool's
    DispatchQueue(label: "com.padl.ATDECC.EthernetPort.\(interfaceName)").async {
      let failure = _runBpfReceiveLoop(
        bufferLength: device.bufferLength,
        macAddress: macAddress,
        read: device.read(into:),
        isStopped: isStopped.isSet,
        deliver: { continuation.yield($0) }
      )
      continuation.finish(throwing: failure)
    }
    await onReady()
    for try await packet in packets {
      await handler(packet)
    }
  }

  /// Polls the interface's state, as there is nothing a process can wait on without privilege.
  public func monitorLinkState(_ handler: (Bool) async -> ()) async throws {
    var isUp: Bool?
    while !Task.isCancelled {
      let isRunning = try _isRunning() ?? false
      if isRunning != isUp {
        isUp = isRunning
        await handler(isRunning)
      }
      try? await Task.sleep(for: _linkStatePollInterval)
    }
  }
}

private final class StopFlag: Sendable {
  private let _flag = Atomic(false)

  func set() {
    _flag.store(true, ordering: .relaxed)
  }

  func isSet() -> Bool {
    _flag.load(ordering: .relaxed)
  }
}

#endif
