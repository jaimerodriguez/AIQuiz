import Foundation
import AIQuizCore

/// Items the share extension leaves in the App Group (SPEC F-22). The app turns each into a
/// generation job on launch and when it returns to the foreground.
enum ShareInbox {
    static let groupID = "group.com.jaimerodriguez.aiquiz"

    /// One shared item, written by the extension as `<id>.json` next to its payload file.
    struct Item: Codable, Equatable {
        enum Kind: String, Codable { case url, text, pdf, markdown, image }
        var kind: Kind
        /// The URL or the text, for `url` and `text`.
        var value: String?
        /// The payload file next to the JSON, for files and images.
        var file: String?
        /// A display name.
        var name: String?
    }

    static var inboxURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appending(path: "Inbox")
    }

    /// Where shared files are kept so a quiz can link back to them.
    static var keptFilesURL: URL {
        URL.documentsDirectory.appending(path: "Shared")
    }

    @MainActor
    static func drain(into queue: GenerationQueue) {
        guard let inbox = inboxURL else { return }
        drain(from: inbox, keepFilesIn: keptFilesURL, into: queue)
    }

    /// Enqueues every item in `inbox` and deletes it. Unreadable items are dropped with a log line.
    @MainActor
    static func drain(from inbox: URL, keepFilesIn kept: URL, into queue: GenerationQueue) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: inbox.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") {
            let itemURL = inbox.appending(path: name)
            defer { try? fm.removeItem(at: itemURL) }
            guard let data = try? Data(contentsOf: itemURL), let item = try? JSONDecoder().decode(Item.self, from: data) else {
                Log.data.error("Share inbox: unreadable item \(name)")
                continue
            }
            let payload = item.file.map { inbox.appending(path: $0) }
            defer { if let payload { try? fm.removeItem(at: payload) } }
            if let job = job(for: item, payload: payload, keptFiles: kept, queue: queue) {
                queue.enqueue(job)
                Log.app.info("Share inbox: queued a \(item.kind.rawValue) item")
            }
        }
    }

    @MainActor
    private static func job(for item: Item, payload: URL?, keptFiles: URL, queue: GenerationQueue) -> GenerationJob? {
        let fm = FileManager.default
        switch item.kind {
        case .url:
            guard let value = item.value, let url = URL(string: value) else { return nil }
            return GenerationJob(title: url.host ?? value, source: .url(url))
        case .text:
            guard let text = item.value, !text.isEmpty else { return nil }
            return GenerationJob(title: item.name ?? "Shared text", source: .text(text))
        case .pdf, .markdown:
            guard let payload else { return nil }
            try? fm.createDirectory(at: keptFiles, withIntermediateDirectories: true)
            let kept = keptFiles.appending(path: "\(UUID().uuidString.prefix(8))-\(item.name ?? payload.lastPathComponent)")
            guard (try? fm.copyItem(at: payload, to: kept)) != nil,
                  let bookmark = try? kept.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
            let name = item.name ?? payload.lastPathComponent
            return GenerationJob(title: name, source: .file(name: name, bookmark: bookmark, kind: item.kind == .pdf ? .pdf : .markdown))
        case .image:
            guard let payload else { return nil }
            let job = GenerationJob(title: item.name ?? "Shared image", source: .images([payload.lastPathComponent]))
            let folder = queue.folder(for: job.id)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? fm.copyItem(at: payload, to: folder.appending(path: payload.lastPathComponent))) != nil else { return nil }
            return job
        }
    }
}
