import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

@MainActor
struct MessageActionsTests {
    private func message(_ id: Int64, _ text: String, from name: String = "Anna", isOutgoing: Bool = false) -> MessageModel {
        MessageModel(
            id: id, date: .now, isOutgoing: isOutgoing,
            sender: .init(id: isOutgoing ? 1 : 2, name: name, accentColorId: 0, photoFileId: nil),
            body: .text(RichText(text: text)), replyToMessageId: nil, reply: nil,
            forwardedFrom: nil, isEdited: false, status: .sent
        )
    }

    @Test func copyingOneMessageCopiesJustItsText() {
        #expect(ConversationModel.copiedText(of: [message(1, "See you at 8")]) == "See you at 8")
    }

    @Test func copyingSeveralMessagesNamesWhoSaidWhat() {
        let copied = ConversationModel.copiedText(of: [
            message(1, "Are we still on?"),
            message(2, "Yes!", isOutgoing: true),
        ])
        #expect(copied == "Anna: Are we still on?\nYou: Yes!")
    }

    @Test func copyingAVoiceMessageCopiesItsTranscript() {
        let voice = MessageModel(
            id: 3, date: .now, isOutgoing: false,
            sender: .init(id: 2, name: "Anna", accentColorId: 0, photoFileId: nil),
            body: .voiceNote(VoiceNoteMedia(fileId: 1, duration: 4, waveform: [], isListened: true, transcription: .done("Running late")), caption: RichText(text: "")),
            replyToMessageId: nil, reply: nil, forwardedFrom: nil, isEdited: false, status: .sent
        )
        #expect(voice.copyableText == "Running late")
        #expect(ConversationModel.copiedText(of: [message(1, "Where are you?"), voice]) == "Anna: Where are you?\nAnna: Running late")
    }

    @Test func videosWithoutAVideoExtensionAreOpenedAsMP4() {
        #expect(PlayableFile.needsTypeHint(URL(filePath: "/files/videos/mp4")))
        #expect(PlayableFile.needsTypeHint(URL(filePath: "/files/videos/clip.bin")))
        #expect(!PlayableFile.needsTypeHint(URL(filePath: "/files/videos/IMG_6157.MOV")))
        #expect(!PlayableFile.needsTypeHint(URL(filePath: "/files/videos/clip.mp4")))
    }

    @Test func sendingWithoutSoundTurnsOffTheNotification() {
        #expect(ConversationModel.sendOptions(silently: false) == nil)
        #expect(ConversationModel.sendOptions(silently: true)?.disableNotification == true)
    }

    private var defaults: ChatNotificationSettings {
        ChatNotificationSettings(
            disableMentionNotifications: false, disablePinnedMessageNotifications: false, muteFor: 0,
            muteStories: true, showPreview: true, showStoryPoster: false, soundId: 7, storySoundId: 0,
            useDefaultDisableMentionNotifications: true, useDefaultDisablePinnedMessageNotifications: true,
            useDefaultMuteFor: true, useDefaultMuteStories: false, useDefaultShowPreview: true,
            useDefaultShowStoryPoster: true, useDefaultSound: false, useDefaultStorySound: true
        )
    }

    @Test func mutingSetsTheChatsOwnMuteTimeAndKeepsTheRest() {
        let muted = ChatStore.notificationSettings(defaults, mutedFor: 3_600)
        #expect(muted.muteFor == 3_600)
        #expect(!muted.useDefaultMuteFor)
        #expect(muted.soundId == 7)
        #expect(muted.muteStories)
        #expect(!muted.useDefaultSound)
    }

    @Test func mutingForeverIsTelegramsLongestMute() {
        #expect(ChatStore.notificationSettings(defaults, mutedFor: .max).muteFor == Int(Int32.max))
    }

    @Test func unmutingClearsTheMuteTime() {
        let unmuted = ChatStore.notificationSettings(defaults, mutedFor: nil)
        #expect(unmuted.muteFor == 0)
        #expect(!unmuted.useDefaultMuteFor)
    }
}
