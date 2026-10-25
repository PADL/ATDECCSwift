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
import Logging

/// avdecc-ctl: an ATDECC controller for the command line.
public enum AvdeccCtl {
  /// Parses `arguments` (without the program name), opens the port they name and runs the
  /// command, returning the exit status.
  public static func main(
    arguments: [String],
    output: some OutputSink = StandardOutput(),
    logger: Logger
  ) async -> Int32 {
    let invocation: Invocation
    do {
      invocation = try Invocation(parsing: arguments)
    } catch {
      output.error("avdecc-ctl: \(error)")
      output.error("Try 'avdecc-ctl --help'.")
      return 2
    }
    if invocation.command == .help {
      output.write(usage)
      return 0
    }
    guard let name = invocation.options.port else {
      output.error("avdecc-ctl: --port is required (an interface such as enp8s0, or unix:/path)")
      return 2
    }

    #if os(Linux)
    do {
      if name.hasPrefix("unix:") {
        return try await run(
          invocation,
          on: UnixSocketPort(path: String(name.dropFirst("unix:".count))),
          output: output,
          logger: logger
        )
      } else if name.hasPrefix("/") {
        let components = name.split(separator: "@", maxSplits: 1)
        guard let baudRate = components.count == 2 ? Int(components[1]) : 115_200 else {
          output.error("avdecc-ctl: invalid baud rate in \(name)")
          return 2
        }
        return try await run(
          invocation,
          on: SerialPort(path: String(components[0]), baudRate: baudRate),
          output: output,
          logger: logger
        )
      } else {
        return try await run(
          invocation,
          on: EthernetPort(interfaceName: name),
          output: output,
          logger: logger
        )
      }
    } catch {
      output.error("avdecc-ctl: cannot open \(name): \(error)")
      return 2
    }
    #else
    output.error("avdecc-ctl: the Ethernet, serial and Unix socket ports need Linux")
    return 2
    #endif
  }

  /// Runs `invocation`'s command on `port`, printing its result to `output`, and returns the
  /// exit status.
  public static func run<Port: NetworkPort>(
    _ invocation: Invocation,
    on port: Port,
    output: some OutputSink,
    logger: Logger
  ) async -> Int32 {
    let endStation = EndStation(port: port, logger: logger)
    let controllerID = invocation.options.controllerID ??
      UniqueIdentifier(UInt64(eui48: port.macAddress) << 16 | UInt64(controllerProgramID))
    let controller: Controller<Port>
    do {
      controller = try await Controller(
        endStation: endStation,
        entityID: controllerID,
        logger: logger
      )
    } catch {
      output.error("avdecc-ctl: cannot start a controller: \(error)")
      await endStation.close()
      return 2
    }

    let session = Session(controller: controller, options: invocation.options)
    let command = invocation.command
    let exitStatus: Int32
    do {
      let report = if case .discover = command {
        // the discovery window, then name reads that are each bounded by the timeout
        try await session.run(command)
      } else {
        try await withDeadline(invocation.options.timeout) { try await session.run(command) }
      }
      if invocation.options.json {
        if case .discover = command {
          output.write(renderJSON(report.records, single: false))
        } else {
          output.write(renderJSON(report.records, single: true))
        }
      } else if report.records.isEmpty {
        output.error("avdecc-ctl: no entities found")
      } else {
        output.write(renderText(report.records))
      }
      exitStatus = report.exitStatus
    } catch Failure.timedOut(activity: nil) {
      let failure = Failure.timedOut(activity: session.activity.withLock { $0 })
      output.error("avdecc-ctl: \(failure.message)")
      exitStatus = 2
    } catch let failure as Failure {
      output.error("avdecc-ctl: \(failure.message)")
      exitStatus = failure.exitStatus
    } catch {
      output.error("avdecc-ctl: \(error)")
      exitStatus = 1
    }
    await controller.close()
    await endStation.close()
    return exitStatus
  }
}
