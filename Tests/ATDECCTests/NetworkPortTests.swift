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
import Synchronization
import XCTest
#if os(Linux)
import Glibc
#endif

private let firstMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x0A]
private let secondMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x0B]

private func makePacket(from source: EUI48, marker: UInt8) -> IEEE802Packet {
  IEEE802Packet(
    destMacAddress: AvdeccMulticastMacAddress,
    tci: nil,
    sourceMacAddress: source,
    etherType: AvtpEtherType,
    payload: [marker]
  )
}

/// Collects the payload markers of the frames a port receives, and how its reception ended.
private final class Receiver: Sendable {
  let markers = Mutex([UInt8]())
  let end = Mutex<Result<(), any Error>?>(nil)
  private let _task = Mutex<Task<(), Never>?>(nil)

  init(_ port: VirtualPort) {
    let task = Task {
      do {
        try await port.receive { packet in
          self.markers.withLock { $0.append(packet.payload[0]) }
        }
        self.end.withLock { $0 = .success(()) }
      } catch {
        self.end.withLock { $0 = .failure(error) }
      }
    }
    _task.withLock { $0 = task }
  }

  func stop() {
    _task.withLock { $0?.cancel() }
  }

  /// Waits up to `timeout` for `predicate` to hold.
  func wait(
    timeout: Duration = .seconds(1),
    until predicate: () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    repeat {
      if predicate() {
        return true
      }
      try? await Task.sleep(for: .milliseconds(5))
    } while ContinuousClock.now < deadline
    return false
  }
}

final class VirtualPortTests: XCTestCase {
  func testLinkDownDropsFramesInBothDirections() async throws {
    let network = VirtualNetwork()
    let first = network.makePort(macAddress: firstMacAddress)
    let second = network.makePort(macAddress: secondMacAddress)
    let secondReceiver = Receiver(second)
    defer { secondReceiver.stop() }

    first.setLinkUp(false)
    // nothing is sent from a port whose link is down
    try await first.send(makePacket(from: firstMacAddress, marker: 1))
    // nor received by it
    try await second.send(makePacket(from: secondMacAddress, marker: 2))
    // and it does not receive, as an AF_PACKET socket on an interface that is down does not
    let firstReceiver = Receiver(first)
    let receptionEnded = await firstReceiver.wait { firstReceiver.end.withLock { $0 != nil } }
    XCTAssertTrue(receptionEnded)
    if case .success = firstReceiver.end.withLock({ $0 }) {
      XCTFail("reception on a port whose link is down did not fail")
    }

    first.setLinkUp(true)
    let restartedReceiver = Receiver(first)
    defer { restartedReceiver.stop() }
    try await first.send(makePacket(from: firstMacAddress, marker: 3))
    try await second.send(makePacket(from: secondMacAddress, marker: 4))
    let secondReceived = await secondReceiver.wait { secondReceiver.markers.withLock { $0.contains(3) } }
    let firstReceived = await restartedReceiver.wait { restartedReceiver.markers.withLock { $0.contains(4) } }
    XCTAssertTrue(secondReceived && firstReceived)
    XCTAssertEqual(secondReceiver.markers.withLock { $0 }, [3])
    XCTAssertEqual(restartedReceiver.markers.withLock { $0 }, [4])
  }

  func testLinkDownEndsReception() async throws {
    let network = VirtualNetwork()
    let port = network.makePort(macAddress: firstMacAddress)
    let receiver = Receiver(port)
    defer { receiver.stop() }
    // let reception begin before the link goes down
    try await Task.sleep(for: .milliseconds(20))
    port.setLinkUp(false)
    let receptionEnded = await receiver.wait { receiver.end.withLock { $0 != nil } }
    XCTAssertTrue(receptionEnded)
    if case .success = receiver.end.withLock({ $0 }) {
      XCTFail("reception did not fail when the link went down")
    }
  }
}

final class EndStationTests: XCTestCase {
  // a PDU shorter than the Ethernet minimum payload is padded with zeros, and a longer one sent as
  // it is
  func testSentPdusArePaddedToTheEthernetMinimum() async throws {
    let network = VirtualNetwork()
    let endStation = EndStation(port: network.makePort(macAddress: firstMacAddress))
    let peer = network.makePort(macAddress: secondMacAddress)
    let payloads = Mutex([[UInt8]]())
    let reception = Task {
      try await peer.receive { packet in
        payloads.withLock { $0.append(packet.payload) }
      }
    }
    defer { reception.cancel() }
    // let reception begin
    try await Task.sleep(for: .milliseconds(20))

    let command = AvdeccPdu.aecp(.aem(AemAecpdu(
      isResponse: false,
      targetEntityID: UniqueIdentifier(1),
      controllerEntityID: UniqueIdentifier(2),
      commandType: .getCounters,
      commandSpecificData: [0x00, 0x05, 0x00, 0x00]
    )))
    let advertisement = AvdeccPdu.adp(Adpdu(messageType: .entityAvailable, entityID: UniqueIdentifier(3)))
    try await endStation.send(command, to: .unicast(secondMacAddress))
    try await endStation.send(advertisement, to: .multicast)

    let deadline = ContinuousClock.now + .seconds(1)
    while payloads.withLock({ $0.count }) < 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let received = payloads.withLock { $0 }
    guard received.count == 2 else { return XCTFail("received \(received.count) frames") }
    let commandBytes = try command.serialized()
    XCTAssertEqual(commandBytes.count, 28)
    XCTAssertEqual(received[0], commandBytes + [UInt8](repeating: 0, count: 46 - commandBytes.count))
    XCTAssertEqual(received[1], try advertisement.serialized())
    XCTAssertEqual(received[1].count, 68)
  }
}

#if os(Linux)

private let testInterfaceIndex = 7
private let otherInterfaceIndex = 8

private struct StateReadFailure: Error {}

/// The interface state a link monitor reads: running or not, absent (nil), or unreadable.
private final class InterfaceState: Sendable {
  enum Reading {
    case running(Bool)
    case absent
    case unreadable
  }

  private let _reading = Mutex(Reading.running(false))

  func set(_ reading: Reading) {
    _reading.withLock { $0 = reading }
  }

  func read() throws -> Bool? {
    switch _reading.withLock({ $0 }) {
    case let .running(isRunning): isRunning
    case .absent: nil
    case .unreadable: throw StateReadFailure()
    }
  }
}

private final class Reports: Sendable {
  let values = Mutex([Bool]())
}

/// The link notification subscriptions a test hands a monitor, in turn.
private final class Subscriptions: Sendable {
  typealias Notifications = AsyncThrowingStream<LinkNotification, any Error>

  private let _pending: Mutex<[Notifications]>
  let count = Mutex(0)

  init(_ subscriptions: [Notifications]) {
    _pending = Mutex(subscriptions)
  }

  func subscribe() throws -> Notifications {
    count.withLock { $0 += 1 }
    return try _pending.withLock { pending in
      guard !pending.isEmpty else { throw StateReadFailure() }
      return pending.removeFirst()
    }
  }
}

private func waitFor(_ expected: [Bool], in reports: Reports) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(1)
  repeat {
    if reports.values.withLock({ $0 }) == expected {
      return true
    }
    try? await Task.sleep(for: .milliseconds(5))
  } while ContinuousClock.now < deadline
  return false
}

final class LinkMonitorTests: XCTestCase {
  func testStateIsReadAgainAfterEachNotification() async throws {
    let state = InterfaceState()
    let reports = Reports()
    let (notifications, continuation) = AsyncThrowingStream<LinkNotification, any Error>.makeStream()
    let subscriptions = Subscriptions([notifications])
    let monitor = Task {
      try await _monitorLinkState(
        interfaceName: "test0",
        interfaceIndex: { testInterfaceIndex },
        subscribe: subscriptions.subscribe,
        isInterfaceRunning: { _ in try state.read() },
        handler: { isUp in reports.values.withLock { $0.append(isUp) } }
      )
    }
    defer { monitor.cancel() }

    var reported = await waitFor([false], in: reports)
    XCTAssertTrue(reported, "initial state not reported")

    // the notification that the link came up was lost; any later one reveals it
    state.set(.running(true))
    continuation.yield(.newLink(interfaceIndex: otherInterfaceIndex, flags: 0))
    reported = await waitFor([false, true], in: reports)
    XCTAssertTrue(reported, "a lost rising edge was not recovered")

    // a stale notification does not override the state read
    continuation.yield(.newLink(interfaceIndex: testInterfaceIndex, flags: 0))
    // the interface is removed
    state.set(.absent)
    continuation.yield(.deleteLink(interfaceIndex: testInterfaceIndex))
    reported = await waitFor([false, true, false], in: reports)
    XCTAssertTrue(reported, "a removed interface was not reported down")

    // when the state cannot be read, the notifications for the interface decide
    state.set(.unreadable)
    continuation.yield(.newLink(interfaceIndex: testInterfaceIndex, flags: _interfaceRunningFlag))
    reported = await waitFor([false, true, false, true], in: reports)
    XCTAssertTrue(reported)
    continuation.yield(.newLink(interfaceIndex: otherInterfaceIndex, flags: 0))
    continuation.yield(.deleteLink(interfaceIndex: testInterfaceIndex))
    reported = await waitFor([false, true, false, true, false], in: reports)
    XCTAssertTrue(reported, "RTM_DELLINK was not taken as down")

    continuation.finish()
    try await monitor.value
  }

  // a socket that overruns fails its notifications; the monitor subscribes again, reading the state
  // afresh, so a change whose notification was dropped is still reported
  func testSubscribesAgainWhenNotificationsFail() async throws {
    let state = InterfaceState()
    let reports = Reports()
    let (first, firstContinuation) = AsyncThrowingStream<LinkNotification, any Error>.makeStream()
    let (second, secondContinuation) = AsyncThrowingStream<LinkNotification, any Error>.makeStream()
    let subscriptions = Subscriptions([first, second])
    let monitor = Task {
      try await _monitorLinkState(
        interfaceName: "test0",
        interfaceIndex: { testInterfaceIndex },
        subscribe: subscriptions.subscribe,
        isInterfaceRunning: { _ in try state.read() },
        handler: { isUp in reports.values.withLock { $0.append(isUp) } }
      )
    }
    defer { monitor.cancel() }

    var reported = await waitFor([false], in: reports)
    XCTAssertTrue(reported)
    firstContinuation.yield(.newLink(interfaceIndex: otherInterfaceIndex, flags: 0))
    state.set(.running(true))
    firstContinuation.finish(throwing: StateReadFailure())
    reported = await waitFor([false, true], in: reports)
    XCTAssertTrue(reported, "the state was not read again after subscribing again")
    XCTAssertEqual(subscriptions.count.withLock { $0 }, 2)

    secondContinuation.finish()
    try await monitor.value
  }

  // a subscription that fails before delivering anything is not retried
  func testNotificationsFailingAtOnceThrow() async throws {
    let (notifications, continuation) = AsyncThrowingStream<LinkNotification, any Error>.makeStream()
    continuation.finish(throwing: StateReadFailure())
    let subscriptions = Subscriptions([notifications])
    do {
      try await _monitorLinkState(
        interfaceName: "test0",
        interfaceIndex: { testInterfaceIndex },
        subscribe: subscriptions.subscribe,
        isInterfaceRunning: { _ in false },
        handler: { _ in }
      )
      XCTFail("expected the failure to be thrown")
    } catch is StateReadFailure {}
    XCTAssertEqual(subscriptions.count.withLock { $0 }, 1)
  }
}

#endif
