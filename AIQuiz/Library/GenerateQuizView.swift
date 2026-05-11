import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct GenerateQuizView: View {
    enum Source: String, CaseIterable, Identifiable {
        case topic
        case markdown
        case paste
        case url

        var id: String { rawValue }

        var label: String {
            switch self {
            case .topic: return "Topic"
            case .markdown: return "Markdown file"
            case .paste: return "Paste text"
            case .url: return "Web URL"
            }
        }

        var icon: String {
            switch self {
            case .topic: return "text.bubble"
            case .markdown: return "doc.text"
            case .paste: return "square.and.pencil"
            case .url: return "link"
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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var source: Source = .topic
    @State private var topic: String = ""
    @State private var cardCount: Int = 20
    @State private var difficulty: Difficulty = .intermediate
    @State private var language: String = ""
    @State private var tone: Tone = .formal
    @State private var focus: String = ""
    @State private var excludeText: String = ""

    @State private var pickedMarkdownURL: URL?
    @State private var markdownContent: String?
    @State private var pickingMarkdown = false

    @State private var pasted: String = ""

    @State private var urlString: String = ""

    @State private var generating = false
    @State private var errorMessage: String?
    @State private var showProviderSetup = false
    @State private var generatedQuizId: UUID?
    @State private var exportingJSON: Data?
    @State private var exporting = false

    var body: some View {
        Form {
            sourceSection

            switch source {
            case .topic: topicSection
            case .markdown: markdownSection
            case .paste: pasteSection
            case .url: urlSection
            }

            generateSection

            if let err = errorMessage {
                Section {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Generate quiz")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $pickingMarkdown,
            allowedContentTypes: markdownContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                pickedMarkdownURL = url
                Task {
                    do {
                        markdownContent = try await ContentExtractor.loadMarkdown(url)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportingJSON.map { JSONDocument(data: $0) },
            contentType: .json,
            defaultFilename: defaultExportFilename
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showProviderSetup) {
            NavigationStack { ProviderSettingsView() }
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("Source", selection: $source) {
                ForEach(Source.allCases) { s in
                    Label(s.label, systemImage: s.icon).tag(s)
                }
            }
            .pickerStyle(.menu)
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

    private var markdownSection: some View {
        Section("Markdown file") {
            Button {
                pickingMarkdown = true
            } label: {
                Label(pickedMarkdownURL?.lastPathComponent ?? "Pick a .md file from Files",
                      systemImage: "doc.text")
            }
            if let content = markdownContent {
                Text("\(content.count) characters loaded")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var pasteSection: some View {
        Section("Paste text or markdown") {
            TextEditor(text: $pasted)
                .frame(minHeight: 220)
            Text("\(pasted.count) characters")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var urlSection: some View {
        Section {
            TextField("https://en.wikipedia.org/wiki/…", text: $urlString)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Web URL")
        } footer: {
            Text("AIQuiz fetches the page, extracts the main article text, and sends just that to the AI.")
        }
    }

    private var generateSection: some View {
        Section {
            Button {
                Task { await generate() }
            } label: {
                HStack {
                    if generating {
                        ProgressView()
                        Text("Generating…")
                    } else {
                        Label("Generate quiz", systemImage: "sparkles")
                    }
                    Spacer()
                }
            }
            .disabled(generating || !canGenerate)

            if let id = generatedQuizId {
                Button {
                    if exportingJSON != nil {
                        exporting = true
                    }
                } label: {
                    Label("Also save JSON to Files", systemImage: "square.and.arrow.up")
                }
                .disabled(exportingJSON == nil)
                Button {
                    dismiss()
                } label: {
                    Label("Open in library", systemImage: "checkmark.circle")
                }
                .id(id)
            }
        } header: {
            Text("Generate")
        } footer: {
            Text("Provider: \(ProviderRegistry.shared.generationProvider.label)")
                .font(.footnote)
        }
    }

    private var canGenerate: Bool {
        switch source {
        case .topic: return !topic.trimmingCharacters(in: .whitespaces).isEmpty
        case .markdown: return markdownContent != nil
        case .paste: return !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .url: return URL(string: urlString.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
        }
    }

    private var markdownContentTypes: [UTType] {
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        return types
    }

    private var defaultExportFilename: String {
        let raw = (topic.isEmpty ? "quiz" : topic)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return raw + ".json"
    }

    private func generate() async {
        errorMessage = nil
        generatedQuizId = nil
        exportingJSON = nil

        if let validation = ProviderRegistry.shared.validate(for: .generation) {
            switch validation {
            case .missingAPIKey, .providerUnavailable, .noProviderConfigured:
                showProviderSetup = true
                return
            default:
                errorMessage = validation.localizedDescription
                return
            }
        }

        let request: QuizGenRequest
        do {
            request = try await buildRequest()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        generating = true
        defer { generating = false }
        do {
            let provider = ProviderRegistry.shared.provider(for: .generation)
            let payload = try await provider.generateQuiz(request)
            try saveQuiz(payload)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func buildRequest() async throws -> QuizGenRequest {
        switch source {
        case .topic:
            return QuizGenRequest(
                source: .topic,
                topic: topic,
                sourceContent: nil,
                cardCount: cardCount,
                difficulty: difficulty.rawValue,
                language: language.isEmpty ? Locale.current.identifier : language,
                tone: tone.rawValue,
                focus: focus.isEmpty ? nil : focus,
                exclude: excludeText.isEmpty ? nil : excludeText
            )
        case .markdown:
            guard let content = markdownContent else { throw ContentExtractor.ExtractError.empty(URL(string: "file://")!) }
            return QuizGenRequest(
                source: .markdown,
                topic: pickedMarkdownURL?.deletingPathExtension().lastPathComponent ?? "Quiz",
                sourceContent: content
            )
        case .paste:
            return QuizGenRequest(
                source: .markdown,
                topic: "Quiz",
                sourceContent: pasted
            )
        case .url:
            guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)) else {
                throw NSError(domain: "GenerateQuizView", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }
            let extracted = try await ContentExtractor.fetchAndExtract(url)
            return QuizGenRequest(
                source: .article,
                topic: url.host ?? "Quiz",
                sourceContent: extracted
            )
        }
    }

    private func saveQuiz(_ payload: QuizPayload) throws {
        let record = QuizRecord(name: payload.name, sourceBookmark: nil, bundledSampleId: nil)
        for (idx, card) in payload.cards.enumerated() {
            let cr = CardRecord(
                prompt: card.prompt,
                longAnswer: card.longAnswer,
                shortAnswer: card.shortAnswer,
                hint: card.hint,
                orderIndex: idx
            )
            cr.quiz = record
            record.cards.append(cr)
        }
        context.insert(record)
        try context.save()
        generatedQuizId = record.id

        // Build JSON for optional export
        let file = QuizFile(quiz: payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(file) {
            exportingJSON = data
        }
    }
}

private struct JSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        if let read = configuration.file.regularFileContents {
            data = read
        } else {
            data = Data()
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
