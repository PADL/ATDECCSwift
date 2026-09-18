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
import IEEE802
import XCTest

private let entityID = UniqueIdentifier(0x0200_00FF_FE00_0002)
private let primaryMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
private let secondaryMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x01, 0x02]

private func adpdu(
  _ messageType: AdpMessageType = .entityAvailable,
  validTime: UInt8 = 5,
  availableIndex: UInt32,
  interfaceIndex: UInt16? = nil,
  capabilities: EntityCapabilities = .aemSupported
) -> Adpdu {
  Adpdu(
    messageType: messageType,
    validTime: validTime,
    entityID: entityID,
    entityCapabilities: interfaceIndex == nil ? capabilities : capabilities.union(.aemInterfaceIndexValid),
    availableIndex: availableIndex,
    interfaceIndex: interfaceIndex ?? 0
  )
}

private extension [DiscoveryEvent] {
  /// "online", "updated" or "offline" for each event.
  var kinds: [String] {
    map {
      switch $0 {
      case .online: "online"
      case .updated: "updated"
      case .offline: "offline"
      }
    }
  }
}

final class DiscoveryStateMachineTests: XCTestCase {
  private let start = ContinuousClock.now

  func testEntityExpiresAfterTwiceItsValidTime() {
    var discovery = DiscoveryStateMachine()
    // valid_time 5 is ten seconds
    let online = discovery.handleEntityAvailable(adpdu(availableIndex: 0), macAddress: primaryMacAddress, now: start)
    XCTAssertEqual(online.kinds, ["online"])
    XCTAssertEqual(discovery.expire(now: start + .seconds(10)).kinds, [])
    XCTAssertNotNil(discovery.entity(id: entityID))
    XCTAssertEqual(discovery.expire(now: start + .milliseconds(10001)).kinds, ["offline"])
    XCTAssertNil(discovery.entity(id: entityID))
  }

  func testAdvertisementRenewsValidTime() {
    var discovery = DiscoveryStateMachine()
    _ = discovery.handleEntityAvailable(adpdu(availableIndex: 0), macAddress: primaryMacAddress, now: start)
    let renewed = discovery.handleEntityAvailable(
      adpdu(availableIndex: 1), macAddress: primaryMacAddress, now: start + .seconds(8)
    )
    XCTAssertEqual(renewed.kinds, [])
    XCTAssertEqual(discovery.expire(now: start + .seconds(15)).kinds, [])
    XCTAssertEqual(discovery.expire(now: start + .seconds(19)).kinds, ["offline"])
  }

  func testInterfacesExpireSeparately() {
    var discovery = DiscoveryStateMachine()
    _ = discovery.handleEntityAvailable(
      adpdu(availableIndex: 0, interfaceIndex: 0), macAddress: primaryMacAddress, now: start
    )
    let merged = discovery.handleEntityAvailable(
      adpdu(availableIndex: 0, interfaceIndex: 1), macAddress: secondaryMacAddress, now: start + .seconds(5)
    )
    XCTAssertEqual(merged.kinds, ["updated"])
    XCTAssertEqual(discovery.entity(id: entityID)?.interfaceInformationCount, 2)

    XCTAssertEqual(discovery.expire(now: start + .seconds(11)).kinds, ["updated"])
    XCTAssertEqual(discovery.entity(id: entityID)?.interfacesInformation.keys.sorted(), [1])
    XCTAssertEqual(discovery.expire(now: start + .seconds(16)).kinds, ["offline"])
  }

  /// An available_index that does not increase means the entity restarted unnoticed.
  func testAvailableIndexThatDoesNotIncreaseIsANewEntity() {
    var discovery = DiscoveryStateMachine()
    _ = discovery.handleEntityAvailable(adpdu(availableIndex: 7), macAddress: primaryMacAddress, now: start)
    let repeated = discovery.handleEntityAvailable(adpdu(availableIndex: 7), macAddress: primaryMacAddress, now: start)
    XCTAssertEqual(repeated.kinds, ["offline", "online"])
    let regressed = discovery.handleEntityAvailable(adpdu(availableIndex: 0), macAddress: primaryMacAddress, now: start)
    XCTAssertEqual(regressed.kinds, ["offline", "online"])
    XCTAssertEqual(discovery.entity(id: entityID)?.interfacesInformation.values.first?.availableIndex, 0)
  }

  func testChangedMacAddressIsANewEntity() {
    var discovery = DiscoveryStateMachine()
    _ = discovery.handleEntityAvailable(adpdu(availableIndex: 0), macAddress: primaryMacAddress, now: start)
    let moved = discovery.handleEntityAvailable(adpdu(availableIndex: 1), macAddress: secondaryMacAddress, now: start)
    XCTAssertEqual(moved.kinds, ["offline", "online"])
  }

  func testEntityNotReadyIsIgnored() {
    var discovery = DiscoveryStateMachine()
    let notReady = discovery.handleEntityAvailable(
      adpdu(availableIndex: 0, capabilities: [.aemSupported, .entityNotReady]),
      macAddress: primaryMacAddress,
      now: start
    )
    XCTAssertEqual(notReady.kinds, [])
    XCTAssertNil(discovery.entity(id: entityID))
  }
}
