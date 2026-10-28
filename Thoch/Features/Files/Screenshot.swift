import SwiftUI
import AppKit

// MARK: - Screenshot area → langsung masuk Tray

@MainActor
enum ScreenshotTool {
    /// Simpan referensi proses selama berjalan
    private static var running: Process?
    /// Folder: ~/Pictures/Thoch Screenshots
    private static var folder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let dir = pictures.appendingPathComponent("Thoch Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func capture(model: NotchViewModel) {
        // Tutup panel dulu supaya tidak menghalangi area yang mau di-screenshot
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.isExpanded = false }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent("Screenshot \(formatter.string(from: Date())).png")

        // Tunggu animasi tutup selesai, lalu jalankan screenshot bawaan macOS (-i = pilih area)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", url.path]
            process.terminationHandler = { _ in
                Task { @MainActor in
                    running = nil
                    // Kalau user menekan Esc, file tidak dibuat → tidak terjadi apa-apa
                    guard FileManager.default.fileExists(atPath: url.path) else { return }
                    TrayStore.shared.add([url])
                    ToastController.shared.show(icon: "camera.viewfinder", text: "Screenshot added to Tray")
                }
            }
            running = process
            try? process.run()
        }
    }
}
