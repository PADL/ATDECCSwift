//
// Copyright (c) 2023-2026 PADL Software Pty Ltd
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
import Logging

// MARK: - Timing

/// Commands in flight to one entity at a time; further commands queue (as la_avdecc does).
private let _maximumInflightAecpCommands = 10

/// Timeout of each ACMP command (IEEE 1722.1-2021 Table 8-1).
private func _acmpCommandTimeout(_ messageType: AcmpMessageType) -> Duration {
  switch messageType {
  case .connectTxCommand: .milliseconds(2000)
  case .disconnectTxCommand: .milliseconds(200)
  case .getTxStateCommand: .milliseconds(200)
  case .connectRxCommand: .milliseconds(4500)
  case .disconnectRxCommand: .milliseconds(500)
  case .getRxStateCommand: .milliseconds(200)
  case .getTxConnectionCommand: .milliseconds(200)
  default: preconditionFailure("\(messageType) is not an ACMP command")
  }
}

/// The timing of a controller's state machines, injectable for tests.
struct ControllerTiming: Sendable {
  /// Timeout of every AECP command (IEEE 1722.1-2021 §9.3.2.6); an IN_PROGRESS response
  /// restarts it.
  var aecpCommandTimeout = Duration.milliseconds(250)
  /// How often a time-limited unsolicited notification registration is renewed (IEEE
  /// 1722.1-2021 §7.4.37.2).
  var unsolicitedNotificationRenewalInterval = Duration.seconds(100)
  /// Delays before a failed renewal is retried, doubling from the lower bound; well within the
  /// entity's 300 second timeout.
  var unsolicitedNotificationRetryDelay = Duration.seconds(1)...Duration.seconds(30)
  /// How often discovered interfaces' valid times, and registrations due for renewal, are
  /// checked.
  var maintenanceInterval = Duration.milliseconds(500)
}

/// Advertised available durations (valid_time is in units of 2 seconds).
private let _availableDurationRange = Duration.seconds(2)...Duration.seconds(62)

/// Responses that complete this controller's ACMP commands without also being reported as
/// sniffed. The set is la_avdecc's rather than that of IEEE 1722.1-2021 §8.2.3, which also
/// includes GET_TX_STATE_RESPONSE: other responses carrying a controller's ID, including a
/// talker's responses to a listener acting on its behalf, are reported as sniffed as well.
private let _controllerAcmpResponses: Set<AcmpMessageType> = [
  .connectRxResponse, .disconnectRxResponse, .getRxStateResponse, .getTxConnectionResponse,
]

// name_index values (IEEE 1722.1-2021 §7.4.17.1): the ENTITY descriptor's entity_name and
// group_name, and every other descriptor's object_name.
private let _entityNameIndex: UInt16 = 0
private let _entityGroupNameIndex: UInt16 = 1
private let _objectNameIndex: UInt16 = 0

/// Why a command did not receive a response.
private enum CommandError: Error {
  case timedOut
  case unknownEntity
  case networkError(any Error)
  case closed
}

private extension AemStatus {
  init(_ error: CommandError) {
    switch error {
    case .timedOut: self = .timedOut
    case .unknownEntity: self = .unknownEntity
    case .networkError: self = .networkError
    case .closed: self = .internalError
    }
  }
}

private extension MvuStatus {
  init(_ error: CommandError) {
    switch error {
    case .timedOut: self = .timedOut
    case .unknownEntity: self = .unknownEntity
    case .networkError: self = .networkError
    case .closed: self = .internalError
    }
  }
}

private extension AcmpStatus {
  init(_ error: CommandError) {
    switch error {
    case .timedOut: self = .timedOut
    case .unknownEntity: self = .unknownEntity
    case .networkError: self = .networkError
    case .closed: self = .internalError
    }
  }
}

private extension Duration {
  var wholeMilliseconds: UInt64 {
    let (seconds, attoseconds) = components
    return UInt64(max(seconds, 0)) * 1000 + UInt64(max(attoseconds, 0)) / 1_000_000_000_000_000
  }
}

// MARK: - Controller

/// An ATDECC Controller (IEEE 1722.1-2021 §9.3.6, §8.2.3) on an end station. It discovers
/// entities, sends them AEM, Milan MVU and ACMP commands and awaits the responses, and reports
/// discovery, unsolicited notifications and sniffed connection management as
/// `ControllerEvent`s.
///
/// Where the specification leaves room, or differs from la_avdecc on the wire, the controller
/// behaves as la_avdecc does:
/// - At most ten AECP commands are in flight to an entity; further commands wait in a queue.
/// - An AECP command is retried once on timeout, including after IN_PROGRESS responses
///   (Figure 9-4). ACMP commands are also retried once (Figure 8-2).
/// - ACMPDUs are sent with the 2013 control_data_length (see `Acmpdu.length`).
///
/// Unlike la_avdecc, ACMP commands are neither queued nor paced.
public actor Controller<Port: NetworkPort> {
  private struct AecpTransaction: Sendable {
    let sequenceID: UInt16
    let aecpdu: Aecpdu
    let destination: EUI48
    let promise: Promise<Aecpdu>
    let timer: Timer
    var retried = false
    var sendTime = ContinuousClock.now
  }

  private struct AecpTarget: Sendable {
    var inflight = [AecpTransaction]()
    var queued = [AecpTransaction]()
  }

  private struct AcmpTransaction: Sendable {
    let acmpdu: Acmpdu
    let promise: Promise<Acmpdu>
    let timer: Timer
    var retried = false
  }

  /// A registration for an entity's unsolicited notifications, from when it is requested.
  private struct UnsolicitedNotificationRegistration: Sendable {
    /// Distinguishes this registration from a later one for the same entity.
    let id: UInt64
    /// Whether the entity accepted a time-limited registration, which is renewed; nil until
    /// the entity responds.
    var isTimeLimited: Bool?
    /// When the registration is next renewed, or a failed renewal retried.
    var renewalTime: ContinuousClock.Instant
    /// The delay before the last retry of a failed renewal; nil once a renewal succeeds.
    var retryDelay: Duration?
    /// The renewal in progress. It is cancelled when the registration is dropped, so that its
    /// AECP retry cannot register again after a deregistration.
    var renewal: Task<(), Never>?
  }

  /// A PDU queued for the transmit task. A command's timeout starts once it has been sent.
  private enum Transmission: Sendable {
    case aecpCommand(AecpTransaction)
    case acmpCommand(AcmpTransaction, sequenceID: UInt16)
    /// A PDU outside any transaction: a response, an advertisement or a deregistration.
    case pdu(AvdeccPdu, destination: EUI48)
  }

  private struct Advertising: Sendable {
    let validTime: UInt8
    let interfaceIndex: UInt16?
    let timer: Timer
  }

  public nonisolated let entityID: UniqueIdentifier
  public nonisolated let endStation: EndStation<Port>
  private nonisolated let _logger: Logger
  private nonisolated let _timing: ControllerTiming

  private var _subscribers = [Int: AsyncStream<ControllerEvent>.Continuation]()
  private var _nextSubscriberID = 0
  private var _discovery = DiscoveryStateMachine()
  private var _automaticDiscoveryDelay: Duration?
  private var _lastDiscovery = ContinuousClock.now
  private var _maintenanceTask: Task<(), Never>?
  private var _aecpSequenceID = UInt16(0)
  private var _acmpSequenceID = UInt16(0)
  private var _aecpTargets = [UniqueIdentifier: AecpTarget]()
  private var _acmpTransactions = [UInt16: AcmpTransaction]()
  private var _advertising: Advertising?
  // PDUs are sent in turn by one task, so that a slow port holds up transmission, never the
  // receive path, and so that ENTITY_DEPARTING follows any ENTITY_AVAILABLE
  private nonisolated let _transmissions: AsyncStream<Transmission>.Continuation
  private var _transmitTask: Task<(), Never>?
  private var _availableIndex = UInt32(0)
  private var _lastLinkIsUp = false
  private var _unsolicitedNotificationRegistrations = [UniqueIdentifier: UnsolicitedNotificationRegistration]()
  private var _nextUnsolicitedNotificationRegistration = UInt64(0)
  private var _isClosed = false

  /// Creates a controller entity with `entityID` on `endStation`, and sends ENTITY_DISCOVER
  /// to find the entities already on the network.
  public init(
    endStation: EndStation<Port>,
    entityID: UniqueIdentifier,
    logger: Logger? = nil
  ) async throws {
    try await self.init(endStation: endStation, entityID: entityID, logger: logger, timing: ControllerTiming())
  }

  /// `timing` is injectable for tests.
  init(
    endStation: EndStation<Port>,
    entityID: UniqueIdentifier,
    logger: Logger? = nil,
    timing: ControllerTiming
  ) async throws {
    self.endStation = endStation
    self.entityID = entityID
    _logger = logger ?? endStation.logger
    _timing = timing
    let transmissions: AsyncStream<Transmission>
    (transmissions, _transmissions) = AsyncStream.makeStream()
    try await endStation.register(self)
    _transmitTask = Task { [weak self, endStation, entityID, logger = _logger] in
      for await transmission in transmissions {
        switch transmission {
        case let .aecpCommand(transaction):
          // a command cancelled, or completed, while it was queued is not sent
          guard !transaction.promise.isResolved else { continue }
          do {
            try await endStation.send(.aecp(transaction.aecpdu), to: transaction.destination)
            await self?._aecpCommandSent(transaction)
          } catch {
            await self?._completeAecpCommand(
              transaction.aecpdu.targetEntityID,
              sequenceID: transaction.sequenceID,
              with: .failure(CommandError.networkError(error))
            )
          }
        case let .acmpCommand(transaction, sequenceID):
          guard !transaction.promise.isResolved else { continue }
          do {
            try await endStation.send(.acmp(transaction.acmpdu), to: AvdeccMulticastMacAddress)
            await self?._acmpCommandSent(sequenceID: sequenceID, timer: transaction.timer)
          } catch {
            await self?._acmpCommandSendFailed(sequenceID: sequenceID, timer: transaction.timer, error: error)
          }
        case let .pdu(pdu, destination):
          do {
            try await endStation.send(pdu, to: destination)
          } catch {
            logger.debug("\(entityID): transmission failed: \(error)")
          }
        }
      }
    }
    do {
      try await discoverRemoteEntities()
    } catch {
      _transmissions.finish()
      await endStation.unregister(entityID)
      throw error
    }
    _maintenanceTask = Task { [weak self, timing] in
      while !Task.isCancelled {
        try? await Task.sleep(for: timing.maintenanceInterval)
        await self?._maintainDiscovery()
      }
    }
  }

  deinit {
    _maintenanceTask?.cancel()
    _advertising?.timer.stop()
    _transmissions.finish()
  }

  /// Fails pending commands, stops advertising (sending ENTITY_DEPARTING), finishes event
  /// streams and detaches from the end station. Idempotent. Closing does not wait for the
  /// deregistrations and ENTITY_DEPARTING to be sent.
  public func close() async {
    guard !_isClosed else { return }
    _isClosed = true
    _maintenanceTask?.cancel()

    for transaction in _aecpTargets.values.flatMap({ $0.inflight + $0.queued }) {
      transaction.timer.stop()
      transaction.promise.resolve(.failure(CommandError.closed))
    }
    _aecpTargets = [:]
    for transaction in _acmpTransactions.values {
      transaction.timer.stop()
      transaction.promise.resolve(.failure(CommandError.closed))
    }
    _acmpTransactions = [:]

    _deregisterUnsolicitedNotifications()
    if let advertising = _advertising {
      _advertising = nil
      advertising.timer.stop()
      _sendAdvertisement(.entityDeparting, advertising)
    }
    // what is already queued is still sent
    _transmissions.finish()

    for continuation in _subscribers.values {
      continuation.finish()
    }
    _subscribers = [:]
    _discovery = DiscoveryStateMachine()
    await endStation.unregister(entityID)
  }

  // MARK: - Events

  /// A stream of this controller's events, beginning with `entityOnline` for each entity
  /// already discovered. Each call returns an independent stream, which buffers so that the
  /// receive path never waits on a slow consumer.
  public func events() -> AsyncStream<ControllerEvent> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: ControllerEvent.self,
      bufferingPolicy: .unbounded
    )
    guard !_isClosed else {
      continuation.finish()
      return stream
    }
    let id = _nextSubscriberID
    _nextSubscriberID += 1
    _subscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?._removeSubscriber(id) }
    }
    for entity in _discovery.entities {
      continuation.yield(.entityOnline(entity.entityID))
    }
    return stream
  }

  private func _removeSubscriber(_ id: Int) {
    _subscribers[id] = nil
  }

  private func _yield(_ event: ControllerEvent) {
    for continuation in _subscribers.values {
      continuation.yield(event)
    }
  }

  func _handleTransportError() {
    _yield(.transportError)
  }

  // MARK: - Discovery

  /// Remote entities currently discovered by this controller.
  public var discoveredEntities: [Entity] {
    _discovery.entities
  }

  public func discoveredEntity(id: UniqueIdentifier) -> Entity? {
    _discovery.entity(id: id)
  }

  /// Drops `id` from the discovered entities, raising `entityOffline`; its next advertisement
  /// brings it back online.
  public func forgetRemoteEntity(_ id: UniqueIdentifier) {
    _apply(_discovery.forget(id))
  }

  /// Sends ENTITY_DISCOVER for every entity (IEEE 1722.1-2021 §6.2.6).
  public func discoverRemoteEntities() async throws {
    try await _discover(entityID: UniqueIdentifier())
  }

  /// Sends ENTITY_DISCOVER for a single entity.
  public func discoverRemoteEntity(id: UniqueIdentifier) async throws {
    try await _discover(entityID: id)
  }

  /// Sends ENTITY_DISCOVER periodically, or never (the default) if `delay` is nil or zero.
  public func setAutomaticDiscoveryDelay(_ delay: Duration?) {
    _automaticDiscoveryDelay = delay.flatMap { $0 > .zero ? $0 : nil }
    _lastDiscovery = .now
  }

  private func _discover(entityID: UniqueIdentifier) async throws {
    _lastDiscovery = .now
    try await endStation.send(
      .adp(Adpdu(messageType: .entityDiscover, validTime: 0, entityID: entityID)),
      to: AvdeccMulticastMacAddress
    )
  }

  private func _apply(_ events: [DiscoveryEvent]) {
    for event in events {
      switch event {
      case let .online(entity):
        _yield(.entityOnline(entity.entityID))
      case let .updated(entity):
        _yield(.entityUpdated(entity.entityID))
      case let .offline(entityID):
        _yield(.entityOffline(entityID))
        _failAecpCommands(towards: entityID)
        // an entity that returns has lost its registrations
        _dropUnsolicitedNotificationRegistration(entityID)
      }
    }
  }

  private func _maintainDiscovery() async {
    guard !_isClosed else { return }
    _apply(_discovery.expire())
    _renewUnsolicitedNotificationRegistrations()
    guard let delay = _automaticDiscoveryDelay, ContinuousClock.now - _lastDiscovery >= delay
    else { return }
    do {
      try await discoverRemoteEntities()
    } catch {
      _logger.debug("\(entityID): automatic discovery failed: \(error)")
    }
  }

  func _handle(_ adpdu: Adpdu, from sourceMacAddress: EUI48) {
    switch adpdu.messageType {
    case .entityAvailable:
      _apply(_discovery.handleEntityAvailable(adpdu, macAddress: sourceMacAddress.bytes))
    case .entityDeparting:
      _apply(_discovery.handleEntityDeparting(adpdu))
    case .entityDiscover:
      // entity_id 0 discovers every entity (IEEE 1722.1-2021 §6.2.6.3); like la_avdecc, an
      // all-ones entity_id is also taken to mean every entity
      guard adpdu.entityID == UniqueIdentifier() || adpdu.entityID == .null ||
        adpdu.entityID == entityID,
            let advertising = _advertising
      else { return }
      advertising.timer.start(interval: _randomAdvertisingDelay(validTime: advertising.validTime))
    }
  }

  // MARK: - Advertising

  /// Advertises again, after the random delay, when the link comes up (lastLinkIsUp in IEEE
  /// 1722.1-2021 Figure 6-5).
  func _handleLinkState(isUp: Bool) {
    guard isUp != _lastLinkIsUp else { return }
    _lastLinkIsUp = isUp
    guard isUp, !_isClosed, let advertising = _advertising else { return }
    advertising.timer.start(interval: _randomAdvertisingDelay(validTime: advertising.validTime))
  }

  /// Advertises this controller with ENTITY_AVAILABLE (IEEE 1722.1-2021 §6.2.4), declaring it
  /// available for `availableDuration` (2 to 62 seconds) after each advertisement.
  public func enableEntityAdvertising(
    availableDuration: Duration = .seconds(62),
    interfaceIndex: UInt16? = nil
  ) throws {
    guard !_isClosed else { throw EndStationError.closed }
    guard _availableDurationRange.contains(availableDuration) else {
      throw AemStatus.badArguments
    }
    let validTime = UInt8(availableDuration.components.seconds / 2)
    let timer = Timer(label: "\(entityID) advertising") { [weak self] in
      await self?._advertise()
    }
    _advertising?.timer.stop()
    _advertising = Advertising(validTime: validTime, interfaceIndex: interfaceIndex, timer: timer)
    timer.start(interval: _randomAdvertisingDelay(validTime: validTime))
  }

  /// Stops advertising, sending ENTITY_DEPARTING.
  public func disableEntityAdvertising() async {
    guard let advertising = _advertising else { return }
    _advertising = nil
    advertising.timer.stop()
    _sendAdvertisement(.entityDeparting, advertising)
  }

  /// A uniformly distributed delay of up to a fifth of the valid period, so that entities
  /// answering the same DISCOVER do not all transmit at once (IEEE 1722.1-2021 §6.2.4.2.2).
  private func _randomAdvertisingDelay(validTime: UInt8) -> Duration {
    let maximum = max(Int(validTime) * 2 * 1000 / 5, 1)
    return .milliseconds(Int.random(in: 0..<maximum))
  }

  private func _advertise() {
    guard let advertising = _advertising else { return }
    _sendAdvertisement(.entityAvailable, advertising)
    // re-advertise after a quarter of the valid period, plus jitter
    let interval = Duration.milliseconds(max(1000, Int(advertising.validTime) * 1000 / 2))
    advertising.timer.start(interval: interval + _randomAdvertisingDelay(validTime: advertising.validTime))
  }

  private func _sendAdvertisement(_ messageType: AdpMessageType, _ advertising: Advertising) {
    // valid_time and available_index are zero except in ENTITY_AVAILABLE, whose available_index
    // increases with each one sent (IEEE 1722.1-2021 §6.2.2.5, §6.2.2.15)
    let isAvailable = messageType == .entityAvailable
    let adpdu = Adpdu(
      messageType: messageType,
      validTime: isAvailable ? advertising.validTime : 0,
      entityID: entityID,
      entityCapabilities: advertising.interfaceIndex == nil ? [] : .aemInterfaceIndexValid,
      controllerCapabilities: .implemented,
      availableIndex: isAvailable ? _availableIndex : 0,
      interfaceIndex: advertising.interfaceIndex ?? 0
    )
    if isAvailable {
      _availableIndex &+= 1
    }
    _transmissions.yield(.pdu(.adp(adpdu), destination: AvdeccMulticastMacAddress))
  }

  // MARK: - Unsolicited notification registrations

  /// Registrations are time limited, so that entities stop sending notifications to a
  /// controller that has gone away, and renewed until deregistered. An entity that rejects the
  /// flags field, predating IEEE 1722.1-2021, is registered without it.
  private func _registerUnsolicitedNotifications(_ targetEntityID: UniqueIdentifier) async throws {
    let id = _nextUnsolicitedNotificationRegistration
    _nextUnsolicitedNotificationRegistration += 1
    // recorded before sending, so that deregistering during the command supersedes it
    _dropUnsolicitedNotificationRegistration(targetEntityID)
    _unsolicitedNotificationRegistrations[targetEntityID] = UnsolicitedNotificationRegistration(
      id: id,
      renewalTime: .now + _timing.unsolicitedNotificationRenewalInterval
    )

    let isTimeLimited: Bool
    do {
      do {
        _ = try await _aem(targetEntityID, .registerUnsolicitedNotification(flags: .timeLimited))
        isTimeLimited = true
      } catch AemStatus.badArguments {
        _ = try await _aem(targetEntityID, .registerUnsolicitedNotification(flags: []))
        isTimeLimited = false
      }
    } catch {
      if _unsolicitedNotificationRegistrations[targetEntityID]?.id == id {
        _dropUnsolicitedNotificationRegistration(targetEntityID)
      }
      throw error
    }

    guard var registration = _unsolicitedNotificationRegistrations[targetEntityID],
          registration.id == id
    else { return }
    registration.isTimeLimited = isTimeLimited
    registration.renewalTime = .now + _timing.unsolicitedNotificationRenewalInterval
    _unsolicitedNotificationRegistrations[targetEntityID] = registration
  }

  private func _deregisterUnsolicitedNotifications(_ targetEntityID: UniqueIdentifier) async throws {
    _dropUnsolicitedNotificationRegistration(targetEntityID)
    // an entity that is not discovered holds no registration to remove: it was dropped when
    // the entity went offline, and there is nowhere to send the command
    guard _discovery.entity(id: targetEntityID) != nil else { return }
    _ = try await _aem(targetEntityID, .deregisterUnsolicitedNotification)
  }

  /// Forgets the registration with an entity, cancelling any renewal in progress.
  private func _dropUnsolicitedNotificationRegistration(_ targetEntityID: UniqueIdentifier) {
    _unsolicitedNotificationRegistrations.removeValue(forKey: targetEntityID)?.renewal?.cancel()
  }

  private func _renewUnsolicitedNotificationRegistrations() {
    let now = ContinuousClock.now
    for (targetEntityID, registration) in _unsolicitedNotificationRegistrations
      where (registration.isTimeLimited == true || registration.retryDelay != nil) &&
      registration.renewal == nil && now >= registration.renewalTime
    {
      _startRenewingUnsolicitedNotificationRegistration(targetEntityID)
    }
  }

  /// Registers again, in the background so that expiry and discovery are not held up.
  private func _startRenewingUnsolicitedNotificationRegistration(_ targetEntityID: UniqueIdentifier) {
    guard let registration = _unsolicitedNotificationRegistrations[targetEntityID],
          registration.renewal == nil
    else { return }
    let id = registration.id
    let flags: RegisterUnsolicitedNotificationFlags = registration.isTimeLimited == false ? [] : .timeLimited
    _unsolicitedNotificationRegistrations[targetEntityID]?.renewal = Task { [weak self] in
      await self?._renewUnsolicitedNotificationRegistration(targetEntityID, id: id, flags: flags)
    }
  }

  private func _renewUnsolicitedNotificationRegistration(
    _ targetEntityID: UniqueIdentifier,
    id: UInt64,
    flags: RegisterUnsolicitedNotificationFlags
  ) async {
    guard _unsolicitedNotificationRegistrations[targetEntityID]?.id == id else { return }
    var failure: (any Error)?
    do {
      _ = try await _aem(targetEntityID, .registerUnsolicitedNotification(flags: flags))
    } catch {
      failure = error
    }

    // a registration dropped meanwhile, by deregistering or by its entity going offline, is
    // not recorded again
    guard var registration = _unsolicitedNotificationRegistrations[targetEntityID],
          registration.id == id
    else { return }
    registration.renewal = nil
    if let failure {
      let retryDelays = _timing.unsolicitedNotificationRetryDelay
      let delay = registration.retryDelay.map { min($0 * 2, retryDelays.upperBound) } ??
        retryDelays.lowerBound
      _logger.debug("\(entityID): renewing unsolicited notifications from \(targetEntityID) failed, retrying in \(delay): \(failure)")
      registration.retryDelay = delay
      registration.renewalTime = .now + delay
    } else {
      registration.retryDelay = nil
      registration.renewalTime = .now + _timing.unsolicitedNotificationRenewalInterval
    }
    _unsolicitedNotificationRegistrations[targetEntityID] = registration
  }

  /// Deregisters from every entity on closing, for entities that predate time-limited
  /// registration. The commands are queued, not awaited, as closing does not wait for them.
  private func _deregisterUnsolicitedNotifications() {
    let registrations = _unsolicitedNotificationRegistrations
    _unsolicitedNotificationRegistrations = [:]
    for (targetEntityID, registration) in registrations {
      registration.renewal?.cancel()
      guard let macAddress = _discovery.entity(id: targetEntityID)?.macAddress else { continue }
      let sequenceID = _aecpSequenceID
      _aecpSequenceID &+= 1
      _transmissions.yield(.pdu(.aecp(.aem(AemAecpdu(
        isResponse: false,
        targetEntityID: targetEntityID,
        controllerEntityID: entityID,
        sequenceID: sequenceID,
        commandType: .deregisterUnsolicitedNotification
      ))), destination: EUI48(bytes: macAddress)))
    }
  }

  // MARK: - AECP transactions

  private func _sendAecpCommand(
    to targetEntityID: UniqueIdentifier,
    _ makeAecpdu: (UInt16) -> Aecpdu
  ) async throws -> Aecpdu {
    guard !_isClosed else { throw CommandError.closed }
    guard let macAddress = _discovery.entity(id: targetEntityID)?.macAddress else {
      throw CommandError.unknownEntity
    }

    let sequenceID = _aecpSequenceID
    _aecpSequenceID &+= 1
    let promise = Promise<Aecpdu>()
    let timer = Timer(label: "AECP \(targetEntityID) #\(sequenceID)") { [weak self] in
      await self?._aecpCommandTimedOut(targetEntityID, sequenceID: sequenceID)
    }
    _aecpTargets[targetEntityID, default: AecpTarget()].queued.append(AecpTransaction(
      sequenceID: sequenceID,
      aecpdu: makeAecpdu(sequenceID),
      destination: EUI48(bytes: macAddress),
      promise: promise,
      timer: timer
    ))
    _transmit(_dequeueAecpCommands(targetEntityID))

    return try await withTaskCancellationHandler {
      try await promise.value
    } onCancel: { [weak self] in
      promise.resolve(.failure(CancellationError()))
      // stop retrying it, and free its place in flight
      Task { await self?._cancelAecpCommand(targetEntityID, sequenceID: sequenceID) }
    }
  }

  /// Moves queued commands in flight while there is room.
  private func _dequeueAecpCommands(_ targetEntityID: UniqueIdentifier) -> [AecpTransaction] {
    guard var target = _aecpTargets[targetEntityID] else { return [] }
    var transmit = [AecpTransaction]()
    while target.inflight.count < _maximumInflightAecpCommands, !target.queued.isEmpty {
      let transaction = target.queued.removeFirst()
      target.inflight.append(transaction)
      transmit.append(transaction)
    }
    _aecpTargets[targetEntityID] = target.inflight.isEmpty && target.queued.isEmpty ? nil : target
    return transmit
  }

  /// Queues in-flight commands for the transmit task, which starts each one's timeout once it
  /// has been sent (txCommand, IEEE 1722.1-2021 §9.3.6).
  private func _transmit(_ transactions: [AecpTransaction]) {
    for transaction in transactions {
      _transmissions.yield(.aecpCommand(transaction))
    }
  }

  private func _aecpCommandSent(_ transaction: AecpTransaction) {
    let targetEntityID = transaction.aecpdu.targetEntityID
    // it may have been answered or cancelled during the send
    guard !transaction.promise.isResolved,
          var target = _aecpTargets[targetEntityID],
          let index = target.inflight.firstIndex(where: { $0.sequenceID == transaction.sequenceID })
    else { return }
    target.inflight[index].sendTime = .now
    _aecpTargets[targetEntityID] = target
    transaction.timer.start(interval: _timing.aecpCommandTimeout)
  }

  private func _cancelAecpCommand(_ targetEntityID: UniqueIdentifier, sequenceID: UInt16) {
    guard var target = _aecpTargets[targetEntityID] else { return }
    if let index = target.queued.firstIndex(where: { $0.sequenceID == sequenceID }) {
      target.queued.remove(at: index)
      _aecpTargets[targetEntityID] = target.inflight.isEmpty && target.queued.isEmpty ? nil : target
    } else {
      _completeAecpCommand(targetEntityID, sequenceID: sequenceID, with: .failure(CancellationError()))
    }
  }

  private func _completeAecpCommand(
    _ targetEntityID: UniqueIdentifier,
    sequenceID: UInt16,
    with result: Result<Aecpdu, any Error>
  ) {
    guard var target = _aecpTargets[targetEntityID],
          let index = target.inflight.firstIndex(where: { $0.sequenceID == sequenceID })
    else { return }
    let transaction = target.inflight.remove(at: index)
    _aecpTargets[targetEntityID] = target
    transaction.timer.stop()
    transaction.promise.resolve(result)
    _transmit(_dequeueAecpCommands(targetEntityID))
  }

  private func _aecpCommandTimedOut(_ targetEntityID: UniqueIdentifier, sequenceID: UInt16) {
    guard var target = _aecpTargets[targetEntityID],
          let index = target.inflight.firstIndex(where: { $0.sequenceID == sequenceID }),
          // a timer restarted since it fired, by IN_PROGRESS or a retry, supersedes this expiry
          !target.inflight[index].timer.isRunning
    else { return }

    // a command cancelled since is not retried; the cancellation completes it
    guard !target.inflight[index].promise.isResolved else {
      _completeAecpCommand(targetEntityID, sequenceID: sequenceID, with: .failure(CancellationError()))
      return
    }

    guard !target.inflight[index].retried else {
      _yield(.aecpTimeout(targetEntityID))
      _completeAecpCommand(targetEntityID, sequenceID: sequenceID, with: .failure(CommandError.timedOut))
      return
    }

    target.inflight[index].retried = true
    _aecpTargets[targetEntityID] = target
    _yield(.aecpRetry(targetEntityID))
    _transmit([target.inflight[index]])
  }

  private func _failAecpCommands(towards targetEntityID: UniqueIdentifier) {
    guard let target = _aecpTargets.removeValue(forKey: targetEntityID) else { return }
    for transaction in target.inflight + target.queued {
      transaction.timer.stop()
      transaction.promise.resolve(.failure(CommandError.unknownEntity))
    }
  }

  func _handle(_ aecpdu: Aecpdu, from sourceMacAddress: EUI48) {
    switch aecpdu {
    case let .aem(aem):
      guard aem.isResponse else {
        _respond(to: aem, from: sourceMacAddress)
        return
      }
      if aem.unsolicited, aem.controllerEntityID == IdentifyNotificationControllerEntityID {
        _yield(.entityIdentifyNotification(aem.targetEntityID))
        return
      }
      guard aem.controllerEntityID == entityID else { return }
      if aem.unsolicited {
        _handleUnsolicitedResponse(aem)
        _yield(.aemAecpUnsolicitedReceived(aem.targetEntityID, sequenceID: aem.sequenceID))
      } else {
        _handleAecpResponse(
          aecpdu,
          inProgress: aem.status == AemStatus.inProgress.rawValue,
          from: sourceMacAddress
        )
      }
    case let .mvu(mvu):
      guard mvu.isResponse, mvu.controllerEntityID == entityID else { return }
      if mvu.unsolicited {
        _handleUnsolicitedResponse(mvu)
        _yield(.mvuAecpUnsolicitedReceived(mvu.targetEntityID, sequenceID: mvu.sequenceID))
      } else {
        _handleAecpResponse(aecpdu, inProgress: false, from: sourceMacAddress)
      }
    case .other:
      break
    }
  }

  /// Answers AEM commands addressed to this controller: CONTROLLER_AVAILABLE succeeds, so that
  /// an entity this controller has acquired is not taken by another controller (IEEE
  /// 1722.1-2021 §7.4.1), and any other command is not implemented (§9.3.5.3.3).
  private func _respond(to command: AemAecpdu, from sourceMacAddress: EUI48) {
    guard !_isClosed, command.targetEntityID == entityID else { return }
    var response = command
    response.isResponse = true
    response.unsolicited = false
    let status: AemStatus = command.commandType == .controllerAvailable ? .success : .notImplemented
    response.status = UInt8(status.rawValue)
    _transmissions.yield(.pdu(.aecp(.aem(response)), destination: sourceMacAddress))
  }

  private func _handleAecpResponse(
    _ aecpdu: Aecpdu,
    inProgress: Bool,
    from sourceMacAddress: EUI48
  ) {
    let targetEntityID = aecpdu.targetEntityID
    let sequenceID = aecpdu.sequenceID
    guard let transaction = _aecpTargets[targetEntityID]?.inflight
      .first(where: { $0.sequenceID == sequenceID })
    else {
      _yield(.aecpUnexpectedResponse(targetEntityID))
      return
    }
    guard _isEqualMacAddress(transaction.destination, sourceMacAddress) else {
      _logger.debug("\(entityID): ignoring response #\(sequenceID) for \(targetEntityID) from \(_macAddressToString(sourceMacAddress))")
      return
    }
    guard !inProgress else {
      // response times are measured from the last IN_PROGRESS, as la_avdecc does
      if var target = _aecpTargets[targetEntityID],
         let index = target.inflight.firstIndex(where: { $0.sequenceID == sequenceID })
      {
        target.inflight[index].sendTime = .now
        _aecpTargets[targetEntityID] = target
      }
      transaction.timer.start(interval: _timing.aecpCommandTimeout)
      return
    }
    let responseTime = ContinuousClock.now - transaction.sendTime
    _completeAecpCommand(targetEntityID, sequenceID: sequenceID, with: .success(aecpdu))
    _yield(.aecpResponseTime(targetEntityID, responseTime: responseTime.wholeMilliseconds))
  }

  /// Sends an AEM command and returns its decoded successful response.
  private func _aem(
    _ targetEntityID: UniqueIdentifier,
    _ command: AemCommandPayload
  ) async throws -> AemResponsePayload {
    let commandSpecificData: [UInt8]
    do {
      commandSpecificData = try command.serialized()
    } catch {
      throw AemStatus.badArguments
    }

    let response: Aecpdu
    do {
      response = try await _sendAecpCommand(to: targetEntityID) { sequenceID in
        var aem = AemAecpdu(
          isResponse: false,
          targetEntityID: targetEntityID,
          controllerEntityID: entityID,
          sequenceID: sequenceID,
          commandType: .invalidCommandType,
          commandSpecificData: commandSpecificData
        )
        aem.commandTypeRaw = command.commandTypeRaw
        return .aem(aem)
      }
    } catch let error as CommandError {
      throw AemStatus(error)
    }

    guard case let .aem(aem) = response, aem.commandTypeRaw == command.commandTypeRaw else {
      throw AemStatus.protocolError
    }
    guard aem.status == AemStatus.success.rawValue else {
      throw AemStatus(UInt16(aem.status))
    }
    do {
      return try AemResponsePayload(commandTypeRaw: aem.commandTypeRaw, data: aem.commandSpecificData)
    } catch {
      throw AemStatus.protocolError
    }
  }

  /// Sends a Milan MVU command and returns its decoded successful response.
  private func _mvu(
    _ targetEntityID: UniqueIdentifier,
    _ command: MvuCommandPayload
  ) async throws -> MvuResponsePayload {
    let commandSpecificData: [UInt8]
    do {
      commandSpecificData = try command.serialized()
    } catch {
      throw MvuStatus.badArguments
    }

    let response: Aecpdu
    do {
      response = try await _sendAecpCommand(to: targetEntityID) { sequenceID in
        var mvu = MvuAecpdu(
          isResponse: false,
          targetEntityID: targetEntityID,
          controllerEntityID: entityID,
          sequenceID: sequenceID,
          commandType: .invalidCommandType,
          commandSpecificData: commandSpecificData
        )
        mvu.commandTypeRaw = command.commandTypeRaw
        return .mvu(mvu)
      }
    } catch let error as CommandError {
      throw MvuStatus(error)
    }

    guard case let .mvu(mvu) = response, mvu.commandTypeRaw == command.commandTypeRaw else {
      throw MvuStatus.protocolError
    }
    guard mvu.status == MvuStatus.success.rawValue else {
      throw MvuStatus(UInt16(mvu.status))
    }
    do {
      return try MvuResponsePayload(commandTypeRaw: mvu.commandTypeRaw, data: mvu.commandSpecificData)
    } catch {
      throw MvuStatus.protocolError
    }
  }

  // MARK: - Unsolicited notifications

  private func _handleUnsolicitedResponse(_ aem: AemAecpdu) {
    guard aem.status == AemStatus.success.rawValue,
          let payload = try? AemResponsePayload(
            commandTypeRaw: aem.commandTypeRaw,
            data: aem.commandSpecificData
          )
    else { return }
    let id = aem.targetEntityID

    switch payload {
    case let .acquireEntity(flags, ownerID, descriptorType, descriptorIndex):
      _yield(flags.contains(.release)
        ? .entityReleased(id, owningEntity: ownerID, descriptorType: descriptorType.rawValue, descriptorIndex: descriptorIndex)
        : .entityAcquired(id, owningEntity: ownerID, descriptorType: descriptorType.rawValue, descriptorIndex: descriptorIndex))
    case let .lockEntity(flags, lockedID, descriptorType, descriptorIndex):
      _yield(flags.contains(.unlock)
        ? .entityUnlocked(id, lockingEntity: lockedID, descriptorType: descriptorType.rawValue, descriptorIndex: descriptorIndex)
        : .entityLocked(id, lockingEntity: lockedID, descriptorType: descriptorType.rawValue, descriptorIndex: descriptorIndex))
    case let .setConfiguration(configurationIndex), let .getConfiguration(configurationIndex):
      _yield(.configurationChanged(id, configurationIndex: configurationIndex))
    case let .setStreamFormat(descriptorType, descriptorIndex, streamFormat),
         let .getStreamFormat(descriptorType, descriptorIndex, streamFormat):
      switch descriptorType {
      case .streamInput:
        _yield(.streamInputFormatChanged(id, streamIndex: descriptorIndex, streamFormat: streamFormat))
      case .streamOutput:
        _yield(.streamOutputFormatChanged(id, streamIndex: descriptorIndex, streamFormat: streamFormat))
      default:
        break
      }
    case let .setStreamInfo(descriptorType, descriptorIndex, streamInfo):
      _yieldStreamInfoChanged(id, descriptorType, descriptorIndex, streamInfo, fromGetResponse: false)
    case let .getStreamInfo(descriptorType, descriptorIndex, streamInfo):
      _yieldStreamInfoChanged(id, descriptorType, descriptorIndex, streamInfo, fromGetResponse: true)
    case let .setName(descriptorType, descriptorIndex, nameIndex, configurationIndex, name),
         let .getName(descriptorType, descriptorIndex, nameIndex, configurationIndex, name):
      _yieldNameChanged(id, descriptorType, descriptorIndex, nameIndex, configurationIndex, name)
    case let .setAssociationID(associationID), let .getAssociationID(associationID):
      _yield(.associationIDChanged(id, associationID: associationID))
    case let .setSamplingRate(descriptorType, descriptorIndex, samplingRate),
         let .getSamplingRate(descriptorType, descriptorIndex, samplingRate):
      switch descriptorType {
      case .audioUnit:
        _yield(.audioUnitSamplingRateChanged(id, audioUnitIndex: descriptorIndex, samplingRate: samplingRate.rawValue))
      case .videoCluster:
        _yield(.videoClusterSamplingRateChanged(id, videoClusterIndex: descriptorIndex, samplingRate: samplingRate.rawValue))
      case .sensorCluster:
        _yield(.sensorClusterSamplingRateChanged(id, sensorClusterIndex: descriptorIndex, samplingRate: samplingRate.rawValue))
      default:
        break
      }
    case let .setClockSource(descriptorType, descriptorIndex, clockSourceIndex),
         let .getClockSource(descriptorType, descriptorIndex, clockSourceIndex):
      guard descriptorType == .clockDomain else { break }
      _yield(.clockSourceChanged(id, clockDomainIndex: descriptorIndex, clockSourceIndex: clockSourceIndex))
    case let .setControl(descriptorType, descriptorIndex, packedControlValues),
         let .getControl(descriptorType, descriptorIndex, packedControlValues):
      guard descriptorType == .control else { break }
      _yield(.controlValuesChanged(id, controlIndex: descriptorIndex, packedControlValues: packedControlValues))
    case let .startStreaming(descriptorType, descriptorIndex):
      switch descriptorType {
      case .streamInput: _yield(.streamInputStarted(id, streamIndex: descriptorIndex))
      case .streamOutput: _yield(.streamOutputStarted(id, streamIndex: descriptorIndex))
      default: break
      }
    case let .stopStreaming(descriptorType, descriptorIndex):
      switch descriptorType {
      case .streamInput: _yield(.streamInputStopped(id, streamIndex: descriptorIndex))
      case .streamOutput: _yield(.streamOutputStopped(id, streamIndex: descriptorIndex))
      default: break
      }
    case .deregisterUnsolicitedNotification:
      // the entity removed a registration that was not renewed in time (§7.4.37.2); one that
      // is still wanted is registered again
      _yield(.deregisteredFromUnsolicitedNotifications(id))
      _startRenewingUnsolicitedNotificationRegistration(id)
    case let .getAvbInfo(descriptorType, descriptorIndex, avbInfo):
      guard descriptorType == .avbInterface else { break }
      _yield(.avbInfoChanged(id, avbInterfaceIndex: descriptorIndex, info: avbInfo))
    case let .getAsPath(descriptorIndex, asPath):
      _yield(.asPathChanged(id, avbInterfaceIndex: descriptorIndex, asPath: asPath.sequence))
    case let .getCounters(descriptorType, descriptorIndex, countersValid, counters):
      switch descriptorType {
      case .entity:
        _yield(.entityCountersChanged(id, valid: EntityCounterValidFlags(rawValue: countersValid), counters: counters))
      case .avbInterface:
        _yield(.avbInterfaceCountersChanged(id, avbInterfaceIndex: descriptorIndex, valid: AvbInterfaceCounterValidFlags(rawValue: countersValid), counters: counters))
      case .clockDomain:
        _yield(.clockDomainCountersChanged(id, clockDomainIndex: descriptorIndex, valid: ClockDomainCounterValidFlags(rawValue: countersValid), counters: counters))
      case .streamInput:
        _yield(.streamInputCountersChanged(id, streamIndex: descriptorIndex, valid: StreamInputCounterValidFlags(rawValue: countersValid), counters: counters))
      case .streamOutput:
        _yield(.streamOutputCountersChanged(id, streamIndex: descriptorIndex, valid: StreamOutputCounterValidFlags(rawValue: countersValid), counters: counters))
      default:
        break
      }
    case let .getAudioMap(descriptorType, descriptorIndex, _, _, mappings):
      switch descriptorType {
      case .streamPortInput:
        _yield(.streamPortInputAudioMappingsChanged(id, streamPortIndex: descriptorIndex, mappings: mappings))
      case .streamPortOutput:
        _yield(.streamPortOutputAudioMappingsChanged(id, streamPortIndex: descriptorIndex, mappings: mappings))
      default:
        break
      }
    case let .addAudioMappings(descriptorType, descriptorIndex, mappings):
      switch descriptorType {
      case .streamPortInput:
        _yield(.streamPortInputAudioMappingsAdded(id, streamPortIndex: descriptorIndex, mappings: mappings))
      case .streamPortOutput:
        _yield(.streamPortOutputAudioMappingsAdded(id, streamPortIndex: descriptorIndex, mappings: mappings))
      default:
        break
      }
    case let .removeAudioMappings(descriptorType, descriptorIndex, mappings):
      switch descriptorType {
      case .streamPortInput:
        _yield(.streamPortInputAudioMappingsRemoved(id, streamPortIndex: descriptorIndex, mappings: mappings))
      case .streamPortOutput:
        _yield(.streamPortOutputAudioMappingsRemoved(id, streamPortIndex: descriptorIndex, mappings: mappings))
      default:
        break
      }
    case let .operationStatus(descriptorType, descriptorIndex, operationID, percentComplete):
      _yield(.operationStatus(id, descriptorType: descriptorType.rawValue, descriptorIndex: descriptorIndex, operationID: operationID, percentComplete: percentComplete))
    case let .setMemoryObjectLength(configurationIndex, memoryObjectIndex, length),
         let .getMemoryObjectLength(configurationIndex, memoryObjectIndex, length):
      _yield(.memoryObjectLengthChanged(id, configurationIndex: configurationIndex, memoryObjectIndex: memoryObjectIndex, length: length))
    case let .setMaxTransitTime(descriptorType, descriptorIndex, maxTransitTime),
         let .getMaxTransitTime(descriptorType, descriptorIndex, maxTransitTime):
      guard descriptorType == .streamOutput else { break }
      _yield(.maxTransitTimeChanged(id, streamIndex: descriptorIndex, maxTransitTime: maxTransitTime))
    case .entityAvailable, .controllerAvailable, .readDescriptor, .registerUnsolicitedNotification,
         .reboot, .startOperation, .abortOperation, .other:
      break
    }
  }

  private func _yieldStreamInfoChanged(
    _ id: UniqueIdentifier,
    _ descriptorType: DescriptorType,
    _ descriptorIndex: DescriptorIndex,
    _ streamInfo: StreamInfo,
    fromGetResponse: Bool
  ) {
    switch descriptorType {
    case .streamInput:
      _yield(.streamInputInfoChanged(id, streamIndex: descriptorIndex, info: streamInfo, fromGetResponse: fromGetResponse))
    case .streamOutput:
      _yield(.streamOutputInfoChanged(id, streamIndex: descriptorIndex, info: streamInfo, fromGetResponse: fromGetResponse))
    default:
      break
    }
  }

  private func _yieldNameChanged(
    _ id: UniqueIdentifier,
    _ descriptorType: DescriptorType,
    _ descriptorIndex: DescriptorIndex,
    _ nameIndex: UInt16,
    _ configurationIndex: UInt16,
    _ name: String
  ) {
    switch (descriptorType, nameIndex) {
    case (.entity, _entityNameIndex):
      _yield(.entityNameChanged(id, name: name))
    case (.entity, _entityGroupNameIndex):
      _yield(.entityGroupNameChanged(id, name: name))
    case (.configuration, _objectNameIndex):
      _yield(.descriptorNameChanged(id, descriptorType: .configuration, configurationIndex: descriptorIndex, descriptorIndex: descriptorIndex, name: name))
    case (_, _objectNameIndex):
      _yield(.descriptorNameChanged(id, descriptorType: descriptorType, configurationIndex: configurationIndex, descriptorIndex: descriptorIndex, name: name))
    default:
      break
    }
  }

  private func _handleUnsolicitedResponse(_ mvu: MvuAecpdu) {
    guard mvu.status == MvuStatus.success.rawValue,
          let payload = try? MvuResponsePayload(
            commandTypeRaw: mvu.commandTypeRaw,
            data: mvu.commandSpecificData
          )
    else { return }
    let id = mvu.targetEntityID

    switch payload {
    case let .setSystemUniqueID(systemUniqueID, systemName),
         let .getSystemUniqueID(systemUniqueID, systemName):
      _yield(.systemUniqueIDChanged(id, systemUniqueID: systemUniqueID, systemName: systemName))
    case let .setMediaClockReferenceInfo(clockDomainIndex, defaultPriority, info),
         let .getMediaClockReferenceInfo(clockDomainIndex, defaultPriority, info):
      _yield(.mediaClockReferenceInfoChanged(id, clockDomainIndex: clockDomainIndex, defaultPriority: defaultPriority, info: info))
    case let .bindStream(flags, _, descriptorIndex, talkerStream):
      _yield(.bindStream(id, streamIndex: descriptorIndex, talker: talkerStream, flags: flags))
    case let .unbindStream(_, descriptorIndex):
      _yield(.unbindStream(id, streamIndex: descriptorIndex))
    case let .getStreamInputInfoEx(_, descriptorIndex, info):
      _yield(.streamInputInfoExChanged(id, streamIndex: descriptorIndex, info: info))
    case .getMilanInfo, .other:
      break
    }
  }

  // MARK: - ACMP transactions

  private func _acmp(
    _ messageType: AcmpMessageType,
    talker: StreamIdentification,
    listener: StreamIdentification,
    connectionCount: UInt16 = 0
  ) async throws -> StreamConnectionState {
    guard !_isClosed else { throw AcmpStatus.internalError }

    let sequenceID = _acmpSequenceID
    _acmpSequenceID &+= 1
    let acmpdu = Acmpdu(
      messageType: messageType,
      controllerEntityID: entityID,
      talkerEntityID: talker.entityID,
      listenerEntityID: listener.entityID,
      talkerUniqueID: talker.streamIndex,
      listenerUniqueID: listener.streamIndex,
      connectionCount: connectionCount,
      sequenceID: sequenceID
    )
    let promise = Promise<Acmpdu>()
    let timer = Timer(label: "ACMP #\(sequenceID)") { [weak self] in
      await self?._acmpCommandTimedOut(sequenceID: sequenceID)
    }
    _acmpTransactions[sequenceID] = AcmpTransaction(acmpdu: acmpdu, promise: promise, timer: timer)
    _transmitAcmpCommand(sequenceID: sequenceID)

    let response: Acmpdu
    do {
      response = try await withTaskCancellationHandler {
        try await promise.value
      } onCancel: { [weak self] in
        promise.resolve(.failure(CancellationError()))
        // stop retrying it
        Task { await self?._completeAcmpCommand(sequenceID: sequenceID, with: .failure(CancellationError())) }
      }
    } catch let error as CommandError {
      throw AcmpStatus(error)
    }

    guard response.status == AcmpStatus.success.rawValue else {
      throw AcmpStatus(UInt16(response.status))
    }
    return StreamConnectionState(
      talkerStream: response.talkerStream,
      listenerStream: response.listenerStream,
      connectionCount: response.connectionCount,
      flags: response.flags
    )
  }

  private func _completeAcmpCommand(sequenceID: UInt16, with result: Result<Acmpdu, any Error>) {
    guard let transaction = _acmpTransactions.removeValue(forKey: sequenceID) else { return }
    transaction.timer.stop()
    transaction.promise.resolve(result)
  }

  /// Queues an ACMP command for the transmit task, which starts its timeout once it has been
  /// sent (txCommand, IEEE 1722.1-2021 §8.2.3).
  private func _transmitAcmpCommand(sequenceID: UInt16) {
    guard let transaction = _acmpTransactions[sequenceID] else { return }
    _transmissions.yield(.acmpCommand(transaction, sequenceID: sequenceID))
  }

  private func _acmpCommandSent(sequenceID: UInt16, timer: Timer) {
    // it may have been answered or cancelled during the send
    guard let transaction = _acmpTransactions[sequenceID], transaction.timer === timer,
          !transaction.promise.isResolved
    else { return }
    timer.start(interval: _acmpCommandTimeout(transaction.acmpdu.messageType))
  }

  private func _acmpCommandSendFailed(sequenceID: UInt16, timer: Timer, error: any Error) {
    guard _acmpTransactions[sequenceID]?.timer === timer else { return }
    _completeAcmpCommand(sequenceID: sequenceID, with: .failure(CommandError.networkError(error)))
  }

  private func _acmpCommandTimedOut(sequenceID: UInt16) {
    // a timer restarted since it fired supersedes this expiry
    guard var transaction = _acmpTransactions[sequenceID], !transaction.timer.isRunning else {
      return
    }
    guard !transaction.retried, !transaction.promise.isResolved else {
      _completeAcmpCommand(sequenceID: sequenceID, with: .failure(CommandError.timedOut))
      return
    }
    transaction.retried = true
    _acmpTransactions[sequenceID] = transaction
    _transmitAcmpCommand(sequenceID: sequenceID)
  }

  func _handle(_ acmpdu: Acmpdu) {
    guard acmpdu.messageType.isResponse else { return }

    if acmpdu.controllerEntityID == entityID,
       _acmpTransactions[acmpdu.sequenceID]?.acmpdu.messageType.response == acmpdu.messageType
    {
      _completeAcmpCommand(sequenceID: acmpdu.sequenceID, with: .success(acmpdu))
    }

    guard acmpdu.controllerEntityID != entityID ||
      !_controllerAcmpResponses.contains(acmpdu.messageType)
    else { return }

    let state = StreamConnectionState(
      talkerStream: acmpdu.talkerStream,
      listenerStream: acmpdu.listenerStream,
      connectionCount: acmpdu.connectionCount,
      flags: acmpdu.flags
    )
    let status = AcmpStatus(UInt16(acmpdu.status))

    switch acmpdu.messageType {
    case .connectTxResponse: _yield(.listenerConnectResponse(state, status))
    case .disconnectTxResponse: _yield(.listenerDisconnectResponse(state, status))
    case .getTxStateResponse: _yield(.talkerStreamStateResponse(state, status))
    case .connectRxResponse: _yield(.controllerConnectResponse(state, status))
    case .disconnectRxResponse: _yield(.controllerDisconnectResponse(state, status))
    case .getRxStateResponse: _yield(.listenerStreamStateResponse(state, status))
    default: break
    }
  }
}

// MARK: - AEM commands

public extension Controller {
  /// ACQUIRE_ENTITY (IEEE 1722.1-2021 §7.4.1). Returns the ID of the controller that now owns
  /// the entity.
  @discardableResult
  func acquireEntity(
    id targetEntityID: UniqueIdentifier,
    persistent: Bool = false,
    descriptorType: DescriptorType = .entity,
    descriptorIndex: DescriptorIndex = 0
  ) async throws -> UniqueIdentifier {
    guard case let .acquireEntity(_, ownerID, _, _) = try await _aem(targetEntityID, .acquireEntity(
      flags: persistent ? .persistent : [],
      ownerID: UniqueIdentifier(),
      descriptorType: descriptorType,
      descriptorIndex: descriptorIndex
    )) else { throw AemStatus.protocolError }
    return ownerID
  }

  @discardableResult
  func releaseEntity(
    id targetEntityID: UniqueIdentifier,
    descriptorType: DescriptorType = .entity,
    descriptorIndex: DescriptorIndex = 0
  ) async throws -> UniqueIdentifier {
    guard case let .acquireEntity(_, ownerID, _, _) = try await _aem(targetEntityID, .acquireEntity(
      flags: .release,
      ownerID: UniqueIdentifier(),
      descriptorType: descriptorType,
      descriptorIndex: descriptorIndex
    )) else { throw AemStatus.protocolError }
    return ownerID
  }

  /// LOCK_ENTITY (IEEE 1722.1-2021 §7.4.2). Returns the ID of the controller holding the lock.
  @discardableResult
  func lockEntity(
    id targetEntityID: UniqueIdentifier,
    descriptorType: DescriptorType = .entity,
    descriptorIndex: DescriptorIndex = 0
  ) async throws -> UniqueIdentifier {
    guard case let .lockEntity(_, lockedID, _, _) = try await _aem(targetEntityID, .lockEntity(
      flags: [],
      lockedID: UniqueIdentifier(),
      descriptorType: descriptorType,
      descriptorIndex: descriptorIndex
    )) else { throw AemStatus.protocolError }
    return lockedID
  }

  @discardableResult
  func unlockEntity(
    id targetEntityID: UniqueIdentifier,
    descriptorType: DescriptorType = .entity,
    descriptorIndex: DescriptorIndex = 0
  ) async throws -> UniqueIdentifier {
    guard case let .lockEntity(_, lockedID, _, _) = try await _aem(targetEntityID, .lockEntity(
      flags: .unlock,
      lockedID: UniqueIdentifier(),
      descriptorType: descriptorType,
      descriptorIndex: descriptorIndex
    )) else { throw AemStatus.protocolError }
    return lockedID
  }

  /// ENTITY_AVAILABLE (IEEE 1722.1-2021 §7.4.3).
  func queryEntityAvailable(id targetEntityID: UniqueIdentifier) async throws {
    _ = try await _aem(targetEntityID, .entityAvailable)
  }

  /// CONTROLLER_AVAILABLE (IEEE 1722.1-2021 §7.4.4).
  func queryControllerAvailable(id targetEntityID: UniqueIdentifier) async throws {
    _ = try await _aem(targetEntityID, .controllerAvailable)
  }

  /// REGISTER_UNSOLICITED_NOTIFICATION (IEEE 1722.1-2021 §7.4.37). The registration is time
  /// limited and renewed every 100 seconds until it is deregistered, the entity goes offline or
  /// the controller closes, which deregisters from every entity.
  func registerUnsolicitedNotifications(id targetEntityID: UniqueIdentifier) async throws {
    try await _registerUnsolicitedNotifications(targetEntityID)
  }

  /// DEREGISTER_UNSOLICITED_NOTIFICATION (IEEE 1722.1-2021 §7.4.38).
  func unregisterUnsolicitedNotifications(id targetEntityID: UniqueIdentifier) async throws {
    try await _deregisterUnsolicitedNotifications(targetEntityID)
  }

  // MARK: Configuration

  func getConfiguration(id targetEntityID: UniqueIdentifier) async throws -> UInt16 {
    guard case let .getConfiguration(configurationIndex) =
      try await _aem(targetEntityID, .getConfiguration)
    else { throw AemStatus.protocolError }
    return configurationIndex
  }

  @discardableResult
  func setConfiguration(
    id targetEntityID: UniqueIdentifier,
    to configurationIndex: UInt16
  ) async throws -> UInt16 {
    guard case let .setConfiguration(configurationIndex) =
      try await _aem(targetEntityID, .setConfiguration(configurationIndex: configurationIndex))
    else { throw AemStatus.protocolError }
    return configurationIndex
  }

  // MARK: Names

  private func _setName(
    _ targetEntityID: UniqueIdentifier,
    _ descriptorType: DescriptorType,
    _ descriptorIndex: DescriptorIndex,
    nameIndex: UInt16 = _objectNameIndex,
    configurationIndex: UInt16,
    _ name: String
  ) async throws {
    _ = try await _aem(targetEntityID, .setName(
      descriptorType: descriptorType,
      descriptorIndex: descriptorIndex,
      nameIndex: nameIndex,
      configurationIndex: configurationIndex,
      name: name
    ))
  }

  private func _getName(
    _ targetEntityID: UniqueIdentifier,
    _ descriptorType: DescriptorType,
    _ descriptorIndex: DescriptorIndex,
    nameIndex: UInt16 = _objectNameIndex,
    configurationIndex: UInt16
  ) async throws -> String {
    guard case let .getName(_, _, _, _, name) = try await _aem(targetEntityID, .getName(
      descriptorType: descriptorType,
      descriptorIndex: descriptorIndex,
      nameIndex: nameIndex,
      configurationIndex: configurationIndex
    )) else { throw AemStatus.protocolError }
    return name
  }

  func setEntityName(id targetEntityID: UniqueIdentifier, to name: String) async throws {
    try await _setName(targetEntityID, .entity, 0, nameIndex: _entityNameIndex, configurationIndex: 0, name)
  }

  func getEntityName(id targetEntityID: UniqueIdentifier) async throws -> String {
    try await _getName(targetEntityID, .entity, 0, nameIndex: _entityNameIndex, configurationIndex: 0)
  }

  func setEntityGroupName(id targetEntityID: UniqueIdentifier, to name: String) async throws {
    try await _setName(targetEntityID, .entity, 0, nameIndex: _entityGroupNameIndex, configurationIndex: 0, name)
  }

  func getEntityGroupName(id targetEntityID: UniqueIdentifier) async throws -> String {
    try await _getName(targetEntityID, .entity, 0, nameIndex: _entityGroupNameIndex, configurationIndex: 0)
  }

  func setConfigurationName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .configuration, configurationIndex, configurationIndex: 0, name)
  }

  func getConfigurationName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .configuration, configurationIndex, configurationIndex: 0)
  }

  func setAudioUnitName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, audioUnitIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .audioUnit, audioUnitIndex, configurationIndex: configurationIndex, name)
  }

  func getAudioUnitName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, audioUnitIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .audioUnit, audioUnitIndex, configurationIndex: configurationIndex)
  }

  func setStreamInputName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, streamIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .streamInput, streamIndex, configurationIndex: configurationIndex, name)
  }

  func getStreamInputName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, streamIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .streamInput, streamIndex, configurationIndex: configurationIndex)
  }

  func setStreamOutputName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, streamIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .streamOutput, streamIndex, configurationIndex: configurationIndex, name)
  }

  func getStreamOutputName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, streamIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .streamOutput, streamIndex, configurationIndex: configurationIndex)
  }

  func setJackInputName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, jackIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .jackInput, jackIndex, configurationIndex: configurationIndex, name)
  }

  func getJackInputName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, jackIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .jackInput, jackIndex, configurationIndex: configurationIndex)
  }

  func setJackOutputName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, jackIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .jackOutput, jackIndex, configurationIndex: configurationIndex, name)
  }

  func getJackOutputName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, jackIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .jackOutput, jackIndex, configurationIndex: configurationIndex)
  }

  func setAvbInterfaceName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, avbInterfaceIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .avbInterface, avbInterfaceIndex, configurationIndex: configurationIndex, name)
  }

  func getAvbInterfaceName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, avbInterfaceIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .avbInterface, avbInterfaceIndex, configurationIndex: configurationIndex)
  }

  func setClockSourceName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, clockSourceIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .clockSource, clockSourceIndex, configurationIndex: configurationIndex, name)
  }

  func getClockSourceName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, clockSourceIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .clockSource, clockSourceIndex, configurationIndex: configurationIndex)
  }

  func setMemoryObjectName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, memoryObjectIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .memoryObject, memoryObjectIndex, configurationIndex: configurationIndex, name)
  }

  func getMemoryObjectName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, memoryObjectIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .memoryObject, memoryObjectIndex, configurationIndex: configurationIndex)
  }

  func setAudioClusterName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, clusterIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .audioCluster, clusterIndex, configurationIndex: configurationIndex, name)
  }

  func getAudioClusterName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, clusterIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .audioCluster, clusterIndex, configurationIndex: configurationIndex)
  }

  func setControlName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, controlIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .control, controlIndex, configurationIndex: configurationIndex, name)
  }

  func getControlName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, controlIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .control, controlIndex, configurationIndex: configurationIndex)
  }

  func setClockDomainName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, clockDomainIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .clockDomain, clockDomainIndex, configurationIndex: configurationIndex, name)
  }

  func getClockDomainName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, clockDomainIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .clockDomain, clockDomainIndex, configurationIndex: configurationIndex)
  }

  func setTimingName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, timingIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .timing, timingIndex, configurationIndex: configurationIndex, name)
  }

  func getTimingName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, timingIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .timing, timingIndex, configurationIndex: configurationIndex)
  }

  func setPtpInstanceName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, ptpInstanceIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .ptpInstance, ptpInstanceIndex, configurationIndex: configurationIndex, name)
  }

  func getPtpInstanceName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, ptpInstanceIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .ptpInstance, ptpInstanceIndex, configurationIndex: configurationIndex)
  }

  func setPtpPortName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, ptpPortIndex: UInt16, to name: String
  ) async throws {
    try await _setName(targetEntityID, .ptpPort, ptpPortIndex, configurationIndex: configurationIndex, name)
  }

  func getPtpPortName(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, ptpPortIndex: UInt16
  ) async throws -> String {
    try await _getName(targetEntityID, .ptpPort, ptpPortIndex, configurationIndex: configurationIndex)
  }

  // MARK: Streams

  func startStreamInput(id targetEntityID: UniqueIdentifier, streamIndex: UInt16) async throws {
    _ = try await _aem(targetEntityID, .startStreaming(descriptorType: .streamInput, descriptorIndex: streamIndex))
  }

  func startStreamOutput(id targetEntityID: UniqueIdentifier, streamIndex: UInt16) async throws {
    _ = try await _aem(targetEntityID, .startStreaming(descriptorType: .streamOutput, descriptorIndex: streamIndex))
  }

  func stopStreamInput(id targetEntityID: UniqueIdentifier, streamIndex: UInt16) async throws {
    _ = try await _aem(targetEntityID, .stopStreaming(descriptorType: .streamInput, descriptorIndex: streamIndex))
  }

  func stopStreamOutput(id targetEntityID: UniqueIdentifier, streamIndex: UInt16) async throws {
    _ = try await _aem(targetEntityID, .stopStreaming(descriptorType: .streamOutput, descriptorIndex: streamIndex))
  }

  private func _getStreamFormat(_ id: UniqueIdentifier, _ type: DescriptorType, _ index: UInt16) async throws -> StreamFormat {
    guard case let .getStreamFormat(_, _, streamFormat) =
      try await _aem(id, .getStreamFormat(descriptorType: type, descriptorIndex: index))
    else { throw AemStatus.protocolError }
    return streamFormat
  }

  private func _setStreamFormat(
    _ id: UniqueIdentifier, _ type: DescriptorType, _ index: UInt16, _ format: StreamFormat
  ) async throws -> StreamFormat {
    guard case let .setStreamFormat(_, _, streamFormat) =
      try await _aem(id, .setStreamFormat(descriptorType: type, descriptorIndex: index, streamFormat: format))
    else { throw AemStatus.protocolError }
    return streamFormat
  }

  func getStreamInputFormat(id targetEntityID: UniqueIdentifier, streamIndex: UInt16) async throws -> StreamFormat {
    try await _getStreamFormat(targetEntityID, .streamInput, streamIndex)
  }

  @discardableResult
  func setStreamInputFormat(
    id targetEntityID: UniqueIdentifier, streamIndex: UInt16, to streamFormat: StreamFormat
  ) async throws -> StreamFormat {
    try await _setStreamFormat(targetEntityID, .streamInput, streamIndex, streamFormat)
  }

  func getStreamOutputFormat(id targetEntityID: UniqueIdentifier, streamIndex: UInt16) async throws -> StreamFormat {
    try await _getStreamFormat(targetEntityID, .streamOutput, streamIndex)
  }

  @discardableResult
  func setStreamOutputFormat(
    id targetEntityID: UniqueIdentifier, streamIndex: UInt16, to streamFormat: StreamFormat
  ) async throws -> StreamFormat {
    try await _setStreamFormat(targetEntityID, .streamOutput, streamIndex, streamFormat)
  }

  private func _getStreamInfo(_ id: UniqueIdentifier, _ type: DescriptorType, _ index: UInt16) async throws -> StreamInfo {
    guard case let .getStreamInfo(_, _, streamInfo) =
      try await _aem(id, .getStreamInfo(descriptorType: type, descriptorIndex: index))
    else { throw AemStatus.protocolError }
    return streamInfo
  }

  private func _setStreamInfo(
    _ id: UniqueIdentifier, _ type: DescriptorType, _ index: UInt16, _ info: StreamInfo
  ) async throws -> StreamInfo {
    guard case let .setStreamInfo(_, _, streamInfo) =
      try await _aem(id, .setStreamInfo(descriptorType: type, descriptorIndex: index, streamInfo: info))
    else { throw AemStatus.protocolError }
    return streamInfo
  }

  func getStreamInputInfo(id targetEntityID: UniqueIdentifier, streamIndex: UInt16) async throws -> StreamInfo {
    try await _getStreamInfo(targetEntityID, .streamInput, streamIndex)
  }

  func getStreamOutputInfo(id targetEntityID: UniqueIdentifier, streamIndex: UInt16) async throws -> StreamInfo {
    try await _getStreamInfo(targetEntityID, .streamOutput, streamIndex)
  }

  @discardableResult
  func setStreamInputInfo(
    id targetEntityID: UniqueIdentifier, streamIndex: UInt16, to info: StreamInfo
  ) async throws -> StreamInfo {
    try await _setStreamInfo(targetEntityID, .streamInput, streamIndex, info)
  }

  @discardableResult
  func setStreamOutputInfo(
    id targetEntityID: UniqueIdentifier, streamIndex: UInt16, to info: StreamInfo
  ) async throws -> StreamInfo {
    try await _setStreamInfo(targetEntityID, .streamOutput, streamIndex, info)
  }

  /// SET_MAX_TRANSIT_TIME (IEEE 1722.1-2021 §7.4.77); `maxTransitTime` is in nanoseconds.
  @discardableResult
  func setMaxTransitTime(
    id targetEntityID: UniqueIdentifier, streamIndex: UInt16, to maxTransitTime: UInt64
  ) async throws -> UInt64 {
    guard case let .setMaxTransitTime(_, _, maxTransitTime) = try await _aem(targetEntityID, .setMaxTransitTime(
      descriptorType: .streamOutput, descriptorIndex: streamIndex, maxTransitTime: maxTransitTime
    )) else { throw AemStatus.protocolError }
    return maxTransitTime
  }

  func getMaxTransitTime(id targetEntityID: UniqueIdentifier, streamIndex: UInt16) async throws -> UInt64 {
    guard case let .getMaxTransitTime(_, _, maxTransitTime) = try await _aem(targetEntityID, .getMaxTransitTime(
      descriptorType: .streamOutput, descriptorIndex: streamIndex
    )) else { throw AemStatus.protocolError }
    return maxTransitTime
  }

  // MARK: Clocks

  func getClockSource(id targetEntityID: UniqueIdentifier, clockDomainIndex: UInt16) async throws -> UInt16 {
    guard case let .getClockSource(_, _, clockSourceIndex) = try await _aem(targetEntityID, .getClockSource(
      descriptorType: .clockDomain, descriptorIndex: clockDomainIndex
    )) else { throw AemStatus.protocolError }
    return clockSourceIndex
  }

  @discardableResult
  func setClockSource(
    id targetEntityID: UniqueIdentifier, clockDomainIndex: UInt16, to clockSourceIndex: UInt16
  ) async throws -> UInt16 {
    guard case let .setClockSource(_, _, clockSourceIndex) = try await _aem(targetEntityID, .setClockSource(
      descriptorType: .clockDomain, descriptorIndex: clockDomainIndex, clockSourceIndex: clockSourceIndex
    )) else { throw AemStatus.protocolError }
    return clockSourceIndex
  }

  private func _getSamplingRate(_ id: UniqueIdentifier, _ type: DescriptorType, _ index: UInt16) async throws -> SamplingRate {
    guard case let .getSamplingRate(_, _, samplingRate) =
      try await _aem(id, .getSamplingRate(descriptorType: type, descriptorIndex: index))
    else { throw AemStatus.protocolError }
    return samplingRate
  }

  private func _setSamplingRate(
    _ id: UniqueIdentifier, _ type: DescriptorType, _ index: UInt16, _ rate: SamplingRate
  ) async throws -> SamplingRate {
    guard case let .setSamplingRate(_, _, samplingRate) =
      try await _aem(id, .setSamplingRate(descriptorType: type, descriptorIndex: index, samplingRate: rate))
    else { throw AemStatus.protocolError }
    return samplingRate
  }

  @discardableResult
  func setAudioUnitSamplingRate(
    id targetEntityID: UniqueIdentifier, audioUnitIndex: UInt16, to samplingRate: SamplingRate
  ) async throws -> SamplingRate {
    try await _setSamplingRate(targetEntityID, .audioUnit, audioUnitIndex, samplingRate)
  }

  func getAudioUnitSamplingRate(id targetEntityID: UniqueIdentifier, audioUnitIndex: UInt16) async throws -> SamplingRate {
    try await _getSamplingRate(targetEntityID, .audioUnit, audioUnitIndex)
  }

  @discardableResult
  func setVideoClusterSamplingRate(
    id targetEntityID: UniqueIdentifier, videoClusterIndex: UInt16, to samplingRate: SamplingRate
  ) async throws -> SamplingRate {
    try await _setSamplingRate(targetEntityID, .videoCluster, videoClusterIndex, samplingRate)
  }

  func getVideoClusterSamplingRate(id targetEntityID: UniqueIdentifier, videoClusterIndex: UInt16) async throws -> SamplingRate {
    try await _getSamplingRate(targetEntityID, .videoCluster, videoClusterIndex)
  }

  @discardableResult
  func setSensorClusterSamplingRate(
    id targetEntityID: UniqueIdentifier, sensorClusterIndex: UInt16, to samplingRate: SamplingRate
  ) async throws -> SamplingRate {
    try await _setSamplingRate(targetEntityID, .sensorCluster, sensorClusterIndex, samplingRate)
  }

  func getSensorClusterSamplingRate(id targetEntityID: UniqueIdentifier, sensorClusterIndex: UInt16) async throws -> SamplingRate {
    try await _getSamplingRate(targetEntityID, .sensorCluster, sensorClusterIndex)
  }

  // MARK: Descriptors

  private func _readDescriptor<Value: Sendable>(
    _ targetEntityID: UniqueIdentifier,
    configurationIndex: UInt16,
    _ descriptorType: DescriptorType,
    _ descriptorIndex: DescriptorIndex,
    _ extract: (Descriptor) -> Value?
  ) async throws -> Value {
    guard case let .readDescriptor(_, _, descriptor) = try await _aem(targetEntityID, .readDescriptor(
      configurationIndex: configurationIndex,
      descriptorType: descriptorType,
      descriptorIndex: descriptorIndex
    )), let value = extract(descriptor) else { throw AemStatus.protocolError }
    return value
  }

  /// READ_DESCRIPTOR for any descriptor type (IEEE 1722.1-2021 §7.4.5).
  func readDescriptor(
    id targetEntityID: UniqueIdentifier,
    configurationIndex: UInt16,
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex
  ) async throws -> Descriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, descriptorType, descriptorIndex) { $0 }
  }

  func readEntityDescriptor(id targetEntityID: UniqueIdentifier) async throws -> EntityDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: 0, .entity, 0) {
      if case let .entity(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readConfigurationDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16
  ) async throws -> ConfigurationDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: 0, .configuration, configurationIndex) {
      if case let .configuration(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readAudioUnitDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, audioUnitIndex: UInt16
  ) async throws -> AudioUnitDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .audioUnit, audioUnitIndex) {
      if case let .audioUnit(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readStreamInputDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, streamIndex: UInt16
  ) async throws -> StreamDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .streamInput, streamIndex) {
      if case let .streamInput(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readStreamOutputDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, streamIndex: UInt16
  ) async throws -> StreamDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .streamOutput, streamIndex) {
      if case let .streamOutput(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readJackInputDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, jackIndex: UInt16
  ) async throws -> JackDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .jackInput, jackIndex) {
      if case let .jackInput(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readJackOutputDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, jackIndex: UInt16
  ) async throws -> JackDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .jackOutput, jackIndex) {
      if case let .jackOutput(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readAvbInterfaceDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, avbInterfaceIndex: UInt16
  ) async throws -> AvbInterfaceDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .avbInterface, avbInterfaceIndex) {
      if case let .avbInterface(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readClockSourceDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, clockSourceIndex: UInt16
  ) async throws -> ClockSourceDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .clockSource, clockSourceIndex) {
      if case let .clockSource(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readMemoryObjectDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, memoryObjectIndex: UInt16
  ) async throws -> MemoryObjectDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .memoryObject, memoryObjectIndex) {
      if case let .memoryObject(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readLocaleDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, localeIndex: UInt16
  ) async throws -> LocaleDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .locale, localeIndex) {
      if case let .locale(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readStringsDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, stringsIndex: UInt16
  ) async throws -> StringsDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .strings, stringsIndex) {
      if case let .strings(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readStreamPortInputDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, streamPortIndex: UInt16
  ) async throws -> StreamPortDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .streamPortInput, streamPortIndex) {
      if case let .streamPortInput(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readStreamPortOutputDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, streamPortIndex: UInt16
  ) async throws -> StreamPortDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .streamPortOutput, streamPortIndex) {
      if case let .streamPortOutput(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readExternalPortInputDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, externalPortIndex: UInt16
  ) async throws -> ExternalPortDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .externalPortInput, externalPortIndex) {
      if case let .externalPortInput(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readExternalPortOutputDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, externalPortIndex: UInt16
  ) async throws -> ExternalPortDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .externalPortOutput, externalPortIndex) {
      if case let .externalPortOutput(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readInternalPortInputDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, internalPortIndex: UInt16
  ) async throws -> InternalPortDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .internalPortInput, internalPortIndex) {
      if case let .internalPortInput(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readInternalPortOutputDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, internalPortIndex: UInt16
  ) async throws -> InternalPortDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .internalPortOutput, internalPortIndex) {
      if case let .internalPortOutput(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readAudioClusterDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, clusterIndex: UInt16
  ) async throws -> AudioClusterDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .audioCluster, clusterIndex) {
      if case let .audioCluster(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readAudioMapDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, mapIndex: UInt16
  ) async throws -> AudioMapDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .audioMap, mapIndex) {
      if case let .audioMap(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readControlDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, controlIndex: UInt16
  ) async throws -> ControlDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .control, controlIndex) {
      if case let .control(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readClockDomainDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, clockDomainIndex: UInt16
  ) async throws -> ClockDomainDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .clockDomain, clockDomainIndex) {
      if case let .clockDomain(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readTimingDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, timingIndex: UInt16
  ) async throws -> TimingDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .timing, timingIndex) {
      if case let .timing(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readPtpInstanceDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, ptpInstanceIndex: UInt16
  ) async throws -> PtpInstanceDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .ptpInstance, ptpInstanceIndex) {
      if case let .ptpInstance(descriptor) = $0 { descriptor } else { nil }
    }
  }

  func readPtpPortDescriptor(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, ptpPortIndex: UInt16
  ) async throws -> PtpPortDescriptor {
    try await _readDescriptor(targetEntityID, configurationIndex: configurationIndex, .ptpPort, ptpPortIndex) {
      if case let .ptpPort(descriptor) = $0 { descriptor } else { nil }
    }
  }

  // MARK: Dynamic information

  func getAvbInfo(id targetEntityID: UniqueIdentifier, avbInterfaceIndex: UInt16) async throws -> AvbInfo {
    guard case let .getAvbInfo(_, _, avbInfo) = try await _aem(targetEntityID, .getAvbInfo(
      descriptorType: .avbInterface, descriptorIndex: avbInterfaceIndex
    )) else { throw AemStatus.protocolError }
    return avbInfo
  }

  func getAsPath(id targetEntityID: UniqueIdentifier, avbInterfaceIndex: UInt16) async throws -> AsPath {
    guard case let .getAsPath(_, asPath) =
      try await _aem(targetEntityID, .getAsPath(descriptorIndex: avbInterfaceIndex))
    else { throw AemStatus.protocolError }
    return asPath
  }

  private func _getCounters(
    _ id: UniqueIdentifier, _ type: DescriptorType, _ index: UInt16
  ) async throws -> (UInt32, DescriptorCounters) {
    guard case let .getCounters(_, _, countersValid, counters) =
      try await _aem(id, .getCounters(descriptorType: type, descriptorIndex: index))
    else { throw AemStatus.protocolError }
    return (countersValid, counters)
  }

  func getEntityCounters(
    id targetEntityID: UniqueIdentifier
  ) async throws -> (valid: EntityCounterValidFlags, counters: DescriptorCounters) {
    let (valid, counters) = try await _getCounters(targetEntityID, .entity, 0)
    return (EntityCounterValidFlags(rawValue: valid), counters)
  }

  func getAvbInterfaceCounters(
    id targetEntityID: UniqueIdentifier, avbInterfaceIndex: UInt16
  ) async throws -> (valid: AvbInterfaceCounterValidFlags, counters: DescriptorCounters) {
    let (valid, counters) = try await _getCounters(targetEntityID, .avbInterface, avbInterfaceIndex)
    return (AvbInterfaceCounterValidFlags(rawValue: valid), counters)
  }

  func getClockDomainCounters(
    id targetEntityID: UniqueIdentifier, clockDomainIndex: UInt16
  ) async throws -> (valid: ClockDomainCounterValidFlags, counters: DescriptorCounters) {
    let (valid, counters) = try await _getCounters(targetEntityID, .clockDomain, clockDomainIndex)
    return (ClockDomainCounterValidFlags(rawValue: valid), counters)
  }

  func getStreamInputCounters(
    id targetEntityID: UniqueIdentifier, streamIndex: UInt16
  ) async throws -> (valid: StreamInputCounterValidFlags, counters: DescriptorCounters) {
    let (valid, counters) = try await _getCounters(targetEntityID, .streamInput, streamIndex)
    return (StreamInputCounterValidFlags(rawValue: valid), counters)
  }

  func getStreamOutputCounters(
    id targetEntityID: UniqueIdentifier, streamIndex: UInt16
  ) async throws -> (valid: StreamOutputCounterValidFlags, counters: DescriptorCounters) {
    let (valid, counters) = try await _getCounters(targetEntityID, .streamOutput, streamIndex)
    return (StreamOutputCounterValidFlags(rawValue: valid), counters)
  }

  // MARK: Controls

  /// GET_CONTROL (IEEE 1722.1-2021 §7.4.26); the values are packed as described by the
  /// control's CONTROL descriptor.
  func getControlValues(id targetEntityID: UniqueIdentifier, controlIndex: UInt16) async throws -> [UInt8] {
    guard case let .getControl(_, _, packedControlValues) = try await _aem(targetEntityID, .getControl(
      descriptorType: .control, descriptorIndex: controlIndex
    )) else { throw AemStatus.protocolError }
    return packedControlValues
  }

  @discardableResult
  func setControlValues(
    id targetEntityID: UniqueIdentifier, controlIndex: UInt16, to packedControlValues: [UInt8]
  ) async throws -> [UInt8] {
    guard case let .setControl(_, _, packedControlValues) = try await _aem(targetEntityID, .setControl(
      descriptorType: .control, descriptorIndex: controlIndex, packedControlValues: packedControlValues
    )) else { throw AemStatus.protocolError }
    return packedControlValues
  }

  // MARK: Audio maps

  private func _getAudioMap(
    _ id: UniqueIdentifier, _ type: DescriptorType, _ streamPortIndex: UInt16, _ mapIndex: UInt16
  ) async throws -> (numberOfMaps: UInt16, mapIndex: UInt16, mappings: [AudioMapping]) {
    guard case let .getAudioMap(_, _, mapIndex, numberOfMaps, mappings) = try await _aem(id, .getAudioMap(
      descriptorType: type, descriptorIndex: streamPortIndex, mapIndex: mapIndex
    )) else { throw AemStatus.protocolError }
    return (numberOfMaps, mapIndex, mappings)
  }

  func getStreamPortInputAudioMap(
    id targetEntityID: UniqueIdentifier, streamPortIndex: UInt16, mapIndex: UInt16
  ) async throws -> (numberOfMaps: UInt16, mapIndex: UInt16, mappings: [AudioMapping]) {
    try await _getAudioMap(targetEntityID, .streamPortInput, streamPortIndex, mapIndex)
  }

  func getStreamPortOutputAudioMap(
    id targetEntityID: UniqueIdentifier, streamPortIndex: UInt16, mapIndex: UInt16
  ) async throws -> (numberOfMaps: UInt16, mapIndex: UInt16, mappings: [AudioMapping]) {
    try await _getAudioMap(targetEntityID, .streamPortOutput, streamPortIndex, mapIndex)
  }

  private func _addAudioMappings(
    _ id: UniqueIdentifier, _ type: DescriptorType, _ streamPortIndex: UInt16, _ mappings: [AudioMapping]
  ) async throws -> [AudioMapping] {
    guard case let .addAudioMappings(_, _, mappings) = try await _aem(id, .addAudioMappings(
      descriptorType: type, descriptorIndex: streamPortIndex, mappings: mappings
    )) else { throw AemStatus.protocolError }
    return mappings
  }

  private func _removeAudioMappings(
    _ id: UniqueIdentifier, _ type: DescriptorType, _ streamPortIndex: UInt16, _ mappings: [AudioMapping]
  ) async throws -> [AudioMapping] {
    guard case let .removeAudioMappings(_, _, mappings) = try await _aem(id, .removeAudioMappings(
      descriptorType: type, descriptorIndex: streamPortIndex, mappings: mappings
    )) else { throw AemStatus.protocolError }
    return mappings
  }

  @discardableResult
  func addStreamPortInputAudioMappings(
    id targetEntityID: UniqueIdentifier, streamPortIndex: UInt16, mappings: [AudioMapping]
  ) async throws -> [AudioMapping] {
    try await _addAudioMappings(targetEntityID, .streamPortInput, streamPortIndex, mappings)
  }

  @discardableResult
  func addStreamPortOutputAudioMappings(
    id targetEntityID: UniqueIdentifier, streamPortIndex: UInt16, mappings: [AudioMapping]
  ) async throws -> [AudioMapping] {
    try await _addAudioMappings(targetEntityID, .streamPortOutput, streamPortIndex, mappings)
  }

  @discardableResult
  func removeStreamPortInputAudioMappings(
    id targetEntityID: UniqueIdentifier, streamPortIndex: UInt16, mappings: [AudioMapping]
  ) async throws -> [AudioMapping] {
    try await _removeAudioMappings(targetEntityID, .streamPortInput, streamPortIndex, mappings)
  }

  @discardableResult
  func removeStreamPortOutputAudioMappings(
    id targetEntityID: UniqueIdentifier, streamPortIndex: UInt16, mappings: [AudioMapping]
  ) async throws -> [AudioMapping] {
    try await _removeAudioMappings(targetEntityID, .streamPortOutput, streamPortIndex, mappings)
  }

  // MARK: Memory objects and operations

  @discardableResult
  func setMemoryObjectLength(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, memoryObjectIndex: UInt16, to length: UInt64
  ) async throws -> UInt64 {
    guard case let .setMemoryObjectLength(_, _, length) = try await _aem(targetEntityID, .setMemoryObjectLength(
      configurationIndex: configurationIndex, memoryObjectIndex: memoryObjectIndex, length: length
    )) else { throw AemStatus.protocolError }
    return length
  }

  func getMemoryObjectLength(
    id targetEntityID: UniqueIdentifier, configurationIndex: UInt16, memoryObjectIndex: UInt16
  ) async throws -> UInt64 {
    guard case let .getMemoryObjectLength(_, _, length) = try await _aem(targetEntityID, .getMemoryObjectLength(
      configurationIndex: configurationIndex, memoryObjectIndex: memoryObjectIndex
    )) else { throw AemStatus.protocolError }
    return length
  }

  /// START_OPERATION (IEEE 1722.1-2021 §7.4.53). The returned `operationID` identifies the
  /// operation in OPERATION_STATUS notifications and ABORT_OPERATION.
  func startOperation(
    id targetEntityID: UniqueIdentifier,
    descriptorType: DescriptorType, descriptorIndex: UInt16,
    operationType: MemoryObjectOperationType, payload: [UInt8] = []
  ) async throws -> OperationResult {
    guard case let .startOperation(descriptorType, descriptorIndex, operationID, operationType, values) =
      try await _aem(targetEntityID, .startOperation(
        descriptorType: descriptorType,
        descriptorIndex: descriptorIndex,
        operationID: 0,
        operationType: operationType.rawValue,
        values: payload
      ))
    else { throw AemStatus.protocolError }
    return OperationResult(
      descriptorType: descriptorType.rawValue,
      descriptorIndex: descriptorIndex,
      operationID: operationID,
      operationType: MemoryObjectOperationType(rawValue: operationType) ?? .read,
      payload: values
    )
  }

  func abortOperation(
    id targetEntityID: UniqueIdentifier,
    descriptorType: DescriptorType, descriptorIndex: UInt16, operationID: UInt16
  ) async throws {
    _ = try await _aem(targetEntityID, .abortOperation(
      descriptorType: descriptorType, descriptorIndex: descriptorIndex, operationID: operationID
    ))
  }

  // MARK: Association and reboot

  @discardableResult
  func setAssociation(
    id targetEntityID: UniqueIdentifier, to associationID: UniqueIdentifier
  ) async throws -> UniqueIdentifier {
    guard case let .setAssociationID(associationID) =
      try await _aem(targetEntityID, .setAssociationID(associationID))
    else { throw AemStatus.protocolError }
    return associationID
  }

  func getAssociation(id targetEntityID: UniqueIdentifier) async throws -> UniqueIdentifier {
    guard case let .getAssociationID(associationID) = try await _aem(targetEntityID, .getAssociationID)
    else { throw AemStatus.protocolError }
    return associationID
  }

  /// REBOOT (IEEE 1722.1-2021 §7.4.43). The response confirms the request, not the reboot.
  func reboot(id targetEntityID: UniqueIdentifier) async throws {
    _ = try await _aem(targetEntityID, .reboot(descriptorType: .entity, descriptorIndex: 0))
  }

  /// REBOOT into the firmware image held by a MEMORY_OBJECT.
  func rebootToFirmware(id targetEntityID: UniqueIdentifier, memoryObjectIndex: UInt16) async throws {
    _ = try await _aem(targetEntityID, .reboot(descriptorType: .memoryObject, descriptorIndex: memoryObjectIndex))
  }
}

// MARK: - Milan MVU commands

public extension Controller {
  /// GET_MILAN_INFO (Milan 1.3 §5.4.4.1).
  func getMilanInfo(id targetEntityID: UniqueIdentifier) async throws -> MilanInfo {
    guard case let .getMilanInfo(info) = try await _mvu(targetEntityID, .getMilanInfo)
    else { throw MvuStatus.protocolError }
    return info
  }

  /// BIND_STREAM (Milan 1.3 §5.4.4.6): binds a listener stream to a talker stream.
  @discardableResult
  func bindStream(
    id targetEntityID: UniqueIdentifier, streamIndex: UInt16,
    talker: StreamIdentification, flags: BindStreamFlags = []
  ) async throws -> (talker: StreamIdentification, flags: BindStreamFlags) {
    guard case let .bindStream(flags, _, _, talkerStream) = try await _mvu(targetEntityID, .bindStream(
      flags: flags, descriptorType: .streamInput, descriptorIndex: streamIndex, talkerStream: talker
    )) else { throw MvuStatus.protocolError }
    return (talkerStream, flags)
  }

  /// UNBIND_STREAM (Milan 1.3 §5.4.4.7).
  func unbindStream(id targetEntityID: UniqueIdentifier, streamIndex: UInt16) async throws {
    _ = try await _mvu(targetEntityID, .unbindStream(descriptorType: .streamInput, descriptorIndex: streamIndex))
  }

  /// GET_STREAM_INPUT_INFO_EX (Milan 1.3 §5.4.4.8).
  func getStreamInputInfoEx(id targetEntityID: UniqueIdentifier, streamIndex: UInt16) async throws -> StreamInputInfoEx {
    guard case let .getStreamInputInfoEx(_, _, info) = try await _mvu(targetEntityID, .getStreamInputInfoEx(
      descriptorType: .streamInput, descriptorIndex: streamIndex
    )) else { throw MvuStatus.protocolError }
    return info
  }

  /// GET_SYSTEM_UNIQUE_ID (Milan 1.3 §5.4.4.3).
  func getSystemUniqueID(
    id targetEntityID: UniqueIdentifier
  ) async throws -> (systemUniqueID: UniqueIdentifier, systemName: String) {
    guard case let .getSystemUniqueID(systemUniqueID, systemName) =
      try await _mvu(targetEntityID, .getSystemUniqueID)
    else { throw MvuStatus.protocolError }
    return (systemUniqueID, systemName)
  }

  /// SET_SYSTEM_UNIQUE_ID (Milan 1.3 §5.4.4.2).
  @discardableResult
  func setSystemUniqueID(
    id targetEntityID: UniqueIdentifier,
    systemUniqueID: UniqueIdentifier, systemName: String
  ) async throws -> (systemUniqueID: UniqueIdentifier, systemName: String) {
    guard case let .setSystemUniqueID(systemUniqueID, systemName) = try await _mvu(targetEntityID, .setSystemUniqueID(
      systemUniqueID: systemUniqueID, systemName: systemName
    )) else { throw MvuStatus.protocolError }
    return (systemUniqueID, systemName)
  }

  /// GET_MEDIA_CLOCK_REFERENCE_INFO (Milan 1.3 §5.4.4.5).
  func getMediaClockReferenceInfo(
    id targetEntityID: UniqueIdentifier, clockDomainIndex: UInt16
  ) async throws -> (defaultPriority: MediaClockReferencePriority, info: MediaClockReferenceInfo) {
    guard case let .getMediaClockReferenceInfo(_, defaultPriority, info) =
      try await _mvu(targetEntityID, .getMediaClockReferenceInfo(clockDomainIndex: clockDomainIndex))
    else { throw MvuStatus.protocolError }
    return (defaultPriority, info)
  }

  /// SET_MEDIA_CLOCK_REFERENCE_INFO (Milan 1.3 §5.4.4.4); nil fields are left unchanged.
  @discardableResult
  func setMediaClockReferenceInfo(
    id targetEntityID: UniqueIdentifier, clockDomainIndex: UInt16,
    userMediaClockPriority: MediaClockReferencePriority? = nil,
    mediaClockDomainName: String? = nil
  ) async throws -> (defaultPriority: MediaClockReferencePriority, info: MediaClockReferenceInfo) {
    var flags = MediaClockReferenceInfoFlags()
    if userMediaClockPriority != nil { flags.insert(.userMediaClockReferencePriorityValid) }
    if mediaClockDomainName != nil { flags.insert(.mediaClockDomainNameValid) }
    guard case let .setMediaClockReferenceInfo(_, defaultPriority, info) = try await _mvu(targetEntityID, .setMediaClockReferenceInfo(
      clockDomainIndex: clockDomainIndex,
      flags: flags,
      defaultPriority: DefaultMediaClockReferencePriority.default.rawValue,
      userPriority: userMediaClockPriority ?? 0,
      domainName: mediaClockDomainName ?? ""
    )) else { throw MvuStatus.protocolError }
    return (defaultPriority, info)
  }
}

// MARK: - ACMP commands

public extension Controller {
  /// Connects a listener stream to a talker stream: CONNECT_RX_COMMAND to the listener
  /// (IEEE 1722.1-2021 §8.2.3).
  func connectStream(
    talker: StreamIdentification, listener: StreamIdentification
  ) async throws -> StreamConnectionState {
    try await _acmp(.connectRxCommand, talker: talker, listener: listener)
  }

  /// DISCONNECT_RX_COMMAND to the listener.
  func disconnectStream(
    talker: StreamIdentification, listener: StreamIdentification
  ) async throws -> StreamConnectionState {
    try await _acmp(.disconnectRxCommand, talker: talker, listener: listener)
  }

  /// DISCONNECT_TX_COMMAND to the talker, for cleaning up after a listener that has gone.
  func disconnectTalkerStream(
    talker: StreamIdentification, listener: StreamIdentification
  ) async throws -> StreamConnectionState {
    try await _acmp(.disconnectTxCommand, talker: talker, listener: listener)
  }

  /// GET_TX_STATE_COMMAND.
  func getTalkerStreamState(talker: StreamIdentification) async throws -> StreamConnectionState {
    try await _acmp(
      .getTxStateCommand,
      talker: talker,
      listener: StreamIdentification(entityID: UniqueIdentifier(), streamIndex: 0)
    )
  }

  /// GET_RX_STATE_COMMAND.
  func getListenerStreamState(listener: StreamIdentification) async throws -> StreamConnectionState {
    try await _acmp(
      .getRxStateCommand,
      talker: StreamIdentification(entityID: UniqueIdentifier(), streamIndex: 0),
      listener: listener
    )
  }

  /// GET_TX_CONNECTION_COMMAND for the talker's `connectionIndex`th connection.
  func getTalkerStreamConnection(
    talker: StreamIdentification, connectionIndex: UInt16
  ) async throws -> StreamConnectionState {
    try await _acmp(
      .getTxConnectionCommand,
      talker: talker,
      listener: StreamIdentification(entityID: UniqueIdentifier(), streamIndex: 0),
      connectionCount: connectionIndex
    )
  }
}
