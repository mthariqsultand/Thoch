import SwiftUI
import ServiceManagement

// MARK: - Settings (muat dalam satu layar, tanpa scroll)

struct SettingsPage: View {
    @AppStorage("userName") private var userName = ""
    @AppStorage(Theme.storageKey) private var accent: AccentChoice = .colorful
    /// Status dibaca langsung dari macOS (bukan disimpan sendiri), supaya selalu sinkron
    /// dengan System Settings → General → Login Items
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Baris atas: Profile + Accent
            HStack(spacing: 10) {
                GlassCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("PROFILE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.primary)
                            Spacer()
                            Toggle("Open at login", isOn: Binding(
                                get: { openAtLogin },
                                set: { setOpenAtLogin($0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 10, weight: .medium))
                            .tint(Theme.primary)
                        }
                        TextField("Your name", text: $userName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .frame(width: 250)

                GlassCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("ACCENT")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.primary)
                            Spacer()
                            Text(accent == .colorful ? "Colorful (default)" : accent.label)
                                .font(.system(size: 10, weight: .medium))
                                .opacity(0.55)
                        }
                        HStack(spacing: 10) {
                            ForEach(AccentChoice.allCases) { choice in
                                AccentSwatch(choice: choice, selected: accent == choice) {
                                    accent = choice
                                }
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
            }
            .frame(height: 76)

            // Baris bawah: Anniversary
            AnniversarySettingsCard()

            Text("Made with love for Nay Cantik from Oik ❤️")
                .font(.system(size: 10, weight: .medium))
                .opacity(0.45)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Daftarkan / hapus Thoch dari Login Items
    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Gagal (misal butuh persetujuan) → buka halaman Login Items di System Settings
            SMAppService.openSystemSettingsLoginItems()
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
