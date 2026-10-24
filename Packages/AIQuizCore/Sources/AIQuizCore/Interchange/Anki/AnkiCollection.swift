import Foundation

/// The parts of an Anki collection AIQuiz uses, read from either schema Anki has shipped
/// (docs/anki-interchange.md §1): schema 11 (`collection.anki2` / `.anki21`, note types and
/// decks as JSON in `col`) and schema 18 (`collection.anki21b`, their own tables).
public struct AnkiCollection: Sendable, Equatable {
    public struct Notetype: Sendable, Equatable {
        public var id: Int64
        public var name: String
        public var isCloze: Bool
        /// Field names in order.
        public var fields: [String]
        public var templates: [Template]
        /// The note type's styling, read for the rules that hide elements.
        public var css: String = ""
    }

    public struct Template: Sendable, Equatable {
        public var ord: Int
        public var name: String
        public var question: String
        public var answer: String
    }

    public struct Deck: Sendable, Equatable {
        public var id: Int64
        /// "Spanish::Verbs" as ["Spanish", "Verbs"].
        public var path: [String]
    }

    public struct Note: Sendable, Equatable {
        public var id: Int64
        public var notetypeId: Int64
        public var fields: [String]
        public var tags: [String]
    }

    public struct Card: Sendable, Equatable {
        public var id: Int64
        public var noteId: Int64
        /// The card's home deck (its original deck when it sits in a filtered deck).
        public var deckId: Int64
        public var ord: Int
        /// 0 new, 1 learning, 2 review, 3 relearning.
        public var type: Int
        /// 0 new, 1 learning (due in epoch seconds), 2 review, 3 day learning; negative when suspended or buried.
        public var queue: Int
        public var due: Int64
        /// Days.
        public var interval: Int
        /// Ease, in permille (2500 = 250 %).
        public var factor: Int
        public var reps: Int
        public var lapses: Int
        /// JSON: FSRS memory state (`s`, `d`) and last review time (`lrt`) when present.
        public var data: String
    }

    public struct Review: Sendable, Equatable {
        /// Milliseconds since 1970, which is also when the review happened.
        public var id: Int64
        public var cardId: Int64
        /// 1 Again, 2 Hard, 3 Good, 4 Easy; 0 for a manual reschedule.
        public var ease: Int
    }

    /// Seconds since 1970 of the collection's first day; review due dates count days from it.
    public var createdAt: Int64
    public var schemaVersion: Int
    public var notetypes: [Notetype]
    public var decks: [Deck]
    public var notes: [Note]
    public var cards: [Card]
    public var reviews: [Review]
}

/// An Anki package (`.apkg`, `.colpkg`): which collection inside it is read.
public enum AnkiPackage {
    public enum Format: String, Sendable {
        /// `collection.anki21b`, zstd-compressed, schema 18 (Anki 2.1.50 and later).
        case latest
        /// `collection.anki21`, schema 11 ("Support older Anki versions").
        case legacy2
        /// `collection.anki2`, schema 11 (Anki 2.0).
        case legacy1
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case noCollection
        public var errorDescription: String? {
            "This file has no Anki collection in it. Export the deck from Anki as a .apkg and try again."
        }
    }

    /// Reads the newest collection in the package. Current packages also carry a stub
    /// `collection.anki2` that only says "please update", so the order matters.
    public static func read(url: URL) throws -> (AnkiCollection, Format) {
        let zip = try ZipArchive(url: url)
        let candidates: [(String, Format)] = [("collection.anki21b", .latest), ("collection.anki21", .legacy2), ("collection.anki2", .legacy1)]
        guard let (name, format) = candidates.first(where: { zip.entry($0.0) != nil }), let entry = zip.entry(name) else {
            throw Failure.noCollection
        }
        var data = try zip.data(for: entry)
        if format == .latest { data = try Zstd.decompress(data) }
        return (try read(database: data), format)
    }

    /// Reads a collection from SQLite file bytes.
    public static func read(database data: Data) throws -> AnkiCollection {
        let file = FileManager.default.temporaryDirectory.appending(path: "anki-\(UUID().uuidString).sqlite")
        try data.write(to: file)
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(at: URL(filePath: file.path + suffix))
            }
        }
        let db = try SQLiteDatabase(path: file.path)
        let col = try db.query("select crt, ver from col").first ?? []
        let createdAt = col.first?.int ?? 0
        let version = Int(col.dropFirst().first?.int ?? 0)
        let (notetypes, decks) = try db.tableExists("notetypes") ? readSchema18(db) : readSchema11(db)

        let notes = try db.query("select id, mid, flds, tags from notes order by id").map { row in
            AnkiCollection.Note(
                id: row[0].int, notetypeId: row[1].int,
                fields: row[2].text.components(separatedBy: "\u{1f}"),
                tags: row[3].text.split(whereSeparator: \.isWhitespace).map(String.init)
            )
        }
        let cards = try db.query("select id, nid, did, ord, type, queue, due, ivl, factor, reps, lapses, odid, data from cards order by nid, ord").map { row in
            AnkiCollection.Card(
                id: row[0].int, noteId: row[1].int, deckId: row[11].int != 0 ? row[11].int : row[2].int,
                ord: Int(row[3].int), type: Int(row[4].int), queue: Int(row[5].int), due: row[6].int,
                interval: Int(row[7].int), factor: Int(row[8].int), reps: Int(row[9].int), lapses: Int(row[10].int),
                data: row[12].text
            )
        }
        let reviews = try db.query("select id, cid, ease from revlog order by id").map {
            AnkiCollection.Review(id: $0[0].int, cardId: $0[1].int, ease: Int($0[2].int))
        }
        return AnkiCollection(createdAt: createdAt, schemaVersion: version, notetypes: notetypes, decks: decks, notes: notes, cards: cards, reviews: reviews)
    }

    // MARK: Schema 11: JSON in `col`

    private static func readSchema11(_ db: SQLiteDatabase) throws -> ([AnkiCollection.Notetype], [AnkiCollection.Deck]) {
        let row = try db.query("select models, decks from col").first ?? []
        let models = (try? JSONSerialization.jsonObject(with: Data((row.first?.text ?? "{}").utf8))) as? [String: Any] ?? [:]
        let decks = (try? JSONSerialization.jsonObject(with: Data((row.dropFirst().first?.text ?? "{}").utf8))) as? [String: Any] ?? [:]
        let notetypes: [AnkiCollection.Notetype] = models.values.compactMap { value in
            guard let model = value as? [String: Any] else { return nil }
            let fields = ((model["flds"] as? [[String: Any]]) ?? [])
                .sorted { ($0["ord"] as? Int ?? 0) < ($1["ord"] as? Int ?? 0) }
                .map { $0["name"] as? String ?? "" }
            let templates = ((model["tmpls"] as? [[String: Any]]) ?? []).map { t in
                AnkiCollection.Template(ord: t["ord"] as? Int ?? 0, name: t["name"] as? String ?? "",
                                        question: t["qfmt"] as? String ?? "", answer: t["afmt"] as? String ?? "")
            }
            return AnkiCollection.Notetype(id: int64(model["id"]), name: model["name"] as? String ?? "",
                                           isCloze: (model["type"] as? Int) == 1, fields: fields, templates: templates,
                                           css: model["css"] as? String ?? "")
        }
        let deckList: [AnkiCollection.Deck] = decks.values.compactMap { value in
            guard let deck = value as? [String: Any] else { return nil }
            return AnkiCollection.Deck(id: int64(deck["id"]), path: (deck["name"] as? String ?? "").components(separatedBy: "::"))
        }
        return (notetypes, deckList)
    }

    private static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s) ?? 0
        default: return 0
        }
    }

    // MARK: Schema 18: tables, with protobuf settings

    private static func readSchema18(_ db: SQLiteDatabase) throws -> ([AnkiCollection.Notetype], [AnkiCollection.Deck]) {
        var fields: [Int64: [String]] = [:]
        for row in try db.query("select ntid, name from fields order by ntid, ord") {
            fields[row[0].int, default: []].append(row[1].text)
        }
        var templates: [Int64: [AnkiCollection.Template]] = [:]
        for row in try db.query("select ntid, ord, name, config from templates order by ntid, ord") {
            let config = Protobuf.fields(row[3].blob)
            templates[row[0].int, default: []].append(AnkiCollection.Template(
                ord: Int(row[1].int), name: row[2].text,
                question: config[1]?.string ?? "", answer: config[2]?.string ?? ""
            ))
        }
        let notetypes = try db.query("select id, name, config from notetypes").map { row in
            let config = Protobuf.fields(row[2].blob)
            return AnkiCollection.Notetype(
                id: row[0].int, name: row[1].text,
                isCloze: config[1]?.varint == 1,
                fields: fields[row[0].int] ?? [], templates: templates[row[0].int] ?? [],
                css: config[3]?.string ?? ""
            )
        }
        let decks = try db.query("select id, name from decks").map {
            AnkiCollection.Deck(id: $0[0].int, path: $0[1].text.components(separatedBy: "\u{1f}"))
        }
        return (notetypes, decks)
    }
}

/// Reads the top-level fields of a protobuf message: enough for Anki's note type and
/// template settings (kind = 1, css = 3; q_format = 1, a_format = 2).
enum Protobuf {
    enum Value {
        case varint(UInt64)
        case bytes(Data)

        var varint: UInt64? { if case .varint(let v) = self { return v } else { return nil } }
        var string: String? { if case .bytes(let d) = self { return String(decoding: d, as: UTF8.self) } else { return nil } }
    }

    /// The first value of each field number.
    static func fields(_ data: Data) -> [Int: Value] {
        var result: [Int: Value] = [:]
        var at = data.startIndex
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while at < data.endIndex, shift < 64 {
                let byte = data[at]
                at += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while at < data.endIndex, let tag = varint() {
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = varint() else { return result }
                if result[number] == nil { result[number] = .varint(value) }
            case 1:
                at += 8
            case 2:
                guard let length = varint(), let end = data.index(at, offsetBy: Int(length), limitedBy: data.endIndex) else { return result }
                if result[number] == nil { result[number] = .bytes(data[at..<end]) }
                at = end
            case 5:
                at += 4
            default:
                return result
            }
        }
        return result
    }
}
