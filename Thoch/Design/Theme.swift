import SwiftUI

// MARK: - Pilihan accent color (disimpan di Settings)

enum AccentChoice: String, CaseIterable, Identifiable {
    case colorful, blue, purple, pink, red, orange, yellow, green, mint

    var id: String { rawValue }

    var label: String {
        switch self {
        case .colorful: "Colorful"
        case .blue:     "Blue"
        case .purple:   "Purple"
        case .pink:     "Pink"
        case .red:      "Red"
        case .orange:   "Orange"
        case .yellow:   "Yellow"
        case .green:    "Green"
        case .mint:     "Mint"
        }
    }

    /// nil = Colorful (tiap fitur punya warna sendiri)
    var color: Color? {
        switch self {
        case .colorful: nil
        case .blue:     Color(red: 0.35, green: 0.66, blue: 1.00)
        case .purple:   Color(red: 0.69, green: 0.52, blue: 1.00)
        case .pink:     Color(red: 1.00, green: 0.45, blue: 0.72)
        case .red:      Color(red: 1.00, green: 0.42, blue: 0.37)
        case .orange:   Color(red: 1.00, green: 0.62, blue: 0.25)
        case .yellow:   Color(red: 1.00, green: 0.83, blue: 0.30)
        case .green:    Color(red: 0.36, green: 0.89, blue: 0.49)
        case .mint:     Color(red: 0.35, green: 0.90, blue: 0.85)
        }
    }
}

// MARK: - Warna yang dipakai di seluruh app

enum Theme {
    static let storageKey = "accentChoice"

    static var choice: AccentChoice {
        AccentChoice(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .colorful
    }

    // Warna default mode Colorful
    static let defaultBlue  = Color(red: 0.35, green: 0.66, blue: 1.00)
    static let defaultAmber = Color(red: 1.00, green: 0.71, blue: 0.28)
    static let defaultGreen = Color(red: 0.36, green: 0.89, blue: 0.49)
    static let defaultRed   = Color(red: 1.00, green: 0.42, blue: 0.37)

    /// Seleksi, drop zone, format terpilih (Files & Convert)
    static var primary: Color  { choice.color ?? defaultBlue }
    /// Timer / Focus
    static var focus: Color    { choice.color ?? defaultAmber }
    /// Notes & To-do
    static var notes: Color    { choice.color ?? defaultGreen }
    /// Calendar
    static var calendar: Color { choice.color ?? defaultRed }
}

// MARK: - Tombol pilihan warna (bulatan)

struct AccentSwatch: View {
    let choice: AccentChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color = choice.color {
                    Circle().fill(color)
                } else {
                    // Colorful: gabungan warna default
                    Circle().fill(AngularGradient(colors: [Theme.defaultBlue, Theme.defaultGreen,
                                                           Theme.defaultAmber, Theme.defaultRed,
                                                           Theme.defaultBlue],
                                                  center: .center))
                }
            }
            .frame(width: 24, height: 24)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .padding(-4)
                    .opacity(selected ? 1 : 0)
            )
            .scaleEffect(selected ? 1 : 0.9)
            .animation(.snappy(duration: 0.2), value: selected)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(choice.label)
    }
}
