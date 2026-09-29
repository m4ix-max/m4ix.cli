# m4ix.CLI

A small macOS app for Claude and Codex. It hosts each installed command-line tool in a real terminal, with projects, live sessions, and saved conversations in the sidebar. The app does not contain either CLI or any account credentials.

The interface follows the NoA 2.0 Elevate design system: paper or ink surfaces that follow the macOS appearance, a dark terminal, ruled lists, and a lime action for starting work. It uses locally installed NoA 2.0 typefaces when available, with system fallbacks. Licensed font files are not included in the app.

## Build and open

Install the Claude and Codex CLIs separately, then check that `claude` and `codex` resolve in a terminal. Build the app with:

```sh
bash Packaging/build-and-package.sh
```

The source lives in Dropbox. `.build` is a symlink to `~/Library/Caches/m4ix.cli/build`, so SwiftPM's cache of nearly a gigabyte never syncs. On a Mac where that link is missing, recreate it before building: `mkdir -p ~/Library/Caches/m4ix.cli/build && ln -s ~/Library/Caches/m4ix.cli/build .build`.

The script builds `PrivateCLIHost` in release mode and creates `outputs/m4ix.CLI 0.9.2.app` and `outputs/m4ix.CLI 0.9.2.zip` in this folder. It then installs the build as `/Applications/m4ix.CLI.app`, replacing the copy there, so quitting and reopening the app is all an update needs. The swap is safe while the app runs, and the running app carries on with the previous build until it is reopened. Keep that one installed copy only: every build shares the bundle ID `com.maxblomqvist.privateclis`, so a second copy lets macOS open the wrong version. To go back to an earlier build, run `bash Packaging/install.sh "outputs/m4ix.CLI <version>.app"`. The app was called Private CLIs before 0.5.0; the bundle ID and private profiles are unchanged, so logins and history carry over. The bundle is signed locally with an ad hoc signature; it is not notarized for distribution. It includes SwiftTerm's MIT license in `Contents/Resources/Licenses`.

## Use

1. Add a project folder with the **+** button beside **Projects**. The app also discovers projects from conversations in its private profiles. Selecting a project sets the folder for new CLI sessions.
2. Select **Claude** or **Codex** in the toolbar. Open the toolbar menu and choose **Log in** to sign in with your private account. **New conversation** opens a blank, separate session.
3. Type in the **Prompt** bar under the terminal and press **Return** or **Send**. **Shift Return** adds a new line. The text goes to the conversation on screen, as if pasted into the CLI's own prompt, and Return submits it; while the CLI is working, both CLIs queue it. When no CLI is running there, the bar reads **New conversation** and starts one in the selected project and provider.

   The bar sends only when the CLI's input line is on screen. When a menu holds the terminal, such as an approval, a folder-trust question, or Codex's update offer, Return there would choose an option, so the bar reads **Answer the terminal first** and waits. Answer the menu in the terminal itself. The check reads the live screen: Claude's input is the `❯` line between two rules, and Codex's is the last `›` line, which its menus number.

   To add images, drop them on the terminal or the bar, paste them with **⌘V**, or choose them with the image button beside **Send**. A copied image pastes into the bar even while the terminal has focus, and the cursor moves to the bar for the message; copied text still pastes where the cursor is. They wait above the text field as thumbnails; click a thumbnail's **×** to take it out. Each image is copied to `~/Library/Caches/com.maxblomqvist.privateclis/prompt-images` under a plain name, and copies older than 30 days are removed at launch. On send, the bar pastes each copy's path, waits until the CLI shows it as `[Image #n]`, then pastes the text and presses Return. A new conversation started with images opens without a prompt argument and receives the prompt the same way once its input line appears.
4. Select a row under **Live** to return to a session. Live sessions for each project and provider remain active when you switch projects, providers, or conversations. Right-click a live row and choose **Stop session** to end its CLI process; a stopped row can be removed from the live list.

   Each live row says whether its CLI is **Working** or **Ready**. A session you are not looking at is marked **Your turn** with a lime pixel when its turn ends or its CLI asks for you, for example to approve a command. The pixel also appears on its project and provider, and the Dock icon counts the sessions waiting. When the app is in the background it also sends a macOS notification; click it to open that session. Looking at the session clears the mark. Claude's reminder a minute after a turn is skipped once you have seen the session. "Working" is read from the terminal: both CLIs redraw while they work and write nothing while idle. The explicit requests come from terminal notifications, which the launcher turns on for each session: Claude's `preferredNotifChannel` is passed with `--settings`, and Codex's `tui.notifications` with `-c`. Neither profile's files are changed.
5. Select a row under **Saved** to resume a conversation from history. Live conversations are remembered every 30 seconds and on quit. On the next launch they return to the **Live** list marked **Restored**; each one resumes when you select it, so a launch does not start every CLI at once. Stopped sessions are not restored. Search or refresh the conversation list in the sidebar. Stopping a live session or quitting the app leaves its saved conversation available to resume.

The toolbar shows the CLI's account check. Its menu can repeat that check or open the current private profile in Finder. Right-click a project to show it in Finder or remove it from the sidebar. Removing a project from the sidebar leaves its folder and conversations intact. You can hide the sidebar from the toolbar when you want more terminal space.

For reliability checks, the toolbar menu also opens `host-events.jsonl` in Finder. This small local log records app and terminal lifecycle events, exit codes, and timeouts. Once a minute it adds a heartbeat with each running CLI's liveness, seconds since its last output and last keystroke, and the app's memory use. Any moment the interface stops responding for more than two seconds is logged as `main_thread_stall` with its length. Each time a session is marked for attention, `attention_raised` records whether a turn ended or the CLI asked. It never records task text, conversation titles, credentials, or project paths. Keep it if a session fails so the failure can be traced later.

## Account separation

The app sets `CLAUDE_CONFIG_DIR` for Claude and `CODEX_HOME` for Codex. Their private profiles live at:

```text
~/Library/Application Support/Private CLI Host/claude
~/Library/Application Support/Private CLI Host/codex
```

The launcher clears inherited Claude, Anthropic, Codex, and OpenAI environment variables before starting either CLI. This prevents credentials or endpoints from another terminal or desktop app from silently changing the intended login. When available, the launcher links the canonical `~/.claude/CLAUDE.md` or `~/.codex/AGENTS.md` instruction file into the corresponding private profile. It does not link credentials or settings.

The sidebar reads conversation metadata from these private profiles. It does not copy transcripts into a second app database or mix in conversations from the ordinary Claude and Codex desktop profiles. The private profiles separate these CLI logins from the ordinary desktop apps. They are still in your macOS account and can access folders you grant them through normal filesystem permissions. This app provides one private profile per provider, not several accounts within one provider. Quitting the app gives hosted CLIs up to five seconds to stop, then force-stops any that remain; saved conversations remain available to resume on the next launch.

Text that starts a new conversation without images is passed as a command-line argument when the CLI process starts. Other local processes with sufficient access may be able to inspect that argument while the process is running. Avoid putting secrets in the prompt bar when it reads **New conversation**.


## Claude and Codex together

Both providers use the selected project folder and keep separate live conversations. In a running conversation, open the session menu and choose **Hand off to Codex** or **Hand off to Claude**. Describe the next task and review the editable context before starting the other provider. The context begins with the current terminal screen only; add earlier decisions and relevant files yourself. The source conversation stays available.

For sequential work, let one agent finish an implementation and hand it to the other for review. For concurrent work, give each agent separate files or use separate Git worktree folders as projects. The app does not yet create worktrees or merge their changes.

Prompt text and image drafts belong to individual live sessions. Delivery is serialized while images attach, and pending delivery is cancelled when the process stops.

## Development checks

```sh
swift test --disable-sandbox
bash Tests/Launcher/agent-launcher-test.sh
swift build --disable-sandbox -c release
```

GitHub Actions runs the same checks. Product requirements and remaining runtime verification are tracked in ROADMAP.md.
