import Foundation
import CoreAudio
import os.log

/// A user-selectable audio output device.
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
}

/// Thin, synchronous wrappers around AudioObject property queries.
/// All functions are safe to call from any non-realtime thread.
public enum AudioDeviceUtils {

    private static let logger = Logger(subsystem: "com.sonarforge.audio", category: "DeviceManagement")

    /// SonarForge's own private aggregate device, created while the engine runs.
    /// Excluded from the output picker — routing output into our capture device
    /// makes no sense. Keep these in sync with `SonarForgeAudioEngine`.
    public static let privateAggregateUID = "com.sonarforge.aggregate"
    public static let privateAggregateName = "SonarForge"

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: - Default / enumeration

    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            logger.error("Failed to get default output device (OSStatus: \(status))")
            return nil
        }
        return deviceID
    }

    /// All devices that have at least one output channel, suitable for the output
    /// picker. Our own private aggregate is filtered out (the HAL does list it
    /// while the engine runs, despite the "private" flag).
    public static func allOutputDevices() -> [AudioOutputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceIDs)
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { id in
            guard outputChannelCount(id) > 0,
                  let uid = deviceUID(id),
                  let name = deviceName(id),
                  uid != privateAggregateUID, name != privateAggregateName else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name)
        }
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allOutputDevices().first(where: { $0.uid == uid })?.id
    }

    /// Invokes `handler` (on `queue`, default main) whenever the set of hardware
    /// audio devices changes — plugged in, removed, or our aggregate appearing or
    /// disappearing. Retain the returned block to keep the listener alive.
    @discardableResult
    public static func addDeviceListChangeListener(queue: DispatchQueue = .main,
                                                   _ handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var addr = address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        if status != noErr {
            logger.error("Failed to observe device-list changes (OSStatus: \(status))")
        }
        return block
    }

    // MARK: - Per-device properties

    public static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        copyStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    public static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        copyStringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    public static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    public static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }

        let ablMemory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablMemory.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ablMemory)
        guard status == noErr else { return 0 }

        let abl = UnsafeMutableAudioBufferListPointer(ablMemory.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    // MARK: - Private

    private static func copyStringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}
