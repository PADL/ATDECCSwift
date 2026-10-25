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
import IEEE802
import Synchronization

let entityMacAddress: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
let fakeEntityID = UniqueIdentifier(0x0200_00FF_FE00_0002)
let fakeTalkerID = UniqueIdentifier(0x0200_00FF_FE00_0003)
let grandmasterID = UniqueIdentifier(0x0011_22FF_FE33_4455)

let crfFormat = StreamFormat(format: 0x0410_6001_0000_BB80)
let aaf8Format = StreamFormat(format: 0x0205_0218_0200_6000) // aaf,48k,int32/24,8ch,6spf
let aaf2Format = StreamFormat(format: 0x0205_0218_0080_6000) // aaf,48k,int32/24,2ch,6spf

func be16(_ value: UInt16) -> [UInt8] {
  [UInt8(value >> 8), UInt8(value & 0xFF)]
}

func be32(_ value: UInt32) -> [UInt8] {
  be16(UInt16(value >> 16)) + be16(UInt16(value & 0xFFFF))
}

func be64(_ value: UInt64) -> [UInt8] {
  be32(UInt32(value >> 32)) + be32(UInt32(value & 0xFFFF_FFFF))
}

private func fixedString(_ string: String) -> [UInt8] {
  let bytes = Array(string.utf8)
  return bytes + [UInt8](repeating: 0, count: AvdeccFixedStringLength - bytes.count)
}

/// `parts` end to end.
func octets(_ parts: [UInt8]...) -> [UInt8] {
  parts.flatMap(\.self)
}

private func header(_ type: DescriptorType, _ index: UInt16) -> [UInt8] {
  be16(type.rawValue) + be16(index)
}

/// A talker and listener on a virtual network: ENTITY, CONFIGURATION, an AUDIO_UNIT,
/// STREAM_INPUT 0 (CRF) and 1 (AAF), STREAM_OUTPUT 0 (AAF), an AVB_INTERFACE, a CLOCK_SOURCE,
/// a CLOCK_DOMAIN and an IDENTIFY CONTROL, answering the commands avdecc-ctl sends.
final class FakeEntity: Sendable {
  struct State {
    var inputFormats = [crfFormat, aaf8Format]
    var outputFormats = [aaf8Format]
    /// SET_STREAM_FORMAT is refused with ACQUIRED_BY_OTHER unless the controller has acquired the
    /// entity.
    var requiresAcquire = false
    var acquiredBy: UniqueIdentifier?
    var lockedBy: UniqueIdentifier?
    var connectedTalkers = [UInt16: StreamIdentification]()
    var identify = false
    var streaming = Set<String>()
    var advertisesIdentifyControl = false
    /// AEM command types received, in order.
    var commands = [AemCommandType]()
  }

  let port: VirtualPort
  let state = Mutex(State())
  private let _availableIndex = Mutex(UInt32(0))
  private let _task = Mutex<Task<(), Never>?>(nil)

  init(network: VirtualNetwork) {
    port = network.makePort(macAddress: entityMacAddress)
    let task = Task { [port] in
      _ = try? await port.receive { [weak self] packet in
        await self?._handle(packet)
      }
    }
    _task.withLock { $0 = task }
  }

  func stop() {
    _task.withLock { $0?.cancel() }
    port.close()
  }

  private func send(_ pdu: AvdeccPdu, to destination: EUI48) async throws {
    try await port.send(IEEE802Packet(
      destMacAddress: destination,
      tci: nil,
      sourceMacAddress: entityMacAddress,
      etherType: AvtpEtherType,
      payload: pdu.serialized()
    ))
  }

  func advertise() async throws {
    let identify = state.withLock(\.advertisesIdentifyControl)
    // an available_index that does not advance is taken for a reboot
    let availableIndex = _availableIndex.withLock { index in
      defer { index += 1 }
      return index
    }
    var capabilities: EntityCapabilities = [.aemSupported, .classASupported, .gptpSupported]
    if identify { capabilities.insert(.aemIdentifyControlIndexValid) }
    try await send(.adp(Adpdu(
      messageType: .entityAvailable,
      validTime: 10,
      entityID: fakeEntityID,
      entityModelID: UniqueIdentifier(0x0200_0000_0000_0042),
      entityCapabilities: capabilities,
      talkerStreamSources: 1,
      talkerCapabilities: [.implemented, .audioSource],
      listenerStreamSinks: 2,
      listenerCapabilities: [.implemented, .audioSink, .mediaClockSink],
      availableIndex: availableIndex,
      gptpGrandmasterID: grandmasterID,
      identifyControlIndex: 0
    )), to: AvdeccMulticastMacAddress)
  }

  private func _handle(_ packet: IEEE802Packet) async {
    guard let pdu = try? packet.payload.withParserSpan({ try AvdeccPdu(parsing: &$0) }) else {
      return
    }
    switch pdu {
    case let .adp(adpdu) where adpdu.messageType == .entityDiscover &&
      (adpdu.entityID == UniqueIdentifier() || adpdu.entityID == fakeEntityID):
      try? await advertise()
    case let .aecp(.aem(aem)) where !aem.isResponse && aem.targetEntityID == fakeEntityID:
      var response = aem
      response.isResponse = true
      let (status, data) = _respond(to: aem)
      response.status = UInt8(status.rawValue)
      if let data { response.commandSpecificData = data }
      try? await send(.aecp(.aem(response)), to: packet.sourceMacAddress)
    case let .acmp(acmpdu) where !acmpdu.messageType.isResponse:
      guard let response = _respond(to: acmpdu) else { return }
      try? await send(.acmp(response), to: AvdeccMulticastMacAddress)
    default:
      break
    }
  }

  // MARK: - AEM

  private func _respond(to aem: AemAecpdu) -> (AemStatus, [UInt8]?) {
    state.withLock { $0.commands.append(aem.commandType) }
    guard let command = try? AemCommandPayload(
      commandTypeRaw: aem.commandTypeRaw,
      data: aem.commandSpecificData
    )
    else { return (.notImplemented, nil) }
    let controller = aem.controllerEntityID
    switch command {
    case let .readDescriptor(configurationIndex, type, index):
      guard let descriptor = _descriptor(type, index) else { return (.noSuchDescriptor, nil) }
      return (.success, be16(configurationIndex) + be16(0) + descriptor)
    case let .acquireEntity(flags, _, type, index):
      return state.withLock { state in
        if let owner = state.acquiredBy, owner != controller {
          return (.acquiredByOther, nil)
        }
        state.acquiredBy = flags.contains(.release) ? nil : controller
        return (
          .success,
          be32(flags.rawValue) + be64((state.acquiredBy ?? UniqueIdentifier()).rawValue) +
            be16(type.rawValue) + be16(index)
        )
      }
    case let .lockEntity(flags, _, type, index):
      return state.withLock { state in
        if let locker = state.lockedBy, locker != controller {
          return (.lockedByOther, nil)
        }
        state.lockedBy = flags.contains(.unlock) ? nil : controller
        return (
          .success,
          be32(flags.rawValue) + be64((state.lockedBy ?? UniqueIdentifier()).rawValue) +
            be16(type.rawValue) + be16(index)
        )
      }
    case let .setStreamFormat(type, index, format):
      return state.withLock { state in
        if state.requiresAcquire, state.acquiredBy != controller {
          return (.acquiredByOther, nil)
        }
        let supported = type == .streamInput ? [crfFormat, aaf8Format, aaf2Format] : [
          aaf8Format,
          aaf2Format,
        ]
        guard supported.contains(format) else { return (.badArguments, nil) }
        if type == .streamInput, Int(index) < state.inputFormats.count {
          state.inputFormats[Int(index)] = format
        } else if type == .streamOutput, Int(index) < state.outputFormats.count {
          state.outputFormats[Int(index)] = format
        } else {
          return (.noSuchDescriptor, nil)
        }
        return (.success, be16(type.rawValue) + be16(index) + be64(format.format))
      }
    case let .getStreamInfo(type, index):
      let format = state
        .withLock {
          type == .streamInput ? $0.inputFormats[Int(index)] : $0.outputFormats[Int(index)]
        }
      let flags = StreamInfoFlags([
        .streamFormatValid,
        .streamIDValid,
        .streamDestMacValid,
        .connected,
      ])
      return (.success, octets(
        be16(type.rawValue), be16(index), be32(flags.rawValue), be64(format.format),
        be64(0x0200_0000_0002_0000), be32(500_000), [0x91, 0xE0, 0xF0, 0x00, 0xFE, 0x01], [0, 0],
        be64(0), be16(2), be16(0)
      ))
    case let .getCounters(type, index):
      // MEDIA_LOCKED (bit 0) and FRAMES_RX (bit 11) are valid
      var counters = [UInt32](repeating: 0, count: DescriptorCounters.count)
      counters[0] = 1
      counters[11] = 48000
      return (
        .success,
        be16(type.rawValue) + be16(index) + be32(1 | 1 << 11) + counters.flatMap(be32)
      )
    case .startStreaming, .stopStreaming:
      return (.success, nil)
    case let .setControl(_, index, values):
      guard index == 0, values.count == 1 else { return (.badArguments, nil) }
      state.withLock { $0.identify = values[0] != 0 }
      return (.success, nil)
    default:
      return (.notImplemented, nil)
    }
  }

  private func _descriptor(_ type: DescriptorType, _ index: UInt16) -> [UInt8]? {
    switch (type, index) {
    case (.entity, 0):
      return octets(
        header(.entity, 0), be64(fakeEntityID.rawValue), be64(0x0200_0000_0000_0042),
        be32(EntityCapabilities.aemSupported.rawValue), be16(1), be16(0x4001), be16(2),
        be16(0x4001),
        be32(0), be32(1), be64(0), fixedString("Fake Entity"), be16(0xFFFF), be16(0xFFFF),
        fixedString("1.2.3"), fixedString("bench"), fixedString("SN1"), be16(1), be16(0)
      )
    case (.configuration, 0):
      let counts: [(DescriptorType, UInt16)] = [
        (.audioUnit, 1), (.streamInput, 2), (.streamOutput, 1), (.avbInterface, 1), (
          .clockSource,
          1
        ),
        (.control, 1), (.clockDomain, 1),
      ]
      return header(.configuration, 0) + fixedString("Default") + be16(0xFFFF) +
        be16(UInt16(counts.count)) +
        be16(74) + counts.flatMap { be16($0.0.rawValue) + be16($0.1) }
    case (.audioUnit, 0):
      // clock domain 0, two stream input ports, one stream output port, nothing else
      var body = fixedString("Audio") + be16(0xFFFF) + be16(0) + be16(2) + be16(0) + be16(1) +
        be16(0)
      body += [UInt8](repeating: 0, count: 2 * 28)
      body += be32(48000) + be16(144) + be16(2)
      return header(.audioUnit, 0) + body + be32(48000) + be32(96000)
    case (.streamInput, 0):
      return stream(.streamInput, 0, "CRF in", [crfFormat], flags: [.clockSyncSource, .classA])
    case (.streamInput, 1):
      return stream(.streamInput, 1, "Audio in", [aaf8Format, aaf2Format], flags: [.classA])
    case (.streamOutput, 0):
      return stream(.streamOutput, 0, "Audio out", [aaf8Format, aaf2Format], flags: [.classA])
    case (.avbInterface, 0):
      let flags = AvbInterfaceFlags([.gptpSupported, .srpSupported]).rawValue
      return octets(
        header(.avbInterface, 0), fixedString("enp8s0"), be16(0xFFFF),
        (0..<6).map { entityMacAddress[$0] }, be16(flags),
        be64(0x0200_00FF_FE00_0002), [248, 248], be16(0x436A), [0xFE, 248, 0, 0xFD, 0, 0], be16(1)
      )
    case (.clockSource, 0):
      return octets(
        header(.clockSource, 0), fixedString("CRF"), be16(0xFFFF),
        be16(ClockSourceFlags.streamID.rawValue),
        be16(2), be64(0), be16(DescriptorType.streamInput.rawValue), be16(0)
      )
    case (.clockDomain, 0):
      return octets(
        header(.clockDomain, 0),
        fixedString("Domain"),
        be16(0xFFFF),
        be16(0),
        be16(76),
        be16(1),
        be16(0)
      )
    case (.control, 0):
      // a LINEAR_UINT8 IDENTIFY control: min, max, step, default, current, unit, string
      return octets(
        header(.control, 0), fixedString("Identify"), be16(0xFFFF), be32(0), be32(0), be16(0),
        be16(0x0001), be64(0x90E0_F000_0000_0001), be32(3), be16(104), be16(1),
        be16(DescriptorType.entity.rawValue), be16(0), be16(0), [0, 255, 255, 0, 0], be16(0),
        be16(0xFFFF)
      )
    default:
      return nil
    }
  }

  private func stream(
    _ type: DescriptorType, _ index: UInt16, _ name: String, _ formats: [StreamFormat],
    flags: StreamFlags
  ) -> [UInt8] {
    let current = state
      .withLock { type == .streamInput ? $0.inputFormats[Int(index)] : $0.outputFormats[Int(index)]
      }
    var body = fixedString(name) + be16(0xFFFF) + be16(0) + be16(flags.rawValue) +
      be64(current.format)
    body += be16(132) + be16(UInt16(formats.count))
    body += [UInt8](repeating: 0, count: 40) + be16(0) + be32(2_000_000)
    return header(type, index) + body + formats.flatMap { be64($0.format) }
  }

  // MARK: - ACMP

  private func _respond(to command: Acmpdu) -> Acmpdu? {
    var response = command
    response.messageType = command.messageType.response!
    response.streamID = UniqueIdentifier(0x0200_0000_0002_0000)
    response.streamDestAddress = [0x91, 0xE0, 0xF0, 0x00, 0xFE, 0x01]
    response.streamVlanID = 2
    switch command.messageType {
    case .connectRxCommand, .disconnectRxCommand, .getRxStateCommand:
      guard command.listenerEntityID == fakeEntityID else { return nil }
      let index = command.listenerUniqueID
      return state.withLock { state in
        guard index < 2 else {
          response.status = UInt8(AcmpStatus.listenerUnknownID.rawValue)
          return response
        }
        switch command.messageType {
        case .connectRxCommand:
          state.connectedTalkers[index] = command.talkerStream
        case .disconnectRxCommand:
          guard state.connectedTalkers[index] == command.talkerStream else {
            response.status = UInt8(AcmpStatus.notConnected.rawValue)
            return response
          }
          state.connectedTalkers[index] = nil
        default:
          let talker = state.connectedTalkers[index] ?? StreamIdentification(
            entityID: UniqueIdentifier(),
            streamIndex: 0
          )
          response.talkerEntityID = talker.entityID
          response.talkerUniqueID = talker.streamIndex
        }
        response.connectionCount = state.connectedTalkers[index] == nil ? 0 : 1
        return response
      }
    case .getTxStateCommand, .getTxConnectionCommand:
      guard command.talkerEntityID == fakeEntityID else { return nil }
      if command.messageType == .getTxConnectionCommand {
        response.listenerEntityID = fakeTalkerID
        response.listenerUniqueID = 1
      }
      response.connectionCount = 1
      return response
    default:
      return nil
    }
  }
}
