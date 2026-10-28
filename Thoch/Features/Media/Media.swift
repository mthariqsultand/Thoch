import SwiftUI
import AppKit
import Combine

// MARK: - Model

enum MediaApp: String, CaseIterable {
    case spotify = "Spotify"
    case music = "Music"

    var bundleID: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

struct NowPlaying: Equatable {
    var app: MediaApp
    var title: String
    var artist: String
    var album: String
    var duration: Double   // detik
    var position: Double   // detik
    var isPlaying: Bool
    var volume: Double     // 0…1 (volume app, bukan volume sistem)
}

// MARK: - AppleScript helper (dengan cache supaya tidak compile ulang tiap detik)

@MainActor
enum Script {
    private static var cache: [String: NSAppleScript] = [:]

    static func run(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = cache[source] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            cache[source] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

// MARK: - Controller

/// Membaca & mengontrol lagu dari Spotify / Apple Music.
/// App TIDAK pernah dibuka paksa: script cuma dijalankan kalau app-nya sudah jalan.
@MainActor
final class MediaController: ObservableObject {
    static let shared = MediaController()

    @Published private(set) var info: NowPlaying?
    @Published private(set) var artwork: NSImage?
    /// 2–3 warna dominan dari album art (untuk ambient light)
    @Published private(set) var palette: [Color] = []

    var isLive: Bool { info?.isPlaying == true }

    private var trackKey = ""
    private var poller: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {
        // Spotify & Music mengirim notifikasi saat lagu/status berubah → refresh langsung
        let center = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // Polling ringan tiap detik untuk progress bar
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
        refresh()
    }

    // MARK: Kontrol

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    func setVolume(_ value: Double) {
        let v = min(max(value, 0), 1)
        info?.volume = v // update lokal dulu biar slider tidak lompat
        send("set sound volume to \(Int(v * 100))", refreshAfter: false)
    }

    func seek(to seconds: Double) {
        info?.position = seconds
        send("set player position to \(seconds)")
    }

    private func send(_ command: String, refreshAfter: Bool = true) {
        guard let app = info?.app, app.isRunning else { return }
        _ = Script.run("tell application \"\(app.rawValue)\" to \(command)")
        if refreshAfter { refresh() }
    }

    // MARK: Baca status

    func refresh() {
        var best: NowPlaying?
        for app in MediaApp.allCases where app.isRunning {
            guard let state = fetch(app) else { continue }
            if state.isPlaying { best = state; break } // yang sedang play diutamakan
            if best == nil { best = state }
        }
        if info != best { info = best }
        updateArtwork(for: best)
    }

    private func fetch(_ app: MediaApp) -> NowPlaying? {
        let source = """
        tell application "\(app.rawValue)"
            if player state is stopped then return {"stopped"}
            set t to current track
            return {(player state as string), name of t, artist of t, album of t, duration of t, player position, sound volume}
        end tell
        """
        guard let list = Script.run(source), list.numberOfItems >= 7,
              let state = list.atIndex(1)?.stringValue, state != "stopped" else { return nil }

        var duration = list.atIndex(5)?.doubleValue ?? 0
        if app == .spotify { duration /= 1000 } // Spotify memakai milidetik

        return NowPlaying(
            app: app,
            title: list.atIndex(2)?.stringValue ?? "",
            artist: list.atIndex(3)?.stringValue ?? "",
            album: list.atIndex(4)?.stringValue ?? "",
            duration: duration,
            position: list.atIndex(6)?.doubleValue ?? 0,
            isPlaying: state == "playing",
            volume: (list.atIndex(7)?.doubleValue ?? 0) / 100
        )
    }

    /// Ambil album art hanya saat lagu berganti
    private func updateArtwork(for state: NowPlaying?) {
        let key = state.map { "\($0.app.rawValue)|\($0.title)|\($0.artist)|\($0.album)" } ?? ""
        guard key != trackKey else { return }
        trackKey = key

        guard let state else {
            setArtwork(nil)
            return
        }

        switch state.app {
        case .music:
            let data = Script.run("""
            tell application "Music"
                if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track
            end tell
            """)?.data
            setArtwork(data.flatMap { NSImage(data: $0) })

        case .spotify:
            guard let urlString = Script.run("tell application \"Spotify\" to return artwork url of current track")?.stringValue,
                  let url = URL(string: urlString) else {
                setArtwork(nil)
                return
            }
            Task {
                let data = try? await URLSession.shared.data(from: url).0
                guard self.trackKey == key else { return } // lagu sudah ganti lagi
                self.setArtwork(data.flatMap { NSImage(data: $0) })
            }
        }
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        withAnimation(.easeInOut(duration: 1.2)) {
            palette = image.map(Palette.colors(from:)) ?? []
        }
    }
}

// MARK: - Ambil warna dominan dari album art

enum Palette {
    static func colors(from image: NSImage) -> [Color] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let w = 8, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h * 4)

        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return [] }

        // Nilai tiap piksel: utamakan warna yang "hidup" (saturasi & terang)
        var candidates: [(hue: CGFloat, sat: CGFloat, bri: CGFloat, score: CGFloat)] = []
        for i in 0..<(w * h) {
            let c = NSColor(red: CGFloat(pixels[i * 4]) / 255,
                            green: CGFloat(pixels[i * 4 + 1]) / 255,
                            blue: CGFloat(pixels[i * 4 + 2]) / 255, alpha: 1)
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0
            c.getHue(&hue, saturation: &sat, brightness: &bri, alpha: nil)
            guard bri > 0.15 else { continue } // abaikan yang hampir hitam
            candidates.append((hue, sat, bri, sat * 0.7 + bri * 0.3))
        }

        // Pilih maksimal 3 warna dengan hue yang berbeda-beda
        var picked: [(hue: CGFloat, sat: CGFloat, bri: CGFloat)] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            let distinct = picked.allSatisfy { p in
                let d = abs(p.hue - c.hue)
                return min(d, 1 - d) > 0.08
            }
            if distinct { picked.append((c.hue, c.sat, c.bri)) }
            if picked.count == 3 { break }
        }

        // Sedikit dicerahkan supaya terlihat seperti cahaya
        return picked.map {
            Color(hue: $0.hue, saturation: min(1, $0.sat * 1.1), brightness: max(0.75, $0.bri))
        }
    }
}

// MARK: - Ambient light (cahaya dari album art yang bergeser pelan)

struct AmbientLight: View {
    let colors: [Color]
    /// Tinggi zona hitam notch — cahaya tidak boleh masuk ke sini supaya notch hardware tidak "kelihatan"
    var notchHeight: CGFloat = 32
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            let tb = min(notchHeight / max(geo.size.height, 1), 0.9)
            lights
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: tb),
                        .init(color: .black, location: min(tb + 0.2, 1)),
                        .init(color: .black, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                )
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    private var lights: some View {
        ZStack {
            if colors.indices.contains(0) {
                RadialGradient(colors: [colors[0].opacity(0.55), .clear],
                               center: drift ? UnitPoint(x: 0.12, y: 0.95) : UnitPoint(x: 0.35, y: 0.8),
                               startRadius: 0, endRadius: 280)
            }
            if colors.indices.contains(1) {
                RadialGradient(colors: [colors[1].opacity(0.45), .clear],
                               center: drift ? UnitPoint(x: 0.9, y: 0.8) : UnitPoint(x: 0.65, y: 1.0),
                               startRadius: 0, endRadius: 260)
            }
            if colors.indices.contains(2) {
                RadialGradient(colors: [colors[2].opacity(0.35), .clear],
                               center: drift ? UnitPoint(x: 0.5, y: 1.1) : UnitPoint(x: 0.5, y: 0.7),
                               startRadius: 0, endRadius: 220)
            }
        }
    }
}

// MARK: - Live Activity (notch tertutup saat musik jalan)

/// Kapan notch tertutup perlu melebar (musik jalan atau timer jalan)
@MainActor
enum LiveActivity {
    static var isActive: Bool {
        MediaController.shared.isLive
            || FocusTimer.shared.state == .running
            || Anniversary.showInNotch
    }
}

struct LiveActivityView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject private var media = MediaController.shared
    @ObservedObject private var timer = FocusTimer.shared

    private var amber: Color { Theme.focus }
    /// Waveform ikut accent; mode Colorful → putih
    private var waveColor: Color { Theme.choice == .colorful ? .white : Theme.primary }

    var body: some View {
        let music = media.isLive
        let timing = timer.state == .running
        // Musik & timer lebih penting; hati anniversary tampil kalau keduanya tidak jalan
        let love = !music && !timing && Anniversary.showInNotch

        HStack(spacing: 0) {
            // Kiri
            if music {
                ArtworkView(image: media.artwork, size: 22, corner: 6)
            } else if love {
                Image(systemName: "heart.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Anniversary.color)
                    .symbolEffect(.pulse)
                    .padding(3)
            } else {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: timer.fraction)
                        .stroke(amber, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: timer.fraction)
                }
                .frame(width: 16, height: 16)
                .padding(3)
            }

            Spacer(minLength: model.notchSize.width)

            // Kanan
            if timing {
                Text(FocusTimer.format(timer.remaining))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(amber)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: Int(timer.remaining))
            } else if love {
                Text(Anniversary.notchLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Anniversary.color)
            } else {
                Waveform(color: waveColor)
            }
        }
        .padding(.horizontal, (timing || love) ? 22 : 26)
        .frame(height: model.notchSize.height)
    }
}

struct Waveform: View {
    let color: Color

    /// Tiap batang punya rentang tinggi, kecepatan & jeda sendiri → terlihat acak
    private let bars: [WaveBar.Spec] = [
        .init(low: 0.30, high: 0.90, duration: 0.42, delay: 0.00),
        .init(low: 0.45, high: 1.00, duration: 0.34, delay: 0.12),
        .init(low: 0.25, high: 0.80, duration: 0.50, delay: 0.05),
        .init(low: 0.35, high: 0.95, duration: 0.38, delay: 0.20)
    ]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(bars.indices, id: \.self) { i in
                WaveBar(color: color, spec: bars[i])
            }
        }
        .frame(width: 20, height: 16)
    }
}

/// Satu batang waveform. Animasinya dijalankan Core Animation (GPU),
/// jadi tetap mulus walau app sedang di latar belakang.
struct WaveBar: View {
    struct Spec {
        let low: CGFloat
        let high: CGFloat
        let duration: Double
        let delay: Double
    }

    let color: Color
    let spec: Spec
    @State private var up = false

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: 3, height: 16)
            .scaleEffect(x: 1, y: up ? spec.high : spec.low, anchor: .center)
            .task {
                // Mulai sesudah transisi muncul selesai, supaya animasinya tidak "tertelan"
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation(.easeInOut(duration: spec.duration)
                    .repeatForever(autoreverses: true)
                    .delay(spec.delay)) {
                    up = true
                }
            }
    }
}

// MARK: - Komponen bersama

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(red: 1, green: 0.44, blue: 0.69), Color(red: 0.54, green: 0.36, blue: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct TrackProgress: View {
    let position: Double
    let duration: Double
    var showTimes = true

    private var fraction: Double { duration > 0 ? min(position / duration, 1) : 0 }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            .animation(.linear(duration: 1), value: fraction)

            if showTimes {
                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text("-" + Self.format(max(duration - position, 0)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .opacity(0.5)
            }
        }
    }

    static func format(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct MediaControls: View {
    var scale: CGFloat = 1
    @ObservedObject private var media = MediaController.shared

    var body: some View {
        HStack(spacing: 28 * scale) {
            control("backward.fill", size: 15) { media.previous() }
            control(media.isLive ? "pause.fill" : "play.fill", size: 22) { media.playPause() }
            control("forward.fill", size: 15) { media.next() }
        }
        .frame(maxWidth: .infinity)
    }

    private func control(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * scale, weight: .semibold))
                .frame(width: 30 * scale, height: 26 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NothingPlaying: View {
    var compact = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: compact ? 18 : 22, weight: .medium))
            Text("Nothing playing")
                .font(.system(size: 12, weight: .semibold))
            if !compact {
                Text("Play something in Spotify or Apple Music")
                    .font(.system(size: 10))
                    .opacity(0.6)
            }
        }
        .opacity(0.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab Media (player lengkap)

struct MediaPage: View {
    @ObservedObject private var media = MediaController.shared

    var body: some View {
        GlassCard {
            if let info = media.info {
                HStack(spacing: 18) {
                    ArtworkView(image: media.artwork, size: 134, corner: 18)
                        .shadow(color: (media.palette.first ?? .clear).opacity(0.45), radius: 18, y: 8)

                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.title)
                                .font(.system(size: 20, weight: .bold))
                                .lineLimit(1)
                            Text(info.album.isEmpty ? info.artist : "\(info.artist) — \(info.album)")
                                .font(.system(size: 13))
                                .opacity(0.6)
                                .lineLimit(1)
                        }
                        TrackProgress(position: info.position, duration: info.duration)
                        MediaControls()
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 11))
                                .opacity(0.6)
                            Slider(value: Binding(get: { media.info?.volume ?? 0 },
                                                  set: { media.setVolume($0) }),
                                   in: 0...1)
                                .controlSize(.mini)
                                .tint(.white)
                            Text(info.app.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.1), in: Capsule())
                                .opacity(0.8)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                NothingPlaying()
            }
        }
    }
}

// MARK: - Kartu Now Playing di Home

struct NowPlayingCard: View {
    @ObservedObject private var media = MediaController.shared

    var body: some View {
        GlassCard {
            if let info = media.info {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        ArtworkView(image: media.artwork, size: 52, corner: 12)
                            .shadow(color: (media.palette.first ?? .clear).opacity(0.45), radius: 10, y: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(2)
                            Text(info.artist)
                                .font(.system(size: 11))
                                .opacity(0.6)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 6)
                    TrackProgress(position: info.position, duration: info.duration)
                    Spacer(minLength: 4)
                    MediaControls(scale: 0.8)
                }
            } else {
                NothingPlaying(compact: true)
            }
        }
    }
}
