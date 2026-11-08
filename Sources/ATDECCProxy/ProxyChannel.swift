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

/// Turns the octets an APC sends, after its request, into APPDUs, whichever the transport.
///
/// Over WebSocket each binary message should be one APPDU, but the messages are read as one
/// stream, as the Noodles/Sienda proxy reads them, so an APPDU split across messages or several
/// in one are accepted too. A text message fails the connection.
public struct AppChannelReader: Sendable {
  public enum Item: Sendable {
    case appdu(Appdu)
    /// Octets to send back: a pong.
    case reply([UInt8])
    /// The APC closed the WebSocket; the connection answers with its own close.
    case closed
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    case appdu(AppduError)
    case webSocket(WebSocketError)
    case textMessage

    /// The WebSocket close status to fail the connection with (RFC 6455 Section 7.4.1).
    public var webSocketCloseCode: UInt16 {
      switch self {
      case .textMessage: 1003
      case .webSocket(.messageTooLong): 1009
      case .webSocket: 1002
      case .appdu: 1007
      }
    }
  }

  private let isWebSocket: Bool
  private var appdus = AppduStreamDecoder()
  private var frames = WebSocketFrameDecoder()

  public init(transport: AppTransport) {
    if case .webSocket = transport { isWebSocket = true } else { isWebSocket = false }
  }

  public mutating func read(_ bytes: [UInt8]) throws(Error) -> [Item] {
    guard isWebSocket else { return try decodeAppdus(bytes) }
    let messages: [WebSocketMessage]
    do {
      messages = try frames.decode(bytes)
    } catch {
      throw .webSocket(error)
    }
    var items = [Item]()
    for message in messages {
      switch message {
      case let .binary(payload): items += try decodeAppdus(payload)
      case .text: throw .textMessage
      case let .ping(payload): items.append(.reply(webSocketFrame(.pong, payload)))
      case .pong: break
      case .close: return items + [.closed]
      }
    }
    return items
  }

  private mutating func decodeAppdus(_ bytes: [UInt8]) throws(Error) -> [Item] {
    do {
      return try appdus.decode(bytes).map { .appdu($0) }
    } catch {
      throw .appdu(error)
    }
  }
}
