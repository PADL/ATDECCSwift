// swift-tools-version: 6.2

import PackageDescription

let CommonSwiftSettings: [SwiftSetting] = [
  .enableExperimentalFeature("StrictConcurrency"),
  .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
  // NetLinkSwift's libnl module map includes <netlink/...> headers from here, and the importer of
  // every module that imports it, tests included, needs the path
  .unsafeFlags(["-Xcc", "-I/usr/include/libnl3"], .when(platforms: [.linux])),
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
  ],
  dependencies: [
    .package(url: "https://github.com/PADL/IEEE802Swift", branch: "main"),
    .package(url: "https://github.com/PADL/IORingSwift", from: "2.0.0"),
    .package(url: "https://github.com/PADL/NetLinkSwift", branch: "main"),
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
