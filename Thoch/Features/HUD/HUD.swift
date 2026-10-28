import SwiftUI
import AppKit
import CoreAudio
import AudioToolbox
import ApplicationServices
import Combine

// MARK: - State HUD

enum HUDKind { case volume, brightness }

struct HUDInfo: Equatable {
    var kind: HUDKind
    var value: Double      // 0…1
    var muted = false
}

// MARK: - Controller: tangkap tombol volume/brightness & tampilkan HUD di notch

@MainActor
final class HUDController: ObservableObject {
    static let shared = HUDController()

    @Published private(set) var current: HUDInfo?

    private var tap: CFMachPort?
    private var trustTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private let step = 1.0 / 16 // sama seperti macOS: 16 langkah

    private init() {}

    /// Butuh izin Accessibility. Kalau belum diizinkan, macOS menampilkan prompt,
    /// lalu app menunggu sampai izin diberikan.
    func start() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            installTap()
        } else {
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                    self.installTap()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            trustTimer = t
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED: tombol media/volume/brightness
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: hudEventTapCallback,
                                          userInfo: ref) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// macOS mematikan tap kalau dianggap terlalu lama merespons → nyalakan lagi
    func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// true = tombol ditangani di sini (HUD bawaan macOS tidak muncul)
    func handleKey(code: Int, isDown: Bool) -> Bool {
        switch code {
        case 0, 1, 7: // NX_KEYTYPE_SOUND_UP, SOUND_DOWN, MUTE
            guard Volume.isAvailable else { return false } // device tidak mendukung → biar macOS yang urus
            if isDown { volumeKey(code) }
            return true
        case 2, 3:    // NX_KEYTYPE_BRIGHTNESS_UP, BRIGHTNESS_DOWN
            guard Brightness.isAvailable else { return false }
            if isDown { brightnessKey(up: code == 2) }
            return true
        default:
            return false
        }
    }

    private func volumeKey(_ code: Int) {
        var value = Volume.get()
        var muted = Volume.isMuted()
        switch code {
        case 7:
            muted.toggle()
            Volume.setMuted(muted)
        case 0:
            if muted { muted = false; Volume.setMuted(false) }
            value = snapped(value + step)
            Volume.set(value)
        default:
            value = snapped(value - step)
            Volume.set(value)
        }
        show(HUDInfo(kind: .volume, value: value, muted: muted || value == 0))
    }

    private func brightnessKey(up: Bool) {
        let value = snapped(Brightness.get() + (up ? step : -step))
        Brightness.set(value)
        show(HUDInfo(kind: .brightness, value: value))
    }

    /// Bulatkan ke kelipatan 1/16 dan batasi 0…1
    private func snapped(_ v: Double) -> Double {
        min(1, max(0, (v / step).rounded() * step))
    }

    private func show(_ info: HUDInfo) {
        if current == nil {
            // Muncul: bouncy
            withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) { current = info }
        } else {
            // Sudah tampil, cuma nilainya berubah: cepat, tanpa pantulan
            withAnimation(.snappy(duration: 0.15)) { current = info }
        }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) { current = nil }
        }
    }
}

/// Callback event tap (harus fungsi C biasa, tidak boleh menangkap variabel)
nonisolated private func hudEventTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                                             event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passThrough = Unmanaged.passUnretained(event)
    guard let userInfo else { return passThrough }
    let controller = Unmanaged<HUDController>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controller.reenableTap() }
        return passThrough
    }

    // Tombol media datang sebagai NX_SYSDEFINED (14) dengan subtype 8
    guard type.rawValue == 14,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == 8 else { return passThrough }

    let data1 = nsEvent.data1
    let keyCode = (data1 & 0xFFFF0000) >> 16
    let keyFlags = data1 & 0x0000FFFF
    let isDown = ((keyFlags & 0xFF00) >> 8) == 0xA

    // Tap dipasang di run loop utama, jadi callback ini memang jalan di main thread
    let handled = MainActor.assumeIsolated { controller.handleKey(code: keyCode, isDown: isDown) }
    return handled ? nil : passThrough
}

// MARK: - Volume sistem (CoreAudio, API resmi)

@MainActor
enum Volume {
    private static func defaultDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Device output sekarang bisa diatur volumenya? (beberapa HDMI/monitor tidak bisa)
    static var isAvailable: Bool {
        guard let device = defaultDevice() else { return false }
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &a)
            && AudioObjectIsPropertySettable(device, &a, &settable) == noErr
            && settable.boolValue
    }

    static func get() -> Double {
        guard let device = defaultDevice() else { return 0 }
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value)
        return Double(value)
    }

    static func set(_ v: Double) {
        guard let device = defaultDevice() else { return }
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(v)
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func isMuted() -> Bool {
        guard let device = defaultDevice() else { return false }
        var a = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &a) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value)
        return value != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = defaultDevice() else { return }
        var a = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &a) else { return }
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// MARK: - Brightness layar bawaan (DisplayServices — framework TIDAK resmi)

@MainActor
enum Brightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static let getFn: GetFn? = {
        guard let handle, let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetFn.self)
    }()

    private static let setFn: SetFn? = {
        guard let handle, let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(sym, to: SetFn.self)
    }()

    /// Layar bawaan MacBook (brightness monitor eksternal tidak didukung)
    private static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var isAvailable: Bool {
        getFn != nil && setFn != nil && builtInDisplay != nil
    }

    static func get() -> Double {
        guard let getFn, let display = builtInDisplay else { return 0 }
        var value: Float = 0
        _ = getFn(display, &value)
        return Double(value)
    }

    static func set(_ v: Double) {
        guard let setFn, let display = builtInDisplay else { return }
        _ = setFn(display, Float(v))
    }
}

// MARK: - Tampilan HUD di bawah notch

struct HUDView: View {
    let info: HUDInfo
    let notchHeight: CGFloat

    private var level: Double { info.muted ? 0 : info.value }

    private var icon: String {
        switch info.kind {
        case .volume:
            if info.muted || level == 0 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return level < 0.4 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    private var color: Color {
        info.kind == .brightness ? Color(red: 1, green: 0.83, blue: 0.42) : .white
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: notchHeight)
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(color)
                            .frame(width: geo.size.width * level)
                    }
                }
                .frame(height: 6)
                Text("\(Int((level * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
                    .opacity(0.85)
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .animation(.snappy(duration: 0.15), value: level)
    }
}
