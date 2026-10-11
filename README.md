# Hushh

A calm macOS client for Telegram: your friends' chats, without stories, channels or noise.
Unofficial client using the Telegram API, built on [TDLib](https://github.com/tdlib/td) through
[TDLibKit](https://github.com/Swiftgram/TDLibKit).

| Chat | Shown? |
|---|---|
| People, Saved Messages | Yes, unless you hide one |
| Groups, channels, bots, Telegram's service chat | Only the ones you pick |
| "X joined Telegram" chats | Not until someone actually writes |

Picked channels are read-only unless you're an admin, and large public ones show Telegram's
sponsored messages below the last post: Telegram's API terms require clients that show channels to
include them.

Calls and secret chats stay on your phone: this Mac's session tells Telegram it can't accept them.

## Set up

1. Install Xcode 26 from the App Store, then run `sudo xcode-select -s /Applications/Xcode.app`.
2. Install XcodeGen: `brew install xcodegen`.
3. Get an API ID and hash at [my.telegram.org](https://my.telegram.org) → API development tools.
   The app title there must not contain the word "Telegram".
4. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and fill it in.
   Adding your Apple ID's Personal Team there stops keychain prompts after each rebuild. With a
   team set, you can also add `ENABLE_HARDENED_RUNTIME = YES`. Without a team it has to stay off:
   the hardened runtime refuses to load the embedded Lottie framework into a "Sign to Run Locally"
   build.
5. Run `xcodegen generate && open Hush.xcodeproj`, then press Run. The scheme is still called Hush; it builds Hushh.app.

## Keyboard

| Keys | Action |
|---|---|
| ⌘K | Switch to a chat by name |
| ⌘1 – ⌘9 | The first nine chats in your list |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next chat |
| ⇧⌘A | Archived chats |
| ⇧⌘G | Choose which groups, channels and bots to show |
| ⌘, | Settings |

In the message box:

| Keys | Action |
|---|---|
| Enter | Send |
| Shift+Enter | New line |
| ↑ | Edit your last message (box empty) |
| Esc | Cancel a reply, edit or recording |

## Drag and drop

- Drag files onto a conversation: drop on the top half to send them as files (original quality),
  on the bottom half to send pictures and videos compressed, shown right in the chat.
- Drop files on a chat in the sidebar to open it with them attached, or hover there a moment to
  switch to it first.
- Drag a photo, video or file out of a chat into Finder or another app for a copy.

## Transcription and search

- **Transcription**: the text button on a voice message or circle asks Telegram to transcribe it,
  as its own apps do; the text appears as Telegram works through it. Telegram does this on its
  servers, with Premium or a few free transcriptions a week.
- **Find in Chat (⌘F)**: Telegram's word search across the whole history, plus search by meaning
  that runs on this Mac (Apple silicon) with
  [multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small) through
  [swift-embeddings](https://github.com/jkrukowski/swift-embeddings). Settings → AI downloads the
  model once (490 MB); messages never leave the Mac. Each chat is indexed in the background the
  first time you search it (newest first, up to 10,000 messages, paced so the Mac stays smooth),
  then kept current. ↑/↓ choose a result, Enter jumps to it.

Search indexes are kept per account under `accounts/<id>/ai/`, encrypted with a key derived from
the database key in the keychain. The model lives in `Application Support/Hush/Models`.

## Develop

- All code lives in `Packages/HushCore`:
  - `HushCore`: the TDLib session, login, and the chat filter (`VisibilityPolicy`).
  - `HushUI`: the SwiftUI views.
  - The Xcode app target only contains `App/HushApp.swift`.
- `project.yml` defines the Xcode project. After editing it, run `xcodegen generate`. `Hush.xcodeproj`, `App/Info.plist` and `App/Hush.entitlements` are generated.
- To build and test without the app, run `cd Packages/HushCore && swift build && swift test`.
  - With only the Command Line Tools installed (no Xcode), `swift test` needs Swift Testing's location:

    ```sh
    F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F
    ```

- `swift run hush-smoke` checks that TDLib loads on this Mac. It needs no credentials.
- `swift scripts/make-icon.swift` (from the repository root) redraws the app icon.
- `HUSH_MODEL_TESTS=1 swift test --filter ModelTests` runs search by meaning with the real model
  (downloads about 490 MB into `~/Library/Caches/HushModelTests` the first time).
- `HUSH_PREVIEW_DIR=/tmp/hushh-preview swift test --filter DesignPreviewTests` draws a made-up
  conversation and sidebar with the real views, in light and dark mode, as PNGs.
- TDLib's log (errors only) is written to `~/Library/Containers/com.macneil.Hush/Data/Library/Application Support/Hush/tdlib/tdlib.log`.

## Updating TDLib

Telegram eventually rejects old TDLib versions: logging in fails with `UPDATE_APP_TO_LOGIN`.
Bump TDLib every couple of months:

1. In `Packages/HushCore/Package.swift`, bump both pins together. TDLibKit's tag looks like `1.5.2-tdlib-1.8.67-42e6a525`, and TDLibFramework's matching tag is `1.8.67-42e6a525`.
2. Run `swift build`.
3. Fix any new `AuthorizationState` cases the compiler reports.

## License

MIT, see [LICENSE](LICENSE). Hushh builds on [TDLib](https://github.com/tdlib/td) (Boost Software
License), [TDLibKit](https://github.com/Swiftgram/TDLibKit) (MIT),
[Lottie](https://github.com/airbnb/lottie-spm) (Apache 2.0) and swift-embeddings (MIT). The search
model it can download, multilingual-e5, is MIT-licensed.
