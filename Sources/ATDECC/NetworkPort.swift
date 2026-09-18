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
#if os(Linux)
import CLinuxSockAddr
import Glibc
import IEEE802Linux
import IORing
import IORingUtils
import NetLink
import struct SystemPackage.Errno
#endif
import Synchronization

/// A network port of an ATDECC End Station (IEEE 1722.1-2021 §3.1): the link on which AVTP
/// frames carrying ADP, AECP and ACMP are sent and received.
public protocol NetworkPort: Sendable {
  /// Source address of transmitted frames.
  var macAddress: EUI48 { get }

  /// The most AECP commands a controller keeps in flight to one entity through this port;
  /// ten, as la_avdecc has, unless the port says otherwise.
  var maximumInflightAecpCommands: Int { get }

  func send(_ packet: IEEE802Packet) async throws

  /// Receives AVTP frames addressed to this port or to the AVDECC group addresses, calling
  /// `handler` for each, until the task is cancelled or the port fails.
  func receive(_ handler: (IEEE802Packet) async -> ()) async throws

  /// As `receive(_:)`, calling `onReady` once frames that reach the port from then on will be
  /// received: a controller discovers entities then, so that their answers are not missed.
  func receive(
    onReady: () async -> (),
    _ handler: (IEEE802Packet) async -> ()
  ) async throws

  /// Calls `handler` with whether the port's link is up (linkIsUp, IEEE 1722.1-2021
  /// §6.2.7.1.5): first with its current state, then whenever it changes, until the task is
  /// cancelled or monitoring fails.
  func monitorLinkState(_ handler: (Bool) async -> ()) async throws
}

public extension NetworkPort {
  var maximumInflightAecpCommands: Int { 10 }

  /// A port that is ready to receive as soon as it exists.
  func receive(
    onReady: () async -> (),
    _ handler: (IEEE802Packet) async -> ()
  ) async throws {
    await onReady()
    try await receive(handler)
  }

  /// A port without link state, such as a point-to-point serial link, is always up.
  func monitorLinkState(_ handler: (Bool) async -> ()) async throws {
    await handler(true)
    // wait for cancellation on a stream rather than in Task.sleep, whose cancelled sleeps stay
    // enqueued, holding their task's memory, until their deadline (swiftlang/swift#60441)
    let (cancellation, continuation) = AsyncStream<Never>.makeStream()
    await withTaskCancellationHandler {
      for await _ in cancellation {}
    } onCancel: {
      continuation.finish()
    }
  }
}

#if os(Linux)

// the link is operationally up
let _interfaceRunningFlag = UInt32(IFF_RUNNING)

/// An Ethernet network port, using raw AF_PACKET sockets driven by io_uring. It joins the
/// AVDECC multicast groups rather than using promiscuous mode, so frames reach it through
/// bridges that filter multicast in hardware.
public struct EthernetPort: NetworkPort {
  /// The interface as last resolved from its name.
  private final class Resolution: Sendable {
    let port: Mutex<RawEthernetPort>

    init(_ port: RawEthernetPort) {
      self.port = Mutex(port)
    }
  }

  public let interfaceName: String
  /// The interface's address when the port was opened.
  public let macAddress: EUI48
  private let _resolution: Resolution

  public init(interfaceName: String) throws {
    let port = try RawEthernetPort(name: interfaceName)
    self.interfaceName = interfaceName
    macAddress = port.interface.macAddress
    _resolution = Resolution(port)
  }

  public func send(_ packet: IEEE802Packet) async throws {
    try await _resolution.port.withLock { $0 }.send(packet)
  }

  public func receive(_ handler: (IEEE802Packet) async -> ()) async throws {
    try await receive(onReady: {}, handler)
  }

  /// Each reception resolves the interface again: one that is removed and added again, as a
  /// USB adapter or a virtual interface can be, has a new index.
  public func receive(
    onReady: () async -> (),
    _ handler: (IEEE802Packet) async -> ()
  ) async throws {
    let port = try RawEthernetPort(name: interfaceName)
    // frames are sent from, and entity IDs derived from, the address the port was opened with;
    // under another, unicast responses would never arrive, so fail where it can be seen
    guard _isEqualMacAddress(port.interface.macAddress, macAddress) else {
      throw Errno.addressNotAvailable
    }
    _resolution.port.withLock { $0 = port }
    // stream data shares the EtherType, and would crowd ATDECC out of the receive queue
    let packets = try await port.receivePackets(
      etherTypes: [AvtpEtherType],
      groupAddresses: [AvdeccMulticastMacAddress, AvdeccIdentifyMulticastMacAddress],
      subtypes: [AvtpEtherType: [AvtpSubtype.adp.rawValue...AvtpSubtype.acmp.rawValue]]
    )
    await onReady()
    for try await packet in packets {
      await handler(packet)
    }
  }

  /// Monitors the interface's operational state with rtnetlink link notifications.
  public func monitorLinkState(_ handler: (Bool) async -> ()) async throws {
    try await _monitorLinkState(
      interfaceName: interfaceName,
      interfaceIndex: { _resolution.port.withLock { $0.interface.index } },
      subscribe: _subscribeToLinkNotifications,
      isInterfaceRunning: _isInterfaceRunning(name:),
      handler: handler
    )
  }
}

/// A link notification from rtnetlink.
enum LinkNotification: Equatable, Sendable {
  /// RTM_NEWLINK: an interface was added or changed; `flags` are its ifi_flags.
  case newLink(interfaceIndex: Int, flags: UInt32)
  /// RTM_DELLINK: an interface was removed.
  case deleteLink(interfaceIndex: Int)

  var interfaceIndex: Int {
    switch self {
    case let .newLink(interfaceIndex, _), let .deleteLink(interfaceIndex):
      interfaceIndex
    }
  }
}

/// Subscribes to rtnetlink link notifications.
private func _subscribeToLinkNotifications() throws
  -> some AsyncSequence<LinkNotification, any Error>
{
  let socket = try NLSocket(protocol: NETLINK_ROUTE)
  try socket.subscribeLinks()
  return socket.notifications.compactMap { notification -> LinkNotification? in
    // the sequence keeps the socket, and hence its subscription, alive
    _ = socket
    return switch notification as? RTNLLinkMessage {
    case let .new(link):
      .newLink(interfaceIndex: link.index, flags: UInt32(truncatingIfNeeded: link.flags))
    case let .del(link):
      .deleteLink(interfaceIndex: link.index)
    case nil:
      nil
    }
  }
}

/// Follows an interface's operational state from link notifications: reports it once subscribed,
/// so that no change is missed, then whenever it changes.
///
/// The state is read again with `isInterfaceRunning` after each notification rather than taken
/// from it, so that a change whose notification was lost, or one of an interface removed and added
/// again under a new index, is not missed. An interface that no longer exists is down; the
/// notifications for `interfaceIndex` decide only when the state cannot be read. Notifications
/// that fail after any have been received (the socket overran, say) are subscribed to again, and
/// the state read afresh; a subscription that fails before delivering any throws.
func _monitorLinkState<Notifications: AsyncSequence>(
  interfaceName: String,
  interfaceIndex: () -> Int,
  subscribe: () throws -> Notifications,
  isInterfaceRunning: (String) throws -> Bool?,
  handler: (Bool) async -> ()
) async throws where Notifications.Element == LinkNotification {
  var isUp: Bool?
  func report(_ isRunning: Bool) async {
    guard isRunning != isUp else { return }
    isUp = isRunning
    await handler(isRunning)
  }

  while !Task.isCancelled {
    let notifications = try subscribe()
    await report(try isInterfaceRunning(interfaceName) ?? false)
    var hasReceived = false
    do {
      for try await notification in notifications {
        hasReceived = true
        var isRunning: Bool?
        if notification.interfaceIndex == interfaceIndex() {
          switch notification {
          case let .newLink(_, flags):
            isRunning = flags & _interfaceRunningFlag != 0
          case .deleteLink:
            isRunning = false
          }
        }
        do {
          isRunning = try isInterfaceRunning(interfaceName) ?? false
        } catch {
          // the notified state, if any, stands
        }
        if let isRunning {
          await report(isRunning)
        }
      }
      return
    } catch {
      guard hasReceived, !Task.isCancelled else { throw error }
    }
  }
}

/// Whether the interface is operationally up, or nil if there is no such interface.
private func _isInterfaceRunning(name: String) throws -> Bool? {
  let fd = socket(CInt(AF_PACKET), Int32(SOCK_DGRAM.rawValue), 0)
  guard fd >= 0 else { throw Errno(rawValue: errno) }
  defer { close(fd) }

  var ifr = ifreq()
  withUnsafeMutableBytes(of: &ifr.ifr_ifrn.ifrn_name) { buffer in
    for (i, byte) in name.utf8.prefix(Int(IFNAMSIZ) - 1).enumerated() {
      buffer[i] = byte
    }
  }
  guard ioctl(fd, UInt(SIOCGIFFLAGS), &ifr) == 0 else {
    guard errno != ENODEV else { return nil }
    throw Errno(rawValue: errno)
  }
  return UInt32(UInt16(bitPattern: ifr.ifr_ifru.ifru_flags)) & _interfaceRunningFlag != 0
}

#endif

/// An in-memory Ethernet segment connecting virtual ports, for tests and simulation. A frame
/// is delivered to every other port whose address matches its destination, or to all of them
/// for group addresses.
public final class VirtualNetwork: Sendable {
  private struct State {
    var nextID = 0
    var ports = [Int: VirtualPort]()
  }

  private let _state = Mutex(State())

  public init() {}

  /// Attaches a new port with `macAddress` to the network.
  public func makePort(macAddress: EUI48) -> VirtualPort {
    _state.withLock { state in
      let port = VirtualPort(network: self, id: state.nextID, macAddress: macAddress)
      state.ports[state.nextID] = port
      state.nextID += 1
      return port
    }
  }

  fileprivate func deliver(_ packet: IEEE802Packet, from senderID: Int) {
    let recipients = _state.withLock { state in
      state.ports.filter { id, port in
        id != senderID && (
          _isMulticast(macAddress: packet.destMacAddress) ||
            _isEqualMacAddress(packet.destMacAddress, port.macAddress)
        )
      }.values
    }
    for recipient in recipients {
      recipient.enqueue(packet)
    }
  }

  fileprivate func remove(_ id: Int) {
    _ = _state.withLock { $0.ports.removeValue(forKey: id) }
  }
}

/// A port on a `VirtualNetwork`.
///
/// While its link is down the port neither sends nor receives frames, and reception ends with
/// ENETDOWN, as it does on an AF_PACKET socket. Tests can also end reception, or hold sends, to
/// reproduce a failing or congested port.
public final class VirtualPort: NetworkPort {
  private typealias Receiver = AsyncThrowingStream<IEEE802Packet, any Error>.Continuation

  /// How the next reception ends, when it is ended before it begins.
  private enum ReceiveEnd {
    case finished
    case failed(any Error)
  }

  private struct State {
    var isLinkUp = true
    var isClosed = false
    var nextMonitorID = 0
    var monitors = [Int: AsyncStream<Bool>.Continuation]()
    var nextReceiverID = 0
    var receivers = [Int: Receiver]()
    /// frames that arrived while nothing was receiving, for the next reception
    var pendingPackets = [IEEE802Packet]()
    var pendingReceiveEnd: ReceiveEnd?
    var areSendsBlocked = false
    var nextBlockedSendID = 0
    var blockedSends = [Int: CheckedContinuation<(), any Error>]()
  }

  public let macAddress: EUI48
  private let _state = Mutex(State())
  private let _id: Int
  private weak let _network: VirtualNetwork?

  fileprivate init(network: VirtualNetwork, id: Int, macAddress: EUI48) {
    _network = network
    _id = id
    self.macAddress = macAddress
  }

  deinit {
    close()
  }

  /// Detaches the port from its network and ends reception.
  public func close() {
    _network?.remove(_id)
    let (receivers, monitors, blockedSends) = _state.withLock { state in
      state.isClosed = true
      state.pendingPackets = []
      defer {
        state.receivers = [:]
        state.monitors = [:]
        state.blockedSends = [:]
      }
      return (state.receivers.values, state.monitors.values, state.blockedSends.values)
    }
    for receiver in receivers {
      receiver.finish()
    }
    for monitor in monitors {
      monitor.finish()
    }
    for send in blockedSends {
      send.resume()
    }
  }

  public var isLinkUp: Bool {
    _state.withLock { $0.isLinkUp }
  }

  /// Simulates the port's link going down or coming up. Frames sent or arriving while it is
  /// down are dropped, and reception ends with ENETDOWN.
  public func setLinkUp(_ isUp: Bool) {
    let receivers = _state.withLock { state -> [Receiver] in
      guard state.isLinkUp != isUp else { return [] }
      state.isLinkUp = isUp
      for monitor in state.monitors.values {
        monitor.yield(isUp)
      }
      guard !isUp else { return [] }
      state.pendingPackets = []
      defer { state.receivers = [:] }
      return Array(state.receivers.values)
    }
    for receiver in receivers {
      receiver.finish(throwing: _linkDownError)
    }
  }

  /// Ends reception with `error`, or the next reception if none is in progress.
  public func failReceive(with error: any Error) {
    _endReceive(.failed(error))
  }

  /// Ends reception as if the port had no more frames, or ends the next reception if none is
  /// in progress.
  public func finishReceive() {
    _endReceive(.finished)
  }

  private func _endReceive(_ end: ReceiveEnd) {
    let receivers = _state.withLock { state -> [Receiver] in
      guard !state.receivers.isEmpty else {
        state.pendingReceiveEnd = end
        return []
      }
      defer { state.receivers = [:] }
      return Array(state.receivers.values)
    }
    for receiver in receivers {
      switch end {
      case .finished: receiver.finish()
      case let .failed(error): receiver.finish(throwing: error)
      }
    }
  }

  /// Holds sends until they are released, as a congested or stalled transmitter does. A held
  /// send can be cancelled.
  public func setSendsBlocked(_ isBlocked: Bool) {
    let released = _state.withLock { state -> [CheckedContinuation<(), any Error>] in
      state.areSendsBlocked = isBlocked
      guard !isBlocked else { return [] }
      defer { state.blockedSends = [:] }
      return state.blockedSends.sorted { $0.key < $1.key }.map(\.value)
    }
    for send in released {
      send.resume()
    }
  }

  public func monitorLinkState(_ handler: (Bool) async -> ()) async throws {
    let (states, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .unbounded)
    let id = _state.withLock { state in
      let id = state.nextMonitorID
      state.nextMonitorID += 1
      state.monitors[id] = continuation
      continuation.yield(state.isLinkUp)
      if state.isClosed {
        continuation.finish()
      }
      return id
    }
    defer {
      _ = _state.withLock { $0.monitors.removeValue(forKey: id) }
    }
    for await isUp in states {
      await handler(isUp)
    }
  }

  public func send(_ packet: IEEE802Packet) async throws {
    try await _waitUntilSendsAreReleased()
    guard isLinkUp else { return }
    _network?.deliver(packet, from: _id)
  }

  private func _waitUntilSendsAreReleased() async throws {
    guard _state.withLock({ $0.areSendsBlocked }) else { return }
    let id = _state.withLock { state in
      defer { state.nextBlockedSendID += 1 }
      return state.nextBlockedSendID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(), any Error>) in
        let isHeld = _state.withLock { state in
          // cancellation is checked under the lock, so that a cancel either finds the send
          // held or has already been seen here
          guard state.areSendsBlocked, !state.isClosed, !Task.isCancelled else { return false }
          state.blockedSends[id] = continuation
          return true
        }
        guard !isHeld else { return }
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          continuation.resume()
        }
      }
    } onCancel: {
      let continuation = _state.withLock { $0.blockedSends.removeValue(forKey: id) }
      continuation?.resume(throwing: CancellationError())
    }
  }

  public func receive(_ handler: (IEEE802Packet) async -> ()) async throws {
    try await receive(onReady: {}, handler)
  }

  public func receive(
    onReady: () async -> (),
    _ handler: (IEEE802Packet) async -> ()
  ) async throws {
    let (packets, receiver) = AsyncThrowingStream<IEEE802Packet, any Error>
      .makeStream(bufferingPolicy: .unbounded)
    let id: Int? = try _state.withLock { state in
      if let end = state.pendingReceiveEnd {
        state.pendingReceiveEnd = nil
        switch end {
        case .finished: return nil
        case let .failed(error): throw error
        }
      }
      guard !state.isClosed else { return nil }
      // as binding an AF_PACKET socket to an interface that is down does
      guard state.isLinkUp else { throw _linkDownError }
      for packet in state.pendingPackets {
        receiver.yield(packet)
      }
      state.pendingPackets = []
      let id = state.nextReceiverID
      state.nextReceiverID += 1
      state.receivers[id] = receiver
      return id
    }
    guard let id else { return }
    defer {
      _ = _state.withLock { $0.receivers.removeValue(forKey: id) }
    }
    await onReady()
    for try await packet in packets where packet.etherType == AvtpEtherType {
      await handler(packet)
    }
  }

  fileprivate func enqueue(_ packet: IEEE802Packet) {
    _state.withLock { state in
      guard state.isLinkUp, !state.isClosed else { return }
      guard !state.receivers.isEmpty else {
        state.pendingPackets.append(packet)
        return
      }
      for receiver in state.receivers.values {
        receiver.yield(packet)
      }
    }
  }
}

#if os(Linux)
private var _linkDownError: any Error {
  Errno.networkDown
}
#else
private struct LinkDownError: Error {}
private var _linkDownError: any Error {
  LinkDownError()
}
#endif
