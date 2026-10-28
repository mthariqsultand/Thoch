import SwiftUI
import AppKit
import Combine

// MARK: - Data Notes & To-do

struct NoteEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var isTodo = true
    var done = false
}

/// Notes & to-do, disimpan sebagai JSON di ~/Library/Application Support/Thoch/notes.json
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var entries: [NoteEntry] = []

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Thoch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.json")
    }()

    private init() { load() }

    var openTodos: Int { entries.filter { $0.isTodo && !$0.done }.count }
    var hasDone: Bool { entries.contains { $0.isTodo && $0.done } }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        entries.append(NoteEntry(text: t))
        save()
    }

    func toggleDone(_ entry: NoteEntry) {
        update(entry) { $0.done.toggle() }
    }

    func toggleType(_ entry: NoteEntry) {
        update(entry) { $0.isTodo.toggle(); $0.done = false }
    }

    func delete(_ entry: NoteEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clearDone() {
        entries.removeAll { $0.isTodo && $0.done }
        save()
    }

    private func update(_ entry: NoteEntry, _ change: (inout NoteEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        change(&entries[i])
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([NoteEntry].self, from: data) else { return }
        entries = saved
    }
}

// MARK: - Focus timer (tetap jalan walau panel ditutup)

@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()

    enum State { case idle, running, paused, finished }

    @Published private(set) var duration: TimeInterval = 25 * 60
    @Published private(set) var remaining: TimeInterval = 25 * 60
    @Published private(set) var state: State = .idle

    private var endDate: Date?
    private var ticker: Timer?

    private init() {}

    /// Sisa waktu dalam proporsi 0…1 (untuk ring)
    var fraction: Double { duration > 0 ? remaining / duration : 0 }

    func start() {
        if state == .finished { remaining = duration }
        guard remaining > 0 else { return }
        endDate = Date().addingTimeInterval(remaining)
        state = .running
        startTicker()
    }

    func pause() {
        tick()
        endDate = nil
        ticker?.invalidate()
        state = .paused
    }

    func reset() {
        endDate = nil
        ticker?.invalidate()
        remaining = duration
        state = .idle
    }

    func addMinutes(_ m: Double) {
        duration += m * 60
        remaining += m * 60
        if let end = endDate { endDate = end.addingTimeInterval(m * 60) }
    }

    func setPreset(minutes m: Double) {
        guard state == .idle else { return }
        duration = min(max(m, 1), 180) * 60
        remaining = duration
    }

    /// Atur durasi per menit (cuma sebelum timer mulai), 1–180 menit
    func adjustDuration(byMinutes m: Double) {
        setPreset(minutes: (duration / 60).rounded() + m)
    }

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining == 0 { finish() }
    }

    private func finish() {
        endDate = nil
        ticker?.invalidate()
        state = .finished
        NSSound(named: "Glass")?.play()
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - Halaman Productivity

struct ProductivityPage: View {
    var body: some View {
        HStack(spacing: 12) {
            NotesCard()                 // sisa lebar (±248)
            TimerSummaryCard(expanded: true) // + custom durasi & progress bar
                .frame(width: 176)
            CalendarCard()
                .frame(width: 152)
        }
    }
}

// MARK: - Kartu Notes & To-do

struct NotesCard: View {
    @ObservedObject private var store = NotesStore.shared
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                // Header seragam dengan kartu lain: label kapital berwarna
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("NOTES")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.notes)
                    if store.openTodos > 0 {
                        Text("\(store.openTodos) to do")
                            .font(.system(size: 10, weight: .medium))
                            .opacity(0.5)
                    }
                    Spacer()
                    if store.hasDone {
                        Button("Clear done") {
                            withAnimation(.snappy) { store.clearDone() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.6)
                    }
                }

                if store.entries.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checklist")
                            .font(.system(size: 18, weight: .medium))
                        Text("No notes yet")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Type below and press Return")
                            .font(.system(size: 10))
                            .opacity(0.7)
                    }
                    .opacity(0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(store.entries) { entry in
                                NoteRow(entry: entry)
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.5)
                    TextField("Add a to-do…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($fieldFocused)
                        .onSubmit {
                            withAnimation(.snappy) { store.add(draft) }
                            draft = ""
                            fieldFocused = true // tetap fokus, biar bisa langsung ngetik lagi
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }
}

struct NoteRow: View {
    let entry: NoteEntry
    private var store: NotesStore { .shared }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if entry.isTodo {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { store.toggleDone(entry) }
                } label: {
                    Image(systemName: entry.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(entry.done ? Theme.notes : .white.opacity(0.5))
                }
                .buttonStyle(.plain)

                Text(entry.text)
                    .font(.system(size: 12, weight: .medium))
                    .strikethrough(entry.done)
                    .opacity(entry.done ? 0.4 : 0.9)
            } else {
                // Catatan bebas (tanpa checkbox)
                Text(entry.text)
                    .font(.system(size: 11).italic())
                    .opacity(0.6)
            }
        }
        .contextMenu {
            Button(entry.isTodo ? "Make it a note" : "Make it a to-do") {
                withAnimation(.snappy) { store.toggleType(entry) }
            }
            Divider()
            Button("Delete") {
                withAnimation(.snappy) { store.delete(entry) }
            }
        }
    }
}

// MARK: - Kartu Timer ringkas (Home)

struct TimerSummaryCard: View {
    /// true = versi tab Productivity (ada custom durasi & progress bar)
    var expanded = false
    @ObservedObject private var timer = FocusTimer.shared
    private var amber: Color { Theme.focus }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                // Atas: ring + status & sisa waktu
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.14), lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: timer.fraction)
                            .stroke(amber, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.25), value: timer.fraction)
                        Image(systemName: timer.state == .running ? "hourglass" : "timer")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(amber)
                    }
                    .frame(width: expanded ? 52 : 46, height: expanded ? 52 : 46) // Home: ring sedikit kecil, angka lebih besar

                    VStack(alignment: .leading, spacing: 1) {
                        Text(caption)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(amber)
                            .lineLimit(1)
                        Text(FocusTimer.format(timer.remaining))
                            .font(.system(size: expanded ? 24 : 34, weight: .bold).monospacedDigit()) // angka = elemen paling dominan
                            .lineLimit(1)                // jangan pernah pecah ke baris bawah
                            .minimumScaleFactor(0.6)     // kalau sempit, font mengecil
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy, value: Int(timer.remaining))
                    }
                    .layoutPriority(1) // teks dapat ruang duluan, bukan ring
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 6)
                middleRow
                Spacer(minLength: 6)

                // Bawah: tombol utama + tombol kedua
                HStack(spacing: 6) {
                    Button {
                        timer.state == .running ? timer.pause() : timer.start()
                    } label: {
                        Text(buttonTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(timer.state == .running ? Color.white : Color.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(timer.state == .running ? Color.white.opacity(0.12) : amber.opacity(0.9),
                                        in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        timer.state == .running ? timer.addMinutes(5) : timer.reset()
                    } label: {
                        Text(timer.state == .running ? "+5 min" : "Reset")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(timer.state == .idle)
                    .opacity(timer.state == .idle ? 0.4 : 1)
                }
            }
        }
    }

    /// Baris tengah: isinya menyesuaikan status timer
    @ViewBuilder
    private var middleRow: some View {
        switch timer.state {
        case .idle:
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach([5.0, 15, 25, 50], id: \.self) { m in
                        let on = timer.duration == m * 60
                        Button("\(Int(m))m") { timer.setPreset(minutes: m) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(on ? amber.opacity(0.3) : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .opacity(on ? 1 : 0.7)
                    }
                }
                if expanded { durationStepper }
            }
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                if expanded { progressBar }
                Text("Ends at \(Date().addingTimeInterval(timer.remaining).formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.55)
            }
        case .paused:
            Text("Paused · tap Resume to continue")
                .font(.system(size: 11, weight: .medium))
                .opacity(0.55)
        case .finished:
            Text("Session complete")
                .font(.system(size: 11, weight: .medium))
                .opacity(0.55)
        }
    }

    /// − 25 min +  (tahan tombol untuk mengubah terus)
    private var durationStepper: some View {
        HStack(spacing: 0) {
            stepButton("minus") { timer.adjustDuration(byMinutes: -1) }
            Spacer(minLength: 0)
            Text("\(Int((timer.duration / 60).rounded())) min")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy, value: timer.duration)
            Spacer(minLength: 0)
            stepButton("plus") { timer.adjustDuration(byMinutes: 1) }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 20)
                .background(Color.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(amber).frame(width: geo.size.width * (1 - timer.fraction))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.25), value: timer.fraction)
    }

    private var caption: String {
        switch timer.state {
        case .idle: "FOCUS"
        case .running: "FOCUSING"
        case .paused: "PAUSED"
        case .finished: "DONE!"
        }
    }

    private var buttonTitle: String {
        switch timer.state {
        case .running: "Pause"
        case .paused: "Resume"
        case .finished: "Again"
        case .idle: "Start"
        }
    }
}
