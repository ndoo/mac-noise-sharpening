import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

// Keeps a loopback device at full volume and unmuted, so its own digital attenuation never applies.
public final class UnityPin {
    private var pinned: AudioDeviceID?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init() {}

    deinit { release() }

    public func pin(_ id: AudioDeviceID) {
        if pinned == id { return }
        release()
        pinned = id
        enforce(id)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyMute,
        ]
        for selector in selectors {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.enforce(id) }
            if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr {
                listeners.append((addr, block))
            }
        }
    }

    public func release() {
        if let id = pinned {
            for (addr, block) in listeners {
                var a = addr
                AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
            }
        }
        listeners = []
        pinned = nil
    }

    private func enforce(_ id: AudioDeviceID) {
        if let v = Devices.volume(id), v != 1 { Devices.setVolume(id, 1) }
        if Devices.muted(id) == true { Devices.setMuted(id, false) }
    }
}

public enum VolumeKey { case up, down, mute }

// Consumes the hardware volume keys and passes them to `handler`; a false return passes the key on.
public final class VolumeKeyTap {
    public var handler: ((VolumeKey, _ fine: Bool) -> Bool)?
    private var tap: CFMachPort?

    public init() {}

    public static var trusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    public func start(prompt: Bool) -> Bool {
        if tap != nil { return true }
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return false }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: tapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let code = Int((ns.data1 & 0xFFFF0000) >> 16)
        let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
        let key: VolumeKey
        switch code {
        case 0: key = .up
        case 1: key = .down
        case 7: key = .mute
        default: return false
        }
        // A key-up is consumed only if its key-down was.
        if !down { return consumed.remove(code) != nil }
        let fine = ns.modifierFlags.contains([.shift, .option])
        guard handler?(key, fine) == true else { return false }
        consumed.insert(code)
        return true
    }

    private var consumed = Set<Int>()
}

private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                         _ ref: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let ref else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<VolumeKeyTap>.fromOpaque(ref).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        return Unmanaged.passUnretained(event)
    }
    return tap.handle(event) ? nil : Unmanaged.passUnretained(event)
}
