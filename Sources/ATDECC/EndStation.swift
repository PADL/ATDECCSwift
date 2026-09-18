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

import BinaryParsing
import IEEE802
import Logging

/// Failures of an end station.
public enum EndStationError: Error, Sendable, Equatable {
  /// The end station has been closed.
  case closed
  /// An entity with this ID already exists on the end station.
  case duplicateEntityID(UniqueIdentifier)
  /// Every dynamic entity ID for this port is in use.
  case noDynamicEntityIDAvailable
  /// The entity ID was not issued by `makeDynamicEntityID()`.
  case invalidDynamicEntityID(UniqueIdentifier)
  case invalidMacAddress
}

/// Ethernet destination of a raw PDU.
public enum PduDestination: Sendable {
  /// The AVDECC multicast address used by ADP and ACMP (IEEE 1722.1-2021 Annex B).
  case multicast
  case unicast(EUI48)
}

// Frames shorter than this are padded, as some drivers do not pad raw sends themselves.
private let _ethernetMinimumPayloadLength = 46
// Delays before receiving again on a port that stopped, doubling while it receives nothing.
private let _receiveRetryDelay = Duration.milliseconds(100)...Duration.seconds(5)
// The program-specific part of a dynamic entity ID; 0 and 0xFFFF are avoided.
private let _dynamicEntityIDRange: ClosedRange<UInt16> = 1...0xFFFD

/// An ATDECC End Station (IEEE 1722.1-2021 §3.1): a device with a network port and the
/// ATDECC entities on it. The end station sends and receives AVDECC PDUs on the port and
/// dispatches those it receives to its entities.
public actor EndStation<Port: NetworkPort> {
  private struct ControllerReference {
    weak var controller: Controller<Port>?
  }

  public nonisolated let port: Port
  public nonisolated let logger: Logger

  private var _controllers = [UniqueIdentifier: ControllerReference]()
  private var _dynamicEntityIDs = Set<UInt16>()
  private var _receiveTask: Task<(), Never>?
  private var _linkStateTask: Task<(), Never>?
  private var _isClosed = false

  public init(port: Port, logger: Logger = Logger(label: "com.padl.AVDECCSwift")) {
    self.port = port
    self.logger = logger
  }

  deinit {
    _receiveTask?.cancel()
    _linkStateTask?.cancel()
  }

  public nonisolated var macAddress: EUI48 {
    port.macAddress
  }

  /// Stops receiving; entities on the end station stop receiving PDUs. Idempotent.
  public func close() {
    _isClosed = true
    _receiveTask?.cancel()
    _receiveTask = nil
    _linkStateTask?.cancel()
    _linkStateTask = nil
    _controllers = [:]
  }

  // MARK: - Entity IDs

  /// Returns an entity ID derived from the port's MAC address (IEEE 1722.1-2021 §6.2.1.8)
  /// that no other dynamic ID on this end station is using. Release it with
  /// `releaseDynamicEntityID(_:)`.
  public func makeDynamicEntityID() throws -> UniqueIdentifier {
    guard _dynamicEntityIDs.count < _dynamicEntityIDRange.count else {
      throw EndStationError.noDynamicEntityIDAvailable
    }
    var programID: UInt16
    repeat {
      programID = UInt16.random(in: _dynamicEntityIDRange)
    } while _dynamicEntityIDs.contains(programID)
    _dynamicEntityIDs.insert(programID)
    return UniqueIdentifier((UInt64(eui48: macAddress) << 16) | UInt64(programID))
  }

  public func releaseDynamicEntityID(_ entityID: UniqueIdentifier) throws {
    guard entityID.rawValue >> 16 == UInt64(eui48: macAddress),
          _dynamicEntityIDs.remove(UInt16(truncatingIfNeeded: entityID.rawValue)) != nil
    else {
      throw EndStationError.invalidDynamicEntityID(entityID)
    }
  }

  // MARK: - Entities

  func register(_ controller: Controller<Port>) throws {
    guard !_isClosed else { throw EndStationError.closed }
    guard _controllers[controller.entityID]?.controller == nil else {
      throw EndStationError.duplicateEntityID(controller.entityID)
    }
    _controllers[controller.entityID] = ControllerReference(controller: controller)
    _startMonitoringLinkState()
  }

  func unregister(_ entityID: UniqueIdentifier) {
    _controllers[entityID] = nil
  }

  private var _liveControllers: [Controller<Port>] {
    _controllers.values.compactMap(\.controller)
  }

  // MARK: - Transmit

  /// Sends a raw PDU. Commands sent this way are not tracked: use a `Controller` to send
  /// commands and await their responses.
  public nonisolated func send(_ pdu: AvdeccPdu, to destination: PduDestination) async throws {
    switch destination {
    case .multicast:
      try await send(pdu, to: AvdeccMulticastMacAddress)
    case let .unicast(macAddress):
      try await send(pdu, to: macAddress)
    }
  }

  nonisolated func send(_ pdu: AvdeccPdu, to destination: EUI48) async throws {
    var payload = SerializationContext()
    payload.reserveCapacity(max(pdu.serializedLength, _ethernetMinimumPayloadLength))
    try pdu.serialize(into: &payload)
    if payload.position < _ethernetMinimumPayloadLength {
      payload.serialize(repeating: 0, count: _ethernetMinimumPayloadLength - payload.position)
    }
    try await port.send(IEEE802Packet(
      destMacAddress: destination,
      tci: nil,
      sourceMacAddress: macAddress,
      etherType: AvtpEtherType,
      payload: payload.bytes
    ))
  }

  // MARK: - Receive

  /// Receives on the port while its link is up, receiving again whenever reception ends: a port
  /// can stop receiving (an AF_PACKET socket fails with ENETDOWN when its interface goes down, a
  /// serial device with EIO when it hangs up), and the entities on the end station would
  /// otherwise hear nothing more. A port that keeps failing, such as a serial device that has
  /// gone, is tried again ever less often, and reported to the entities once.
  private func _startReceiving() {
    guard !_isClosed, _receiveTask == nil else { return }
    let port = port
    _receiveTask = Task { [weak self] in
      var retryDelay: Duration?
      while !Task.isCancelled {
        var failure: (any Error)?
        var hasReceived = false
        do {
          try await port.receive { packet in
            hasReceived = true
            await self?._handle(packet)
          }
        } catch {
          failure = error
        }
        guard !Task.isCancelled, let self else { return }
        if hasReceived { retryDelay = nil }
        await _receiveEnded(failure: failure, isRepeated: retryDelay != nil)
        let delay = retryDelay.map { min($0 * 2, _receiveRetryDelay.upperBound) } ??
          _receiveRetryDelay.lowerBound
        retryDelay = delay
        try? await Task.sleep(for: delay)
      }
    }
  }

  private func _stopReceiving() {
    _receiveTask?.cancel()
    _receiveTask = nil
  }

  private func _startMonitoringLinkState() {
    guard !_isClosed, _linkStateTask == nil else { return }
    let port = port
    _linkStateTask = Task { [weak self] in
      do {
        try await port.monitorLinkState { isUp in
          await self?._handleLinkState(isUp)
        }
      } catch {
        await self?._linkStateMonitoringFailed(error)
      }
    }
  }

  private func _handleLinkState(_ isUp: Bool) async {
    logger.debug("end station \(_macAddressToString(macAddress)): link \(isUp ? "up" : "down")")
    if isUp {
      _startReceiving()
    } else {
      _stopReceiving()
    }
    for controller in _liveControllers {
      await controller._handleLinkState(isUp: isUp)
    }
  }

  /// Without link state, the link is taken to be up, so that the end station still receives.
  private func _linkStateMonitoringFailed(_ error: any Error) {
    guard !Task.isCancelled, !_isClosed else { return }
    logger.warning("end station \(_macAddressToString(macAddress)): cannot monitor link state: \(error)")
    _startReceiving()
  }

  /// `isRepeated` if nothing has been received since reception last ended.
  private func _receiveEnded(failure: (any Error)?, isRepeated: Bool) async {
    guard !_isClosed else { return }
    let reason = failure.map { "receive failed: \($0)" } ?? "reception ended"
    guard !isRepeated else {
      logger.debug("end station \(_macAddressToString(macAddress)): \(reason)")
      return
    }
    logger.error("end station \(_macAddressToString(macAddress)): \(reason)")
    for controller in _liveControllers {
      await controller._handleTransportError()
    }
  }

  private func _handle(_ packet: IEEE802Packet) async {
    guard packet.etherType == AvtpEtherType else { return }

    let pdu: AvdeccPdu
    do {
      pdu = try packet.payload.withParserSpan { try AvdeccPdu(parsing: &$0) }
    } catch {
      logger.trace("ignoring malformed PDU from \(_macAddressToString(packet.sourceMacAddress)): \(error)")
      return
    }

    switch pdu {
    case let .adp(adpdu):
      // our own entities' advertisements are not discoveries
      guard adpdu.messageType == .entityDiscover || _controllers[adpdu.entityID]?.controller == nil
      else { return }
      for controller in _liveControllers {
        await controller._handle(adpdu, from: packet.sourceMacAddress)
      }
    case let .aecp(aecpdu):
      for controller in _liveControllers {
        await controller._handle(aecpdu, from: packet.sourceMacAddress)
      }
    case let .acmp(acmpdu):
      for controller in _liveControllers {
        await controller._handle(acmpdu)
      }
    }
  }
}
