import SwiftUI
import AIQuizCore
import LLMKit
import PhotosUI
import UniformTypeIdentifiers
import VisionKit

/// The Generate screen (SPEC §6, F-19). It builds a job and adds it to the generation queue
/// (F-61); progress and the new quiz appear in the library.
struct GenerateQuizView: View {
    enum Source: String, CaseIterable, Identifiable {
        case topic
        case url
        case document
        case photo
        case paste

        var id: String { rawValue }

        var label: String {
            switch self {
            case .topic: return "Topic"
            case .url: return "Web page"
            case .document: return "Document"
            case .photo: return "Photo"
            case .paste: return "Paste text"
            }
        }

        var icon: String {
            switch self {
            case .topic: return "text.bubble"
            case .url: return "globe"
            case .document: return "doc.text"
            case .photo: return "camera.viewfinder"
            case .paste: return "doc.on.clipboard"
            }
        }
    }

    enum Difficulty: String, CaseIterable, Identifiable {
        case intro, intermediate, advanced
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum Tone: String, CaseIterable, Identifiable {
        case formal, casual
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// A document picked in Files.
    struct PickedDocument: Equatable {
        var name: String
        var bookmark: Data
        var kind: GenerationJob.FileKind
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AIRouter.self) private var router
    @Environment(GenerationQueue.self) private var queue

    @State private var source: Source
    @State private var topic = ""
    @State private var cardCount = 20
    @State private var difficulty: Difficulty = .intermediate
    @State private var language = ""
    @State private var tone: Tone = .formal
    @State private var focus = ""
    @State private var excludeText = ""
    @State private var urlString = ""
    @State private var pasted = ""
    @State private var document: PickedDocument?
    @State private var pickingDocument = false
    @State private var images: [Data] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var scanning = false
    @State private var errorMessage: String?
    @State private var gate = AIGate()

    init(initialSource: Source = .topic) {
        _source = State(initialValue: initialSource)
    }

    var body: some View {
        Form {
            sourceSection
            switch source {
            case .topic: topicSection
            case .url: urlSection
            case .document: documentSection
            case .photo: photoSection
            case .paste: pasteSection
            }
            Section {
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("generate.error")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let note = keptNote { Text(note) }
                    Text("The quiz is made in the background; you can keep studying meanwhile.")
                    Text("Endpoint: \(router.summary(for: .generation))")
                }
                .font(.footnote)
            }
        }
        .navigationTitle("Generate quiz")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("generate.cancel")
            }
            // The primary action: greyed out until the source is filled in, then accent (CR-011).
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    enqueue()
                } label: {
                    Text("Generate").fontWeight(.semibold)
                }
                .primaryActionStyle()
                .disabled(!canGenerate)
                .accessibilityIdentifier("generate.run")
            }
        }
        .fileImporter(isPresented: $pickingDocument, allowedContentTypes: documentTypes, allowsMultipleSelection: false) { result in
            pickDocument(result)
        }
        .sheet(isPresented: $scanning) {
            DocumentScanner { scanned in
                images += scanned.compactMap { $0.jpegData(compressionQuality: 0.8) }
                scanning = false
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItems) { _, items in
            Task { await loadPhotos(items) }
        }
        .aiSetupSheet(gate)
    }

    // MARK: Sections

    private var sourceSection: some View {
        Section {
            Picker("Source", selection: $source) {
                ForEach(Source.allCases) { s in
                    Label(s.label, systemImage: s.icon).tag(s)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("generate.source")
        } header: {
            Text("Source")
        } footer: {
            Text(source == .topic
                 ? "Topic mode lets you set card count, difficulty, language, and tone."
                 : "When you provide a source, the AI decides card count, difficulty, language, tone, and focus from the content. Topic mode if you want fine control.")
        }
    }

    private var topicSection: some View {
        Section("Topic") {
            TextField("e.g. Roman emperors", text: $topic)
                .accessibilityIdentifier("generate.topic")
            Stepper(value: $cardCount, in: 5...50) {
                Text("\(cardCount) cards")
            }
            Picker("Difficulty", selection: $difficulty) {
                ForEach(Difficulty.allCases) { Text($0.label).tag($0) }
            }
            TextField("Output language (optional, default device locale)", text: $language)
                .textInputAutocapitalization(.never)
            Picker("Tone", selection: $tone) {
                ForEach(Tone.allCases) { Text($0.label).tag($0) }
            }
            TextField("Focus areas (optional)", text: $focus, axis: .vertical)
                .lineLimit(1...3)
            TextField("Exclude (optional)", text: $excludeText, axis: .vertical)
                .lineLimit(1...3)
        }
    }

    private var urlSection: some View {
        Section {
            TextField("https://en.wikipedia.org/wiki/…", text: $urlString)
                .accessibilityIdentifier("generate.url")
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            PasteButton(payloadType: URL.self) { urls in
                if let url = urls.first { urlString = url.absoluteString }
            }
            .labelStyle(.titleAndIcon)
        } header: {
            Text("Web page")
        } footer: {
            Text("AIQuiz fetches the page, keeps just the article, and sends that to the AI. A link to a PDF works too.")
        }
    }

    private var documentSection: some View {
        Section {
            Button {
                pickingDocument = true
            } label: {
                Label(document?.name ?? "Pick a PDF or markdown file", systemImage: document?.kind == .pdf ? "doc.richtext" : "doc.text")
            }
            .accessibilityIdentifier("generate.document")
        } header: {
            Text("Document")
        } footer: {
            Text("PDFs are read page by page; scanned pages are read with text recognition.")
        }
    }

    private var photoSection: some View {
        Section {
            if VNDocumentCameraViewController.isSupported {
                Button {
                    scanning = true
                } label: {
                    Label("Scan pages", systemImage: "doc.viewfinder")
                }
                .accessibilityIdentifier("generate.photo.scan")
            }
            PhotosPicker(selection: $photoItems, maxSelectionCount: 20, matching: .images) {
                Label("Choose photos", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("generate.photo.pick")
            if !images.isEmpty {
                HStack {
                    Label("\(images.count) page\(images.count == 1 ? "" : "s") ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Button("Clear", role: .destructive) {
                        images = []
                        photoItems = []
                    }
                    .buttonStyle(.borderless)
                }
                .accessibilityIdentifier("generate.photo.count")
            }
        } header: {
            Text("Photo")
        } footer: {
            Text("The text on the pages is recognised on this device; only the text goes to the AI.")
        }
    }

    private var pasteSection: some View {
        Section {
            TextEditor(text: $pasted)
                .frame(minHeight: 220)
                .accessibilityIdentifier("generate.paste")
            HStack {
                Text("\(pasted.count) characters")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first { pasted = text }
                }
                .labelStyle(.iconOnly)
            }
        } header: {
            Text("Paste text or markdown")
        }
    }

    // MARK: Logic

    private var canGenerate: Bool {
        switch source {
        case .topic: return !topic.trimmingCharacters(in: .whitespaces).isEmpty
        case .url: return validURL != nil
        case .document: return document != nil
        case .photo: return !images.isEmpty
        case .paste: return !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var validURL: URL? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    private var keptNote: String? {
        switch source {
        case .topic: return nil
        case .url: return "We keep a link to the original page so you can review it later."
        case .document: return "We keep a link to the original file so you can review it later."
        case .photo: return "We keep the recognised text so you can review it later."
        case .paste: return "We keep the original text so you can review it later."
        }
    }

    private var documentTypes: [UTType] {
        [.pdf, .plainText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    }

    private func pickDocument(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let bookmark = OriginalFileLoader.bookmark(for: url) else {
                errorMessage = "That file couldn't be opened."
                return
            }
            let isPDF = url.pathExtension.lowercased() == "pdf"
            document = PickedDocument(name: url.lastPathComponent, bookmark: bookmark, kind: isPDF ? .pdf : .markdown)
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var loaded: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) { loaded.append(data) }
        }
        images = loaded
    }

    /// Builds the job and queues it (F-61), then closes the sheet.
    private func enqueue() {
        guard gate.client(.generation, from: router) != nil else { return }
        errorMessage = nil
        let job: GenerationJob
        switch source {
        case .topic:
            let options = GenerationJob.TopicOptions(
                topic: topic.trimmingCharacters(in: .whitespaces), cardCount: cardCount, difficulty: difficulty.rawValue,
                language: language.isEmpty ? Locale.current.identifier : language, tone: tone.rawValue,
                focus: focus.isEmpty ? nil : focus, exclude: excludeText.isEmpty ? nil : excludeText
            )
            job = GenerationJob(title: options.topic, source: .topic(options))
        case .url:
            guard let url = validURL else { return }
            job = GenerationJob(title: url.host ?? url.absoluteString, source: .url(url))
        case .document:
            guard let document else { return }
            job = GenerationJob(title: document.name, source: .file(name: document.name, bookmark: document.bookmark, kind: document.kind))
        case .photo:
            let names = images.indices.map { "page-\($0 + 1).jpg" }
            let candidate = GenerationJob(title: "\(images.count) scanned page\(images.count == 1 ? "" : "s")", source: .images(names))
            let folder = queue.folder(for: candidate.id)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (data, name) in zip(images, names) { try data.write(to: folder.appending(path: name)) }
            } catch {
                errorMessage = "The photos couldn't be saved: \(error.localizedDescription)"
                return
            }
            job = candidate
        case .paste:
            let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            job = GenerationJob(title: String(text.prefix(40)), source: .text(text))
        }
        queue.enqueue(job)
        Notifier.requestPermissionIfNeeded()
        dismiss()
    }
}

/// VisionKit's document camera (F-3 *From photo*).
struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish([])
        }
    }
}
