@preconcurrency import TDLibKit
import CryptoKit
import Foundation
import Testing
@testable import HushAI
@testable import HushCore
@testable import HushUI

struct LocalVaultTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "hush-vault-\(UUID().uuidString)")

    @Test func whatIsWrittenReadsBackOnlyWithTheSameKey() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let vault = LocalVault(directory: directory, key: key)
        try vault.write(Data("встречаемся в кафе".utf8), to: "transcripts")
        #expect(vault.read("transcripts") == Data("встречаемся в кафе".utf8))
        // On disk it's sealed, not plain text.
        let raw = try Data(contentsOf: directory.appending(path: "transcripts"))
        #expect(raw.range(of: Data("кафе".utf8)) == nil)
        #expect(LocalVault(directory: directory, key: SymmetricKey(size: .bits256)).read("transcripts") == nil)
        #expect(vault.read("missing") == nil)
    }
}

struct TranscriptionMappingTests {
    @Test func telegramsSpeechRecognitionBecomesATranscript() {
        #expect(MediaMapping.transcription(nil) == nil)
        #expect(MediaMapping.transcription(.speechRecognitionResultPending(.init(partialText: "Привет, давай"))) == .pending("Привет, давай"))
        #expect(MediaMapping.transcription(.speechRecognitionResultText(.init(text: "Привет, давай встретимся"))) == .done("Привет, давай встретимся"))
        let refused = MediaMapping.transcription(.speechRecognitionResultError(.init(error: TDLibKit.Error(code: 400, message: "PREMIUM_ACCOUNT_REQUIRED"))))
        guard case .failed(let reason) = refused else {
            Issue.record("expected a failure")
            return
        }
        #expect(reason.contains("Premium"))
    }

    @Test func searchSeesTranscripts() {
        let note = VoiceNoteMedia(fileId: 1, duration: 4, waveform: [], isListened: true, transcription: .done("встречаемся в кафе на Тверской"))
        let message = MessageModel(
            id: 1, date: .now, isOutgoing: false,
            sender: .init(id: 2, name: "Anna", accentColorId: 0, photoFileId: nil),
            body: .voiceNote(note, caption: RichText(text: "")),
            replyToMessageId: nil, reply: nil, forwardedFrom: nil, isEdited: false, status: .sent
        )
        #expect(message.transcript == "встречаемся в кафе на Тверской")
        #expect(SearchText.of(message) == "встречаемся в кафе на Тверской")
    }
}

struct SemanticIndexTests {
    /// A unit vector pointing mostly along one axis.
    private func vector(_ axis: Int, _ lean: Int? = nil) -> [Float] {
        var vector = [Float](repeating: 0, count: SemanticIndex.dimensions)
        vector[axis] = 1
        if let lean { vector[lean] = 0.5 }
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return vector.map { $0 / length }
    }

    @Test func findsTheClosestMessagesFirst() {
        var index = SemanticIndex()
        index.add(1, vector: vector(0))
        index.add(2, vector: vector(1))
        index.add(3, vector: vector(0, 1))
        let hits = index.search(vector(0), limit: 2)
        #expect(hits.map(\.id) == [1, 3])
        #expect(abs(hits[0].score - 1) < 0.001)
        // Replacing a vector (an edited message) keeps one entry.
        index.add(2, vector: vector(0))
        #expect(index.count == 3)
        #expect(index.search(vector(0), limit: 1).first.map { [1, 2].contains($0.id) } == true)
    }

    @Test func survivesSavingAndRemovals() throws {
        var index = SemanticIndex()
        for id in 1...5 { index.add(Int64(id), vector: vector(id)) }
        index.newestSeen = 50
        index.oldestSeen = 1
        index.seenCount = 120
        index.isComplete = true
        index.remove([2, 4])
        let restored = try #require(SemanticIndex(serialized: index.serialized()))
        #expect(restored.ids == [1, 3, 5])
        #expect(restored.newestSeen == 50 && restored.oldestSeen == 1 && restored.seenCount == 120 && restored.isComplete)
        #expect(restored.search(vector(3), limit: 1).first?.id == 3)
        #expect(SemanticIndex(serialized: Data("nonsense".utf8)) == nil)
    }

    @Test func fusionFavoursWhatBothSearchesFound() {
        // Words found 10 then 20; meaning found 30 then 20: 20 is in both.
        #expect(RankFusion.fuse([[10, 20], [30, 20]]) == [20, 10, 30])
        #expect(RankFusion.fuse([[], [5, 6]]) == [5, 6])
    }

    @Test func emptyChatterIsLeftToWordSearch() {
        for text in ["ок", "ахахахаха", "хехе", "hahaha", "👍", "да", "кино"] {
            #expect(!SearchText.isMeaningful(text), "\(text)")
        }
        for text in ["встречаемся в кафе на Тверской", "купи молоко", "the meeting moved to Friday", "Достопримечательности"] {
            #expect(SearchText.isMeaningful(text), "\(text)")
        }
    }
}

@MainActor
struct SearchSnippetTests {
    @Test func searchedWordsAreBold() {
        let message = MessageModel(
            id: 1, date: .now, isOutgoing: false,
            sender: .init(id: 2, name: "Anna", accentColorId: 0, photoFileId: nil),
            body: .text(RichText(text: "Встречаемся в КАФЕ на Тверской,\nв кафе у окна")),
            replyToMessageId: nil, reply: nil, forwardedFrom: nil, isEdited: false, status: .sent
        )
        let result = ChatSearch.Result(message: message, matchesWords: true, matchesMeaning: false)
        let snippet = ChatSearchView.snippet(for: result, query: "кафе")
        var bold: [String] = []
        for run in snippet.runs where run.inlinePresentationIntent == .stronglyEmphasized {
            bold.append(String(snippet[run.range].characters))
        }
        #expect(bold == ["КАФЕ", "кафе"])
        #expect(!String(snippet.characters).contains("\n"))
    }
}
