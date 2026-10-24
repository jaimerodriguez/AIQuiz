import UIKit
import UniformTypeIdentifiers

/// The share extension (SPEC F-22). It saves what was shared into the App Group inbox and
/// tells the user to open AIQuiz, which turns each item into a quiz in its generation queue.
/// Extensions can't launch their app, so this is the "Open AIQuiz to continue" path.
final class ShareViewController: UIViewController {
    private static let groupID = "group.com.jaimerodriguez.aiquiz"

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let icon = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        icon.image = UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold))
        icon.tintColor = .tintColor
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center
        titleLabel.text = "Saving to AIQuiz…"
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await save() }
    }

    private func save() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        var saved = 0
        if let inbox = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.groupID)?.appending(path: "Inbox") {
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            for provider in providers {
                if await store(provider, in: inbox) { saved += 1 }
            }
        }
        if saved > 0 {
            titleLabel.text = "Saved to AIQuiz"
            detailLabel.text = "Open AIQuiz to make \(saved == 1 ? "the quiz" : "\(saved) quizzes"). It continues in the background."
        } else {
            titleLabel.text = "Nothing to save"
            detailLabel.text = "AIQuiz can make quizzes from web pages, text, PDFs and photos, and import Anki decks."
        }
        try? await Task.sleep(for: .seconds(1.6))
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Writes `<id>.json` (kind, value, file, name) and, for files, the payload next to it.
    private func store(_ provider: NSItemProvider, in inbox: URL) async -> Bool {
        let id = UUID().uuidString
        func write(kind: String, value: String? = nil, file: String? = nil, name: String? = nil) -> Bool {
            var item: [String: String] = ["kind": kind]
            item["value"] = value
            item["file"] = file
            item["name"] = name
            guard let data = try? JSONSerialization.data(withJSONObject: item) else { return false }
            return (try? data.write(to: inbox.appending(path: "\(id).json"))) != nil
        }
        func copy(_ url: URL, ext: String) -> String? {
            let name = "\(id).\(ext)"
            return (try? FileManager.default.copyItem(at: url, to: inbox.appending(path: name))) != nil ? name : nil
        }

        // An Anki deck (.apkg, .colpkg) is imported, not generated from.
        if let type = Self.ankiType(provider), let url = await fileURL(provider, type: type),
           let file = copy(url, ext: url.pathExtension.lowercased().isEmpty ? "apkg" : url.pathExtension.lowercased()) {
            return write(kind: "anki", file: file, name: url.lastPathComponent)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier),
           let url = await fileURL(provider, type: .pdf), let file = copy(url, ext: "pdf") {
            return write(kind: "pdf", file: file, name: url.lastPathComponent)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await imageData(provider), (try? data.write(to: inbox.appending(path: "\(id).jpg"))) != nil {
            return write(kind: "image", file: "\(id).jpg", name: "Shared image")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(provider), url.scheme?.hasPrefix("http") == true {
            return write(kind: "url", value: url.absoluteString)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(provider), !text.isEmpty {
            if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true {
                return write(kind: "url", value: url.absoluteString)
            }
            return write(kind: "text", value: text, name: String(text.prefix(40)))
        }
        return false
    }

    /// The type to load an Anki package as: by its extension, since Anki's apps and AIQuiz
    /// may declare different type identifiers for it.
    private static func ankiType(_ provider: NSItemProvider) -> UTType? {
        let isAnki = { (ext: String?) in ["apkg", "colpkg"].contains(ext?.lowercased() ?? "") }
        for id in provider.registeredTypeIdentifiers {
            if let type = UTType(id), isAnki(type.preferredFilenameExtension) { return type }
        }
        if let name = provider.suggestedName, isAnki((name as NSString).pathExtension) {
            return provider.registeredTypeIdentifiers.first.flatMap { UTType($0) } ?? .data
        }
        return nil
    }

    private func fileURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                // The file is deleted when this returns; copy it somewhere stable first.
                guard let url else { cont.resume(returning: nil); return }
                let stable = FileManager.default.temporaryDirectory.appending(path: url.lastPathComponent)
                try? FileManager.default.removeItem(at: stable)
                cont.resume(returning: (try? FileManager.default.copyItem(at: url, to: stable)) != nil ? stable : nil)
            }
        }
    }

    private func imageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { cont in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data, let image = UIImage(data: data) else { cont.resume(returning: nil); return }
                cont.resume(returning: image.jpegData(compressionQuality: 0.8))
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: String.self) { text, _ in cont.resume(returning: text) }
        }
    }
}
