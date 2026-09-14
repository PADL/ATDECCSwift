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

import IEEE802
#if os(Linux)
import IEEE802Linux
#endif
import Synchronization

/// A network port of an ATDECC End Station (IEEE 1722.1-2021 §3.1): the link on which AVTP
/// frames carrying ADP, AECP and ACMP are sent and received.
public protocol NetworkPort: Sendable {
  /// Source address of transmitted frames.
  var macAddress: EUI48 { get }

  func send(_ packet: IEEE802Packet) async throws

  /// Receives AVTP frames addressed to this port or to the AVDECC group addresses, calling
  /// `handler` for each, until the task is cancelled or the port fails.
  func receive(_ handler: (IEEE802Packet) async -> ()) async throws
}

#if os(Linux)

/// An Ethernet network port, using raw AF_PACKET sockets driven by io_uring. It joins the
/// AVDECC multicast groups rather than using promiscuous mode, so frames reach it through
/// bridges that filter multicast in hardware.
public struct EthernetPort: NetworkPort {
  private let _port: RawEthernetPort

  public init(interfaceName: String) throws {
    _port = try RawEthernetPort(name: interfaceName)
  }

  public var interfaceName: String {
    _port.interface.name
  }

  public var macAddress: EUI48 {
    _port.interface.macAddress
  }

  public func send(_ packet: IEEE802Packet) async throws {
    try await _port.send(packet)
  }

  public func receive(_ handler: (IEEE802Packet) async -> ()) async throws {
    let packets = try await _port.receivePackets(
      etherTypes: [AvtpEtherType],
      groupAddresses: [AvdeccMulticastMacAddress, AvdeccIdentifyMulticastMacAddress]
    )
    for try await packet in packets {
      await handler(packet)
    }
  }
}

#endif

/// An in-memory Ethernet segment connecting virtual ports, for tests and simulation. A frame
/// is delivered to every other port whose address matches its destination, or to all of them
/// for group addresses.
public final class VirtualNetwork: Sendable {
  private struct State {
    var nextID = 0
    var ports = [Int: VirtualPort]()
  }

  private let _state = Mutex(State())

  public init() {}

  /// Attaches a new port with `macAddress` to the network.
  public func makePort(macAddress: EUI48) -> VirtualPort {
    _state.withLock { state in
      let port = VirtualPort(network: self, id: state.nextID, macAddress: macAddress)
      state.ports[state.nextID] = port
      state.nextID += 1
      return port
    }
  }

  fileprivate func deliver(_ packet: IEEE802Packet, from senderID: Int) {
    let recipients = _state.withLock { state in
      state.ports.filter { id, port in
        id != senderID && (
          _isMulticast(macAddress: packet.destMacAddress) ||
            _isEqualMacAddress(packet.destMacAddress, port.macAddress)
        )
      }.values
    }
    for recipient in recipients {
      recipient.enqueue(packet)
    }
  }

  fileprivate func remove(_ id: Int) {
    _ = _state.withLock { $0.ports.removeValue(forKey: id) }
  }
}

/// A port on a `VirtualNetwork`.
public final class VirtualPort: NetworkPort {
  public let macAddress: EUI48
  private let _packets: AsyncStream<IEEE802Packet>
  private let _continuation: AsyncStream<IEEE802Packet>.Continuation
  private let _id: Int
  private weak let _network: VirtualNetwork?

  fileprivate init(network: VirtualNetwork, id: Int, macAddress: EUI48) {
    _network = network
    _id = id
    self.macAddress = macAddress
    (_packets, _continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
  }

  deinit {
    close()
  }

  /// Detaches the port from its network and ends reception.
  public func close() {
    _network?.remove(_id)
    _continuation.finish()
  }

  public func send(_ packet: IEEE802Packet) async throws {
    _network?.deliver(packet, from: _id)
  }

  public func receive(_ handler: (IEEE802Packet) async -> ()) async throws {
    for await packet in _packets where packet.etherType == AvtpEtherType {
      await handler(packet)
    }
  }

  fileprivate func enqueue(_ packet: IEEE802Packet) {
    _continuation.yield(packet)
  }
}
