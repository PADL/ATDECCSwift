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
import FlyingFox
import Foundation
import IEEE802
import XCTest

let apcMacAddress: EUI48 = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]
let linkMacAddress: EUI48 = [0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]
let entityMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x42]

func macBytes(_ address: EUI48) -> [UInt8] { (0..<6).map { address[$0] } }

/// An AVTP control PDU with `subtype` and `controlDataLength` octets of data, then `padding`.
func makeAvtpdu(subtype: UInt8 = AvtpSubtype.adp.rawValue, controlDataLength: Int = 56, padding: Int = 0) -> [UInt8] {
  var bytes: [UInt8] = [subtype, 0x00, UInt8(controlDataLength >> 8), UInt8(controlDataLength & 0xFF)]
  bytes += [UInt8](repeating: 0x11, count: 8) // stream_id / entity_id
  bytes += (0..<controlDataLength).map { UInt8(truncatingIfNeeded: $0) }
  return bytes + [UInt8](repeating: 0, count: padding)
}

final class AppduTests: XCTestCase {
  func testHeaderLayoutFollowsFigureC1() {
    let appdu = Appdu.atdeccFromApc(destinationMacAddress: entityMacAddress, avtpdu: [0xFA, 1, 2])
    XCTAssertEqual(appdu.serialized(), [0x00, 0x06, 0x00, 0x03] + macBytes(entityMacAddress) + [0, 0, 0xFA, 1, 2])
  }

  func testEveryMessageTypeRoundTrips() throws {
    let entityID = UniqueIdentifier(0x0011_2233_4455_6677)
    let appdus: [Appdu] = [
      .nop,
      .entityIDRequest(apcMacAddress: apcMacAddress, entityID: entityID),
      .entityIDResponse(apcMacAddress: apcMacAddress, entityID: entityID),
      .linkStatus(true, linkMacAddress: linkMacAddress),
      .linkStatus(false, linkMacAddress: linkMacAddress),
      .atdeccFromAps(sourceMacAddress: entityMacAddress, avtpdu: makeAvtpdu()),
      .atdeccFromApc(destinationMacAddress: entityMacAddress, avtpdu: makeAvtpdu(subtype: 0xFB)),
      Appdu(messageType: .vendor, address: [0x00, 0x1B, 0x92, 0, 0, 1], payload: [1, 2, 3]),
      Appdu(messageType: .atdeccFromAps, payload: [UInt8](repeating: 0xFC, count: Appdu.maximumPayloadLength)),
    ]
    for appdu in appdus {
      let decoded = try Appdu(bytes: appdu.serialized())
      XCTAssertEqual(decoded.messageType, appdu.messageType)
      XCTAssertEqual(macBytes(decoded.address), macBytes(appdu.address))
      XCTAssertEqual(decoded.payload, appdu.payload)
    }
    XCTAssertEqual(try Appdu(bytes: appdus[1].serialized()).entityID, entityID)
  }

  func testMalformedAppdusAreRefused() {
    let nop = Appdu.nop.serialized()
    XCTAssertThrowsError(try Appdu(bytes: [1] + nop.dropFirst())) { XCTAssertEqual($0 as? AppduError, .unsupportedVersion(1)) }
    XCTAssertThrowsError(try Appdu(bytes: Array(nop.prefix(11)))) { XCTAssertEqual($0 as? AppduError, .truncated) }
    var tooLong = nop
    tooLong[2] = 0x05
    tooLong[3] = 0xDD // 1501
    XCTAssertThrowsError(try Appdu(bytes: tooLong)) { XCTAssertEqual($0 as? AppduError, .payloadTooLong(1501)) }
    let nopWithPayload = Appdu(messageType: .nop, payload: [0]).serialized()
    XCTAssertThrowsError(try Appdu(bytes: nopWithPayload)) {
      XCTAssertEqual($0 as? AppduError, .invalidPayloadLength(.nop, 1))
    }
    let shortRequest = Appdu(messageType: .entityIDRequest, payload: [0, 0, 0, 0, 0, 0, 0]).serialized()
    XCTAssertThrowsError(try Appdu(bytes: shortRequest)) {
      XCTAssertEqual($0 as? AppduError, .invalidPayloadLength(.entityIDRequest, 7))
    }
    var linkUpMissingPayload = Appdu.linkStatus(true, linkMacAddress: linkMacAddress).serialized()
    linkUpMissingPayload[3] = 2
    XCTAssertThrowsError(try Appdu(bytes: linkUpMissingPayload)) { XCTAssertEqual($0 as? AppduError, .truncated) }
  }

  func testStreamDecoderReassemblesAppdusSplitAnywhere() throws {
    let first = Appdu.entityIDRequest(apcMacAddress: apcMacAddress, entityID: UniqueIdentifier(7))
    let second = Appdu.atdeccFromApc(destinationMacAddress: entityMacAddress, avtpdu: makeAvtpdu())
    let stream = first.serialized() + second.serialized()
    for split in 0...stream.count {
      var decoder = AppduStreamDecoder()
      let decoded = try decoder.decode(Array(stream[..<split])) + decoder.decode(Array(stream[split...]))
      XCTAssertEqual(decoded.map(\.messageType), [.entityIDRequest, .atdeccFromApc])
      XCTAssertEqual(decoder.bufferedCount, 0)
    }
  }

  func testStreamDecoderFailsOnAMalformedHeader() {
    var decoder = AppduStreamDecoder()
    XCTAssertThrowsError(try decoder.decode([0x07, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 8)))
  }

  func testOnlyTableC7SubtypesAreAppAvtpdus() {
    XCTAssertTrue(isAppAvtpdu(makeAvtpdu(subtype: 0xFA)))
    XCTAssertTrue(isAppAvtpdu(makeAvtpdu(subtype: 0xFB)))
    XCTAssertTrue(isAppAvtpdu(makeAvtpdu(subtype: 0xFC)))
    XCTAssertFalse(isAppAvtpdu(makeAvtpdu(subtype: 0xFE))) // MAAP
    XCTAssertFalse(isAppAvtpdu(makeAvtpdu(subtype: 0x02))) // AAF stream data
    XCTAssertFalse(isAppAvtpdu([0xFA, 0, 0]))
  }

  func testEthernetPaddingIsTrimmedFromAvtpdus() throws {
    let acmpdu = makeAvtpdu(subtype: 0xFC, controlDataLength: 44)
    XCTAssertEqual(try avtpdu(withoutPaddingFrom: acmpdu + [0, 0, 0]), acmpdu)
    XCTAssertEqual(try avtpdu(withoutPaddingFrom: acmpdu), acmpdu)
    XCTAssertThrowsError(try avtpdu(withoutPaddingFrom: Array(acmpdu.prefix(40))))
    XCTAssertThrowsError(try avtpdu(withoutPaddingFrom: makeAvtpdu(controlDataLength: 1500)))
  }

  func testServiceRecordFollowsTableC2() {
    let record = appServiceTXTRecord(priority: 3, description: String(repeating: "x", count: 80), manufacturer: "PADL")
    XCTAssertEqual(record.map(\.0), ["txtvers", "Version", "Priority", "Description", "Manufacturer", "path", "Mode"])
    XCTAssertEqual(record.map(\.1), ["1", "0", "3", String(repeating: "x", count: 64), "PADL", "/", "0"])
    XCTAssertEqual(AppServiceType, "_avdecc._tcp")
    XCTAssertEqual(AppDefaultPort, 17221)
  }
}

final class AppRequestTests: XCTestCase {
  private func request(_ method: HTTPMethod, _ path: String, version: HTTPVersion = .http11, headers: [HTTPHeader: String] = [:]) -> HTTPRequest {
    HTTPRequest(method: method, version: version, path: path, query: [], headers: headers, body: Data())
  }

  private func upgrade(origin: String? = "https://noodlescontroller.com", path: String = "/ws") -> HTTPRequest {
    var headers: [HTTPHeader: String] = [.host: "brohavn:17221", .upgrade: "websocket", .connection: "Upgrade"]
    if let origin { headers[HTTPHeader("Origin")] = origin }
    return request(.GET, path, headers: headers)
  }

  #if HTTPTunnel
  func testConnectIsAcceptedOnAnyTarget() {
    for path in ["/", "/proxy"] {
      let outcome = appRequestOutcome(on: request(.CONNECT, path), allowedWebSocketOrigins: [])
      XCTAssertEqual(outcome.requestValid, 200)
      XCTAssertEqual(outcome.transport, .connect)
    }
  }
  #else
  /// Without the HTTPTunnel trait the server supports CONNECT for no resource (RFC 9110
  /// Section 15.6.2).
  func testConnectIsRefusedWithoutTheTrait() {
    let outcome = appRequestOutcome(on: request(.CONNECT, "/"), allowedWebSocketOrigins: [])
    XCTAssertEqual(outcome.requestValid, 501)
    XCTAssertNil(outcome.transport)
    XCTAssertEqual(outcome.refusal.headers[HTTPHeader("Allow")], "GET")
  }
  #endif

  func testOtherRequestsAreRefused() {
    XCTAssertEqual(appRequestOutcome(on: request(.GET, "/"), allowedWebSocketOrigins: []).requestValid, 404)
    XCTAssertEqual(appRequestOutcome(on: request(.POST, "/"), allowedWebSocketOrigins: []).requestValid, 404)
    let post = appRequestOutcome(on: request(.POST, "/ws"), allowedWebSocketOrigins: [])
    XCTAssertEqual(post.requestValid, 405)
    XCTAssertEqual(post.refusal.headers[HTTPHeader("Allow")], "GET")
    XCTAssertEqual(post.refusal.statusCode.code, 405)
    let http2 = appRequestOutcome(on: request(.CONNECT, "/", version: HTTPVersion("HTTP/2")), allowedWebSocketOrigins: [])
    XCTAssertEqual(http2.requestValid, 505)
  }

  /// The upgrade the Noodles controller makes: GET /ws from its origin, no subprotocol.
  func testTheNoodlesUpgradeIsAccepted() {
    let outcome = appRequestOutcome(on: upgrade(), allowedWebSocketOrigins: AppNoodlesWebSocketOrigins)
    XCTAssertEqual(outcome.requestValid, 200)
    XCTAssertEqual(outcome.transport, .webSocket)
  }

  func testWebSocketOriginsAreChecked() {
    let allowed = AppNoodlesWebSocketOrigins
    XCTAssertEqual(appRequestOutcome(on: upgrade(origin: "https://evil.example"), allowedWebSocketOrigins: allowed).requestValid, 403)
    XCTAssertEqual(appRequestOutcome(on: upgrade(origin: "http://brohavn:17221"), allowedWebSocketOrigins: []).requestValid, 200)
    XCTAssertEqual(appRequestOutcome(on: upgrade(origin: nil), allowedWebSocketOrigins: []).requestValid, 200)
    XCTAssertEqual(appRequestOutcome(on: upgrade(origin: "https://app.noodlescontroller.com"), allowedWebSocketOrigins: allowed).requestValid, 200)
  }
}
