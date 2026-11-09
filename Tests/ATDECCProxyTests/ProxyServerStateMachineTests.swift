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
@testable import ATDECCProxy
import IEEE802
import Synchronization
import XCTest

private typealias Action = AtdeccProxyServerStateMachine.Action

/// A readable form of an action, for comparing.
private func describe(_ action: Action) -> String {
  switch action {
  case let .sendHttpResponse(status): "http \(status)"
  case let .sendToApc(appdu): "apc \(appdu.messageType) \(_macAddressToString(appdu.address)) \(appdu.payload.count)"
  case let .sendToLayer2(packet): "l2 \(_macAddressToString(packet.destMacAddress)) from \(_macAddressToString(packet.sourceMacAddress))"
  case .closeConnection: "close"
  }
}

private func describe(_ actions: [Action]) -> [String] { actions.map(describe) }

private let link = _macAddressToString(linkMacAddress)
private let entity = _macAddressToString(entityMacAddress)
private let apc = _macAddressToString(apcMacAddress)

final class ProxyServerStateMachineTests: XCTestCase {
  private var entityIDs: AtdeccProxyEntityIDs!

  override func setUp() {
    entityIDs = AtdeccProxyEntityIDs(linkMacAddress: linkMacAddress, processID: 1234)
  }

  private func makeMachine(linkStatus: Bool = true, connection: Int? = nil) -> AtdeccProxyServerStateMachine {
    let connection = connection ?? entityIDs.makeConnection()
    return AtdeccProxyServerStateMachine(linkMacAddress: linkMacAddress, linkStatus: linkStatus) { [entityIDs] _, requested in
      entityIDs!.assign(connection, requested: requested)
    }
  }

  private func makeTransferring(at time: UInt64 = 0) -> AtdeccProxyServerStateMachine {
    var machine = makeMachine()
    _ = machine.requestReceived(200, at: time)
    return machine
  }

  private func adpFrame(from source: EUI48 = entityMacAddress, subtype: UInt8 = 0xFA, padding: Int = 0) -> IEEE802Packet {
    IEEE802Packet(
      destMacAddress: AvdeccMulticastMacAddress,
      tci: nil,
      sourceMacAddress: source,
      etherType: AvtpEtherType,
      payload: makeAvtpdu(subtype: subtype, padding: padding)
    )
  }

  func testAnAcceptedRequestStartsTransferWithTheLinkStatus() {
    var machine = makeMachine(linkStatus: true)
    XCTAssertEqual(describe(machine.requestReceived(200, at: 5)), ["http 200", "apc LINK_UP \(link) 0"])
    XCTAssertEqual(machine.state, .waiting)
    XCTAssertEqual(machine.nopTimeout, 15)
    var down = makeMachine(linkStatus: false)
    XCTAssertEqual(describe(down.requestReceived(200, at: 0)), ["http 200", "apc LINK_DOWN \(link) 0"])
  }

  func testARefusedRequestIsAnsweredThenClosed() {
    var machine = makeMachine()
    XCTAssertEqual(describe(machine.requestReceived(404, at: 0)), ["http 404", "close"])
    XCTAssertEqual(machine.state, .closed)
    XCTAssertTrue(machine.layer2FrameReceived(adpFrame(), at: 1).isEmpty)
  }

  func testNothingIsRelayedBeforeTheRequest() {
    var machine = makeMachine()
    XCTAssertTrue(machine.layer2FrameReceived(adpFrame(), at: 0).isEmpty)
    XCTAssertTrue(machine.apcMessageReceived(.atdeccFromApc(destinationMacAddress: entityMacAddress, avtpdu: makeAvtpdu()), at: 0).isEmpty)
    XCTAssertTrue(machine.timeAdvanced(to: 100).isEmpty)
  }

  func testANopIsSentOnceNopTimeoutHasPassed() {
    var machine = makeTransferring(at: 0)
    XCTAssertTrue(machine.timeAdvanced(to: 10).isEmpty)
    XCTAssertEqual(describe(machine.timeAdvanced(to: 11)), ["apc NOP 00:00:00:00:00:00 0"])
    XCTAssertTrue(machine.timeAdvanced(to: 21).isEmpty)
    XCTAssertEqual(describe(machine.timeAdvanced(to: 22)), ["apc NOP 00:00:00:00:00:00 0"])
  }

  func testTrafficToTheApcPostponesTheNop() {
    var machine = makeTransferring(at: 0)
    _ = machine.layer2FrameReceived(adpFrame(), at: 8)
    XCTAssertTrue(machine.timeAdvanced(to: 18).isEmpty)
    XCTAssertEqual(machine.timeAdvanced(to: 19).count, 1)
  }

  func testTrafficFromTheApcDoesNotPostponeTheNop() {
    var machine = makeTransferring(at: 0)
    _ = machine.apcMessageReceived(.atdeccFromApc(destinationMacAddress: entityMacAddress, avtpdu: makeAvtpdu()), at: 8)
    XCTAssertEqual(machine.timeAdvanced(to: 11).count, 1)
  }

  func testLayer2FramesAreRelayedWithTheirSourceAddressAndWithoutPadding() {
    var machine = makeTransferring()
    let actions = machine.layer2FrameReceived(adpFrame(padding: 4), at: 1)
    XCTAssertEqual(describe(actions), ["apc ATDECC_FROM_APS \(entity) \(12 + 56)"])
  }

  func testOnlyTableC7SubtypesAreRelayedToTheApc() {
    var machine = makeTransferring()
    XCTAssertTrue(machine.layer2FrameReceived(adpFrame(subtype: 0xFE), at: 1).isEmpty)
    XCTAssertTrue(machine.layer2FrameReceived(adpFrame(subtype: 0x02), at: 1).isEmpty)
    XCTAssertEqual(machine.layer2FrameReceived(adpFrame(subtype: 0xFB), at: 1).count, 1)
    XCTAssertEqual(machine.layer2FrameReceived(adpFrame(subtype: 0xFC), at: 1).count, 1)
  }

  func testApcPdusGoToTheirDestinationFromLinkMac() {
    var machine = makeTransferring()
    let actions = machine.apcMessageReceived(.atdeccFromApc(destinationMacAddress: entityMacAddress, avtpdu: makeAvtpdu(subtype: 0xFB)), at: 1)
    XCTAssertEqual(describe(actions), ["l2 \(entity) from \(link)"])
    guard case let .sendToLayer2(packet) = actions.first else { return XCTFail() }
    XCTAssertEqual(packet.etherType, AvtpEtherType)
    XCTAssertEqual(packet.payload, makeAvtpdu(subtype: 0xFB))
  }

  func testAnApcPduOutsideTableC7ClosesTheConnection() {
    var machine = makeTransferring()
    let actions = machine.apcMessageReceived(.atdeccFromApc(destinationMacAddress: entityMacAddress, avtpdu: makeAvtpdu(subtype: 0x02)), at: 1)
    XCTAssertEqual(describe(actions), ["close"])
    XCTAssertEqual(machine.state, .closed)
  }

  func testTheRequestedEntityIDIsAssignedIfFree() {
    var machine = makeTransferring()
    let requested = UniqueIdentifier(0x0211_22FF_FE33_4455)
    let actions = machine.apcMessageReceived(.entityIDRequest(apcMacAddress: apcMacAddress, entityID: requested), at: 3)
    XCTAssertEqual(describe(actions), ["apc ENTITY_ID_RESPONSE \(apc) 8"])
    guard case let .sendToApc(response) = actions.first else { return XCTFail() }
    XCTAssertEqual(response.entityID, requested)
    XCTAssertEqual(machine.nopTimeout, 13)
  }

  func testAnApcWithoutAnEntityIDIsGivenOneDerivedFromLinkMac() {
    var machine = makeTransferring()
    _ = machine.apcMessageReceived(.entityIDRequest(apcMacAddress: apcMacAddress, entityID: UniqueIdentifier()), at: 1)
    let id = machine.assignedEntityID!.rawValue
    XCTAssertEqual(id >> 16, UInt64(eui48: linkMacAddress))
    XCTAssertNotEqual(id & 0xFFFF, 0)
    XCTAssertNotEqual(id & 0xFFFF, 0xFFFF)
  }

  func testAnEntityIDHeldByAnotherApcIsNotAssignedTwice() {
    let requested = UniqueIdentifier(0x0211_22FF_FE33_4455)
    var first = makeTransferring()
    var second = makeTransferring()
    _ = first.apcMessageReceived(.entityIDRequest(apcMacAddress: apcMacAddress, entityID: requested), at: 1)
    _ = second.apcMessageReceived(.entityIDRequest(apcMacAddress: apcMacAddress, entityID: requested), at: 1)
    XCTAssertEqual(first.assignedEntityID, requested)
    XCTAssertNotEqual(second.assignedEntityID, requested)
    XCTAssertEqual(second.assignedEntityID!.rawValue >> 16, UInt64(eui48: linkMacAddress))
  }

  func testAReleasedEntityIDCanBeAssignedAgain() {
    let requested = UniqueIdentifier(0x0211_22FF_FE33_4455)
    let first = entityIDs.makeConnection()
    XCTAssertEqual(entityIDs.assign(first, requested: requested), requested)
    entityIDs.release(first)
    XCTAssertEqual(entityIDs.assign(entityIDs.makeConnection(), requested: requested), requested)
  }

  func testAnyApcAddressIsEchoedAndAnEntityIDAssigned() {
    var machine = makeTransferring()
    let actions = machine.apcMessageReceived(.entityIDRequest(apcMacAddress: AvdeccMulticastMacAddress, entityID: UniqueIdentifier()), at: 1)
    XCTAssertEqual(describe(actions), ["apc ENTITY_ID_RESPONSE \(_macAddressToString(AvdeccMulticastMacAddress)) 8"])
  }

  func testAFrameTooLongForAnAppduIsDropped() {
    var machine = makeTransferring()
    let jumbo = IEEE802Packet(
      destMacAddress: AvdeccMulticastMacAddress,
      tci: nil,
      sourceMacAddress: entityMacAddress,
      etherType: AvtpEtherType,
      payload: makeAvtpdu(subtype: 0xFB, controlDataLength: 1600)
    )
    XCTAssertTrue(machine.layer2FrameReceived(jumbo, at: 1).isEmpty)
    XCTAssertEqual(machine.state, .waiting)
  }

  func testLinkChangesAreReportedOnce() {
    var machine = makeTransferring()
    XCTAssertEqual(describe(machine.linkStatusChanged(false, at: 2)), ["apc LINK_DOWN \(link) 0"])
    XCTAssertTrue(machine.linkStatusChanged(false, at: 3).isEmpty)
    XCTAssertEqual(describe(machine.linkStatusChanged(true, at: 4)), ["apc LINK_UP \(link) 0"])
    XCTAssertEqual(machine.nopTimeout, 14)
  }

  func testALinkChangeBeforeTheRequestIsReportedAtStartTransfer() {
    var machine = makeMachine(linkStatus: true)
    XCTAssertTrue(machine.linkStatusChanged(false, at: 0).isEmpty)
    XCTAssertEqual(describe(machine.requestReceived(200, at: 0)), ["http 200", "apc LINK_DOWN \(link) 0"])
  }

  func testMessagesAnApcShouldNotSendAreIgnored() {
    var machine = makeTransferring()
    XCTAssertTrue(machine.apcMessageReceived(.nop, at: 1).isEmpty)
    XCTAssertTrue(machine.apcMessageReceived(.linkStatus(true, linkMacAddress: linkMacAddress), at: 1).isEmpty)
    XCTAssertTrue(machine.apcMessageReceived(Appdu(messageType: .vendor, payload: [1]), at: 1).isEmpty)
    XCTAssertTrue(machine.apcMessageReceived(Appdu(messageType: AppMessageType(rawValue: 0x42)), at: 1).isEmpty)
  }

  func testClosingIsFinal() {
    var machine = makeTransferring()
    XCTAssertEqual(describe(machine.close()), ["close"])
    XCTAssertTrue(machine.close().isEmpty)
    XCTAssertTrue(machine.timeAdvanced(to: 100).isEmpty)
  }
}

/// An ADPDU for `entityID`: ENTITY_AVAILABLE (0) or ENTITY_DEPARTING (1), with valid_time in
/// units of 2 seconds (IEEE 1722.1-2021 Clause 6.2.1.6).
func makeAdpdu(entityID: UInt64, messageType: UInt8 = 0, validTime: UInt8 = 5) -> [UInt8] {
  var bytes: [UInt8] = [AvtpSubtype.adp.rawValue, messageType, validTime << 3, 56]
  bytes += (0..<8).map { UInt8(truncatingIfNeeded: entityID >> (56 - 8 * $0)) }
  return bytes + [UInt8](repeating: 0, count: 56)
}

final class EntityIDTrackingTests: XCTestCase {
  private let clock = FakeClock()
  private var entityIDs: AtdeccProxyEntityIDs!
  private let lanID = UniqueIdentifier(0x0200_00FF_FE00_0042)

  override func setUp() {
    entityIDs = AtdeccProxyEntityIDs(linkMacAddress: linkMacAddress, processID: 1234) { [clock] in clock.now.withLock { $0 } }
  }

  private func advance(to time: UInt64) { clock.now.withLock { $0 = time } }

  func testAnIDAdvertisedOnTheLanIsNotAssigned() {
    entityIDs.observe(makeAdpdu(entityID: lanID.rawValue))
    let connection = entityIDs.makeConnection()
    let id = entityIDs.assign(connection, requested: lanID)
    XCTAssertNotEqual(id, lanID)
    XCTAssertEqual(id!.rawValue >> 16, UInt64(eui48: linkMacAddress))
  }

  func testAnAdvertisementExpiresWithItsValidTime() {
    entityIDs.observe(makeAdpdu(entityID: lanID.rawValue, validTime: 5))
    let connection = entityIDs.makeConnection()
    advance(to: 9)
    XCTAssertTrue(entityIDs.isInUse(lanID, for: connection))
    advance(to: 10)
    XCTAssertFalse(entityIDs.isInUse(lanID, for: connection))
    XCTAssertEqual(entityIDs.assign(connection, requested: lanID), lanID)
  }

  func testADepartingEntityIsForgotten() {
    entityIDs.observe(makeAdpdu(entityID: lanID.rawValue))
    entityIDs.observe(makeAdpdu(entityID: lanID.rawValue, messageType: 1))
    XCTAssertEqual(entityIDs.assign(entityIDs.makeConnection(), requested: lanID), lanID)
  }

  func testAnApcsOwnAdvertisementDoesNotCountAgainstIt() {
    let own = entityIDs.makeConnection()
    let other = entityIDs.makeConnection()
    entityIDs.observe(makeAdpdu(entityID: lanID.rawValue), sentBy: own)
    // heard again through the other connection's port, as the egress tap delivers it
    entityIDs.observe(makeAdpdu(entityID: lanID.rawValue))
    XCTAssertFalse(entityIDs.isInUse(lanID, for: own))
    XCTAssertTrue(entityIDs.isInUse(lanID, for: other))
    XCTAssertEqual(entityIDs.assign(own, requested: lanID), lanID)
  }

  func testAReconnectingApcKeepsItsID() {
    let first = entityIDs.makeConnection()
    XCTAssertEqual(entityIDs.assign(first, requested: lanID), lanID)
    entityIDs.observe(makeAdpdu(entityID: lanID.rawValue), sentBy: first)
    entityIDs.release(first)
    XCTAssertEqual(entityIDs.assign(entityIDs.makeConnection(), requested: lanID), lanID)
  }

  func testAnIDTheApcHoldsDoesNotCountAgainstIt() {
    let connection = entityIDs.makeConnection()
    XCTAssertEqual(entityIDs.assign(connection, requested: lanID), lanID)
    entityIDs.observe(makeAdpdu(entityID: lanID.rawValue))
    XCTAssertEqual(entityIDs.assign(connection, requested: lanID), lanID)
  }

  func testExpiredAdvertisementsArePruned() {
    entityIDs.observe(makeAdpdu(entityID: lanID.rawValue, validTime: 1))
    XCTAssertEqual(entityIDs.advertisementCount, 1)
    advance(to: 3)
    entityIDs.observe(makeAdpdu(entityID: 0x0200_00FF_FE00_0043))
    XCTAssertEqual(entityIDs.advertisementCount, 1)
  }

  func testDerivedIDsAvoidThoseOnTheLan() {
    let probe = entityIDs.makeConnection()
    let derived = entityIDs.assign(probe, requested: UniqueIdentifier())!
    entityIDs.release(probe)
    entityIDs.observe(makeAdpdu(entityID: derived.rawValue))
    XCTAssertNotEqual(entityIDs.assign(entityIDs.makeConnection(), requested: UniqueIdentifier()), derived)
  }
}

/// Seconds, set by the test.
final class FakeClock: Sendable {
  let now = Mutex<UInt64>(0)
}
