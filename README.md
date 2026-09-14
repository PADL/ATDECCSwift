# ATDECCSwift

A pure Swift implementation of [IEEE 1722.1-2021](https://standards.ieee.org/ieee/1722.1/6900/)
(ATDECC, formerly AVDECC) and the Milan Vendor Unique extensions, sending and receiving PDUs
directly on raw Ethernet.

ATDECCSwift was previously AVDECCSwift, a wrapper around the L-Acoustics
[la_avdecc](https://github.com/L-Acoustics/avdecc) C++ library. It no longer depends on
la_avdecc, although its wire behaviour (timeouts, retries, tolerance of non-conforming
entities, which responses raise notifications) deliberately matches it.

## Status

- Linux only. Frames are sent and received with io_uring
  ([IORingSwift](https://github.com/PADL/IORingSwift)), on `AF_PACKET` sockets or serial
  devices.
- ATDECC Controller role. The codecs encode and decode commands and responses in both
  directions, so an entity (talker/listener) responder can be added later.
- Swift 6 strict concurrency: `EndStation` and `Controller` are actors.

## Capabilities

| Surface | Status |
|---|---|
| ADP discovery (§6.2.6) and controller advertising (§6.2.4) | ✓ |
| AEM commands (§7.4) | ✓ acquire/lock, entity/controller available, READ_DESCRIPTOR, configuration, stream format/info, names, association, sampling rate, clock source, controls, start/stop streaming, unsolicited notifications, AVB info, AS path, counters, reboot, audio maps, operations, memory object length, max transit time |
| AEM descriptors (§7.2) | ✓ entity, configuration, audio unit, stream, jack, AVB interface, clock source, memory object, locale, strings, stream/external/internal port, audio cluster, audio map, control, clock domain, timing, PTP instance, PTP port |
| Milan MVU commands | ✓ GET_MILAN_INFO, system unique ID, media clock reference info, BIND_STREAM, UNBIND_STREAM, GET_STREAM_INPUT_INFO_EX |
| ACMP controller commands and sniffing (§8.2) | ✓ |
| Unsolicited notifications as events (§7.5.2) | ✓ |
| Raw PDU send | ✓ |
| Serial (UART) transport | ✓ COBS-framed AVTPDUs |
| Not yet | WRITE_DESCRIPTOR, video/sensor formats and maps, signal selectors/mixers/matrices, authentication and security, GET_DYNAMIC_INFO, address access, entity responder |

## Quick taste

```swift
import ATDECC

let endStation = try EndStation(port: EthernetPort(interfaceName: "eth0"))
let controller = try await Controller(
  endStation: endStation,
  entityID: endStation.makeDynamicEntityID()
)

for await event in await controller.events() {
  if case let .entityOnline(id) = event {
    let descriptor = try await controller.readEntityDescriptor(id: id)
    print(descriptor.entityName)
  }
}
```

See `Examples/Discovery/Discovery.swift` for a complete, runnable example.

## Architecture

The names follow IEEE 1722.1-2021:

- **`NetworkPort`** — a protocol for the link AVTP frames travel on. `EthernetPort` joins the
  AVDECC multicast groups (rather than going promiscuous, so it works behind bridges that
  filter multicast in hardware); `SerialPort` reaches a single entity over a UART; and
  `VirtualPort` connects ports on an in-memory `VirtualNetwork` for tests and simulation.
- **`EndStation<Port>`** — an ATDECC End Station: owns a port, dispatches received PDUs to
  its entities, and issues dynamic entity IDs.
- **`Controller<Port>`** — an ATDECC Controller entity. It runs a Discovery state machine,
  the AEM and ACMP controller state machines (250 ms AECP timeout with one retry and
  IN_PROGRESS handling, per-command ACMP timeouts from Table 8-1), and reports discovery,
  unsolicited notifications and sniffed ACMP traffic as `ControllerEvent`s.
- **Codecs** — `AvdeccPdu` (`Adpdu`, `Aecpdu`, `Acmpdu`), `AemCommandPayload` /
  `AemResponsePayload`, `MvuCommandPayload` / `MvuResponsePayload` and `Descriptor` are enums
  parsed with [swift-binary-parsing](https://github.com/apple/swift-binary-parsing) and
  serialized with the `SerDes` protocols from [IEEE802Swift](https://github.com/PADL/IEEE802Swift).

Controllers and end stations are generic over their port type, so frames are handled without
existential dispatch.

## Migrating from AVDECCSwift

| AVDECCSwift | ATDECC |
|---|---|
| `import AVDECCSwift` | `import ATDECC` |
| `ProtocolInterface(type: .pCap, interfaceID:)` | `EndStation(port: EthernetPort(interfaceName:))` |
| `ProtocolInterface.getDynamicEID()` / `releaseDynamicEID(_:)` | `EndStation.makeDynamicEntityID()` / `releaseDynamicEntityID(_:)` |
| `LocalEntity(protocolInterface:entityID:)` | `Controller(endStation:entityID:)` (async) |
| `LocalEntityDelegate`, `LocalEntityEventStream`, `ProtocolInterfaceObserver` | `Controller.events()` |
| `onRemoteEntityOnline(_:entity:)` | `ControllerEvent.entityOnline` and `Controller.discoveredEntity(id:)` |
| `LocalEntityEvent` | `ControllerEvent` |
| `LocalEntityAemCommandStatus`, `LocalEntityControlStatus`, `LocalEntityMvuCommandStatus` | `AemStatus`, `AcmpStatus`, `MvuStatus` |
| `setStreamInputInfo(id:streamIndex:info:)` and other setters | `setStreamInputInfo(id:streamIndex:to:)` — setters take the new value as `to:` |
| `acquireEntity(… descriptorType: UInt16 …)` | `descriptorType: DescriptorType` |
| `discoverRemoteEntity(id:)`, `enableEntityAdvertising`, `close()` | now `async` |
| `Executor`, `AVDECCSwift.Logger` | removed; pass a swift-log `Logger` to `EndStation` or `Controller` |

## Building

Requires Swift 6.2 or later on Linux, with `liburing` and, for link state monitoring through
[NetLinkSwift](https://github.com/PADL/NetLinkSwift), `libnl` installed:

```sh
apt install liburing-dev pkg-config libnl-3-dev libnl-route-3-dev libnl-nf-3-dev libnl-genl-3-dev \
  libmnl-dev libnftnl-dev
```

```sh
swift build
swift test
```

The tests run controllers against a simulated entity on a `VirtualNetwork` and need no network
access or privileges.

Sending and receiving raw Ethernet needs `CAP_NET_RAW`. Either run as root, or grant the
capability to the binary:

```sh
sudo setcap cap_net_raw+ep .build/debug/avdecc-discovery
.build/debug/avdecc-discovery eth0
```

## Serial links

`SerialPort` carries ATDECC over a point-to-point UART, as used between a host and an AVB
entity's firmware. Each AVTPDU (the AVTP control header and its ADP, AECP or ACMP data, with no
Ethernet header or padding) is COBS encoded and sent between zero bytes. The device is set to
raw 8N1 at the requested baud rate (115200 by default).

The wire carries no addresses. Every frame goes to the one peer, and received frames appear to come from
`SerialPortPeerMacAddress`. The host end uses `SerialPortLocalMacAddress`
(`0A:E9:1B:00:00:00`) by default, because the entity firmware sends frames addressed to it, and
all multicast frames, to its UART.

```sh
.build/debug/avdecc-discovery /dev/ttyAMA0@115200
```

## License

Apache License 2.0; see `LICENSE`.
