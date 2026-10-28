import SwiftUI
import AppKit
import AVFoundation
import Combine

// MARK: - Buka / tutup Mirror

@MainActor
extension NotchViewModel {
    func openMirror() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            isExpanded = false
            isMirrorOn = true
        }
        MirrorCamera.shared.start()
    }

    func closeMirror() {
        MirrorCamera.shared.stop() // kamera mati → lampu hijau mati
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            isMirrorOn = false
        }
    }
}

// MARK: - Kamera

@MainActor
final class MirrorCamera: ObservableObject {
    static let shared = MirrorCamera()

    enum Status { case idle, starting, running, failed, denied, noCamera }

    @Published private(set) var status: Status = .idle

    nonisolated(unsafe) let session = AVCaptureSession()
    /// Satu preview dipakai ulang setiap Mirror dibuka (tidak bikin baru tiap kali)
    let previewView = PreviewView()

    private let queue = DispatchQueue(label: "thoch.camera") // semua start/stop berurutan di sini
    private var configured = false
    /// Apakah user masih ingin kamera nyala (false setelah Mirror ditutup)
    private var wanted = false
    private var attempts = 0
    private var errorObserver: NSObjectProtocol?

    private init() {
        previewView.previewLayer.session = session
        // Kalau kamera error di tengah jalan (misal dipakai app lain), coba nyalakan lagi
        errorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryIfWanted() }
        }
    }

    func start() {
        wanted = true
        attempts = 0
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            status = .starting
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.run() } else { self.status = .denied }
                }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        wanted = false
        if status == .running || status == .starting || status == .failed { status = .idle }
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func retry() {
        attempts = 0
        run()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func run() {
        guard wanted else { return }
        if !configured {
            // Utamakan kamera bawaan MacBook (bukan iPhone via Continuity Camera)
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video)
            guard let device,
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                status = .noCamera
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .high
            session.addInput(input)
            session.commitConfiguration()
            configured = true
        }

        status = .starting
        attempts += 1
        // startRunning() memblokir beberapa ratus ms, jadi dijalankan di antrean kamera
        queue.async { [self] in
            if !session.isRunning { session.startRunning() }
            let ok = session.isRunning
            Task { @MainActor in self.didAttemptStart(ok) }
        }
    }

    private func didAttemptStart(_ ok: Bool) {
        // Mirror sudah ditutup sebelum kamera siap → matikan lagi
        guard wanted else {
            queue.async { [self] in if session.isRunning { session.stopRunning() } }
            return
        }
        if ok {
            status = .running
        } else {
            retryIfWanted()
        }
    }

    /// Kamera kadang belum "dilepas" sepenuhnya setelah ditutup → coba lagi sebentar kemudian
    private func retryIfWanted() {
        guard wanted else { return }
        guard attempts < 3 else {
            status = .failed
            return
        }
        status = .starting
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            self.run()
        }
    }
}

// MARK: - Tampilan Mirror

struct MirrorContent: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject private var camera = MirrorCamera.shared
    @State private var hovering = false

    private var diameter: CGFloat { model.mirrorDiameter }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: model.notchSize.height + model.mirrorTopPadding)

            ZStack(alignment: .bottom) {
                preview
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    // Vignette halus: tepi lingkaran menyatu dengan panel gelap
                    .overlay(
                        Circle().fill(RadialGradient(colors: [.clear, .black.opacity(0.28)],
                                                     center: .center,
                                                     startRadius: diameter * 0.32,
                                                     endRadius: diameter * 0.5))
                            .allowsHitTesting(false)
                    )
                    // Bingkai kaca: pantulan cahaya melingkar, bukan garis rata
                    .overlay(
                        Circle().strokeBorder(
                            AngularGradient(colors: [.white.opacity(0.55), .white.opacity(0.08),
                                                     .white.opacity(0.35), .white.opacity(0.06),
                                                     .white.opacity(0.55)],
                                            center: .center),
                            lineWidth: 1.5)
                    )
                    .shadow(color: .white.opacity(0.06), radius: 14)

                // Tombol tutup, cuma muncul saat kursor di atas preview
                if hovering && camera.status == .running {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .contentShape(Circle())
            .onTapGesture { model.closeMirror() } // klik di mana saja di preview = tutup
            .onHover { inside in
                withAnimation(.snappy(duration: 0.2)) { hovering = inside }
            }
            .animation(.easeOut(duration: 0.35), value: camera.status)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var preview: some View {
        switch camera.status {
        case .running:
            CameraPreview()
                // Masuk: fade + sedikit zoom-out
                .transition(.opacity.combined(with: .scale(scale: 1.08)))
        case .failed:
            MirrorMessage(icon: "exclamationmark.triangle", title: "Camera didn’t start") {
                SmallButton(title: "Retry") { camera.retry() }
                SmallButton(title: "Close") { model.closeMirror() }
            }
        case .idle, .starting:
            ZStack {
                RadialGradient(colors: [Color.white.opacity(0.1), Color.white.opacity(0.03)],
                               center: .center, startRadius: 0, endRadius: diameter / 2)
                Image(systemName: "camera.fill")
                    .font(.system(size: 22, weight: .medium))
                    .opacity(0.45)
                    .symbolEffect(.pulse)
            }
            .transition(.opacity)
        case .denied:
            MirrorMessage(icon: "video.slash", title: "Camera access is off") {
                SmallButton(title: "Open Settings") { camera.openPrivacySettings() }
                SmallButton(title: "Close") { model.closeMirror() }
            }
        case .noCamera:
            MirrorMessage(icon: "video.slash", title: "No camera found") {
                SmallButton(title: "Close") { model.closeMirror() }
            }
        }
    }
}

struct MirrorMessage<Actions: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22, weight: .medium)).opacity(0.7)
            Text(title).font(.system(size: 12, weight: .semibold))
            actions.frame(width: 120)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
    }
}

// MARK: - Preview kamera (AVCaptureVideoPreviewLayer dibungkus untuk SwiftUI)

struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> PreviewView {
        // Pakai ulang view yang sama (sudah tersambung ke kamera sejak awal)
        let view = MirrorCamera.shared.previewView
        view.removeFromSuperview()
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        // Efek cermin: gambar dibalik kiri-kanan, seperti Photo Booth
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}
