import SwiftUI
import AppKit
import Combine
import QuickLookThumbnailing

// MARK: - Data Tray

struct TrayItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
}

/// Menyimpan daftar file di Tray. File TIDAK disalin — cuma referensi ke lokasi aslinya.
final class TrayStore: ObservableObject {
    static let shared = TrayStore()

    @Published private(set) var items: [TrayItem] = []
    private let key = "trayPaths"

    private init() { load() }

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let clean = url.standardizedFileURL
            guard !items.contains(where: { $0.url == clean }) else { continue } // hindari duplikat
            items.append(TrayItem(url: clean))
        }
        save()
    }

    func remove(_ item: TrayItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Buang item yang file aslinya sudah dipindah / dihapus
    func pruneMissing() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        if items.count != before { save() }
    }

    // Disimpan antar-launch (app tidak di-sandbox, jadi path biasa cukup)
    private func save() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: key)
    }

    private func load() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { TrayItem(url: $0) }
    }
}

// MARK: - Halaman Files: Tray + Convert

struct FilesPage: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject private var tray = TrayStore.shared
    @ObservedObject private var convert = ConvertModel.shared

    private var selectedItem: TrayItem? {
        tray.items.first { $0.id == convert.selectedID }
    }

    var body: some View {
        HStack(spacing: 12) {
            trayCard
            if !tray.items.isEmpty {
                ConvertCard(item: selectedItem)
                    .frame(width: 210)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onAppear { tray.pruneMissing() }
    }

    private var trayCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Tray").font(.system(size: 13, weight: .semibold))
                    Text(tray.items.count == 1 ? "1 item" : "\(tray.items.count) items")
                        .font(.system(size: 11))
                        .opacity(0.5)
                    Spacer()
                    if !tray.items.isEmpty && !convert.isBusy {
                        Button("Clear") {
                            withAnimation(.snappy) {
                                convert.selectedID = nil
                                tray.clear()
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.6)
                    }
                }

                if tray.items.isEmpty {
                    EmptyDropZone(targeted: model.isDropTargeted)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(tray.items) { item in
                                TrayTile(item: item, selected: item.id == convert.selectedID) {
                                    withAnimation(.snappy(duration: 0.2)) { convert.select(item) }
                                }
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                            }
                            DropSlot(targeted: model.isDropTargeted)
                        }
                        .padding(2) // ruang untuk outline tile terpilih
                    }
                    Text("Click to select  ·  drag out to use  ·  right-click for more")
                        .font(.system(size: 10))
                        .opacity(0.4)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.trayAccent, lineWidth: 2)
                .opacity(model.isDropTargeted ? 1 : 0)
        )
        .animation(.snappy(duration: 0.2), value: model.isDropTargeted)
    }
}

// MARK: - Tile file

struct TrayTile: View {
    let item: TrayItem
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            FileThumbnail(url: item.url)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.trayAccent, lineWidth: 2)
                        .opacity(selected ? 1 : 0)
                )
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 80)
                .opacity(selected ? 1 : 0.75)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // Tarik keluar ke Finder / app lain
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("AirDrop…") {
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [item.url])
            }
            Divider()
            Button("Remove from Tray") {
                withAnimation(.snappy) {
                    if ConvertModel.shared.selectedID == item.id { ConvertModel.shared.selectedID = nil }
                    TrayStore.shared.remove(item)
                }
            }
        }
    }
}

/// Thumbnail Quick Look (preview isi file), fallback ke ikon file
struct FileThumbnail: View {
    let url: URL
    var size = CGSize(width: 80, height: 72)
    var corner: CGFloat = 12
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size.width > 40 ? 10 : 2)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: 2,
                representationTypes: .thumbnail
            )
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = rep.nsImage
            }
        }
    }
}

// MARK: - Area drop

struct EmptyDropZone: View {
    let targeted: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22, weight: .medium))
            Text("Drop files here")
                .font(.system(size: 12, weight: .semibold))
            Text("They stay here until you drag them out")
                .font(.system(size: 10))
                .opacity(0.5)
        }
        .opacity(targeted ? 1 : 0.7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(targeted ? 0.08 : 0.03),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted ? Color.trayAccent : Color.white.opacity(0.28),
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}

struct DropSlot: View {
    let targeted: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "plus").font(.system(size: 14, weight: .medium))
            Text("Drop").font(.system(size: 10, weight: .medium))
        }
        .opacity(targeted ? 1 : 0.5)
        .frame(width: 80, height: 72)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(targeted ? Color.trayAccent : Color.white.opacity(0.28),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}

extension Color {
    /// Warna utama (ikut pilihan accent di Settings)
    static var trayAccent: Color { Theme.primary }
}
