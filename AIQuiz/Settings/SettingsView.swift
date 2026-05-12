import SwiftUI
import AVFoundation
import UIKit

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var voicePreviewing: String?

    var body: some View {
        Form {
            aiSection
            appearanceSection
            readingSizeSection
            voiceSection
            voiceTuningSection
            studyVoiceSection
            studyReadSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appearanceSection: some View {
        Section {
            Picker("Theme", selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows your device's Light/Dark setting. Pick Light or Dark to override it inside AIQuiz.")
        }
    }

    private var readingSizeSection: some View {
        Section {
            Picker("Size", selection: $settings.quizFontSize) {
                ForEach(QuizFontSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.segmented)

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
                ProviderSettingsView()
            } label: {
                LabeledContent("AI providers", value: ProviderRegistry.shared.generationProvider.label)
            }
        } header: {
            Text("AI")
        } footer: {
            Text("Pick which model generates quizzes and grades your spoken answers. Cloud models need API keys; Apple on-device runs free on supported devices.")
        }
    }

    private var voiceSection: some View {
        Section {
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

    private var studyVoiceSection: some View {
        Section("Study — Voice auto-read") {
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
        Section("Study — User-paced read") {
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
