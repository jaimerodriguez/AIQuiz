import SwiftUI
import SwiftData

@Observable @MainActor
final class StudyVoicePlayer {
    enum State { case idle, playing, paused, ended }

    let deck: SessionDeck
    private(set) var state: State = .idle
    private(set) var hintRevealed: Bool = false
    private var task: Task<Void, Never>?
    private let tts: TTSService
    private let pauseSeconds: Double
    private let repeatCount: Int

    init(deck: SessionDeck, tts: TTSService = .shared) {
        self.deck = deck
        self.tts = tts
        let s = AppSettings.shared
        self.pauseSeconds = s.studyVoicePauseSeconds
        self.repeatCount = s.studyVoiceRepeatCount
    }

    func start() {
        guard state != .playing else { return }
        state = .playing
        runLoop()
    }

    func pause() {
        guard state == .playing else { return }
        state = .paused
        tts.pause()
    }

    func resume() {
        guard state == .paused else { return }
        state = .playing
        tts.resume()
    }

    func stop() {
        task?.cancel()
        tts.stop()
        state = .ended
    }

    func repeatCard() {
        task?.cancel()
        tts.stop()
        hintRevealed = false
        state = .playing
        runLoop()
    }

    func skip() {
        task?.cancel()
        tts.stop()
        hintRevealed = false
        deck.next()
        if deck.ended {
            state = .ended
        } else {
            state = .playing
            runLoop()
        }
    }

    func back() {
        guard !deck.atStart else { return }
        task?.cancel()
        tts.stop()
        hintRevealed = false
        deck.back()
        state = .playing
        runLoop()
    }

    func revealHint() {
        hintRevealed = true
        Task { await tts.speak("Hint.") }
    }

    private func runLoop() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await self.playCurrentCard()
        }
    }

    private func playCurrentCard() async {
        while !Task.isCancelled, let card = deck.current {
            for _ in 0..<repeatCount {
                if Task.isCancelled { return }
                await tts.speak(card.prompt)
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(pauseSeconds))
                if let short = card.shortAnswer, !short.isEmpty {
                    if Task.isCancelled { return }
                    await tts.speak(short)
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(pauseSeconds))
                }
                if Task.isCancelled { return }
                await tts.speak(card.longAnswer)
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(pauseSeconds))
            }
            hintRevealed = false
            deck.next()
            if deck.ended { state = .ended; return }
        }
    }
}

struct StudyVoiceView: View {
    let quiz: QuizRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var player: StudyVoicePlayer
    @State private var showAbandonAlert: Bool = false
    @State private var sessionRecorded: Bool = false

    init(quiz: QuizRecord) {
        self.quiz = quiz
        let deck = ScoreStore.makeDeck(for: quiz)
        _player = State(wrappedValue: StudyVoicePlayer(deck: deck))
    }

    private func recordIfNeeded() {
        guard !sessionRecorded, !player.deck.abandoned else { return }
        sessionRecorded = true
        ScoreStore.recordSession(for: quiz, deck: player.deck, mode: .studyVoice, in: context)
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            if let card = player.deck.current {
                cardView(card)
            } else {
                ContentUnavailableView("Empty quiz", systemImage: "tray")
            }
            Spacer()
            controls
        }
        .padding()
        .navigationTitle(quiz.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .destructive) {
                    showAbandonAlert = true
                } label: {
                    Label("End", systemImage: "xmark.circle")
                }
            }
        }
        .onAppear { player.start() }
        .onDisappear { player.stop() }
        .onChange(of: player.state) { _, new in
            if new == .ended {
                recordIfNeeded()
                dismiss()
            }
        }
        .alert("End session?", isPresented: $showAbandonAlert) {
            Button("End", role: .destructive) {
                player.stop()
                player.deck.abandon()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your progress in this session won't be saved.")
        }
    }

    private var header: some View {
        let progress = player.deck.progress
        return VStack(spacing: 4) {
            ProgressView(value: Double(progress.current), total: Double(progress.total))
            HStack {
                Text("Card \(progress.current) of \(progress.total)")
                Spacer()
                Text(stateLabel).foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var stateLabel: String {
        switch player.state {
        case .idle: return "Ready"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .ended: return "Done"
        }
    }

    @ViewBuilder
    private func cardView(_ card: CardRecord) -> some View {
        let typo = AppSettings.shared.quizFontSize
        VStack(alignment: .leading, spacing: 16) {
            Text(card.prompt)
                .font(typo.promptFont)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let s = card.shortAnswer {
                Text(s).font(typo.emphasisFont).foregroundStyle(.tint)
            }
            Text(card.longAnswer).font(typo.bodyFont)
            if player.hintRevealed, let hint = card.hint {
                Text(hint)
                    .font(typo.bodyFont)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                controlButton("Back", systemImage: "backward.fill") { player.back() }
                    .disabled(player.deck.atStart)
                controlButton("Repeat", systemImage: "arrow.counterclockwise") { player.repeatCard() }
                if player.state == .playing {
                    controlButton("Pause", systemImage: "pause.fill") { player.pause() }
                } else {
                    controlButton("Play", systemImage: "play.fill") {
                        if player.state == .paused { player.resume() } else { player.start() }
                    }
                }
                controlButton("Skip", systemImage: "forward.fill") { player.skip() }
            }
            Button {
                player.revealHint()
            } label: {
                Label(player.hintRevealed ? "Hint shown" : "Hint", systemImage: "lightbulb")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(player.deck.current?.hint == nil)
        }
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }
}
