import SwiftUI
import Combine

// MARK: - Toast: notifikasi kecil di bawah notch (pakai slot yang sama dengan HUD)

struct ToastInfo: Equatable {
    let id = UUID()
    let icon: String
    let text: String
}

@MainActor
final class ToastController: ObservableObject {
    static let shared = ToastController()

    @Published private(set) var current: ToastInfo?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(icon: String, text: String, duration: Double = 1.8) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
            current = ToastInfo(icon: icon, text: text)
        }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { current = nil }
        }
    }
}

struct ToastView: View {
    let toast: ToastInfo
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: notchHeight)
            HStack(spacing: 8) {
                Image(systemName: toast.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text(toast.text)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
    }
}
