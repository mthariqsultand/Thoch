import SwiftUI
import AppKit
import EventKit
import Combine

// MARK: - Data agenda

struct AgendaItem: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let isTomorrow: Bool
    let color: Color
}

/// Membaca agenda hari ini dari app Calendar bawaan Mac (iCloud, Google, dll yang tersambung)
@MainActor
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()

    enum Access { case notDetermined, granted, denied }

    @Published private(set) var access: Access = .notDetermined
    @Published private(set) var items: [AgendaItem] = []

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    private init() {
        refreshAccess()
        // Update otomatis kalau ada agenda baru / berubah
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged,
                                                          object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func requestAccess() {
        let model = self
        store.requestFullAccessToEvents { _, _ in
            Task { @MainActor in
                model.refreshAccess()
                model.reload()
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:    access = .granted
        case .notDetermined: access = .notDetermined
        default:             access = .denied // denied, restricted, write-only
        }
    }

    /// Agenda hari ini (yang belum selesai) + besok. Urut: hari, all-day dulu, lalu jam mulai.
    func reload() {
        refreshAccess()
        guard access == .granted else { items = []; return }

        let now = Date()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        guard let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday),
              let endOfTomorrow = cal.date(byAdding: .day, value: 2, to: startOfToday) else { return }

        // Agenda yang mulai besok (atau all-day besok) dihitung "Tomorrow"
        func isTomorrow(_ e: EKEvent) -> Bool { e.startDate >= startOfTomorrow }

        let predicate = store.predicateForEvents(withStart: startOfToday, end: endOfTomorrow, calendars: nil)
        items = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted {
                (isTomorrow($0) ? 1 : 0, $0.isAllDay ? 0 : 1, $0.startDate) <
                (isTomorrow($1) ? 1 : 0, $1.isAllDay ? 0 : 1, $1.startDate)
            }
            .map { event in
                AgendaItem(
                    // Event berulang punya identifier sama, jadi tambahkan jam mulainya
                    id: "\(event.eventIdentifier ?? "event")-\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "Untitled",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    isTomorrow: isTomorrow(event),
                    color: Color(nsColor: event.calendar?.color ?? .systemBlue)
                )
            }
    }
}

// MARK: - Kartu Calendar

struct CalendarCard: View {
    /// compact = versi Home (tanpa tanggal besar)
    var compact = false
    @ObservedObject private var calendar = CalendarStore.shared

    /// Versi lengkap muat 3 agenda, versi Home 2
    private var maxItems: Int { compact ? 2 : 3 }
    private var red: Color { Theme.calendar }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                if compact {
                    Text("NEXT UP")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(red)
                } else {
                    // Tanggal & hari dalam satu baris (hemat tempat untuk agenda)
                    HStack(alignment: .center, spacing: 8) {
                        Text(Date.now.formatted(.dateTime.day()))
                            .font(.system(size: 24, weight: .bold).monospacedDigit())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Date.now.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(red)
                            Text(Date.now.formatted(.dateTime.month(.abbreviated)))
                                .font(.system(size: 10, weight: .medium))
                                .opacity(0.5)
                        }
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                }
                content
                Spacer(minLength: 0)
            }
        }
        .onAppear { calendar.reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch calendar.access {
        case .notDetermined:
            Text("See today’s events here")
                .font(.system(size: 10))
                .opacity(0.5)
            SmallButton(title: "Allow access") { calendar.requestAccess() }

        case .denied:
            Text("No calendar access")
                .font(.system(size: 10))
                .opacity(0.5)
            SmallButton(title: "Open Settings") { calendar.openPrivacySettings() }

        case .granted:
            if calendar.items.isEmpty {
                Text("Nothing today or tomorrow")
                    .font(.system(size: 11))
                    .opacity(0.5)
            } else {
                ForEach(calendar.items.prefix(maxItems)) { item in
                    EventRow(item: item)
                }
                if calendar.items.count > maxItems {
                    Text("+\(calendar.items.count - maxItems) more")
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.45)
                }
            }
        }
    }
}

struct EventRow: View {
    let item: AgendaItem

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(item.color)
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(timeText)
                    .font(.system(size: 10))
                    .opacity(0.55)
                    .lineLimit(1)
            }
        }
    }

    private var timeText: String {
        let day = item.isTomorrow ? "Tomorrow · " : ""
        if item.isAllDay { return day + "All day" }
        let start = item.start.formatted(date: .omitted, time: .shortened)
        let end = item.end.formatted(date: .omitted, time: .shortened)
        if item.start <= .now { return "Now · until \(end)" }
        return day + "\(start) – \(end)"
    }
}

struct SmallButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
