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

final class AppHTTPTests: XCTestCase {
  private func head(_ text: String) -> AppHTTPRequestHead {
    AppHTTPRequestHead(bytes: Array(text.utf8))!
  }

  private func webSocketUpgrade(origin: String? = "https://noodlescontroller.com", path: String = "/ws") -> String {
    var text = "GET \(path) HTTP/1.1\r\nHost: brohavn:17221\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    text += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
    if let origin { text += "Origin: \(origin)\r\n" }
    return text + "\r\n"
  }

  func testTheConnectRequestOfClauseC5327IsAccepted() {
    let request = appConnectRequest(host: "brohavn", port: 17221)
    XCTAssertEqual(String(decoding: request.serialized(), as: UTF8.self), "CONNECT / HTTP/1.1\r\nHost: brohavn:17221\r\n\r\n")
    let parsed = AppHTTPRequestHead(bytes: request.serialized())
    XCTAssertEqual(parsed, request)
    let verdict = appVerdict(on: request, allowedWebSocketOrigins: [])
    XCTAssertEqual(verdict.requestValid, 200)
    XCTAssertEqual(String(decoding: verdict.response, as: UTF8.self), "HTTP/1.1 200 OK\r\n\r\n")
  }

  func testRequestHeadEndIsFound() {
    let bytes = Array("CONNECT / HTTP/1.1\r\nHost: a:1\r\n\r\n".utf8) + [0x00, 0x01]
    XCTAssertEqual(AppHTTPRequestHead.endOfHead(in: bytes), bytes.count - 2)
    XCTAssertNil(AppHTTPRequestHead.endOfHead(in: Array("CONNECT / HTTP/1.1\r\n".utf8)))
    XCTAssertNil(AppHTTPRequestHead(bytes: Array("NONSENSE\r\n\r\n".utf8)))
    XCTAssertNil(AppHTTPRequestHead(bytes: Array("GET / HTTP/1.1\r\nno colon\r\n\r\n".utf8)))
  }

  func testOtherRequestsAreRefused() {
    XCTAssertEqual(appVerdict(on: head("GET / HTTP/1.1\r\n\r\n"), allowedWebSocketOrigins: []).requestValid, 404)
    let post = appVerdict(on: head("POST /ws HTTP/1.1\r\n\r\n"), allowedWebSocketOrigins: [])
    XCTAssertEqual(post.requestValid, 405)
    XCTAssertTrue(String(decoding: post.response, as: UTF8.self).contains("\r\nAllow: GET\r\n"))
    XCTAssertEqual(appVerdict(on: head("POST / HTTP/1.1\r\n\r\n"), allowedWebSocketOrigins: []).requestValid, 404)
    XCTAssertEqual(appVerdict(on: head("CONNECT / HTTP/2.0\r\n\r\n"), allowedWebSocketOrigins: []).requestValid, 505)
    XCTAssertEqual(appVerdict(on: head("GET /ws HTTP/1.1\r\n\r\n"), allowedWebSocketOrigins: []).requestValid, 426)
    let refusal = String(decoding: appVerdict(on: head("GET / HTTP/1.1\r\n\r\n"), allowedWebSocketOrigins: []).response, as: UTF8.self)
    XCTAssertEqual(refusal, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
  }

  /// The upgrade the Noodles controller makes: GET /ws, no subprotocol, from its origin.
  func testTheNoodlesUpgradeIsAcceptedWithTheRFC6455AcceptValue() {
    let verdict = appVerdict(on: head(webSocketUpgrade()), allowedWebSocketOrigins: AppNoodlesWebSocketOrigins)
    XCTAssertEqual(verdict.requestValid, 200)
    XCTAssertEqual(verdict.transport, .webSocket(key: "dGhlIHNhbXBsZSBub25jZQ=="))
    let response = String(decoding: verdict.response, as: UTF8.self)
    XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
    XCTAssertTrue(response.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
    XCTAssertFalse(response.contains("Sec-WebSocket-Protocol"))
  }

  func testWebSocketOriginsAreChecked() {
    let allowed = AppNoodlesWebSocketOrigins
    XCTAssertEqual(appVerdict(on: head(webSocketUpgrade(origin: "https://evil.example")), allowedWebSocketOrigins: allowed).requestValid, 403)
    XCTAssertEqual(appVerdict(on: head(webSocketUpgrade(origin: "http://brohavn:17221")), allowedWebSocketOrigins: []).requestValid, 200)
    XCTAssertEqual(appVerdict(on: head(webSocketUpgrade(origin: nil)), allowedWebSocketOrigins: []).requestValid, 200)
    XCTAssertEqual(appVerdict(on: head(webSocketUpgrade(origin: "https://app.noodlescontroller.com")), allowedWebSocketOrigins: allowed).requestValid, 200)
    XCTAssertEqual(appVerdict(on: head(webSocketUpgrade(path: "/ws?x=1")), allowedWebSocketOrigins: allowed).requestValid, 200)
  }

  func testSHA1AndBase64MatchTheirTestVectors() {
    XCTAssertEqual(base64Encode(sha1(Array("abc".utf8))), "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=")
    XCTAssertEqual(base64Encode(sha1([])), "2jmj7l5rSw0yVb/vlWAYkK/YBwk=")
    XCTAssertEqual(base64Encode(Array("fo".utf8)), "Zm8=")
    XCTAssertEqual(base64Encode(Array("f".utf8)), "Zg==")
  }
}

final class WebSocketFrameTests: XCTestCase {
  private let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]

  func testMaskedFramesFromRFC6455Section572Decode() throws {
    var decoder = WebSocketFrameDecoder()
    // a masked "Hello"
    let messages = try decoder.decode([0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58])
    XCTAssertEqual(messages, [.text(Array("Hello".utf8))])
    XCTAssertEqual(webSocketFrame(.text, Array("Hello".utf8), maskingKey: mask), [0x81, 0x85] + mask + [0x7F, 0x9F, 0x4D, 0x51, 0x58])
    XCTAssertEqual(webSocketFrame(.text, Array("Hello".utf8)), [0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F])
  }

  func testFragmentsAndInterleavedControlFramesAreAssembled() throws {
    var decoder = WebSocketFrameDecoder()
    let first = webSocketFrame(.binary, [1, 2], maskingKey: mask)
    var firstUnfinished = first
    firstUnfinished[0] &= 0x7F
    var last = webSocketFrame(.continuation, [3], maskingKey: mask)
    last[0] = 0x80
    let ping = webSocketFrame(.ping, [9], maskingKey: mask)
    let stream = firstUnfinished + ping + last
    var messages = [WebSocketMessage]()
    for byte in stream {
      messages += try decoder.decode([byte])
    }
    XCTAssertEqual(messages, [.ping([9]), .binary([1, 2, 3])])
  }

  func testExtendedLengthsDecode() throws {
    var decoder = WebSocketFrameDecoder()
    let payload = [UInt8](repeating: 0xAB, count: 1512)
    XCTAssertEqual(try decoder.decode(webSocketFrame(.binary, payload, maskingKey: mask)), [.binary(payload)])
  }

  func testUnmaskedAndOversizedClientFramesAreRefused() {
    var decoder = WebSocketFrameDecoder()
    XCTAssertThrowsError(try decoder.decode(webSocketFrame(.binary, [1]))) {
      XCTAssertEqual($0 as? WebSocketError, .unmaskedClientFrame)
    }
    var other = WebSocketFrameDecoder()
    let huge = webSocketFrame(.binary, [UInt8](repeating: 0, count: AppWebSocketMaximumMessageLength + 1), maskingKey: mask)
    XCTAssertThrowsError(try other.decode(huge)) { XCTAssertEqual($0 as? WebSocketError, .messageTooLong) }
  }

  func testChannelReaderReadsOneAppduPerMessageAndAcceptsSplits() throws {
    var reader = AppChannelReader(transport: .webSocket(key: "k"))
    let request = Appdu.entityIDRequest(apcMacAddress: apcMacAddress, entityID: UniqueIdentifier()).serialized()
    let whole = webSocketFrame(.binary, request, maskingKey: mask)
    let split = webSocketFrame(.binary, Array(request.prefix(5)), maskingKey: mask) +
      webSocketFrame(.binary, Array(request.dropFirst(5)), maskingKey: mask)
    for bytes in [whole, split] {
      let items = try reader.read(bytes)
      XCTAssertEqual(items.count, 1)
      guard case let .appdu(appdu) = items.first else { return XCTFail("no APPDU") }
      XCTAssertEqual(appdu.messageType, .entityIDRequest)
    }
    let pingItems = try reader.read(webSocketFrame(.ping, [7], maskingKey: mask))
    guard case let .reply(pong) = pingItems.first else { return XCTFail("no pong") }
    XCTAssertEqual(pong, [0x8A, 0x01, 0x07])
    // a close is answered by the connection, once, not by the reader
    let closeItems = try reader.read(webSocketFrame(.close, [0x03, 0xE8], maskingKey: mask))
    XCTAssertEqual(closeItems.count, 1)
    guard case .closed = closeItems.first else { return XCTFail("no close") }
    var other = AppChannelReader(transport: .webSocket(key: "k"))
    XCTAssertThrowsError(try other.read(webSocketFrame(.text, [0x41], maskingKey: mask))) {
      XCTAssertEqual(($0 as? AppChannelReader.Error)?.webSocketCloseCode, 1003)
    }
  }
}
