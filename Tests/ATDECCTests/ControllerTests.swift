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

@testable import ATDECC
import BinaryParsing
import IEEE802
import Logging
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
    /// AEM commands are not answered until `releaseHeldResponses()`.
    var holdResponses = false
    var dropAcmpCommands = false
    /// The status of CONNECT_RX_RESPONSE.
    var acmpStatus = UInt8(0)
  }

  let port: VirtualPort
  let behaviour = Mutex(Behaviour())
  /// Every PDU received, in order.
  let received = Mutex([AvdeccPdu]())
  private let _heldCommands = Mutex([(command: AemAecpdu, source: EUI48)]())
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

  func advertise(
    _ messageType: AdpMessageType = .entityAvailable,
    currentConfigurationIndex: UInt16? = nil
  ) async throws {
    let availableIndex = _availableIndex.withLock { index in
      defer { index += 1 }
      return index
    }
    try await send(.adp(Adpdu(
      messageType: messageType,
      validTime: 10,
      entityID: entityID,
      entityCapabilities: currentConfigurationIndex == nil
        ? .aemSupported : [.aemSupported, .aemConfigurationIndexValid],
      listenerStreamSinks: 1,
      listenerCapabilities: [.implemented, .audioSink],
      availableIndex: availableIndex,
      currentConfigurationIndex: currentConfigurationIndex ?? 0
    )), to: AvdeccMulticastMacAddress)
  }

  /// As if the entity had rebooted: its next advertisement starts again from available_index 0.
  func resetAvailableIndex() {
    _availableIndex.withLock { $0 = 0 }
  }

  /// Answers the commands held so far, and answers later ones at once.
  func releaseHeldResponses() async {
    let held = _heldCommands.withLock { held in
      behaviour.withLock { $0.holdResponses = false }
      defer { held = [] }
      return held
    }
    for (command, source) in held {
      await _handleCommand(command, from: source)
    }
  }

  func sendUnsolicited(
    _ commandType: AemCommandType,
    data: [UInt8],
    controllerRequest: Bool = false
  ) async throws {
    var aem = AemAecpdu(
      isResponse: true,
      targetEntityID: entityID,
      controllerEntityID: controllerEntityID,
      unsolicited: true,
      commandType: commandType,
      commandSpecificData: data
    )
    aem.controllerRequest = controllerRequest
    try await send(.aecp(.aem(aem)), to: controllerMacAddress)
  }

  /// One transmission of an IDENTIFY_NOTIFICATION (IEEE 1722.1-2021 §7.5.1).
  func sendIdentifyNotification(sequenceID: UInt16) async throws {
    try await send(.aecp(.aem(AemAecpdu(
      isResponse: true,
      targetEntityID: entityID,
      controllerEntityID: IdentifyNotificationControllerEntityID,
      sequenceID: sequenceID,
      unsolicited: true,
      commandType: .setControl
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

  /// Waits up to `timeout` for `count` PDUs matching `predicate` to have been received.
  func waitUntilReceived(
    _ count: Int,
    timeout: Duration = .seconds(2),
    where predicate: (AvdeccPdu) -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    repeat {
      if receivedCount(where: predicate) >= count {
        return true
      }
      try? await Task.sleep(for: .milliseconds(5))
    } while ContinuousClock.now < deadline
    return false
  }

  /// The sequence IDs of the REGISTER_UNSOLICITED_NOTIFICATION commands received, in order and
  /// without retries, which repeat a sequence ID.
  var registerSequenceIDs: [UInt16] {
    received.withLock { received in
      var sequenceIDs = [UInt16]()
      for case let .aecp(.aem(aem)) in received
        where !aem.isResponse && aem.commandType == .registerUnsolicitedNotification &&
        !sequenceIDs.contains(aem.sequenceID)
      {
        sequenceIDs.append(aem.sequenceID)
      }
      return sequenceIDs
    }
  }

  /// Waits up to `timeout` for `count` distinct REGISTER_UNSOLICITED_NOTIFICATION commands.
  func waitUntilRegistered(_ count: Int, timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    repeat {
      if registerSequenceIDs.count >= count {
        return true
      }
      try? await Task.sleep(for: .milliseconds(5))
    } while ContinuousClock.now < deadline
    return false
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
      acmpdu.listenerEntityID == entityID && !behaviour.withLock(\.dropAcmpCommands):
      var response = acmpdu
      response.messageType = .connectRxResponse
      response.status = behaviour.withLock(\.acmpStatus)
      response.connectionCount = 1
      try? await send(.acmp(response), to: AvdeccMulticastMacAddress)
    default:
      break
    }
  }

  private func _handleCommand(_ command: AemAecpdu, from source: EUI48) async {
    let isHeld = _heldCommands.withLock { held in
      guard behaviour.withLock(\.holdResponses) else { return false }
      held.append((command: command, source: source))
      return true
    }
    guard !isHeld else { return }
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

/// The result of `task`, or nil if it does not complete within `timeout`. The wait does not
/// depend on `task` honouring cancellation.
private func result<Success: Sendable>(
  of task: Task<Success, any Error>,
  within timeout: Duration = .seconds(2)
) async -> Result<Success, any Error>? {
  let completion = Mutex<Result<Success, any Error>?>(nil)
  Task {
    let result = await task.result
    completion.withLock { $0 = result }
  }
  let deadline = ContinuousClock.now + timeout
  repeat {
    if let result = completion.withLock({ $0 }) {
      return result
    }
    try? await Task.sleep(for: .milliseconds(5))
  } while ContinuousClock.now < deadline
  return nil
}

private struct ReceiveFailure: Error {}

/// A port that has gone: it sends nowhere, and every reception fails at once.
private final class FailedPort: NetworkPort {
  let macAddress = controllerMacAddress
  let receptions = Mutex(0)

  func send(_: IEEE802Packet) async throws {}

  func receive(_: (IEEE802Packet) async -> ()) async throws {
    receptions.withLock { $0 += 1 }
    throw ReceiveFailure()
  }
}

private func isCommand(_ commandType: AemCommandType) -> @Sendable (AvdeccPdu) -> Bool {
  { pdu in
    if case let .aecp(.aem(aem)) = pdu { !aem.isResponse && aem.commandType == commandType } else { false }
  }
}

private let talkerStream = StreamIdentification(
  entityID: UniqueIdentifier(0x0200_00FF_FE00_0003),
  streamIndex: 0
)
private let listenerStream = StreamIdentification(entityID: entityID, streamIndex: 0)

private final class EventCount: Sendable {
  let value = Mutex(0)
}

final class ControllerTests: XCTestCase {
  private var network: VirtualNetwork!
  private var entity: FakeEntity!
  /// The port of the controller made by `makeController()`.
  private var controllerPort: VirtualPort!

  override func setUp() async throws {
    network = VirtualNetwork()
    entity = FakeEntity(network: network)
  }

  override func tearDown() async throws {
    entity.stop()
  }

  /// A controller that has discovered the fake entity.
  private func makeController(
    timing: ControllerTiming = ControllerTiming()
  ) async throws -> Controller<VirtualPort> {
    controllerPort = network.makePort(macAddress: controllerMacAddress)
    let endStation = EndStation(port: controllerPort, logger: Logger(label: "ControllerTests"))
    let controller = try await Controller(
      endStation: endStation,
      entityID: controllerEntityID,
      timing: timing
    )
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
    XCTAssertEqual(entity?.macAddress.map { UInt64(eui48: $0) }, 0x0200_0000_0002)
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

  // a change of current configuration in an advertisement updates the entity (IEEE 1722.1-2021
  // Table 6-2, AEM_CONFIGURATION_INDEX_VALID)
  func testAdvertisedConfigurationChange() async throws {
    let controller = try await makeController()
    let initial = await controller.discoveredEntity(id: entityID)
    XCTAssertNil(initial?.currentConfigurationIndex)
    let events = await controller.events()
    try await entity.advertise(currentConfigurationIndex: 1)
    let updated = await first(events) {
      if case .entityUpdated(entityID) = $0 { true } else { false }
    }
    XCTAssertNotNil(updated)
    let changed = await controller.discoveredEntity(id: entityID)
    XCTAssertEqual(changed?.currentConfigurationIndex, 1)
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

  // MVU commands are numbered apart from AEM commands (Milan 1.3 §5.4.3.2)
  func testMvuSequenceIDsAreIndependentOfAem() async throws {
    let controller = try await makeController()
    _ = try await controller.readEntityDescriptor(id: entityID)
    _ = try await controller.readEntityDescriptor(id: entityID)
    let command = Task { try await controller.getMilanInfo(id: entityID) }
    let sent = await entity.firstReceived {
      if case let .aecp(.mvu(mvu)) = $0 { !mvu.isResponse } else { false }
    }
    command.cancel()
    guard case let .aecp(.mvu(mvu)) = sent else { return XCTFail("no MVU command sent") }
    XCTAssertEqual(mvu.sequenceID, 0)
    await controller.close()
  }

  // 100 mappings exceed one 524-octet AECPDU, so they go as 63 and 37 (§9.2.2.6)
  func testAudioMappingsAreSplitAcrossCommands() async throws {
    let controller = try await makeController()
    let mappings = (0..<UInt16(100)).map {
      AudioMapping(streamIndex: 0, streamChannel: $0, clusterOffset: $0, clusterChannel: 0)
    }
    let added = try await controller.addStreamPortInputAudioMappings(
      id: entityID,
      streamPortIndex: 0,
      mappings: mappings
    )
    XCTAssertEqual(added, mappings)
    let counts = entity.received.withLock { received in
      received.compactMap { pdu -> Int? in
        guard case let .aecp(.aem(aem)) = pdu, !aem.isResponse, aem.commandType == .addAudioMappings
        else { return nil }
        // descriptor_type, descriptor_index, number_of_mappings, reserved, then 8 octets each
        return (aem.commandSpecificData.count - 8) / 8
      }
    }
    XCTAssertEqual(counts, [63, 37])
    await controller.close()
  }

  // 504 octets of mappings per AECPDU: 63 video mappings of 8 octets, 84 sensor mappings of 6
  func testVideoAndSensorMappingsAreSplitAcrossCommands() async throws {
    let controller = try await makeController()
    let video = (0..<UInt16(64)).map {
      VideoMapping(streamIndex: 0, programStream: $0, elementaryStream: 0, clusterOffset: $0)
    }
    let addedVideo = try await controller.addVideoMappings(
      id: entityID,
      descriptorType: .streamPortInput,
      streamPortIndex: 0,
      mappings: video
    )
    XCTAssertEqual(addedVideo, video)
    let sensor = (0..<UInt16(85)).map { SensorMapping(streamIndex: 0, streamSignal: $0, clusterOffset: $0) }
    let removedSensor = try await controller.removeSensorMappings(
      id: entityID,
      descriptorType: .streamPortOutput,
      streamPortIndex: 0,
      mappings: sensor
    )
    XCTAssertEqual(removedSensor, sensor)
    let counts = entity.received.withLock { received in
      received.compactMap { pdu -> Int? in
        guard case let .aecp(.aem(aem)) = pdu, !aem.isResponse else { return nil }
        switch aem.commandType {
        case .addVideoMappings: return (aem.commandSpecificData.count - 8) / VideoMapping.length
        case .removeSensorMappings: return (aem.commandSpecificData.count - 8) / SensorMapping.length
        default: return nil
        }
      }
    }
    XCTAssertEqual(counts, [63, 1, 84, 1])
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

  // a reserved status from the entity reaches the caller as received
  func testReservedAemStatusIsPreserved() async throws {
    let controller = try await makeController()
    entity.behaviour.withLock { $0.status = .reserved20 }
    do {
      _ = try await controller.readEntityDescriptor(id: entityID)
      XCTFail("expected a reserved status")
    } catch let status as AemStatus {
      XCTAssertEqual(status.rawValue, 20)
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

  func testUnsolicitedNotificationRegistration() async throws {
    let controller = try await makeController()
    try await controller.registerUnsolicitedNotifications(id: entityID)
    // registrations are time limited (IEEE 1722.1-2021 §7.4.37.2)
    let register = await entity.firstReceived {
      if case let .aecp(.aem(aem)) = $0 { !aem.isResponse && aem.commandType == .registerUnsolicitedNotification } else { false }
    }
    guard case let .aecp(.aem(registerCommand)) = register else { return XCTFail("no REGISTER_UNSOLICITED_NOTIFICATION") }
    XCTAssertEqual(registerCommand.commandSpecificData, [0x00, 0x00, 0x00, 0x01])

    // and removed on closing, for entities that do not time them out
    await controller.close()
    let deregister = await entity.firstReceived {
      if case let .aecp(.aem(aem)) = $0 { !aem.isResponse && aem.commandType == .deregisterUnsolicitedNotification } else { false }
    }
    XCTAssertNotNil(deregister)
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

  // a front-panel SET_SAMPLING_RATE sent with cr set is a request, not a change (§9.3.2.2)
  func testControllerRequestIsNotReportedAsAChange() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    let changedEvents = await controller.events()
    try await entity.sendUnsolicited(
      .setSamplingRate,
      data: be16(DescriptorType.audioUnit.rawValue) + be16(0) + be32(96000),
      controllerRequest: true
    )
    let request = await first(events) {
      if case .controllerRequest(entityID, command: .setSamplingRate(.audioUnit, 0, _)) = $0 { true } else { false }
    }
    XCTAssertNotNil(request)
    let changed = await first(changedEvents, timeout: .milliseconds(200)) {
      if case .audioUnitSamplingRateChanged = $0 { true } else { false }
    }
    XCTAssertNil(changed)
    await controller.close()
  }

  // an identification is sent three times with one sequence_id (§7.5.1.2.1) and reported once
  func testIdentifyNotificationIsReportedOncePerSequenceID() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    let identifications = EventCount()
    let counting = Task {
      for await case .entityIdentifyNotification(entityID) in events {
        identifications.value.withLock { $0 += 1 }
      }
    }
    defer { counting.cancel() }
    for _ in 0..<3 {
      try await entity.sendIdentifyNotification(sequenceID: 0)
    }
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(identifications.value.withLock { $0 }, 1)
    // a held button identifies again a second later, with the next sequence_id
    try await entity.sendIdentifyNotification(sequenceID: 1)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(identifications.value.withLock { $0 }, 2)
    await controller.close()
  }

  // another controller's INCREMENT_CONTROL notifies the control's new values (§7.5.2)
  func testUnsolicitedIncrementControl() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    try await entity.sendUnsolicited(
      .incrementControl,
      data: be16(DescriptorType.control.rawValue) + be16(2) + [0x05]
    )
    let changed = await first(events) {
      if case .controlValuesChanged(entityID, controlIndex: 2, packedControlValues: [0x05]) = $0 { true } else { false }
    }
    XCTAssertNotNil(changed)
    await controller.close()
  }

  // GET_DYNAMIC_INFO carries only fixed-size GET commands (§7.4.76.2)
  func testDynamicInfoRefusesVariableSizeCommands() async throws {
    let controller = try await makeController()
    do {
      _ = try await controller.getDynamicInfo(
        id: entityID,
        commands: [.getControl(descriptorType: .control, descriptorIndex: 0)]
      )
      XCTFail("expected badArguments")
    } catch let status as AemStatus {
      XCTAssertEqual(status, .badArguments)
    }
    XCTAssertEqual(entity.receivedCount(where: isCommand(.getDynamicInfo)), 0)
    await controller.close()
  }

  func testUnsolicitedPtpPortCounters() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    var data = be16(DescriptorType.ptpPort.rawValue) + be16(1)
    data += be32(PtpPortCounterValidFlags.rxSync.rawValue)
    for counter in 0..<UInt32(DescriptorCounters.count) {
      data += be32(counter)
    }
    try await entity.sendUnsolicited(.getCounters, data: data)
    let changed = await first(events) {
      if case .ptpPortCountersChanged(entityID, ptpPortIndex: 1, valid: .rxSync, counters: _) = $0 { true } else { false }
    }
    XCTAssertNotNil(changed)
    await controller.close()
  }

  func testUnsolicitedStreamBackup() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    // Figure 7-92: each talker is an Entity ID, a unique ID and a reserved word
    let none = be64(0) + be16(0) + be16(0)
    try await entity.sendUnsolicited(
      .setStreamBackup,
      data: be16(DescriptorType.streamInput.rawValue) + be16(1) + be64(0x0200_00FF_FE00_0003) + be16(0) +
        be16(0) + none + none + none
    )
    let changed = await first(events) {
      if case .streamBackupChanged(entityID, descriptorType: DescriptorType.streamInput.rawValue, descriptorIndex: 1,
                                   backup: let backup) = $0
      {
        backup.backupTalker0.entityID == UniqueIdentifier(0x0200_00FF_FE00_0003)
      } else {
        false
      }
    }
    XCTAssertNotNil(changed)
    await controller.close()
  }

  func testUnsolicitedSignalSelectorAndMatrix() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    try await entity.sendUnsolicited(
      .setSignalSelector,
      data: be16(DescriptorType.signalSelector.rawValue) + be16(2) + be16(DescriptorType.audioCluster.rawValue) +
        be16(3) + be16(0) + be16(0)
    )
    let selected = await first(events) {
      if case .signalSelectorChanged(entityID, signalSelectorIndex: 2, source: let source) = $0 {
        source.signalType == .audioCluster && source.signalIndex == 3
      } else {
        false
      }
    }
    XCTAssertNotNil(selected)

    try await entity.sendUnsolicited(
      .setMatrix,
      data: be16(DescriptorType.matrix.rawValue) + be16(0) + be16(0) + be16(0) + be16(2) + be16(1) + be16(0x0002) +
        be16(0) + [0x7F, 0x00]
    )
    let matrix = await first(events) {
      if case .matrixValuesChanged(entityID, matrixIndex: 0, subregion: let subregion, packedValues: [0x7F, 0x00]) = $0 {
        subregion.width == 2 && subregion.valueCount == 2 && subregion.direction == .horizontal
      } else {
        false
      }
    }
    XCTAssertNotNil(matrix)
    await controller.close()
  }

  func testPtpSettingsAndUnsolicitedOverrides() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    let settings = PtpInstanceSettings(flags: .domainNumber, domainNumber: 1)
    let applied = try await controller.setPtpInstanceInfo(id: entityID, ptpInstanceIndex: 0, to: settings)
    XCTAssertEqual(applied, settings)

    try await entity.sendUnsolicited(
      .setPtpPortOverrides,
      data: be16(DescriptorType.ptpPort.rawValue) + be16(1) + be16(0x0080) + be16(0) + [0, 0, 0, 0, 9, 0] + be16(0)
    )
    let changed = await first(events) {
      if case .ptpPortOverridesChanged(entityID, ptpPortIndex: 1, overrides: let overrides) = $0 {
        overrides.desiredState == 9 && overrides.flags == .desiredState
      } else {
        false
      }
    }
    XCTAssertNotNil(changed)
    await controller.close()
  }

  func testUnsolicitedRebootIsReported() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    try await entity.sendUnsolicited(.reboot, data: be16(DescriptorType.entity.rawValue) + be16(0))
    let rebooting = await first(events) {
      if case .entityRebooting(entityID, descriptorType: DescriptorType.entity.rawValue, descriptorIndex: 0) = $0 {
        true
      } else {
        false
      }
    }
    XCTAssertNotNil(rebooting)
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

  func testAdvertisesWhenLinkComesUp() async throws {
    let port = network.makePort(macAddress: controllerMacAddress)
    let controller = try await Controller(endStation: EndStation(port: port), entityID: controllerEntityID)
    try await controller.enableEntityAdvertising(availableDuration: .seconds(2))
    let isAvailable: (AvdeccPdu) -> Bool = {
      if case let .adp(adpdu) = $0 { adpdu.messageType == .entityAvailable && adpdu.entityID == controllerEntityID } else { false }
    }
    // the first advertisement follows a random delay of up to 400 ms
    let first = await entity.firstReceived(where: isAvailable)
    XCTAssertNotNil(first)
    let advertisements = entity.receivedCount(where: isAvailable)

    port.setLinkUp(false)
    try await Task.sleep(for: .milliseconds(20))
    port.setLinkUp(true)
    // the next reannouncement is not due for at least a second; link up advertises within 400 ms
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertGreaterThan(entity.receivedCount(where: isAvailable), advertisements)
    await controller.close()
  }

  /// An ENTITY_DISCOVER does not restart a delay already pending (IEEE 1722.1-2021 Figure
  /// 6-2): discovers that keep coming would otherwise keep putting the advertisement off.
  func testRepeatedDiscoverDoesNotPostponeAdvertising() async throws {
    let controller = try await makeController()
    try await controller.enableEntityAdvertising(availableDuration: .seconds(2))
    let isAvailable: (AvdeccPdu) -> Bool = {
      if case let .adp(adpdu) = $0 { adpdu.messageType == .entityAvailable && adpdu.entityID == controllerEntityID } else { false }
    }
    // the delay is up to 400 ms; discovers arrive far more often than that throughout
    let discovering = Task { [entity = entity!] in
      while !Task.isCancelled {
        try? await entity.send(
          .adp(Adpdu(messageType: .entityDiscover, validTime: 0, entityID: UniqueIdentifier())),
          to: AvdeccMulticastMacAddress
        )
        try? await Task.sleep(for: .milliseconds(5))
      }
    }
    defer { discovering.cancel() }
    let advertised = await entity.firstReceived(timeout: .milliseconds(800), where: isAvailable)
    XCTAssertNotNil(advertised)
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

  // with Milan timeouts an unanswered bind fails after 200 ms and one retry, not 4.5 s and one
  // retry (Milan 1.3 Table 5.26)
  func testMilanAcmpCommandTimeout() async throws {
    var timing = ControllerTiming()
    timing.acmpCommandTimeouts = .milan
    let controller = try await makeController(timing: timing)
    entity.behaviour.withLock { $0.dropAcmpCommands = true }
    let start = ContinuousClock.now
    do {
      _ = try await controller.connectStream(talker: talkerStream, listener: listenerStream)
      XCTFail("expected the bind to time out")
    } catch {}
    XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(1500))
    await controller.close()
  }

  // a bind can request connection flags such as STREAMING_WAIT (IEEE 1722.1-2021 Table 8-4)
  func testConnectStreamSendsFlags() async throws {
    let controller = try await makeController()
    _ = try await controller.connectStream(talker: talkerStream, listener: listenerStream, flags: .streamingWait)
    let sent = await entity.firstReceived {
      if case let .acmp(acmpdu) = $0 { acmpdu.messageType == .connectRxCommand } else { false }
    }
    guard case let .acmp(acmpdu) = sent else { return XCTFail("no CONNECT_RX_COMMAND sent") }
    XCTAssertEqual(acmpdu.flags, .streamingWait)
    await controller.close()
  }

  func testReservedAcmpStatusIsPreserved() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    // 20 is reserved in IEEE 1722.1-2021 Table 8-3
    entity.behaviour.withLock { $0.acmpStatus = 20 }
    let talker = StreamIdentification(entityID: UniqueIdentifier(0x0200_00FF_FE00_0003), streamIndex: 0)
    let listener = StreamIdentification(entityID: entityID, streamIndex: 0)
    do {
      _ = try await controller.connectStream(talker: talker, listener: listener)
      XCTFail("expected a reserved status")
    } catch let status as AcmpStatus {
      XCTAssertEqual(status.rawValue, 20)
    }

    try await entity.send(.acmp(Acmpdu(
      messageType: .connectRxResponse,
      status: 21,
      controllerEntityID: UniqueIdentifier(0x0200_00FF_FE00_0099),
      talkerEntityID: talker.entityID,
      listenerEntityID: entityID
    )), to: AvdeccMulticastMacAddress)
    let sniffed = await first(events) {
      if case let .controllerConnectResponse(_, status) = $0 { status.rawValue == 21 } else { false }
    }
    XCTAssertNotNil(sniffed)
    await controller.close()
  }

  /// A talker's response to a listener acting for this controller carries the controller's ID
  /// and the listener's sequence_id, which may be that of a command of the controller's own.
  func testAcmpResponseForAnotherStreamDoesNotCompleteCommand() async throws {
    let controller = try await makeController()
    let command = Task {
      try await controller.disconnectTalkerStream(talker: talkerStream, listener: listenerStream)
    }
    let sent = await entity.firstReceived {
      if case let .acmp(acmpdu) = $0 { acmpdu.messageType == .disconnectTxCommand } else { false }
    }
    guard case var .acmp(response) = sent else { return XCTFail("DISCONNECT_TX_COMMAND not sent") }
    response.messageType = .disconnectTxResponse

    var other = response
    other.listenerUniqueID = 7
    other.connectionCount = 3
    try await entity.send(.acmp(other), to: AvdeccMulticastMacAddress)
    try await entity.send(.acmp(response), to: AvdeccMulticastMacAddress)
    let state = try await command.value
    XCTAssertEqual(state.listenerStream, listenerStream)
    XCTAssertEqual(state.connectionCount, 0)
    await controller.close()
  }

  /// A listener that answers after its command has timed out has still connected.
  func testLateAcmpResponseIsReported() async throws {
    var timing = ControllerTiming()
    timing.acmpCommandTimeouts = .milan
    let controller = try await makeController(timing: timing)
    let events = await controller.events()
    entity.behaviour.withLock { $0.dropAcmpCommands = true }
    do {
      _ = try await controller.connectStream(talker: talkerStream, listener: listenerStream)
      XCTFail("expected a timeout")
    } catch {
      XCTAssertEqual(error as? AcmpStatus, .timedOut)
    }

    let sent = await entity.firstReceived {
      if case let .acmp(acmpdu) = $0 { acmpdu.messageType == .connectRxCommand } else { false }
    }
    guard case var .acmp(response) = sent else { return XCTFail("CONNECT_RX_COMMAND not sent") }
    response.messageType = .connectRxResponse
    response.connectionCount = 1
    try await entity.send(.acmp(response), to: AvdeccMulticastMacAddress)
    let reported = await first(events) {
      if case let .controllerConnectResponse(state, .success) = $0 {
        state.listenerStream == listenerStream
      } else {
        false
      }
    }
    XCTAssertNotNil(reported)
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

  // MARK: - Recovery

  func testReceptionRecoversAfterReceiveFailure() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    controllerPort.failReceive(with: ReceiveFailure())
    let transportError = await first(events) {
      if case .transportError = $0 { true } else { false }
    }
    XCTAssertNotNil(transportError)
    // frames arriving after the failure are handled
    let descriptor = try await controller.readEntityDescriptor(id: entityID)
    XCTAssertEqual(descriptor.entityID, entityID)
    await controller.close()
  }

  func testReceptionRecoversAfterReceiveEnds() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    controllerPort.finishReceive()
    let transportError = await first(events) {
      if case .transportError = $0 { true } else { false }
    }
    XCTAssertNotNil(transportError)
    let descriptor = try await controller.readEntityDescriptor(id: entityID)
    XCTAssertEqual(descriptor.entityID, entityID)
    await controller.close()
  }

  /// A port that keeps failing is tried again ever less often, and reported once.
  func testRepeatedReceiveFailureBacksOff() async throws {
    let port = FailedPort()
    let endStation = EndStation(port: port, logger: Logger(label: "ControllerTests"))
    let controller = try await Controller(endStation: endStation, entityID: controllerEntityID)
    let events = await controller.events()
    let transportErrors = Mutex(0)
    let counting = Task {
      for await event in events {
        if case .transportError = event { transportErrors.withLock { $0 += 1 } }
      }
    }
    defer { counting.cancel() }

    // retried after 100, 200 and 400 ms
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertGreaterThanOrEqual(port.receptions.withLock { $0 }, 2)
    XCTAssertLessThanOrEqual(port.receptions.withLock { $0 }, 4)
    XCTAssertEqual(transportErrors.withLock { $0 }, 1)
    await controller.close()
    await endStation.close()
  }

  func testReceivesOnlyWhileLinkIsUp() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    let transportErrors = Mutex(0)
    let counting = Task {
      for await event in events {
        if case .transportError = event { transportErrors.withLock { $0 += 1 } }
      }
    }
    defer { counting.cancel() }

    // a port whose link is down fails to receive at once; the end station does not keep trying
    controllerPort.setLinkUp(false)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertLessThanOrEqual(transportErrors.withLock { $0 }, 1)

    controllerPort.setLinkUp(true)
    let descriptor = try await controller.readEntityDescriptor(id: entityID)
    XCTAssertEqual(descriptor.entityID, entityID)
    await controller.close()
  }

  /// Entities that came while the link was down are found when reception begins again.
  func testDiscoversWhenReceptionBegins() async throws {
    let controller = try await makeController()
    let isDiscover: (AvdeccPdu) -> Bool = {
      if case let .adp(adpdu) = $0 { adpdu.messageType == .entityDiscover } else { false }
    }
    XCTAssertEqual(entity.receivedCount(where: isDiscover), 1)
    controllerPort.setLinkUp(false)
    try await Task.sleep(for: .milliseconds(20))
    controllerPort.setLinkUp(true)
    let discovered = await entity.waitUntilReceived(2, where: isDiscover)
    XCTAssertTrue(discovered)
    await controller.close()
  }

  // MARK: - Transmission

  func testReceptionContinuesWhileSendIsBlocked() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    controllerPort.setSendsBlocked(true)
    // the controller's response to this command cannot be sent
    try await entity.send(.aecp(.aem(AemAecpdu(
      isResponse: false,
      targetEntityID: controllerEntityID,
      controllerEntityID: entityID,
      sequenceID: 1,
      commandType: .controllerAvailable
    ))), to: controllerMacAddress)
    try await entity.advertise(.entityDeparting)
    let offline = await first(events) {
      if case .entityOffline(entityID) = $0 { true } else { false }
    }
    XCTAssertNotNil(offline, "ENTITY_DEPARTING not handled while a send was blocked")

    controllerPort.setSendsBlocked(false)
    let response = await entity.firstReceived {
      if case let .aecp(.aem(aem)) = $0 { aem.isResponse && aem.commandType == .controllerAvailable } else { false }
    }
    XCTAssertNotNil(response)
    await controller.close()
  }

  func testCancellingAecpCommandDuringSend() async throws {
    let controller = try await makeController()
    controllerPort.setSendsBlocked(true)
    // the first command's send is blocked; the second waits to be sent after it
    let sending = Task {
      try await controller.readEntityDescriptor(id: entityID)
    }
    try await Task.sleep(for: .milliseconds(20))
    let waiting = Task {
      try await controller.lockEntity(id: entityID)
    }
    try await Task.sleep(for: .milliseconds(20))
    sending.cancel()
    waiting.cancel()
    switch await result(of: sending) {
    case .failure(is CancellationError): break
    case let result: XCTFail("expected CancellationError, got \(String(describing: result))")
    }
    switch await result(of: waiting) {
    case .failure(is CancellationError): break
    case let result: XCTFail("expected CancellationError, got \(String(describing: result))")
    }

    // the send in progress completes once sends resume, but the command waiting is not sent
    controllerPort.setSendsBlocked(false)
    let sent = await entity.waitUntilReceived(1, where: isCommand(.readDescriptor))
    XCTAssertTrue(sent)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(entity.receivedCount(where: isCommand(.lockEntity)), 0)
    await controller.close()
  }

  func testCancellingAcmpCommandDuringSend() async throws {
    let controller = try await makeController()
    controllerPort.setSendsBlocked(true)
    let command = Task {
      try await controller.connectStream(talker: talkerStream, listener: listenerStream)
    }
    try await Task.sleep(for: .milliseconds(50))
    command.cancel()
    switch await result(of: command) {
    case .failure(is CancellationError): break
    case let result: XCTFail("expected CancellationError, got \(String(describing: result))")
    }
    controllerPort.setSendsBlocked(false)
    await controller.close()
  }

  func testCommandsBeyondInflightLimitAreQueued() async throws {
    // responses are held for longer than the standard timeout
    let controller = try await makeController(timing: ControllerTiming(aecpCommandTimeout: .seconds(10)))
    entity.behaviour.withLock { $0.holdResponses = true }
    let commandCount = 15
    let inflightLimit = 10
    let commands = (0..<commandCount).map { index in
      Task {
        try await controller.lockEntity(id: entityID, descriptorIndex: UInt16(index))
      }
    }

    let isLock = isCommand(.lockEntity)
    let inflight = await entity.waitUntilReceived(inflightLimit, where: isLock)
    XCTAssertTrue(inflight)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(entity.receivedCount(where: isLock), inflightLimit)

    // cancel a command that is still queued
    let sentIndices = entity.received.withLock { received in
      Set(received.compactMap { pdu -> Int? in
        guard case let .aecp(.aem(aem)) = pdu, aem.commandType == .lockEntity else { return nil }
        // flags, locked_id, descriptor_type, descriptor_index
        let data = aem.commandSpecificData
        return Int(data[14]) << 8 | Int(data[15])
      })
    }
    let queuedIndex = try XCTUnwrap((0..<commandCount).first { !sentIndices.contains($0) })
    commands[queuedIndex].cancel()
    switch await result(of: commands[queuedIndex]) {
    case .failure(is CancellationError): break
    case let result: XCTFail("expected CancellationError, got \(String(describing: result))")
    }

    // each response lets a queued command through
    await entity.releaseHeldResponses()
    for (index, command) in commands.enumerated() where index != queuedIndex {
      switch await result(of: command) {
      case .success: break
      case let result: XCTFail("command \(index): \(String(describing: result))")
      }
    }
    XCTAssertEqual(entity.receivedCount(where: isLock), commandCount - 1)
    await controller.close()
  }

  /// A port such as a UART has its controller send one command at a time.
  func testInflightLimitOfOne() async throws {
    let timing = ControllerTiming(aecpCommandTimeout: .seconds(10), maximumInflightAecpCommands: 1)
    let controller = try await makeController(timing: timing)
    entity.behaviour.withLock { $0.holdResponses = true }
    let commands = (0..<3).map { index in
      Task {
        try await controller.lockEntity(id: entityID, descriptorIndex: UInt16(index))
      }
    }
    let isLock = isCommand(.lockEntity)
    let inflight = await entity.waitUntilReceived(1, where: isLock)
    XCTAssertTrue(inflight)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(entity.receivedCount(where: isLock), 1)

    await entity.releaseHeldResponses()
    for (index, command) in commands.enumerated() {
      switch await result(of: command) {
      case .success: break
      case let result: XCTFail("command \(index): \(String(describing: result))")
      }
    }
    await controller.close()
  }

  func testEventStreamsEndWhenControllerIsReleased() async throws {
    var controller: Controller<VirtualPort>? = try await makeController()
    let events = await controller!.events()
    controller = nil
    let consumer = Task<Bool, any Error> {
      for await _ in events {}
      return true
    }
    defer { consumer.cancel() }
    switch await result(of: consumer) {
    case .success: break
    case let result: XCTFail("event stream did not end: \(String(describing: result))")
    }
  }

  func testCloseFailsPendingCommandsPromptly() async throws {
    let controller = try await makeController()
    // closing deregisters, which is sent on a port whose sends are blocked below
    try await controller.registerUnsolicitedNotifications(id: entityID)
    entity.behaviour.withLock { behaviour in
      behaviour.commandsToDrop = .max
      behaviour.dropAcmpCommands = true
    }
    let aecpCommand = Task {
      try await controller.readEntityDescriptor(id: entityID)
    }
    let acmpCommand = Task {
      try await controller.connectStream(talker: talkerStream, listener: listenerStream)
    }
    let aecpSent = await entity.waitUntilReceived(1, where: isCommand(.readDescriptor))
    let acmpSent = await entity.waitUntilReceived(1) {
      if case let .acmp(acmpdu) = $0 { acmpdu.messageType == .connectRxCommand } else { false }
    }
    XCTAssertTrue(aecpSent && acmpSent)

    controllerPort.setSendsBlocked(true)
    let closing = Task { () throws in await controller.close() }
    // well within the AECP command's 250 ms timeout
    let closeWait = Duration.milliseconds(150)
    switch await result(of: aecpCommand, within: closeWait) {
    case .failure(AemStatus.internalError): break
    case let result: XCTFail("expected internalError, got \(String(describing: result))")
    }
    switch await result(of: acmpCommand, within: closeWait) {
    case .failure(AcmpStatus.internalError): break
    case let result: XCTFail("expected internalError, got \(String(describing: result))")
    }
    let closed = await result(of: closing, within: closeWait)
    XCTAssertNotNil(closed, "close() waited on a blocked send")
    controllerPort.setSendsBlocked(false)
    _ = await result(of: closing)
  }

  // MARK: - Entity reboot

  private func checkEntityReboot(departing: Bool) async throws {
    let timing = ControllerTiming(
      unsolicitedNotificationRenewalInterval: .milliseconds(50),
      maintenanceInterval: .milliseconds(10)
    )
    let controller = try await makeController(timing: timing)
    let events = await controller.events()
    try await controller.registerUnsolicitedNotifications(id: entityID)

    entity.behaviour.withLock { $0.commandsToDrop = .max }
    let inflight = Task {
      try await controller.readEntityDescriptor(id: entityID)
    }
    let sent = await entity.waitUntilReceived(1, where: isCommand(.readDescriptor))
    XCTAssertTrue(sent)

    if departing {
      try await entity.advertise(.entityDeparting)
      let offline = await first(events) {
        if case .entityOffline(entityID) = $0 { true } else { false }
      }
      XCTAssertNotNil(offline)
    }
    entity.resetAvailableIndex()
    entity.behaviour.withLock { $0.commandsToDrop = 0 }
    try await entity.advertise()

    // the command in flight to the entity that went away fails
    switch await result(of: inflight) {
    case .failure(AemStatus.unknownEntity): break
    case let result: XCTFail("expected unknownEntity, got \(String(describing: result))")
    }
    let online = await first(events) {
      if case .entityOnline(entityID) = $0 { true } else { false }
    }
    XCTAssertNotNil(online)

    // its registration went with it, and is no longer renewed
    let registrations = entity.registerSequenceIDs.count
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(entity.registerSequenceIDs.count, registrations)

    // the returned entity answers commands, and can be registered with again
    let descriptor = try await controller.readEntityDescriptor(id: entityID)
    XCTAssertEqual(descriptor.entityID, entityID)
    try await controller.registerUnsolicitedNotifications(id: entityID)
    // and that registration is renewed
    let renewed = await entity.waitUntilRegistered(registrations + 2, timeout: .seconds(1))
    XCTAssertTrue(renewed)
    await controller.close()
  }

  func testEntityRebootAfterDeparting() async throws {
    try await checkEntityReboot(departing: true)
  }

  func testEntityRebootWithoutDeparting() async throws {
    try await checkEntityReboot(departing: false)
  }

  // MARK: - Unsolicited notification registrations

  func testUnregisterFromDepartedEntity() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    try await controller.registerUnsolicitedNotifications(id: entityID)
    try await entity.advertise(.entityDeparting)
    let offline = await first(events) {
      if case .entityOffline(entityID) = $0 { true } else { false }
    }
    XCTAssertNotNil(offline)
    // the registration went with the entity: there is nothing to deregister
    try await controller.unregisterUnsolicitedNotifications(id: entityID)
    XCTAssertEqual(entity.receivedCount(where: isCommand(.deregisterUnsolicitedNotification)), 0)
    await controller.close()
  }

  func testFailedRenewalIsRetriedSoon() async throws {
    let timing = ControllerTiming(
      aecpCommandTimeout: .milliseconds(50),
      unsolicitedNotificationRenewalInterval: .milliseconds(600),
      unsolicitedNotificationRetryDelay: .milliseconds(10)...(.milliseconds(40)),
      maintenanceInterval: .milliseconds(10)
    )
    let controller = try await makeController(timing: timing)
    try await controller.registerUnsolicitedNotifications(id: entityID)
    // the renewal, and its retry, go unanswered
    entity.behaviour.withLock { $0.commandsToDrop = 2 }
    let renewed = await entity.waitUntilRegistered(2, timeout: .seconds(2))
    XCTAssertTrue(renewed, "not renewed")

    // the renewal fails after two 50 ms timeouts, and is retried 10 ms later rather than after
    // the 600 ms renewal interval
    let retried = await entity.waitUntilRegistered(3, timeout: .milliseconds(400))
    XCTAssertTrue(retried, "failed renewal not retried soon")
    await controller.close()
  }

  func testReregistersAfterUnsolicitedDeregistration() async throws {
    let controller = try await makeController()
    let events = await controller.events()
    try await controller.registerUnsolicitedNotifications(id: entityID)
    // the entity timed out the registration (IEEE 1722.1-2021 §7.4.37.2)
    try await entity.sendUnsolicited(.deregisterUnsolicitedNotification, data: [])
    let deregistered = await first(events) {
      if case .deregisteredFromUnsolicitedNotifications(entityID) = $0 { true } else { false }
    }
    XCTAssertNotNil(deregistered)
    let registered = await entity.waitUntilRegistered(2, timeout: .seconds(1))
    XCTAssertTrue(registered, "not registered again")
    await controller.close()
  }

  func testRenewalRetryDoesNotFollowUnregister() async throws {
    let timing = ControllerTiming(
      unsolicitedNotificationRenewalInterval: .milliseconds(100),
      maintenanceInterval: .milliseconds(10)
    )
    let controller = try await makeController(timing: timing)
    try await controller.registerUnsolicitedNotifications(id: entityID)
    // the renewal goes unanswered, so it is retried after the 250 ms AECP timeout
    entity.behaviour.withLock { $0.commandsToDrop = 1 }
    let renewed = await entity.waitUntilRegistered(2, timeout: .seconds(2))
    XCTAssertTrue(renewed, "not renewed")

    try await controller.unregisterUnsolicitedNotifications(id: entityID)
    try await Task.sleep(for: .milliseconds(400))
    let isDeregister = isCommand(.deregisterUnsolicitedNotification)
    let isRegister = isCommand(.registerUnsolicitedNotification)
    let registeredAfterDeregistering = entity.received.withLock { received in
      guard let deregister = received.lastIndex(where: isDeregister) else { return false }
      return received[deregister...].contains(where: isRegister)
    }
    XCTAssertFalse(registeredAfterDeregistering)
    await controller.close()
  }
}
