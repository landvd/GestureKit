import CoreAudio
import AudioToolbox

/// System output volume through CoreAudio (microseconds, any thread), replacing the
/// AppleScript `set volume` round trip. Devices without a settable master volume
/// (some HDMI / USB outputs) return false so the caller can fall back.
enum OutputVolume {

    private static func defaultOutputDevice() -> AudioObjectID? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return st == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    /// Current volume 0…1, or nil when not readable.
    static func current() -> Float? {
        guard let dev = defaultOutputDevice(), AudioObjectHasProperty(dev, &volumeAddress) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &volumeAddress, 0, nil, &size, &v) == noErr ? v : nil
    }

    /// Pure: next level for a ±percent step (0…100 scale, like the old AppleScript).
    static func next(_ current: Float, byPercent p: Double) -> Float {
        max(0, min(1, current + Float(p / 100)))
    }

    /// New level 0…1, or nil when the device has no settable volume.
    static func adjust(byPercent percent: Double) -> Float? {
        guard let dev = defaultOutputDevice(), AudioObjectHasProperty(dev, &volumeAddress) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(dev, &volumeAddress, &settable) == noErr, settable.boolValue,
              let cur = current() else { return nil }
        var v = next(cur, byPercent: percent)
        let st = AudioObjectSetPropertyData(dev, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        return st == noErr ? v : nil
    }
}
