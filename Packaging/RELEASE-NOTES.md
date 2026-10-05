# m4ix.CLI 0.16.2

Orders sidebar conversations by their latest activity and preserves that order
across restarts. Reading an older conversation keeps its place; sending a new
message moves it to the top.

Codex's queued questions reveal the terminal with an Open questions button.
The answer form stays visible until submitted or cancelled, then returns to
chat with the unsent message draft intact.

# m4ix.CLI 0.16.1

Website URLs and Markdown web links in conversations and Shared chat open in
Safari by default. File and email links use their usual apps; website links
fall back to the system browser when Safari is unavailable.

# m4ix.CLI 0.16.0

Shows normal Claude and Codex conversations in a chat view with selectable
messages, clickable website and Markdown links, and copyable code blocks.
Shared chat uses the same link support. Existing provider transcripts supply
the messages without a second history database.

Terminal controls remain available with the keyboard button or Command Shift T.
Login and approval requests show the terminal automatically; the chat returns
when the request is answered.

# m4ix.CLI 0.15.2

Renames the sidebar's Live section to History and removes the separate Saved
conversation list. Session restoration and provider conversation files are
preserved.

# m4ix.CLI 0.15.0

Adds Shared chat: you, Claude, and Codex in one discussion, with each agent
receiving the other's completed replies. Open it from the speech-bubbles
button or More session actions. Let them take turns with a configurable reply
limit, address @claude or @codex for one reply, and stop at any point. Saved
discussions and drafts are separated by project and account profile.

This first version is for discussion and project inspection. It starts its
own provider conversations; existing terminal chats remain separate. Failed
and interrupted replies stop the relay. Closing a room stops the exchange;
reopening it does not automatically restart it.

# m4ix.CLI 0.14.0

Shows Claude and Codex side by side. Press ⌘\ or click the split button
beside the provider names, and each provider's selected conversation gets
its own terminal, message field, draft, and dictation. The pane in use
carries a rule under its name and drives the toolbar; a question in the
other pane comes into view without taking the keyboard. The layout is
remembered across launches.

# m4ix.CLI 0.13.0

Adds dictation to the message composer, as in Claude Desktop. Press Caps
Lock or click the microphone, speak, and the words appear in the message
field; press either again to finish. Nothing is sent until you press Return.
Speech is transcribed on this Mac by macOS's on-device recognizers, which
need macOS 26, and the audio is not stored. English uses SpeechTranscriber;
Swedish and other languages it does not cover use the system dictation
model, downloaded on first use. Right-click the microphone for the language
and the Caps Lock setting.

# m4ix.CLI 0.12.2

The message composer now stays on when Claude or Codex updates itself. It
previously required one exact version of each CLI, so the Codex 0.160.0 update
returned Codex sessions to the native terminal input. Any version from the
checked one onward now uses the composer; every send still reads the live
screen and waits when it does not recognise it.

# m4ix.CLI 0.12.1

Adds a consistent hover and press response for custom toolbar, sidebar, and
workspace navigation buttons. Tooltips now describe the eight workspace tool
tabs, provider switching, session activity, session rows, and key actions.

# m4ix.CLI 0.12.0

Adds a production workspace control center with named account profiles,
session queue and cancellation controls, Git change review against session
starting points, configurable project checks, gated multi-step workflows,
durable draft and image recovery, provider setup diagnostics, and staged app
updates with rollback copies. Handoffs now include project notes, open tasks,
change summaries, and recorded check results. New-session prompts are sent
through the terminal input so delivery can be tracked and recovered.

The app still opens one blank conversation in the last-used project with the
last-used provider. Earlier conversations remain available as **Restored**.

MIT-licensed macOS workspace for Claude and
Codex. It hosts locally installed CLIs in real terminals with separate private
profiles, persistent sessions, project briefs, reviewed handoffs, image
prompts, and isolated Git workspaces.

## Build and run

Requires macOS 13 or later and a Swift 6.2 or newer toolchain. Install and
authenticate Claude and Codex separately. Clone this repository, then run:

```sh
bash Packaging/build-and-package.sh --install
```

Local builds use ad hoc signing. This release distributes source through
GitHub's source archives; it does not include an Apple-notarized app download.
Apple Developer membership is not required to build from source.

Neither provider CLI, account credentials, licensed fonts, nor optional
animation tools are bundled. SwiftTerm's MIT notice and this project's MIT
notice are included in packaged builds. The current locally verified binary
targets Apple silicon; Intel runtime support has not been verified.

## Verification

On 2026-10-02, the full Swift suite ran 65 tests with one optional live-provider
test skipped and no failures. Launcher isolation checks and signed release
packaging passed.

Startup checks cover Claude and Codex, empty and restored session lists,
remembering the selected provider and project, repeated startup callbacks,
unavailable folders, and shutdown. The actual SwiftUI window is tested with
an inert CLI: one fresh chat starts while both restored chats remain idle.
Authenticated provider tests were not rerun for this update.

Optional Developer ID and notarization tooling remains available for future
distribution, but is not required for this source release.
