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

/// A command line that cannot be run; exits with status 2.
public struct UsageError: Error, Equatable, CustomStringConvertible {
  public let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// A stream's direction, naming STREAM_INPUT or STREAM_OUTPUT.
public enum Direction: String, Sendable, Equatable {
  case input
  case output

  var descriptorType: DescriptorType {
    self == .input ? .streamInput : .streamOutput
  }
}

/// The options every command takes.
public struct Options: Sendable, Equatable {
  /// `eth0`, `unix:/path` or `/dev/tty…[@baud]`.
  public var port: String?
  /// Bounds the whole command, discovery of its entity included.
  public var timeout: Duration = .seconds(5)
  public var json = false
  public var verbose = false
  /// The controller's entity ID, by default the port's MAC address followed by
  /// `controllerProgramID`,
  /// so that successive invocations are the same controller to an entity they acquired.
  public var controllerID: UniqueIdentifier?

  public init() {}
}

/// The lower 16 bits of the default controller entity ID.
public let controllerProgramID: UInt16 = 0xC71D

/// A subcommand and its arguments.
public enum Command: Sendable, Equatable {
  case help
  case discover(seconds: Duration)
  case dump(UniqueIdentifier)
  case streamInfo(UniqueIdentifier, Direction, UInt16)
  case setFormat(UniqueIdentifier, Direction, UInt16, StreamFormat, acquire: Bool, lock: Bool)
  case startStreaming(UniqueIdentifier, Direction, UInt16)
  case stopStreaming(UniqueIdentifier, Direction, UInt16)
  case counters(UniqueIdentifier, DescriptorType, UInt16)
  /// Every CLOCK_DOMAIN of the current configuration, or the one given.
  case clockSources(UniqueIdentifier, clockDomain: UInt16?)
  case setClockSource(
    UniqueIdentifier,
    clockDomain: UInt16,
    clockSource: UInt16,
    acquire: Bool,
    lock: Bool
  )
  case connect(listener: StreamIdentification, talker: StreamIdentification)
  /// With no talker, the listener's GET_RX_STATE names it.
  case disconnect(listener: StreamIdentification, talker: StreamIdentification?)
  case rxState(StreamIdentification)
  case txState(StreamIdentification)
  case acquire(UniqueIdentifier, persistent: Bool)
  case release(UniqueIdentifier)
  case lock(UniqueIdentifier)
  case unlock(UniqueIdentifier)
  case identify(UniqueIdentifier, on: Bool)
}

/// A parsed command line.
public struct Invocation: Sendable, Equatable {
  public var options: Options
  public var command: Command

  public init(options: Options = Options(), command: Command) {
    self.options = options
    self.command = command
  }

  /// Parses the arguments after the program name. Options may come before or after the
  /// subcommand; `--name=value` and `--name value` are equivalent.
  public init(parsing arguments: [String]) throws(UsageError) {
    var options = Options()
    var flags = Set<String>()
    var values = [String: String]()
    var positional = [String]()
    let valueOptions: Set = ["--port", "--timeout", "--controller-id", "--seconds"]
    let flagOptions: Set = [
      "--json",
      "--verbose",
      "--help",
      "--acquire",
      "--lock",
      "--persistent",
      "--off",
    ]
    let shortOptions = ["-p": "--port", "-t": "--timeout", "-v": "--verbose", "-h": "--help"]

    var index = 0
    while index < arguments.count {
      var argument = arguments[index]
      index += 1
      if argument == "--" {
        positional += arguments[index...]
        break
      }
      if let long = shortOptions[argument] { argument = long }
      guard argument.hasPrefix("--") else {
        positional.append(argument)
        continue
      }
      var name = argument
      var value: String?
      if let equals = argument.firstIndex(of: "=") {
        name = String(argument[..<equals])
        value = String(argument[argument.index(after: equals)...])
      }
      if valueOptions.contains(name) {
        if value == nil {
          guard index < arguments.count else { throw UsageError("\(name) needs a value") }
          value = arguments[index]
          index += 1
        }
        values[name] = value
      } else if flagOptions.contains(name), value == nil {
        flags.insert(name)
      } else {
        throw UsageError("unknown option '\(argument)'")
      }
    }

    options.port = values["--port"]
    if let timeout = values["--timeout"] {
      options.timeout = try parseSeconds(timeout, option: "--timeout")
    }
    if let controllerID = values["--controller-id"] {
      options.controllerID = try parseEntityID(controllerID)
    }
    options.json = flags.contains("--json")
    options.verbose = flags.contains("--verbose")
    self.options = options

    guard !flags.contains("--help"), let name = positional.first, name != "help" else {
      command = .help
      return
    }
    var arguments = Arguments(command: name, values: Array(positional.dropFirst()))
    var allowed: Set<String> = []
    switch name {
    case "discover":
      allowed = ["--seconds"]
      var seconds = Duration.seconds(3)
      if let text = values["--seconds"] {
        seconds = try parseSeconds(text, option: "--seconds")
      }
      command = .discover(seconds: seconds)
    case "dump":
      command = try .dump(arguments.entityID())
    case "stream-info":
      command = try .streamInfo(arguments.entityID(), arguments.direction(), arguments.index())
    case "set-format":
      allowed = ["--acquire", "--lock"]
      command = try .setFormat(
        arguments.entityID(), arguments.direction(), arguments.index(),
        parseStreamFormat(arguments.next("format")),
        acquire: flags.contains("--acquire"), lock: flags.contains("--lock")
      )
    case "start":
      command = try .startStreaming(arguments.entityID(), arguments.direction(), arguments.index())
    case "stop":
      command = try .stopStreaming(arguments.entityID(), arguments.direction(), arguments.index())
    case "counters":
      command = try .counters(
        arguments.entityID(),
        parseDescriptorType(arguments.next("descriptor type")),
        arguments.index()
      )
    case "clock-sources":
      command = try .clockSources(
        arguments.entityID(),
        clockDomain: arguments.isEmpty ? nil : arguments.index()
      )
    case "set-clock-source":
      allowed = ["--acquire", "--lock"]
      command = try .setClockSource(
        arguments.entityID(),
        clockDomain: arguments.index(),
        clockSource: arguments.index(),
        acquire: flags.contains("--acquire"),
        lock: flags.contains("--lock")
      )
    case "connect":
      command = try .connect(
        listener: arguments.stream("listener"),
        talker: arguments.stream("talker")
      )
    case "disconnect":
      let listener = try arguments.stream("listener")
      command = try .disconnect(
        listener: listener,
        talker: arguments.isEmpty ? nil : arguments.stream("talker")
      )
    case "rx-state":
      command = try .rxState(arguments.stream("listener"))
    case "tx-state":
      command = try .txState(arguments.stream("talker"))
    case "acquire":
      allowed = ["--persistent"]
      command = try .acquire(arguments.entityID(), persistent: flags.contains("--persistent"))
    case "release":
      command = try .release(arguments.entityID())
    case "lock":
      command = try .lock(arguments.entityID())
    case "unlock":
      command = try .unlock(arguments.entityID())
    case "identify":
      allowed = ["--off"]
      command = try .identify(arguments.entityID(), on: !flags.contains("--off"))
    default:
      throw UsageError("unknown command '\(name)'")
    }
    try arguments.finish()
    let commandOptions: Set = ["--seconds", "--acquire", "--lock", "--persistent", "--off"]
    if let misplaced = flags.union(values.keys).intersection(commandOptions).subtracting(allowed)
      .sorted().first
    {
      throw UsageError("\(misplaced) does not apply to \(name)")
    }
  }
}

/// A subcommand's positional arguments, consumed in order.
private struct Arguments {
  let command: String
  var values: [String]

  var isEmpty: Bool {
    values.isEmpty
  }

  mutating func next(_ what: String) throws(UsageError) -> String {
    guard !values.isEmpty else { throw UsageError("\(command) needs a \(what)") }
    return values.removeFirst()
  }

  mutating func entityID() throws(UsageError) -> UniqueIdentifier {
    try parseEntityID(next("entity ID"))
  }

  mutating func direction() throws(UsageError) -> Direction {
    let text = try next("direction (input or output)")
    guard let direction = Direction(rawValue: text.lowercased()) else {
      throw UsageError("'\(text)' is not input or output")
    }
    return direction
  }

  mutating func index() throws(UsageError) -> UInt16 {
    try parseIndex(next("descriptor index"))
  }

  mutating func stream(_ role: String) throws(UsageError) -> StreamIdentification {
    let entityID = try parseEntityID(next("\(role) entity ID"))
    return try StreamIdentification(
      entityID: entityID,
      streamIndex: parseIndex(next("\(role) stream index"))
    )
  }

  func finish() throws(UsageError) {
    guard values.isEmpty
    else { throw UsageError("unexpected argument '\(values[0])' to \(command)") }
  }
}

/// An entity ID as 16 hex digits, optionally separated by `:` or `-`, or as `0x` and up to 16
/// hex digits.
public func parseEntityID(_ text: String) throws(UsageError) -> UniqueIdentifier {
  let compact = text.hasPrefix("0x") || text.hasPrefix("0X")
    ? text : text.filter { $0 != ":" && $0 != "-" }
  guard let value = parseHex64(compact) else {
    throw UsageError("'\(text)' is not an entity ID (16 hex digits, or 0x…)")
  }
  return UniqueIdentifier(value)
}

/// A descriptor index, in decimal or `0x` hex.
func parseIndex(_ text: String) throws(UsageError) -> UInt16 {
  let value = text.hasPrefix("0x") ? UInt16(text.dropFirst(2), radix: 16) : UInt16(text)
  guard let value else { throw UsageError("'\(text)' is not a descriptor index") }
  return value
}

/// A descriptor type by name (`stream-input`, `STREAM_INPUT`, `streamInput`, or `input` and
/// `output` for streams) or number.
func parseDescriptorType(_ text: String) throws(UsageError) -> DescriptorType {
  let normalized = text.lowercased().filter { $0 != "-" && $0 != "_" }
  switch normalized {
  case "input": return .streamInput
  case "output": return .streamOutput
  default: break
  }
  if let value = text.hasPrefix("0x") ? UInt16(text.dropFirst(2), radix: 16) : UInt16(text) {
    return DescriptorType(rawValue: value)
  }
  for rawValue in UInt16(0)...0x28 {
    let type = DescriptorType(rawValue: rawValue)
    if type.description.lowercased() == normalized { return type }
  }
  throw UsageError("'\(text)' is not a descriptor type")
}

/// Seconds, possibly fractional, as a duration.
func parseSeconds(_ text: String, option: String) throws(UsageError) -> Duration {
  guard let seconds = Double(text), seconds > 0, seconds < 86400 else {
    throw UsageError("\(option) takes a number of seconds, not '\(text)'")
  }
  return .milliseconds(Int((seconds * 1000).rounded()))
}

public let usage = """
usage: avdecc-ctl --port <iface|unix:path|/dev/tty…[@baud]> [options] <command> [arguments]

An ATDECC (IEEE 1722.1-2021, Milan) controller for the command line. An Ethernet interface
needs CAP_NET_RAW; a Unix domain socket reaches only the entity on this host.

Commands:
  discover [--seconds N]                       list the entities heard in N seconds (default 3)
  dump <entity>                                the current configuration's descriptors
  stream-info <entity> input|output <index>    GET_STREAM_INFO
  set-format <entity> input|output <index> <format> [--acquire] [--lock]
                                               SET_STREAM_FORMAT, acquiring or locking the
                                               entity around it if asked
  start|stop <entity> input|output <index>     START_STREAMING / STOP_STREAMING
  counters <entity> <descriptor type> <index>  GET_COUNTERS (entity, avb-interface,
                                               clock-domain, input, output, ptp-port)
  clock-sources <entity> [<clock domain>]      the CLOCK_DOMAINs, each with its CLOCK_SOURCEs
                                               and the current one (GET_CLOCK_SOURCE)
  set-clock-source <entity> <clock domain> <clock source> [--acquire] [--lock]
                                               SET_CLOCK_SOURCE, acquiring or locking the
                                               entity around it if asked
  connect <listener> <index> <talker> <index>  ACMP CONNECT_RX
  disconnect <listener> <index> [<talker> <index>]
                                               ACMP DISCONNECT_RX; the talker defaults to the
                                               one GET_RX_STATE reports
  rx-state <listener> <index>                  ACMP GET_RX_STATE
  tx-state <talker> <index>                    ACMP GET_TX_STATE and the talker's connections
  acquire <entity> [--persistent] | release <entity>
  lock <entity> | unlock <entity>
  identify <entity> [--off]                    set the entity's IDENTIFY control

Options:
  -p, --port <port>          eth0, unix:/run/mediabridge/atdecc.sock, or /dev/ttyAMA0@115200
  -t, --timeout <seconds>    bound on the whole command, discovery included (default 5)
  --json                     print JSON rather than text
  --controller-id <id>       this controller's entity ID (default: the port's MAC address
                             followed by c71d, the same in every invocation)
  -v, --verbose              log the protocol
  -h, --help

Entities are 16 hex digits or 0x…; formats are hex (0x0205022000806000) or a spec:
  aaf,48k,int32/24,8ch,6spf[,ut]   crf,48k[,interval=96,tpp=1]   iec61883-6,48k,8ch[,ut]

Exit status: 0 success, 1 the entity answered with a failure status (printed), 2 a usage
error, a timeout, or a port that could not be opened.

Examples:
  avdecc-ctl -p enp8s0 discover
  avdecc-ctl -p unix:/run/mediabridge/atdecc.sock dump 0x8c1f64fffee89001
  avdecc-ctl -p enp8s0 stream-info 0x8c1f64fffee89037 input 1
  avdecc-ctl -p enp8s0 set-format 0x0001f2fffefed2a4 output 0 aaf,48k,int32/24,8ch,6spf --acquire
  avdecc-ctl -p enp8s0 connect 0x8c1f64fffee89037 1 0x8c1f64fffee89001 0
  avdecc-ctl -p enp8s0 counters 0x8c1f64fffee89037 input 0
  avdecc-ctl -p enp8s0 clock-sources 0x0001f2fffefed2a4
  avdecc-ctl -p enp8s0 set-clock-source 0x0001f2fffefed2a4 0 1 --acquire
"""
