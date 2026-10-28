import SwiftUI
import AppKit

// MARK: - Bentuk notch dengan "shoulder" cekung di atas & sudut bawah membulat

struct NotchShape: Shape {
    var shoulder: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottom) }
        set { shoulder = newValue.first; bottom = newValue.second }
    }

    /// Konstanta Bézier untuk seperempat lingkaran (hasilnya praktis identik dengan busur asli)
    private let k: CGFloat = 0.5523

    func path(in rect: CGRect) -> Path {
        let r = shoulder
        let R = max(0, min(bottom, (rect.width - 2 * r) / 2, rect.height - r))
        let (minX, maxX, minY, maxY) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        var p = Path()
        p.move(to: CGPoint(x: minX, y: minY))
        p.addLine(to: CGPoint(x: maxX, y: minY))
        // shoulder kanan (cekung, seperempat lingkaran)
        p.addCurve(to: CGPoint(x: maxX - r, y: minY + r),
                   control1: CGPoint(x: maxX - r * k, y: minY),
                   control2: CGPoint(x: maxX - r, y: minY + r - r * k))
        p.addLine(to: CGPoint(x: maxX - r, y: maxY - R))
        // sudut kanan bawah (seperempat lingkaran)
        p.addCurve(to: CGPoint(x: maxX - r - R, y: maxY),
                   control1: CGPoint(x: maxX - r, y: maxY - R + R * k),
                   control2: CGPoint(x: maxX - r - R + R * k, y: maxY))
        p.addLine(to: CGPoint(x: minX + r + R, y: maxY))
        // sudut kiri bawah (seperempat lingkaran)
        p.addCurve(to: CGPoint(x: minX + r, y: maxY - R),
                   control1: CGPoint(x: minX + r + R - R * k, y: maxY),
                   control2: CGPoint(x: minX + r, y: maxY - R + R * k))
        p.addLine(to: CGPoint(x: minX + r, y: minY + r))
        // shoulder kiri (cekung, seperempat lingkaran)
        p.addCurve(to: CGPoint(x: minX, y: minY),
                   control1: CGPoint(x: minX + r, y: minY + r - r * k),
                   control2: CGPoint(x: minX + r * k, y: minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - View utama notch

struct NotchView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject private var media = MediaController.shared
    @ObservedObject private var hud = HUDController.shared
    @ObservedObject private var timer = FocusTimer.shared
    /// Saat accent diganti, isi panel dibuat ulang supaya semua warna ikut berubah
    @AppStorage(Theme.storageKey) private var accent: AccentChoice = .colorful
    @ObservedObject private var toast = ToastController.shared
    // Supaya hati anniversary di notch langsung muncul/hilang saat pengaturannya diubah
    @AppStorage(Anniversary.enabledKey) private var annivEnabled = false
    @AppStorage(Anniversary.monthlyKey) private var annivMonthly = false
    @AppStorage(Anniversary.showNotchKey) private var annivShowNotch = false
    @AppStorage(Anniversary.modeKey) private var annivMode: Anniversary.Mode = .together

    var body: some View {
        let mirror = model.isMirrorOn
        let expanded = model.isExpanded && !mirror
        let open = expanded || mirror
        let hudInfo = open ? nil : hud.current          // HUD volume/brightness (notch tertutup)
        let toastInfo = (open || hudInfo != nil) ? nil : toast.current // notifikasi kecil
        let banner = hudInfo != nil || toastInfo != nil  // HUD & toast pakai bentuk yang sama
        let liveActive = media.isLive || timer.state == .running || Anniversary.showInNotch
        let live = !open && !banner && liveActive        // Live Activity: musik / timer / anniversary
        let size: CGSize = mirror ? model.mirrorSize
            : expanded ? model.expandedSize
            : banner ? CGSize(width: max(model.notchSize.width + 140, 330),
                              height: model.notchSize.height + 30)
            : live ? CGSize(width: model.notchSize.width + 160, height: model.notchSize.height)
            : model.notchSize
        let shoulder: CGFloat = mirror ? 14 : (expanded ? 16 : 6)
        let bottom: CGFloat = mirror ? model.mirrorSize.width / 2 : expanded ? 34 : banner ? 20 : live ? 12 : 10
        let shape = NotchShape(shoulder: shoulder, bottom: bottom)

        ZStack(alignment: .top) {
            // 1. Liquid glass (dengan tint gelap)
            GlassBackground(shape: shape)

            // 2. Gradasi hitam: solid di tinggi notch, lalu memudar ke kaca
            //    (HUD tetap hitam penuh, seperti bagian dari hardware)
            shape.fill(LinearGradient(stops: blendStops(height: size.height, solid: banner),
                                      startPoint: .top, endPoint: .bottom))

            // 2b. Ambient light dari warna album art (saat musik jalan)
            if expanded && media.isLive && !media.palette.isEmpty {
                AmbientLight(colors: media.palette, notchHeight: model.notchSize.height)
                    .transition(.opacity)
            } else if expanded && !media.isLive {
                // 2c. Belum ada musik → glow putih lembut mengikuti kursor
                CursorGlow(notchHeight: model.notchSize.height)
                    .transition(.opacity)
            }

            // 3. Rim light, cuma di bagian bawah supaya sambungan atas tidak terlihat
            shape.stroke(LinearGradient(stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0), location: 0.32),
                .init(color: .white.opacity(0.2), location: 0.75),
                .init(color: .white.opacity(0.5), location: 1)
            ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .opacity(open ? 1 : 0)

            // 4. Isi panel (lihat Pages.swift / Mirror.swift)
            if mirror {
                MirrorContent(model: model)
                    .padding(.horizontal, shoulder)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            } else if expanded {
                ExpandedContent(model: model)
                    .id(accent)
                    .padding(.horizontal, shoulder + 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if let hudInfo {
                HUDView(info: hudInfo, notchHeight: model.notchSize.height)
                    .transition(.opacity)
            } else if let toastInfo {
                ToastView(toast: toastInfo, notchHeight: model.notchSize.height)
                    .id(toastInfo.id)
                    .transition(.opacity)
            } else if live {
                LiveActivityView(model: model)
                    .id(accent)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width + shoulder * 2, height: size.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 28, y: 14)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: liveActive)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Stop gradien hitam → kaca (sama seperti spec di Figma)
    private func blendStops(height: CGFloat, solid: Bool = false) -> [Gradient.Stop] {
        let tb = model.notchSize.height / max(height, 1)
        guard tb < 0.95, !solid else {
            // Saat tertutup: hitam penuh, menyatu dengan notch hardware
            return [.init(color: .black, location: 0), .init(color: .black, location: 1)]
        }
        return [
            .init(color: .black, location: 0),
            .init(color: .black, location: tb),
            .init(color: .black.opacity(0.85), location: min(tb + 0.1, 0.5)),
            .init(color: .black.opacity(0.5), location: 0.55),
            .init(color: .black.opacity(0.3), location: 0.8),
            .init(color: .black.opacity(0.22), location: 1)
        ]
    }
}

// MARK: - Liquid glass (macOS 26) dengan fallback blur (macOS 14–15)

struct GlassBackground: View {
    let shape: NotchShape

    var body: some View {
        if #available(macOS 26.0, *) {
            // Tint gelap supaya tetap gelap walau di atas jendela putih
            Rectangle().fill(.clear)
                .glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)
        } else {
            VisualEffectBlur().clipShape(shape)
        }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
