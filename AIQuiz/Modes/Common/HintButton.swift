import SwiftUI

struct HintButton: View {
    let hint: String?
    @State private var revealed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { revealed.toggle() }
            } label: {
                Label(revealed ? "Hide hint" : "Hint", systemImage: "lightbulb")
            }
            .buttonStyle(.bordered)
            .disabled(hint == nil)

            if revealed, let hint {
                Text(hint)
                    .font(AppSettings.shared.quizFontSize.bodyFont)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
