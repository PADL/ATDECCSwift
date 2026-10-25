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
@testable import AvdeccCtl
import XCTest

final class ArgumentTests: XCTestCase {
  private func parse(_ arguments: String) throws -> Invocation {
    try Invocation(parsing: arguments.split(separator: " ").map(String.init))
  }

  private func assertUsageError(
    _ arguments: String,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try parse(arguments), file: file, line: line) { error in
      XCTAssertTrue("\(error)".contains(message), "\(error)", file: file, line: line)
    }
  }

  func testEntityIDs() throws {
    XCTAssertEqual(try parseEntityID("0x8c1f64fffee89001"), UniqueIdentifier(0x8C1F_64FF_FEE8_9001))
    XCTAssertEqual(try parseEntityID("8C1F64FFFEE89001"), UniqueIdentifier(0x8C1F_64FF_FEE8_9001))
    XCTAssertEqual(
      try parseEntityID("8c:1f:64:ff:fe:e8:90:01"),
      UniqueIdentifier(0x8C1F_64FF_FEE8_9001)
    )
    XCTAssertEqual(try parseEntityID("0x1"), UniqueIdentifier(1))
    XCTAssertThrowsError(try parseEntityID("8c1f64fffee8900"))
    XCTAssertThrowsError(try parseEntityID("0x"))
    XCTAssertThrowsError(try parseEntityID("0x18c1f64fffee89001"))
    XCTAssertThrowsError(try parseEntityID("werkstatt"))
  }

  func testOptionsBeforeAndAfterTheCommand() throws {
    let invocation =
      try parse("--port unix:/run/mediabridge/atdecc.sock dump 0x8c1f64fffee89001 --json -t 2.5")
    XCTAssertEqual(invocation.options.port, "unix:/run/mediabridge/atdecc.sock")
    XCTAssertTrue(invocation.options.json)
    XCTAssertEqual(invocation.options.timeout, .milliseconds(2500))
    XCTAssertEqual(invocation.command, .dump(UniqueIdentifier(0x8C1F_64FF_FEE8_9001)))
    XCTAssertEqual(
      try parse("--port=enp8s0 --timeout=1 discover --seconds=0.5").command,
      .discover(seconds: .milliseconds(500))
    )
    XCTAssertEqual(
      try parse("--controller-id 0x1234 -p eth0 dump 0x1").options.controllerID,
      UniqueIdentifier(0x1234)
    )
  }

  func testDefaults() throws {
    let invocation = try parse("-p eth0 discover")
    XCTAssertEqual(invocation.command, .discover(seconds: .seconds(3)))
    XCTAssertEqual(invocation.options.timeout, .seconds(5))
    XCTAssertFalse(invocation.options.json)
    XCTAssertNil(invocation.options.controllerID)
  }

  func testHelp() throws {
    XCTAssertEqual(try parse("--help").command, .help)
    XCTAssertEqual(try parse("help").command, .help)
    XCTAssertEqual(try parse("-p eth0 dump 0x1 -h").command, .help)
    XCTAssertEqual(try Invocation(parsing: []).command, .help)
  }

  func testStreamCommands() throws {
    let werkstatt = UniqueIdentifier(0x8C1F_64FF_FEE8_9037)
    XCTAssertEqual(
      try parse("stream-info 0x8c1f64fffee89037 input 1").command,
      .streamInfo(werkstatt, .input, 1)
    )
    XCTAssertEqual(
      try parse("start 0x8c1f64fffee89037 output 0x2").command,
      .startStreaming(werkstatt, .output, 2)
    )
    XCTAssertEqual(
      try parse("stop 0x8c1f64fffee89037 OUTPUT 0").command,
      .stopStreaming(werkstatt, .output, 0)
    )
    let aaf = StreamFormat(format: 0x0205_0218_0200_6000)
    XCTAssertEqual(
      try parse("set-format 0x8c1f64fffee89037 input 1 aaf,48k,int32/24,8ch,6spf --acquire")
        .command,
      .setFormat(werkstatt, .input, 1, aaf, acquire: true, lock: false)
    )
    let crf = StreamFormat(format: 0x0410_6001_0000_BB80)
    XCTAssertEqual(
      try parse("set-format 0x8c1f64fffee89037 input 0 0x041060010000bb80 --lock").command,
      .setFormat(werkstatt, .input, 0, crf, acquire: false, lock: true)
    )
  }

  func testCountersDescriptorTypes() throws {
    let id = UniqueIdentifier(1)
    XCTAssertEqual(try parse("counters 0x1 input 0").command, .counters(id, .streamInput, 0))
    XCTAssertEqual(
      try parse("counters 0x1 stream-output 1").command,
      .counters(id, .streamOutput, 1)
    )
    XCTAssertEqual(
      try parse("counters 0x1 AVB_INTERFACE 0").command,
      .counters(id, .avbInterface, 0)
    )
    XCTAssertEqual(try parse("counters 0x1 clockDomain 0").command, .counters(id, .clockDomain, 0))
    XCTAssertEqual(try parse("counters 0x1 ptp-port 0").command, .counters(id, .ptpPort, 0))
    XCTAssertEqual(try parse("counters 0x1 0x24 0").command, .counters(id, .clockDomain, 0))
    XCTAssertEqual(try parse("counters 0x1 entity 0").command, .counters(id, .entity, 0))
    assertUsageError("counters 0x1 widget 0", "not a descriptor type")
  }

  func testConnectionCommands() throws {
    let listener = StreamIdentification(
      entityID: UniqueIdentifier(0x8C1F_64FF_FEE8_9037),
      streamIndex: 1
    )
    let talker = StreamIdentification(
      entityID: UniqueIdentifier(0x8C1F_64FF_FEE8_9001),
      streamIndex: 0
    )
    XCTAssertEqual(
      try parse("connect 0x8c1f64fffee89037 1 0x8c1f64fffee89001 0").command,
      .connect(listener: listener, talker: talker)
    )
    XCTAssertEqual(
      try parse("disconnect 0x8c1f64fffee89037 1").command,
      .disconnect(listener: listener, talker: nil)
    )
    XCTAssertEqual(
      try parse("disconnect 0x8c1f64fffee89037 1 0x8c1f64fffee89001 0").command,
      .disconnect(listener: listener, talker: talker)
    )
    XCTAssertEqual(try parse("rx-state 0x8c1f64fffee89037 1").command, .rxState(listener))
    XCTAssertEqual(try parse("tx-state 0x8c1f64fffee89001 0").command, .txState(talker))
    assertUsageError(
      "connect 0x8c1f64fffee89037 1 0x8c1f64fffee89001",
      "needs a talker stream index"
    )
  }

  func testEntityCommands() throws {
    let id = UniqueIdentifier(0x0001_F2FF_FEFE_D2A4)
    XCTAssertEqual(try parse("acquire 0x0001f2fffefed2a4").command, .acquire(id, persistent: false))
    XCTAssertEqual(
      try parse("acquire 0x0001f2fffefed2a4 --persistent").command,
      .acquire(id, persistent: true)
    )
    XCTAssertEqual(try parse("release 0x0001f2fffefed2a4").command, .release(id))
    XCTAssertEqual(try parse("lock 0x0001f2fffefed2a4").command, .lock(id))
    XCTAssertEqual(try parse("unlock 0x0001f2fffefed2a4").command, .unlock(id))
    XCTAssertEqual(try parse("identify 0x0001f2fffefed2a4").command, .identify(id, on: true))
    XCTAssertEqual(try parse("identify 0x0001f2fffefed2a4 --off").command, .identify(id, on: false))
  }

  func testUsageErrors() {
    assertUsageError("frobnicate 0x1", "unknown command 'frobnicate'")
    assertUsageError("dump", "needs a entity ID")
    assertUsageError("dump 0x1 0x2", "unexpected argument '0x2'")
    assertUsageError("stream-info 0x1 sideways 0", "is not input or output")
    assertUsageError("stream-info 0x1 input -1", "not a descriptor index")
    assertUsageError("stream-info 0x1 input 65536", "not a descriptor index")
    assertUsageError("dump 0x1 --frob", "unknown option '--frob'")
    assertUsageError("dump 0x1 --timeout", "--timeout needs a value")
    assertUsageError("dump 0x1 --timeout soon", "--timeout takes a number of seconds")
    assertUsageError("dump 0x1 --timeout 0", "--timeout takes a number of seconds")
    assertUsageError("dump 0x1 --acquire", "--acquire does not apply to dump")
    assertUsageError("identify 0x1 --seconds 2", "--seconds does not apply to identify")
    assertUsageError("dump 0x1 --json=yes", "unknown option '--json=yes'")
  }
}
