//
// Copyright (c) 2023-2026 PADL Software Pty Ltd
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

// Status codes 0..<256 are carried on the wire; the 99x range is library-local and reports
// failures that never reached, or never came back from, the remote entity. The library codes
// match the library-local codes of la_avdecc.

/// AEM status code (IEEE 1722.1-2021 Table 7-141), extended with library-local failures.
public enum AemStatus: UInt16, Error {
  case success = 0
  case notImplemented = 1
  case noSuchDescriptor = 2
  case lockedByOther = 3
  case acquiredByOther = 4
  case notAuthenticated = 5
  case authenticationDisabled = 6
  case badArguments = 7
  case noResources = 8
  case inProgress = 9
  case entityMisbehaving = 10
  case notSupported = 11
  case streamIsRunning = 12
  case networkError = 995
  case protocolError = 996
  case timedOut = 997
  case unknownEntity = 998
  case internalError = 999

  /// Lossy init: unknown `raw` values collapse to `.internalError` so callers always get a
  /// usable error rather than nil. Use `init(rawValue:)` to distinguish "unknown value" from
  /// the catch-all internal-error case.
  public init(_ raw: UInt16) {
    self = Self(rawValue: raw) ?? .internalError
  }
}

/// ACMP status code (IEEE 1722.1-2021 Table 8-3), extended with library-local failures.
public enum AcmpStatus: UInt16, Error {
  case success = 0
  case listenerUnknownID = 1
  case talkerUnknownID = 2
  case talkerDestMacFail = 3
  case talkerNoStreamIndex = 4
  case talkerNoBandwidth = 5
  case talkerExclusive = 6
  case listenerTalkerTimeout = 7
  case listenerExclusive = 8
  case stateUnavailable = 9
  case notConnected = 10
  case noSuchConnection = 11
  case couldNotSendMessage = 12
  case talkerMisbehaving = 13
  case listenerMisbehaving = 14
  case controllerNotAuthorized = 16
  case incompatibleRequest = 17
  case notSupported = 31
  case baseProtocolViolation = 991
  case networkError = 995
  case protocolError = 996
  case timedOut = 997
  case unknownEntity = 998
  case internalError = 999

  public init(_ raw: UInt16) {
    self = Self(rawValue: raw) ?? .internalError
  }
}

/// Milan AECP-MVU status code (Milan 1.3 §5.3.5). Codes 0..10 overlap with AEM; the
/// library-local codes (99x) match across all three status enums.
public enum MvuStatus: UInt16, Error {
  case success = 0
  case notImplemented = 1
  case noSuchDescriptor = 2
  case entityLocked = 3
  case badArguments = 7
  case entityMisbehaving = 10
  case payloadTooShort = 13
  case baseProtocolViolation = 991
  case partialImplementation = 992
  case busy = 993
  case networkError = 995
  case protocolError = 996
  case timedOut = 997
  case unknownEntity = 998
  case internalError = 999

  public init(_ raw: UInt16) {
    self = Self(rawValue: raw) ?? .internalError
  }
}

@available(*, deprecated, renamed: "AemStatus")
public typealias LocalEntityAemCommandStatus = AemStatus

@available(*, deprecated, renamed: "AcmpStatus")
public typealias LocalEntityControlStatus = AcmpStatus

@available(*, deprecated, renamed: "MvuStatus")
public typealias LocalEntityMvuCommandStatus = MvuStatus
