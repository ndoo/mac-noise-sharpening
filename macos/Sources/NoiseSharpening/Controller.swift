import AppKit
import AudioToolbox
import CNoiseSharpening
import CoreAudio
import Foundation
import NSKit

final class Controller: ObservableObject {
    let settings = Prefs()
    let engine = AudioEngine()
    @Published var error: String?
    @Published var devices: [AudioDevice] = []
    @Published var volume: Float?
    @Published var keysActive = false
    @Published var limited = false
    @Published var muted = false
    @Published var blackHoleMissing = false
    private let unityPin = UnityPin()
    private let keyTap = VolumeKeyTap()
    private let hud = VolumeHUD()
    private var keyTimer: Timer?
    private var volumeDevice: AudioDevice?
    private var lastApplied: Float?
    // Loudness the user chose, in dB at the device with no compensation. The device is set to
    // level + compensation, clamped to its range. Only user actions change the level, so the
    // same settings always produce the same display.
    private var levelDB: Float?
    private var deviceRange: ClosedRange<Float> = -64...0
    private static let silentDB: Float = -1000
    private var volumeListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        settings.onChange = { [weak self] in self?.apply() }
        settings.onDeviceChange = { [weak self] in self?.restart() }
        apply()
        restart()
        keyTap.handler = { [weak self] key, fine in self?.handleKey(key, fine: fine) ?? false }
        startKeyTap(prompt: true)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.restoreLevel() }
    }

    func startKeyTap(prompt: Bool) {
        keysActive = keyTap.start(prompt: prompt)
        guard !keysActive, keyTimer == nil else { return }
        keyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.keyTap.start(prompt: false) {
                self.keysActive = true
                self.keyTimer?.invalidate()
                self.keyTimer = nil
            }
        }
    }

    // Volume keys go to the real output device while BlackHole is the system output.
    private func handleKey(_ key: VolumeKey, fine: Bool) -> Bool {
        guard let out = engine.outputDevice, let bh = Devices.blackHole(),
              Devices.defaultOutput()?.id == bh.id, let current = Devices.volume(out.id) else { return false }
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        let v = lastApplied ?? current
        switch key {
        case .up:
            Devices.setMuted(out.id, false)
            setOutputVolume(v + step)
        case .down:
            setOutputVolume(v - step)
        case .mute:
            Devices.setMuted(out.id, !(Devices.muted(out.id) ?? false))
        }
        refreshMute()
        hud.show(level: lastApplied ?? current, muted: muted)
        return true
    }

    func refreshDevices() {
        let bh = Devices.blackHole()
        devices = Devices.all().filter { $0.hasOutput && $0.id != bh?.id }
    }

    func refreshVolume() {
        volume = lastApplied
    }

    // Loudness lost to Prevent clipping, in dB.
    private var compensationDB: Float {
        guard settings.enabled, settings.preventClipping else { return 0 }
        let gain = ns_peak_gain(Float(settings.percent * 0.01), Float(settings.bassPercent * 0.01),
                                Float(settings.widthPercent * 0.01))
        return 20 * log10(max(1, gain))
    }

    private func decibels(ofOutput v: Float) -> Float? {
        guard let device = volumeDevice else { return nil }
        return v <= 0 ? Self.silentDB : Devices.decibels(forVolume: device.id, v)
    }

    // The uncompensated level for a device level the user sees.
    private func level(forShown db: Float) -> Float {
        db <= Self.silentDB ? Self.silentDB : db - compensationDB
    }

    // Slider and keys set the output level shown; the level is that minus the compensation.
    func setOutputVolume(_ real: Float) {
        guard let db = decibels(ofOutput: min(max(real, 0), 1)) else { return }
        levelDB = level(forShown: db)
        if muted, let device = volumeDevice {
            Devices.setMuted(device.id, false)
            muted = false
        }
        applyVolume()
    }

    private func applyVolume() {
        guard let device = volumeDevice, let level = levelDB else { return }
        let comp = compensationDB
        let wanted = level + comp
        let realDB = min(max(wanted, deviceRange.lowerBound), deviceRange.upperBound)
        let target: Float
        if realDB <= deviceRange.lowerBound {
            target = 0
        } else if let s = Devices.scalar(forDecibels: device.id, realDB) {
            target = min(max(s, 0), 1)
        } else {
            return
        }
        lastApplied = target
        Devices.setVolume(device.id, target)
        volume = target
        limited = comp > 0 && wanted > deviceRange.upperBound
        let d = UserDefaults.standard
        d.set(device.uid, forKey: "volumeDeviceUID")
        d.set(level, forKey: "levelDB")
        d.set(target, forKey: "appliedVolume")
    }

    // Puts the device back at the uncompensated level.
    private func restoreLevel() {
        guard let device = volumeDevice, let level = levelDB else { return }
        let db = min(max(level, deviceRange.lowerBound), deviceRange.upperBound)
        let target = db <= deviceRange.lowerBound ? 0 : (Devices.scalar(forDecibels: device.id, db) ?? 0)
        lastApplied = target
        Devices.setVolume(device.id, target)
        UserDefaults.standard.set(target, forKey: "appliedVolume")
    }

    // Volume changed outside the app (System Settings, another app): take it as the new level.
    private func externalVolumeChange() {
        guard let device = volumeDevice, let applied = lastApplied, let current = Devices.volume(device.id),
              abs(current - applied) >= 0.002, let db = decibels(ofOutput: current) else { return }
        levelDB = level(forShown: db)
        lastApplied = current
        volume = current
        let d = UserDefaults.standard
        d.set(levelDB, forKey: "levelDB")
        d.set(current, forKey: "appliedVolume")
        limited = false
    }

    func refreshMute() {
        muted = volumeDevice.flatMap { Devices.muted($0.id) } ?? false
    }

    private func watchVolume(of device: AudioDevice?) {
        for (id, addr, block) in volumeListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
        volumeListeners = []
        guard let device else { return }
        let handlers: [(AudioObjectPropertySelector, () -> Void)] = [
            (kAudioHardwareServiceDeviceProperty_VirtualMainVolume, { [weak self] in self?.externalVolumeChange() }),
            (kAudioDevicePropertyMute, { [weak self] in self?.refreshMute() }),
        ]
        for (selector, handler) in handlers {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            if AudioObjectAddPropertyListenerBlock(device.id, &addr, DispatchQueue.main, block) == noErr {
                volumeListeners.append((device.id, addr, block))
            }
        }
    }

    private func adoptVolumeDevice() {
        restoreLevel()
        watchVolume(of: engine.outputDevice)
        volumeDevice = engine.outputDevice
        levelDB = nil
        guard let device = volumeDevice, let current = Devices.volume(device.id),
              let lo = Devices.minDecibels(device.id), let hi = Devices.maxDecibels(device.id) else {
            volume = nil
            return
        }
        deviceRange = lo...hi
        let d = UserDefaults.standard
        // After a quit or crash while compensated, the device still holds the compensated level.
        if d.string(forKey: "volumeDeviceUID") == device.uid, d.object(forKey: "levelDB") != nil,
           abs(d.float(forKey: "appliedVolume") - current) < 0.002 {
            levelDB = d.float(forKey: "levelDB")
        } else {
            levelDB = decibels(ofOutput: current)
        }
        refreshMute()
        applyVolume()
    }

    func apply() {
        engine.update(enabled: settings.enabled, percent: settings.percent, bassPercent: settings.bassPercent,
                      widthPercent: settings.widthPercent, preventClipping: settings.preventClipping)
        applyVolume()
    }

    func restart() {
        refreshDevices()
        do {
            guard try engine.start(outputUID: settings.outputUID, lowLatency: settings.lowLatency) else { return }
            error = nil
            blackHoleMissing = false
        } catch {
            self.error = "\(error)"
            if case EngineError.noInputDevice = error { blackHoleMissing = true }
        }
        if let bh = Devices.blackHole() { unityPin.pin(bh.id) }
        adoptVolumeDevice()
    }
}
