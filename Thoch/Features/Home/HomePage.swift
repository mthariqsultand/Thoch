import SwiftUI

// MARK: - Home

struct HomePage: View {
    @AppStorage("userName") private var userName = ""
    // Supaya chip anniversary ikut berubah saat pengaturannya diubah
    @AppStorage(Anniversary.enabledKey) private var annivEnabled = false
    @AppStorage(Anniversary.monthlyKey) private var annivMonthly = false
    @AppStorage(Anniversary.modeKey) private var annivMode: Anniversary.Mode = .together

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(greeting)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                if userName.isEmpty {
                    Text("Set your name in ⚙︎")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.45)
                }
                Spacer(minLength: 0)
                if let text = Anniversary.homeText {
                    AnniversaryChip(text: text)
                }
            }

            HStack(spacing: 12) {
                NowPlayingCard()
                CalendarCard(compact: true)
                TimerSummaryCard()
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let base = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return userName.isEmpty ? base : "\(base), \(userName)"
    }
}
