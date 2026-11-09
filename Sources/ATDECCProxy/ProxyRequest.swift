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

import FlyingFox

// APP over WebSocket is an extension, not part of IEEE 1722.1-2021 Annex C: it lets browser
// controllers reach an APS. It follows the Noodles/Sienda ATDECC proxy: the upgrade is a GET of
// /ws, without a subprotocol, and messages are binary, each one APPDU. The Noodles controller
// opens ws://host:port/ws, so the path may be served on a port that serves other routes too.

/// The request path on which an APS accepts WebSocket upgrades.
public let AppWebSocketPath = "/ws"

/// The route to mount an `AtdeccProxyHandler` on beside other routes: WebSocket upgrades on
/// `AppWebSocketPath`. Mount it before any route that would match that path too.
public let AppWebSocketRoute = HTTPRoute("GET \(AppWebSocketPath)")

/// The largest WebSocket message an APS accepts: a little more than the largest APPDU.
public let AppWebSocketMaximumMessageLength = 4096

/// The origins of the Noodles controller, which the Noodles/Sienda proxy always allows.
public let AppNoodlesWebSocketOrigins = ["noodlescontroller.com", "app.noodlescontroller.com", "noodles-controller.web.app"]

/// Whether this build serves HTTP CONNECT (the HTTPTunnel trait); without it, CONNECT is
/// refused 501 and only WebSocket is served, so there is no Annex C entry point to advertise.
#if HTTPTunnel
public let AppServesConnect = true
#else
public let AppServesConnect = false
#endif

/// How an APC's APPDUs are carried once its request is accepted.
public enum AppTransport: Sendable, Equatable {
  /// A byte stream of APPDUs after HTTP CONNECT (IEEE 1722.1-2021 Clause C.1).
  case connect
  /// One APPDU per binary WebSocket message after an upgrade on `AppWebSocketPath`.
  case webSocket
}

/// The outcome of an APC's HTTP request at the APS: requestValid in IEEE 1722.1-2021 Clause
/// C.5.2.1.14, and the transport if it is accepted (200).
///
/// Over WebSocket the opening handshake (RFC 6455 Section 4) stands in for CONNECT: an upgrade
/// the APS accepts is requestValid == 200, answered 101 by FlyingFox's WebSocket handler; one
/// it refuses is the status it is refused with (400 for a malformed handshake).
public struct AppRequestOutcome: Sendable, Equatable {
  public var requestValid: Int
  public var transport: AppTransport?
  /// Header fields for a refusal, such as Allow for 405.
  public var headers: [String: String]

  /// sendHttpResponse(requestValid) for a refused request (Clause C.5.2.2.6).
  public var refusal: HTTPResponse {
    var response = HTTPResponse(statusCode: HTTPStatusCode(requestValid, phrase: Self.reasonPhrase(requestValid)))
    for (name, value) in headers {
      response.headers[HTTPHeader(name)] = value
    }
    return response
  }

  static func refused(_ status: Int, _ headers: [String: String] = [:]) -> Self {
    Self(requestValid: status, transport: nil, headers: headers)
  }

  /// CONNECT without the HTTPTunnel trait: 501, as the server supports it for no resource
  /// (RFC 9110 Section 15.6.2); Allow names the method it does support, for /ws.
  static let refusedConnect = Self.refused(501, ["Allow": "GET"])

  static func reasonPhrase(_ status: Int) -> String {
    switch status {
    case 400: "Bad Request"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 503: "Service Unavailable"
    case 501: "Not Implemented"
    case 505: "HTTP Version Not Supported"
    default: "Error"
    }
  }
}

/// Decides an APC's request. With the HTTPTunnel trait, CONNECT is accepted on any target, as
/// the Noodles/Sienda proxy does, since the advertised path is "/" (Clause C.3.5); without it,
/// CONNECT is refused 501. A WebSocket upgrade is accepted only on `AppWebSocketPath`, and only
/// from an allowed origin. The handshake itself is FlyingFox's.
public func appRequestOutcome(on request: HTTPRequest, allowedWebSocketOrigins: [String]) -> AppRequestOutcome {
  guard request.version == .http11 || request.version == HTTPVersion("HTTP/1.0") else { return .refused(505) }
  if request.method == .CONNECT {
    #if HTTPTunnel
    return AppRequestOutcome(requestValid: 200, transport: .connect, headers: [:])
    #else
    return .refusedConnect
    #endif
  }
  guard request.path == AppWebSocketPath else { return .refused(404) }
  guard request.method == .GET else { return .refused(405, ["Allow": "GET"]) }
  let origin = request.headers[HTTPHeader("Origin")]
  guard isAllowedWebSocketOrigin(origin, host: request.headers[.host], allowedHosts: allowedWebSocketOrigins) else {
    return .refused(403)
  }
  return AppRequestOutcome(requestValid: 200, transport: .webSocket, headers: [:])
}

/// Whether a WebSocket upgrade from a page at `origin` (its Origin field) is allowed: no Origin
/// (not a browser), a page served by the host the APC reached (`host`, its Host field, compared
/// by host alone, so a page at http://10.10.32.8 may open ws://10.10.32.8:8080/ws as well as
/// ws://10.10.32.8/ws), or one of `allowedHosts`, each a host or host:port.
public func isAllowedWebSocketOrigin(_ origin: String?, host: String?, allowedHosts: [String]) -> Bool {
  guard let origin else { return true }
  guard let schemeEnd = origin.range(of: "://") else { return false }
  let authority = origin[schemeEnd.upperBound...].lowercased()
  let originHost = hostPart(of: authority)
  if let host, originHost == hostPart(of: host.lowercased()) { return true }
  return allowedHosts.contains { $0.lowercased() == authority || $0.lowercased() == originHost }
}

/// The host of an authority, host or host:port, without the port; an IPv6 literal keeps its
/// brackets ("[fe80::1]:8080" is "[fe80::1]").
func hostPart(of authority: String) -> String {
  if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
    return String(authority[...close])
  }
  return authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? authority
}
