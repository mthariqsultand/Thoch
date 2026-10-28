import SwiftUI
import AppKit
import Combine
import AVFoundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Jenis file & format tujuan

enum FileKind {
    case image, document, pdf, audio, unsupported
}

struct ConvertFormat: Identifiable, Hashable {
    let ext: String
    let label: String
    var id: String { ext }
}

enum ConvertError: Error {
    case read, write, unsupported
}

enum Converter {
    // Format tujuan
    static let pdf  = ConvertFormat(ext: "pdf",  label: "PDF")
    static let docx = ConvertFormat(ext: "docx", label: "DOCX")
    static let rtf  = ConvertFormat(ext: "rtf",  label: "RTF")
    static let txt  = ConvertFormat(ext: "txt",  label: "TXT")
    static let m4a  = ConvertFormat(ext: "m4a",  label: "M4A")
    static let wav  = ConvertFormat(ext: "wav",  label: "WAV")
    static let aiff = ConvertFormat(ext: "aiff", label: "AIFF")

    /// Format gambar yang benar-benar bisa ditulis oleh macOS ini (+ PDF)
    static let imageFormats: [ConvertFormat] = {
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        let candidates: [(String, String, UTType)] = [
            ("png", "PNG", .png), ("jpg", "JPG", .jpeg), ("heic", "HEIC", .heic),
            ("webp", "WebP", .webP), ("tiff", "TIFF", .tiff)
        ]
        return candidates
            .filter { writable.contains($0.2.identifier) }
            .map { ConvertFormat(ext: $0.0, label: $0.1) } + [Converter.pdf]
    }()

    private static let wordTypes: [UTType] = [
        UTType("org.openxmlformats.wordprocessingml.document"), // .docx
        UTType("com.microsoft.word.doc")                        // .doc
    ].compactMap { $0 }

    static func kind(of url: URL) -> FileKind {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .unsupported }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .rtf) || t.conforms(to: .plainText) || t.conforms(to: .html)
            || wordTypes.contains(where: { t.conforms(to: $0) }) {
            return .document
        }
        return .unsupported
    }

    /// Pilihan format sesuai jenis file, tanpa format asalnya sendiri
    static func formats(for url: URL) -> [ConvertFormat] {
        let source = normalized(url.pathExtension)
        let list: [ConvertFormat]
        switch kind(of: url) {
        case .image:       list = imageFormats
        case .document:    list = [pdf, docx, rtf, txt]
        case .pdf:         list = [txt]
        case .audio:       list = [m4a, wav, aiff]
        case .unsupported: list = []
        }
        return list.filter { $0.ext != source }
    }

    static func normalized(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": return "jpg"
        case "tif":  return "tiff"
        case "aif":  return "aiff"
        default:     return ext.lowercased()
        }
    }

    /// Hasil disimpan di folder yang sama: "foto.png", "foto 2.png", dst.
    static func outputURL(for source: URL, ext: String) -> URL {
        var dir = source.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: dir.path),
           let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            dir = downloads
        }
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    // MARK: Gambar (jalan di background)

    nonisolated static func convertImage(_ src: URL, toExt ext: String, out: URL) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { throw ConvertError.read }

        if ext == "pdf" {
            // Ambil gambar dengan orientasi yang benar (foto iPhone sering diputar via metadata)
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 20_000
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
                throw ConvertError.read
            }
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw ConvertError.write }
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: box)
            ctx.endPDFPage()
            ctx.closePDF()
            return
        }

        let type: UTType
        switch ext {
        case "jpg":  type = .jpeg
        case "heic": type = .heic
        case "webp": type = .webP
        case "tiff": type = .tiff
        default:     type = .png
        }
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError.unsupported
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImageFromSource(dest, source, 0, props as CFDictionary) // metadata ikut terbawa
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.write }
    }

    // MARK: Audio (jalan di background, dengan progress)

    nonisolated static func convertAudio(_ src: URL, toExt ext: String, out: URL,
                                         progress: @escaping @Sendable (Double) -> Void) throws {
        let input = try AVAudioFile(forReading: src)
        let format = input.processingFormat

        var settings: [String: Any] = [
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        switch ext {
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 256_000
        case "wav", "aiff":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = (ext == "aiff") // AIFF = big endian
        default:
            throw ConvertError.unsupported
        }

        do {
            let output = try AVAudioFile(forWriting: out, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
                throw ConvertError.read
            }
            let total = Double(max(input.length, 1))
            var lastReported = 0.0
            while input.framePosition < input.length {
                if Task.isCancelled { throw CancellationError() }
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
                let p = Double(input.framePosition) / total
                if p - lastReported >= 0.01 {
                    lastReported = p
                    progress(p)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: out) // buang file setengah jadi
            throw error
        }
    }

    // MARK: Dokumen (main thread — cepat, dan NSTextView wajib di main thread)

    @MainActor
    static func convertDocument(_ src: URL, toExt ext: String, out: URL) throws {
        let attr: NSAttributedString
        if src.pathExtension.lowercased() == "pdf" {
            guard let text = PDFDocument(url: src)?.string else { throw ConvertError.read }
            attr = NSAttributedString(string: text)
        } else {
            // Otomatis mengenali DOCX, DOC, RTF, HTML, TXT
            attr = try NSAttributedString(url: src, options: [:], documentAttributes: nil)
        }
        let range = NSRange(location: 0, length: attr.length)

        switch ext {
        case "txt":
            try attr.string.write(to: out, atomically: true, encoding: .utf8)
        case "rtf":
            let data = try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: out)
        case "docx":
            let data = try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: out)
        case "pdf":
            try writePDF(attr, to: out)
        default:
            throw ConvertError.unsupported
        }
    }

    /// Render teks ke PDF ukuran A4 lewat sistem print macOS (tanpa dialog)
    @MainActor
    private static func writePDF(_ attr: NSAttributedString, to url: URL) throws {
        let page = NSSize(width: 595, height: 842) // A4 dalam point
        let margin: CGFloat = 56

        let info = NSPrintInfo()
        info.paperSize = page
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary().setObject(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0,
                                                width: page.width - margin * 2,
                                                height: page.height - margin * 2))
        textView.appearance = NSAppearance(named: .aqua) // paksa teks gelap di kertas putih
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attr)
        textView.sizeToFit()

        let op = NSPrintOperation(view: textView, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw ConvertError.write }
    }

    static func message(for error: Error) -> String {
        if let e = error as? ConvertError {
            switch e {
            case .read:        return "Couldn’t read this file."
            case .write:       return "Couldn’t save the result."
            case .unsupported: return "This conversion isn’t supported."
            }
        }
        return error.localizedDescription
    }
}

// MARK: - State convert

@MainActor
final class ConvertModel: ObservableObject {
    static let shared = ConvertModel()

    enum Phase {
        case ready
        case converting(Double)
        case done(URL)
        case failed(String)
    }

    @Published var selectedID: UUID?
    @Published var target: ConvertFormat?
    @Published private(set) var phase: Phase = .ready
    private var job: Task<URL, Error>?

    var isBusy: Bool {
        if case .converting = phase { return true }
        return false
    }

    func select(_ item: TrayItem) {
        guard !isBusy else { return }
        if selectedID == item.id {          // klik lagi = batal pilih
            selectedID = nil
            return
        }
        selectedID = item.id
        phase = .ready
        target = Converter.formats(for: item.url).first
    }

    func deselect() {
        selectedID = nil
        phase = .ready
    }

    func retry() { phase = .ready }

    func cancel() {
        job?.cancel()
        job = nil
        phase = .ready
    }

    func convert(_ item: TrayItem) {
        guard let target, !isBusy else { return }
        let src = item.url
        let ext = target.ext
        let kind = Converter.kind(of: src)
        let out = Converter.outputURL(for: src, ext: ext)
        let model = self
        phase = .converting(0)

        Task {
            do {
                switch kind {
                case .document, .pdf:
                    try Converter.convertDocument(src, toExt: ext, out: out)
                case .image:
                    let job = Task.detached(priority: .userInitiated) {
                        try Converter.convertImage(src, toExt: ext, out: out)
                        return out
                    }
                    self.job = job
                    _ = try await job.value
                case .audio:
                    let job = Task.detached(priority: .userInitiated) {
                        try Converter.convertAudio(src, toExt: ext, out: out) { p in
                            Task { @MainActor in model.updateProgress(p) }
                        }
                        return out
                    }
                    self.job = job
                    _ = try await job.value
                case .unsupported:
                    throw ConvertError.unsupported
                }
                self.job = nil
                TrayStore.shared.add([out])  // hasil masuk Tray
                withAnimation(.snappy) { phase = .done(out) }
            } catch is CancellationError {
                phase = .ready
            } catch {
                self.job = nil
                phase = .failed(Converter.message(for: error))
            }
        }
    }

    private func updateProgress(_ p: Double) {
        if case .converting = phase { phase = .converting(p) }
    }
}

// MARK: - Kartu Convert

struct ConvertCard: View {
    let item: TrayItem?
    @ObservedObject private var convert = ConvertModel.shared

    var body: some View {
        GlassCard {
            if let item {
                switch convert.phase {
                case .converting(let p): converting(item, progress: p)
                case .done(let url):     done(url)
                case .failed(let msg):   failed(msg)
                case .ready:
                    if Converter.kind(of: item.url) == .unsupported {
                        unsupported(item)
                    } else {
                        ready(item)
                    }
                }
            } else {
                emptyState
            }
        }
    }

    // Belum ada file dipilih
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 20, weight: .medium))
            Text("Convert")
                .font(.system(size: 12, weight: .semibold))
            Text("Select a file in Tray")
                .font(.system(size: 10))
                .opacity(0.5)
        }
        .opacity(0.7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Step 1: pilih format
    private func ready(_ item: TrayItem) -> some View {
        let formats = Converter.formats(for: item.url)
        return VStack(alignment: .leading, spacing: 8) {
            FileHeader(item: item)
            Text("Convert to")
                .font(.system(size: 10, weight: .medium))
                .opacity(0.5)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 50), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(formats) { format in
                    FormatChip(label: format.label, selected: convert.target == format) {
                        convert.target = format
                    }
                }
            }
            Spacer(minLength: 0)
            PillButton(title: "Convert to \(convert.target?.label ?? "")") {
                convert.convert(item)
            }
            .disabled(convert.target == nil)
        }
    }

    // Step 2a: sedang proses
    private func converting(_ item: TrayItem, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FileHeader(item: item)
            Text("Converting to \(convert.target?.label ?? "")…")
                .font(.system(size: 12, weight: .medium))
                .opacity(0.85)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.trayAccent)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 10, weight: .medium))
                .opacity(0.5)
            Spacer(minLength: 0)
            if Converter.kind(of: item.url) == .audio {
                PillButton(title: "Cancel", primary: false) { convert.cancel() }
            }
        }
    }

    // Step 2b: selesai
    private func done(_ url: URL) -> some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color(red: 0.36, green: 0.89, blue: 0.49))
            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Added to Tray · drag it out anywhere")
                .font(.system(size: 10))
                .opacity(0.55)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                PillButton(title: "Show in Finder", primary: false, size: 11) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                PillButton(title: "Done", size: 11) {
                    withAnimation(.snappy) { convert.deselect() }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // Gagal
    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
            Text("Couldn’t convert")
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.system(size: 10))
                .opacity(0.55)
            Spacer(minLength: 0)
            PillButton(title: "Try again", primary: false) { convert.retry() }
        }
    }

    // File tidak didukung
    private func unsupported(_ item: TrayItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FileHeader(item: item)
            Spacer(minLength: 0)
            Text("Can’t convert this file")
                .font(.system(size: 12, weight: .semibold))
                .opacity(0.85)
            Text("This type isn’t supported yet. You can still keep it in Tray and drag it out.")
                .font(.system(size: 10))
                .opacity(0.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            PillButton(title: "Convert", primary: false) {}
                .disabled(true)
                .opacity(0.4)
        }
    }
}

// MARK: - Komponen kecil

struct FileHeader: View {
    let item: TrayItem

    var body: some View {
        HStack(spacing: 8) {
            FileThumbnail(url: item.url, size: CGSize(width: 30, height: 30), corner: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 10))
                    .opacity(0.5)
            }
        }
    }

    private var detail: String {
        let kind: String
        switch Converter.kind(of: item.url) {
        case .image:       kind = "Image"
        case .document:    kind = "Document"
        case .pdf:         kind = "PDF"
        case .audio:       kind = "Audio"
        case .unsupported: kind = "File"
        }
        let bytes = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        guard let bytes else { return kind }
        return "\(kind) · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct FormatChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(selected ? Color.trayAccent.opacity(0.3) : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.trayAccent.opacity(selected ? 1 : 0)))
                .opacity(selected ? 1 : 0.8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PillButton: View {
    let title: String
    var primary = true
    var size: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(primary ? Color.black : Color.white)
                .background(Color.white.opacity(primary ? 0.92 : 0.1),
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
