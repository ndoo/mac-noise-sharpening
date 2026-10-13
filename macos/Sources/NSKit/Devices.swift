import AudioToolbox
import CoreAudio
import Foundation

public struct AudioDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool
}

public enum Devices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr,
              let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    private static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                               hasInput: channels(id, scope: kAudioDevicePropertyScopeInput) > 0,
                               hasOutput: channels(id, scope: kAudioDevicePropertyScopeOutput) > 0)
        }
    }

    public static func blackHole() -> AudioDevice? {
        all().first { $0.hasInput && $0.name.hasPrefix("BlackHole") && $0.name.contains("2ch") }
            ?? all().first { $0.hasInput && $0.name.hasPrefix("BlackHole") }
    }

    public static func defaultOutput() -> AudioDevice? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return nil }
        return all().first { $0.id == id }
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }

    // nil when the device has no settable output volume (e.g. some HDMI/DisplayPort sinks).
    public static func volume(_ id: AudioDeviceID) -> Float? {
        var addr = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    @discardableResult
    public static func setVolume(_ id: AudioDeviceID, _ value: Float) -> Bool {
        var addr = volumeAddress
        var v = Float32(min(max(value, 0), 1))
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    public static func nominalRate(_ id: AudioDeviceID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    @discardableResult
    public static func setNominalRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var r = Float64(rate)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &r) == noErr
    }
}

extension Devices {
    public static func bufferFrames(_ id: AudioDeviceID) -> UInt32? {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &frames) == noErr else { return nil }
        return frames
    }

    // Sets the I/O buffer size, clamped to the range the device supports.
    @discardableResult
    public static func setBufferFrames(_ id: AudioDeviceID, _ frames: UInt32) -> Bool {
        var rangeAddr = address(kAudioDevicePropertyBufferFrameSizeRange)
        var range = AudioValueRange()
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        var wanted = frames
        if AudioObjectGetPropertyData(id, &rangeAddr, 0, nil, &rangeSize, &range) == noErr {
            wanted = min(max(frames, UInt32(range.mMinimum)), UInt32(range.mMaximum))
        }
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &wanted) == noErr
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    public static func muted(_ id: AudioDeviceID) -> Bool? {
        var addr = muteAddress()
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { return nil }
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &m) == noErr else { return nil }
        return m != 0
    }

    @discardableResult
    public static func setMuted(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
        var addr = muteAddress()
        var m: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
    }
}

extension Devices {
    private static func convert(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ input: Float) -> Float? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var v = Float32(input)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    // The conversion properties are inconsistent with each other: ScalarToDecibels takes the
    // hardware scalar, DecibelsToScalar returns the virtual-main-volume scalar (the square of it
    // on built-in speakers). The virtual scalar is what the volume keys and sliders use.
    public static func scalar(forDecibels id: AudioDeviceID, _ db: Float) -> Float? {
        convert(id, kAudioDevicePropertyVolumeDecibelsToScalar, db)
    }

    public static func decibels(forVolume id: AudioDeviceID, _ volume: Float) -> Float? {
        guard let minDB = convert(id, kAudioDevicePropertyVolumeScalarToDecibels, 0),
              let maxDB = convert(id, kAudioDevicePropertyVolumeScalarToDecibels, 1),
              maxDB > minDB else { return nil }
        var lo = minDB, hi = maxDB
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            guard let v = scalar(forDecibels: id, mid) else { return nil }
            if v < volume { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    public static func minDecibels(_ id: AudioDeviceID) -> Float? {
        convert(id, kAudioDevicePropertyVolumeScalarToDecibels, 0)
    }

    public static func maxDecibels(_ id: AudioDeviceID) -> Float? {
        convert(id, kAudioDevicePropertyVolumeScalarToDecibels, 1)
    }
}
