import SwiftUI
import UIKit

/// First run (SPEC F-60): how to study, how quizzes are made, which AI to use.
/// Skippable, shown once, ends with *Let's get started* (CR-011).
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip", action: onFinish)
                    .opacity(page < pageCount - 1 ? 1 : 0)
                    .disabled(page == pageCount - 1)
                    .accessibilityIdentifier("onboarding.skip")
            }
            .padding(.horizontal)
            .frame(height: 44)

            TabView(selection: $page) {
                StudyModesPage().tag(0)
                GeneratePage().tag(1)
                ProvidersPage().tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 16) {
                PageDots(count: pageCount, current: page)
                Button {
                    if page < pageCount - 1 {
                        withAnimation { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(page < pageCount - 1 ? "Next" : "Let's get started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .frame(maxWidth: 420)
                .accessibilityIdentifier(page < pageCount - 1 ? "onboarding.next" : "onboarding.start")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Pages

/// A page: illustration, title, subtitle, then the page's own content. Scrolls on small phones.
private struct OnboardingPage<Hero: View, Content: View>: View {
    let index: Int
    let title: String
    let subtitle: String
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Content
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var regular: Bool { sizeClass == .regular }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: regular ? 32 : 18) {
                    hero
                        .frame(height: regular ? 190 : 104)
                        .scaleEffect(regular ? 1.25 : 0.8)
                    VStack(spacing: regular ? 10 : 6) {
                        Text(title)
                            .font(regular ? .system(size: 44, weight: .bold) : .title.bold())
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("onboarding.title.\(index)")
                        Text(subtitle)
                            .font(regular ? .title3 : .body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    content
                }
                .frame(maxWidth: regular ? 860 : Theme.readableWidth)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                // Centre the page when it fits; scroll when it doesn't.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct StudyModesPage: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let modes: [(icon: String, title: String, text: String)] = [
        ("speaker.wave.2.fill", "Listen", "The app reads each card aloud. Hands-free, for walks and commutes."),
        ("rectangle.portrait.on.rectangle.portrait.fill", "Flip through", "Read at your own pace: one card at a time, or the whole answer at once."),
        ("mic.fill", "Answer out loud", "Say your answer, watch it transcribed, then grade yourself or ask AI.")
    ]

    var body: some View {
        OnboardingPage(index: 0, title: "Three ways to study", subtitle: "Every quiz works in all three.") {
            StackedCardsHero()
        } content: {
            AdaptiveTiles(sizeClass: sizeClass, items: modes.map { FeatureTileModel(icon: $0.icon, title: $0.title, text: $0.text) })
        }
    }
}

private struct GeneratePage: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let sources: [(icon: String, label: String)] = [
        ("text.bubble.fill", "A topic"),
        ("globe", "A web page"),
        ("doc.text.fill", "A Markdown file"),
        ("doc.on.clipboard.fill", "Pasted text")
    ]

    var body: some View {
        OnboardingPage(index: 1, title: "Make quizzes from anything",
                       subtitle: "AI turns your material into flashcards and keeps the original for reading later.") {
            GenerateHero()
        } content: {
            VStack(spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: sizeClass == .regular ? 4 : 2), spacing: 10) {
                    ForEach(sources, id: \.label) { source in
                        if sizeClass == .regular {
                            VStack(spacing: 10) {
                                AccentIcon(systemName: source.icon, size: 52)
                                Text(source.label).font(.headline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.tileRadius))
                        } else {
                            HStack(spacing: 10) {
                                AccentIcon(systemName: source.icon, size: 32)
                                Text(source.label)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.tileRadius))
                        }
                    }
                }
                Label("AI writes the cards", systemImage: "arrow.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                AdaptiveTiles(sizeClass: sizeClass, items: [
                    FeatureTileModel(icon: "rectangle.stack.fill", title: "A deck of flashcards", text: "Ready for all three study modes."),
                    FeatureTileModel(icon: "book.fill", title: "The original, kept", text: "Read it again from the quiz any time.")
                ])
            }
        }
    }
}

private struct ProvidersPage: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        OnboardingPage(index: 2, title: "Bring your own AI",
                       subtitle: "Pick who writes and grades your quizzes. Requests go straight from this device to them.") {
            AccentIcon(systemName: "cpu.fill", size: 120)
        } content: {
            VStack(spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: sizeClass == .regular ? 4 : 2), spacing: 12) {
                    ForEach(ProviderMark.Provider.allCases, id: \.self) { provider in
                        ProviderMark(provider: provider, large: sizeClass == .regular)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    AccentIcon(systemName: "lock.shield.fill", size: sizeClass == .regular ? 48 : 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your keys stay on this device").font(sizeClass == .regular ? .title3.weight(.semibold) : .headline)
                        Text("API keys live in the Keychain. Add an endpoint from Settings whenever you're ready.")
                            .font(sizeClass == .regular ? .body : .subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(sizeClass == .regular ? 18 : 12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.tileRadius))
            }
        }
    }
}

// MARK: - Building blocks

private struct FeatureTileModel: Hashable {
    let icon: String
    let title: String
    let text: String
}

/// Feature tiles: side by side on iPad, stacked rows on iPhone.
private struct AdaptiveTiles: View {
    let sizeClass: UserInterfaceSizeClass?
    let items: [FeatureTileModel]

    var body: some View {
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        AccentIcon(systemName: item.icon, size: 60)
                        Text(item.title).font(.title3.weight(.semibold))
                        Text(item.text).font(.body).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.tileRadius))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 10) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 12) {
                        AccentIcon(systemName: item.icon, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text(item.text).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.tileRadius))
                }
            }
        }
    }
}

/// Three fanned cards, the front one in the accent color.
private struct StackedCardsHero: View {
    var body: some View {
        ZStack {
            card(opacity: 0.18).rotationEffect(.degrees(-14)).offset(x: -34, y: 8)
            card(opacity: 0.35).rotationEffect(.degrees(12)).offset(x: 34, y: 8)
            RoundedRectangle(cornerRadius: 18)
                .fill(Theme.accent.gradient)
                .frame(width: 104, height: 136)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "questionmark")
                            .font(.system(size: 44, weight: .bold))
                        Capsule().frame(width: 56, height: 6).opacity(0.6)
                        Capsule().frame(width: 40, height: 6).opacity(0.4)
                    }
                    .foregroundStyle(.white)
                }
                .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 6)
        }
        .accessibilityHidden(true)
    }

    private func card(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Theme.accent.opacity(opacity))
            .frame(width: 104, height: 136)
    }
}

/// Source → AI → cards.
private struct GenerateHero: View {
    var body: some View {
        HStack(spacing: 10) {
            AccentIcon(systemName: "doc.text.fill", size: 64)
            Image(systemName: "chevron.right").font(.title3.weight(.bold)).foregroundStyle(.tertiary)
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(Theme.accent.gradient, in: Circle())
                .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 6)
            Image(systemName: "chevron.right").font(.title3.weight(.bold)).foregroundStyle(.tertiary)
            AccentIcon(systemName: "rectangle.stack.fill", size: 64)
        }
        .accessibilityHidden(true)
    }
}

/// A provider tile. Uses the official logo when its image set (`logo-anthropic`,
/// `logo-openai`) is in the asset catalog; otherwise a neutral monogram.
struct ProviderMark: View {
    enum Provider: CaseIterable {
        case anthropic, openAI, apple, local

        var name: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openAI: return "OpenAI"
            case .apple: return "Apple"
            case .local: return "Your server"
            }
        }

        var detail: String {
            switch self {
            case .anthropic: return "Claude models"
            case .openAI: return "GPT models"
            case .apple: return "On-device, private"
            case .local: return "Ollama, LM Studio"
            }
        }

        var assetName: String? {
            switch self {
            case .anthropic: return "logo-anthropic"
            case .openAI: return "logo-openai"
            case .apple, .local: return nil
            }
        }
    }

    let provider: Provider
    var large = false

    var body: some View {
        VStack(spacing: large ? 10 : 4) {
            logo
                .frame(width: large ? 56 : 34, height: large ? 56 : 34)
            Text(provider.name).font(large ? .headline : .subheadline.weight(.semibold))
            Text(provider.detail)
                .font(large ? .subheadline : .caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: large ? 150 : 88)
        .padding(.vertical, 4)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.tileRadius))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var logo: some View {
        if let asset = provider.assetName, UIImage(named: asset) != nil {
            // The SwiftUI image follows light and dark mode; the asset holds both variants.
            Image(asset).resizable().scaledToFit()
        } else {
            switch provider {
            case .apple:
                Image(systemName: "apple.logo")
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .foregroundStyle(.primary)
            case .local:
                Image(systemName: "server.rack")
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .foregroundStyle(.primary)
            case .anthropic, .openAI:
                Text(String(provider.name.prefix(1)))
                    .font(.system(size: large ? 28 : 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.fill.tertiary, in: Circle())
            }
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Theme.accent : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 22 : 8, height: 8)
                    .animation(.snappy, value: current)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
