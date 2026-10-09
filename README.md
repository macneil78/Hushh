# Hush

A calm macOS client for Telegram: your friends' chats, without stories, channels or noise.
Unofficial client using the Telegram API, built on [TDLib](https://github.com/tdlib/td) through
[TDLibKit](https://github.com/Swiftgram/TDLibKit).

| Chat | Shown? |
|---|---|
| People, Saved Messages | Yes, unless you hide one |
| Groups, bots, Telegram's service chat | Only the ones you pick |
| Channels | Never |
| "X joined Telegram" chats | Not until someone actually writes |

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
5. Run `xcodegen generate && open Hush.xcodeproj`, then press Run.

## Keyboard

| Keys | Action |
|---|---|
| ⌘K | Switch to a chat by name |
| ⌘1 – ⌘9 | The first nine chats in your list |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next chat |
| ⇧⌘A | Archived chats |
| ⇧⌘G | Choose groups & bots |
| ⌘, | Settings |

In the message box:

| Keys | Action |
|---|---|
| Enter | Send |
| Shift+Enter | New line |
| ↑ | Edit your last message (box empty) |
| Esc | Cancel a reply, edit or recording |

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
- TDLib's log (errors only) is written to `~/Library/Containers/com.macneil.Hush/Data/Library/Application Support/Hush/tdlib/tdlib.log`.

## Updating TDLib

Telegram eventually rejects old TDLib versions: logging in fails with `UPDATE_APP_TO_LOGIN`.
Bump TDLib every couple of months:

1. In `Packages/HushCore/Package.swift`, bump both pins together. TDLibKit's tag looks like `1.5.2-tdlib-1.8.67-42e6a525`, and TDLibFramework's matching tag is `1.8.67-42e6a525`.
2. Run `swift build`.
3. Fix any new `AuthorizationState` cases the compiler reports.
