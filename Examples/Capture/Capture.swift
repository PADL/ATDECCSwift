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
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Prints the ATDECC frames that reach an interface for a few seconds, then how many there were.
/// It only ever listens: no controller is started, and on macOS the BPF device is opened read-only,
/// so the kernel would refuse a transmission. Interfaces are put in promiscuous mode meanwhile.
@main
enum Capture {
  private static let maximumSeconds = 60

  static func main() async {
    #if os(macOS)
    let arguments = CommandLine.arguments
    guard arguments.count == 2 || arguments.count == 3,
          let seconds = arguments.count == 3 ? Int(arguments[2]) : 5,
          (1...maximumSeconds).contains(seconds)
    else {
      print("Usage: \(arguments[0]) interface [seconds, 1 to \(maximumSeconds); default 5]")
      exit(1)
    }

    let port: EthernetPort
    do {
      port = try EthernetPort(
        interfaceName: arguments[1],
        access: .receiveOnly,
        multicastReception: .promiscuous
      )
    } catch {
      print("cannot open \(arguments[1]): \(error)")
      exit(2)
    }

    print("listening on \(arguments[1]) for \(seconds)s, receive-only")
    let reception = Task {
      var count = 0
      do {
        try await port.receive { packet in
          count += 1
          print(packet)
        }
      } catch {
        print("reception failed: \(error)")
      }
      return count
    }
    try? await Task.sleep(for: .seconds(seconds))
    reception.cancel()
    await print("\(reception.value) ATDECC frames")
    #else
    print("avdecc-capture needs macOS; on Linux, use tcpdump")
    exit(1)
    #endif
  }
}
