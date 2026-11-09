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

/// The seconds between messages to an idle APC: nopTimeout is set this far ahead
/// (IEEE 1722.1-2021 Figure C.2).
public let AppNopInterval: UInt64 = 10

/// The APS state machine for one APC connection (IEEE 1722.1-2021 Clause C.5.2, Figure C.2),
/// from CONNECTED on: INITIALIZE and WAIT_FOR_CONNECT are the server's accept loop, and FINISH
/// its shutdown. Each input is one of the figure's conditions, handled at once, so the
/// transient states (START_TRANSFER, LINK_STATUS, TRANSFER_TO_L2, ...) return to WAITING within
/// the call. Times are currentTime, in seconds (Clause C.5.2.1.4).
public struct AtdeccProxyServerStateMachine {
  public enum State: Sendable, Equatable {
    case waitingForRequest
    case waiting
    case closed
  }

  /// What the connection does in response; performed in order.
  public enum Action: Sendable {
    /// sendHttpResponse(requestValid) (Clause C.5.2.2.6).
    case sendHttpResponse(Int)
    /// An APPDU to send to the APC.
    case sendToApc(Appdu)
    /// sendAvdeccToL2(out) (Clause C.5.2.2.4): a frame to send on the network port.
    case sendToLayer2(IEEE802Packet)
    /// closeTcpConnection() (Clause C.5.2.2.1).
    case closeConnection
  }

  /// Assigns the APC at the given MAC address an entity ID, given the one it asked for or zero;
  /// nil refuses the request (Clause C.5.2.2.5).
  public typealias EntityIDAssigner = (_ apcMacAddress: EUI48, _ requested: UniqueIdentifier) -> UniqueIdentifier?

  public private(set) var state = State.waitingForRequest
  /// linkMac (Clause C.5.2.1.15).
  public let linkMacAddress: EUI48
  /// linkStatus (Clause C.5.2.1.9).
  public private(set) var linkStatus: Bool
  /// nopTimeout (Clause C.5.2.1.12).
  public private(set) var nopTimeout: UInt64 = 0
  /// The entity ID last assigned to the APC.
  public private(set) var assignedEntityID: UniqueIdentifier?
  private let entityIDAssigner: EntityIDAssigner

  public init(linkMacAddress: EUI48, linkStatus: Bool, assignEntityID: @escaping EntityIDAssigner) {
    self.linkMacAddress = linkMacAddress
    self.linkStatus = linkStatus
    entityIDAssigner = assignEntityID
  }

  /// WAITING_FOR_REQUEST: requestValid becomes `status`. 200 goes to START_TRANSFER, which also
  /// reports the link status; anything else to REJECT, then CLOSED.
  public mutating func requestReceived(_ status: Int, at currentTime: UInt64) -> [Action] {
    guard state == .waitingForRequest else { return [] }
    guard status == 200 else {
      state = .closed
      return [.sendHttpResponse(status), .closeConnection]
    }
    state = .waiting
    nopTimeout = currentTime + AppNopInterval
    return [.sendHttpResponse(status), .sendToApc(.linkStatus(linkStatus, linkMacAddress: linkMacAddress))]
  }

  /// A message from the APC: apcMsg for ATDECC_FROM_APC, assignEntityIdRequest for
  /// ENTITY_ID_REQUEST. Others an APC has no business sending are ignored.
  public mutating func apcMessageReceived(_ appdu: Appdu, at currentTime: UInt64) -> [Action] {
    guard state == .waiting else { return [] }
    switch appdu.messageType {
    case .atdeccFromApc:
      return transferToLayer2(appdu)
    case .entityIDRequest:
      return assignEntityIDToApc(appdu, at: currentTime)
    default:
      return []
    }
  }

  /// TRANSFER_TO_L2: an AVTPDU outside Table C.7 sets incomingTcpClosed (Clause C.5.2.2.4).
  private mutating func transferToLayer2(_ appdu: Appdu) -> [Action] {
    guard isAppAvtpdu(appdu.payload) else { return close() }
    let packet = IEEE802Packet(
      destMacAddress: appdu.address,
      tci: nil,
      sourceMacAddress: linkMacAddress,
      etherType: AvtpEtherType,
      payload: appdu.payload
    )
    return [.sendToLayer2(packet)]
  }

  /// ASSIGN_ENTITY_ID: sendEntityIdAssignment(a, entity_id) (Clause C.5.2.2.5). The address
  /// is echoed whatever it is: Clause C.5.2.2.5 defines no refusal, and a browser APC has no
  /// MAC address of its own to give.
  private mutating func assignEntityIDToApc(_ appdu: Appdu, at currentTime: UInt64) -> [Action] {
    guard let requested = appdu.entityID, let entityID = entityIDAssigner(appdu.address, requested) else {
      return close()
    }
    assignedEntityID = entityID
    nopTimeout = currentTime + AppNopInterval
    return [.sendToApc(.entityIDResponse(apcMacAddress: appdu.address, entityID: entityID))]
  }

  /// TRANSFER_TO_APC: L2Msg, for a frame with a Table C.7 subtype (Clause C.5.2.1.11), sent
  /// without its Ethernet padding. A frame whose AVTPDU is malformed or would not fit an APPDU
  /// (a LAN with a larger MTU) is dropped.
  public mutating func layer2FrameReceived(_ packet: IEEE802Packet, at currentTime: UInt64) -> [Action] {
    guard state == .waiting, packet.etherType == AvtpEtherType, isAppAvtpdu(packet.payload),
          let avtpdu = try? avtpdu(withoutPaddingFrom: packet.payload, maximumLength: Appdu.maximumPayloadLength)
    else {
      return []
    }
    nopTimeout = currentTime + AppNopInterval
    return [.sendToApc(.atdeccFromAps(sourceMacAddress: packet.sourceMacAddress, avtpdu: avtpdu))]
  }

  /// LINK_STATUS on linkStatusChanged; a status reported again unchanged sends nothing.
  public mutating func linkStatusChanged(_ isUp: Bool, at currentTime: UInt64) -> [Action] {
    guard linkStatus != isUp else { return [] }
    linkStatus = isUp
    guard state == .waiting else { return [] }
    nopTimeout = currentTime + AppNopInterval
    return [.sendToApc(.linkStatus(isUp, linkMacAddress: linkMacAddress))]
  }

  /// SEND_NOP once currentTime passes nopTimeout.
  public mutating func timeAdvanced(to currentTime: UInt64) -> [Action] {
    guard state == .waiting, currentTime > nopTimeout else { return [] }
    nopTimeout = currentTime + AppNopInterval
    return [.sendToApc(.nop)]
  }

  /// CLOSED on incomingTcpClosed or finished: CLOSE_AND_FINISH closes the connection too.
  public mutating func close() -> [Action] {
    guard state != .closed else { return [] }
    state = .closed
    return [.closeConnection]
  }
}
