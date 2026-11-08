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
import ATDECCProxy
import IEEE802
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

  func testAMulticastApcAddressClosesTheConnection() {
    var machine = makeTransferring()
    let actions = machine.apcMessageReceived(.entityIDRequest(apcMacAddress: AvdeccMulticastMacAddress, entityID: UniqueIdentifier()), at: 1)
    XCTAssertEqual(describe(actions), ["close"])
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
