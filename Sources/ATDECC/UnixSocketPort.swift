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
import SocketAddress
import Synchronization
import struct SystemPackage.Errno

/// The address of the controller end of a Unix domain socket link, as la_avdecc's local
/// protocol interface uses. Frames carry no addresses on the wire; received AECP frames are
/// given this destination.
public let UnixSocketPortLocalMacAddress: EUI48 = [0x0A, 0xE9, 0x1B, 0x01, 0x01, 0x01]

/// The source address given to frames received on a Unix domain socket link: the entity at the
/// other end, which a controller can pair with without waiting to learn its address.
public let UnixSocketPortPeerMacAddress: EUI48 = [0x0A, 0xE9, 0x1B, 0xFF, 0xFF, 0xFF]

/// A point-to-point network port to an entity on the same host, reached over an AF_UNIX
/// datagram socket, as la_avdecc's local protocol interface is. Each datagram carries one
/// AVTPDU (the AVTP control header and ADP, AECP or ACMP data, without an Ethernet header or
/// padding, and not COBS encoded), of at most 1500 octets.
///
/// There is one peer, so every frame is sent to it whatever its destination address, and
/// received frames appear to come from `peerMacAddress`.
///
/// Opened with a path, the port binds its socket to an autobound abstract address, so that the
/// entity, which receives on the path with `recvfrom`, can reply with `sendto` to the address
/// each datagram came from, and connects it to the path. A datagram socket has no end of
/// stream: an entity that goes away is noticed when a send fails, and the port then connects
/// to the path again, once per send, so that a restarted entity is reached; until it is, sends
/// fail with ECONNREFUSED or ENOENT, and the entity goes offline when its advertisements stop.
///
/// An entity learns of a controller only from datagrams it receives, and a restarted entity
/// cannot reach a controller at all until the controller sends again (its `sendto` fails with
/// EPERM, as the controller's socket is still connected to the entity's old one): a controller
/// that should find an entity that restarts sets an automatic discovery delay. An entity
/// forgets a controller when a send to it fails with EPERM, ECONNREFUSED or ENOENT.
public final class UnixSocketPort: NetworkPort {
  /// The path of the entity's socket, if the port was opened with one.
  public let path: String?
  public let macAddress: EUI48
  public let peerMacAddress: EUI48
  public let maximumInflightAecpCommands: Int

  private let _socket: _DatagramSocket
  private let _link: PointToPointLink

  /// Connects to the entity's socket at `path`, a filesystem path; abstract names (beginning
  /// with a zero byte) are not supported. The port is opened, and the entity reached once it
  /// is listening, even if it is not yet: sends fail until then.
  public convenience init(
    path: String,
    macAddress: EUI48 = UnixSocketPortLocalMacAddress,
    peerMacAddress: EUI48 = UnixSocketPortPeerMacAddress,
    maximumInflightAecpCommands: Int = 10,
    ring: IORing = .shared
  ) throws {
    let address = try _unixSocketAddress(path: path)
    let socket = try Socket(ring: ring, domain: sa_family_t(AF_UNIX), type: SOCK_DGRAM)
    // an unbound socket has no address for the entity to reply to
    try socket.bind(to: _AutobindAddress())
    let datagramSocket = _DatagramSocket(socket: socket, address: address)
    do {
      try datagramSocket.connect()
    } catch let error as Errno where error.entityIsAbsent {
      // connected by the first send once the entity is listening
    }
    self.init(
      socket: datagramSocket,
      path: path,
      macAddress: macAddress,
      peerMacAddress: peerMacAddress,
      maximumInflightAecpCommands: maximumInflightAecpCommands
    )
  }

  /// Uses `fileDescriptor`, a connected AF_UNIX datagram socket, such as one end of a
  /// `socketpair`; an unconnected socket fails with ENOTCONN. The port owns the descriptor,
  /// closing it when released, or if it cannot be used. It does not connect the socket again
  /// if the peer goes away.
  public convenience init(
    fileDescriptor: CInt,
    macAddress: EUI48 = UnixSocketPortLocalMacAddress,
    peerMacAddress: EUI48 = UnixSocketPortPeerMacAddress,
    maximumInflightAecpCommands: Int = 10,
    ring: IORing = .shared
  ) throws {
    let fileHandle: FileHandle
    do {
      fileHandle = try FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    } catch {
      Glibc.close(fileDescriptor)
      throw error
    }
    let socket = Socket(ring: ring, fileHandle: fileHandle, domain: sa_family_t(AF_UNIX))
    guard try socket.getIntegerOption(option: SO_DOMAIN) == AF_UNIX,
          try socket.getIntegerOption(option: SO_TYPE) == CInt(SOCK_DGRAM.rawValue)
    else {
      throw Errno.protocolWrongTypeForSocket
    }
    _ = try socket.peerAddress

    self.init(
      socket: _DatagramSocket(socket: socket, address: nil),
      path: nil,
      macAddress: macAddress,
      peerMacAddress: peerMacAddress,
      maximumInflightAecpCommands: maximumInflightAecpCommands
    )
  }

  private init(
    socket: _DatagramSocket,
    path: String?,
    macAddress: EUI48,
    peerMacAddress: EUI48,
    maximumInflightAecpCommands: Int
  ) {
    self.path = path
    self.macAddress = macAddress
    self.peerMacAddress = peerMacAddress
    self.maximumInflightAecpCommands = max(maximumInflightAecpCommands, 1)
    _socket = socket
    _link = PointToPointLink(
      framing: .datagram,
      read: { count in try await socket.read(count: count) },
      write: { frame in try await socket.send(frame) }
    )
  }

  deinit {
    close()
  }

  /// Stops the port: later sends and receptions fail with EBADF, and a reception in progress
  /// ends. Frames already queued are still sent. The socket itself is closed once the port is
  /// released and the requests in flight on it complete.
  public func close() {
    _link.close()
    // ends a read in progress, which then fails with EBADF
    _socket.close()
  }

  /// Sends a frame once those queued before it are sent, connecting to the entity again if it
  /// has gone away. Cancelling the send abandons the frame.
  public func send(_ packet: IEEE802Packet) async throws {
    try await _link.send(packet)
  }

  /// Receives frames until the task is cancelled or the port is closed. The peer going away
  /// does not end reception: a datagram socket has no end of stream.
  public func receive(_ handler: (IEEE802Packet) async -> ()) async throws {
    try await _link.receive(macAddress: macAddress, peerMacAddress: peerMacAddress, handler)
  }
}

/// The port's socket and its connection to the entity. Sends are made by the link's one writer
/// task, so the socket is connected again by one task at a time; reads by the one task
/// receiving, whose read in progress `close()` cancels.
private final class _DatagramSocket: Sendable {
  private let _socket: Socket
  private let _address: sockaddr_un?
  private let _isConnected = Atomic(false)
  private let _reading = Mutex<(isClosed: Bool, read: Task<[UInt8], any Error>?)>((false, nil))

  init(socket: Socket, address: sockaddr_un?) {
    _socket = socket
    _address = address
    _isConnected.store(address == nil, ordering: .relaxed)
  }

  /// Connects the socket to the entity's path, which an AF_UNIX datagram socket does at once,
  /// or fails with ENOENT or ECONNREFUSED if nothing is bound to it.
  func connect() throws {
    guard let _address else { return }
    try _socket.connect(to: _address)
    _isConnected.store(true, ordering: .relaxed)
  }

  func send(_ frame: [UInt8]) async throws {
    var hasConnected = false
    while true {
      try Task.checkCancellation()
      if !_isConnected.load(ordering: .relaxed) {
        try connect()
        hasConnected = true
      }
      do {
        // a datagram is sent whole or not at all
        try await _socket.send(frame)
        return
      } catch let error as Errno where error.isTransient {
        await Task.yield()
      } catch let error as Errno where error.entityIsAbsent && _address != nil && !hasConnected {
        // the entity has gone, and may be bound to the path again
        _isConnected.store(false, ordering: .relaxed)
      }
    }
  }

  /// One datagram, cut to `count` octets, or EBADF once the socket is closed.
  func read(count: Int) async throws -> [UInt8] {
    let read = try _reading.withLock { reading in
      guard !reading.isClosed else { throw Errno.badFileDescriptor }
      let socket = _socket
      let read = Task {
        try Task.checkCancellation()
        return try await socket.receive(count: count, timeout: nil)
      }
      reading.read = read
      return read
    }
    do {
      return try await withTaskCancellationHandler {
        try await read.value
      } onCancel: {
        read.cancel()
      }
    } catch {
      guard !_reading.withLock({ $0.isClosed }) else { throw Errno.badFileDescriptor }
      throw error
    }
  }

  func close() {
    _reading.withLock { reading in
      reading.isClosed = true
      return reading.read
    }?.cancel()
  }
}

/// A `sockaddr_un` naming `path`, a filesystem path.
private func _unixSocketAddress(path: String) throws -> sockaddr_un {
  // an abstract name begins with a zero byte, and its length is part of the address
  guard let first = path.utf8.first, first != 0 else { throw Errno.invalidArgument }
  // a path the length of sun_path would lack its terminating zero
  guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
    throw Errno.fileNameTooLong
  }
  return try sockaddr_un(family: sa_family_t(AF_UNIX), presentationAddress: path)
}

/// `sun_family` alone, which binds a socket to an abstract address the kernel chooses.
private struct _AutobindAddress: SocketAddress {
  static var family: sa_family_t { sa_family_t(AF_UNIX) }

  private var _address = sockaddr_un()

  init() {
    _address.sun_family = Self.family
  }

  init(family: sa_family_t, presentationAddress: String) throws {
    throw Errno.invalidArgument
  }

  var size: socklen_t { socklen_t(MemoryLayout<sa_family_t>.size) }

  var presentationAddress: String {
    get throws { try _address.presentationAddress }
  }

  var presentationAddressNoPort: String {
    get throws { try _address.presentationAddressNoPort }
  }

  var port: UInt16 {
    get throws { try _address.port }
  }

  func withSockAddr<R, E: Error>(
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws(E) -> R
  ) throws(E) -> R {
    let size = size
    return try _address.withSockAddr { (sa, _) throws(E) in try body(sa, size) }
  }

  mutating func withMutableSockAddr<T, E: Error>(
    _ body: (UnsafeMutablePointer<sockaddr>, socklen_t) throws(E) -> T
  ) throws(E) -> T {
    let size = size
    return try _address.withMutableSockAddr { (sa, _) throws(E) in try body(sa, size) }
  }
}

private extension Errno {
  /// Nothing is bound to the entity's path, or what was has gone: a connected datagram socket
  /// whose peer has closed fails with ECONNREFUSED, then ENOTCONN.
  var entityIsAbsent: Bool {
    self == .connectionRefused || self == .noSuchFileOrDirectory || self == .socketNotConnected
  }
}

#endif
