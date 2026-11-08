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

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import ATDECC
import IEEE802
import Synchronization

/// The entity IDs an APS has assigned to its APCs (IEEE 1722.1-2021 Clause C.5.2.2.5), one per
/// connection, and those ADP shows in use on the LAN.
///
/// An APC is given the ID it asks for unless it is known not to be unique: another APC of this
/// server holds it, or an entity on the LAN advertises it (ENTITY_AVAILABLE, until its
/// valid_time passes or it departs, IEEE 1722.1-2021 Clause 6.2.1.6). What the requesting
/// APC itself advertised does not count, so an APC keeps its ID; what an APC advertised is
/// forgotten when its connection closes, so one that reconnects keeps it too. Otherwise, or
/// if it asks for none, it is given one derived from linkMac (Clause C.5.2.1.15) with a
/// program ID (IEEE 1722.1-2021 Clause 6.2.1.8).
public final class AtdeccProxyEntityIDs: Sendable {
  /// An entity advertised on the LAN, until `expiry` (seconds on `clock`); `sender` is the
  /// connection whose APC advertised it, if one did.
  private struct Advertisement {
    var expiry: UInt64
    var sender: Int?
  }

  private struct State {
    var held = [Int: UniqueIdentifier]()
    var connections = Set<Int>()
    var nextConnection = 0
    var advertised = [UniqueIdentifier: Advertisement]()
  }

  public let linkMacAddress: EUI48
  private let firstProgramID: UInt16
  private let clock: @Sendable () -> UInt64
  private let state = Mutex(State())

  /// Program IDs start half the range away from those `EndStation.makeDynamicEntityID()`
  /// gives this process, so the APS's IDs keep clear of the host's own controllers. `clock`
  /// gives seconds, monotonic; by default from a `ContinuousClock`.
  public init(
    linkMacAddress: EUI48,
    processID: Int32 = getpid(),
    clock: (@Sendable () -> UInt64)? = nil
  ) {
    self.linkMacAddress = linkMacAddress
    let start = UInt32(dynamicEntityProgramID(processID: processID)) - 1 + 0x7FFE
    firstProgramID = UInt16(start % 0xFFFD) + 1
    let origin = ContinuousClock.now
    self.clock = clock ?? { UInt64(max((ContinuousClock.now - origin).components.seconds, 0)) }
  }

  /// A key for one connection's assignments, released with `release(_:)`.
  public func makeConnection() -> Int {
    state.withLock { state in
      defer { state.nextConnection += 1 }
      state.connections.insert(state.nextConnection)
      return state.nextConnection
    }
  }

  /// The ID for `connection`, given the one its APC requested or zero; nil if none is left.
  public func assign(_ connection: Int, requested: UniqueIdentifier) -> UniqueIdentifier? {
    let now = clock()
    return state.withLock { state in
      let inUse = Self.inUse(state, excluding: connection, at: now)
      let id = Self.isAssignable(requested) && !inUse.contains(requested) ? requested : derived(avoiding: inUse)
      state.held[connection] = id
      return id
    }
  }

  /// Forgets `connection`: the ID it holds and what its APC advertised.
  public func release(_ connection: Int) {
    state.withLock { state in
      state.held.removeValue(forKey: connection)
      state.connections.remove(connection)
      state.advertised = state.advertised.filter { $0.value.sender != connection }
    }
  }

  /// Notes an AVTPDU the APC of `connection` sent to the LAN.
  public func noteSent(_ avtpdu: [UInt8], by connection: Int) {
    guard let adpdu = try? Adpdu(bytes: avtpdu) else { return }
    let now = clock()
    state.withLock { state in
      switch adpdu.messageType {
      case .entityAvailable:
        state.advertised[adpdu.entityID] = Advertisement(expiry: now + 2 * UInt64(adpdu.validTime), sender: connection)
      case .entityDeparting:
        state.advertised.removeValue(forKey: adpdu.entityID)
      case .entityDiscover:
        break
      }
    }
  }

  /// Notes an AVTPDU received from the LAN. An advertisement an APC of this server made, heard
  /// again through another connection's port, stays that APC's.
  public func noteReceived(_ avtpdu: [UInt8]) {
    guard let adpdu = try? Adpdu(bytes: avtpdu) else { return }
    let now = clock()
    state.withLock { state in
      switch adpdu.messageType {
      case .entityAvailable:
        let sender = state.advertised[adpdu.entityID]?.sender.flatMap { state.connections.contains($0) ? $0 : nil }
        state.advertised[adpdu.entityID] = Advertisement(expiry: now + 2 * UInt64(adpdu.validTime), sender: sender)
      case .entityDeparting:
        state.advertised.removeValue(forKey: adpdu.entityID)
      case .entityDiscover:
        break
      }
    }
  }

  /// Whether `id` is known not to be unique for the APC of `connection`.
  public func isInUse(_ id: UniqueIdentifier, for connection: Int) -> Bool {
    let now = clock()
    return state.withLock { Self.inUse($0, excluding: connection, at: now).contains(id) }
  }

  private static func inUse(_ state: State, excluding connection: Int, at now: UInt64) -> Set<UniqueIdentifier> {
    var ids = Set(state.held.filter { $0.key != connection }.values)
    for (id, advertisement) in state.advertised where advertisement.expiry > now && advertisement.sender != connection {
      ids.insert(id)
    }
    ids.subtract(state.held[connection].map { [$0] } ?? [])
    return ids
  }

  private static func isAssignable(_ id: UniqueIdentifier) -> Bool {
    id.rawValue != 0 && id.rawValue != UInt64.max
  }

  private func derived(avoiding others: Set<UniqueIdentifier>) -> UniqueIdentifier? {
    let base = UInt64(eui48: linkMacAddress) << 16
    for offset in 0..<UInt32(0xFFFD) {
      let programID = UInt64((UInt32(firstProgramID) - 1 + offset) % 0xFFFD + 1)
      let id = UniqueIdentifier(base | programID)
      if !others.contains(id) { return id }
    }
    return nil
  }
}

//
// DNS-SD - Clauses C.2, C.3
//

/// The DNS-SD service type of an APS (IEEE 1722.1-2021 Clause C.2, Table C.1).
public let AppServiceType = "_avdecc._tcp"
/// The TCP port IANA assigned to APP (Table C.1).
public let AppDefaultPort: UInt16 = 17221

/// What an APS forwards (Clause C.3.7, Table C.3).
public enum AppServerMode: Int, Sendable {
  /// Messages to and from other devices on the network.
  case network = 0
  /// Messages to and from entities on the APS's own end station only.
  case host = 1
}

/// The TXT record of an APS (IEEE 1722.1-2021 Clause C.3, Table C.2), in order; values are
/// cut to their maximum lengths.
public func appServiceTXTRecord(
  priority: Int = 0,
  description: String,
  manufacturer: String,
  path: String = "/",
  mode: AppServerMode = .network
) -> [(String, String)] {
  [
    ("txtvers", "1"),
    ("Version", "\(AppVersion)"),
    ("Priority", String(String(max(priority, 0)).prefix(4))),
    ("Description", utf8Prefix(description, 64)),
    ("Manufacturer", utf8Prefix(manufacturer, 64)),
    ("path", utf8Prefix(path, 128)),
    ("Mode", "\(mode.rawValue)"),
  ]
}

private func utf8Prefix(_ string: String, _ count: Int) -> String {
  var result = ""
  for character in string {
    guard result.utf8.count + String(character).utf8.count <= count else { break }
    result.append(character)
  }
  return result
}
