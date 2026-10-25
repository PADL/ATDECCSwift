// swift-tools-version: 6.4

import PackageDescription

let CommonSwiftSettings: [SwiftSetting] = [
  .enableExperimentalFeature("StrictConcurrency"),
  .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
]

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
    .executable(
      name: "avdecc-discovery",
      targets: ["Discovery"]
    ),
    .executable(
      name: "avdecc-ctl",
      targets: ["AvdeccCtlTool"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/PADL/IEEE802Swift", from: "0.2.1"),
    .package(url: "https://github.com/PADL/IORingSwift", from: "2.3.1"),
    .package(url: "https://github.com/PADL/NetLinkSwift", from: "0.2.2"),
    .package(url: "https://github.com/PADL/SocketAddress", from: "0.5.2"),
    .package(url: "https://github.com/apple/swift-system", from: "1.2.1"),
    .package(url: "https://github.com/apple/swift-binary-parsing", from: "0.0.2"),
    .package(url: "https://github.com/apple/swift-log", from: "1.6.2"),
  ],
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
        .product(name: "NetLink", package: "NetLinkSwift", condition: .when(platforms: [.linux])),
        // NETLINK_ROUTE
        .product(name: "CLinuxSockAddr", package: "SocketAddress", condition: .when(platforms: [.linux])),
        .product(name: "SocketAddress", package: "SocketAddress", condition: .when(platforms: [.linux])),
        .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
        .product(name: "BinaryParsing", package: "swift-binary-parsing"),
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
  ]
)
