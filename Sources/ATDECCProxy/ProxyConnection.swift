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

import ATDECC
import IEEE802
import Logging
import Synchronization

/// Messages queued for an APC beyond which it is not keeping up, and its connection is closed.
let AppOutputCapacity = 256
/// Frames queued for the network port, or events for a connection, beyond which more are
/// dropped, as a congested LAN drops them.
private let _layer2OutputCapacity = 256
private let _eventCapacity = 1024

/// One APC's connection, whatever carries it: its APS state machine (IEEE 1722.1-2021 Clause
/// C.5.2), driven by what the transport delivers from the APC, the network port, the port's link
/// and a one-second clock (Clause C.5.2.1.4), handled one at a time.
///
/// The transport feeds `deliver(_:)` and `apcClosed(closeCode:)`, and writes `output` to the
/// APC until it ends. The HTTP response that starts the transfer (or refuses it) is the
/// transport's: a connection exists only for an accepted request.
final class AtdeccProxyConnection<Port: NetworkPort>: Sendable {
  enum Output: Sendable {
    case appdu(Appdu)
    /// A WebSocket pong, with the ping's payload.
    case pong([UInt8])
    /// The connection is closing; for a WebSocket, the close status to send, if any.
    case close(closeCode: UInt16?)
  }

  private enum Event: Sendable {
    case apc(Appdu)
    case apcClosed(closeCode: UInt16?)
    case layer2(IEEE802Packet)
    case link(Bool)
    case tick
  }

  /// What to write to the APC, in order; it ends after `.close`.
  let output: AsyncStream<Output>
  private let outputSink: AsyncStream<Output>.Continuation
  private let events: AsyncStream<Event>
  private let eventSink: AsyncStream<Event>.Continuation
  private let port: Port
  private let entityIDs: AtdeccProxyEntityIDs
  private let logger: Logger
  /// Called when the APC has stopped reading, to end the connection at once.
  private let abort = Mutex<(@Sendable () -> ())?>(nil)

  init(port: Port, entityIDs: AtdeccProxyEntityIDs, logger: Logger) {
    (output, outputSink) = AsyncStream<Output>.makeStream(bufferingPolicy: .bufferingOldest(AppOutputCapacity))
    (events, eventSink) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(_eventCapacity))
    self.port = port
    self.entityIDs = entityIDs
    self.logger = logger
  }

  /// How the transport ends the connection when the APC stops reading what is sent to it.
  func onAbort(_ body: @escaping @Sendable () -> ()) {
    abort.withLock { $0 = body }
  }

  /// An APPDU from the APC.
  func deliver(_ appdu: Appdu) {
    eventSink.yield(.apc(appdu))
  }

  /// A WebSocket ping from the APC, answered in order with what else is sent.
  func pong(_ payload: [UInt8]) {
    outputSink.yield(.pong(payload))
  }

  /// The APC's end has closed; for a WebSocket, the close status to answer with, if any.
  func apcClosed(closeCode: UInt16?) async {
    // the end must not be lost to a full queue while the connection is still driven
    while case .dropped = eventSink.yield(.apcClosed(closeCode: closeCode)) {
      await Task.yield()
    }
  }

  /// Runs the connection until CLOSED, then ends `output`.
  func run() async {
    let (layer2Output, layer2Sink) = AsyncStream<IEEE802Packet>.makeStream(bufferingPolicy: .bufferingOldest(_layer2OutputCapacity))
    let key = entityIDs.makeConnection()
    defer { entityIDs.release(key) }
    await withTaskGroup { group in
      group.addTask { [self] in await writeLayer2(layer2Output) }
      group.addTask { [self] in await monitorLink() }
      group.addTask { [self] in await receiveLayer2() }
      group.addTask { [self] in await tick() }
      await drive(key: key, layer2Sink)
      outputSink.finish()
      layer2Sink.finish()
      eventSink.finish()
      group.cancelAll()
    }
  }

  /// The state machine, from the accepted request on; ends at CLOSED.
  private func drive(key: Int, _ layer2: AsyncStream<IEEE802Packet>.Continuation) async {
    let start = ContinuousClock.now
    var currentTime: UInt64 { UInt64(max((ContinuousClock.now - start).components.seconds, 0)) }
    var iterator = events.makeAsyncIterator()
    // START_TRANSFER reports the link status, so learn it first
    var linkStatus = false
    var pending = [Event]()
    while let event = await iterator.next() {
      if case .apcClosed = event { return close(closeCode: nil) }
      if case let .link(isUp) = event {
        linkStatus = isUp
        break
      }
      pending.append(event)
    }
    var machine = AtdeccProxyServerStateMachine(linkMacAddress: port.macAddress, linkStatus: linkStatus) {
      [entityIDs] _, requested in entityIDs.assign(key, requested: requested)
    }
    var closeCode: UInt16? = 1000
    guard perform(machine.requestReceived(200, at: currentTime), key: key, closeCode, layer2) else { return }
    for event in pending {
      guard perform(handle(event, &machine, &closeCode, at: currentTime), key: key, closeCode, layer2) else { return }
    }
    while let event = await iterator.next() {
      guard perform(handle(event, &machine, &closeCode, at: currentTime), key: key, closeCode, layer2) else { return }
    }
  }

  private func handle(
    _ event: Event,
    _ machine: inout AtdeccProxyServerStateMachine,
    _ closeCode: inout UInt16?,
    at currentTime: UInt64
  ) -> [AtdeccProxyServerStateMachine.Action] {
    switch event {
    case let .apc(appdu):
      let actions = machine.apcMessageReceived(appdu, at: currentTime)
      if appdu.messageType == .entityIDRequest, let id = machine.assignedEntityID {
        logger.debug("ATDECC proxy assigned entity ID \(id)")
      }
      return actions
    case let .apcClosed(code):
      closeCode = code
      return machine.close()
    case let .layer2(packet):
      entityIDs.observe(packet.payload)
      return machine.layer2FrameReceived(packet, at: currentTime)
    case let .link(isUp):
      return machine.linkStatusChanged(isUp, at: currentTime)
    case .tick:
      return machine.timeAdvanced(to: currentTime)
    }
  }

  /// Performs `actions`; false once the connection is to close. An APC whose messages back up
  /// is not reading them, and its connection is ended.
  private func perform(
    _ actions: [AtdeccProxyServerStateMachine.Action],
    key: Int,
    _ closeCode: UInt16?,
    _ layer2: AsyncStream<IEEE802Packet>.Continuation
  ) -> Bool {
    for action in actions {
      switch action {
      case .sendHttpResponse:
        // the transport has answered the request already
        break
      case let .sendToApc(appdu):
        if case .dropped = outputSink.yield(.appdu(appdu)) {
          logger.notice("ATDECC proxy closing a connection whose APC is not reading")
          abort.withLock { $0 }?()
          return false
        }
      case let .sendToLayer2(packet):
        entityIDs.observe(packet.payload, sentBy: key)
        if case .dropped = layer2.yield(packet) {
          logger.trace("ATDECC proxy dropped a frame for the LAN")
        }
      case .closeConnection:
        close(closeCode: closeCode)
        return false
      }
    }
    return true
  }

  private func close(closeCode: UInt16?) {
    outputSink.yield(.close(closeCode: closeCode))
  }

  /// Frames for the network port, sent in order; one that fails is dropped, as on a LAN.
  private func writeLayer2(_ output: AsyncStream<IEEE802Packet>) async {
    for await packet in output {
      do {
        try await port.send(packet)
      } catch {
        logger.debug("ATDECC proxy could not send a frame: \(error)")
      }
    }
  }

  private func receiveLayer2() async {
    while !Task.isCancelled {
      do {
        try await port.receive { [eventSink] packet in eventSink.yield(.layer2(packet)) }
      } catch {
        logger.trace("ATDECC proxy reception ended: \(error)")
      }
      // a port whose link is down fails until it comes up again
      try? await Task.sleep(for: .seconds(1))
    }
  }

  private func monitorLink() async {
    do {
      try await port.monitorLinkState { [eventSink] isUp in eventSink.yield(.link(isUp)) }
    } catch {
      logger.warning("ATDECC proxy cannot follow the link state: \(error)")
      eventSink.yield(.link(true))
    }
  }

  private func tick() async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      eventSink.yield(.tick)
    }
  }
}
