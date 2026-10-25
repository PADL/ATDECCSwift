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

@testable import ATDECC
@testable import AvdeccCtl
import IEEE802
import Logging
import Synchronization
import XCTest

private let controllerMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]

/// Collects what a command prints.
private final class CapturedOutput: OutputSink {
  private let _output = Mutex<(out: [String], err: [String])>(([], []))

  var out: String {
    _output.withLock { $0.out.joined(separator: "\n") }
  }

  var err: String {
    _output.withLock { $0.err.joined(separator: "\n") }
  }

  func write(_ text: String) {
    _output.withLock { $0.out.append(text) }
  }

  func error(_ text: String) {
    _output.withLock { $0.err.append(text) }
  }
}

/// Each subcommand, run against a fake entity on a virtual network.
final class CommandTests: XCTestCase {
  private var network: VirtualNetwork!
  private var entity: FakeEntity!

  override func setUp() async throws {
    network = VirtualNetwork()
    entity = FakeEntity(network: network)
  }

  override func tearDown() async throws {
    entity.stop()
  }

  private func run(_ arguments: String) async throws -> (status: Int32, out: String, err: String) {
    var invocation = try Invocation(parsing: arguments.split(separator: " ").map(String.init))
    if invocation.options.timeout == Options().timeout {
      invocation.options.timeout = .seconds(2)
    }
    let output = CapturedOutput()
    let status = await AvdeccCtl.run(
      invocation,
      on: network.makePort(macAddress: controllerMacAddress),
      output: output,
      logger: Logger(label: "CommandTests")
    )
    return (status, output.out, output.err)
  }

  private let id = "0x020000fffe000002"

  // MARK: - Discovery and descriptors

  func testDiscover() async throws {
    let (status, out, _) = try await run("discover --seconds 0.3")
    XCTAssertEqual(status, 0)
    XCTAssertTrue(out.contains("0x020000fffe000002 \"Fake Entity\""), out)
    XCTAssertTrue(out.contains("entity model id: 0x0200000000000042"), out)
    XCTAssertTrue(
      out.contains("capabilities: AEM_SUPPORTED, CLASS_A_SUPPORTED, GPTP_SUPPORTED"),
      out
    )
    XCTAssertTrue(out.contains("talker stream sources: 1"), out)
    XCTAssertTrue(
      out.contains("listener capabilities: IMPLEMENTED, MEDIA_CLOCK_SINK, AUDIO_SINK"),
      out
    )
    XCTAssertTrue(out.contains("gptp grandmaster id: 0x001122fffe334455"), out)
    XCTAssertTrue(out.contains("mac address: 02:00:00:00:00:02"), out)
  }

  func testDiscoverJSON() async throws {
    let (status, out, _) = try await run("discover --seconds 0.3 --json")
    XCTAssertEqual(status, 0)
    XCTAssertTrue(
      out.hasPrefix("[{\"entity_id\":\"0x020000fffe000002\",\"name\":\"Fake Entity\""),
      out
    )
    XCTAssertTrue(out.contains("\"talker_stream_sources\":1"), out)
  }

  func testDiscoverNothing() async throws {
    entity.stop()
    let (status, out, err) = try await run("discover --seconds 0.2")
    XCTAssertEqual(status, 0)
    XCTAssertEqual(out, "")
    XCTAssertTrue(err.contains("no entities found"), err)
  }

  func testDump() async throws {
    let (status, out, err) = try await run("dump \(id)")
    XCTAssertEqual(status, 0, err)
    for expected in [
      "ENTITY 0 \"Fake Entity\"", "firmware version: 1.2.3", "current configuration: 0",
      "CONFIGURATION 0 \"Default\"", "STREAM_INPUT: 2",
      "AUDIO_UNIT 0 \"Audio\"", "current sampling rate: 48000", "sampling rates: 48000, 96000",
      "STREAM_INPUT 0 \"CRF in\"", "current format: 0x041060010000bb80 (crf,48k)",
      "stream flags: CLOCK_SYNC_SOURCE, CLASS_A",
      "STREAM_INPUT 1 \"Audio in\"", "    0x0205021800806000 (aaf,48k,int32/24,2ch,6spf)",
      "stream input ports: count=2 base=0",
      "STREAM_OUTPUT 0 \"Audio out\"", "buffer length ns: 2000000",
      "AVB_INTERFACE 0 \"enp8s0\"", "interface flags: GPTP_SUPPORTED, SRP_SUPPORTED",
      "log sync interval: -3",
      "CLOCK_SOURCE 0 \"CRF\"", "clock source type: INPUT_STREAM",
      "clock source location: STREAM_INPUT 0",
      "CLOCK_DOMAIN 0 \"Domain\"", "clock sources: 0",
    ] {
      XCTAssertTrue(out.contains(expected), "missing \(expected) in\n\(out)")
    }
    // the fake entity does not implement GET_AVB_INFO, which a dump does without
    XCTAssertFalse(out.contains("avb info"))
  }

  func testDumpJSON() async throws {
    let (status, out, _) = try await run("dump \(id) --json")
    XCTAssertEqual(status, 0)
    let entity = #"[{"descriptor_type":"ENTITY","descriptor_index":0,"name":"Fake Entity""#
    XCTAssertTrue(out.hasPrefix(entity), out)
    let stream = #"{"descriptor_type":"STREAM_INPUT","descriptor_index":1,"name":"Audio in""#
    XCTAssertTrue(out.contains(stream), out)
    XCTAssertTrue(
      out.contains("\"formats\":[\"0x0205021802006000 (aaf,48k,int32/24,8ch,6spf)\","),
      out
    )
    XCTAssertTrue(out.contains("\"descriptor_counts\":{\"AUDIO_UNIT\":1,"), out)
  }

  func testUnknownEntityTimesOut() async throws {
    let (status, _, err) = try await run("dump 0x020000fffe0000ff --timeout 0.5")
    XCTAssertEqual(status, 2)
    XCTAssertTrue(
      err.contains("timed out waiting for entity 0x020000fffe0000ff to be discovered"),
      err
    )
  }

  // MARK: - Streams

  func testStreamInfo() async throws {
    let (status, out, err) = try await run("stream-info \(id) input 1")
    XCTAssertEqual(status, 0, err)
    XCTAssertTrue(out.hasPrefix("STREAM_INPUT 1\n"), out)
    XCTAssertTrue(
      out.contains("flags: CONNECTED, STREAM_DEST_MAC_VALID, STREAM_ID_VALID, STREAM_FORMAT_VALID"),
      out
    )
    XCTAssertTrue(
      out.contains("stream format: 0x0205021802006000 (aaf,48k,int32/24,8ch,6spf)"),
      out
    )
    XCTAssertTrue(out.contains("stream id: 0x0200000000020000"), out)
    XCTAssertTrue(out.contains("stream dest mac: 91:e0:f0:00:fe:01"), out)
    XCTAssertTrue(out.contains("stream vlan id: 2"), out)
    XCTAssertTrue(out.contains("msrp accumulated latency ns: 500000"), out)
  }

  func testSetFormat() async throws {
    let (status, out, err) = try await run("set-format \(id) output 0 aaf,48k,int32/24,2ch,6spf")
    XCTAssertEqual(status, 0, err)
    XCTAssertEqual(
      out,
      "STREAM_OUTPUT 0\n  stream format: 0x0205021800806000 (aaf,48k,int32/24,2ch,6spf)"
    )
    XCTAssertEqual(entity.state.withLock(\.outputFormats), [aaf2Format])
  }

  func testSetFormatFailureNamesTheStatus() async throws {
    let (status, _, err) = try await run("set-format \(id) output 0 crf,48k")
    XCTAssertEqual(status, 1)
    XCTAssertTrue(err.contains("SET_STREAM_FORMAT failed: BAD_ARGUMENTS"), err)
  }

  func testSetFormatAcquiringTheEntity() async throws {
    entity.state.withLock { $0.requiresAcquire = true }
    var (status, _, err) = try await run("set-format \(id) input 1 0x0205021800806000")
    XCTAssertEqual(status, 1)
    XCTAssertTrue(err.contains("ACQUIRED_BY_OTHER"), err)

    (status, _, err) = try await run("set-format \(id) input 1 0x0205021800806000 --acquire --lock")
    XCTAssertEqual(status, 0, err)
    let state = entity.state.withLock { $0 }
    XCTAssertEqual(state.inputFormats, [crfFormat, aaf2Format])
    // released and unlocked afterwards
    XCTAssertNil(state.acquiredBy)
    XCTAssertNil(state.lockedBy)
    XCTAssertEqual(
      state.commands.suffix(5),
      [.acquireEntity, .lockEntity, .setStreamFormat, .lockEntity, .acquireEntity]
    )
  }

  func testStartAndStop() async throws {
    var (status, out, _) = try await run("start \(id) output 0")
    XCTAssertEqual(status, 0)
    XCTAssertEqual(out, "STREAM_OUTPUT 0\n  streaming: started")
    (status, out, _) = try await run("stop \(id) input 1")
    XCTAssertEqual(status, 0)
    XCTAssertEqual(out, "STREAM_INPUT 1\n  streaming: stopped")
    XCTAssertEqual(entity.state.withLock(\.commands).suffix(2), [.startStreaming, .stopStreaming])
  }

  func testCounters() async throws {
    let (status, out, err) = try await run("counters \(id) input 0")
    XCTAssertEqual(status, 0, err)
    XCTAssertEqual(
      out,
      "STREAM_INPUT 0 counters\n  counters valid: 0x00000801\n  MEDIA_LOCKED: 1\n  FRAMES_RX: 48000"
    )
    let (_, json, _) = try await run("counters \(id) avb-interface 0 --json")
    XCTAssertEqual(
      json,
      "{\"descriptor_type\":\"AVB_INTERFACE\",\"descriptor_index\":0,\"counters_valid\":\"0x00000801\",\"LINK_UP\":1,\"COUNTER_11\":48000}"
    )
  }

  // MARK: - Connections

  func testConnectAndDisconnect() async throws {
    var (status, out, err) = try await run("connect \(id) 1 0x020000fffe000003 0")
    XCTAssertEqual(status, 0, err)
    let heading = "CONNECT_RX\n  talker: 0x020000fffe000003 0\n  listener: 0x020000fffe000002 1\n"
    XCTAssertTrue(out.hasPrefix(heading), out)
    XCTAssertTrue(out.contains("stream id: 0x0200000000020000"), out)
    XCTAssertTrue(out.contains("stream dest mac: 91:e0:f0:00:fe:01"), out)
    XCTAssertTrue(out.contains("stream vlan id: 2"), out)
    XCTAssertTrue(out.contains("connection count: 1"), out)

    (status, out, _) = try await run("rx-state \(id) 1")
    XCTAssertEqual(status, 0)
    XCTAssertTrue(out.contains("talker: 0x020000fffe000003 0"), out)

    // the talker comes from GET_RX_STATE
    (status, out, err) = try await run("disconnect \(id) 1")
    XCTAssertEqual(status, 0, err)
    XCTAssertTrue(out.hasPrefix("DISCONNECT_RX\n"), out)
    XCTAssertTrue(entity.state.withLock(\.connectedTalkers).isEmpty)

    (status, _, err) = try await run("disconnect \(id) 1 0x020000fffe000003 0")
    XCTAssertEqual(status, 1)
    XCTAssertTrue(err.contains("DISCONNECT_RX failed: NOT_CONNECTED"), err)
  }

  func testConnectFailureNamesTheStatus() async throws {
    let (status, _, err) = try await run("connect \(id) 7 0x020000fffe000003 0")
    XCTAssertEqual(status, 1)
    XCTAssertTrue(err.contains("CONNECT_RX failed: LISTENER_UNKNOWN_ID"), err)
  }

  func testTxState() async throws {
    let (status, out, err) = try await run("tx-state \(id) 0 --json")
    XCTAssertEqual(status, 0, err)
    XCTAssertTrue(
      out.hasPrefix("{\"command\":\"GET_TX_STATE\",\"talker\":\"0x020000fffe000002 0\""),
      out
    )
    XCTAssertTrue(out.contains("\"connection_count\":1"), out)
    XCTAssertTrue(out.hasSuffix("\"listeners\":[\"0x020000fffe000003 1\"]}"), out)
  }

  // MARK: - Entity commands

  func testAcquireLockAndRelease() async throws {
    var (status, out, _) = try await run("acquire \(id)")
    XCTAssertEqual(status, 0)
    XCTAssertTrue(out.contains("owner id: 0x020000000001c71d"), out)
    // the same controller ID in the next invocation
    (status, _, _) = try await run("lock \(id)")
    XCTAssertEqual(status, 0)
    XCTAssertEqual(entity.state.withLock(\.lockedBy), UniqueIdentifier(0x0200_0000_0001_C71D))

    // another controller is refused
    var err: String
    (status, _, err) = try await run("release \(id) --controller-id 0x1")
    XCTAssertEqual(status, 1)
    XCTAssertTrue(err.contains("failed: ACQUIRED_BY_OTHER"), err)

    (status, _, _) = try await run("unlock \(id)")
    XCTAssertEqual(status, 0)
    (status, _, _) = try await run("release \(id)")
    XCTAssertEqual(status, 0)
    let state = entity.state.withLock { $0 }
    XCTAssertNil(state.acquiredBy)
    XCTAssertNil(state.lockedBy)
  }

  func testIdentifyFindsTheControl() async throws {
    // not advertised, so found among the CONTROL descriptors
    var (status, out, err) = try await run("identify \(id)")
    XCTAssertEqual(status, 0, err)
    XCTAssertEqual(out, "IDENTIFY 0x020000fffe000002\n  control index: 0\n  identify: yes")
    XCTAssertTrue(entity.state.withLock(\.identify))
    XCTAssertTrue(entity.state.withLock(\.commands).contains(.readDescriptor))

    entity.state.withLock {
      $0.advertisesIdentifyControl = true
      $0.commands = []
    }
    (status, out, err) = try await run("identify \(id) --off")
    XCTAssertEqual(status, 0, err)
    XCTAssertFalse(entity.state.withLock(\.identify))
    XCTAssertEqual(entity.state.withLock(\.commands), [.setControl])
  }
}
