import Foundation
import Testing
@testable import AIQuizCore

@Suite("Folder tree (F-63)")
struct FolderTreeTests {
    // Languages ⊃ Spanish ⊃ Verbs; Languages ⊃ french; Science
    let languages = FolderNode(id: UUID(), name: "Languages", parentID: nil)
    let science = FolderNode(id: UUID(), name: "Science", parentID: nil)
    var spanish: FolderNode { FolderNode(id: spanishID, name: "Spanish", parentID: languages.id) }
    var french: FolderNode { FolderNode(id: frenchID, name: "french", parentID: languages.id) }
    var verbs: FolderNode { FolderNode(id: verbsID, name: "Verbs", parentID: spanishID) }
    let spanishID = UUID(), frenchID = UUID(), verbsID = UUID()
    var all: [FolderNode] { [science, verbs, languages, spanish, french] }

    @Test("a path runs from the top level down to the folder")
    func path() {
        #expect(FolderTree.path(to: verbsID, in: all).map(\.name) == ["Languages", "Spanish", "Verbs"])
        #expect(FolderTree.path(to: nil, in: all).isEmpty)
        #expect(FolderTree.path(to: UUID(), in: all).isEmpty)
    }

    @Test("descendants are everything inside, at any depth")
    func descendants() {
        #expect(FolderTree.descendants(of: languages.id, in: all) == [spanishID, frenchID, verbsID])
        #expect(FolderTree.descendants(of: verbsID, in: all).isEmpty)
    }

    @Test("a folder can't move into itself or anything inside it")
    func moves() {
        #expect(!FolderTree.canMove(languages.id, into: languages.id, in: all))
        #expect(!FolderTree.canMove(languages.id, into: verbsID, in: all))
        #expect(FolderTree.canMove(verbsID, into: languages.id, in: all))
        #expect(FolderTree.canMove(spanishID, into: science.id, in: all))
        #expect(FolderTree.canMove(verbsID, into: nil, in: all), "anything can go to the top level")
    }

    @Test("children sort by name the way Files does, ignoring case")
    func children() {
        #expect(FolderTree.children(of: nil, in: all).map(\.name) == ["Languages", "Science"])
        #expect(FolderTree.children(of: languages.id, in: all).map(\.name) == ["french", "Spanish"])
    }

    @Test("the outline lists each folder followed by its contents, minus the one being moved")
    func outline() {
        let full = FolderTree.outline(all).map { "\(String(repeating: "-", count: $0.depth))\($0.folder.name)" }
        #expect(full == ["Languages", "-french", "-Spanish", "--Verbs", "Science"])
        let moving = FolderTree.outline(all, excluding: spanishID).map(\.folder.name)
        #expect(moving == ["Languages", "french", "Science"])
    }

    @Test("names are trimmed, and a taken name gets a number")
    func names() {
        #expect(FolderTree.cleanName("  Spanish  ") == "Spanish")
        #expect(FolderTree.cleanName("   ") == nil)
        #expect(FolderTree.uniqueName("Spanish", among: ["Science"]) == "Spanish")
        #expect(FolderTree.uniqueName("Spanish", among: ["spanish", "Spanish 2"]) == "Spanish 3")
    }

    @Test("a loop in stored data stops instead of spinning")
    func loops() {
        let a = UUID(), b = UUID()
        let looped = [FolderNode(id: a, name: "A", parentID: b), FolderNode(id: b, name: "B", parentID: a)]
        #expect(FolderTree.path(to: a, in: looped).count == 2)
        #expect(FolderTree.descendants(of: a, in: looped) == [b])
    }

    @Test("a quiz's folder path round-trips through JSON and is left out at the top level")
    func payloadFolder() throws {
        let inFolder = QuizPayload(name: "Verbs", folder: ["Languages", "Spanish"], cards: [CardPayload(prompt: "ser", longAnswer: "to be")])
        let data = try QuizDecoder.encode(inFolder)
        #expect(String(decoding: data, as: UTF8.self).contains(#""folder" : ["#))
        #expect(try QuizDecoder.decode(data).folder == ["Languages", "Spanish"])
        let top = try QuizDecoder.encode(QuizPayload(name: "Top", cards: [CardPayload(prompt: "p", longAnswer: "a")]))
        #expect(!String(decoding: top, as: UTF8.self).contains("folder"))
        #expect(try QuizDecoder.decode(Data(#"{"quiz":{"name":"x","folder":[" A ",""],"cards":[{"prompt":"p","long_answer":"a"}]}}"#.utf8)).folder == ["A"])
    }
}
