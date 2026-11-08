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

/// How an APC's APPDUs are carried once its request is accepted.
public enum AppTransport: Sendable, Equatable {
  /// A byte stream of APPDUs after HTTP CONNECT (IEEE 1722.1-2021 Clause C.1).
  case connect
  /// One APPDU per binary WebSocket message after an upgrade (an extension; see
  /// `AppWebSocketPath`), with the client's Sec-WebSocket-Key.
  case webSocket(key: String)
}

/// The APS's verdict on an APC's HTTP request: requestValid in IEEE 1722.1-2021 Clause
/// C.5.2.1.14, the transport if it is accepted (200), and the response to send.
///
/// Over WebSocket the opening handshake (RFC 6455 Section 4) stands in for CONNECT: an upgrade
/// the APS accepts is requestValid == 200, answered 101 rather than 200; one it refuses is the
/// status it is refused with.
public struct AppRequestVerdict: Sendable, Equatable {
  public var requestValid: Int
  public var transport: AppTransport?
  public var extraHeaders: [String]

  /// The response head for `requestValid` (Clause C.5.2.2.6), or the handshake's 101.
  public var response: [UInt8] {
    switch transport {
    case .connect:
      return appHTTPResponse(status: 200)
    case let .webSocket(key):
      return appHTTPResponse(status: 101, headers: [
        ("Upgrade", "websocket"),
        ("Connection", "Upgrade"),
        ("Sec-WebSocket-Accept", webSocketAcceptValue(forKey: key)),
      ])
    case nil:
      let headers = extraHeaders.compactMap { line -> (String, String)? in
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return (String(line[..<colon]), String(line[line.index(after: colon)...].dropFirst()))
      }
      return appHTTPResponse(status: requestValid, headers: headers + [("Content-Length", "0")])
    }
  }

  static func refused(_ status: Int, _ extraHeaders: [String] = []) -> Self {
    Self(requestValid: status, transport: nil, extraHeaders: extraHeaders)
  }
}

/// Decides an APC's request. CONNECT is accepted on any target, as the Noodles/Sienda proxy
/// does, since the advertised path is "/" (Clause C.3.5); a WebSocket upgrade only on
/// `AppWebSocketPath`, and only from an allowed origin.
public func appVerdict(on head: AppHTTPRequestHead, allowedWebSocketOrigins: [String]) -> AppRequestVerdict {
  guard head.version == "HTTP/1.1" || head.version == "HTTP/1.0" else { return .refused(505) }
  if head.method == "CONNECT" {
    return AppRequestVerdict(requestValid: 200, transport: .connect, extraHeaders: [])
  }
  let path = head.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.target
  guard path == AppWebSocketPath else { return .refused(head.method == "GET" ? 404 : 405) }
  guard head.method == "GET" else { return .refused(405) }
  return webSocketVerdict(on: head, allowedOrigins: allowedWebSocketOrigins)
}

private func webSocketVerdict(on head: AppHTTPRequestHead, allowedOrigins: [String]) -> AppRequestVerdict {
  guard head.header("Upgrade", containsToken: "websocket"), head.header("Connection", containsToken: "upgrade"),
        let key = head.header("Sec-WebSocket-Key"), !key.isEmpty
  else {
    return .refused(426, ["Upgrade: websocket"])
  }
  guard head.header("Sec-WebSocket-Version") == "13" else {
    return .refused(426, ["Sec-WebSocket-Version: 13"])
  }
  guard isAllowedWebSocketOrigin(head.header("Origin"), host: head.header("Host"), allowedHosts: allowedOrigins) else {
    return .refused(403)
  }
  return AppRequestVerdict(requestValid: 200, transport: .webSocket(key: key), extraHeaders: [])
}
