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


/// A change in the set of discovered entities.
enum DiscoveryEvent: Sendable {
  case online(Entity)
  case updated(Entity)
  case offline(UniqueIdentifier)
}

/// Tracks remote entities from their ADP advertisements (IEEE 1722.1-2021 §6.2.6 Discovery
/// state machine and §6.2.7 Discovery Interface state machine).
///
/// An entity is online while at least one of its interfaces has advertised within that
/// interface's valid time (twice `valid_time` seconds). An advertisement that changes a field
/// which must not change while an entity stays online, or whose available_index does not
/// increase, is treated as a new entity: it goes offline and comes back online.
///
/// Where the specification is silent or differs, this follows la_avdecc: an unchanged
/// available_index also means a new entity; each interface times out separately, where
/// Figure 6-4 has one timeout per entity; an ENTITY_AVAILABLE with ENTITY_NOT_READY is ignored,
/// so a discovered entity that becomes not ready times out rather than going offline at once;
/// and entities with GENERAL_CONTROLLER_IGNORE are discovered like any other.
struct DiscoveryStateMachine: Sendable {
  private struct DiscoveredEntity: Sendable {
    var entity: Entity
    var expiries: [UInt16: ContinuousClock.Instant]
  }

  private var _entities = [UniqueIdentifier: DiscoveredEntity]()

  var entities: [Entity] {
    _entities.values.map(\.entity)
  }

  func entity(id: UniqueIdentifier) -> Entity? {
    _entities[id]?.entity
  }

  mutating func handleEntityAvailable(
    _ adpdu: Adpdu,
    macAddress: [UInt8],
    now: ContinuousClock.Instant = .now
  ) -> [DiscoveryEvent] {
    // an entity that is not ready must not be enumerated (IEEE 1722.1-2021 §6.2.2.10)
    guard !adpdu.entityCapabilities.contains(.entityNotReady) else { return [] }

    let advertised = Entity(adpdu: adpdu, macAddress: macAddress)
    let interfaceIndex = advertised.interfacesInformation.keys.first!
    let expiry = now + .seconds(2 * Int(adpdu.validTime))

    guard var discovered = _entities[adpdu.entityID] else {
      _entities[adpdu.entityID] = DiscoveredEntity(
        entity: advertised,
        expiries: [interfaceIndex: expiry]
      )
      return [.online(advertised)]
    }

    var events = [DiscoveryEvent]()
    switch Self._merge(advertised, into: &discovered.entity) {
    case .unchanged:
      break
    case .updated:
      events = [.updated(discovered.entity)]
    case .replaced:
      discovered = DiscoveredEntity(entity: advertised, expiries: [:])
      events = [.offline(adpdu.entityID), .online(advertised)]
    }
    discovered.expiries[interfaceIndex] = expiry
    _entities[adpdu.entityID] = discovered
    return events
  }

  mutating func handleEntityDeparting(_ adpdu: Adpdu) -> [DiscoveryEvent] {
    forget(adpdu.entityID)
  }

  mutating func forget(_ entityID: UniqueIdentifier) -> [DiscoveryEvent] {
    _entities.removeValue(forKey: entityID) == nil ? [] : [.offline(entityID)]
  }

  /// Removes interfaces whose valid time has elapsed, taking an entity offline when none
  /// remain.
  mutating func expire(now: ContinuousClock.Instant = .now) -> [DiscoveryEvent] {
    var events = [DiscoveryEvent]()
    for (entityID, var discovered) in _entities {
      let expired = discovered.expiries.filter { $0.value < now }.keys
      guard !expired.isEmpty else { continue }
      for interfaceIndex in expired {
        discovered.expiries[interfaceIndex] = nil
        discovered.entity.interfacesInformation[interfaceIndex] = nil
      }
      if discovered.entity.interfacesInformation.isEmpty {
        _entities[entityID] = nil
        events.append(.offline(entityID))
      } else {
        _entities[entityID] = discovered
        events.append(.updated(discovered.entity))
      }
    }
    return events
  }

  private enum MergeResult {
    case unchanged
    case updated
    case replaced
  }

  /// Folds a single-interface advertisement into a known entity.
  private static func _merge(_ advertised: Entity, into entity: inout Entity) -> MergeResult {
    guard entity.entityModelID == advertised.entityModelID,
          entity.talkerStreamSources == advertised.talkerStreamSources,
          entity.talkerCapabilities == advertised.talkerCapabilities,
          entity.listenerStreamSinks == advertised.listenerStreamSinks,
          entity.listenerCapabilities == advertised.listenerCapabilities,
          entity.controllerCapabilities == advertised.controllerCapabilities,
          entity.identifyControlIndex == advertised.identifyControlIndex
    else {
      return .replaced
    }

    let (interfaceIndex, interface) = advertised.interfacesInformation.first!
    var result = MergeResult.unchanged

    if var known = entity.interfacesInformation[interfaceIndex] {
      // an interface's MAC address is fixed, and its available_index only increases while
      // the entity stays available
      guard known.macAddress == interface.macAddress,
            known.availableIndex < interface.availableIndex
      else {
        return .replaced
      }
      if known.gptpGrandmasterID != interface.gptpGrandmasterID ||
        known.gptpDomainNumber != interface.gptpDomainNumber
      {
        known.gptpGrandmasterID = interface.gptpGrandmasterID
        known.gptpDomainNumber = interface.gptpDomainNumber
        result = .updated
      }
      known.availableIndex = interface.availableIndex
      known.validTime = interface.validTime
      entity.interfacesInformation[interfaceIndex] = known
    } else {
      entity.interfacesInformation[interfaceIndex] = interface
      result = .updated
    }

    if entity.entityCapabilities != advertised.entityCapabilities ||
      entity.associationID != advertised.associationID
    {
      entity.entityCapabilities = advertised.entityCapabilities
      entity.associationID = advertised.associationID
      result = .updated
    }

    return result
  }
}
