import SwiftUI
import Combine

// MARK: - Posisi kursor di dalam panel (diisi oleh NotchWindowController)

/// Dipisah dari NotchViewModel supaya cuma glow yang digambar ulang saat kursor bergerak,
/// bukan seluruh isi panel.
@MainActor
final class CursorTracker: ObservableObject {
    static let shared = CursorTracker()
    /// Koordinat SwiftUI (0,0 = kiri atas panel). nil = kursor di luar panel.
    @Published var location: CGPoint?
    private init() {}
}

// MARK: - Glow putih yang mengikuti kursor (saat belum ada musik)

struct CursorGlow: View {
    /// Tinggi zona hitam notch — glow tidak boleh masuk ke sini supaya sambungan tetap mulus
    let notchHeight: CGFloat
    @ObservedObject private var tracker = CursorTracker.shared
    @State private var lastPoint: CGPoint = .zero

    private let radius: CGFloat = 170

    var body: some View {
        GeometryReader { geo in
            let point = tracker.location ?? lastPoint
            let tb = min(notchHeight / max(geo.size.height, 1), 0.9)

            RadialGradient(colors: [.white.opacity(0.13), .white.opacity(0.04), .clear],
                           center: .center, startRadius: 0, endRadius: radius)
                .frame(width: radius * 2, height: radius * 2)
                .position(point)
                // Ikut kursor dengan sedikit delay (spring) supaya halus
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: point)
                .opacity(tracker.location == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.3), value: tracker.location == nil)
                // Jangan terangi zona hitam di sekitar notch
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: tb),
                        .init(color: .black, location: min(tb + 0.12, 1)),
                        .init(color: .black, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(width: geo.size.width, height: geo.size.height)
                )
                .onChange(of: tracker.location) { _, new in
                    if let new { lastPoint = new } // simpan posisi terakhir untuk fade-out
                }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}
