import SwiftUI
import AIQuizCore
import AVFoundation
import Speech
import SwiftData
import UIKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AIRouter.self) private var router
    @Environment(\.modelContext) private var context
    @State private var voicePreviewing: String?
    @State private var pendingClear: PrivacyClear?
    @State private var clearResult: String?
    @State private var logSize = 0

    /// S-15 actions, each confirmed first.
    enum PrivacyClear: String, Identifiable {
        case keys, history, library
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keys: return "Clear API keys?"
            case .history: return "Clear session history?"
            case .library: return "Clear quiz library?"
            }
        }
        var message: String {
            switch self {
            case .keys: return "Every saved API key is removed from the Keychain. Endpoints stay; you'll need to enter keys again."
            case .history: return "Every study and quiz session and every card's right/wrong counts are deleted. Quizzes and cards stay."
            case .library: return "Every quiz, with its cards, history and saved source, is deleted. This can't be undone."
            }
        }
    }

    var body: some View {
        Form {
            aiSection
            appearanceSection
            readingSizeSection
            voiceSection
            voiceTuningSection
            recognitionSection
            reviewSection
            studyVoiceSection
            studyReadSection
            debugSection
            privacySection
            introSection
        }
        .alert(pendingClear?.title ?? "", isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } }), presenting: pendingClear) { clear in
            Button("Clear", role: .destructive) { perform(clear) }
                .accessibilityIdentifier("settings.confirmClear")
            Button("Cancel", role: .cancel) {}
        } message: { clear in
            Text(clear.message)
        }
        .alert("Done", isPresented: Binding(get: { clearResult != nil }, set: { if !$0 { clearResult = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(clearResult ?? "")
        }
        .onAppear { logSize = Log.file.size }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appearanceSection: some View {
        @Bindable var settings = settings
        return Section {
            Picker("Theme", selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.appearance")
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows your device's Light/Dark setting. Pick Light or Dark to override it inside AIQuiz.")
        }
    }

    private var readingSizeSection: some View {
        @Bindable var settings = settings
        return Section {
            Picker("Size", selection: $settings.quizFontSize) {
                ForEach(QuizFontSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.readingSize")

            VStack(alignment: .leading, spacing: 6) {
                Text("Sample prompt: who succeeded Augustus?")
                    .font(settings.quizFontSize.promptFont)
                Text("Tiberius")
                    .font(settings.quizFontSize.emphasisFont)
                    .foregroundStyle(.tint)
                Text("Augustus's stepson, ruled 14–37 AD. He retired to Capri.")
                    .font(settings.quizFontSize.bodyFont)
            }
            .padding(.vertical, 6)
        } header: {
            Text("Reading size")
        } footer: {
            Text("Controls text size in study and quiz screens. The library and settings keep the system size.")
        }
    }

    private var aiSection: some View {
        Section {
            NavigationLink {
                EndpointsListView()
            } label: {
                LabeledContent("AI endpoints", value: router.summary(for: .generation))
            }
            .accessibilityIdentifier("settings.endpoints")
            Toggle("Auto-grade spoken answers", isOn: Bindable(settings).autoGrade)
                .accessibilityIdentifier("settings.autoGrade")
        } header: {
            Text("AI")
        } footer: {
            Text("Add Anthropic, OpenAI, local-network servers such as Ollama, or Apple on-device, then choose which one handles each task.")
        }
    }

    private var voiceSection: some View {
        @Bindable var settings = settings
        return Section {
            if !VoiceCatalog.hasAnyPremiumOrEnhanced {
                premiumVoicesHint
            }

            NavigationLink {
                VoicePickerView(selection: $settings.ttsVoiceIdentifier)
            } label: {
                LabeledContent("Voice", value: currentVoiceLabel)
            }
        } header: {
            Text("Speech")
        } footer: {
            Text("Premium and Enhanced voices sound dramatically more natural than the default. Tap Voice and pick one — or download more in iOS Settings.")
        }
    }

    private var premiumVoicesHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No Premium or Enhanced voices installed", systemImage: "exclamationmark.bubble")
                .font(.subheadline.weight(.semibold))
            Text("In iOS Settings → Accessibility → Spoken Content → Voices, pick a language and tap a voice to download a higher-quality version. They're free and work offline.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Open iOS Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private var voiceTuningSection: some View {
        Section("Speech rate") {
            VStack {
                Slider(
                    value: Binding(
                        get: { Double(settings.ttsRate) },
                        set: { settings.ttsRate = Float($0) }
                    ),
                    in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate),
                    step: 0.05
                )
                HStack {
                    Text("Slower").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", settings.ttsRate))
                    Spacer()
                    Text("Faster").foregroundStyle(.secondary)
                }
                .font(.caption)
                Button("Preview") { Task { await TTSService.shared.speak("This is the AIQuiz voice. Ready to study?") } }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// S-11 session size and S-12 the daily due reminder.
    private var reviewSection: some View {
        @Bindable var settings = settings
        return Section {
            Stepper(value: $settings.sessionCap, in: 10...100, step: 5) {
                LabeledContent("Cards per quiz session", value: "\(settings.sessionCap)")
            }
            .accessibilityIdentifier("settings.sessionCap")
            Toggle("Daily reminder", isOn: $settings.reminderOn)
                .accessibilityIdentifier("settings.reminder")
                .onChange(of: settings.reminderOn) { _, on in
                    if on { Task { _ = await DueNotifications.requestPermission() } }
                }
            if settings.reminderOn {
                DatePicker("Time", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: settings.reminderMinutes / 60, minute: settings.reminderMinutes % 60, second: 0, of: .now) ?? .now },
                    set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        settings.reminderMinutes = (parts.hour ?? 18) * 60 + (parts.minute ?? 0)
                    }
                ), displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("settings.reminderTime")
            }
        } header: {
            Text("Reviews")
        } footer: {
            Text("Quizzes ask the cards that are due or new, up to this many. The reminder says how many cards are due, and only when some are.")
        }
    }

    /// S-5: the language Quiz — Voice answer listens for.
    private var recognitionSection: some View {
        @Bindable var settings = settings
        let locales = SFSpeechRecognizer.supportedLocales()
            .sorted { displayName($0.identifier) < displayName($1.identifier) }
        return Section {
            Picker("Language", selection: $settings.sttLocaleIdentifier) {
                Text("Device language (\(displayName(Locale.current.identifier)))").tag(String?.none)
                ForEach(locales, id: \.identifier) { locale in
                    Text(displayName(locale.identifier)).tag(Optional(locale.identifier))
                }
            }
            .accessibilityIdentifier("settings.sttLanguage")
        } header: {
            Text("Speech recognition")
        } footer: {
            Text("The language Quiz — Voice answer listens for. Pick the quiz's language when it differs from your device's.")
        }
    }

    private func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// S-14: opt-in log file for troubleshooting.
    private var debugSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle("Debug logging", isOn: $settings.debugLogging)
                .accessibilityIdentifier("settings.debugLogging")
            if logSize > 0 {
                ShareLink(item: Log.file.url) {
                    Label("Share log (\(ByteCountFormatter.string(fromByteCount: Int64(logSize), countStyle: .file)))", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("settings.shareLog")
                Button("Delete log", role: .destructive) {
                    Log.file.clear()
                    logSize = 0
                }
                .accessibilityIdentifier("settings.deleteLog")
            }
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("When on, AIQuiz keeps a log on this device that you can share when reporting a problem. It never includes API keys.")
        }
        .onChange(of: settings.debugLogging) { _, on in
            if on { Log.app.info("Debug logging turned on") }
            logSize = Log.file.size
        }
    }

    /// S-15.
    private var privacySection: some View {
        Section {
            Button("Clear API keys", role: .destructive) { pendingClear = .keys }
                .accessibilityIdentifier("settings.clearKeys")
            Button("Clear session history", role: .destructive) { pendingClear = .history }
                .accessibilityIdentifier("settings.clearHistory")
            Button("Clear quiz library", role: .destructive) { pendingClear = .library }
                .accessibilityIdentifier("settings.clearLibrary")
        } header: {
            Text("Privacy")
        } footer: {
            Text("Each asks before deleting anything.")
        }
    }

    private var introSection: some View {
        @Bindable var settings = settings
        return Section {
            Button("Show the introduction again") { settings.onboardingDone = false }
                .disabled(!settings.onboardingDone)
                .accessibilityIdentifier("settings.showIntro")
        } footer: {
            Text("It appears the next time AIQuiz starts.")
        }
    }

    private func perform(_ clear: PrivacyClear) {
        do {
            switch clear {
            case .keys:
                router.clearAllKeys()
                clearResult = "API keys cleared."
            case .history:
                try LibraryMaintenance.clearSessionHistory(in: context)
                clearResult = "Session history cleared."
            case .library:
                try LibraryMaintenance.clearLibrary(in: context)
                clearResult = "Quiz library cleared."
            }
        } catch {
            clearResult = "Couldn't finish: \(error.localizedDescription)"
        }
    }

    private var studyVoiceSection: some View {
        @Bindable var settings = settings
        return Section("Study — Voice auto-read") {
            Stepper(value: $settings.studyVoiceRepeatCount, in: 1...5) {
                Text("Repeat each card \(settings.studyVoiceRepeatCount)×")
            }
            HStack {
                Text("Pause between cards")
                Spacer()
                Text(String(format: "%.1fs", settings.studyVoicePauseSeconds))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $settings.studyVoicePauseSeconds, in: 0.5...3.0, step: 0.1)
        }
    }

    private var studyReadSection: some View {
        @Bindable var settings = settings
        return Section("Study — User-paced read") {
            Picker("Default style", selection: $settings.studyReadStyle) {
                ForEach(StudyReadStyle.allCases) { s in Text(s.label).tag(s) }
            }
        }
    }

    private var currentVoiceLabel: String {
        if let id = settings.ttsVoiceIdentifier, let info = VoiceCatalog.info(forIdentifier: id) {
            return "\(info.name) (\(info.qualityLabel))"
        }
        if let best = VoiceCatalog.bestVoiceForCurrentLocale() {
            return "Auto · \(best.name) (\(best.qualityLabel))"
        }
        return "System default"
    }
}

private struct VoicePickerView: View {
    @Binding var selection: String?
    @State private var previewing: String?
    @State private var diagnostic: String?
    private let tts = TTSService.shared

    var body: some View {
        List {
            if let diagnostic {
                Section {
                    Text(diagnostic)
                        .font(.footnote)
                } header: {
                    Text("Diagnostic")
                }
            }
            Section {
                Button {
                    selection = nil
                    preview(nil)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Automatic")
                            Text("Best installed voice for your language")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == nil { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(VoiceCatalog.grouped(), id: \.language) { group in
                Section(languageLabel(group.language)) {
                    ForEach(group.voices) { voice in
                        voiceRow(voice)
                    }
                }
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func voiceRow(_ voice: VoiceInfo) -> some View {
        Button {
            selection = voice.identifier
            preview(voice.identifier as String?)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(voice.name)
                    Text(voice.qualityLabel)
                        .font(.caption)
                        .foregroundStyle(qualityColor(voice.qualityRaw))
                }
                Spacer()
                if selection == voice.identifier {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func qualityColor(_ raw: Int) -> Color {
        switch raw {
        case AVSpeechSynthesisVoiceQuality.premium.rawValue: return .purple
        case AVSpeechSynthesisVoiceQuality.enhanced.rawValue: return .blue
        default: return .secondary
        }
    }

    private func languageLabel(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code) ?? code
    }

    private func preview(_ identifier: String?) {
        previewing = identifier
        let requested = identifier
        Task {
            await TTSService.shared.speak("Hello. This is how this voice sounds.")
            previewing = nil
            let actualID = TTSService.shared.lastUsedVoiceIdentifier
            diagnostic = buildDiagnostic(requested: requested, actual: actualID)
        }
    }

    private func buildDiagnostic(requested: String?, actual: String?) -> String {
        let actualName: String
        if let actual, let info = VoiceCatalog.info(forIdentifier: actual) {
            actualName = "\(info.name) (\(info.qualityLabel))"
        } else if let actual {
            actualName = actual
        } else {
            actualName = "unknown"
        }
        if let requested {
            let requestedName: String
            if let info = VoiceCatalog.info(forIdentifier: requested) {
                requestedName = "\(info.name) (\(info.qualityLabel))"
            } else {
                requestedName = requested
            }
            if requested == actual {
                return "Played: \(actualName) ✓"
            } else {
                return "Asked for \(requestedName) but iOS played \(actualName). The chosen voice may not be fully downloaded — open Settings → Accessibility → Spoken Content → Voices and download it again."
            }
        } else {
            return "Played: \(actualName) (Automatic)"
        }
    }
}
