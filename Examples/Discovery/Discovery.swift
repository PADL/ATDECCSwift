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
#endif

/// Discovers ATDECC entities on an Ethernet interface and prints each one's ENTITY
/// descriptor.
@main
enum Discovery {
  static func main() async throws {
    LoggingSystem.bootstrap { label in
      var handler = StreamLogHandler.standardError(label: label)
      handler.logLevel = .debug
      return handler
    }

    guard CommandLine.arguments.count == 2 else {
      print("Usage: \(CommandLine.arguments[0]) interface")
      exit(1)
    }

    let controller: Controller<EthernetPort>
    do {
      let endStation = try EndStation(port: EthernetPort(interfaceName: CommandLine.arguments[1]))
      controller = try await Controller(
        endStation: endStation,
        entityID: endStation.makeDynamicEntityID()
      )
    } catch {
      print("failed to open \(CommandLine.arguments[1]): \(error)")
      exit(2)
    }
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
