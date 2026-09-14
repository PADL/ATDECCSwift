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

import BinaryParsing
import IEEE802

// Payload layouts follow the command_specific_data figures of IEEE 1722.1-2021 §7.4. A
// response carries the same fields as its command unless noted; a GET_* command carries only
// the fields that address what is being read.

// GET_STREAM_INFO response lengths: IEEE 1722.1-2013, Milan (with the extension fields) and
// IEEE 1722.1-2021 (with the IP fields).
private let _streamInfoLength = 48
private let _milanStreamInfoLength = 56
private let _ieee2021StreamInfoLength = 84

/// AEM command_specific_data of a command (IEEE 1722.1-2021 §7.4).
public enum AemCommandPayload: Sendable, Hashable {
  case acquireEntity(
    flags: AcquireEntityFlags,
    ownerID: UniqueIdentifier,
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex
  )
  case lockEntity(
    flags: LockEntityFlags,
    lockedID: UniqueIdentifier,
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex
  )
  case entityAvailable
  case controllerAvailable
  case readDescriptor(
    configurationIndex: UInt16,
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex
  )
  case setConfiguration(configurationIndex: UInt16)
  case getConfiguration
  case setStreamFormat(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    streamFormat: StreamFormat
  )
  case getStreamFormat(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case setStreamInfo(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    streamInfo: StreamInfo
  )
  case getStreamInfo(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case setName(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    nameIndex: UInt16,
    configurationIndex: UInt16,
    name: String
  )
  case getName(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    nameIndex: UInt16,
    configurationIndex: UInt16
  )
  case setAssociationID(UniqueIdentifier)
  case getAssociationID
  case setSamplingRate(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    samplingRate: SamplingRate
  )
  case getSamplingRate(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case setClockSource(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    clockSourceIndex: UInt16
  )
  case getClockSource(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case setControl(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    packedControlValues: [UInt8]
  )
  case getControl(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case startStreaming(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case stopStreaming(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case registerUnsolicitedNotification(flags: RegisterUnsolicitedNotificationFlags)
  case deregisterUnsolicitedNotification
  case getAvbInfo(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getAsPath(descriptorIndex: DescriptorIndex)
  case getCounters(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case reboot(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getAudioMap(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    mapIndex: UInt16
  )
  case addAudioMappings(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    mappings: [AudioMapping]
  )
  case removeAudioMappings(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    mappings: [AudioMapping]
  )
  case startOperation(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    operationID: UInt16,
    operationType: UInt16,
    values: [UInt8]
  )
  case abortOperation(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    operationID: UInt16
  )
  case setMemoryObjectLength(configurationIndex: UInt16, memoryObjectIndex: UInt16, length: UInt64)
  case getMemoryObjectLength(configurationIndex: UInt16, memoryObjectIndex: UInt16)
  case setMaxTransitTime(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    maxTransitTime: UInt64
  )
  case getMaxTransitTime(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  /// A command without a dedicated model.
  case other(commandType: UInt16, data: [UInt8])

  public var commandTypeRaw: UInt16 {
    switch self {
    case .acquireEntity: AemCommandType.acquireEntity.rawValue
    case .lockEntity: AemCommandType.lockEntity.rawValue
    case .entityAvailable: AemCommandType.entityAvailable.rawValue
    case .controllerAvailable: AemCommandType.controllerAvailable.rawValue
    case .readDescriptor: AemCommandType.readDescriptor.rawValue
    case .setConfiguration: AemCommandType.setConfiguration.rawValue
    case .getConfiguration: AemCommandType.getConfiguration.rawValue
    case .setStreamFormat: AemCommandType.setStreamFormat.rawValue
    case .getStreamFormat: AemCommandType.getStreamFormat.rawValue
    case .setStreamInfo: AemCommandType.setStreamInfo.rawValue
    case .getStreamInfo: AemCommandType.getStreamInfo.rawValue
    case .setName: AemCommandType.setName.rawValue
    case .getName: AemCommandType.getName.rawValue
    case .setAssociationID: AemCommandType.setAssociationID.rawValue
    case .getAssociationID: AemCommandType.getAssociationID.rawValue
    case .setSamplingRate: AemCommandType.setSamplingRate.rawValue
    case .getSamplingRate: AemCommandType.getSamplingRate.rawValue
    case .setClockSource: AemCommandType.setClockSource.rawValue
    case .getClockSource: AemCommandType.getClockSource.rawValue
    case .setControl: AemCommandType.setControl.rawValue
    case .getControl: AemCommandType.getControl.rawValue
    case .startStreaming: AemCommandType.startStreaming.rawValue
    case .stopStreaming: AemCommandType.stopStreaming.rawValue
    case .registerUnsolicitedNotification:
      AemCommandType.registerUnsolicitedNotification.rawValue
    case .deregisterUnsolicitedNotification:
      AemCommandType.deregisterUnsolicitedNotification.rawValue
    case .getAvbInfo: AemCommandType.getAvbInfo.rawValue
    case .getAsPath: AemCommandType.getAsPath.rawValue
    case .getCounters: AemCommandType.getCounters.rawValue
    case .reboot: AemCommandType.reboot.rawValue
    case .getAudioMap: AemCommandType.getAudioMap.rawValue
    case .addAudioMappings: AemCommandType.addAudioMappings.rawValue
    case .removeAudioMappings: AemCommandType.removeAudioMappings.rawValue
    case .startOperation: AemCommandType.startOperation.rawValue
    case .abortOperation: AemCommandType.abortOperation.rawValue
    case .setMemoryObjectLength: AemCommandType.setMemoryObjectLength.rawValue
    case .getMemoryObjectLength: AemCommandType.getMemoryObjectLength.rawValue
    case .setMaxTransitTime: AemCommandType.setMaxTransitTime.rawValue
    case .getMaxTransitTime: AemCommandType.getMaxTransitTime.rawValue
    case let .other(commandType, _): commandType
    }
  }

  public var commandType: AemCommandType {
    AemCommandType(rawValue: commandTypeRaw) ?? .invalidCommandType
  }

  /// The encoded command_specific_data.
  public func serialized() throws -> [UInt8] {
    var context = SerializationContext()

    switch self {
    case let .acquireEntity(flags, ownerID, descriptorType, descriptorIndex):
      context.serialize(uint32: flags.rawValue)
      try context.serialize(ownerID)
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
    case let .lockEntity(flags, lockedID, descriptorType, descriptorIndex):
      context.serialize(uint32: flags.rawValue)
      try context.serialize(lockedID)
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
    case .entityAvailable, .controllerAvailable, .getConfiguration, .getAssociationID,
         .deregisterUnsolicitedNotification:
      break
    case let .registerUnsolicitedNotification(flags):
      context.serialize(uint32: flags.rawValue)
    case let .readDescriptor(configurationIndex, descriptorType, descriptorIndex):
      context.serialize(uint16: configurationIndex)
      context.serialize(uint16: 0) // reserved
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
    case let .setConfiguration(configurationIndex):
      context.serialize(uint16: 0) // reserved
      context.serialize(uint16: configurationIndex)
    case let .setStreamFormat(descriptorType, descriptorIndex, streamFormat):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      try context.serialize(streamFormat)
    case let .getStreamFormat(descriptorType, descriptorIndex),
         let .getStreamInfo(descriptorType, descriptorIndex),
         let .getSamplingRate(descriptorType, descriptorIndex),
         let .getClockSource(descriptorType, descriptorIndex),
         let .getControl(descriptorType, descriptorIndex),
         let .startStreaming(descriptorType, descriptorIndex),
         let .stopStreaming(descriptorType, descriptorIndex),
         let .getAvbInfo(descriptorType, descriptorIndex),
         let .getCounters(descriptorType, descriptorIndex),
         let .reboot(descriptorType, descriptorIndex),
         let .getMaxTransitTime(descriptorType, descriptorIndex):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
    case let .setStreamInfo(descriptorType, descriptorIndex, streamInfo):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      try streamInfo.serialize(into: &context)
    case let .setName(descriptorType, descriptorIndex, nameIndex, configurationIndex, name):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: nameIndex)
      context.serialize(uint16: configurationIndex)
      context.serialize(avdeccFixedString: name)
    case let .getName(descriptorType, descriptorIndex, nameIndex, configurationIndex):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: nameIndex)
      context.serialize(uint16: configurationIndex)
    case let .setAssociationID(associationID):
      try context.serialize(associationID)
    case let .setSamplingRate(descriptorType, descriptorIndex, samplingRate):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      try context.serialize(samplingRate)
    case let .setClockSource(descriptorType, descriptorIndex, clockSourceIndex):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: clockSourceIndex)
      context.serialize(uint16: 0) // reserved
    case let .setControl(descriptorType, descriptorIndex, packedControlValues):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(packedControlValues)
    case let .getAsPath(descriptorIndex):
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: 0) // reserved
    case let .getAudioMap(descriptorType, descriptorIndex, mapIndex):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: mapIndex)
      context.serialize(uint16: 0) // reserved
    case let .addAudioMappings(descriptorType, descriptorIndex, mappings),
         let .removeAudioMappings(descriptorType, descriptorIndex, mappings):
      try _serializeAudioMappings(descriptorType, descriptorIndex, mappings, into: &context)
    case let .startOperation(descriptorType, descriptorIndex, operationID, operationType, values):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: operationID)
      context.serialize(uint16: operationType)
      context.serialize(values)
    case let .abortOperation(descriptorType, descriptorIndex, operationID):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: operationID)
      context.serialize(uint16: 0) // reserved
    case let .setMemoryObjectLength(configurationIndex, memoryObjectIndex, length):
      _serializeMemoryObjectIndices(configurationIndex, memoryObjectIndex, into: &context)
      context.serialize(uint64: length)
    case let .getMemoryObjectLength(configurationIndex, memoryObjectIndex):
      _serializeMemoryObjectIndices(configurationIndex, memoryObjectIndex, into: &context)
    case let .setMaxTransitTime(descriptorType, descriptorIndex, maxTransitTime):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint64: maxTransitTime)
    case let .other(_, data):
      context.serialize(data)
    }

    return context.bytes
  }

  /// Decodes the command_specific_data of a received command.
  public init(commandTypeRaw: UInt16, data: [UInt8]) throws {
    self = try data.withParserSpan { input in
      switch AemCommandType(rawValue: commandTypeRaw) {
      case .acquireEntity:
        return try .acquireEntity(
          flags: AcquireEntityFlags(rawValue: UInt32(parsingBigEndian: &input)),
          ownerID: UniqueIdentifier(parsing: &input),
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input)
        )
      case .lockEntity:
        return try .lockEntity(
          flags: LockEntityFlags(rawValue: UInt32(parsingBigEndian: &input)),
          lockedID: UniqueIdentifier(parsing: &input),
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input)
        )
      case .entityAvailable:
        return .entityAvailable
      case .controllerAvailable:
        return .controllerAvailable
      case .readDescriptor:
        let configurationIndex = try UInt16(parsingBigEndian: &input)
        _ = try UInt16(parsingBigEndian: &input) // reserved
        return try .readDescriptor(
          configurationIndex: configurationIndex,
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input)
        )
      case .setConfiguration:
        _ = try UInt16(parsingBigEndian: &input) // reserved
        return try .setConfiguration(configurationIndex: UInt16(parsingBigEndian: &input))
      case .getConfiguration:
        return .getConfiguration
      case .setStreamFormat:
        return try .setStreamFormat(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          streamFormat: StreamFormat(parsing: &input)
        )
      case .getStreamFormat:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getStreamFormat(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .setStreamInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setStreamInfo(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          streamInfo: StreamInfo(parsing: &input)
        )
      case .getStreamInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getStreamInfo(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .setName:
        return try .setName(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          nameIndex: UInt16(parsingBigEndian: &input),
          configurationIndex: UInt16(parsingBigEndian: &input),
          name: String(parsingAvdeccFixedString: &input)
        )
      case .getName:
        return try .getName(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          nameIndex: UInt16(parsingBigEndian: &input),
          configurationIndex: UInt16(parsingBigEndian: &input)
        )
      case .setAssociationID:
        return try .setAssociationID(UniqueIdentifier(parsing: &input))
      case .getAssociationID:
        return .getAssociationID
      case .setSamplingRate:
        return try .setSamplingRate(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          samplingRate: SamplingRate(parsing: &input)
        )
      case .getSamplingRate:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getSamplingRate(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .setClockSource:
        return try .setClockSource(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          clockSourceIndex: UInt16(parsingBigEndian: &input)
        )
      case .getClockSource:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getClockSource(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .setControl:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .setControl(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          packedControlValues: [UInt8](parsingRemainingBytes: &input)
        )
      case .getControl:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getControl(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .startStreaming:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .startStreaming(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .stopStreaming:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .stopStreaming(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .registerUnsolicitedNotification:
        // a command without flags is from an entity predating IEEE 1722.1-2021 (§7.4.37.1)
        guard !input.isEmpty else { return .registerUnsolicitedNotification(flags: []) }
        return try .registerUnsolicitedNotification(
          flags: RegisterUnsolicitedNotificationFlags(rawValue: UInt32(parsingBigEndian: &input))
        )
      case .deregisterUnsolicitedNotification:
        return .deregisterUnsolicitedNotification
      case .getAvbInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getAvbInfo(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getAsPath:
        return try .getAsPath(descriptorIndex: UInt16(parsingBigEndian: &input))
      case .getCounters:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getCounters(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .reboot:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .reboot(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getAudioMap:
        return try .getAudioMap(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          mapIndex: UInt16(parsingBigEndian: &input)
        )
      case .addAudioMappings:
        let (descriptorType, descriptorIndex, mappings) = try _parseAudioMappings(&input)
        return .addAudioMappings(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          mappings: mappings
        )
      case .removeAudioMappings:
        let (descriptorType, descriptorIndex, mappings) = try _parseAudioMappings(&input)
        return .removeAudioMappings(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          mappings: mappings
        )
      case .startOperation:
        return try .startOperation(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          operationID: UInt16(parsingBigEndian: &input),
          operationType: UInt16(parsingBigEndian: &input),
          values: [UInt8](parsingRemainingBytes: &input)
        )
      case .abortOperation:
        return try .abortOperation(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          operationID: UInt16(parsingBigEndian: &input)
        )
      case .setMemoryObjectLength:
        let (configurationIndex, memoryObjectIndex) = try _parseMemoryObjectIndices(&input)
        return try .setMemoryObjectLength(
          configurationIndex: configurationIndex,
          memoryObjectIndex: memoryObjectIndex,
          length: UInt64(parsingBigEndian: &input)
        )
      case .getMemoryObjectLength:
        let (configurationIndex, memoryObjectIndex) = try _parseMemoryObjectIndices(&input)
        return .getMemoryObjectLength(
          configurationIndex: configurationIndex,
          memoryObjectIndex: memoryObjectIndex
        )
      case .setMaxTransitTime:
        return try .setMaxTransitTime(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          maxTransitTime: UInt64(parsingBigEndian: &input)
        )
      case .getMaxTransitTime:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getMaxTransitTime(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      default:
        return .other(commandType: commandTypeRaw, data: [UInt8](parsingRemainingBytes: &input))
      }
    }
  }
}

/// AEM command_specific_data of a successful response (IEEE 1722.1-2021 §7.4).
///
/// Only successful responses are decoded: an entity answering NOT_IMPLEMENTED reflects the
/// command, and other failures may omit fields.
public enum AemResponsePayload: Sendable, Hashable {
  case acquireEntity(
    flags: AcquireEntityFlags,
    ownerID: UniqueIdentifier,
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex
  )
  case lockEntity(
    flags: LockEntityFlags,
    lockedID: UniqueIdentifier,
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex
  )
  case entityAvailable
  case controllerAvailable
  case readDescriptor(
    configurationIndex: UInt16,
    descriptorIndex: DescriptorIndex,
    descriptor: Descriptor
  )
  case setConfiguration(configurationIndex: UInt16)
  case getConfiguration(configurationIndex: UInt16)
  case setStreamFormat(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    streamFormat: StreamFormat
  )
  case getStreamFormat(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    streamFormat: StreamFormat
  )
  case setStreamInfo(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    streamInfo: StreamInfo
  )
  case getStreamInfo(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    streamInfo: StreamInfo
  )
  case setName(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    nameIndex: UInt16,
    configurationIndex: UInt16,
    name: String
  )
  case getName(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    nameIndex: UInt16,
    configurationIndex: UInt16,
    name: String
  )
  case setAssociationID(UniqueIdentifier)
  case getAssociationID(UniqueIdentifier)
  case setSamplingRate(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    samplingRate: SamplingRate
  )
  case getSamplingRate(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    samplingRate: SamplingRate
  )
  case setClockSource(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    clockSourceIndex: UInt16
  )
  case getClockSource(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    clockSourceIndex: UInt16
  )
  case setControl(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    packedControlValues: [UInt8]
  )
  case getControl(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    packedControlValues: [UInt8]
  )
  case startStreaming(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case stopStreaming(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case registerUnsolicitedNotification
  case deregisterUnsolicitedNotification
  case getAvbInfo(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, avbInfo: AvbInfo)
  case getAsPath(descriptorIndex: DescriptorIndex, asPath: AsPath)
  case getCounters(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    countersValid: UInt32,
    counters: DescriptorCounters
  )
  case reboot(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getAudioMap(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    mapIndex: UInt16,
    numberOfMaps: UInt16,
    mappings: [AudioMapping]
  )
  case addAudioMappings(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    mappings: [AudioMapping]
  )
  case removeAudioMappings(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    mappings: [AudioMapping]
  )
  case startOperation(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    operationID: UInt16,
    operationType: UInt16,
    values: [UInt8]
  )
  case abortOperation(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    operationID: UInt16
  )
  /// Unsolicited progress of an operation (IEEE 1722.1-2021 §7.4.55).
  case operationStatus(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    operationID: UInt16,
    percentComplete: UInt16
  )
  case setMemoryObjectLength(configurationIndex: UInt16, memoryObjectIndex: UInt16, length: UInt64)
  case getMemoryObjectLength(configurationIndex: UInt16, memoryObjectIndex: UInt16, length: UInt64)
  case setMaxTransitTime(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    maxTransitTime: UInt64
  )
  case getMaxTransitTime(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    maxTransitTime: UInt64
  )
  /// A response without a dedicated model.
  case other(commandType: UInt16, data: [UInt8])

  /// Decodes the command_specific_data of a successful response.
  public init(commandTypeRaw: UInt16, data: [UInt8]) throws {
    self = try data.withParserSpan { input in
      switch AemCommandType(rawValue: commandTypeRaw) {
      case .acquireEntity:
        return try .acquireEntity(
          flags: AcquireEntityFlags(rawValue: UInt32(parsingBigEndian: &input)),
          ownerID: UniqueIdentifier(parsing: &input),
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input)
        )
      case .lockEntity:
        return try .lockEntity(
          flags: LockEntityFlags(rawValue: UInt32(parsingBigEndian: &input)),
          lockedID: UniqueIdentifier(parsing: &input),
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input)
        )
      case .entityAvailable:
        return .entityAvailable
      case .controllerAvailable:
        return .controllerAvailable
      case .readDescriptor:
        let configurationIndex = try UInt16(parsingBigEndian: &input)
        _ = try UInt16(parsingBigEndian: &input) // reserved
        // descriptor offsets count from descriptor_type, so give the descriptor its own origin
        var descriptorInput = input.extractRemaining()
        let descriptorTypeRaw = try UInt16(parsingBigEndian: &descriptorInput)
        let descriptorIndex = try UInt16(parsingBigEndian: &descriptorInput)
        return try .readDescriptor(
          configurationIndex: configurationIndex,
          descriptorIndex: descriptorIndex,
          descriptor: Descriptor(
            descriptorTypeRaw: descriptorTypeRaw,
            parsingBody: &descriptorInput
          )
        )
      case .setConfiguration:
        _ = try UInt16(parsingBigEndian: &input) // reserved
        return try .setConfiguration(configurationIndex: UInt16(parsingBigEndian: &input))
      case .getConfiguration:
        _ = try UInt16(parsingBigEndian: &input) // reserved
        return try .getConfiguration(configurationIndex: UInt16(parsingBigEndian: &input))
      case .setStreamFormat:
        return try .setStreamFormat(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          streamFormat: StreamFormat(parsing: &input)
        )
      case .getStreamFormat:
        return try .getStreamFormat(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          streamFormat: StreamFormat(parsing: &input)
        )
      case .setStreamInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setStreamInfo(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          streamInfo: StreamInfo(parsing: &input)
        )
      case .getStreamInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getStreamInfo(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          streamInfo: StreamInfo(parsing: &input)
        )
      case .setName:
        return try .setName(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          nameIndex: UInt16(parsingBigEndian: &input),
          configurationIndex: UInt16(parsingBigEndian: &input),
          name: String(parsingAvdeccFixedString: &input)
        )
      case .getName:
        return try .getName(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          nameIndex: UInt16(parsingBigEndian: &input),
          configurationIndex: UInt16(parsingBigEndian: &input),
          name: String(parsingAvdeccFixedString: &input)
        )
      case .setAssociationID:
        return try .setAssociationID(UniqueIdentifier(parsing: &input))
      case .getAssociationID:
        return try .getAssociationID(UniqueIdentifier(parsing: &input))
      case .setSamplingRate:
        return try .setSamplingRate(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          samplingRate: SamplingRate(parsing: &input)
        )
      case .getSamplingRate:
        return try .getSamplingRate(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          samplingRate: SamplingRate(parsing: &input)
        )
      case .setClockSource:
        return try .setClockSource(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          clockSourceIndex: UInt16(parsingBigEndian: &input)
        )
      case .getClockSource:
        return try .getClockSource(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          clockSourceIndex: UInt16(parsingBigEndian: &input)
        )
      case .setControl:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .setControl(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          packedControlValues: [UInt8](parsingRemainingBytes: &input)
        )
      case .getControl:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getControl(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          packedControlValues: [UInt8](parsingRemainingBytes: &input)
        )
      case .startStreaming:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .startStreaming(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .stopStreaming:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .stopStreaming(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .registerUnsolicitedNotification:
        // some entities append data to this response; la_avdecc ignores it, and so do we
        return .registerUnsolicitedNotification
      case .deregisterUnsolicitedNotification:
        return .deregisterUnsolicitedNotification
      case .getAvbInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getAvbInfo(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          avbInfo: AvbInfo(parsing: &input)
        )
      case .getAsPath:
        let descriptorIndex = try UInt16(parsingBigEndian: &input)
        let count = try UInt16(parsingBigEndian: &input)
        try input.requireRemaining(count, of: MemoryLayout<UInt64>.size)
        let sequence = try (0..<count).map { _ in try UniqueIdentifier(parsing: &input) }
        return .getAsPath(descriptorIndex: descriptorIndex, asPath: AsPath(sequence: sequence))
      case .getCounters:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        let countersValid = try UInt32(parsingBigEndian: &input)
        let counters = try (0..<DescriptorCounters.count).map { _ in
          try UInt32(parsingBigEndian: &input)
        }
        return .getCounters(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          countersValid: countersValid,
          counters: DescriptorCounters(counters)
        )
      case .reboot:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .reboot(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getAudioMap:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        let mapIndex = try UInt16(parsingBigEndian: &input)
        let numberOfMaps = try UInt16(parsingBigEndian: &input)
        let numberOfMappings = try UInt16(parsingBigEndian: &input)
        _ = try UInt16(parsingBigEndian: &input) // reserved
        try input.requireRemaining(numberOfMappings, of: AudioMapping.length)
        let mappings = try (0..<numberOfMappings).map { _ in try AudioMapping(parsing: &input) }
        return .getAudioMap(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          mapIndex: mapIndex,
          numberOfMaps: numberOfMaps,
          mappings: mappings
        )
      case .addAudioMappings:
        let (descriptorType, descriptorIndex, mappings) = try _parseAudioMappings(&input)
        return .addAudioMappings(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          mappings: mappings
        )
      case .removeAudioMappings:
        let (descriptorType, descriptorIndex, mappings) = try _parseAudioMappings(&input)
        return .removeAudioMappings(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          mappings: mappings
        )
      case .startOperation:
        return try .startOperation(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          operationID: UInt16(parsingBigEndian: &input),
          operationType: UInt16(parsingBigEndian: &input),
          values: [UInt8](parsingRemainingBytes: &input)
        )
      case .abortOperation:
        return try .abortOperation(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          operationID: UInt16(parsingBigEndian: &input)
        )
      case .operationStatus:
        return try .operationStatus(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          operationID: UInt16(parsingBigEndian: &input),
          percentComplete: UInt16(parsingBigEndian: &input)
        )
      case .setMemoryObjectLength:
        let (configurationIndex, memoryObjectIndex) = try _parseMemoryObjectIndices(&input)
        return try .setMemoryObjectLength(
          configurationIndex: configurationIndex,
          memoryObjectIndex: memoryObjectIndex,
          length: UInt64(parsingBigEndian: &input)
        )
      case .getMemoryObjectLength:
        let (configurationIndex, memoryObjectIndex) = try _parseMemoryObjectIndices(&input)
        return try .getMemoryObjectLength(
          configurationIndex: configurationIndex,
          memoryObjectIndex: memoryObjectIndex,
          length: UInt64(parsingBigEndian: &input)
        )
      case .setMaxTransitTime:
        return try .setMaxTransitTime(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          maxTransitTime: UInt64(parsingBigEndian: &input)
        )
      case .getMaxTransitTime:
        return try .getMaxTransitTime(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          maxTransitTime: UInt64(parsingBigEndian: &input)
        )
      default:
        return .other(commandType: commandTypeRaw, data: [UInt8](parsingRemainingBytes: &input))
      }
    }
  }
}

// MARK: - Shared layouts

private func _parseDescriptor(
  _ input: inout ParserSpan
) throws -> (DescriptorType, DescriptorIndex) {
  try (DescriptorType(parsing: &input), UInt16(parsingBigEndian: &input))
}

private func _parseAudioMappings(
  _ input: inout ParserSpan
) throws -> (DescriptorType, DescriptorIndex, [AudioMapping]) {
  let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
  let numberOfMappings = try UInt16(parsingBigEndian: &input)
  _ = try UInt16(parsingBigEndian: &input) // reserved
  try input.requireRemaining(numberOfMappings, of: AudioMapping.length)
  let mappings = try (0..<numberOfMappings).map { _ in try AudioMapping(parsing: &input) }
  return (descriptorType, descriptorIndex, mappings)
}

private func _serializeAudioMappings(
  _ descriptorType: DescriptorType,
  _ descriptorIndex: DescriptorIndex,
  _ mappings: [AudioMapping],
  into context: inout SerializationContext
) throws {
  try context.serialize(descriptorType)
  context.serialize(uint16: descriptorIndex)
  context.serialize(uint16: UInt16(mappings.count))
  context.serialize(uint16: 0) // reserved
  for mapping in mappings {
    try context.serialize(mapping)
  }
}

// SET/GET_MEMORY_OBJECT_LENGTH put memory_object_index before configuration_index on the wire,
// as la_avdecc (and the devices it interoperates with) do.
private func _parseMemoryObjectIndices(_ input: inout ParserSpan) throws -> (UInt16, UInt16) {
  let memoryObjectIndex = try UInt16(parsingBigEndian: &input)
  let configurationIndex = try UInt16(parsingBigEndian: &input)
  return (configurationIndex, memoryObjectIndex)
}

private func _serializeMemoryObjectIndices(
  _ configurationIndex: UInt16,
  _ memoryObjectIndex: UInt16,
  into context: inout SerializationContext
) {
  context.serialize(uint16: memoryObjectIndex)
  context.serialize(uint16: configurationIndex)
}

// MARK: - Dynamic information

extension StreamInfo {
  /// Parses the fields following descriptor_type and descriptor_index in SET_STREAM_INFO and
  /// GET_STREAM_INFO (IEEE 1722.1-2021 §7.4.16.2), accepting the 1722.1-2013 layout, the Milan
  /// extension and the 1722.1-2021 IP fields (which are skipped).
  init(parsing input: inout ParserSpan) throws {
    // the length of the whole payload, including the descriptor fields already consumed
    let payloadLength = input.count + 4
    streamInfoFlags = try StreamInfoFlags(rawValue: UInt32(parsingBigEndian: &input))
    streamFormat = try StreamFormat(parsing: &input)
    streamID = try UniqueIdentifier(parsing: &input)
    msrpAccumulatedLatency = try UInt32(parsingBigEndian: &input)
    streamDestMac = try _parseMacAddress(&input)
    msrpFailureCode = try UInt8(parsing: &input)
    _ = try UInt8(parsing: &input) // reserved
    msrpFailureBridgeID = try UInt64(parsingBigEndian: &input)
    streamVlanID = try UInt16(parsingBigEndian: &input)
    streamInfoFlagsEx = nil
    probingStatusRaw = nil
    acmpStatusRaw = nil

    if payloadLength >= _ieee2021StreamInfoLength {
      // ip_flags, source_port, destination_port, source_ip_address, destination_ip_address
      _ = try [UInt8](parsing: &input, byteCount: _ieee2021StreamInfoLength - _streamInfoLength + 2)
    } else if payloadLength >= _milanStreamInfoLength {
      _ = try UInt16(parsingBigEndian: &input) // reserved
      streamInfoFlagsEx = try StreamInfoFlagsEx(rawValue: UInt32(parsingBigEndian: &input))
      let probingAcmpStatus = try ProbingAcmpStatus(UInt8(parsing: &input))
      probingStatusRaw = probingAcmpStatus.probingStatusRaw
      acmpStatusRaw = probingAcmpStatus.acmpStatusRaw
      _ = try UInt8(parsing: &input) // reserved
      _ = try UInt16(parsingBigEndian: &input) // reserved
    } else {
      _ = try UInt16(parsingBigEndian: &input) // reserved
    }
  }

  /// Serializes the SET_STREAM_INFO fields following descriptor_type and descriptor_index,
  /// in the 1722.1-2013 layout, which every entity accepts.
  func serialize(into context: inout SerializationContext) throws {
    context.serialize(uint32: streamInfoFlags.rawValue)
    try context.serialize(streamFormat)
    try context.serialize(streamID)
    context.serialize(uint32: msrpAccumulatedLatency)
    context.serialize(macAddress: streamDestMac)
    context.serialize(uint8: msrpFailureCode)
    context.serialize(uint8: 0) // reserved
    context.serialize(uint64: msrpFailureBridgeID)
    context.serialize(uint16: streamVlanID)
    context.serialize(uint16: 0) // reserved
  }
}

extension MsrpMapping {
  // traffic_class, priority, vlan_id
  static let length = 4
}

extension AvbInfo {
  /// Parses the GET_AVB_INFO response fields following descriptor_type and descriptor_index
  /// (IEEE 1722.1-2021 §7.4.40.2).
  init(parsing input: inout ParserSpan) throws {
    gptpGrandmasterID = try UniqueIdentifier(parsing: &input)
    propagationDelay = try UInt32(parsingBigEndian: &input)
    gptpDomainNumber = try UInt8(parsing: &input)
    flags = try AvbInfoFlags(rawValue: UInt8(parsing: &input))
    let msrpMappingsCount = try UInt16(parsingBigEndian: &input)
    try input.requireRemaining(msrpMappingsCount, of: MsrpMapping.length)
    mappings = try (0..<msrpMappingsCount).map { _ in
      try MsrpMapping(
        trafficClass: UInt8(parsing: &input),
        priority: UInt8(parsing: &input),
        vlanID: UInt16(parsingBigEndian: &input)
      )
    }
  }
}
