import SwiftUI
import AppKit

// MARK: - Pilihan saat file di-drag ke notch: Tray atau AirDrop

struct DropChoices: View {
    @ObservedObject var model: NotchViewModel
    @State private var trayTargeted = false
    @State private var airDropTargeted = false

    var body: some View {
        HStack(spacing: 12) {
            DropZone(icon: "tray.and.arrow.down",
                     title: "Add to Tray",
                     subtitle: "Keep it here for later",
                     targeted: trayTargeted)
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard !files.isEmpty else { return false }
                    withAnimation(.snappy) {
                        TrayStore.shared.add(files)
                        model.isFileDragging = false
                        model.tab = .files
                    }
                    return true
                } isTargeted: { trayTargeted = $0 }

            DropZone(icon: "dot.radiowaves.left.and.right",
                     title: "AirDrop",
                     subtitle: "Send to a nearby device",
                     targeted: airDropTargeted,
                     tint: Color(nsColor: .systemBlue)) // biru khas AirDrop
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard !files.isEmpty else { return false }
                    withAnimation(.snappy) { model.isFileDragging = false }
                    AirDrop.send(files)
                    return true
                } isTargeted: { airDropTargeted = $0 }
        }
    }
}

struct DropZone: View {
    let icon: String
    let title: String
    let subtitle: String
    let targeted: Bool
    /// Warna ikon & judul (nil = putih)
    var tint: Color? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(tint ?? .white)
                .symbolEffect(.bounce, value: targeted)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint ?? .white)
            Text(subtitle)
                .font(.system(size: 11))
                .opacity(0.55)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(targeted ? 0.14 : 0.06),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(targeted ? Color.trayAccent : Color.white.opacity(0.25),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1,
                                                 dash: targeted ? [] : [6, 5]))
        )
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.snappy(duration: 0.2), value: targeted)
    }
}

// MARK: - AirDrop

@MainActor
enum AirDrop {
    static func send(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { return }
        // Tunggu sesi drag selesai, lalu bawa app ke depan supaya jendela AirDrop terlihat
        DispatchQueue.main.async {
            NSApp.activate()
            service.perform(withItems: urls)
        }
    }
}
