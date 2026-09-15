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


/// Something an ATDECC Controller observed on the network. Remote entities are referred to by
/// ID; look up their ADP information with `Controller.discoveredEntity(id:)`.
///
/// Change notifications (`*Changed`, `*Added`, `*Removed`, started/stopped, acquired/locked)
/// are raised for unsolicited responses, which an entity sends to controllers registered with
/// `registerUnsolicitedNotifications(id:)` when another controller or the entity itself
/// changes its state (IEEE 1722.1-2021 §7.5.2). Sniffed ACMP responses are those exchanged
/// between other controllers, talkers and listeners (IEEE 1722.1-2021 §8.2).
public enum ControllerEvent: Sendable {
  case transportError
  /// Entities advertising GENERAL_CONTROLLER_IGNORE (IEEE 1722.1-2021 Table 6-2) are
  /// reported too; a general-purpose controller should not present them.
  case entityOnline(UniqueIdentifier)
  case entityUpdated(UniqueIdentifier)
  case entityOffline(UniqueIdentifier)
  case entityIdentifyNotification(UniqueIdentifier)
  case deregisteredFromUnsolicitedNotifications(UniqueIdentifier)
  /// Another controller rebooted the entity, or part of it (IEEE 1722.1-2021 §7.4.43): its state
  /// is about to be lost.
  case entityRebooting(UniqueIdentifier, descriptorType: UInt16, descriptorIndex: UInt16)

  case controllerConnectResponse(StreamConnectionState, AcmpStatus)
  case controllerDisconnectResponse(StreamConnectionState, AcmpStatus)
  case listenerConnectResponse(StreamConnectionState, AcmpStatus)
  case listenerDisconnectResponse(StreamConnectionState, AcmpStatus)
  case talkerStreamStateResponse(StreamConnectionState, AcmpStatus)
  case listenerStreamStateResponse(StreamConnectionState, AcmpStatus)

  case entityAcquired(UniqueIdentifier, owningEntity: UniqueIdentifier, descriptorType: UInt16, descriptorIndex: UInt16)
  case entityReleased(UniqueIdentifier, owningEntity: UniqueIdentifier, descriptorType: UInt16, descriptorIndex: UInt16)
  case entityLocked(UniqueIdentifier, lockingEntity: UniqueIdentifier, descriptorType: UInt16, descriptorIndex: UInt16)
  case entityUnlocked(UniqueIdentifier, lockingEntity: UniqueIdentifier, descriptorType: UInt16, descriptorIndex: UInt16)

  case configurationChanged(UniqueIdentifier, configurationIndex: UInt16)
  case associationIDChanged(UniqueIdentifier, associationID: UniqueIdentifier)
  case clockSourceChanged(UniqueIdentifier, clockDomainIndex: UInt16, clockSourceIndex: UInt16)

  case streamInputFormatChanged(UniqueIdentifier, streamIndex: UInt16, streamFormat: StreamFormat)
  case streamOutputFormatChanged(UniqueIdentifier, streamIndex: UInt16, streamFormat: StreamFormat)
  case streamPortInputAudioMappingsChanged(UniqueIdentifier, streamPortIndex: UInt16, mappings: [AudioMapping])
  case streamPortOutputAudioMappingsChanged(UniqueIdentifier, streamPortIndex: UInt16, mappings: [AudioMapping])
  case streamPortInputAudioMappingsAdded(UniqueIdentifier, streamPortIndex: UInt16, mappings: [AudioMapping])
  case streamPortOutputAudioMappingsAdded(UniqueIdentifier, streamPortIndex: UInt16, mappings: [AudioMapping])
  case streamPortInputAudioMappingsRemoved(UniqueIdentifier, streamPortIndex: UInt16, mappings: [AudioMapping])
  case streamPortOutputAudioMappingsRemoved(UniqueIdentifier, streamPortIndex: UInt16, mappings: [AudioMapping])
  case streamInputInfoChanged(UniqueIdentifier, streamIndex: UInt16, info: StreamInfo, fromGetResponse: Bool)
  case streamOutputInfoChanged(UniqueIdentifier, streamIndex: UInt16, info: StreamInfo, fromGetResponse: Bool)
  case streamInputStarted(UniqueIdentifier, streamIndex: UInt16)
  case streamOutputStarted(UniqueIdentifier, streamIndex: UInt16)
  case streamInputStopped(UniqueIdentifier, streamIndex: UInt16)
  case streamOutputStopped(UniqueIdentifier, streamIndex: UInt16)
  /// `maxTransitTime` is in nanoseconds.
  case maxTransitTimeChanged(UniqueIdentifier, streamIndex: UInt16, maxTransitTime: UInt64)

  case entityNameChanged(UniqueIdentifier, name: String)
  case entityGroupNameChanged(UniqueIdentifier, name: String)
  /// Any descriptor-level name change; `descriptorType` is `.configuration` for the
  /// configuration's own name (then `descriptorIndex` is the configuration index).
  case descriptorNameChanged(
    UniqueIdentifier,
    descriptorType: DescriptorType,
    configurationIndex: UInt16,
    descriptorIndex: UInt16,
    name: String
  )

  case audioUnitSamplingRateChanged(UniqueIdentifier, audioUnitIndex: UInt16, samplingRate: UInt32)
  case videoClusterSamplingRateChanged(UniqueIdentifier, videoClusterIndex: UInt16, samplingRate: UInt32)
  case sensorClusterSamplingRateChanged(UniqueIdentifier, sensorClusterIndex: UInt16, samplingRate: UInt32)

  case entityCountersChanged(UniqueIdentifier, valid: EntityCounterValidFlags, counters: DescriptorCounters)
  case avbInterfaceCountersChanged(UniqueIdentifier, avbInterfaceIndex: UInt16, valid: AvbInterfaceCounterValidFlags, counters: DescriptorCounters)
  case clockDomainCountersChanged(UniqueIdentifier, clockDomainIndex: UInt16, valid: ClockDomainCounterValidFlags, counters: DescriptorCounters)
  case streamInputCountersChanged(UniqueIdentifier, streamIndex: UInt16, valid: StreamInputCounterValidFlags, counters: DescriptorCounters)
  case streamOutputCountersChanged(UniqueIdentifier, streamIndex: UInt16, valid: StreamOutputCounterValidFlags, counters: DescriptorCounters)
  case avbInfoChanged(UniqueIdentifier, avbInterfaceIndex: UInt16, info: AvbInfo)
  case asPathChanged(UniqueIdentifier, avbInterfaceIndex: UInt16, asPath: [UniqueIdentifier])

  case controlValuesChanged(UniqueIdentifier, controlIndex: UInt16, packedControlValues: [UInt8])
  case memoryObjectLengthChanged(UniqueIdentifier, configurationIndex: UInt16, memoryObjectIndex: UInt16, length: UInt64)
  case operationStatus(UniqueIdentifier, descriptorType: UInt16, descriptorIndex: UInt16, operationID: UInt16, percentComplete: UInt16)

  case systemUniqueIDChanged(UniqueIdentifier, systemUniqueID: UniqueIdentifier, systemName: String)
  case mediaClockReferenceInfoChanged(UniqueIdentifier, clockDomainIndex: UInt16, defaultPriority: MediaClockReferencePriority, info: MediaClockReferenceInfo)
  case bindStream(UniqueIdentifier, streamIndex: UInt16, talker: StreamIdentification, flags: BindStreamFlags)
  case unbindStream(UniqueIdentifier, streamIndex: UInt16)
  case streamInputInfoExChanged(UniqueIdentifier, streamIndex: UInt16, info: StreamInputInfoEx)

  /// An unsolicited response with cr set: the entity asks the controller to execute `command`,
  /// which has not been applied (IEEE 1722.1-2021 §9.3.2.2).
  case controllerRequest(UniqueIdentifier, command: AemResponsePayload)

  case aecpRetry(UniqueIdentifier)
  case aecpTimeout(UniqueIdentifier)
  case aecpUnexpectedResponse(UniqueIdentifier)
  /// `responseTime` is in milliseconds.
  case aecpResponseTime(UniqueIdentifier, responseTime: UInt64)
  case aemAecpUnsolicitedReceived(UniqueIdentifier, sequenceID: UInt16)
  case mvuAecpUnsolicitedReceived(UniqueIdentifier, sequenceID: UInt16)
}

@available(*, deprecated, renamed: "ControllerEvent")
public typealias LocalEntityEvent = ControllerEvent

public extension ControllerEvent {
  /// The remote entity an event concerns; listener-side ACMP responses report the listener,
  /// talker-side ones the talker. nil for events with no entity.
  var entityID: UniqueIdentifier? {
    switch self {
    case .transportError:
      UniqueIdentifier?.none
    case let .entityOnline(id), let .entityUpdated(id), let .entityOffline(id),
         let .entityIdentifyNotification(id), let .deregisteredFromUnsolicitedNotifications(id),
         let .entityRebooting(id, _, _):
      id
    case let .controllerConnectResponse(state, _), let .controllerDisconnectResponse(state, _),
         let .listenerConnectResponse(state, _), let .listenerDisconnectResponse(state, _),
         let .listenerStreamStateResponse(state, _):
      state.listenerStream.entityID
    case let .talkerStreamStateResponse(state, _):
      state.talkerStream.entityID
    case let .entityAcquired(id, _, _, _), let .entityReleased(id, _, _, _),
         let .entityLocked(id, _, _, _), let .entityUnlocked(id, _, _, _):
      id
    case let .configurationChanged(id, _), let .associationIDChanged(id, _),
         let .clockSourceChanged(id, _, _):
      id
    case let .streamInputFormatChanged(id, _, _), let .streamOutputFormatChanged(id, _, _),
         let .streamPortInputAudioMappingsChanged(id, _, _),
         let .streamPortOutputAudioMappingsChanged(id, _, _),
         let .streamPortInputAudioMappingsAdded(id, _, _),
         let .streamPortOutputAudioMappingsAdded(id, _, _),
         let .streamPortInputAudioMappingsRemoved(id, _, _),
         let .streamPortOutputAudioMappingsRemoved(id, _, _):
      id
    case let .streamInputInfoChanged(id, _, _, _), let .streamOutputInfoChanged(id, _, _, _),
         let .streamInputStarted(id, _), let .streamOutputStarted(id, _),
         let .streamInputStopped(id, _), let .streamOutputStopped(id, _),
         let .maxTransitTimeChanged(id, _, _):
      id
    case let .entityNameChanged(id, _), let .entityGroupNameChanged(id, _),
         let .descriptorNameChanged(id, _, _, _, _):
      id
    case let .audioUnitSamplingRateChanged(id, _, _), let .videoClusterSamplingRateChanged(id, _, _),
         let .sensorClusterSamplingRateChanged(id, _, _):
      id
    case let .entityCountersChanged(id, _, _), let .avbInterfaceCountersChanged(id, _, _, _),
         let .clockDomainCountersChanged(id, _, _, _), let .streamInputCountersChanged(id, _, _, _),
         let .streamOutputCountersChanged(id, _, _, _), let .avbInfoChanged(id, _, _),
         let .asPathChanged(id, _, _):
      id
    case let .controlValuesChanged(id, _, _), let .memoryObjectLengthChanged(id, _, _, _),
         let .operationStatus(id, _, _, _, _), let .systemUniqueIDChanged(id, _, _),
         let .mediaClockReferenceInfoChanged(id, _, _, _):
      id
    case let .bindStream(id, _, _, _), let .unbindStream(id, _), let .streamInputInfoExChanged(id, _, _):
      id
    case let .controllerRequest(id, _):
      id
    case let .aecpRetry(id), let .aecpTimeout(id), let .aecpUnexpectedResponse(id),
         let .aecpResponseTime(id, _), let .aemAecpUnsolicitedReceived(id, _),
         let .mvuAecpUnsolicitedReceived(id, _):
      id
    }
  }
}
