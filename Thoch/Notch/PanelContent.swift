import SwiftUI

// MARK: - Isi panel: top bar + halaman aktif

struct ExpandedContent: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TopBar(model: model)

            ZStack(alignment: .topLeading) {
                if model.isFileDragging {
                    // File sedang di-drag dari luar → pilih Tray atau AirDrop
                    DropChoices(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    page(for: model.tab)
                        .id(model.tab)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.bottom, 20) // jarak kartu ke tepi bawah panel
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        // Seluruh panel jadi tempat drop file → masuk Tray
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            withAnimation(.snappy) {
                TrayStore.shared.add(files)
                model.isFileDragging = false
                model.tab = .files
            }
            return true
        } isTargeted: { targeted in
            model.isDropTargeted = targeted
        }
    }

    @ViewBuilder
    private func page(for tab: NotchTab) -> some View {
        switch tab {
        case .home:
            HomePage()
        case .media:
            MediaPage()
        case .files:
            FilesPage(model: model)
        case .clipboard:
            ClipboardPage()
        case .productivity:
            ProductivityPage()
        case .settings:
            SettingsPage()
        }
    }
}

// MARK: - Baris atas (di zona hitam, mengapit notch)

struct TopBar: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(NotchTab.mainTabs) { tab in
                    IconButton(icon: tab.icon, active: model.tab == tab) { select(tab) }
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))

            Spacer(minLength: model.notchSize.width + 20)

            HStack(spacing: 2) {
                IconButton(icon: "camera.viewfinder", active: false) { ScreenshotTool.capture(model: model) }
                    .help("Screenshot to Tray")
                IconButton(icon: "camera", active: false) { model.openMirror() }
                IconButton(icon: NotchTab.settings.icon, active: model.tab == .settings) {
                    select(model.tab == .settings ? .home : .settings)
                }
            }
        }
        .frame(height: model.notchSize.height)
    }

    private func select(_ tab: NotchTab) {
        withAnimation(.snappy(duration: 0.25)) { model.tab = tab }
    }
}

struct IconButton: View {
    let icon: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 22)
                .background(
                    active ? Color.white.opacity(0.18) : (hovering ? Color.white.opacity(0.08) : .clear),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .opacity(active ? 1 : (hovering ? 0.85 : 0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
