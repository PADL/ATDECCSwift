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
import BinaryParsing
import IEEE802
import Synchronization
import XCTest

private let controllerMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]
private let entityMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
private let controllerEntityID = UniqueIdentifier(0x0200_00FF_FE00_0001)
private let entityID = UniqueIdentifier(0x0200_00FF_FE00_0002)
private let entityName = "Fake Entity"

private func be16(_ value: UInt16) -> [UInt8] {
  [UInt8(value >> 8), UInt8(value & 0xFF)]
}

private func be32(_ value: UInt32) -> [UInt8] {
  be16(UInt16(value >> 16)) + be16(UInt16(value & 0xFFFF))
}

private func be64(_ value: UInt64) -> [UInt8] {
  be32(UInt32(value >> 32)) + be32(UInt32(value & 0xFFFF_FFFF))
}

private func fixedString(_ string: String) -> [UInt8] {
  let bytes = Array(string.utf8)
  return bytes + [UInt8](repeating: 0, count: AvdeccFixedStringLength - bytes.count)
}

/// The ENTITY descriptor, including descriptor_type and descriptor_index.
private let entityDescriptor: [UInt8] = be16(DescriptorType.entity.rawValue) + be16(0) +
  be64(entityID.rawValue) + be64(0x0200_0000_0000_0042) +
  be32(EntityCapabilities.aemSupported.rawValue) + be16(0) + be16(0) + be16(1) + be16(0x4001) +
  be32(0) + be32(1) + be64(0) + fixedString(entityName) + be16(0xFFFF) + be16(0xFFFF) +
  fixedString("1.0") + fixedString("") + fixedString("") + be16(1) + be16(0)

/// A minimal ATDECC entity on a virtual network, answering the commands these tests send.
private final class FakeEntity: Sendable {
  struct Behaviour {
    var commandsToDrop = 0
    var inProgressResponses = 0
    var status = AemStatus.success
  }

  let port: VirtualPort
  let behaviour = Mutex(Behaviour())
  /// Every PDU received, in order.
  let received = Mutex([AvdeccPdu]())
  private let _availableIndex = Mutex(UInt32(0))
  private let _task = Mutex<Task<(), Never>?>(nil)

  init(network: VirtualNetwork) {
    port = network.makePort(macAddress: entityMacAddress)
    let task = Task { [port] in
      _ = try? await port.receive { [weak self] packet in
        await self?._handle(packet)
      }
    }
    _task.withLock { $0 = task }
  }

  func stop() {
    _task.withLock { $0?.cancel() }
    port.close()
  }

  func send(_ pdu: AvdeccPdu, to destination: EUI48) async throws {
    try await port.send(IEEE802Packet(
      destMacAddress: destination,
      tci: nil,
      sourceMacAddress: entityMacAddress,
      etherType: AvtpEtherType,
      payload: pdu.serialized()
    ))
  }

  func advertise(_ messageType: AdpMessageType = .entityAvailable) async throws {
    let availableIndex = _availableIndex.withLock { index in
      defer { index += 1 }
      return index
    }
    try await send(.adp(Adpdu(
      messageType: messageType,
      validTime: 10,
      entityID: entityID,
      entityCapabilities: .aemSupported,
      listenerStreamSinks: 1,
      listenerCapabilities: [.implemented, .audioSink],
      availableIndex: availableIndex
    )), to: AvdeccMulticastMacAddress)
  }

  func sendUnsolicited(_ commandType: AemCommandType, data: [UInt8]) async throws {
    try await send(.aecp(.aem(AemAecpdu(
      isResponse: true,
      targetEntityID: entityID,
      controllerEntityID: controllerEntityID,
      unsolicited: true,
      commandType: commandType,
      commandSpecificData: data
    ))), to: controllerMacAddress)
  }

  /// Returns the first PDU received that matches `predicate`, waiting up to `timeout`.
  func firstReceived(
    timeout: Duration = .seconds(2),
    where predicate: (AvdeccPdu) -> Bool
  ) async -> AvdeccPdu? {
    let deadline = ContinuousClock.now + timeout
    repeat {
      if let pdu = received.withLock({ $0.first(where: predicate) }) {
        return pdu
      }
      try? await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    return nil
  }

  func receivedCount(where predicate: (AvdeccPdu) -> Bool) -> Int {
    received.withLock { $0.count(where: predicate) }
  }

  private func _handle(_ packet: IEEE802Packet) async {
    guard let pdu = try? packet.payload.withParserSpan({ try AvdeccPdu(parsing: &$0) }) else {
      return
    }
    received.withLock { $0.append(pdu) }
    switch pdu {
    case let .adp(adpdu) where adpdu.messageType == .entityDiscover:
      try? await advertise()
    case let .aecp(.aem(aem)) where !aem.isResponse && aem.targetEntityID == entityID:
      await _handleCommand(aem, from: packet.sourceMacAddress)
    case let .acmp(acmpdu) where acmpdu.messageType == .connectRxCommand &&
      acmpdu.listenerEntityID == entityID:
      var response = acmpdu
      response.messageType = .connectRxResponse
      response.connectionCount = 1
      try? await send(.acmp(response), to: AvdeccMulticastMacAddress)
    default:
      break
    }
  }

  private func _handleCommand(_ command: AemAecpdu, from source: EUI48) async {
    let (drop, inProgressResponses, status) = behaviour.withLock { behaviour in
      guard behaviour.commandsToDrop == 0 else {
        behaviour.commandsToDrop -= 1
        return (true, 0, behaviour.status)
      }
      return (false, behaviour.inProgressResponses, behaviour.status)
    }
    guard !drop else { return }

    var response = command
    response.isResponse = true
    for _ in 0..<inProgressResponses {
      response.status = UInt8(AemStatus.inProgress.rawValue)
      try? await send(.aecp(.aem(response)), to: source)
      try? await Task.sleep(for: .milliseconds(120))
    }

    response.status = UInt8(status.rawValue)
    if status == .success, command.commandType == .readDescriptor {
      response.commandSpecificData = be16(0) + be16(0) + entityDescriptor
    }
    try? await send(.aecp(.aem(response)), to: source)
  }
}

/// Returns the first event matching `predicate`, or nil if none arrives within `timeout`.
private func first(
  _ events: AsyncStream<ControllerEvent>,
  timeout: Duration = .seconds(2),
  where predicate: @escaping @Sendable (ControllerEvent) -> Bool
) async -> ControllerEvent? {
  await withTaskGroup(of: ControllerEvent?.self) { group in
    group.addTask {
      for await event in events where predicate(event) {
        return event
      }
      return nil
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return nil
    }
    let event = await group.next() ?? nil
    group.cancelAll()
    return event
  }
}

final class ControllerTests: XCTestCase {
  private var network: VirtualNetwork!
  private var entity: FakeEntity!

  override func setUp() async throws {
    network = VirtualNetwork()
    entity = FakeEntity(network: network)
  }

  override func tearDown() async throws {
    entity.stop()
  }

  /// A controller that has discovered the fake entity.
  private func makeController() async throws -> Controller<VirtualPort> {
    let endStation = EndStation(port: network.makePort(macAddress: controllerMacAddress))
    let controller = try await Controller(endStation: endStation, entityID: controllerEntityID)
    let online = await first(await controller.events()) {
      if case .entityOnline(entityID) = $0 { true } else { false }
    }
    XCTAssertNotNil(online, "fake entity not discovered")
    return controller
  }

  // MARK: - Discovery

  func testDiscovery() async throws {
    let controller = try await makeController()
    let entity = await controller.discoveredEntity(id: entityID)
    XCTAssertEqual(entity?.macAddress, [0x02, 0x00, 0x00, 0x00, 0x00, 0x02])
    XCTAssertEqual(entity?.listenerStreamSinks, 1)
    XCTAssertEqual(entity?.interfaceInformationCount, 1)
    await controller.close()
  }

  func testEntityDeparting() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    try await entity.advertise(.entityDeparting)
    let offline = await first(events) {
      if case .entityOffline(entityID) = $0 { true } else { false }
    }
    XCTAssertNotNil(offline)
    let discovered = await controller.discoveredEntity(id: entityID)
    XCTAssertNil(discovered)
    await controller.close()
  }

  func testDynamicEntityID() async throws {
    let endStation = EndStation(port: network.makePort(macAddress: controllerMacAddress))
    let id = try await endStation.makeDynamicEntityID()
    XCTAssertEqual(id.rawValue >> 16, 0x0200_0000_0001)
    XCTAssertNotEqual(id.rawValue & 0xFFFF, 0)
    try await endStation.releaseDynamicEntityID(id)
    do {
      try await endStation.releaseDynamicEntityID(id)
      XCTFail("released an unissued entity ID")
    } catch EndStationError.invalidDynamicEntityID {}
  }

  // MARK: - AEM

  func testReadEntityDescriptor() async throws {
    let controller = try await makeController()
    let descriptor = try await controller.readEntityDescriptor(id: entityID)
    XCTAssertEqual(descriptor.entityID, entityID)
    XCTAssertEqual(descriptor.entityName, entityName)
    XCTAssertEqual(descriptor.firmwareVersion, "1.0")
    XCTAssertEqual(descriptor.configurationsCount, 1)
    await controller.close()
  }

  func testCommandToUnknownEntity() async throws {
    let controller = try await makeController()
    do {
      try await controller.registerUnsolicitedNotifications(id: UniqueIdentifier(0x1234))
      XCTFail("expected unknownEntity")
    } catch let status as AemStatus {
      XCTAssertEqual(status, .unknownEntity)
    }
    await controller.close()
  }

  func testErrorStatus() async throws {
    let controller = try await makeController()
    entity.behaviour.withLock { $0.status = .noSuchDescriptor }
    do {
      _ = try await controller.readEntityDescriptor(id: entityID)
      XCTFail("expected noSuchDescriptor")
    } catch let status as AemStatus {
      XCTAssertEqual(status, .noSuchDescriptor)
    }
    await controller.close()
  }

  func testRetryAfterTimeout() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    entity.behaviour.withLock { $0.commandsToDrop = 1 }
    try await controller.registerUnsolicitedNotifications(id: entityID)
    let retry = await first(events) {
      if case .aecpRetry(entityID) = $0 { true } else { false }
    }
    XCTAssertNotNil(retry)
    await controller.close()
  }

  func testTimeoutAfterRetry() async throws {
    let controller = try await makeController()
    entity.behaviour.withLock { $0.commandsToDrop = 2 }
    let start = ContinuousClock.now
    do {
      try await controller.registerUnsolicitedNotifications(id: entityID)
      XCTFail("expected timedOut")
    } catch let status as AemStatus {
      XCTAssertEqual(status, .timedOut)
    }
    // one timeout, a retry, and a second timeout
    XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(500))
    await controller.close()
  }

  func testInProgressExtendsTimeout() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    // IN_PROGRESS every 120 ms holds the command open well past the 250 ms timeout
    entity.behaviour.withLock { $0.inProgressResponses = 3 }
    try await controller.registerUnsolicitedNotifications(id: entityID)
    let retry = await first(events, timeout: .milliseconds(100)) {
      if case .aecpRetry = $0 { true } else { false }
    }
    XCTAssertNil(retry)
    await controller.close()
  }

  func testCancelledCommandIsNotRetried() async throws {
    let controller = try await makeController()
    entity.behaviour.withLock { $0.commandsToDrop = 2 }
    let command = Task {
      try await controller.registerUnsolicitedNotifications(id: entityID)
    }
    try await Task.sleep(for: .milliseconds(50))
    command.cancel()
    _ = await command.result
    // well past the 250 ms timeout at which the command would have been retried
    try await Task.sleep(for: .milliseconds(400))
    let sent = entity.receivedCount {
      if case let .aecp(.aem(aem)) = $0 { aem.commandType == .registerUnsolicitedNotification } else { false }
    }
    XCTAssertEqual(sent, 1)
    await controller.close()
  }

  func testAnswersCommandsToController() async throws {
    let controller = try await makeController()
    let commands: [(sequenceID: UInt16, commandType: AemCommandType, status: AemStatus)] = [
      (1, .controllerAvailable, .success),
      (2, .readDescriptor, .notImplemented),
    ]
    for command in commands {
      try await entity.send(.aecp(.aem(AemAecpdu(
        isResponse: false,
        targetEntityID: controllerEntityID,
        controllerEntityID: entityID,
        sequenceID: command.sequenceID,
        commandType: command.commandType
      ))), to: controllerMacAddress)
      let response = await entity.firstReceived {
        if case let .aecp(.aem(aem)) = $0 { aem.isResponse && aem.sequenceID == command.sequenceID } else { false }
      }
      guard case let .aecp(.aem(aem)) = response else {
        XCTFail("no response to \(command.commandType)")
        continue
      }
      XCTAssertEqual(aem.commandType, command.commandType)
      XCTAssertEqual(aem.targetEntityID, controllerEntityID)
      XCTAssertEqual(aem.status, UInt8(command.status.rawValue))
    }
    await controller.close()
  }

  func testUnsolicitedStreamFormatChange() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    let format = StreamFormat(format: 0x0205_0220_0040_6000)
    try await entity.sendUnsolicited(
      .setStreamFormat,
      data: be16(DescriptorType.streamInput.rawValue) + be16(1) + be64(format.format)
    )
    let changed = await first(events) {
      if case .streamInputFormatChanged(entityID, streamIndex: 1, streamFormat: let changed) = $0 {
        changed == format
      } else {
        false
      }
    }
    XCTAssertNotNil(changed)
    await controller.close()
  }

  // MARK: - Advertising

  func testAdvertisingAndDeparting() async throws {
    let controller = try await makeController()
    try await controller.enableEntityAdvertising(availableDuration: .seconds(2))
    let available = await entity.firstReceived {
      if case let .adp(adpdu) = $0 { adpdu.messageType == .entityAvailable && adpdu.entityID == controllerEntityID } else { false }
    }
    guard case let .adp(availableAdpdu) = available else { return XCTFail("controller not advertised") }
    XCTAssertEqual(availableAdpdu.validTime, 1)
    XCTAssertEqual(availableAdpdu.availableIndex, 0)

    await controller.disableEntityAdvertising()
    let departing = await entity.firstReceived {
      if case let .adp(adpdu) = $0 { adpdu.messageType == .entityDeparting && adpdu.entityID == controllerEntityID } else { false }
    }
    guard case let .adp(departingAdpdu) = departing else { return XCTFail("no ENTITY_DEPARTING") }
    // IEEE 1722.1-2021 §6.2.2.5, §6.2.2.15
    XCTAssertEqual(departingAdpdu.validTime, 0)
    XCTAssertEqual(departingAdpdu.availableIndex, 0)

    // nothing is advertised after departing, past the reannounce interval
    let isAvailable: (AvdeccPdu) -> Bool = {
      if case let .adp(adpdu) = $0 { adpdu.messageType == .entityAvailable && adpdu.entityID == controllerEntityID } else { false }
    }
    let advertisements = entity.receivedCount(where: isAvailable)
    try await Task.sleep(for: .milliseconds(1500))
    XCTAssertEqual(entity.receivedCount(where: isAvailable), advertisements)
    await controller.close()
  }

  // MARK: - ACMP

  func testConnectStream() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    let talker = StreamIdentification(entityID: UniqueIdentifier(0x0200_00FF_FE00_0003), streamIndex: 0)
    let listener = StreamIdentification(entityID: entityID, streamIndex: 0)
    let state = try await controller.connectStream(talker: talker, listener: listener)
    XCTAssertEqual(state.talkerStream, talker)
    XCTAssertEqual(state.listenerStream, listener)
    XCTAssertEqual(state.connectionCount, 1)
    // our own controller response is not reported as sniffed
    let sniffed = await first(events, timeout: .milliseconds(100)) {
      if case .controllerConnectResponse = $0 { true } else { false }
    }
    XCTAssertNil(sniffed)
    await controller.close()
  }

  func testSniffedConnectResponse() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    try await entity.send(.acmp(Acmpdu(
      messageType: .connectRxResponse,
      controllerEntityID: UniqueIdentifier(0x0200_00FF_FE00_0099),
      talkerEntityID: UniqueIdentifier(0x0200_00FF_FE00_0003),
      listenerEntityID: entityID,
      connectionCount: 1
    )), to: AvdeccMulticastMacAddress)
    let sniffed = await first(events) {
      if case let .controllerConnectResponse(state, .success) = $0 {
        state.listenerStream.entityID == entityID
      } else {
        false
      }
    }
    XCTAssertNotNil(sniffed)
    await controller.close()
  }
}
