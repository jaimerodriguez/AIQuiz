import Foundation
import CryptoKit

/// Writes a quiz as an Anki package (docs/anki-interchange.md §3): a schema 11
/// `collection.anki2`, which every Anki version and AnkiDroid import. Cards use two note
/// types, "AIQuiz" and "AIQuiz Cloze", whose fields keep everything an AIQuiz card has, so
/// importing an AIQuiz export gives back the same cards.
public enum AnkiExporter {
    public struct Card: Sendable, Equatable {
        public var payload: CardPayload
        public var schedule: FSRS.State

        public init(payload: CardPayload, schedule: FSRS.State = FSRS.State()) {
            self.payload = payload
            self.schedule = schedule
        }
    }

    public static let basicFields = ["Front", "Back", "Short Answer", "Hint", "Options", "Explanation", "Mnemonic", "Kind"]
    public static let clozeFields = ["Text", "Back Extra", "Hint", "Explanation", "Mnemonic"]

    static let basicQuestion = "{{Front}}{{#Options}}<br><br>{{Options}}{{/Options}}{{#Hint}}<br><br>{{hint:Hint}}{{/Hint}}"
    static let basicAnswer = "{{FrontSide}}\n\n<hr id=answer>\n\n{{#Short Answer}}<b>{{Short Answer}}</b><br><br>{{/Short Answer}}{{Back}}{{#Explanation}}<br><br>{{Explanation}}{{/Explanation}}{{#Mnemonic}}<br><br><i>{{Mnemonic}}</i>{{/Mnemonic}}"
    static let clozeQuestion = "{{cloze:Text}}{{#Hint}}<br><br>{{hint:Hint}}{{/Hint}}"
    static let clozeAnswer = "{{cloze:Text}}<br>\n{{Back Extra}}{{#Explanation}}<br><br>{{Explanation}}{{/Explanation}}{{#Mnemonic}}<br><br><i>{{Mnemonic}}</i>{{/Mnemonic}}"
    static let css = ".card {\n    font-family: arial;\n    font-size: 20px;\n    line-height: 1.5;\n    text-align: center;\n    color: black;\n    background-color: white;\n}\n.cloze {\n    font-weight: bold;\n    color: blue;\n}\n.nightMode .cloze {\n    color: lightblue;\n}\n"

    /// The `.apkg` bytes for one quiz: one deck named after it ("A › B" becomes "A::B").
    public static func package(quizName: String, cards: [Card], now: Date = .now, calendar: Calendar = .current) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appending(path: "anki-export-\(UUID().uuidString).anki2")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(at: URL(filePath: file.path + suffix))
            }
        }
        try writeCollection(to: file.path, quizName: quizName, cards: cards, now: now, calendar: calendar)
        let collection = try Data(contentsOf: file)
        return ZipArchive.write([("collection.anki2", collection), ("media", Data("{}".utf8))])
    }

    static func writeCollection(to path: String, quizName: String, cards: [Card], now: Date, calendar: Calendar) throws {
        let db = try SQLiteDatabase(path: path)
        try db.execute(schema11)
        try db.execute("begin")

        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let nowSecs = Int64(now.timeIntervalSince1970)
        // Review due dates count days from the collection's first day, so start it on the
        // earliest due date (or today) to keep every due day zero or later.
        let earliest = cards.compactMap { $0.schedule.isNew ? nil : $0.schedule.dueAt }.min() ?? now
        let crt = Int64(calendar.startOfDay(for: min(now, earliest)).timeIntervalSince1970)

        let basicId = nowMs - 100, clozeId = nowMs - 99
        let deckPath = quizName.components(separatedBy: AnkiImporter.separator).map { $0.replacingOccurrences(of: "::", with: ":") }
        var decks: [String: Any] = ["1": deckJSON(id: 1, name: "Default", mod: 0)]
        var deckId: Int64 = 1
        for depth in 1...max(1, deckPath.count) {
            deckId = nowMs - 98 + Int64(depth)
            decks[String(deckId)] = deckJSON(id: deckId, name: deckPath.prefix(depth).joined(separator: "::"), mod: nowSecs)
        }
        let models: [String: Any] = [
            String(basicId): modelJSON(id: basicId, name: "AIQuiz", cloze: false, fields: basicFields, question: basicQuestion, answer: basicAnswer, deck: deckId, mod: nowSecs),
            String(clozeId): modelJSON(id: clozeId, name: "AIQuiz Cloze", cloze: true, fields: clozeFields, question: clozeQuestion, answer: clozeAnswer, deck: deckId, mod: nowSecs)
        ]
        let conf: [String: Any] = [
            "activeDecks": [deckId], "curDeck": deckId, "newSpread": 0, "collapseTime": 1200, "timeLim": 0,
            "estTimes": true, "dueCounts": true, "curModel": basicId, "nextPos": cards.count + 1, "sortType": "noteFld",
            "sortBackwards": false, "addToCur": true, "dayLearnFirst": false, "schedVer": 2, "sched2021": true,
            "creationOffset": -calendar.timeZone.secondsFromGMT(for: now) / 60
        ]
        try db.execute("delete from col")
        try db.execute("insert into col values (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, '{}')", [
            .int(crt), .int(nowMs), .int(nowMs), .text(json(conf)), .text(json(models)), .text(json(decks)), .text(json(["1": defaultDeckConfig]))
        ])

        for (index, card) in cards.enumerated() {
            let noteId = nowMs + Int64(index)
            let cloze = card.payload.kind == .cloze
            let fields = cloze ? clozeFieldValues(card.payload) : basicFieldValues(card.payload)
            let sortField = HTMLText.plain(fields[0])
            try db.execute("insert into notes values (?, ?, ?, ?, -1, ' AIQuiz ', ?, ?, ?, 0, '')", [
                .int(noteId), .text(guid()), .int(cloze ? clozeId : basicId), .int(nowSecs),
                .text(fields.joined(separator: "\u{1f}")), .text(sortField), .int(checksum(sortField))
            ])
            let s = card.schedule
            if s.isNew || s.dueAt == nil {
                try db.execute("insert into cards values (?, ?, ?, 0, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')", [
                    .int(noteId), .int(noteId), .int(deckId), .int(nowSecs), .int(Int64(index + 1))
                ])
            } else {
                let dueAt = s.dueAt ?? now
                let last = s.lastReviewedAt ?? now
                let due = Int64(((calendar.startOfDay(for: dueAt).timeIntervalSince1970 - Double(crt)) / 86_400).rounded())
                let interval = max(1, Int((dueAt.timeIntervalSince(last) / 86_400).rounded()))
                let ease = Int(min(3_500, max(1_300, 2_500 - (s.difficulty - 5) * 240)))
                let data = json(["s": s.stability, "d": s.difficulty, "lrt": Int64(last.timeIntervalSince1970)])
                try db.execute("insert into cards values (?, ?, ?, 0, ?, -1, 2, 2, ?, ?, ?, ?, ?, 0, 0, 0, 0, ?)", [
                    .int(noteId), .int(noteId), .int(deckId), .int(nowSecs), .int(due), .int(Int64(interval)),
                    .int(Int64(ease)), .int(Int64(s.reps)), .int(Int64(s.lapses)), .text(data)
                ])
            }
        }
        try db.execute("commit")
    }

    // MARK: Fields

    /// Text as Anki field HTML: escaped, line breaks as `<br>`.
    static func html(_ text: String?) -> String {
        (text ?? "")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    static func basicFieldValues(_ card: CardPayload) -> [String] {
        [html(card.prompt), html(card.longAnswer), html(card.shortAnswer), html(card.hint),
         (card.options ?? []).map(html).joined(separator: "<br>"), html(card.explanation), html(card.mnemonic), card.kind.rawValue]
    }

    /// Every blank becomes `{{c1::answer}}`: AIQuiz asks a card's blanks together, which is
    /// what one Anki cloze number does.
    static func clozeFieldValues(_ card: CardPayload) -> [String] {
        let segments = Cloze.segments(card.prompt)
        let answers = Cloze.expected(card.shortAnswer, blanks: segments.count - 1)
        var text = html(segments.first)
        for (index, segment) in segments.dropFirst().enumerated() {
            text += "{{c1::" + html(answers[index]) + "}}" + html(segment)
        }
        return [text, html(card.longAnswer), html(card.hint), html(card.explanation), html(card.mnemonic)]
    }

    /// The card an AIQuiz note type holds, read field by field; nil for any other note type.
    static func aiQuizPayload(notetype: AnkiCollection.Notetype, values: [String: String]) -> CardPayload? {
        guard notetype.name.hasPrefix("AIQuiz") else { return nil }
        func text(_ name: String) -> String? {
            let value = HTMLText.plain(values[name] ?? "")
            return value.isEmpty ? nil : value
        }
        if notetype.isCloze {
            guard Set(clozeFields).isSubset(of: notetype.fields) else { return nil }
            let parts = Cloze.anki(values["Text"] ?? "", number: 1, side: .question)
            let prompt = HTMLText.plain(parts.text)
            let filled = HTMLText.plain(Cloze.anki(values["Text"] ?? "", number: 1, side: .answer).text)
            return CardPayload(prompt: prompt, longAnswer: text("Back Extra") ?? filled,
                               shortAnswer: parts.answers.map { HTMLText.plain($0) }.joined(separator: "|"),
                               hint: text("Hint"), kind: .cloze, explanation: text("Explanation"), mnemonic: text("Mnemonic"))
        }
        guard Set(basicFields).isSubset(of: notetype.fields), let prompt = text("Front") else { return nil }
        let kind = CardKind(rawValue: HTMLText.plain(values["Kind"] ?? "")) ?? .recall
        let options = text("Options")?.components(separatedBy: "\n").filter { !$0.isEmpty }
        return CardPayload(prompt: prompt, longAnswer: text("Back") ?? "", shortAnswer: text("Short Answer"), hint: text("Hint"),
                           kind: kind, options: kind == .multipleChoice ? options : nil,
                           explanation: text("Explanation"), mnemonic: text("Mnemonic"))
    }

    // MARK: Collection pieces

    /// Anki's duplicate check: the first 8 hex digits of the SHA-1 of the sort field.
    static func checksum(_ text: String) -> Int64 {
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return digest.prefix(4).reduce(Int64(0)) { $0 << 8 | Int64($1) }
    }

    static func guid() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_`{|}~")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }

    static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func deckJSON(id: Int64, name: String, mod: Int64) -> [String: Any] {
        ["id": id, "mod": mod, "name": name, "usn": -1, "lrnToday": [0, 0], "revToday": [0, 0], "newToday": [0, 0], "timeToday": [0, 0],
         "collapsed": false, "browserCollapsed": false, "desc": "", "dyn": 0, "conf": 1, "extendNew": 0, "extendRev": 0]
    }

    static func modelJSON(id: Int64, name: String, cloze: Bool, fields: [String], question: String, answer: String, deck: Int64, mod: Int64) -> [String: Any] {
        [
            "id": id, "name": name, "type": cloze ? 1 : 0, "mod": mod, "usn": -1, "sortf": 0, "did": deck,
            "tmpls": [["name": cloze ? "Cloze" : "Card 1", "ord": 0, "qfmt": question, "afmt": answer, "bqfmt": "", "bafmt": "", "did": NSNull(), "bfont": "", "bsize": 0]],
            "flds": fields.enumerated().map { ["name": $0.element, "ord": $0.offset, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": [String]()] },
            "css": css,
            "latexPre": "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
            "latexPost": "\\end{document}", "latexsvg": false, "req": [[0, "any", [0]]], "tags": [String](), "vers": [String]()
        ]
    }

    static var defaultDeckConfig: [String: Any] { [
        "id": 1, "mod": 0, "name": "Default", "usn": 0, "maxTaken": 60, "autoplay": true, "timer": 0, "replayq": true, "dyn": false,
        "new": ["bury": false, "delays": [1.0, 10.0], "initialFactor": 2_500, "ints": [1, 4, 0], "order": 1, "perDay": 20],
        "rev": ["bury": false, "ease4": 1.3, "ivlFct": 1.0, "maxIvl": 36_500, "perDay": 200, "hardFactor": 1.2],
        "lapse": ["delays": [10.0], "leechAction": 1, "leechFails": 8, "minInt": 1, "mult": 0.0]
    ] }

    /// Anki's schema 11 tables (rslib/src/storage/schema11.sql).
    static let schema11 = """
    create table col (id integer primary key, crt integer not null, mod integer not null, scm integer not null, ver integer not null, dty integer not null, usn integer not null, ls integer not null, conf text not null, models text not null, decks text not null, dconf text not null, tags text not null);
    create table notes (id integer primary key, guid text not null, mid integer not null, mod integer not null, usn integer not null, tags text not null, flds text not null, sfld integer not null, csum integer not null, flags integer not null, data text not null);
    create table cards (id integer primary key, nid integer not null, did integer not null, ord integer not null, mod integer not null, usn integer not null, type integer not null, queue integer not null, due integer not null, ivl integer not null, factor integer not null, reps integer not null, lapses integer not null, left integer not null, odue integer not null, odid integer not null, flags integer not null, data text not null);
    create table revlog (id integer primary key, cid integer not null, usn integer not null, ease integer not null, ivl integer not null, lastIvl integer not null, factor integer not null, time integer not null, type integer not null);
    create table graves (usn integer not null, oid integer not null, type integer not null);
    create index ix_notes_usn on notes (usn);
    create index ix_cards_usn on cards (usn);
    create index ix_revlog_usn on revlog (usn);
    create index ix_cards_nid on cards (nid);
    create index ix_cards_sched on cards (did, queue, due);
    create index ix_revlog_cid on revlog (cid);
    create index ix_notes_csum on notes (csum);
    """
}
