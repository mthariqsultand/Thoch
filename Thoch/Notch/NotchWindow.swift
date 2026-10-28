import AppKit
import SwiftUI
import Combine

// MARK: - Tab / halaman

enum NotchTab: String, CaseIterable, Identifiable {
    case home, media, files, clipboard, productivity, settings

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .media: "music.note"
        case .files: "folder"
        case .clipboard: "doc.on.clipboard"
        case .productivity: "checklist"
        case .settings: "gearshape"
        }
    }

    /// Tab yang tampil di deretan ikon kiri (Settings ada di kanan)
    static let mainTabs: [NotchTab] = [.home, .media, .files, .clipboard, .productivity]
}

// MARK: - State

final class NotchViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var tab: NotchTab = .home
    /// True saat file sedang di-drag di atas panel (untuk highlight)
    @Published var isDropTargeted = false
    /// True selama ada file (dari luar) yang sedang di-drag → tampilkan pilihan Tray / AirDrop
    @Published var isFileDragging = false
    /// Mode Mirror (preview kamera bulat). Tetap terbuka sampai diklik.
    @Published var isMirrorOn = false
    /// Mirror: lingkaran kamera & lengkungan bawah panel dibuat SEPUSAT,
    /// jadi jarak di kiri, kanan, dan bawah sama persis.
    let mirrorDiameter: CGFloat = 216
    let mirrorGap: CGFloat = 10
    let mirrorTopPadding: CGFloat = 4
    var mirrorSize: CGSize {
        let width = mirrorDiameter + mirrorGap * 2
        // pusat lingkaran = notch + padding + d/2  →  harus = tinggi panel − radius lengkungan (width/2)
        let height = notchSize.height + mirrorTopPadding + mirrorDiameter / 2 + width / 2
        return CGSize(width: width, height: height)
    }
    /// Ukuran notch hardware, dibaca dari layar
    @Published var notchSize = CGSize(width: 200, height: 32)
    /// Ukuran panel saat terbuka (tanpa "shoulder")
    let expandedSize = CGSize(width: 640, height: 250)
}

// MARK: - Deteksi notch

extension NSScreen {
    /// Layar yang punya notch (layar bawaan MacBook), fallback ke layar utama
    static var notchScreen: NSScreen? {
        screens.first { $0.safeAreaInsets.top > 0 } ?? main
    }

    /// Lebar & tinggi notch. Area di kiri-kanan notch disebut "auxiliary area".
    var notchSize: CGSize {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else {
            return CGSize(width: 200, height: 32) // layar tanpa notch: notch palsu
        }
        return CGSize(width: frame.width - left.width - right.width,
                      height: safeAreaInsets.top)
    }
}

// MARK: - Panel transparan di atas menu bar

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // di atas menu bar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = true // klik tembus selama notch tertutup
    }

    override var canBecomeKey: Bool { true } // perlu untuk mengetik di TextField

    // Cegah macOS menggeser jendela ke bawah menu bar
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Supaya klik pertama langsung kena tombol (tanpa klik "aktivasi" dulu)
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller

@MainActor
final class NotchWindowController {
    private let panel = NotchPanel()
    private let model = NotchViewModel()
    private var monitors: [Any] = []
    /// Polling posisi kursor selama panel terbuka (untuk CursorGlow).
    /// Event mouseMoved tidak dikirim ke jendela notch kalau app tidak aktif, jadi dibaca langsung.
    private var glowTimer: Timer?
    /// Ukuran kanvas panel, cukup besar untuk state expanded + bayangan
    private let canvasSize = CGSize(width: 760, height: 330)

    init() {
        let host = FirstClickHostingView(rootView: NotchView(model: model))
        host.frame = CGRect(origin: .zero, size: canvasSize)
        panel.contentView = host
        reposition()
        startMouseTracking()
        HUDController.shared.start() // tombol volume & brightness (butuh izin Accessibility)
        ClipboardStore.shared.start() // riwayat clipboard
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func reposition() {
        guard let screen = NSScreen.notchScreen else { return }
        model.notchSize = screen.notchSize
        let f = screen.frame
        let origin = CGPoint(x: f.midX - canvasSize.width / 2,
                             y: f.maxY - canvasSize.height)
        panel.setFrame(CGRect(origin: origin, size: canvasSize), display: true)
    }

    // MARK: Drag tracking
    /// changeCount pasteboard drag saat mouse ditekan. Kalau berubah selama drag → ada file baru di-drag.
    private var dragCountAtMouseDown = 0
    /// Sedang ada file yang di-drag (dari Finder, desktop, dll)
    private var isFileDrag = false
    /// Drag dimulai dari dalam panel (misal: menarik file keluar dari Tray)
    private var dragStartedInside = false

    // Pantau posisi kursor di seluruh layar (tidak butuh izin Accessibility)
    private func startMouseTracking() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] e in
            self?.handle(e)
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] e in
            self?.handle(e)
            return e
        }) { monitors.append(l) }
    }

    private func handle(_ event: NSEvent) {
        let dragBoard = NSPasteboard(name: .drag)
        switch event.type {
        case .leftMouseDown:
            dragCountAtMouseDown = dragBoard.changeCount
            dragStartedInside = model.isExpanded && hitRect().contains(NSEvent.mouseLocation)
        case .leftMouseDragged:
            if !isFileDrag,
               dragBoard.changeCount != dragCountAtMouseDown,
               dragBoard.canReadObject(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) {
                isFileDrag = true
            }
        case .leftMouseUp:
            isFileDrag = false
            dragStartedInside = false
        default:
            break
        }
        updateHover()
        syncGlowTimer()
    }

    // MARK: Cursor glow

    private func syncGlowTimer() {
        let shouldRun = model.isExpanded && !model.isMirrorOn
        if shouldRun && glowTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickGlow() }
            }
            RunLoop.main.add(t, forMode: .common)
            glowTimer = t
        } else if !shouldRun, let t = glowTimer {
            t.invalidate()
            glowTimer = nil
            CursorTracker.shared.location = nil
        }
    }

    /// Ubah posisi kursor layar → koordinat SwiftUI di dalam panel
    private func tickGlow() {
        guard model.isExpanded, !model.isMirrorOn else { syncGlowTimer(); return }
        let pf = panel.frame
        let shapeWidth = model.expandedSize.width + 32 // + shoulder kiri-kanan
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - pf.minX - (pf.width - shapeWidth) / 2,
                            y: pf.maxY - mouse.y)
        let inside = point.x >= 0 && point.x <= shapeWidth
            && point.y >= 0 && point.y <= model.expandedSize.height
        let new: CGPoint? = inside ? point : nil

        // Publish cuma kalau benar-benar bergerak (hemat render)
        let old = CursorTracker.shared.location
        let moved: Bool
        switch (old, new) {
        case (nil, nil): moved = false
        case let (a?, b?): moved = abs(a.x - b.x) > 0.5 || abs(a.y - b.y) > 0.5
        default: moved = true
        }
        if moved { CursorTracker.shared.location = new }
    }

    /// Area aktif: notch kecil saat tertutup, seluruh panel saat terbuka
    private func hitRect() -> CGRect {
        let pf = panel.frame
        let size: CGSize
        if model.isExpanded {
            size = CGSize(width: model.expandedSize.width + 32, height: model.expandedSize.height)
        } else if isFileDrag {
            // "Magnet": area lebih besar waktu bawa file, biar gampang kena notch
            size = CGSize(width: model.notchSize.width + 120, height: model.notchSize.height + 40)
        } else if LiveActivity.isActive {
            // Live Activity: notch lebih lebar, jadi area hover ikut lebar
            size = CGSize(width: model.notchSize.width + 172, height: model.notchSize.height + 4)
        } else {
            size = CGSize(width: model.notchSize.width + 12, height: model.notchSize.height + 4)
        }
        var r = CGRect(x: pf.midX - size.width / 2, y: pf.maxY - size.height,
                       width: size.width, height: size.height)
        if model.isExpanded { r = r.insetBy(dx: -12, dy: -12) } // toleransi biar tidak gampang nutup
        return r
    }

    private func updateHover() {
        // Pengaman: kalau tombol mouse sudah dilepas, reset status drag
        if NSEvent.pressedMouseButtons & 1 == 0 {
            isFileDrag = false
            dragStartedInside = false
        }

        // Pilihan Tray / AirDrop cuma untuk file dari luar (bukan yang ditarik keluar dari Tray)
        let showChoices = isFileDrag && !dragStartedInside
        if model.isFileDragging != showChoices {
            withAnimation(.snappy(duration: 0.2)) { model.isFileDragging = showChoices }
        }

        // Mode Mirror: tidak ikut buka-tutup hover. Klik cuma ditangkap di area preview,
        // di luar itu klik tembus ke app di belakangnya.
        if model.isMirrorOn {
            panel.ignoresMouseEvents = !mirrorRect().contains(NSEvent.mouseLocation)
            return
        }

        let inside = hitRect().contains(NSEvent.mouseLocation)

        // Jangan tutup panel saat file sedang ditarik keluar dari Tray
        if !inside && dragStartedInside { return }

        // Bawa file ke panel yang sudah terbuka → pindah ke tab Files
        if inside && isFileDrag && model.isExpanded && model.tab != .files {
            withAnimation(.snappy(duration: 0.25)) { model.tab = .files }
        }

        if inside != model.isExpanded {
            // Buka: spring biasa. Tutup: lebih bouncy (memantul sedikit saat menyusut).
            // Tutup ke Live Activity (lebih lebar dari notch): hampir tanpa pantulan,
            // supaya tidak sempat lebih kecil dari ukuran akhir dan memperlihatkan menu bar.
            let animation: Animation = inside
                ? .spring(response: 0.38, dampingFraction: 0.78)
                : LiveActivity.isActive
                    ? .spring(response: 0.42, dampingFraction: 0.86)
                    : .spring(response: 0.45, dampingFraction: 0.58)
            withAnimation(animation) {
                model.isExpanded = inside
                if inside && isFileDrag { model.tab = .files }
            }
        }
        panel.ignoresMouseEvents = !model.isExpanded
    }

    private func mirrorRect() -> CGRect {
        let pf = panel.frame
        let w = model.mirrorSize.width + 28
        let h = model.mirrorSize.height
        return CGRect(x: pf.midX - w / 2, y: pf.maxY - h, width: w, height: h)
    }
}
