import SwiftUI
import SwiftData
import AVFoundation
import Speech

@Observable @MainActor
final class QuizVoicePlayer {
    enum Phase {
        case awaitingAnswer
        case listening
        case reveal
        case ended
    }

    let deck: SessionDeck
    private(set) var phase: Phase = .awaitingAnswer
    var transcript: String = ""
    private(set) var hintRevealed: Bool = false
    var sttError: String?
    var aiVerdict: AIVerdict?

    struct AIVerdict {
        let verdict: CardVerdict
        let reason: String
    }

    private let stt: STTService

    init(deck: SessionDeck, stt: STTService = .shared) {
        self.deck = deck
        self.stt = stt
    }

    func startListening() async {
        DebugLog.log("QV.startListening invoked, phase=\(phase)")
        guard phase == .awaitingAnswer else { return }
        sttError = nil
        transcript = ""
        aiVerdict = nil

        let micGranted: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        guard micGranted else {
            sttError = "Microphone access denied. Enable it in Settings → AIQuiz."
            return
        }

        if stt.authorisationStatus() != .authorized {
            let result = await stt.requestAuthorisation()
            guard result == .authorized else {
                sttError = "Speech recognition not authorised."
                return
            }
        }

        do {
            phase = .listening
            try stt.startListening(
                onTranscript: { [weak self] text in
                    Task { @MainActor in self?.transcript = text }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.sttError = self?.friendlyMessage(for: error) ?? error.localizedDescription
                        self?.phase = .reveal
                    }
                }
            )
        } catch {
            sttError = friendlyMessage(for: error)
            phase = .awaitingAnswer
        }
    }

    func stopListeningAndReveal() {
        stt.stopListening()
        phase = .reveal
    }

    func revealAnswerWithoutVoice() {
        stt.stopListening()
        phase = .reveal
    }

    func revealHint() {
        hintRevealed = true
    }

    func record(_ verdict: CardVerdict) {
        deck.record(verdict)
        advance()
    }

    func advance() {
        transcript = ""
        hintRevealed = false
        aiVerdict = nil
        deck.next()
        if deck.ended {
            phase = .ended
        } else {
            phase = .awaitingAnswer
        }
    }

    func abandon() {
        stt.stopListening()
        deck.abandon()
        phase = .ended
    }

    private func friendlyMessage(for error: Error) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("siri") && lower.contains("dictation") {
            return "Speech recognition needs Siri or Dictation enabled. Open Settings → Apple Intelligence & Siri (turn Siri on), or Settings → General → Keyboard → Dictation."
        }
        if lower.contains("not authorized") || lower.contains("denied") {
            return "Speech recognition isn't authorised. Enable it in Settings → AIQuiz."
        }
        if lower.contains("no speech") {
            return "Didn't catch any speech — tap the mic and try again."
        }
        return raw
    }
}

struct QuizVoiceView: View {
    let quiz: QuizRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var player: QuizVoicePlayer
    @State private var showAbandonAlert = false
    @State private var sessionRecorded = false
    @State private var aiJudging = false
    @State private var aiError: String?
    @State private var showProviderSetup = false

    init(quiz: QuizRecord) {
        self.quiz = quiz
        let deck = ScoreStore.makeDeck(for: quiz)
        _player = State(wrappedValue: QuizVoicePlayer(deck: deck))
    }

    var body: some View {
        Group {
            switch player.phase {
            case .ended:
                SessionSummaryView(
                    deck: player.deck,
                    onDone: { dismiss() },
                    onPracticeMissed: nil
                )
            default:
                sessionBody
            }
        }
        .navigationTitle(quiz.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if player.phase != .ended {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        showAbandonAlert = true
                    } label: {
                        Label("End", systemImage: "xmark.circle")
                    }
                }
            }
        }
        .alert("End session?", isPresented: $showAbandonAlert) {
            Button("End", role: .destructive) {
                player.abandon()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your progress in this session won't be saved.")
        }
        .sheet(isPresented: $showProviderSetup) {
            NavigationStack { ProviderSettingsView() }
        }
        .onChange(of: player.phase) { _, new in
            if new == .ended && !sessionRecorded {
                sessionRecorded = true
                ScoreStore.recordSession(for: quiz, deck: player.deck, mode: .quizVoice, in: context)
            }
        }
    }

    @ViewBuilder
    private var sessionBody: some View {
        VStack(spacing: 16) {
            header

            if let card = player.deck.current {
                cardContent(card)
            } else {
                ContentUnavailableView("Empty quiz", systemImage: "tray")
            }

            Spacer()

            controls
        }
        .padding()
    }

    private var header: some View {
        let p = player.deck.progress
        return VStack(spacing: 4) {
            ProgressView(value: Double(p.current), total: Double(p.total))
            Text("Card \(p.current) of \(p.total)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func cardContent(_ card: CardRecord) -> some View {
        let typo = AppSettings.shared.quizFontSize
        VStack(alignment: .leading, spacing: 16) {
            Text(card.prompt)
                .font(typo.promptFont)
                .frame(maxWidth: .infinity, alignment: .leading)

            if player.phase == .listening || (player.phase == .reveal && !player.transcript.isEmpty) {
                transcriptBlock(typo: typo)
            }

            if player.phase == .reveal {
                answerReveal(card, typo: typo)
            }

            if player.hintRevealed, let hint = card.hint {
                Text(hint)
                    .font(typo.bodyFont)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }

            if let err = player.sttError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func transcriptBlock(typo: QuizFontSize) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Your answer")
                    .font(.caption).foregroundStyle(.secondary)
                if player.phase == .listening {
                    Spacer()
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                        .foregroundStyle(.tint)
                }
            }
            Text(player.transcript.isEmpty ? "Listening…" : player.transcript)
                .font(typo.bodyFont)
                .foregroundStyle(player.transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func answerReveal(_ card: CardRecord, typo: QuizFontSize) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text("Correct answer")
                .font(.caption).foregroundStyle(.secondary)
            if let s = card.shortAnswer {
                Text(s).font(typo.emphasisFont).foregroundStyle(.tint)
            }
            Text(card.longAnswer).font(typo.bodyFont)
        }

        if let v = player.aiVerdict {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "sparkles")
                    Text("AI verdict: \(verdictLabel(v.verdict))")
                        .font(.subheadline.weight(.medium))
                }
                Text(v.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch player.phase {
        case .awaitingAnswer:
            VStack(spacing: 12) {
                Button {
                    Task { await player.startListening() }
                } label: {
                    Label("Tap to answer", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)

                HStack {
                    Button {
                        player.revealHint()
                    } label: {
                        Label(player.hintRevealed ? "Hint shown" : "Hint", systemImage: "lightbulb")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(player.deck.current?.hint == nil)

                    Button {
                        player.revealAnswerWithoutVoice()
                    } label: {
                        Label("Show answer", systemImage: "eye")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .listening:
            Button {
                player.stopListeningAndReveal()
            } label: {
                Label("Stop & reveal", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        case .reveal:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        player.record(.wrong)
                    } label: {
                        Label("Wrong", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button {
                        player.record(.partial)
                    } label: {
                        Label("Partial", systemImage: "circle.lefthalf.filled")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Button {
                        player.record(.correct)
                    } label: {
                        Label("Correct", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }

                Button {
                    Task { await askAIToJudge() }
                } label: {
                    HStack {
                        if aiJudging {
                            ProgressView()
                            Text("Asking AI…")
                        } else {
                            Label("Ask AI to judge", systemImage: "sparkles")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(aiJudging || player.transcript.isEmpty)

                if let err = aiError {
                    Text(err).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .ended:
            EmptyView()
        }
    }

    private func askAIToJudge() async {
        guard let card = player.deck.current else { return }
        aiError = nil
        if let error = ProviderRegistry.shared.validate(for: .grading) {
            switch error {
            case .missingAPIKey, .providerUnavailable, .noProviderConfigured:
                showProviderSetup = true
                return
            default:
                aiError = error.localizedDescription
                return
            }
        }
        aiJudging = true
        defer { aiJudging = false }
        do {
            let provider = ProviderRegistry.shared.provider(for: .grading)
            let verdict = try await provider.judgeAnswer(JudgeRequest(
                prompt: card.prompt,
                userAnswer: player.transcript,
                correctShort: card.shortAnswer,
                correctLong: card.longAnswer
            ))
            player.aiVerdict = .init(verdict: verdict.verdict, reason: verdict.reason)
        } catch {
            aiError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func verdictLabel(_ v: CardVerdict) -> String {
        switch v {
        case .correct: return "Correct"
        case .partial: return "Partial"
        case .wrong: return "Wrong"
        case .skipped: return "Skipped"
        }
    }
}
