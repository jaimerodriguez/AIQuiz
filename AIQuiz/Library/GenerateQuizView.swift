import SwiftUI
import AIQuizCore
import LLMKit
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
    @Environment(AIRouter.self) private var router

    @State private var source: Source = .topic
    @State private var topic: String = ""
    @State private var cardCount: Int = 20
    @State private var difficulty: Difficulty = .intermediate
    @State private var language: String = ""
    @State private var tone: Tone = .formal
    @State private var focus: String = ""
    @State private var excludeText: String = ""

    @State private var pickedMarkdownURL: URL?
    @State private var markdownBookmark: Data?
    @State private var markdownContent: String?
    @State private var pickingMarkdown = false

    @State private var pasted: String = ""

    @State private var urlString: String = ""

    @State private var generating = false
    @State private var errorMessage: String?
    @State private var showProviderSetup = false
    @State private var setupIssue: String?
    @State private var generatedQuizId: UUID?
    @State private var exportingJSON: Data?
    @State private var exporting = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                sourceSection

                switch source {
                case .topic: topicSection
                case .markdown: markdownSection
                case .paste: pasteSection
                case .url: urlSection
                }

                generateSection
            }
            // The sheet is short on iPad; bring the outcome into view when generation ends.
            .onChange(of: generatedQuizId) { _, id in
                if id != nil { withAnimation { proxy.scrollTo(Self.resultAnchor, anchor: .bottom) } }
            }
            .onChange(of: errorMessage) { _, message in
                if message != nil { withAnimation { proxy.scrollTo(Self.resultAnchor, anchor: .bottom) } }
            }
        }
        .navigationTitle("Generate quiz")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("generate.cancel")
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
                markdownBookmark = OriginalFileLoader.bookmark(for: url)
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
            document: exportingJSON.map { QuizJSONDocument(data: $0) },
            contentType: .json,
            defaultFilename: defaultExportFilename
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showProviderSetup) {
            NavigationStack { EndpointsListView(setupIssue: setupIssue, showsDoneButton: true) }
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
                .accessibilityIdentifier("generate.paste")
            Text("\(pasted.count) characters")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var urlSection: some View {
        Section {
            TextField("https://en.wikipedia.org/wiki/…", text: $urlString)
                .accessibilityIdentifier("generate.url")
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
            .accessibilityIdentifier("generate.run")

            if generatedQuizId != nil {
                Button {
                    if exportingJSON != nil {
                        exporting = true
                    }
                } label: {
                    Label("Also save JSON to Files", systemImage: "square.and.arrow.up")
                }
                .disabled(exportingJSON == nil)
                .accessibilityIdentifier("generate.saveJSON")
                Button {
                    dismiss()
                } label: {
                    Label("Open in library", systemImage: "checkmark.circle")
                }
                .accessibilityIdentifier("generate.openLibrary")
                .id(Self.resultAnchor)
            }

            if let err = errorMessage {
                Text(err).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("generate.error")
                    .id(Self.resultAnchor)
            }
        } header: {
            Text("Generate")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if source != .topic {
                    Text("The original \(source == .url ? "page link" : source == .markdown ? "file link" : "text") is kept with the quiz so you can read it later.")
                }
                Text("Endpoint: \(router.summary(for: .generation))")
            }
            .font(.footnote)
        }
    }

    private static let resultAnchor = "generate.result"

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

        if let issue = router.issue(for: .generation) {
            setupIssue = issue.localizedDescription
            showProviderSetup = true
            return
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
            let client = try router.client(for: .generation)
            let payload = try await QuizGenerator.generate(request, using: client)
            try saveQuiz(payload, request: request, endpoint: client.endpoint)
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

    /// Saves the quiz and, for source modes, its original content (CR-007).
    private func saveQuiz(_ payload: QuizPayload, request: QuizGenRequest, endpoint: LLMEndpoint) throws {
        let record = QuizRecord.make(from: payload, origin: origin, source: originalSource(text: request.sourceContent))
        record.generatedByEndpointName = endpoint.name
        record.generatedByModel = endpoint.model
        context.insert(record)
        try context.save()
        generatedQuizId = record.id
        exportingJSON = try? QuizDecoder.encode(payload)
    }

    private var origin: QuizOrigin {
        switch source {
        case .topic: return .topic
        case .markdown: return .markdown
        case .paste: return .pastedText
        case .url: return .url
        }
    }

    private func originalSource(text: String?) -> OriginalSource? {
        switch source {
        case .topic:
            return nil
        case .markdown:
            return OriginalSource(
                kind: .markdownFile,
                title: pickedMarkdownURL?.lastPathComponent ?? "Markdown file",
                text: text,
                fileBookmark: markdownBookmark
            )
        case .paste:
            return OriginalSource(kind: .pastedText, title: "Pasted text", text: text)
        case .url:
            let url = URL(string: urlString.trimmingCharacters(in: .whitespaces))
            return OriginalSource(kind: .webPage, title: url?.host ?? "Web page", text: text, url: url)
        }
    }
}
