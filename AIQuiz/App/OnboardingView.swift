import SwiftUI

/// First run (SPEC F-60): modes, AI generation, endpoints. Skippable, shown once.
struct OnboardingView: View {
    /// Called with true when the user chose *Add an endpoint now*.
    let onFinish: (_ addEndpoint: Bool) -> Void
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let body: String
    }

    private let pages = [
        Page(symbol: "rectangle.on.rectangle.angled", title: "Study your way",
             body: "Each quiz has three modes: listen hands-free while the app reads every card, flip through cards at your own pace, or answer out loud and grade yourself."),
        Page(symbol: "sparkles", title: "Make quizzes with AI",
             body: "Generate a quiz from a topic, a web page, a Markdown file or text you paste. The original stays with the quiz so you can read it again."),
        Page(symbol: "server.rack", title: "Bring your own AI",
             body: "AI features use an endpoint you add: Anthropic, OpenAI, a server on your network such as Ollama, or Apple's on-device model. Your keys stay in the Keychain on this device.")
    ]

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Spacer()
                if page < pages.count - 1 {
                    Button("Skip") { onFinish(false) }
                        .accessibilityIdentifier("onboarding.skip")
                }
            }
            .frame(height: 44)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    let item = pages[index]
                    VStack(spacing: 20) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                        Text(item.title)
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("onboarding.title.\(index)")
                        Text(item.body)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 560)
                    }
                    .padding(.horizontal, 32)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Group {
                if page < pages.count - 1 {
                    Button {
                        withAnimation { page += 1 }
                    } label: {
                        Text("Next").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding.next")
                } else {
                    VStack(spacing: 12) {
                        Button {
                            onFinish(true)
                        } label: {
                            Text("Add an endpoint now").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("onboarding.addEndpoint")
                        Button {
                            onFinish(false)
                        } label: {
                            Text("Later").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("onboarding.later")
                    }
                }
            }
            .controlSize(.large)
            .frame(maxWidth: 480)
        }
        .padding()
    }
}
