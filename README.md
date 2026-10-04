# m4ix.CLI

A small macOS app for Claude and Codex. It hosts each installed command-line tool in a real terminal, with projects, live sessions, and saved conversations in the sidebar. The app does not contain either CLI or any account credentials.

Open source under the MIT license. SwiftTerm retains its own MIT license;
both notices are included in packaged apps. Claude and Codex are installed
separately and remain subject to their providers' terms.

The interface follows the NoA 2.0 Elevate design system: paper or ink surfaces that follow the macOS appearance, a dark terminal, ruled lists, and a lime action for starting work. It uses locally installed NoA 2.0 typefaces when available, with system fallbacks. Licensed font files are not included in the app.

## Build and open

Install the Claude and Codex CLIs separately, then check that `claude` and `codex` resolve in a terminal. Build the app with:

```sh
bash Packaging/build-and-package.sh --install
```

The source lives in Dropbox. `.build` is a symlink to `~/Library/Caches/m4ix.cli/build`, so SwiftPM's cache of nearly a gigabyte never syncs. On a Mac where that link is missing, recreate it before building: `mkdir -p ~/Library/Caches/m4ix.cli/build && ln -s ~/Library/Caches/m4ix.cli/build .build`.

The script builds `PrivateCLIHost` in release mode and creates versioned app and ZIP artifacts in `outputs/`. With `--install`, it installs the build as `/Applications/m4ix.CLI.app`. The app was called Private CLIs before 0.5.0; the bundle ID and private profiles are unchanged, so logins and history carry over. The bundle is signed locally with an ad hoc signature; it is not notarized for distribution. It includes SwiftTerm's MIT license in `Contents/Resources/Licenses`.

## Use

Custom toolbar, sidebar, and workspace navigation controls show a subtle hover
and press response. Hover over controls for concise descriptions and keyboard
shortcuts where available.

Opening the app starts one blank conversation in your last-used project with
your last-used provider (Claude on first launch). Previous live conversations
remain in the sidebar as **Restored** and resume when selected.

1. Add a project folder with the **+** button beside **Projects**. The app also discovers projects from conversations in its private profiles. Selecting a project sets the folder for new CLI sessions.
2. Select **Claude** or **Codex** in the toolbar. Open the toolbar menu and choose **Log in** to sign in with your private account. **New conversation** opens a blank, separate session.
3. Type in the message composer below the terminal. **Return** sends; **Shift Return** adds a new line. **⌘L** returns focus to the composer. Attachments and Send sit inside the same field, which grows with new lines. The CLI input and footer are concealed when a recognized prompt is visible, so there is one main input. Menus and approvals reappear in the terminal. Use the keyboard button or **⌘⇧T** for native terminal controls and shortcuts. When a CLI question or approval is open, **Answer in terminal** reveals its controls and places keyboard focus there; your message draft stays intact. **More session actions → Show CLI input and status** keeps the native input visible. The composer needs Claude 2.1.287 or Codex 0.159.3 or newer; an older CLI, or one that does not report its version, uses its own input instead.

   The bar sends only when the CLI's input line is on screen. When a menu holds the terminal, such as an approval, a folder-trust question, or Codex's update offer, Return there would choose an option, so the bar reads **Answer the terminal first** and waits. Answer the menu in the terminal itself. The check reads the live screen: Claude's input is the `❯` line between two rules, and Codex's is the last `›` line, which its menus number.

   To dictate, press **Caps Lock** or click the microphone beside the image button, then speak. The words appear in the message field as they are recognized; press Caps Lock or click the microphone again to finish, then edit and send as usual. Nothing is sent until you press Return. Speech is transcribed on this Mac by macOS's on-device recognizers, which need macOS 26 or later, and the audio is not stored. English uses Apple's SpeechTranscriber model; languages it does not cover, such as Swedish, use the system dictation model, downloaded the first time that language is used. Right-click the microphone to choose among your Mac's preferred languages or to stop Caps Lock from starting dictation. Dictation finishes when the app moves to the background or you switch conversations. macOS asks for microphone access the first time; local builds are ad hoc signed, so it may ask again after each new build.

   To add images, drop them on the terminal or the editor, paste them with **⌘V**, or choose them with the image button beside **Send**. A copied image pastes into the editor even while the terminal has focus, and the cursor moves to the editor for the message; copied text still pastes where the cursor is. They wait above the text field as thumbnails; click a thumbnail's **×** to take it out. Each image is copied to `~/Library/Caches/com.maxblomqvist.privateclis/prompt-images` under a plain name, and copies older than 30 days are removed at launch. On send, the editor pastes each copy's path, waits until the CLI shows it as `[Image #n]`, then pastes the text and presses Return. A new conversation started with images opens without a prompt argument and receives the prompt the same way once its input line appears.
4. Select a row under **Live** to return to a session. Live sessions for each project and provider remain active when you switch projects, providers, or conversations. Right-click a live row and choose **Stop session** to end its CLI process; a stopped row can be removed from the live list.

   Each live terminal retains up to 10,000 lines of scrollback. Its persistent scrollbar uses a high contrast lime thumb to show your current position. It supports dragging, clicking the track, wheel scrolling, and keyboard/accessibility navigation. **Jump to latest** returns to the live output. Approvals, option menus, and confirmation prompts come into view and receive keyboard focus when they appear or when you return to their session. When the normal CLI prompt returns, focus moves back to the message field with its draft intact. A small footer shows the active keyboard destination. Scrolling through earlier output reveals the full terminal viewport; the CLI input is concealed only when you return to the bottom.

   The Live list shows both Claude and Codex sessions for this project. Each row says whether its CLI is **Working** or **Waiting**. Waiting means terminal output is quiet; it does not certify that a task succeeded. A session you are not looking at is marked **Your turn** with a lime pixel when its turn ends or its CLI asks for you, for example to approve a command. The pixel also appears on its project and provider, and the Dock icon counts the sessions waiting. When the app is in the background it also sends a macOS notification; click it to open that session. Looking at the session clears the mark. Claude's reminder a minute after a turn is skipped once you have seen the session. "Working" is read from the terminal: both CLIs redraw while they work and write nothing while idle. The explicit requests come from terminal notifications, which the launcher turns on for each session: Claude's `preferredNotifChannel` is passed with `--settings`, and Codex's `tui.notifications` with `-c`. Neither profile's files are changed.
5. Select a row under **Saved** to resume a conversation from history. Live conversations are remembered every 30 seconds and on quit. On the next launch they return to the **Live** list marked **Restored**, alongside the new blank conversation; each restored conversation resumes when you select it. Stopped sessions are not restored. Search or refresh the conversation list in the sidebar. Stopping a live session or quitting the app leaves its saved conversation available to resume.

The toolbar shows the project, conversation title, provider, a model menu, and a compact **Activity** control.

The model menu sets the model and reasoning effort for the selected provider's new and resumed conversations. Its label names what the next conversation will run; **Profile default** leaves the choice to the private profile's own settings. Claude offers its Fable, Opus, Sonnet, and Haiku aliases with low to max effort. Codex lists the models in its profile's model cache, each with the effort levels it supports. The choice is passed as launch flags for that session only: Claude's `/model` and `/effort` commands would save it as the profile's default, so the app does not use them, and neither profile's files are changed. A running conversation keeps the model it started with; the menu shows that model when it differs. Activity holds the account check and Codex background process count; **View terminals** opens Codex's native process manager. The animation-tools menu opens the **Motion library** or **Annotator** in Chrome, reusing their server on port 8705 or starting it when needed. Servers started by the app stop when it quits; servers already running are left alone.

The toolbar's Activity menu shows the CLI's account check. Its menu can repeat that check or open the current private profile in Finder. Right-click a project to show it in Finder or remove it from the sidebar. Removing a project from the sidebar leaves its folder and conversations intact. You can hide the sidebar from the toolbar when you want more terminal space.

For reliability checks, the toolbar menu also opens `host-events.jsonl` in Finder. This small local log records app and terminal lifecycle events, exit codes, and timeouts. Once a minute it adds a heartbeat with each running CLI's liveness, seconds since its last output and last keystroke, and the app's memory use. Any moment the interface stops responding for more than two seconds is logged as `main_thread_stall` with its length. Each time a session is marked for attention, `attention_raised` records whether a turn ended or the CLI asked. It never records task text, conversation titles, credentials, or project paths. Keep it if a session fails so the failure can be traced later.

## Account separation

The app sets `CLAUDE_CONFIG_DIR` for Claude and `CODEX_HOME` for Codex. Their private profiles live at:

```text
~/Library/Application Support/Private CLI Host/claude
~/Library/Application Support/Private CLI Host/codex
```

The launcher clears inherited Claude, Anthropic, Codex, and OpenAI environment variables before starting either CLI. This prevents credentials or endpoints from another terminal or desktop app from silently changing the intended login. When available, the launcher links the canonical `~/.claude/CLAUDE.md` or `~/.codex/AGENTS.md` instruction file into the corresponding private profile. It does not link credentials or settings.

The sidebar reads conversation metadata from these private profiles. It does not copy transcripts into a second app database or mix in conversations from the ordinary Claude and Codex desktop profiles. The private profiles separate these CLI logins from the ordinary desktop apps. They are still in your macOS account and can access folders you grant them through normal filesystem permissions. This app provides one private profile per provider, not several accounts within one provider. Quitting the app gives hosted CLIs up to five seconds to stop, then force-stops any that remain; saved conversations remain available to resume on the next launch.

New conversation prompts are delivered through the terminal after its input becomes ready. The app records uncertain delivery and offers draft recovery rather than silently discarding an interrupted message.


## Claude and Codex together

The speech-bubbles button in the toolbar, or **More session actions → Shared
chat with Claude and Codex**, opens **Shared chat**, a conversation
with you, Claude, and Codex. Both agents receive the messages in the room and
take turns replying. **Let them discuss** defaults to six replies per exchange;
choose a different limit or turn it off for one reply from each. **Stop** (⌘.)
interrupts the current reply and stops the relay. An unfinished or failed reply
is never passed to the other agent.

Use **To → Claude/Codex**, or start a message with **@claude** or **@codex**, to
request just one reply. Send with **⌘Return**. After an exchange, add your own
message or choose **Continue discussion**. **Discussions** lets you start a new
room or reopen an earlier one. Closing the room stops its exchange; reopening
it restores the discussion and draft without starting the agents.

Shared chat starts its own Claude and Codex conversations using the selected
private account profile and toolbar model choices. It is intended for discussion
and project inspection: Claude has file-reading tools, and Codex runs with a
read-only filesystem sandbox and no interactive approvals. Take implementation
work to a normal terminal conversation. The shared transcript and delivery
positions are saved under `shared-chats/` in that account profile. Existing
terminal conversations are not imported into the room.

The relay reads structured CLI output and requires an explicit successful
completion before forwarding a reply. It does not infer completion from a
quiet terminal. The integrations follow the providers' documented
[Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
and [Claude programmatic mode](https://code.claude.com/docs/en/headless).

To work with both at once, click the split button beside the provider names or press **⌘\\**. Claude's selected conversation sits on the left and Codex's on the right, each with its own terminal, message field, draft, and dictation. The pane you are using carries a rule under its name, and the toolbar's model menu, activity, and **New conversation** act on it. Click inside the other pane, or its name in either place, to move there. A question or approval in the pane you are not using comes into view without taking the keyboard, and takes it when you move to that pane. Selecting a live conversation in the sidebar opens it in its provider's pane. The layout is remembered across launches; at the minimum window size, hide the sidebar for wider terminals.

Both providers use the selected project folder and keep separate live conversations. In a running conversation, open the session menu and choose **Hand off to Codex** or **Hand off to Claude**. Describe the next task and review the editable context before starting the other provider. The context begins with the current terminal screen only; add earlier decisions and relevant files yourself. The source conversation stays available.

For sequential work, let one agent finish an implementation and hand it to the other for review. For concurrent work, open **Project tools** in the toolbar and choose **Git workspaces**. Create one branch and workspace per agent. A new workspace starts at the current commit, leaving uncommitted changes in the source folder. The app adds the new folder to Projects. Briefs, tasks, and handoff history are shared across all worktrees of the repository. Review and integrate completed branches with Git in the terminal; the app never merges or deletes worktrees automatically.

Open **Project tools** for the production control center. It includes Git change review against session starting points, configurable Swift/launcher/release checks, workflows with explicit review and completion gates, recovered drafts and attachments, session queue controls, named account profiles, setup diagnostics, and staged updates with retained rollback copies. Handoffs include the shared brief, open tasks, current change summary, and recorded check results. Status changes and task completion remain explicit user decisions. Project records live in the private app data directory under `projects/`, with one record shared by the repository and its worktrees.


Prompt text and image drafts belong to individual live sessions. Delivery is serialized while images attach, and pending delivery is cancelled when the process stops. If delivery is interrupted, **Restore draft** recovers the text and images; check the terminal before sending again.

## Development checks

```sh
swift test --disable-sandbox
bash Tests/Launcher/agent-launcher-test.sh
swift build --disable-sandbox -c release
```

Test runs keep their data and event log in a temporary folder and never write into the private profiles. The opt-in live tests below use the private profiles' existing logins explicitly.

GitHub Actions runs the Swift and launcher checks, packages a signed app without installing it, and retains the ZIP as a build artifact. Requirements and verification evidence are tracked in ROADMAP.md.

To exercise a packaged build with your authenticated private accounts:

```sh
bash Packaging/build-and-package.sh
bash Tools/verify-packaged-app.sh
```

The verification opens a temporary app session, uses a separate UI preferences suite, and sends benign prompts. It checks a real Claude-to-Codex handoff, durable history, conversation resumption, image delivery, shutdown, and idle CPU/memory. Its report is saved under `outputs/packaged-runtime.*`. It leaves the installed app and its saved sidebar/session preferences intact. Both CLIs must already be authenticated and trust this source folder; the verifier never answers startup or approval menus.

`M4IX_SPEECH_TESTS=1 swift test --disable-sandbox --filter DictationTests` transcribes synthesized speech through the dictation recognizer with both on-device models. It needs macOS 26 and the English speech assets, and never opens the microphone.

`M4IX_REAL_CLI_TESTS=1 swift test --disable-sandbox --filter RealCLISmokeTests` also verifies live providers through the SwiftPM build. These tests are skipped in CI, which uses inert CLI fixtures for terminal lifecycle and prompt delivery checks.

`M4IX_SHARED_CHAT_LIVE_TESTS=1 swift test --disable-sandbox --filter SharedChatTests/testAuthenticatedProvidersExchangeAndResumeReplies`
checks four real shared-chat replies, including resuming both providers. It
uses the private profiles' existing logins and requests no file changes or tools.

Release version and build number live in `Packaging/version.env`. Packaging without `--install` leaves the installed app alone, so a build can be verified before installation.

## External distribution

The public release distributes MIT-licensed source. Build locally with the
command above; Apple Developer membership is not required. Local builds are
ad hoc signed. There is no Apple-notarized app download in this release.

Optional future notarized distribution:


Production packaging uses `bash Packaging/build-and-package.sh --production`
with a Developer ID Application identity and a notarization keychain profile.
It verifies Gatekeeper acceptance and produces a SHA-256 checksum alongside the
ZIP. See `Packaging/RELEASE.md` for the release procedure and required checks.
Ordinary local and CI packages use ad hoc signatures and are not notarized.
