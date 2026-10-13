import AudioToolbox
import CNoiseSharpening
import CoreAudio
import AVFoundation
import Foundation
import os

public enum EngineError: Error, CustomStringConvertible {
    case noInputDevice
    case noOutputDevice
    case audio(String, OSStatus)

    public var description: String {
        switch self {
        case .noInputDevice: return "BlackHole is not installed (brew install blackhole-2ch)"
        case .noOutputDevice: return "No output device"
        case let .audio(what, status): return "\(what) failed (\(status))"
        }
    }
}

// Captures from a virtual loopback device, applies the filter and plays to a real output.
private let log = Logger(subsystem: "sg.ndoo.NoiseSharpening", category: "engine")

public final class AudioEngine {
    private static let channels = 2
    private static let ringFrames = 16384
    private static let targetFrames = 1024
    private static let lowLatencyBufferFrames: UInt32 = 128
    private static let lowLatencyTargetFrames = 128

    public private(set) var outputDevice: AudioDevice?
    private var inputDeviceID: AudioDeviceID?
    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var lowLatency = false
    private var originalBuffers: [(AudioDeviceID, UInt32)] = []
    private var ring: OpaquePointer?
    private let sharpener = ns_sharpener_create()
    private var scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)
    private var scratchFrames = 16384

    // Read from the audio thread; written from the main thread (aligned 32-bit stores).
    private var strength: Float = 0.4
    private var bass: Float = 0
    private var width: Float = 1
    private var bypass = false
    private var preventClipping = false
    private var loggedRenderError = false

    public init() {}

    deinit {
        stop()
        ns_sharpener_destroy(sharpener)
        scratch.deallocate()
    }

    public func update(enabled: Bool, percent: Double, bassPercent: Double, widthPercent: Double, preventClipping: Bool) {
        self.preventClipping = preventClipping
        strength = Float(Strength.clamp(percent) * 0.01)
        bass = Float(Strength.clampBody(bassPercent) * 0.01)
        width = Float(min(max(widthPercent, 0), Strength.widthMaxPercent) * 0.01)
        bypass = !enabled
    }

    private func resolveDevices(outputUID: String?) throws -> (input: AudioDevice, output: AudioDevice) {
        guard let input = Devices.blackHole() else { throw EngineError.noInputDevice }
        let outputs = Devices.all().filter { $0.hasOutput && $0.id != input.id }
        guard let output = outputs.first(where: { $0.uid == outputUID }) ?? Devices.defaultOutput().flatMap({ d in
            d.id == input.id ? nil : d
        }) ?? outputs.first else { throw EngineError.noOutputDevice }
        return (input, output)
    }

    // Returns false, leaving the running engine alone, when it already uses the resolved devices.
    @discardableResult
    public func start(outputUID: String?, lowLatency: Bool = false) throws -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        let input: AudioDevice, output: AudioDevice
        do {
            (input, output) = try resolveDevices(outputUID: outputUID)
        } catch {
            stop()
            throw error
        }
        if inputUnit != nil, outputUnit != nil, inputDeviceID == input.id, outputDevice?.id == output.id,
           self.lowLatency == lowLatency {
            return false
        }
        stop()
        self.lowLatency = lowLatency

        if let rate = Devices.nominalRate(output.id), Devices.nominalRate(input.id) != rate {
            Devices.setNominalRate(input.id, rate)
        }
        let rate = Devices.nominalRate(input.id) ?? 48000
        outputDevice = output
        inputDeviceID = input.id

        if lowLatency {
            for id in [input.id, output.id] {
                guard let current = Devices.bufferFrames(id) else { continue }
                originalBuffers.append((id, current))
                Devices.setBufferFrames(id, Self.lowLatencyBufferFrames)
            }
        }

        ring = ns_ring_create(Self.ringFrames * Self.channels)
        ns_sharpener_reset(sharpener)

        inputUnit = try makeUnit(device: input.id, capture: true, rate: rate)
        outputUnit = try makeUnit(device: output.id, capture: false, rate: rate)
        try check(AudioOutputUnitStart(inputUnit!), "start input")
        try check(AudioOutputUnitStart(outputUnit!), "start output")
        log.notice("started: in=\(input.name, privacy: .public) out=\(output.name, privacy: .public) rate=\(rate) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        return true
    }

    public func stop() {
        for unit in [inputUnit, outputUnit] {
            guard let unit else { continue }
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputUnit = nil
        outputUnit = nil
        outputDevice = nil
        inputDeviceID = nil
        for (id, frames) in originalBuffers { Devices.setBufferFrames(id, frames) }
        originalBuffers = []
        if let ring { ns_ring_destroy(ring) }
        ring = nil
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw EngineError.audio(what, status) }
    }

    private func makeUnit(device: AudioDeviceID, capture: Bool, rate: Double) throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw EngineError.audio("find HAL", -1) }
        var unitOpt: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unitOpt), "create unit")
        let unit = unitOpt!

        var inputOn: UInt32 = capture ? 1 : 0
        var outputOn: UInt32 = capture ? 0 : 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                       &inputOn, size), "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                       &outputOn, size), "enable output")
        var dev = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "set device")

        var fmt = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * Self.channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * Self.channels), mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 32, mReserved: 0)
        let fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if capture {
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           &fmt, fmtSize), "input format")
            var cb = AURenderCallbackStruct(inputProc: inputCallback,
                                            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                           kAudioUnitScope_Global, 0, &cb,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")
        } else {
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                           &fmt, fmtSize), "output format")
            var cb = AURenderCallbackStruct(inputProc: outputCallback,
                                            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0, &cb,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "render callback")
        }
        try check(AudioUnitInitialize(unit), "initialize")
        return unit
    }

    fileprivate func capture(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ ts: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let unit = inputUnit, let ring, Int(frames) <= scratchFrames else { return noErr }
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(Self.channels),
            mDataByteSize: frames * UInt32(4 * Self.channels), mData: scratch))
        let status = AudioUnitRender(unit, flags, ts, 1, frames, &abl)
        if status != noErr {
            if !loggedRenderError { loggedRenderError = true; log.error("render status \(status)") }
            return status
        }
        if !bypass {
            ns_sharpener_process(sharpener, scratch, Int(frames), Self.channels, strength, bass,
                                 preventClipping ? 1 : 0, width)
        } else {
            ns_sharpener_reset(sharpener)
        }
        _ = ns_ring_write(ring, scratch, Int(frames) * Self.channels)
        return noErr
    }

    fileprivate func render(_ data: UnsafeMutablePointer<AudioBufferList>, _ frames: UInt32) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(data)
        guard let ring, let buf = abl.first, let out = buf.mData?.assumingMemoryBound(to: Float.self) else {
            for b in abl { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
            return noErr
        }
        let samples = Int(frames) * Self.channels
        // Capture/render clocks differ; keep the backlog bounded.
        let target = lowLatency ? Self.lowLatencyTargetFrames : Self.targetFrames * 4
        ns_ring_trim(ring, (target + Int(frames)) * Self.channels)
        let got = ns_ring_read(ring, out, samples)
        if got < samples { memset(out + got, 0, (samples - got) * 4) }
        return noErr
    }
}

private func inputCallback(_ ref: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                           _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                           _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<AudioEngine>.fromOpaque(ref).takeUnretainedValue().capture(flags, ts, frames)
}

private func outputCallback(_ ref: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                            _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let data else { return noErr }
    return Unmanaged<AudioEngine>.fromOpaque(ref).takeUnretainedValue().render(data, frames)
}
