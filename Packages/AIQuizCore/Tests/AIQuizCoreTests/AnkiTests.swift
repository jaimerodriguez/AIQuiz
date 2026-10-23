import Foundation
import Testing
@testable import AIQuizCore

/// The interchange fixtures, made by Anki 26.9.3 itself (tools/anki/make_fixtures.py).
enum AnkiFixture {
    static func url(_ name: String) throws -> URL {
        let base = try #require(Bundle.module.resourceURL)
        return base.appending(path: "Fixtures/Anki/\(name)")
    }

    struct Expected: Decodable {
        struct Card: Decodable, Equatable {
            let kind: String
            let prompt: String
            let long_answer: String
            let short_answer: String?
            let hint: String?
        }
        struct Schedule: Decodable {
            let type: Int
            let reps: Int
            let lapses: Int
            let ivl: Int
            let stability: Double?
            let difficulty: Double?
            let revlogEases: [Int]
        }
        struct Media: Decodable { let images: Int; let sounds: Int }
        struct Package: Decodable {
            let quizzes: [String: [Card]]
            let media: Media
            let schedules: [String: Schedule]
        }
        let anki: String
        let plain: Package
        let fsrs: Package
    }

    static func expected() throws -> Expected {
        try JSONDecoder().decode(Expected.self, from: Data(contentsOf: url("expected.json")))
    }
}

private extension AnkiImportResult.Card {
    var expected: AnkiFixture.Expected.Card {
        .init(kind: payload.kind.rawValue, prompt: payload.prompt, long_answer: payload.longAnswer, short_answer: payload.shortAnswer, hint: payload.hint)
    }
}

@Suite("Anki import from real Anki packages (docs/anki-interchange.md §2)")
struct AnkiImportTests {
    @Test("every package format gives the same quizzes", arguments: [
        ("latest.apkg", AnkiPackage.Format.latest), ("legacy2.apkg", .legacy2), ("legacy1.apkg", .legacy1), ("collection.colpkg", .latest)
    ])
    func formats(_ file: String, _ format: AnkiPackage.Format) throws {
        let expected = try AnkiFixture.expected().plain
        let result = try AnkiImporter.importPackage(at: AnkiFixture.url(file))
        #expect(result.format == format)
        #expect(Set(result.quizzes.map(\.name)) == Set(expected.quizzes.keys))
        for quiz in result.quizzes {
            #expect(quiz.cards.map(\.expected) == expected.quizzes[quiz.name], "\(file) · \(quiz.name)")
        }
        #expect(result.skippedImages == expected.media.images)
        #expect(result.skippedSounds == expected.media.sounds)
        #expect(result.skippedCards == 0)
        #expect(result.quizzes.flatMap(\.cards).allSatisfy { CardValidator.problem(with: $0.payload) == nil })
    }

    private func card(_ result: AnkiImportResult, _ prompt: String) throws -> AnkiImportResult.Card {
        try #require(result.quizzes.flatMap(\.cards).first { $0.payload.prompt == prompt })
    }

    @Test("review history carries over: due dates, reps, lapses and answer counts")
    func history() throws {
        let expected = try AnkiFixture.expected().plain.schedules
        for file in ["latest.apkg", "legacy2.apkg"] {
            let result = try AnkiImporter.importPackage(at: AnkiFixture.url(file))
            let hablar = try card(result, "hablar")
            let hablarAnki = try #require(expected["<b>hablar</b>"])
            #expect(hablar.schedule.reps == hablarAnki.reps)
            #expect(!hablar.schedule.isNew)
            let gap = try #require(hablar.schedule.dueAt).timeIntervalSince(try #require(hablar.schedule.lastReviewedAt)) / 86_400
            #expect(abs(gap - Double(hablarAnki.ivl)) <= 1, "\(file): due \(gap) days after the review, Anki says \(hablarAnki.ivl)")
            #expect(hablar.correct == 1 && hablar.wrong == 0)
            #expect(hablar.schedule.lastRating == 4)

            let comer = try card(result, "comer")
            #expect(comer.correct == 2)
            #expect(comer.schedule.stability == Double(try #require(expected["comer"]).ivl), "no FSRS memory: stability is the interval")

            let vivir = try card(result, "vivir")
            #expect(vivir.schedule.lapses == 1)
            #expect(vivir.correct == 1 && vivir.wrong == 1, "the manual reschedule (ease 0) is not an answer")
            #expect(vivir.schedule.lastRating == 1)
            let due = try #require(vivir.schedule.dueAt)
            #expect(abs(due.timeIntervalSince(try #require(vivir.schedule.lastReviewedAt))) < 86_400, "a lapse is due again the same day")

            #expect(try card(result, "to live").schedule.isNew, "the never-studied reverse card is new")
            #expect(try card(result, "ser (yo)").schedule == FSRS.State())
        }
    }

    @Test("with FSRS on in Anki, its stability and difficulty are kept")
    func fsrsMemory() throws {
        let expected = try AnkiFixture.expected().fsrs.schedules
        let result = try AnkiImporter.importPackage(at: AnkiFixture.url("fsrs.apkg"))
        for (prompt, key) in [("hablar", "<b>hablar</b>"), ("comer", "comer"), ("vivir", "vivir")] {
            let imported = try card(result, prompt).schedule
            let anki = try #require(expected[key])
            #expect(abs(imported.stability - (anki.stability ?? -1)) < 0.001, "\(prompt) stability")
            #expect(abs(imported.difficulty - (anki.difficulty ?? -1)) < 0.001, "\(prompt) difficulty")
        }
    }

    @Test("a file without a collection, or not a zip, is a clear error")
    func badFiles() throws {
        let dir = FileManager.default.temporaryDirectory
        let notZip = dir.appending(path: "not-a-zip-\(UUID()).apkg")
        try Data("hello".utf8).write(to: notZip)
        #expect(throws: ZipArchive.Failure.notAZip) { try AnkiImporter.importPackage(at: notZip) }
        let empty = dir.appending(path: "no-collection-\(UUID()).apkg")
        try ZipArchive.write([("media", Data("{}".utf8))]).write(to: empty)
        #expect(throws: AnkiPackage.Failure.noCollection) { try AnkiImporter.importPackage(at: empty) }
    }

    @Test("Image Occlusion and cards that render empty are skipped and counted")
    func skipped() {
        let occlusion = AnkiCollection.Notetype(id: 1, name: "Image Occlusion", isCloze: true, fields: ["Occlusion", "Image"],
                                                templates: [.init(ord: 0, name: "Image Occlusion", question: "{{cloze:Occlusion}}", answer: "{{cloze:Occlusion}}")])
        let optional = AnkiCollection.Notetype(id: 2, name: "Basic (optional reversed card)", isCloze: false, fields: ["Front", "Back", "Add Reverse"],
                                               templates: [.init(ord: 0, name: "Card 1", question: "{{Front}}", answer: "{{FrontSide}}<hr id=answer>{{Back}}"),
                                                           .init(ord: 1, name: "Card 2", question: "{{#Add Reverse}}{{Back}}{{/Add Reverse}}", answer: "{{FrontSide}}<hr id=answer>{{Front}}")])
        let collection = AnkiCollection(
            createdAt: 0, schemaVersion: 11, notetypes: [occlusion, optional], decks: [.init(id: 1, path: ["Deck"])],
            notes: [.init(id: 10, notetypeId: 1, fields: ["{{c1::image-occlusion:rect:left=.1}}", "<img src=\"a.png\">"], tags: []),
                    .init(id: 11, notetypeId: 2, fields: ["Front", "Back", ""], tags: [])],
            cards: [card(id: 1, note: 10, ord: 0), card(id: 2, note: 11, ord: 0), card(id: 3, note: 11, ord: 1)],
            reviews: []
        )
        let result = AnkiImporter.convert(collection, format: .legacy2)
        #expect(result.cardCount == 1)
        #expect(result.skippedCards == 2)
        #expect(result.skippedImages == 1)
    }

    private func card(id: Int64, note: Int64, ord: Int) -> AnkiCollection.Card {
        AnkiCollection.Card(id: id, noteId: note, deckId: 1, ord: ord, type: 0, queue: 0, due: 1, interval: 0, factor: 0, reps: 0, lapses: 0, data: "")
    }
}

@Suite("Anki package building blocks")
struct AnkiBuildingBlockTests {
    @Test("zip: written entries read back; deflated entries inflate")
    func zip() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID()).zip")
        let big = Data((0..<5_000).map { UInt8($0 % 251) })
        try ZipArchive.write([("a.txt", Data("alpha".utf8)), ("dir/b.bin", big), ("empty", Data())]).write(to: file)
        let zip = try ZipArchive(url: file)
        #expect(zip.entries.map(\.name) == ["a.txt", "dir/b.bin", "empty"])
        #expect(try zip.data(for: #require(zip.entry("a.txt"))) == Data("alpha".utf8))
        #expect(try zip.data(for: #require(zip.entry("dir/b.bin"))) == big)
        #expect(try zip.data(for: #require(zip.entry("empty"))).isEmpty)
        // legacy1.apkg was written by Python's zipfile with DEFLATE.
        let legacy = try ZipArchive(url: AnkiFixture.url("legacy1.apkg"))
        let media = try legacy.data(for: #require(legacy.entry("media")))
        #expect(String(decoding: media, as: UTF8.self).contains("perro.png"))
    }

    @Test("CRC-32 matches the standard check value")
    func crc() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("zstd: Anki's compressed collection decompresses to SQLite; damaged data fails")
    func zstd() throws {
        let zip = try ZipArchive(url: AnkiFixture.url("latest.apkg"))
        let compressed = try zip.data(for: #require(zip.entry("collection.anki21b")))
        let database = try Zstd.decompress(compressed)
        #expect(database.prefix(15) == Data("SQLite format 3".utf8))
        #expect(throws: Zstd.Failure.self) { try Zstd.decompress(compressed.prefix(compressed.count / 2)) }
        #expect(throws: Zstd.Failure.self) { try Zstd.decompress(Data("not zstd".utf8)) }
    }

    @Test("protobuf: the first value of each field")
    func protobuf() {
        // field 1 varint 1; field 3 string "css"; field 1 again (ignored).
        let fields = Protobuf.fields(Data([0x08, 0x01, 0x1A, 0x03, 0x63, 0x73, 0x73, 0x08, 0x00]))
        #expect(fields[1]?.varint == 1)
        #expect(fields[3]?.string == "css")
    }

    @Test("templates: fields, sections, filters and FrontSide")
    func templates() {
        let fields = ["Front": "Bonjour", "Back": "<b>Hello</b>", "Empty": "", "Reading": " 日本[にほん]"]
        func q(_ t: String) -> String { AnkiTemplate.render(t, .init(fields: fields, side: .question)) }
        func a(_ t: String, front: String = "") -> String { AnkiTemplate.render(t, .init(fields: fields, side: .answer, frontSide: front)) }
        #expect(q("{{Front}} / {{text:Back}}") == "Bonjour / Hello")
        #expect(q("{{#Back}}has back{{/Back}}{{#Empty}}no{{/Empty}}{{^Empty}} and no empty{{/Empty}}") == "has back and no empty")
        #expect(q("{{Front}}{{type:Back}}") == "Bonjour")
        #expect(a("{{type:Back}}") == "<b>Hello</b>")
        #expect(q("{{hint:Back}}") == "")
        #expect(q("{{kanji:Reading}}") == "日本")
        #expect(q("{{kana:Reading}}") == "にほん")
        #expect(a("{{FrontSide}}<hr id=answer>{{Back}}", front: "Q") == "Q<hr id=answer><b>Hello</b>")
        #expect(q("{{Missing}}x") == "x")
        #expect(q("{{#Front}}{{#Back}}both{{/Back}}{{/Front}}") == "both")
    }

    @Test("cloze: the active deletion is a blank; others show their text")
    func cloze() {
        let text = "{{c1::Paris::city}} is in {{c2::France}}; {{c1::Paris}} again."
        let one = Cloze.anki(text, number: 1, side: .question)
        #expect(one.text == "{{blank}} is in France; {{blank}} again.")
        #expect(one.answers == ["Paris", "Paris"])
        #expect(one.hints == ["city"])
        #expect(Cloze.anki(text, number: 1, side: .answer).text == "Paris is in France; Paris again.")
        #expect(Cloze.anki(text, number: 2, side: .question).text == "Paris is in {{blank}}; Paris again.")
        #expect(Cloze.ankiNumbers(text) == [1, 2])
    }

    @Test("HTML to text keeps line breaks and drops markup and sounds")
    func html() {
        #expect(HTMLText.plain("a<br>b<div>c</div>d") == "a\nb\nc\nd")
        #expect(HTMLText.plain("<div>x</div><div>y<br></div>") == "x\ny", "block boundaries make one line break")
        #expect(HTMLText.plain("x<br><br>y") == "x\n\ny", "each <br> counts")
        #expect(HTMLText.plain("to eat&nbsp;(regular)&amp;more") == "to eat (regular)&more")
        #expect(HTMLText.plain("el perro [sound:perro.mp3]") == "el perro")
        #expect(HTMLText.plain("<style>.x{}</style>Shown") == "Shown")
        #expect(HTMLText.plain("one\n\ntwo") == "one\n\ntwo", "plain text keeps its own lines")
        #expect(HTMLText.plain("<b>x</b>\n\n<i>y</i>") == "x y", "in HTML a newline is a space")
        #expect(HTMLText.media(#"<img src="a.png"> [sound:b.mp3] <img src="c.png">"#) == (images: 2, sounds: 1))
    }
}

@Suite("Anki export (docs/anki-interchange.md §3)")
struct AnkiExportTests {
    static let cards: [AnkiExporter.Card] = [
        .init(payload: CardPayload(prompt: "What is ATP?", longAnswer: "The cell's energy currency.\nMade in mitochondria.", shortAnswer: "Energy <currency> & more",
                                   hint: "Think power", explanation: "It stores energy in phosphate bonds.", mnemonic: "A Tiny Power-pack")),
        .init(payload: CardPayload(prompt: "Which is a mammal?", longAnswer: "The whale breathes air.", shortAnswer: "Whale", kind: .multipleChoice, options: ["Shark", "Whale", "Trout"])),
        .init(payload: CardPayload(prompt: "The sun is a star.", longAnswer: "It is a G-type star.", shortAnswer: "true", kind: .trueFalse)),
        .init(payload: CardPayload(prompt: "{{blank}} is the capital of {{blank}}.", longAnswer: "Canberra, Australia.", shortAnswer: "Canberra|Australia", hint: "Planned city", kind: .cloze),
              schedule: FSRS.State(stability: 12.5, difficulty: 4.2, dueAt: Date(timeIntervalSince1970: 1_800_000_000), reps: 3, lapses: 1, lastRating: 3,
                                   lastReviewedAt: Date(timeIntervalSince1970: 1_800_000_000 - 12 * 86_400)))
    ]

    @Test("export, then import: every card and its schedule come back")
    func roundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_799_000_000)
        let data = try AnkiExporter.package(quizName: "Biology › Cells", cards: Self.cards, now: now)
        let file = FileManager.default.temporaryDirectory.appending(path: "roundtrip-\(UUID()).apkg")
        try data.write(to: file)
        let zip = try ZipArchive(url: file)
        #expect(zip.entries.map(\.name) == ["collection.anki2", "media"])

        let result = try AnkiImporter.importPackage(at: file, now: now)
        #expect(result.format == .legacy1)
        #expect(result.quizzes.map(\.name) == ["Biology › Cells"])
        let back = try #require(result.quizzes.first).cards
        #expect(back.map(\.payload) == Self.cards.map(\.payload))
        #expect(back[0].schedule.isNew)
        let reviewed = back[3].schedule
        #expect(abs(reviewed.stability - 12.5) < 0.0001)
        #expect(abs(reviewed.difficulty - 4.2) < 0.0001)
        #expect(reviewed.reps == 3 && reviewed.lapses == 1)
        let calendar = Calendar.current
        #expect(calendar.isDate(try #require(reviewed.dueAt), inSameDayAs: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(reviewed.lastReviewedAt == Date(timeIntervalSince1970: 1_800_000_000 - 12 * 86_400))
    }

    @Test("an AIQuiz export imported into Anki and exported again by Anki comes back the same")
    func throughAnki() throws {
        // tools/anki/verify_export.py made this from writeForAnki's export.
        let result = try AnkiImporter.importPackage(at: AnkiFixture.url("aiquiz-via-anki.apkg"))
        #expect(result.format == .latest)
        #expect(result.quizzes.map(\.name) == ["Biology › Cells"])
        let back = try #require(result.quizzes.first).cards
        #expect(back.map(\.payload) == Self.cards.map(\.payload))
        let reviewed = back[3].schedule
        #expect(abs(reviewed.stability - 12.5) < 0.001 && abs(reviewed.difficulty - 4.2) < 0.001)
        #expect(reviewed.reps == 3 && reviewed.lapses == 1)
        #expect(back[0].schedule.isNew)
    }

    @Test("fields are escaped HTML; a cloze's blanks are one c1 deletion")
    func fields() {
        let basic = AnkiExporter.basicFieldValues(Self.cards[0].payload)
        #expect(basic[0] == "What is ATP?")
        #expect(basic[1] == "The cell's energy currency.<br>Made in mitochondria.")
        #expect(basic[2] == "Energy &lt;currency&gt; &amp; more")
        #expect(basic[7] == "recall")
        #expect(AnkiExporter.basicFieldValues(Self.cards[1].payload)[4] == "Shark<br>Whale<br>Trout")
        #expect(AnkiExporter.clozeFieldValues(Self.cards[3].payload)[0] == "{{c1::Canberra}} is the capital of {{c1::Australia}}.")
    }

    @Test("the duplicate checksum is Anki's: first 8 hex digits of SHA-1")
    func checksum() {
        // sha1("hablar") starts 18c35a29: 415455785, the csum Anki stored in the fixture.
        #expect(AnkiExporter.checksum("hablar") == 0x18c3_5a29)
    }

    /// Writes an export for tools/anki/verify_export.py when AIQUIZ_ANKI_EXPORT names a file.
    @Test("write an export for Anki to check", .enabled(if: ProcessInfo.processInfo.environment["AIQUIZ_ANKI_EXPORT"] != nil))
    func writeForAnki() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AIQUIZ_ANKI_EXPORT"])
        try AnkiExporter.package(quizName: "Biology › Cells", cards: Self.cards).write(to: URL(filePath: path))
    }
}
