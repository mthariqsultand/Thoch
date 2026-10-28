import SwiftUI

// MARK: - Data anniversary (disimpan di Settings)

@MainActor
enum Anniversary {
    static let enabledKey = "annivEnabled"
    static let monthlyKey = "annivMonthly"
    static let showNotchKey = "annivShowNotch"   // tampilkan terus di notch (bukan cuma hari H)
    static let modeKey = "annivMode"              // "together" / "countdown"

    enum Mode: String, CaseIterable {
        case together, countdown
    }

    static let pink = Color(red: 1.0, green: 0.45, blue: 0.68)
    /// Ikut accent color; mode Colorful → pink
    static var color: Color { Theme.choice.color ?? pink }

    /// Tanggal jadian: 9 Juli 2024
    static let startDate: Date = Calendar.current.date(from: DateComponents(year: 2024, month: 7, day: 9)) ?? Date()

    struct Status {
        let dayNumber: Int          // hari ke-berapa (hari jadian = hari ke-1)
        let years: Int
        let totalMonths: Int
        let isAnniversaryToday: Bool
        let isMonthsaryToday: Bool
        let daysToNextAnniversary: Int
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var monthly: Bool { UserDefaults.standard.bool(forKey: monthlyKey) }
    static var alwaysInNotch: Bool { UserDefaults.standard.bool(forKey: showNotchKey) }
    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .together }

    static func status(on date: Date = Date()) -> Status? {
        guard isEnabled else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        let today = cal.startOfDay(for: date)
        guard today >= start else { return nil }

        let days = cal.dateComponents([.day], from: start, to: today).day ?? 0
        let ym = cal.dateComponents([.year, .month], from: start, to: today)
        let years = ym.year ?? 0
        let totalMonths = years * 12 + (ym.month ?? 0)

        let s = cal.dateComponents([.month, .day], from: start)
        let t = cal.dateComponents([.month, .day], from: today)
        let isAnniversary = years > 0 && s.month == t.month && s.day == t.day
        let isMonthsary = !isAnniversary && totalMonths > 0 && s.day == t.day

        let next = isAnniversary ? today : (cal.date(byAdding: .year, value: years + 1, to: start) ?? today)
        let toNext = cal.dateComponents([.day], from: today, to: next).day ?? 0

        return Status(dayNumber: days + 1, years: years, totalMonths: totalMonths,
                      isAnniversaryToday: isAnniversary, isMonthsaryToday: isMonthsary,
                      daysToNextAnniversary: toNext)
    }

    /// Hari ini hari spesial? (anniversary, atau mensive kalau dinyalakan)
    static var isSpecialToday: Bool {
        guard let s = status() else { return false }
        return s.isAnniversaryToday || (monthly && s.isMonthsaryToday)
    }

    /// Tampilkan hati di notch yang tertutup: selalu (kalau "Show in notch" aktif) atau cuma di hari spesial
    static var showInNotch: Bool {
        guard status() != nil else { return false }
        return alwaysInNotch || isSpecialToday
    }

    /// Label pendek untuk notch: "3 yr" / "28 mo" / "842 days" / "D-254"
    static var notchLabel: String {
        guard let s = status() else { return "" }
        if s.isAnniversaryToday { return "\(s.years) yr" }
        if monthly && s.isMonthsaryToday { return "\(s.totalMonths) mo" }
        switch mode {
        case .together:  return "\(s.dayNumber) days"
        case .countdown: return "D-\(s.daysToNextAnniversary)"
        }
    }

    /// Teks chip di Home
    static var homeText: String? {
        guard let s = status() else { return nil }
        if s.isAnniversaryToday { return "Happy \(ordinal(s.years)) anniversary, Oik and Nay!" }
        if monthly && s.isMonthsaryToday { return "Happy \(s.totalMonths) months, Oik and Nay!" }
        if s.daysToNextAnniversary <= 7 {
            return s.daysToNextAnniversary == 1 ? "Oik and Nay's anniversary is tomorrow" : "Oik and Nay's anniversary in \(s.daysToNextAnniversary) days"
        }
        switch mode {
        case .together:  return "Oik and Nay have been together for \(s.dayNumber) days"
        case .countdown: return "\(s.daysToNextAnniversary) days to Oik and Nay's anniversary"
        }
    }

    /// 1st, 2nd, 3rd, 4th, ...
    private static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Chip di Home

struct AnniversaryChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "heart.fill")
                .font(.system(size: 10))
                .symbolEffect(.pulse)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Anniversary.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Anniversary.color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Kartu pengaturan di Settings

struct AnniversarySettingsCard: View {
    @AppStorage(Anniversary.enabledKey) private var enabled = false
    @AppStorage(Anniversary.monthlyKey) private var monthly = false
    @AppStorage(Anniversary.showNotchKey) private var showNotch = false
    @AppStorage(Anniversary.modeKey) private var mode: Anniversary.Mode = .together

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("OIK AND NAY'S ANNIVERSARY REMINDER")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Anniversary.color)
                    Spacer()
                    Toggle("", isOn: $enabled.animation(.snappy))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .tint(Anniversary.color)
                }

                if enabled {
                    HStack(spacing: 18) {
                        Picker("", selection: $mode) {
                            Text("Days together").tag(Anniversary.Mode.together)
                            Text("Countdown").tag(Anniversary.Mode.countdown)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 200)

                        Toggle("Show in notch", isOn: $showNotch)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .tint(Anniversary.color)

                        Toggle("Monthly too", isOn: $monthly)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .tint(Anniversary.color)

                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .transition(.opacity)
                }
            }
        }
    }
}
