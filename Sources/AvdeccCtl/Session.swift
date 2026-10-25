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
import Synchronization

/// Why a command did not succeed.
enum Failure: Error {
  /// The entity answered `command` with a failure status, or (`timedOut`) did not answer.
  case status(command: String, name: String, timedOut: Bool)
  case entityNotFound(UniqueIdentifier)
  /// The command's deadline passed during `activity`.
  case timedOut(activity: String?)
  case noIdentifyControl(UniqueIdentifier)

  var exitStatus: Int32 {
    switch self {
    case let .status(_, _, timedOut): timedOut ? 2 : 1
    case .entityNotFound, .timedOut: 2
    case .noIdentifyControl: 1
    }
  }

  var message: String {
    switch self {
    case let .status(command, name, timedOut): timedOut ? "\(command) timed out" : "\(command) failed: \(name)"
    case let .entityNotFound(id): "entity \(hex(id)) not found"
    case let .timedOut(activity): activity.map { "timed out \($0)" } ?? "timed out"
    case let .noIdentifyControl(id): "entity \(hex(id)) has no IDENTIFY control"
    }
  }
}

/// A command's records, and its exit status: a dump that could not read every descriptor
/// prints what it read and exits with 1.
struct Report: Sendable {
  var records: [Record]
  var exitStatus: Int32 = 0
}

/// The result of `body`, or `Failure.timedOut` once `timeout` has passed.
func withDeadline<T: Sendable>(
  _ timeout: Duration,
  _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T?.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(for: timeout)
      return nil
    }
    defer { group.cancelAll() }
    guard case let value?? = try await group.next() else { throw Failure.timedOut(activity: nil) }
    return value
  }
}

/// A controller running one command.
final class Session<Port: NetworkPort>: Sendable {
  let controller: Controller<Port>
  let options: Options
  /// What the command is doing, for the message if its deadline passes.
  let activity = Mutex<String?>(nil)

  init(controller: Controller<Port>, options: Options) {
    self.controller = controller
    self.options = options
  }

  /// Runs `body`, which sends `command`, translating a status it throws into a `Failure`.
  @discardableResult
  func step<T: Sendable>(_ command: String, _ body: () async throws -> T) async throws -> T {
    activity.withLock { $0 = "waiting for the response to \(command)" }
    do {
      return try await body()
    } catch let status as AemStatus {
      throw Failure.status(
        command: command,
        name: statusName(status),
        timedOut: status == .timedOut
      )
    } catch let status as AcmpStatus {
      throw Failure.status(
        command: command,
        name: statusName(status),
        timedOut: status == .timedOut
      )
    } catch let status as MvuStatus {
      throw Failure.status(
        command: command,
        name: statusName(status),
        timedOut: status == .timedOut
      )
    }
  }

  func run(_ command: Command) async throws -> Report {
    switch command {
    case .help:
      return Report(records: [])
    case let .discover(seconds):
      return try await discover(for: seconds)
    case let .dump(id):
      return try await dump(id)
    case let .streamInfo(id, direction, index):
      return try await Report(records: [streamInfo(id, direction, index)])
    case let .setFormat(id, direction, index, format, acquire, lock):
      return try await Report(records: [setFormat(
        id,
        direction,
        index,
        format,
        acquire: acquire,
        lock: lock
      )])
    case let .startStreaming(id, direction, index):
      return try await Report(records: [streaming(id, direction, index, start: true)])
    case let .stopStreaming(id, direction, index):
      return try await Report(records: [streaming(id, direction, index, start: false)])
    case let .counters(id, type, index):
      return try await Report(records: [counters(id, type, index)])
    case let .connect(listener, talker):
      let state = try await step("CONNECT_RX") {
        try await controller.connectStream(talker: talker, listener: listener)
      }
      return Report(records: [connectionRecord("CONNECT_RX", state)])
    case let .disconnect(listener, talker):
      return try await Report(records: [disconnect(listener, talker)])
    case let .rxState(listener):
      let state = try await step("GET_RX_STATE") {
        try await controller.getListenerStreamState(listener: listener)
      }
      return Report(records: [connectionRecord("GET_RX_STATE", state)])
    case let .txState(talker):
      return try await Report(records: [txState(talker)])
    case let .acquire(id, persistent):
      try await waitForEntity(id)
      let owner = try await step("ACQUIRE_ENTITY") { try await controller.acquireEntity(
        id: id,
        persistent: persistent
      ) }
      return Report(records: [Record(
        heading: "ACQUIRE_ENTITY \(hex(id))",
        fields: [("owner_id", .string(hex(owner)))]
      )])
    case let .release(id):
      try await waitForEntity(id)
      let owner = try await step("ACQUIRE_ENTITY (release)") {
        try await controller.releaseEntity(id: id)
      }
      return Report(records: [Record(
        heading: "RELEASE \(hex(id))",
        fields: [("owner_id", .string(hex(owner)))]
      )])
    case let .lock(id):
      try await waitForEntity(id)
      let locker = try await step("LOCK_ENTITY") { try await controller.lockEntity(id: id) }
      return Report(records: [Record(
        heading: "LOCK_ENTITY \(hex(id))",
        fields: [("locked_id", .string(hex(locker)))]
      )])
    case let .unlock(id):
      try await waitForEntity(id)
      let locker = try await step("LOCK_ENTITY (unlock)") {
        try await controller.unlockEntity(id: id)
      }
      return Report(records: [Record(
        heading: "UNLOCK \(hex(id))",
        fields: [("locked_id", .string(hex(locker)))]
      )])
    case let .identify(id, on):
      return try await Report(records: [identify(id, on: on)])
    }
  }

  // MARK: - Discovery

  /// Returns `id` once it has been discovered, sending ENTITY_DISCOVER for it each second until
  /// then; the caller's deadline ends the wait.
  @discardableResult
  func waitForEntity(_ id: UniqueIdentifier) async throws -> Entity {
    let events = await controller.events()
    if let entity = await controller.discoveredEntity(id: id) { return entity }
    activity.withLock { $0 = "waiting for entity \(hex(id)) to be discovered" }
    let discovery = Task { [controller] in
      while !Task.isCancelled {
        try? await controller.discoverRemoteEntity(id: id)
        try? await Task.sleep(for: .seconds(1))
      }
    }
    defer { discovery.cancel() }
    for await event in events {
      if case .entityOnline(id) = event, let entity = await controller.discoveredEntity(id: id) {
        return entity
      }
    }
    throw Failure.entityNotFound(id)
  }

  private func discover(for duration: Duration) async throws -> Report {
    try await controller.discoverRemoteEntities()
    try await Task.sleep(for: duration)
    let entities = await controller.discoveredEntities.sorted { $0.entityID < $1.entityID }
    // names are read together, each within the timeout
    let names = await withTaskGroup(of: (UniqueIdentifier, String?).self) { group in
      for entity in entities where entity.entityCapabilities.contains(.aemSupported) {
        group.addTask { [controller, options] in
          let name = try? await withDeadline(options.timeout) {
            try await controller.readEntityDescriptor(id: entity.entityID).entityName
          }
          return (entity.entityID, name)
        }
      }
      var names = [UniqueIdentifier: String]()
      for await (id, name) in group {
        names[id] = name
      }
      return names
    }
    return Report(records: entities.map { entityRecord($0, name: names[$0.entityID]) })
  }

  private func entityRecord(_ entity: Entity, name: String?) -> Record {
    var fields: [Field] = [
      ("entity_model_id", .string(hex(entity.entityModelID))),
      (
        "capabilities",
        .strings(flagNames(entity.entityCapabilities.rawValue, entityCapabilityNames))
      ),
      ("talker_stream_sources", .uint(entity.talkerStreamSources)),
      (
        "talker_capabilities",
        .strings(flagNames(entity.talkerCapabilities.rawValue, talkerCapabilityNames))
      ),
      ("listener_stream_sinks", .uint(entity.listenerStreamSinks)),
      (
        "listener_capabilities",
        .strings(flagNames(entity.listenerCapabilities.rawValue, listenerCapabilityNames))
      ),
    ]
    if let configuration = entity.currentConfigurationIndex {
      fields.append(("current_configuration", .uint(configuration)))
    }
    let interfaces = entity.interfacesInformation.sorted { $0.key < $1.key }
      .map { index, interface in
        var fields: [Field] = [("mac_address", .string(macAddressString(interface.macAddress)))]
        if let grandmaster = interface.gptpGrandmasterID {
          fields.append(("gptp_grandmaster_id", .string(hex(grandmaster))))
        }
        if let domain = interface.gptpDomainNumber {
          fields.append(("gptp_domain_number", .uint(domain)))
        }
        return (index, fields)
      }
    if interfaces.count == 1 {
      fields += interfaces[0].1
    } else {
      fields.append((
        "interfaces",
        .array(interfaces.map { .object([("avb_interface_index", .uint($0.0))] + $0.1) })
      ))
    }
    var keys: [Field] = [("entity_id", .string(hex(entity.entityID)))]
    if let name { keys.append(("name", .string(name))) }
    return Record(
      heading: hex(entity.entityID) + (name.map { " \"\($0)\"" } ?? ""),
      keys: keys,
      fields: fields
    )
  }

  // MARK: - Descriptors

  private func dump(_ id: UniqueIdentifier) async throws -> Report {
    try await waitForEntity(id)
    let entity = try await step("READ_DESCRIPTOR ENTITY") {
      try await controller.readEntityDescriptor(id: id)
    }
    let configurationIndex = entity.currentConfiguration
    var report = Report(records: [descriptorRecord(.entity(entity), index: 0)])
    let configuration = try await step("READ_DESCRIPTOR CONFIGURATION") {
      try await controller.readConfigurationDescriptor(
        id: id,
        configurationIndex: configurationIndex
      )
    }
    report.records.append(descriptorRecord(
      .configuration(configuration),
      index: configurationIndex
    ))
    let types: [DescriptorType] = [
      .audioUnit,
      .streamInput,
      .streamOutput,
      .avbInterface,
      .clockSource,
      .clockDomain,
    ]
    for type in types {
      for index in 0..<configuration.descriptorCount(type) {
        do {
          let descriptor = try await step("READ_DESCRIPTOR \(descriptorTypeName(type)) \(index)") {
            try await controller.readDescriptor(
              id: id, configurationIndex: configurationIndex, descriptorType: type,
              descriptorIndex: index
            )
          }
          var record = descriptorRecord(descriptor, index: index)
          if type == .avbInterface, let info = try? await controller.getAvbInfo(
            id: id,
            avbInterfaceIndex: index
          ) {
            record.fields.append(("avb_info", avbInfoValue(info)))
          }
          report.records.append(record)
        } catch let failure as Failure {
          guard case let .status(_, name, timedOut) = failure, !timedOut else { throw failure }
          report.records.append(Record(
            heading: "\(descriptorTypeName(type)) \(index)",
            keys: descriptorKeys(type, index),
            fields: [("error", .string(name))]
          ))
          report.exitStatus = 1
        }
      }
    }
    return report
  }

  private func descriptorKeys(_ type: DescriptorType, _ index: UInt16) -> [Field] {
    [("descriptor_type", .string(descriptorTypeName(type))), ("descriptor_index", .uint(index))]
  }

  private func descriptorRecord(_ descriptor: Descriptor, index: UInt16) -> Record {
    let (type, name, fields) = descriptorFields(descriptor)
    var keys = descriptorKeys(type, index)
    var heading = "\(descriptorTypeName(type)) \(index)"
    if let name {
      keys.append(("name", .string(name)))
      heading += " \"\(name)\""
    }
    return Record(heading: heading, keys: keys, fields: fields)
  }

  private func descriptorFields(_ descriptor: Descriptor) -> (DescriptorType, String?, [Field]) {
    switch descriptor {
    case let .entity(entity):
      return (.entity, entity.entityName, [
        ("entity_id", .string(hex(entity.entityID))),
        ("entity_model_id", .string(hex(entity.entityModelID))),
        ("firmware_version", .string(entity.firmwareVersion)),
        ("serial_number", .string(entity.serialNumber)),
        ("group_name", .string(entity.groupName)),
        (
          "capabilities",
          .strings(flagNames(entity.entityCapabilities.rawValue, entityCapabilityNames))
        ),
        ("talker_stream_sources", .uint(entity.talkerStreamSources)),
        (
          "talker_capabilities",
          .strings(flagNames(entity.talkerCapabilities.rawValue, talkerCapabilityNames))
        ),
        ("listener_stream_sinks", .uint(entity.listenerStreamSinks)),
        (
          "listener_capabilities",
          .strings(flagNames(entity.listenerCapabilities.rawValue, listenerCapabilityNames))
        ),
        ("available_index", .uint(entity.availableIndex)),
        ("association_id", .string(hex(entity.associationID))),
        ("configurations_count", .uint(entity.configurationsCount)),
        ("current_configuration", .uint(entity.currentConfiguration)),
      ])
    case let .configuration(configuration):
      let counts = configuration.descriptorCounts.sorted { $0.key.rawValue < $1.key.rawValue }
      return (.configuration, configuration.objectName, [
        (
          "descriptor_counts",
          .object(counts.map { (descriptorTypeName($0.key), .uint($0.value)) })
        ),
      ])
    case let .audioUnit(unit):
      return (.audioUnit, unit.objectName, [
        ("clock_domain_index", .uint(unit.clockDomainIndex)),
        ("current_sampling_rate", samplingRateValue(unit.currentSamplingRate)),
        ("sampling_rates", .array(unit.samplingRates.map(samplingRateValue))),
        ("stream_input_ports", portRange(unit.numberOfStreamInputPorts, unit.baseStreamInputPort)),
        (
          "stream_output_ports",
          portRange(unit.numberOfStreamOutputPorts, unit.baseStreamOutputPort)
        ),
        (
          "external_input_ports",
          portRange(unit.numberOfExternalInputPorts, unit.baseExternalInputPort)
        ),
        (
          "external_output_ports",
          portRange(unit.numberOfExternalOutputPorts, unit.baseExternalOutputPort)
        ),
        ("controls", portRange(unit.numberOfControls, unit.baseControl)),
      ])
    case let .streamInput(stream):
      return (.streamInput, stream.objectName, streamFields(stream))
    case let .streamOutput(stream):
      return (.streamOutput, stream.objectName, streamFields(stream))
    case let .avbInterface(interface):
      return (.avbInterface, interface.objectName, [
        ("mac_address", .string(macAddressString(interface.macAddress))),
        (
          "interface_flags",
          .strings(flagNames(interface.interfaceFlags.rawValue, avbInterfaceFlagNames))
        ),
        ("clock_identity", .string(hex(interface.clockIdentity))),
        ("priority1", .uint(interface.priority1)),
        ("clock_class", .uint(interface.clockClass)),
        ("offset_scaled_log_variance", .string(hex(interface.offsetScaledLogVariance, width: 4))),
        ("clock_accuracy", .string(hex(interface.clockAccuracy, width: 2))),
        ("priority2", .uint(interface.priority2)),
        ("domain_number", .uint(interface.domainNumber)),
        ("log_sync_interval", .uint(Int8(bitPattern: interface.logSyncInterval))),
        ("log_announce_interval", .uint(Int8(bitPattern: interface.logAnnounceInterval))),
        ("log_pdelay_interval", .uint(Int8(bitPattern: interface.logPDelayInterval))),
        ("port_number", .uint(interface.portNumber)),
      ])
    case let .clockSource(source):
      let type = switch source.clockSourceTypeRaw {
      case 0: "INTERNAL"
      case 1: "EXTERNAL"
      case 2: "INPUT_STREAM"
      default: hex(source.clockSourceTypeRaw, width: 4)
      }
      return (.clockSource, source.objectName, [
        ("clock_source_type", .string(type)),
        (
          "clock_source_flags",
          .strings(flagNames(source.clockSourceFlags.rawValue, clockSourceFlagNames))
        ),
        ("clock_source_identifier", .string(hex(source.clockSourceIdentifier))),
        ("clock_source_location", .string(
          "\(descriptorTypeName(source.clockSourceLocationType)) \(source.clockSourceLocationIndex)"
        )),
      ])
    case let .clockDomain(domain):
      return (.clockDomain, domain.objectName, [
        ("clock_source_index", .uint(domain.clockSourceIndex)),
        ("clock_sources", .array(domain.clockSources.map { .uint($0) })),
      ])
    default:
      return (.invalid, nil, [])
    }
  }

  private func streamFields(_ stream: StreamDescriptor) -> [Field] {
    var fields: [Field] = [
      ("clock_domain_index", .uint(stream.clockDomainIndex)),
      ("avb_interface_index", .uint(stream.avbInterfaceIndex)),
      ("stream_flags", .strings(flagNames(stream.streamFlags.rawValue, streamFlagNames))),
      ("current_format", .string(streamFormatDescription(stream.currentFormat))),
      ("formats", .strings(stream.formats.map(streamFormatDescription))),
      ("buffer_length_ns", .uint(stream.bufferLength)),
    ]
    if !stream.redundantStreams.isEmpty {
      fields.append(("redundant_streams", .array(stream.redundantStreams.map { .uint($0) })))
    }
    return fields
  }

  private func samplingRateValue(_ rate: SamplingRate) -> Value {
    rate.pull == 0 ? .uint(rate.baseFrequency) : .string(String(rate.nominalSampleRate))
  }

  private func portRange(_ count: UInt16, _ base: UInt16) -> Value {
    .object([("count", .uint(count)), ("base", .uint(base))])
  }

  private func avbInfoValue(_ info: AvbInfo) -> Value {
    .object([
      ("gptp_grandmaster_id", .string(hex(info.gptpGrandmasterID))),
      ("gptp_domain_number", .uint(info.gptpDomainNumber)),
      ("propagation_delay_ns", .uint(info.propagationDelay)),
      ("flags", .strings(flagNames(info.flags.rawValue, avbInfoFlagNames))),
    ])
  }

  // MARK: - Streams

  private func streamHeading(_ direction: Direction, _ index: UInt16) -> String {
    "\(descriptorTypeName(direction.descriptorType)) \(index)"
  }

  private func streamInfo(
    _ id: UniqueIdentifier,
    _ direction: Direction,
    _ index: UInt16
  ) async throws -> Record {
    try await waitForEntity(id)
    let info = try await step("GET_STREAM_INFO") {
      direction == .input
        ? try await controller.getStreamInputInfo(id: id, streamIndex: index)
        : try await controller.getStreamOutputInfo(id: id, streamIndex: index)
    }
    var fields: [Field] = [
      ("flags", .strings(flagNames(info.streamInfoFlags.rawValue, streamInfoFlagNames))),
      ("stream_format", .string(streamFormatDescription(info.streamFormat))),
      ("stream_id", .string(hex(info.streamID))),
      ("stream_dest_mac", .string(macAddressString(info.streamDestMac))),
      ("stream_vlan_id", .uint(info.streamVlanID)),
      ("msrp_accumulated_latency_ns", .uint(info.msrpAccumulatedLatency)),
    ]
    if info.streamInfoFlags.contains(.msrpFailureValid) {
      fields.append(("msrp_failure_code", .uint(info.msrpFailureCode)))
      fields.append(("msrp_failure_bridge_id", .string(hex(info.msrpFailureBridgeID, width: 16))))
    }
    if let flagsEx = info.streamInfoFlagsEx {
      fields.append(("flags_ex", .strings(flagNames(flagsEx.rawValue, [0: "REGISTERING"]))))
    }
    if let probing = info.probingStatusRaw {
      fields.append(("probing_status", .string(
        info.probingStatus.map { upperSnakeCase(String(describing: $0)) } ?? String(probing)
      )))
    }
    if let acmpStatus = info.acmpStatus {
      fields.append(("acmp_status", .string(statusName(acmpStatus))))
    }
    return Record(
      heading: streamHeading(direction, index),
      keys: descriptorKeys(direction.descriptorType, index),
      fields: fields
    )
  }

  private func setFormat(
    _ id: UniqueIdentifier, _ direction: Direction, _ index: UInt16, _ format: StreamFormat,
    acquire: Bool, lock: Bool
  ) async throws -> Record {
    try await waitForEntity(id)
    if acquire {
      try await step("ACQUIRE_ENTITY") { try await controller.acquireEntity(id: id) }
    }
    if lock {
      do {
        try await step("LOCK_ENTITY") { try await controller.lockEntity(id: id) }
      } catch {
        if acquire { _ = try? await controller.releaseEntity(id: id) }
        throw error
      }
    }
    let result = await Result {
      try await step("SET_STREAM_FORMAT") {
        direction == .input
          ? try await controller.setStreamInputFormat(id: id, streamIndex: index, to: format)
          : try await controller.setStreamOutputFormat(id: id, streamIndex: index, to: format)
      }
    }
    if lock { _ = try? await controller.unlockEntity(id: id) }
    if acquire { _ = try? await controller.releaseEntity(id: id) }
    return try Record(
      heading: streamHeading(direction, index),
      keys: descriptorKeys(direction.descriptorType, index),
      fields: [("stream_format", .string(streamFormatDescription(result.get())))]
    )
  }

  private func streaming(
    _ id: UniqueIdentifier,
    _ direction: Direction,
    _ index: UInt16,
    start: Bool
  ) async throws -> Record {
    try await waitForEntity(id)
    try await step(start ? "START_STREAMING" : "STOP_STREAMING") {
      switch (direction, start) {
      case (.input, true): try await controller.startStreamInput(id: id, streamIndex: index)
      case (.input, false): try await controller.stopStreamInput(id: id, streamIndex: index)
      case (.output, true): try await controller.startStreamOutput(id: id, streamIndex: index)
      case (.output, false): try await controller.stopStreamOutput(id: id, streamIndex: index)
      }
    }
    return Record(
      heading: streamHeading(direction, index),
      keys: descriptorKeys(direction.descriptorType, index),
      fields: [("streaming", .string(start ? "started" : "stopped"))]
    )
  }

  private func counters(
    _ id: UniqueIdentifier,
    _ type: DescriptorType,
    _ index: UInt16
  ) async throws -> Record {
    try await waitForEntity(id)
    let (valid, counters) = try await step("GET_COUNTERS") {
      try await controller.getCounters(id: id, descriptorType: type, descriptorIndex: index)
    }
    let names = counterNames(type)
    var fields: [Field] = [("counters_valid", .string(hex(valid, width: 8)))]
    for counter in 0..<DescriptorCounters.count
      where valid & (1 << counter) != 0 || counters[counter] != 0
    {
      let name = names[counter] ?? "COUNTER_\(counter)"
      fields.append((
        valid & (1 << counter) != 0 ? name : "\(name) (not valid)",
        .uint(counters[counter])
      ))
    }
    return Record(
      heading: "\(descriptorTypeName(type)) \(index) counters",
      keys: descriptorKeys(type, index),
      fields: fields
    )
  }

  // MARK: - Connections

  /// A stream as its entity ID and index, as the command line takes it.
  private func streamString(_ stream: StreamIdentification) -> String {
    "\(hex(stream.entityID)) \(stream.streamIndex)"
  }

  private func connectionRecord(_ command: String, _ state: StreamConnectionState) -> Record {
    var fields: [Field] = [
      ("talker", .string(streamString(state.talkerStream))),
      ("listener", .string(streamString(state.listenerStream))),
      ("stream_id", .string(hex(state.streamID))),
      ("stream_dest_mac", .string(macAddressString(state.streamDestAddress))),
      ("stream_vlan_id", .uint(state.streamVlanID)),
      ("connection_count", .uint(state.connectionCount)),
      ("flags", .strings(flagNames(state.flags.rawValue, connectionFlagNames))),
    ]
    if let entries = state.connectedListenersEntries {
      fields.append(("connected_listeners_entries", .uint(entries)))
    }
    return Record(heading: command, keys: [("command", .string(command))], fields: fields)
  }

  private func disconnect(
    _ listener: StreamIdentification,
    _ talker: StreamIdentification?
  ) async throws -> Record {
    let talker = if let talker {
      talker
    } else {
      try await step("GET_RX_STATE") {
        try await controller.getListenerStreamState(listener: listener)
      }.talkerStream
    }
    let state = try await step("DISCONNECT_RX") {
      try await controller.disconnectStream(talker: talker, listener: listener)
    }
    return connectionRecord("DISCONNECT_RX", state)
  }

  private func txState(_ talker: StreamIdentification) async throws -> Record {
    let state = try await step("GET_TX_STATE") {
      try await controller.getTalkerStreamState(talker: talker)
    }
    var record = connectionRecord("GET_TX_STATE", state)
    // GET_TX_CONNECTION is optional (Milan talkers do not implement it)
    var listeners = [Value]()
    for connection in 0..<state.connectionCount {
      guard let connected = try? await controller.getTalkerStreamConnection(
        talker: talker,
        connectionIndex: connection
      )
      else { break }
      listeners.append(.string(streamString(connected.listenerStream)))
    }
    if !listeners.isEmpty {
      record.fields.append(("listeners", .array(listeners)))
    }
    return record
  }

  // MARK: - Identification

  /// The IDENTIFY control's index: from the entity's advertisement, or else the first CONTROL
  /// of the current configuration whose control_type is IDENTIFY.
  private func identifyControlIndex(_ entity: Entity) async throws -> UInt16 {
    if let index = entity.identifyControlIndex { return index }
    let id = entity.entityID
    let configurationIndex = try await step("READ_DESCRIPTOR ENTITY") {
      try await controller.readEntityDescriptor(id: id)
    }.currentConfiguration
    let configuration = try await step("READ_DESCRIPTOR CONFIGURATION") {
      try await controller.readConfigurationDescriptor(
        id: id,
        configurationIndex: configurationIndex
      )
    }
    for index in 0..<configuration.controlCount {
      let control = try await step("READ_DESCRIPTOR CONTROL \(index)") {
        try await controller.readControlDescriptor(
          id: id,
          configurationIndex: configurationIndex,
          controlIndex: index
        )
      }
      if control.controlType == identifyControlType { return index }
    }
    throw Failure.noIdentifyControl(id)
  }

  private func identify(_ id: UniqueIdentifier, on: Bool) async throws -> Record {
    let entity = try await waitForEntity(id)
    let index = try await identifyControlIndex(entity)
    // a LINEAR_UINT8 of 0 (off) or 255 (on)
    try await step("SET_CONTROL") {
      try await controller.setControlValues(id: id, controlIndex: index, to: [on ? 0xFF : 0x00])
    }
    return Record(
      heading: "IDENTIFY \(hex(id))",
      fields: [("control_index", .uint(index)), ("identify", .bool(on))]
    )
  }
}

/// control_type of the IEEE 1722.1 IDENTIFY control.
let identifyControlType = UniqueIdentifier(0x90E0_F000_0000_0001)
