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

import ATDECC
import Logging
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Discovers ATDECC entities on an Ethernet interface, or on a serial device given as
/// `path[@baud]`, and prints each one's ENTITY descriptor.
@main
enum Discovery {
  static func main() async throws {
    LoggingSystem.bootstrap { label in
      var handler = StreamLogHandler.standardError(label: label)
      handler.logLevel = .debug
      return handler
    }

    guard CommandLine.arguments.count == 2 else {
      print("Usage: \(CommandLine.arguments[0]) interface|/dev/tty[@baud]")
      exit(1)
    }

    #if os(Linux)
    let name = CommandLine.arguments[1]
    do {
      if name.hasPrefix("/") {
        let components = name.split(separator: "@", maxSplits: 1)
        guard let baudRate = components.count == 2 ? Int(components[1]) : 115_200 else {
          print("invalid baud rate in \(name)")
          exit(1)
        }
        try await discover(on: open(name) { try SerialPort(path: String(components[0]), baudRate: baudRate) })
      } else {
        try await discover(on: open(name) { try EthernetPort(interfaceName: name) })
      }
    } catch {
      print("discovery failed: \(error)")
      exit(2)
    }
    #else
    print("the Ethernet and serial ports are only available on Linux")
    exit(1)
    #endif
  }

  #if os(Linux)
  private static func open<Port: NetworkPort>(_ name: String, _ port: () throws -> Port) -> Port {
    do {
      return try port()
    } catch {
      print("failed to open \(name): \(error)")
      exit(2)
    }
  }
  #endif

  private static func discover<Port: NetworkPort>(on port: Port) async throws {
    let endStation = EndStation(port: port)
    let controller = try await Controller(
      endStation: endStation,
      entityID: endStation.makeDynamicEntityID()
    )
    print("controller \(controller.entityID)")

    for await event in await controller.events() {
      switch event {
      case let .entityOnline(id):
        let entity = await controller.discoveredEntity(id: id)
        print("online: \(entity.map(\.description) ?? id.description)")
        Task {
          do {
            print("  \(try await controller.readEntityDescriptor(id: id))")
          } catch {
            print("  \(id): READ_DESCRIPTOR failed: \(error)")
          }
        }
      case let .entityUpdated(id):
        print("updated: \(id)")
      case let .entityOffline(id):
        print("offline: \(id)")
      default:
        print("event: \(event)")
      }
    }
  }
}
