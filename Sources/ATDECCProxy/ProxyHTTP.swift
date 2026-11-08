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

/// The longest HTTP request head an APS reads before refusing the request.
public let AppMaximumRequestHeadLength = 8192

/// An HTTP/1.x request head (RFC 7230 Section 3): the request line and header fields.
public struct AppHTTPRequestHead: Sendable, Equatable {
  public var method: String
  public var target: String
  public var version: String
  /// Header fields in order, names as received.
  public var headers: [(name: String, value: String)]

  public init(method: String, target: String, version: String, headers: [(name: String, value: String)] = []) {
    self.method = method
    self.target = target
    self.version = version
    self.headers = headers
  }

  /// The first value of the header field `name`, compared without regard to case.
  public func header(_ name: String) -> String? {
    let name = name.lowercased()
    return headers.first { $0.name.lowercased() == name }?.value
  }

  /// Whether the comma-separated header field `name` holds `token`, compared without case.
  public func header(_ name: String, containsToken token: String) -> Bool {
    let token = token.lowercased()
    return headers.contains { field in
      field.name.lowercased() == name.lowercased() &&
        field.value.split(separator: ",").contains { $0.trimmingWhitespace().lowercased() == token }
    }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.method == rhs.method && lhs.target == rhs.target && lhs.version == rhs.version &&
      lhs.headers.map(\.name) == rhs.headers.map(\.name) && lhs.headers.map(\.value) == rhs.headers.map(\.value)
  }

  /// The index just past the blank line ending the head in `bytes`, or nil if it has not
  /// all arrived.
  public static func endOfHead(in bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else { return nil }
    for i in 0...(bytes.count - 4)
      where bytes[i] == 0x0D && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A
    {
      return i + 4
    }
    return nil
  }

  /// Parses a head, without its trailing blank line or with it; nil if it is malformed.
  public init?(bytes: some Collection<UInt8>) {
    guard let text = String(validating: Array(bytes), as: UTF8.self) else { return nil }
    var lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
    while lines.last == "" {
      lines.removeLast()
    }
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, parts[2].hasPrefix("HTTP/") else { return nil }
    var headers = [(name: String, value: String)]()
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
      let name = String(line[..<colon])
      guard !name.contains(" ") else { return nil }
      headers.append((name, String(line[line.index(after: colon)...].trimmingWhitespace())))
    }
    self.init(method: String(parts[0]), target: String(parts[1]), version: String(parts[2]), headers: headers)
  }

  /// The head's octets, ending with the blank line.
  public func serialized() -> [UInt8] {
    var text = "\(method) \(target) \(version)\r\n"
    for (name, value) in headers {
      text += "\(name): \(value)\r\n"
    }
    text += "\r\n"
    return Array(text.utf8)
  }
}

/// The reason phrase for the status codes an APS sends (RFC 7231 Section 6.1, RFC 6455).
public func appHTTPReasonPhrase(_ status: Int) -> String {
  switch status {
  case 101: "Switching Protocols"
  case 200: "OK"
  case 400: "Bad Request"
  case 403: "Forbidden"
  case 404: "Not Found"
  case 405: "Method Not Allowed"
  case 426: "Upgrade Required"
  case 503: "Service Unavailable"
  case 505: "HTTP Version Not Supported"
  default: "Error"
  }
}

/// An HTTP response head: the status line, `headers`, then a blank line (Clause C.5.2.2.6).
public func appHTTPResponse(status: Int, headers: [(String, String)] = []) -> [UInt8] {
  var text = "HTTP/1.1 \(status) \(appHTTPReasonPhrase(status))\r\n"
  for (name, value) in headers {
    text += "\(name): \(value)\r\n"
  }
  text += "\r\n"
  return Array(text.utf8)
}

/// The HTTP CONNECT request an APC sends (IEEE 1722.1-2021 Clause C.5.3.2.7).
public func appConnectRequest(host: String, port: UInt16, path: String = "/") -> AppHTTPRequestHead {
  AppHTTPRequestHead(method: "CONNECT", target: path, version: "HTTP/1.1", headers: [("Host", "\(host):\(port)")])
}

extension Substring {
  func trimmingWhitespace() -> Substring {
    guard let first = firstIndex(where: { $0 != " " && $0 != "\t" }) else { return self[endIndex...] }
    let last = lastIndex(where: { $0 != " " && $0 != "\t" })!
    return self[first...last]
  }
}
