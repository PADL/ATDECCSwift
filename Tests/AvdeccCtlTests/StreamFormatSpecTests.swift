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

final class StreamFormatSpecTests: XCTestCase {
  func testAafSpecs() throws {
    let milan = try parseStreamFormat("aaf,48k,int32/24,8ch,6spf")
    XCTAssertEqual(milan.format, 0x0205_0218_0200_6000)
    XCTAssertEqual(milan.subtype, .aaf)
    XCTAssertEqual(milan.sampleRate, 48000)
    XCTAssertEqual(milan.bitDepth, 24)
    XCTAssertEqual(milan.channelsPerFrame, 8)
    XCTAssertEqual(milan.samplesPerFrame, 6)
    XCTAssertEqual(streamFormatSpec(milan), "aaf,48k,int32/24,8ch,6spf")

    // samples per frame default to one 125 µs class A interval
    XCTAssertEqual(
      try parseStreamFormat("AAF,96k,int24,2ch"),
      try parseStreamFormat("aaf,96000,int24,2ch,12spf")
    )
    let pcm24 = try parseStreamFormat("aaf,96k,int24,2ch")
    XCTAssertEqual(pcm24.bitDepth, 24)
    XCTAssertEqual(streamFormatSpec(pcm24), "aaf,96k,int24,2ch,12spf")

    let upTo = try parseStreamFormat("aaf,44.1k,float32,16ch,6spf,ut")
    XCTAssertTrue(upTo.isUpToChannelsCount)
    XCTAssertTrue(upTo.isFloatingPoint)
    XCTAssertEqual(upTo.sampleRate, 44100)
    XCTAssertEqual(streamFormatSpec(upTo), "aaf,44.1k,float32,16ch,6spf,ut")
  }

  func testCrfSpecs() throws {
    let milan = try parseStreamFormat("crf,48k")
    XCTAssertEqual(milan.format, 0x0410_6001_0000_BB80)
    XCTAssertEqual(streamFormatSpec(milan), "crf,48k")
    let custom = try parseStreamFormat("crf,96k,interval=160,tpp=6")
    XCTAssertEqual(custom.crfTimestampInterval, 160)
    XCTAssertEqual(custom.crfTimestampsPerPdu, 6)
    XCTAssertEqual(custom.crfBaseFrequency, 96000)
    XCTAssertEqual(streamFormatSpec(custom), "crf,96k,interval=160,tpp=6")
  }

  func testIec61883Specs() throws {
    let am824 = try parseStreamFormat("iec61883-6,48k,8ch")
    XCTAssertEqual(am824.format, 0x00A0_0208_4000_0800)
    XCTAssertEqual(am824.sampleRate, 48000)
    XCTAssertEqual(am824.channelsPerFrame, 8)
    XCTAssertEqual(am824.bitDepth, 24)
    XCTAssertEqual(streamFormatSpec(am824), "iec61883-6,48k,8ch")
    XCTAssertEqual(
      try streamFormatSpec(parseStreamFormat("61883-6,96k,2ch,ut")),
      "iec61883-6,96k,2ch,ut"
    )
  }

  func testHexFormats() throws {
    XCTAssertEqual(try parseStreamFormat("0x0205021802006000").format, 0x0205_0218_0200_6000)
    XCTAssertEqual(try parseStreamFormat("0205021802006000").format, 0x0205_0218_0200_6000)
    XCTAssertEqual(try parseStreamFormat("0x1").format, 1)
    XCTAssertEqual(
      streamFormatDescription(StreamFormat(format: 0x0410_6001_0000_BB80)),
      "0x041060010000bb80 (crf,48k)"
    )
    // a format no spec describes is given in hex alone
    XCTAssertNil(streamFormatSpec(StreamFormat(format: 0x0300_0000_0000_0000)))
    XCTAssertEqual(
      streamFormatDescription(StreamFormat(format: 0x0300_0000_0000_0000)),
      "0x0300000000000000"
    )
  }

  func testEverySpecRoundTrips() throws {
    for spec in [
      "aaf,8k,int16,1ch,1spf", "aaf,192k,int32,64ch,24spf", "aaf,48k,int32/20,2ch,6spf,ut",
      "aaf,176.4k,float32,4ch,22spf", "crf,44.1k,type=2,pull=1", "iec61883-6,192k,24ch",
    ] {
      XCTAssertEqual(try streamFormatSpec(parseStreamFormat(spec)), spec)
    }
  }

  func testBadSpecs() {
    for (spec, message) in [
      ("aaf,48k,8ch", "needs a rate, a sample format and a channel count"),
      ("aaf,47k,int24,8ch", "no nominal sample rate"),
      ("aaf,48k,int24,0ch", "out of range"),
      ("aaf,48k,int24,2048ch", "out of range"),
      ("aaf,48k,int24,8ch,tpp=1", "unknown AAF parameter"),
      ("crf", "needs a base frequency"),
      ("crf,48k,interval=5000", "out of range"),
      ("crf,48k,8ch", "unexpected parameters"),
      ("iec61883-6,47k,8ch", "no sample rate"),
      ("iec61883-6,48k,float32,8ch", "only IEC 61883-6 AM824"),
      ("mpeg,48k", "unknown stream format"),
      ("aaf,48k,int24,8ch,loud", "unknown token 'loud'"),
    ] {
      XCTAssertThrowsError(try parseStreamFormat(spec), spec) { error in
        XCTAssertTrue("\(error)".contains(message), "\(spec): \(error)")
      }
    }
  }

  func testNames() {
    XCTAssertEqual(statusName(AemStatus.acquiredByOther), "ACQUIRED_BY_OTHER")
    XCTAssertEqual(statusName(AcmpStatus.listenerUnknownID), "LISTENER_UNKNOWN_ID")
    XCTAssertEqual(statusName(AcmpStatus.talkerDestMacFail), "TALKER_DEST_MAC_FAIL")
    XCTAssertEqual(upperSnakeCase("supportsAvtpUdpV4"), "SUPPORTS_AVTP_UDP_V4")
    XCTAssertEqual(descriptorTypeName(.streamInput), "STREAM_INPUT")
    XCTAssertEqual(descriptorTypeName(.ptpPort), "PTP_PORT")
    XCTAssertEqual(descriptorTypeName(DescriptorType(rawValue: 0x4000)), "0x4000")
    XCTAssertEqual(flagNames(UInt16(0x8003), [0: "A", 1: "B"]), ["A", "B", "0x8000"])
  }
}
