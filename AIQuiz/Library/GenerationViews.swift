import SwiftUI
import AIQuizCore

/// *Generating (n)* at the top of the library (SPEC F-61): each job's phase and progress,
/// with cancel, retry and remove. Hidden when the queue is empty.
struct GeneratingSection: View {
    @Environment(GenerationQueue.self) private var queue
    @State private var expanded = true

    var body: some View {
        if !queue.jobs.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(Array(queue.jobs.enumerated()), id: \.element.id) { index, job in
                        JobRow(job: job, index: index)
                    }
                } label: {
                    HStack(spacing: 10) {
                        if queue.pendingCount > 0 {
                            ProgressView()
                            Text("Generating (\(queue.pendingCount))")
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Needs attention (\(queue.jobs.count))")
                        }
                    }
                    .font(.headline)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("library.generating")
                }
            }
        }
    }
}

private struct JobRow: View {
    let job: GenerationJob
    let index: Int
    @Environment(GenerationQueue.self) private var queue

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                status
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.job.\(index)")
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .queued:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("library.job.\(index).status")
        case .running:
            VStack(alignment: .leading, spacing: 2) {
                Text(job.phase.label).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("library.job.\(index).status")
                ProgressView(value: max(0.05, job.progress))
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                .accessibilityIdentifier("library.job.\(index).status")
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("library.job.\(index).status")
        case .done:
            Text("Done").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch job.state {
        case .queued, .running:
            Button { queue.cancel(job.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel")
            .accessibilityIdentifier("library.job.\(index).cancel")
        case .failed, .cancelled:
            HStack(spacing: 14) {
                Button { queue.retry(job.id) } label: {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.title3).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Retry")
                .accessibilityIdentifier("library.job.\(index).retry")
                Button { queue.remove(job.id) } label: {
                    Image(systemName: "trash.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove")
                .accessibilityIdentifier("library.job.\(index).remove")
            }
        case .done:
            EmptyView()
        }
    }

    private var icon: String {
        switch job.source {
        case .topic: return "text.bubble"
        case .url: return "globe"
        case .text: return "doc.on.clipboard"
        case .file(_, _, let kind): return kind == .pdf ? "doc.richtext" : "doc.text"
        case .images: return "camera.viewfinder"
        }
    }
}

/// *Batch from list* (F-61): one web address per line, one quiz each.
struct BatchFromListView: View {
    /// Where the new quizzes go (F-63); nil is the top level.
    var folderID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(GenerationQueue.self) private var queue
    @Environment(AIRouter.self) private var router
    @State private var text = ""
    @State private var gate = AIGate()

    private var parsed: (urls: [URL], rejected: [String]) { BatchList.parse(text) }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 220)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("batch.text")
                PasteButton(payloadType: String.self) { strings in
                    if let pasted = strings.first { text += (text.isEmpty ? "" : "\n") + pasted }
                }
                .labelStyle(.titleAndIcon)
            } header: {
                Text("One web address per line")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(parsed.urls.count) page\(parsed.urls.count == 1 ? "" : "s") will each become a quiz, made one after another in the background.")
                        .accessibilityIdentifier("batch.count")
                    if !parsed.rejected.isEmpty {
                        Text("Skipped, not web addresses: \(parsed.rejected.prefix(3).joined(separator: ", "))\(parsed.rejected.count > 3 ? "…" : "")")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Batch from list")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("batch.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add \(parsed.urls.count)") { add() }
                    .primaryActionStyle()
                    .disabled(parsed.urls.isEmpty)
                    .accessibilityIdentifier("batch.add")
            }
        }
        .aiSetupSheet(gate)
    }

    private func add() {
        guard gate.client(.generation, from: router) != nil else { return }
        for url in parsed.urls {
            queue.enqueue(GenerationJob(title: url.host.map { "\($0)\(url.path)" } ?? url.absoluteString, source: .url(url), folderID: folderID))
        }
        Notifier.requestPermissionIfNeeded()
        dismiss()
    }
}
