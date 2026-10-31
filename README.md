# ATDECCSwift

A pure Swift implementation of [IEEE 1722.1-2021](https://standards.ieee.org/ieee/1722.1/6900/)
(ATDECC, formerly AVDECC) and the Milan Vendor Unique extensions, sending and receiving PDUs
directly on raw Ethernet.

ATDECCSwift was previously AVDECCSwift, a wrapper around the L-Acoustics
[la_avdecc](https://github.com/L-Acoustics/avdecc) C++ library. It no longer depends on
la_avdecc, although its wire behaviour (timeouts, retries, tolerance of non-conforming
entities, which responses raise notifications) deliberately matches it.

## Status

- Linux and macOS. On Linux, frames are sent and received with io_uring
  ([IORingSwift](https://github.com/PADL/IORingSwift)), on `AF_PACKET` sockets, serial devices
  or Unix domain sockets. On macOS, `EthernetPort` uses a BPF device; the serial and Unix
  domain socket ports are Linux only. See [macOS](#macos).
- ATDECC Controller role. The codecs encode and decode commands and responses in both
  directions, so an entity (talker/listener) responder can be added later.
- Swift 6 strict concurrency: `EndStation` and `Controller` are actors.

## Capabilities

| Surface | Status |
|---|---|
| ADP discovery (§6.2.6) and controller advertising (§6.2.4) | ✓ |
| AEM commands (§7.4) | ✓ acquire/lock, entity/controller available, READ_DESCRIPTOR, configuration, stream format/info, names, association, sampling rate, clock source, controls, start/stop streaming, unsolicited notifications, AVB info, AS path, counters, reboot, audio maps, operations, memory object length, max transit time, WRITE_DESCRIPTOR, GET_DYNAMIC_INFO, stream backup, sampling rate range, path latency, video and sensor formats and maps, signal selectors, mixers and matrices, PTP instance and port commands other than PTP_PORT_INFO |
| AEM descriptors (§7.2) | ✓ entity, configuration, audio unit, stream, jack, AVB interface, clock source, memory object, locale, strings, stream/external/internal port, audio cluster, audio map, control, clock domain, timing, PTP instance, PTP port, video and sensor unit/cluster/map, signal selector, mixer, matrix, matrix signal, signal splitter/combiner/demultiplexer/multiplexer/transcoder, control block |
| Milan MVU commands | ✓ GET_MILAN_INFO, system unique ID, media clock reference info, BIND_STREAM, UNBIND_STREAM, GET_STREAM_INPUT_INFO_EX |
| ACMP controller commands and sniffing (§8.2) | ✓ |
| Unsolicited notifications as events (§7.5.2) | ✓ |
| Raw PDU send | ✓ |
| Serial (UART) transport | ✓ COBS-framed AVTPDUs |
| Not yet | authentication and security, SET/GET_PTP_PORT_INFO, address access, entity responder |

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

See `Examples/Discovery/Discovery.swift` for a complete, runnable example, and
[avdecc-ctl](#avdecc-ctl) for a controller command line.

## Architecture

The names follow IEEE 1722.1-2021:

- **`NetworkPort`** — a protocol for the link AVTP frames travel on. `EthernetPort` joins the
  AVDECC multicast groups (rather than going promiscuous, so it works behind bridges that
  filter multicast in hardware); `SerialPort` reaches a single entity over a UART;
  `UnixSocketPort` reaches a single entity on the same host over an `AF_UNIX` datagram socket
  (these two on Linux only);
  and `VirtualPort` connects ports on an in-memory `VirtualNetwork` for tests and simulation.
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

## macOS

`EthernetPort` on macOS is a Berkeley Packet Filter port. Everything that needs no system call
(reading a BPF buffer, the filter program) is in `BpfBuffer.swift`, and everything else behind
`NetworkPort`, so the codecs and state machines are the same on every platform.

- **BPF access.** The `/dev/bpf*` devices are root's on stock macOS. A process without access
  gets `EthernetPortError.bpfPermissionDenied`; granting it, usually through a group, is up to
  whoever installs the software.
- **Multicast.** Joining the AVDECC groups (`SIOCADDMULTI`) needs root whatever the BPF
  permissions, and otherwise throws `EthernetPortError.multicastMembershipDenied`. The default,
  `.joinGroups`, matches Linux; a process that isn't root passes `.promiscuous`, which needs only
  BPF access. The kernel filter still passes only ADP, AECP and ACMP frames, but promiscuous mode
  is the interface's, for as long as the port is open. Unlike promiscuous mode, a membership is
  not undone by the kernel when a process exits, only when the port is released.
- **Link state** is polled once a second.

```swift
let port = try EthernetPort(interfaceName: "en0", multicastReception: .promiscuous)
let endStation = EndStation(port: port)
let controller = try await Controller(
  endStation: endStation,
  entityID: endStation.makeDynamicEntityID()
)
```

`avdecc-ctl -p` and `avdecc-discovery` take `promisc:en0` to do the same. `avdecc-capture en0 5`
prints the ATDECC frames that arrive for five seconds; it opens the BPF device read-only and starts
no controller, so it cannot transmit.

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

Requires Swift 6.3 or later. macOS 26 needs nothing else; Linux needs `liburing` and, for link
state monitoring through [NetLinkSwift](https://github.com/PADL/NetLinkSwift), `libnl`:

```sh
apt install liburing-dev pkg-config libnl-3-dev libnl-route-3-dev libnl-nf-3-dev libnl-genl-3-dev \
  libmnl-dev libnftnl-dev
```

```sh
swift build
swift test
```

The tests run controllers against a simulated entity on a `VirtualNetwork` and need no network
access or privileges. The serial and Unix domain socket port tests use a pseudo-terminal and io_uring, which Docker's
default seccomp profile blocks: run a container with `--security-opt seccomp=unconfined`.

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

## Unix domain sockets

`UnixSocketPort` carries ATDECC to an entity on the same host over an `AF_UNIX` `SOCK_DGRAM`
socket, as la_avdecc's local protocol interface does. Each datagram is one AVTPDU (the AVTP
control header and its ADP, AECP or ACMP data, with no Ethernet header, padding or COBS
encoding) of at most 1500 octets; longer datagrams, and those too short for a control header,
are discarded.

As on a serial link, the wire carries no addresses: every frame goes to the one peer, and
received frames appear to come from `UnixSocketPortPeerMacAddress` (`0A:E9:1B:FF:FF:FF`), so a
controller can pair with the entity without waiting to learn its address. AECP frames are
given the destination `UnixSocketPortLocalMacAddress` (`0A:E9:1B:01:01:01`), ADP and ACMP the
AVDECC multicast address.

`UnixSocketPort(path:)` binds its socket to an autobound abstract address and connects it to
the entity's path. The entity binds the path, receives with `recvfrom`, and replies to each
controller with `sendto` to the address its datagrams came from, sending its advertisements
and other multicast frames to every controller it has heard from and forgetting one when a
send to it fails with `EPERM`, `ECONNREFUSED` or `ENOENT`. A datagram socket has no end of
stream, so an entity that goes away is noticed when a send fails; the port then connects to
the path again on each send, reaching the entity once it is back, and the entity goes offline
meanwhile when its advertisements stop.

An entity learns of a controller only from its datagrams, and a restarted entity cannot reach
a controller at all until the controller sends again: the controller's socket is still
connected to the entity's old socket, so the entity's `sendto` fails with `EPERM`. A
controller that should find a restarted entity must therefore set an automatic discovery
delay. The path must be a filesystem path: abstract names (beginning with a zero byte) are not
supported. `UnixSocketPort(fileDescriptor:)` takes a connected datagram socket instead, such
as one end of a `socketpair`, and does not reconnect.

```sh
.build/debug/avdecc-discovery unix:/run/mediabridge/atdecc.sock
```

## avdecc-ctl

`avdecc-ctl` is a controller for the command line, built on this library. Each command takes
`--port` (an Ethernet interface, which needs `CAP_NET_RAW`; `unix:path`, which reaches only the
entity on the same host; or a serial device) and `--timeout` (seconds, default 5, bounding the
whole command including discovery of its entity). Output is text, or JSON with `--json`.

| Command | Does |
|---|---|
| `discover [--seconds N]` | lists the entities heard in N seconds (default 3): entity and model IDs, name, capabilities, stream counts, gPTP grandmaster |
| `dump <entity>` | reads the current configuration's ENTITY, CONFIGURATION, AUDIO_UNIT, STREAM_INPUT, STREAM_OUTPUT, AVB_INTERFACE, CLOCK_SOURCE and CLOCK_DOMAIN descriptors, with each stream's current and supported formats decoded |
| `stream-info <entity> input\|output <index>` | GET_STREAM_INFO |
| `set-format <entity> input\|output <index> <format> [--acquire] [--lock]` | SET_STREAM_FORMAT, acquiring or locking the entity around it if asked |
| `start\|stop <entity> input\|output <index>` | START_STREAMING / STOP_STREAMING |
| `counters <entity> <descriptor type> <index>` | GET_COUNTERS, named (`entity`, `avb-interface`, `clock-domain`, `input`, `output`, `ptp-port`) |
| `clock-sources <entity> [<clock domain>]` | the current configuration's CLOCK_DOMAINs (or the one given), each with its CLOCK_SOURCEs (index, name, type, location) and the current one from GET_CLOCK_SOURCE |
| `set-clock-source <entity> <clock domain> <clock source> [--acquire] [--lock]` | SET_CLOCK_SOURCE, printing the index the entity applied; acquiring or locking the entity around it if asked |
| `connect <listener> <index> <talker> <index>` | ACMP CONNECT_RX |
| `disconnect <listener> <index> [<talker> <index>]` | ACMP DISCONNECT_RX; the talker defaults to the one GET_RX_STATE reports |
| `rx-state <listener> <index>`, `tx-state <talker> <index>` | ACMP GET_RX_STATE; GET_TX_STATE and the talker's connections |
| `acquire <entity> [--persistent]`, `release`, `lock`, `unlock` | ACQUIRE_ENTITY / LOCK_ENTITY |
| `identify <entity> [--off]` | sets the IDENTIFY control, found from the advertisement or the CONTROL descriptors |

Entity IDs are 16 hex digits or `0x…`. A stream format is hex (`0x0205021802006000`) or a spec,
which is also how formats are printed: `aaf,48k,int32/24,8ch,6spf` (rate, sample format with
an optional bit depth, channels, samples per frame, optionally `ut`), `crf,48k` (optionally
`interval=`, `tpp=`, `type=`, `pull=`) or `iec61883-6,48k,8ch` (AM824).

The controller's entity ID is the port's MAC address followed by `c71d` unless `--controller-id`
says otherwise, so successive invocations are the same controller: an entity acquired by
`acquire` stays acquired by `avdecc-ctl` until `release`.

The exit status is 0 on success; 1 when an entity answers with a failure status, which is
printed (`SET_STREAM_FORMAT failed: ACQUIRED_BY_OTHER`); and 2 for a usage error, a timeout or a
port that could not be opened.

```sh
avdecc-ctl -p unix:/run/mediabridge/atdecc.sock dump 0x8c1f64fffee89001
avdecc-ctl -p enp8s0 discover
avdecc-ctl -p enp8s0 stream-info 0x8c1f64fffee89037 input 1
avdecc-ctl -p enp8s0 set-format 0x0001f2fffefed2a4 output 0 aaf,48k,int32/24,8ch,6spf --acquire
avdecc-ctl -p enp8s0 connect 0x8c1f64fffee89037 1 0x8c1f64fffee89001 0
avdecc-ctl -p enp8s0 counters 0x8c1f64fffee89037 input 0
```

To move an entity between clock sources, read the indices from `clock-sources` first: they are
the entity's own, not fixed by the standard. On the bench MOTU 16A, for example, switch from
its internal clock to the clock recovered from its gPTP-timed input stream and back:

```sh
avdecc-ctl -p enp8s0 clock-sources 0x0001f2fffefed2a4
# CLOCK_DOMAIN 0 "..."
#   clock source index: 0
#   clock sources:
#     - clock source index: 0
#       name: Internal
#       clock source type: INTERNAL
#       clock source location: CLOCK_DOMAIN 0
#       current: yes
#     - clock source index: 1
#       ...
#       clock source type: INPUT_STREAM
#       clock source location: STREAM_INPUT 0
#       current: no
avdecc-ctl -p enp8s0 set-clock-source 0x0001f2fffefed2a4 0 1 --acquire
avdecc-ctl -p enp8s0 set-clock-source 0x0001f2fffefed2a4 0 0 --acquire
```

The indices and names above are illustrative; use the ones `clock-sources` prints. A refused
change exits with 1 and names the status (`SET_CLOCK_SOURCE failed: ACQUIRED_BY_OTHER`).

Build it with `swift build -c release --product avdecc-ctl`. `--static-swift-stdlib` does not
work with Swift 6.4, so copy the Swift runtime libraries alongside the binary to a box without
a toolchain, and point the loader at them:

```sh
LD_LIBRARY_PATH=/usr/local/lib/swift avdecc-ctl -p enp8s0 discover
```

## License

Apache License 2.0; see `LICENSE`.
