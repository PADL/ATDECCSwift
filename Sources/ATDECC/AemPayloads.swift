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

// GET_STREAM_INFO response lengths: IEEE 1722.1-2013, Milan before 1.3 (with the extension
// fields) and IEEE 1722.1-2021 and Milan 1.3 (with the IP fields).
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
  /// `valueIndices` are the indices of the control's values to step (IEEE 1722.1-2021 §7.4.27).
  case incrementControl(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, valueIndices: [UInt8])
  case decrementControl(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, valueIndices: [UInt8])
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
  case writeDescriptor(configurationIndex: UInt16, descriptorIndex: DescriptorIndex, descriptor: Descriptor)
  case setStreamBackup(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, backup: StreamBackup)
  case getStreamBackup(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case setSamplingRateRange(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, samplingRateRange: UInt64)
  case getSamplingRateRange(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPathLatency(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case setVideoFormat(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, videoFormat: VideoFormat)
  case getVideoFormat(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case setSensorFormat(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, sensorFormat: UInt64)
  case getSensorFormat(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getVideoMap(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, mapIndex: UInt16)
  case addVideoMappings(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, mappings: [VideoMapping])
  case removeVideoMappings(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, mappings: [VideoMapping])
  case getSensorMap(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, mapIndex: UInt16)
  case addSensorMappings(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, mappings: [SensorMapping])
  case removeSensorMappings(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, mappings: [SensorMapping])
  case setSignalSelector(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, source: SignalSource)
  case getSignalSelector(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  /// `values` is packed as the MIXER descriptor's control_value_type describes (§7.4.31).
  case setMixer(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, values: [UInt8])
  case getMixer(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  /// `values` is packed as the MATRIX descriptor's control_value_type describes (§7.4.33).
  case setMatrix(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    subregion: MatrixSubregion,
    values: [UInt8]
  )
  case getMatrix(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, subregion: MatrixSubregion)
  /// PTP_INSTANCE and PTP_PORT commands (IEEE 1722.1-2021 §7.4.81 to §7.4.101).
  case setPtpInstanceInfo(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, settings: PtpInstanceSettings)
  case setPtpPortInitialIntervals(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, intervals: PtpPortIntervals)
  case setPtpPortRemoteIntervals(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, intervals: PtpPortIntervals)
  case setPtpPortOverrides(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, overrides: PtpPortOverrides)
  case getPtpInstanceInfo(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPtpInstanceExtendedInfo(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPtpInstanceGrandmasterInfo(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPtpInstancePathCount(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPtpInstancePerfMonCount(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPtpPortInitialIntervals(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPtpPortCurrentIntervals(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPtpPortRemoteIntervals(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPtpPortOverrides(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPtpPortPdelayMonCount(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPtpPortPerfMonCount(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex)
  case getPtpInstancePathTrace(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, startIndex: UInt16)
  case getPtpInstancePerfMonRecord(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, recordIndex: UInt16)
  case getPtpPortPdelayMonRecord(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, recordIndex: UInt16)
  case getPtpPortPerfMonRecord(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, recordIndex: UInt16)
  /// Fixed-size GET commands answered together (IEEE 1722.1-2021 §7.4.76).
  case getDynamicInfo(commands: [AemCommandPayload])
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
    case .incrementControl: AemCommandType.incrementControl.rawValue
    case .decrementControl: AemCommandType.decrementControl.rawValue
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
    case .writeDescriptor: AemCommandType.writeDescriptor.rawValue
    case .setStreamBackup: AemCommandType.setStreamBackup.rawValue
    case .getStreamBackup: AemCommandType.getStreamBackup.rawValue
    case .setSamplingRateRange: AemCommandType.setSamplingRateRange.rawValue
    case .getSamplingRateRange: AemCommandType.getSamplingRateRange.rawValue
    case .getPathLatency: AemCommandType.getPathLatency.rawValue
    case .setVideoFormat: AemCommandType.setVideoFormat.rawValue
    case .getVideoFormat: AemCommandType.getVideoFormat.rawValue
    case .setSensorFormat: AemCommandType.setSensorFormat.rawValue
    case .getSensorFormat: AemCommandType.getSensorFormat.rawValue
    case .getVideoMap: AemCommandType.getVideoMap.rawValue
    case .addVideoMappings: AemCommandType.addVideoMappings.rawValue
    case .removeVideoMappings: AemCommandType.removeVideoMappings.rawValue
    case .getSensorMap: AemCommandType.getSensorMap.rawValue
    case .addSensorMappings: AemCommandType.addSensorMappings.rawValue
    case .removeSensorMappings: AemCommandType.removeSensorMappings.rawValue
    case .setSignalSelector: AemCommandType.setSignalSelector.rawValue
    case .getSignalSelector: AemCommandType.getSignalSelector.rawValue
    case .setMixer: AemCommandType.setMixer.rawValue
    case .getMixer: AemCommandType.getMixer.rawValue
    case .setMatrix: AemCommandType.setMatrix.rawValue
    case .getMatrix: AemCommandType.getMatrix.rawValue
    case .setPtpInstanceInfo: AemCommandType.setPtpInstanceInfo.rawValue
    case .setPtpPortInitialIntervals: AemCommandType.setPtpPortInitialIntervals.rawValue
    case .setPtpPortRemoteIntervals: AemCommandType.setPtpPortRemoteIntervals.rawValue
    case .setPtpPortOverrides: AemCommandType.setPtpPortOverrides.rawValue
    case .getPtpInstanceInfo: AemCommandType.getPtpInstanceInfo.rawValue
    case .getPtpInstanceExtendedInfo: AemCommandType.getPtpInstanceExtendedInfo.rawValue
    case .getPtpInstanceGrandmasterInfo: AemCommandType.getPtpInstanceGrandmasterInfo.rawValue
    case .getPtpInstancePathCount: AemCommandType.getPtpInstancePathCount.rawValue
    case .getPtpInstancePerfMonCount: AemCommandType.getPtpInstancePerfMonCount.rawValue
    case .getPtpPortInitialIntervals: AemCommandType.getPtpPortInitialIntervals.rawValue
    case .getPtpPortCurrentIntervals: AemCommandType.getPtpPortCurrentIntervals.rawValue
    case .getPtpPortRemoteIntervals: AemCommandType.getPtpPortRemoteIntervals.rawValue
    case .getPtpPortOverrides: AemCommandType.getPtpPortOverrides.rawValue
    case .getPtpPortPdelayMonCount: AemCommandType.getPtpPortPdelayMonCount.rawValue
    case .getPtpPortPerfMonCount: AemCommandType.getPtpPortPerfMonCount.rawValue
    case .getPtpInstancePathTrace: AemCommandType.getPtpInstancePathTrace.rawValue
    case .getPtpInstancePerfMonRecord: AemCommandType.getPtpInstancePerfMonRecord.rawValue
    case .getPtpPortPdelayMonRecord: AemCommandType.getPtpPortPdelayMonRecord.rawValue
    case .getPtpPortPerfMonRecord: AemCommandType.getPtpPortPerfMonRecord.rawValue
    case .getDynamicInfo: AemCommandType.getDynamicInfo.rawValue
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
      // no flags is sent as IEEE 1722.1-2013 has it, without the field, which means the same
      // (§7.4.37.1) and is the only form an entity predating the field need accept
      if !flags.isEmpty {
        context.serialize(uint32: flags.rawValue)
      }
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
         let .getMaxTransitTime(descriptorType, descriptorIndex),
         let .getStreamBackup(descriptorType, descriptorIndex),
         let .getSamplingRateRange(descriptorType, descriptorIndex),
         let .getPathLatency(descriptorType, descriptorIndex),
         let .getVideoFormat(descriptorType, descriptorIndex),
         let .getSensorFormat(descriptorType, descriptorIndex),
         let .getSignalSelector(descriptorType, descriptorIndex),
         let .getMixer(descriptorType, descriptorIndex),
         let .getPtpInstanceInfo(descriptorType, descriptorIndex),
         let .getPtpInstanceExtendedInfo(descriptorType, descriptorIndex),
         let .getPtpInstanceGrandmasterInfo(descriptorType, descriptorIndex),
         let .getPtpInstancePathCount(descriptorType, descriptorIndex),
         let .getPtpInstancePerfMonCount(descriptorType, descriptorIndex),
         let .getPtpPortInitialIntervals(descriptorType, descriptorIndex),
         let .getPtpPortCurrentIntervals(descriptorType, descriptorIndex),
         let .getPtpPortRemoteIntervals(descriptorType, descriptorIndex),
         let .getPtpPortOverrides(descriptorType, descriptorIndex),
         let .getPtpPortPdelayMonCount(descriptorType, descriptorIndex),
         let .getPtpPortPerfMonCount(descriptorType, descriptorIndex):
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
    case let .incrementControl(descriptorType, descriptorIndex, valueIndices),
         let .decrementControl(descriptorType, descriptorIndex, valueIndices):
      guard valueIndices.count <= Int(UInt16.max) else { throw AvdeccCodecError.valueTooLarge }
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: UInt16(valueIndices.count)) // index_count
      context.serialize(uint16: 0) // reserved
      context.serialize(valueIndices)
    case let .getAsPath(descriptorIndex):
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: 0) // reserved
    case let .getAudioMap(descriptorType, descriptorIndex, mapIndex):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: mapIndex)
      context.serialize(uint16: 0) // reserved
    case let .getVideoMap(descriptorType, descriptorIndex, mapIndex),
         let .getSensorMap(descriptorType, descriptorIndex, mapIndex):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: mapIndex)
      context.serialize(uint16: 0) // reserved
    case let .addAudioMappings(descriptorType, descriptorIndex, mappings),
         let .removeAudioMappings(descriptorType, descriptorIndex, mappings):
      try _serializeMappings(descriptorType, descriptorIndex, mappings, into: &context) { try $1.serialize($0) }
    case let .addVideoMappings(descriptorType, descriptorIndex, mappings),
         let .removeVideoMappings(descriptorType, descriptorIndex, mappings):
      try _serializeMappings(descriptorType, descriptorIndex, mappings, into: &context) { $0.serialize(into: &$1) }
    case let .addSensorMappings(descriptorType, descriptorIndex, mappings),
         let .removeSensorMappings(descriptorType, descriptorIndex, mappings):
      try _serializeMappings(descriptorType, descriptorIndex, mappings, into: &context) { $0.serialize(into: &$1) }
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
    case let .writeDescriptor(configurationIndex, descriptorIndex, descriptor):
      context.serialize(uint16: configurationIndex)
      context.serialize(uint16: 0) // reserved
      try descriptor.serialize(descriptorIndex: descriptorIndex, into: &context)
    case let .setStreamBackup(descriptorType, descriptorIndex, backup):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      try backup.serialize(into: &context)
    case let .setSamplingRateRange(descriptorType, descriptorIndex, samplingRateRange):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint64: samplingRateRange)
    case let .setVideoFormat(descriptorType, descriptorIndex, videoFormat):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      videoFormat.serialize(into: &context)
    case let .setSensorFormat(descriptorType, descriptorIndex, sensorFormat):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint64: sensorFormat)
    case let .setSignalSelector(descriptorType, descriptorIndex, source):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      try source.serialize(into: &context)
      context.serialize(uint16: 0) // reserved
    case let .setMixer(descriptorType, descriptorIndex, values):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(values)
    case let .setMatrix(descriptorType, descriptorIndex, subregion, values):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      try subregion.serialize(into: &context)
      context.serialize(values)
    case let .getMatrix(descriptorType, descriptorIndex, subregion):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      try subregion.serialize(into: &context, repeats: false)
    case let .setPtpInstanceInfo(descriptorType, descriptorIndex, settings):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      settings.serialize(into: &context)
    case let .setPtpPortInitialIntervals(descriptorType, descriptorIndex, intervals):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      intervals.serialize(into: &context)
    case let .setPtpPortRemoteIntervals(descriptorType, descriptorIndex, intervals):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      intervals.serialize(into: &context)
    case let .setPtpPortOverrides(descriptorType, descriptorIndex, overrides):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      overrides.serialize(into: &context)
    case let .getPtpInstancePathTrace(descriptorType, descriptorIndex, index),
         let .getPtpInstancePerfMonRecord(descriptorType, descriptorIndex, index),
         let .getPtpPortPdelayMonRecord(descriptorType, descriptorIndex, index),
         let .getPtpPortPerfMonRecord(descriptorType, descriptorIndex, index):
      try context.serialize(descriptorType)
      context.serialize(uint16: descriptorIndex)
      context.serialize(uint16: index)
      context.serialize(uint16: 0) // reserved
    case let .getDynamicInfo(commands):
      for command in commands {
        let data = try command.serialized()
        guard data.count <= Int(UInt16.max) else { throw AvdeccCodecError.valueTooLarge }
        context.serialize(uint16: UInt16(data.count)) // info_command_specific_data_length
        context.serialize(uint16: 0) // reserved
        context.serialize(uint8: 0) // info_status: SUCCESS in a command
        context.serialize(uint8: 0) // reserved
        context.serialize(uint16: command.commandTypeRaw)
        context.serialize(data)
      }
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
      case .incrementControl:
        let (descriptorType, descriptorIndex, valueIndices) = try _parseControlValueIndices(&input)
        return .incrementControl(descriptorType: descriptorType, descriptorIndex: descriptorIndex, valueIndices: valueIndices)
      case .decrementControl:
        let (descriptorType, descriptorIndex, valueIndices) = try _parseControlValueIndices(&input)
        return .decrementControl(descriptorType: descriptorType, descriptorIndex: descriptorIndex, valueIndices: valueIndices)
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
        let (descriptorType, descriptorIndex, mappings) = try _parseMappings(&input, length: AudioMapping.length) {
          try AudioMapping(parsing: &$0)
        }
        return .addAudioMappings(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          mappings: mappings
        )
      case .removeAudioMappings:
        let (descriptorType, descriptorIndex, mappings) = try _parseMappings(&input, length: AudioMapping.length) {
          try AudioMapping(parsing: &$0)
        }
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
      case .writeDescriptor:
        let (configurationIndex, descriptorIndex, descriptor) = try _parseDescriptorPayload(&input)
        return .writeDescriptor(
          configurationIndex: configurationIndex,
          descriptorIndex: descriptorIndex,
          descriptor: descriptor
        )
      case .setStreamBackup:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setStreamBackup(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          backup: StreamBackup(parsing: &input)
        )
      case .getStreamBackup:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getStreamBackup(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .setSamplingRateRange:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setSamplingRateRange(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          samplingRateRange: UInt64(parsingBigEndian: &input)
        )
      case .getSamplingRateRange:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getSamplingRateRange(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPathLatency:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPathLatency(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .setVideoFormat:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setVideoFormat(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          videoFormat: VideoFormat(parsing: &input)
        )
      case .getVideoFormat:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getVideoFormat(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .setSensorFormat:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setSensorFormat(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          sensorFormat: UInt64(parsingBigEndian: &input)
        )
      case .getSensorFormat:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getSensorFormat(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getVideoMap, .getSensorMap:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        let mapIndex = try UInt16(parsingBigEndian: &input)
        return commandTypeRaw == AemCommandType.getVideoMap.rawValue
          ? .getVideoMap(descriptorType: descriptorType, descriptorIndex: descriptorIndex, mapIndex: mapIndex)
          : .getSensorMap(descriptorType: descriptorType, descriptorIndex: descriptorIndex, mapIndex: mapIndex)
      case .addVideoMappings, .removeVideoMappings:
        let (descriptorType, descriptorIndex, mappings) = try _parseMappings(&input, length: VideoMapping.length) {
          try VideoMapping(parsing: &$0)
        }
        return commandTypeRaw == AemCommandType.addVideoMappings.rawValue
          ? .addVideoMappings(descriptorType: descriptorType, descriptorIndex: descriptorIndex, mappings: mappings)
          : .removeVideoMappings(descriptorType: descriptorType, descriptorIndex: descriptorIndex, mappings: mappings)
      case .addSensorMappings, .removeSensorMappings:
        let (descriptorType, descriptorIndex, mappings) = try _parseMappings(&input, length: SensorMapping.length) {
          try SensorMapping(parsing: &$0)
        }
        return commandTypeRaw == AemCommandType.addSensorMappings.rawValue
          ? .addSensorMappings(descriptorType: descriptorType, descriptorIndex: descriptorIndex, mappings: mappings)
          : .removeSensorMappings(descriptorType: descriptorType, descriptorIndex: descriptorIndex, mappings: mappings)
      case .setSignalSelector:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setSignalSelector(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          source: _parseSignalSelector(&input)
        )
      case .getSignalSelector:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getSignalSelector(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .setMixer:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setMixer(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          values: [UInt8](parsingRemainingBytes: &input)
        )
      case .getMixer:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getMixer(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .setMatrix:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setMatrix(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          subregion: MatrixSubregion(parsing: &input),
          values: [UInt8](parsingRemainingBytes: &input)
        )
      case .getMatrix:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getMatrix(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          subregion: MatrixSubregion(parsing: &input, repeats: false)
        )
      case .setPtpInstanceInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setPtpInstanceInfo(descriptorType: descriptorType, descriptorIndex: descriptorIndex, settings: PtpInstanceSettings(parsing: &input))
      case .setPtpPortInitialIntervals:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setPtpPortInitialIntervals(descriptorType: descriptorType, descriptorIndex: descriptorIndex, intervals: PtpPortIntervals(parsing: &input))
      case .setPtpPortRemoteIntervals:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setPtpPortRemoteIntervals(descriptorType: descriptorType, descriptorIndex: descriptorIndex, intervals: PtpPortIntervals(parsing: &input))
      case .setPtpPortOverrides:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setPtpPortOverrides(descriptorType: descriptorType, descriptorIndex: descriptorIndex, overrides: PtpPortOverrides(parsing: &input))
      case .getPtpInstanceInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPtpInstanceInfo(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPtpInstanceExtendedInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPtpInstanceExtendedInfo(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPtpInstanceGrandmasterInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPtpInstanceGrandmasterInfo(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPtpInstancePathCount:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPtpInstancePathCount(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPtpInstancePerfMonCount:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPtpInstancePerfMonCount(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPtpPortInitialIntervals:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPtpPortInitialIntervals(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPtpPortCurrentIntervals:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPtpPortCurrentIntervals(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPtpPortRemoteIntervals:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPtpPortRemoteIntervals(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPtpPortOverrides:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPtpPortOverrides(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPtpPortPdelayMonCount:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPtpPortPdelayMonCount(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPtpPortPerfMonCount:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .getPtpPortPerfMonCount(descriptorType: descriptorType, descriptorIndex: descriptorIndex)
      case .getPtpInstancePathTrace:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpInstancePathTrace(descriptorType: descriptorType, descriptorIndex: descriptorIndex, startIndex: UInt16(parsingBigEndian: &input))
      case .getPtpInstancePerfMonRecord:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpInstancePerfMonRecord(descriptorType: descriptorType, descriptorIndex: descriptorIndex, recordIndex: UInt16(parsingBigEndian: &input))
      case .getPtpPortPdelayMonRecord:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpPortPdelayMonRecord(descriptorType: descriptorType, descriptorIndex: descriptorIndex, recordIndex: UInt16(parsingBigEndian: &input))
      case .getPtpPortPerfMonRecord:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpPortPerfMonRecord(descriptorType: descriptorType, descriptorIndex: descriptorIndex, recordIndex: UInt16(parsingBigEndian: &input))
      case .getDynamicInfo:
        return try .getDynamicInfo(commands: _parseDynamicInfos(&input).map {
          try AemCommandPayload(commandTypeRaw: $0.commandTypeRaw, data: $0.data)
        })
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
  case entityAvailable(EntityAvailability)
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
  case incrementControl(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    packedControlValues: [UInt8]
  )
  case decrementControl(
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
  /// The descriptor as the entity holds it after the command.
  case writeDescriptor(configurationIndex: UInt16, descriptorIndex: DescriptorIndex, descriptor: Descriptor)
  case setStreamBackup(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, backup: StreamBackup)
  case getStreamBackup(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, backup: StreamBackup)
  case setSamplingRateRange(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, samplingRateRange: UInt64)
  case getSamplingRateRange(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, samplingRateRange: UInt64)
  /// `pathLatency` is in nanoseconds.
  case getPathLatency(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, pathLatency: UInt32)
  case setVideoFormat(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, videoFormat: VideoFormat)
  case getVideoFormat(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, videoFormat: VideoFormat)
  case setSensorFormat(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, sensorFormat: UInt64)
  case getSensorFormat(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, sensorFormat: UInt64)
  case getVideoMap(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    mapIndex: UInt16,
    numberOfMaps: UInt16,
    mappings: [VideoMapping]
  )
  case addVideoMappings(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, mappings: [VideoMapping])
  case removeVideoMappings(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, mappings: [VideoMapping])
  case getSensorMap(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    mapIndex: UInt16,
    numberOfMaps: UInt16,
    mappings: [SensorMapping]
  )
  case addSensorMappings(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, mappings: [SensorMapping])
  case removeSensorMappings(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, mappings: [SensorMapping])
  case setSignalSelector(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, source: SignalSource)
  case getSignalSelector(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, source: SignalSource)
  case setMixer(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, values: [UInt8])
  case getMixer(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, values: [UInt8])
  case setMatrix(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    subregion: MatrixSubregion,
    values: [UInt8]
  )
  case getMatrix(
    descriptorType: DescriptorType,
    descriptorIndex: DescriptorIndex,
    subregion: MatrixSubregion,
    values: [UInt8]
  )
  case setPtpInstanceInfo(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, settings: PtpInstanceSettings)
  case getPtpInstanceInfo(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, info: PtpInstanceInfo)
  case getPtpInstanceExtendedInfo(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, info: PtpInstanceExtendedInfo)
  case getPtpInstanceGrandmasterInfo(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, info: PtpGrandmasterInfo)
  case getPtpInstancePerfMonCount(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, counts: PtpPerfMonCounts)
  case getPtpInstancePerfMonRecord(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, record: PtpInstancePerfMonRecord)
  case setPtpPortInitialIntervals(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, intervals: PtpPortIntervals)
  case getPtpPortInitialIntervals(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, intervals: PtpPortIntervals)
  case getPtpPortCurrentIntervals(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, intervals: PtpPortIntervals)
  case setPtpPortRemoteIntervals(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, intervals: PtpPortIntervals)
  case getPtpPortRemoteIntervals(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, intervals: PtpPortIntervals)
  case setPtpPortOverrides(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, overrides: PtpPortOverrides)
  case getPtpPortOverrides(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, overrides: PtpPortOverrides)
  case getPtpPortPdelayMonCount(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, counts: PtpPerfMonCounts)
  case getPtpPortPdelayMonRecord(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, record: PtpPortPdelayMonRecord)
  case getPtpPortPerfMonCount(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, counts: PtpPerfMonCounts)
  case getPtpPortPerfMonRecord(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, record: PtpPortPerfMonRecord)
  case getPtpInstancePathCount(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, traceCount: UInt16)
  /// ClockIdentities of pathTraceDS.list from `startIndex`, as many as fit in the response.
  case getPtpInstancePathTrace(descriptorType: DescriptorType, descriptorIndex: DescriptorIndex, startIndex: UInt16, pathTrace: [UniqueIdentifier])
  case getDynamicInfo([DynamicInfo])
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
        // IEEE 1722.1-2013 entities, like la_avdecc, send no payload
        guard input.count >= 20 else { return .entityAvailable(EntityAvailability()) }
        return try .entityAvailable(EntityAvailability(
          flags: EntityAvailableFlags(rawValue: UInt32(parsingBigEndian: &input)),
          acquiredControllerID: UniqueIdentifier(parsing: &input),
          lockedControllerID: UniqueIdentifier(parsing: &input)
        ))
      case .controllerAvailable:
        return .controllerAvailable
      case .readDescriptor:
        let (configurationIndex, descriptorIndex, descriptor) = try _parseDescriptorPayload(&input)
        return .readDescriptor(
          configurationIndex: configurationIndex,
          descriptorIndex: descriptorIndex,
          descriptor: descriptor
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
      case .incrementControl:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .incrementControl(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          packedControlValues: [UInt8](parsingRemainingBytes: &input)
        )
      case .decrementControl:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return .decrementControl(
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
        var counters = DescriptorCounters.Counters(repeating: 0)
        for index in counters.indices {
          counters[index] = try UInt32(parsingBigEndian: &input)
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
        let mappings = try _parseMappingArray(&input, count: numberOfMappings, length: AudioMapping.length) {
          try AudioMapping(parsing: &$0)
        }
        return .getAudioMap(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          mapIndex: mapIndex,
          numberOfMaps: numberOfMaps,
          mappings: mappings
        )
      case .addAudioMappings:
        let (descriptorType, descriptorIndex, mappings) = try _parseMappings(&input, length: AudioMapping.length) {
          try AudioMapping(parsing: &$0)
        }
        return .addAudioMappings(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          mappings: mappings
        )
      case .removeAudioMappings:
        let (descriptorType, descriptorIndex, mappings) = try _parseMappings(&input, length: AudioMapping.length) {
          try AudioMapping(parsing: &$0)
        }
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
      case .writeDescriptor:
        let (configurationIndex, descriptorIndex, descriptor) = try _parseDescriptorPayload(&input)
        return .writeDescriptor(
          configurationIndex: configurationIndex,
          descriptorIndex: descriptorIndex,
          descriptor: descriptor
        )
      case .setStreamBackup:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setStreamBackup(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          backup: StreamBackup(parsing: &input)
        )
      case .getStreamBackup:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getStreamBackup(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          backup: StreamBackup(parsing: &input)
        )
      case .setSamplingRateRange:
        return try .setSamplingRateRange(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          samplingRateRange: UInt64(parsingBigEndian: &input)
        )
      case .getSamplingRateRange:
        return try .getSamplingRateRange(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          samplingRateRange: UInt64(parsingBigEndian: &input)
        )
      case .getPathLatency:
        return try .getPathLatency(
          descriptorType: DescriptorType(parsing: &input),
          descriptorIndex: UInt16(parsingBigEndian: &input),
          pathLatency: UInt32(parsingBigEndian: &input)
        )
      case .setVideoFormat, .getVideoFormat:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        let videoFormat = try VideoFormat(parsing: &input)
        return commandTypeRaw == AemCommandType.setVideoFormat.rawValue
          ? .setVideoFormat(descriptorType: descriptorType, descriptorIndex: descriptorIndex, videoFormat: videoFormat)
          : .getVideoFormat(descriptorType: descriptorType, descriptorIndex: descriptorIndex, videoFormat: videoFormat)
      case .setSensorFormat, .getSensorFormat:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        let sensorFormat = try UInt64(parsingBigEndian: &input)
        return commandTypeRaw == AemCommandType.setSensorFormat.rawValue
          ? .setSensorFormat(descriptorType: descriptorType, descriptorIndex: descriptorIndex, sensorFormat: sensorFormat)
          : .getSensorFormat(descriptorType: descriptorType, descriptorIndex: descriptorIndex, sensorFormat: sensorFormat)
      case .getVideoMap, .getSensorMap:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        let mapIndex = try UInt16(parsingBigEndian: &input)
        let numberOfMaps = try UInt16(parsingBigEndian: &input)
        let numberOfMappings = try UInt16(parsingBigEndian: &input)
        _ = try UInt16(parsingBigEndian: &input) // reserved
        if commandTypeRaw == AemCommandType.getVideoMap.rawValue {
          return try .getVideoMap(
            descriptorType: descriptorType,
            descriptorIndex: descriptorIndex,
            mapIndex: mapIndex,
            numberOfMaps: numberOfMaps,
            mappings: _parseMappingArray(&input, count: numberOfMappings, length: VideoMapping.length) {
              try VideoMapping(parsing: &$0)
            }
          )
        }
        return try .getSensorMap(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          mapIndex: mapIndex,
          numberOfMaps: numberOfMaps,
          mappings: _parseMappingArray(&input, count: numberOfMappings, length: SensorMapping.length) {
            try SensorMapping(parsing: &$0)
          }
        )
      case .addVideoMappings, .removeVideoMappings:
        let (descriptorType, descriptorIndex, mappings) = try _parseMappings(&input, length: VideoMapping.length) {
          try VideoMapping(parsing: &$0)
        }
        return commandTypeRaw == AemCommandType.addVideoMappings.rawValue
          ? .addVideoMappings(descriptorType: descriptorType, descriptorIndex: descriptorIndex, mappings: mappings)
          : .removeVideoMappings(descriptorType: descriptorType, descriptorIndex: descriptorIndex, mappings: mappings)
      case .addSensorMappings, .removeSensorMappings:
        let (descriptorType, descriptorIndex, mappings) = try _parseMappings(&input, length: SensorMapping.length) {
          try SensorMapping(parsing: &$0)
        }
        return commandTypeRaw == AemCommandType.addSensorMappings.rawValue
          ? .addSensorMappings(descriptorType: descriptorType, descriptorIndex: descriptorIndex, mappings: mappings)
          : .removeSensorMappings(descriptorType: descriptorType, descriptorIndex: descriptorIndex, mappings: mappings)
      case .setSignalSelector, .getSignalSelector:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        let source = try _parseSignalSelector(&input)
        return commandTypeRaw == AemCommandType.setSignalSelector.rawValue
          ? .setSignalSelector(descriptorType: descriptorType, descriptorIndex: descriptorIndex, source: source)
          : .getSignalSelector(descriptorType: descriptorType, descriptorIndex: descriptorIndex, source: source)
      case .setMixer, .getMixer:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        let values = [UInt8](parsingRemainingBytes: &input)
        return commandTypeRaw == AemCommandType.setMixer.rawValue
          ? .setMixer(descriptorType: descriptorType, descriptorIndex: descriptorIndex, values: values)
          : .getMixer(descriptorType: descriptorType, descriptorIndex: descriptorIndex, values: values)
      case .setMatrix, .getMatrix:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        let subregion = try MatrixSubregion(parsing: &input, repeats: commandTypeRaw == AemCommandType.setMatrix.rawValue ? nil : false)
        let values = [UInt8](parsingRemainingBytes: &input)
        return commandTypeRaw == AemCommandType.setMatrix.rawValue
          ? .setMatrix(descriptorType: descriptorType, descriptorIndex: descriptorIndex, subregion: subregion, values: values)
          : .getMatrix(descriptorType: descriptorType, descriptorIndex: descriptorIndex, subregion: subregion, values: values)
      case .setPtpInstanceInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setPtpInstanceInfo(descriptorType: descriptorType, descriptorIndex: descriptorIndex, settings: PtpInstanceSettings(parsing: &input))
      case .getPtpInstanceInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpInstanceInfo(descriptorType: descriptorType, descriptorIndex: descriptorIndex, info: PtpInstanceInfo(parsing: &input))
      case .getPtpInstanceExtendedInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpInstanceExtendedInfo(descriptorType: descriptorType, descriptorIndex: descriptorIndex, info: PtpInstanceExtendedInfo(parsing: &input))
      case .getPtpInstanceGrandmasterInfo:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpInstanceGrandmasterInfo(descriptorType: descriptorType, descriptorIndex: descriptorIndex, info: PtpGrandmasterInfo(parsing: &input))
      case .getPtpInstancePerfMonCount:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpInstancePerfMonCount(descriptorType: descriptorType, descriptorIndex: descriptorIndex, counts: PtpPerfMonCounts(parsing: &input))
      case .getPtpInstancePerfMonRecord:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpInstancePerfMonRecord(descriptorType: descriptorType, descriptorIndex: descriptorIndex, record: PtpInstancePerfMonRecord(parsing: &input))
      case .setPtpPortInitialIntervals:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setPtpPortInitialIntervals(descriptorType: descriptorType, descriptorIndex: descriptorIndex, intervals: PtpPortIntervals(parsing: &input))
      case .getPtpPortInitialIntervals:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpPortInitialIntervals(descriptorType: descriptorType, descriptorIndex: descriptorIndex, intervals: PtpPortIntervals(parsing: &input))
      case .getPtpPortCurrentIntervals:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpPortCurrentIntervals(descriptorType: descriptorType, descriptorIndex: descriptorIndex, intervals: PtpPortIntervals(parsing: &input))
      case .setPtpPortRemoteIntervals:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setPtpPortRemoteIntervals(descriptorType: descriptorType, descriptorIndex: descriptorIndex, intervals: PtpPortIntervals(parsing: &input))
      case .getPtpPortRemoteIntervals:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpPortRemoteIntervals(descriptorType: descriptorType, descriptorIndex: descriptorIndex, intervals: PtpPortIntervals(parsing: &input))
      case .setPtpPortOverrides:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .setPtpPortOverrides(descriptorType: descriptorType, descriptorIndex: descriptorIndex, overrides: PtpPortOverrides(parsing: &input))
      case .getPtpPortOverrides:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpPortOverrides(descriptorType: descriptorType, descriptorIndex: descriptorIndex, overrides: PtpPortOverrides(parsing: &input))
      case .getPtpPortPdelayMonCount:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpPortPdelayMonCount(descriptorType: descriptorType, descriptorIndex: descriptorIndex, counts: PtpPerfMonCounts(parsing: &input))
      case .getPtpPortPdelayMonRecord:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpPortPdelayMonRecord(descriptorType: descriptorType, descriptorIndex: descriptorIndex, record: PtpPortPdelayMonRecord(parsing: &input))
      case .getPtpPortPerfMonCount:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpPortPerfMonCount(descriptorType: descriptorType, descriptorIndex: descriptorIndex, counts: PtpPerfMonCounts(parsing: &input))
      case .getPtpPortPerfMonRecord:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        return try .getPtpPortPerfMonRecord(descriptorType: descriptorType, descriptorIndex: descriptorIndex, record: PtpPortPerfMonRecord(parsing: &input))
      case .getPtpInstancePathCount:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        _ = try UInt16(parsingBigEndian: &input) // reserved
        return try .getPtpInstancePathCount(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          traceCount: UInt16(parsingBigEndian: &input)
        )
      case .getPtpInstancePathTrace:
        let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
        let startIndex = try UInt16(parsingBigEndian: &input)
        let entryCount = try UInt16(parsingBigEndian: &input)
        return try .getPtpInstancePathTrace(
          descriptorType: descriptorType,
          descriptorIndex: descriptorIndex,
          startIndex: startIndex,
          pathTrace: _parseMappingArray(&input, count: entryCount, length: 8) { try UniqueIdentifier(parsing: &$0) }
        )
      case .getDynamicInfo:
        return try .getDynamicInfo(_parseDynamicInfos(&input).map {
          DynamicInfo(commandTypeRaw: $0.commandTypeRaw, statusRaw: $0.statusRaw, data: $0.data)
        })
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

/// descriptor_type, descriptor_index, number_of_mappings, reserved and the mappings of
/// ADD/REMOVE_AUDIO_MAPPINGS, ADD/REMOVE_VIDEO_MAPPINGS and ADD/REMOVE_SENSOR_MAPPINGS (Figure 7-71).
private func _parseMappings<Mapping>(
  _ input: inout ParserSpan,
  length: Int,
  _ parse: (inout ParserSpan) throws -> Mapping
) throws -> (DescriptorType, DescriptorIndex, [Mapping]) {
  let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
  let numberOfMappings = try UInt16(parsingBigEndian: &input)
  _ = try UInt16(parsingBigEndian: &input) // reserved
  return try (descriptorType, descriptorIndex, _parseMappingArray(&input, count: numberOfMappings, length: length, parse))
}

private func _parseMappingArray<Mapping>(
  _ input: inout ParserSpan,
  count: UInt16,
  length: Int,
  _ parse: (inout ParserSpan) throws -> Mapping
) throws -> [Mapping] {
  try input.requireRemaining(count, of: length)
  return try (0..<count).map { _ in try parse(&input) }
}

private func _serializeMappings<Mapping>(
  _ descriptorType: DescriptorType,
  _ descriptorIndex: DescriptorIndex,
  _ mappings: [Mapping],
  into context: inout SerializationContext,
  _ serialize: (Mapping, inout SerializationContext) throws -> Void
) throws {
  guard mappings.count <= Int(UInt16.max) else { throw AvdeccCodecError.valueTooLarge }
  try context.serialize(descriptorType)
  context.serialize(uint16: descriptorIndex)
  context.serialize(uint16: UInt16(mappings.count))
  context.serialize(uint16: 0) // reserved
  for mapping in mappings {
    try serialize(mapping, &context)
  }
}

/// signal_type, signal_index, signal_output and reserved of SET/GET_SIGNAL_SELECTOR (Figure 7-52).
private func _parseSignalSelector(_ input: inout ParserSpan) throws -> SignalSource {
  let source = try SignalSource(parsing: &input)
  _ = try UInt16(parsingBigEndian: &input) // reserved
  return source
}

/// One element of a GET_DYNAMIC_INFO response's dynamic_infos (IEEE 1722.1-2021 §7.4.76.1). An
/// entity leaves out a response that would overflow the AECPDU, so match elements to commands by
/// their contents rather than position.
public struct DynamicInfo: Sendable, Hashable {
  public let commandTypeRaw: UInt16
  public let statusRaw: UInt8
  /// The embedded response's command_specific_data.
  public let data: [UInt8]

  public init(commandTypeRaw: UInt16, statusRaw: UInt8, data: [UInt8]) {
    self.commandTypeRaw = commandTypeRaw
    self.statusRaw = statusRaw
    self.data = data
  }

  public var commandType: AemCommandType {
    AemCommandType(rawValue: commandTypeRaw) ?? .invalidCommandType
  }

  public var status: AemStatus {
    AemStatus(UInt16(statusRaw))
  }

  /// The embedded response, when it succeeded and decodes.
  public var response: AemResponsePayload? {
    guard status == .success else { return nil }
    return try? AemResponsePayload(commandTypeRaw: commandTypeRaw, data: data)
  }
}

// dynamic_info: info_command_specific_data_length, reserved, info_status, reserved,
// info_command_type and info_command_specific_data (IEEE 1722.1-2021 Figure 7-94), to the end of
// the payload.
private func _parseDynamicInfos(
  _ input: inout ParserSpan
) throws -> [(commandTypeRaw: UInt16, statusRaw: UInt8, data: [UInt8])] {
  var infos = [(commandTypeRaw: UInt16, statusRaw: UInt8, data: [UInt8])]()
  while input.count > 0 {
    let length = try UInt16(parsingBigEndian: &input)
    _ = try UInt16(parsingBigEndian: &input) // reserved
    let statusRaw = try UInt8(parsing: &input)
    _ = try UInt8(parsing: &input) // reserved
    let commandTypeRaw = try UInt16(parsingBigEndian: &input)
    infos.append((commandTypeRaw, statusRaw, try [UInt8](parsing: &input, byteCount: Int(length))))
  }
  return infos
}

// READ_DESCRIPTOR's response and WRITE_DESCRIPTOR (IEEE 1722.1-2021 Figures 7-31 and 7-32):
// configuration_index, reserved, then a whole descriptor, whose offsets count from its
// descriptor_type, so it is given its own origin.
private func _parseDescriptorPayload(
  _ input: inout ParserSpan
) throws -> (UInt16, DescriptorIndex, Descriptor) {
  let configurationIndex = try UInt16(parsingBigEndian: &input)
  _ = try UInt16(parsingBigEndian: &input) // reserved
  var descriptorInput = input.extractRemaining()
  let descriptorTypeRaw = try UInt16(parsingBigEndian: &descriptorInput)
  let descriptorIndex = try UInt16(parsingBigEndian: &descriptorInput)
  let descriptor = try Descriptor(descriptorTypeRaw: descriptorTypeRaw, parsingBody: &descriptorInput)
  return (configurationIndex, descriptorIndex, descriptor)
}

// INCREMENT/DECREMENT_CONTROL: descriptor, index_count, reserved and index_count value indices
// (IEEE 1722.1-2021 Figure 7-51).
private func _parseControlValueIndices(
  _ input: inout ParserSpan
) throws -> (DescriptorType, DescriptorIndex, [UInt8]) {
  let (descriptorType, descriptorIndex) = try _parseDescriptor(&input)
  let indexCount = try UInt16(parsingBigEndian: &input)
  _ = try UInt16(parsingBigEndian: &input) // reserved
  return (descriptorType, descriptorIndex, try [UInt8](parsing: &input, byteCount: Int(indexCount)))
}

// SET/GET_MEMORY_OBJECT_LENGTH put the memory object's descriptor_index before
// configuration_index (IEEE 1722.1-2021 Figure 7-90), as la_avdecc does.
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
  /// extension and the 1722.1-2021 IP fields.
  init(parsing input: inout ParserSpan) throws {
    // the length of the whole payload, including the descriptor fields already consumed
    let payloadLength = input.count + 4
    streamInfoFlags = try StreamInfoFlags(rawValue: UInt32(parsingBigEndian: &input))
    streamFormat = try StreamFormat(parsing: &input)
    streamID = try UniqueIdentifier(parsing: &input)
    msrpAccumulatedLatency = try UInt32(parsingBigEndian: &input)
    streamDestMac = try _eui48(parsing: &input)
    msrpFailureCode = try UInt8(parsing: &input)
    _ = try UInt8(parsing: &input) // reserved
    msrpFailureBridgeID = try UInt64(parsingBigEndian: &input)
    streamVlanID = try UInt16(parsingBigEndian: &input)
    streamInfoFlagsEx = nil
    probingStatusRaw = nil
    acmpStatusRaw = nil
    layout = .ieee1722_1_2013
    ipFlags = 0
    sourcePort = 0
    destinationPort = 0
    sourceIPAddress = [UInt8](repeating: 0, count: 16)
    destinationIPAddress = [UInt8](repeating: 0, count: 16)

    if payloadLength >= _ieee2021StreamInfoLength {
      // ip_flags takes the place of the 1722.1-2013 reserved field (Figure 7-40)
      layout = .ieee1722_1_2021
      ipFlags = try UInt16(parsingBigEndian: &input)
      sourcePort = try UInt16(parsingBigEndian: &input)
      destinationPort = try UInt16(parsingBigEndian: &input)
      sourceIPAddress = try [UInt8](parsing: &input, byteCount: 16)
      destinationIPAddress = try [UInt8](parsing: &input, byteCount: 16)
    } else if payloadLength >= _milanStreamInfoLength {
      layout = .milanBefore1_3
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

  /// The flags a SET_STREAM_INFO command carries: the ACMP flags of the lower 16 bits apart from
  /// SAVED_STATE and STREAMING_WAIT, which are not settable (IEEE 1722.1-2021 §7.4.15.1), and
  /// TALKER_FAILED, which reports state; and the flags marking a field of the 1722.1-2013 layout.
  static let commandFlags: StreamInfoFlags = [
    .classB, .fastConnect, .supportsEncrypted, .encryptedPdu, .noSrp,
    .streamVlanIDValid, .streamDestMacValid, .msrpAccLatValid, .streamIDValid, .streamFormatValid,
  ]

  /// The flags marking the IEEE 1722.1-2021 IP fields.
  static let ipFieldFlags: StreamInfoFlags = [
    .ipFlagsValid, .ipSrcPortValid, .ipDstPortValid, .ipSrcAddrValid, .ipDstAddrValid,
  ]

  /// Serializes the SET_STREAM_INFO fields following descriptor_type and descriptor_index,
  /// in the 1722.1-2013 layout, which every entity accepts, or with the IP fields when one of
  /// their flags is set. Response-only flags are dropped and the MSRP failure fields are zero
  /// (IEEE 1722.1-2021 §7.4.15.1); the latency is sent only with MSRP_ACC_LAT_VALID, which
  /// Milan 1.3 entities reject (Milan 1.3 §5.4.2.9).
  func serialize(into context: inout SerializationContext) throws {
    let hasIPFields = !streamInfoFlags.isDisjoint(with: Self.ipFieldFlags)
    let flags = streamInfoFlags.intersection(
      hasIPFields ? Self.commandFlags.union(Self.ipFieldFlags) : Self.commandFlags
    )
    context.serialize(uint32: flags.rawValue)
    try context.serialize(streamFormat)
    try context.serialize(streamID)
    context.serialize(uint32: flags.contains(.msrpAccLatValid) ? msrpAccumulatedLatency : 0)
    context.serialize(eui48: streamDestMac)
    context.serialize(uint8: 0) // msrp_failure_code
    context.serialize(uint8: 0) // reserved
    context.serialize(uint64: 0) // msrp_failure_bridge_id
    context.serialize(uint16: streamVlanID)
    guard hasIPFields else {
      context.serialize(uint16: 0) // reserved
      return
    }
    guard sourceIPAddress.count == 16, destinationIPAddress.count == 16 else {
      throw AvdeccCodecError.valueTooLarge
    }
    context.serialize(uint16: ipFlags)
    context.serialize(uint16: sourcePort)
    context.serialize(uint16: destinationPort)
    context.serialize(sourceIPAddress)
    context.serialize(destinationIPAddress)
  }
}

extension StreamBackup {
  /// Parses the talkers following descriptor_type and descriptor_index (IEEE 1722.1-2021
  /// Figure 7-92), each an Entity ID, a unique ID and a reserved word.
  init(parsing input: inout ParserSpan) throws {
    func talker() throws -> StreamIdentification {
      let talker = try StreamIdentification(
        entityID: UniqueIdentifier(parsing: &input),
        streamIndex: UInt16(parsingBigEndian: &input)
      )
      _ = try UInt16(parsingBigEndian: &input) // reserved
      return talker
    }
    backupTalker0 = try talker()
    backupTalker1 = try talker()
    backupTalker2 = try talker()
    backedUpTalker = try talker()
  }

  func serialize(into context: inout SerializationContext) throws {
    for talker in [backupTalker0, backupTalker1, backupTalker2, backedUpTalker] {
      try context.serialize(talker.entityID)
      context.serialize(uint16: talker.streamIndex)
      context.serialize(uint16: 0) // reserved
    }
  }
}

extension VideoFormat {
  init(parsing input: inout ParserSpan) throws {
    formatSpecific = try UInt32(parsingBigEndian: &input)
    aspectRatio = try UInt16(parsingBigEndian: &input)
    colorSpace = try UInt16(parsingBigEndian: &input)
    frameSize = try UInt32(parsingBigEndian: &input)
  }

  func serialize(into context: inout SerializationContext) {
    context.serialize(uint32: formatSpecific)
    context.serialize(uint16: aspectRatio)
    context.serialize(uint16: colorSpace)
    context.serialize(uint32: frameSize)
  }
}

extension MatrixSubregion {
  /// `repeats` overrides the rep bit, which GET_MATRIX reserves.
  init(parsing input: inout ParserSpan, repeats: Bool? = nil) throws {
    column = try UInt16(parsingBigEndian: &input)
    row = try UInt16(parsingBigEndian: &input)
    width = try UInt16(parsingBigEndian: &input)
    height = try UInt16(parsingBigEndian: &input)
    let bits = try UInt16(parsingBigEndian: &input)
    self.repeats = repeats ?? (bits & 0x8000 != 0)
    direction = MatrixDirection(rawValue: UInt8((bits >> 12) & 0x7))
    valueCount = bits & 0x0FFF
    itemOffset = try UInt16(parsingBigEndian: &input)
  }

  func serialize(into context: inout SerializationContext, repeats: Bool? = nil) throws {
    guard direction.rawValue <= 0x7, valueCount <= 0x0FFF else { throw AvdeccCodecError.valueTooLarge }
    context.serialize(uint16: column)
    context.serialize(uint16: row)
    context.serialize(uint16: width)
    context.serialize(uint16: height)
    let rep: UInt16 = (repeats ?? self.repeats) ? 0x8000 : 0
    context.serialize(uint16: rep | UInt16(direction.rawValue) << 12 | valueCount)
    context.serialize(uint16: itemOffset)
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
