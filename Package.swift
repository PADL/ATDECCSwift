// swift-tools-version: 6.3

import PackageDescription

let CommonSwiftSettings: [SwiftSetting] = [
  .enableExperimentalFeature("StrictConcurrency"),
  .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
]

// NetLinkSwift only serves rtnetlink link monitoring. Its manifest cannot be loaded on Darwin: it
// declares no platforms while depending on packages that require macOS 13 and 15, which SwiftPM
// rejects even if nothing depends on the product. Hence the host check rather than a condition.
#if os(Linux)
let NetLinkPackageDependencies: [Package.Dependency] = [
  .package(url: "https://github.com/PADL/NetLinkSwift", from: "0.2.2"),
]
let NetLinkTargetDependencies: [Target.Dependency] = [
  .product(name: "NetLink", package: "NetLinkSwift"),
]
#else
let NetLinkPackageDependencies: [Package.Dependency] = []
let NetLinkTargetDependencies: [Target.Dependency] = []
#endif

let package = Package(
  name: "ATDECCSwift",
  platforms: [
    .macOS(.v26),
  ],
  products: [
    .library(
      name: "ATDECC",
      targets: ["ATDECC"]
    ),
    .library(
      name: "ATDECCProxy",
      targets: ["ATDECCProxy"]
    ),
    .executable(
      name: "avdecc-discovery",
      targets: ["Discovery"]
    ),
    .executable(
      name: "avdecc-ctl",
      targets: ["AvdeccCtlTool"]
    ),
    .executable(
      name: "avdecc-capture",
      targets: ["Capture"]
    ),
  ],
  traits: [
    .trait(
      name: "HTTPTunnel",
      description: "Serve the ATDECC proxy over HTTP CONNECT as well as WebSocket; needs FlyingFox's HTTPResponse(tunnel:) (swhitty/FlyingFox#254)"
    ),
    .default(enabledTraits: []),
  ],
  dependencies: [
    .package(url: "https://github.com/PADL/IEEE802Swift", from: "0.2.1"),
    .package(url: "https://github.com/PADL/IORingSwift", from: "2.3.1"),
    .package(url: "https://github.com/swhitty/FlyingFox", from: "0.26.2"),
    .package(url: "https://github.com/PADL/SocketAddress", from: "0.5.2"),
    .package(url: "https://github.com/apple/swift-system", from: "1.2.1"),
    .package(url: "https://github.com/apple/swift-binary-parsing", from: "0.0.2"),
    .package(url: "https://github.com/apple/swift-log", from: "1.6.2"),
  ] + NetLinkPackageDependencies,
  targets: [
    // IEEE 1722.1 codecs (PDUs, AEM/MVU payloads, descriptors) and the controller runtime
    // (Ethernet, serial and virtual network ports, end station, controller state machines).
    .target(
      name: "ATDECC",
      dependencies: [
        .product(name: "IEEE802", package: "IEEE802Swift"),
        .product(name: "IEEE802Linux", package: "IEEE802Swift", condition: .when(platforms: [.linux])),
        .product(name: "IORing", package: "IORingSwift", condition: .when(platforms: [.linux])),
        .product(name: "IORingUtils", package: "IORingSwift", condition: .when(platforms: [.linux])),
        // NETLINK_ROUTE
        .product(name: "CLinuxSockAddr", package: "SocketAddress", condition: .when(platforms: [.linux])),
        .product(name: "SocketAddress", package: "SocketAddress", condition: .when(platforms: [.linux])),
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "BinaryParsing", package: "swift-binary-parsing"),
        .product(name: "Logging", package: "swift-log"),
      ] + NetLinkTargetDependencies,
      swiftSettings: CommonSwiftSettings
    ),
    // The ATDECC Proxy Protocol (IEEE 1722.1-2021 Annex C): APPDU codec, the APS state machine
    // and, on Linux, a server over TCP and WebSocket that relays to a network port.
    .target(
      name: "ATDECCProxy",
      dependencies: [
        "ATDECC",
        .product(name: "IEEE802", package: "IEEE802Swift"),
        .product(name: "IEEE802Linux", package: "IEEE802Swift", condition: .when(platforms: [.linux])),
        .product(name: "BinaryParsing", package: "swift-binary-parsing"),
        // HTTP CONNECT and WebSocket; the layer 2 side is ATDECC's own ports
        .product(name: "FlyingFox", package: "FlyingFox"),
        .product(name: "FlyingSocks", package: "FlyingFox"),
        .product(name: "Logging", package: "swift-log"),
      ],
      swiftSettings: CommonSwiftSettings
    ),
    .executableTarget(
      name: "Discovery",
      dependencies: [
        "ATDECC",
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Examples/Discovery",
      swiftSettings: CommonSwiftSettings
    ),
    .executableTarget(
      name: "Capture",
      dependencies: [
        "ATDECC",
        .product(name: "IEEE802", package: "IEEE802Swift"),
      ],
      path: "Examples/Capture",
      swiftSettings: CommonSwiftSettings
    ),
    // avdecc-ctl, a controller command line; a library so that its tests can import it.
    .target(
      name: "AvdeccCtl",
      dependencies: [
        "ATDECC",
        .product(name: "IEEE802", package: "IEEE802Swift"),
        .product(name: "Logging", package: "swift-log"),
      ],
      swiftSettings: CommonSwiftSettings
    ),
    .executableTarget(
      name: "AvdeccCtlTool",
      dependencies: [
        "AvdeccCtl",
        .product(name: "Logging", package: "swift-log"),
      ],
      swiftSettings: CommonSwiftSettings
    ),
    .testTarget(
      name: "AvdeccCtlTests",
      dependencies: [
        "ATDECC",
        "AvdeccCtl",
        .product(name: "IEEE802", package: "IEEE802Swift"),
        .product(name: "Logging", package: "swift-log"),
      ],
      swiftSettings: CommonSwiftSettings
    ),
    .testTarget(
      name: "ATDECCTests",
      dependencies: [
        "ATDECC",
        .product(name: "BinaryParsing", package: "swift-binary-parsing"),
        .product(name: "IORing", package: "IORingSwift", condition: .when(platforms: [.linux])),
      ],
      swiftSettings: CommonSwiftSettings
    ),
    .testTarget(
      name: "ATDECCProxyTests",
      dependencies: [
        "ATDECC",
        "ATDECCProxy",
        .product(name: "BinaryParsing", package: "swift-binary-parsing"),
        // a handler mounted on a server shared with other routes
        .product(name: "FlyingFox", package: "FlyingFox"),
        .product(name: "FlyingSocks", package: "FlyingFox"),
        .product(name: "IEEE802", package: "IEEE802Swift"),
        .product(name: "SocketAddress", package: "SocketAddress", condition: .when(platforms: [.linux])),
        .product(name: "IORing", package: "IORingSwift", condition: .when(platforms: [.linux])),
        .product(name: "IORingUtils", package: "IORingSwift", condition: .when(platforms: [.linux])),
        .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
        .product(name: "Logging", package: "swift-log"),
      ],
      swiftSettings: CommonSwiftSettings
    ),
  ]
)
