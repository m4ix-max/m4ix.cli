# Product requirements

m4ix.CLI should be a reliable macOS workspace for using Claude and Codex together on real software projects. Success requires runtime evidence as well as passing unit tests.

## The release in view in chat for 0.18.7 and 0.18.8

The release label lives in the terminal view, which the chat covers. "Show
terminal instead of chat" is not kept across launches, so after the restart
to 0.18.6 the window opened in chat and the version seemed gone. The chat now
shows the same label in the same corner. From 0.18.8 the choice of terminal
or chat is kept in preferences beside side by side, so the app opens as it
was left. Switching provider and ⌘L still return to chat, and that choice is
kept too. The full suite ran 145 tests: four opt-in skips and the known
scrollbar pixel failure.

## Calmer chat text and provider colours for 0.18.6

Sir found the chat too white to read. Running text was ink, #EBEAEA on
#141414 in dark appearance, about 15:1, and a full-width line ran past 120
characters. Chat text now uses a reading tone, #C2C0BD in dark and #3A3838 in
light, about 10:1, while bold and headings keep ink. The session chat's
column is 760 points instead of 900, about 100 characters a line. The shared
discussion keeps its own full-width layout.

Each provider's name and mark in a chat turn take its colour: Claude orange,
#D97757 in dark and #B5532F in light, and Codex teal, #56C2C9 and #0E7480.
The light values are deeper so the 12-point name still reads. Orange and teal
stay apart for every common colour vision, and teal is not taken for a link.
Hermes keeps ink.

The full suite ran 144 tests: four opt-in skips and the known scrollbar pixel
failure, with the two windowed TerminalInteractionTests failing while keys
were typed on the machine and passing when it was idle; their panel takes
keyboard focus.

## Chat text keeps its width for 0.18.5

On 2026-10-12 a Codex chat showed its messages a character or a word to a
line, running over the messages below, while their frames had the right
size. Since 0.18.1 a message measured itself in the container it draws
with, and SwiftUI asks for sizes it never places a view at, down to no width
at all. The last such size stayed in the container, and macOS no longer clips
a view to its frame. Messages now measure on a second layout of the same
text, so the one on screen only follows the frame. The test probes a laid
out conversation at widths of 0, 60 and 2,000 points; before the fix, a view
placed 664 points wide was left laying out at 708.

The full suite ran 143 tests: four opt-in skips and the known scrollbar
pixel failure.

## Paused conversations free their slots for 0.18.4

On 2026-10-12 Codex could not be used in other projects. Four sessions held
the four slots, every further one waited in the queue with its composer
locked, and only the toolbar said "Queued". A session keeps its slot while it
waits for input, so the queue never moved. Codex itself was healthy: its log
showed nothing arriving from the app.

While a launch waits and every slot is taken, the conversation unused longest
is paused. Its CLI stops, and the session returns to the state of one
restored at launch, resuming when it is next shown. Unused time counts
typing, being on screen and turns of four seconds or more; an idle Claude
redraws itself every half hour, so other output does not count. A
conversation is paused only after five unused minutes, off screen, at its own
input line, with no question, approval, queued text or Codex background
terminal, no shell running below its CLI, and a conversation History can
resume. One pauses at a time. A paused session that starts again clears its
old screen first, since that screen's input line would pass for the new CLI
being ready.

The waiting chat names the conversation being paused, or says that all slots
are in use and offers one more. Text typed straight into a CLI's own input
line and left unsent is lost if that conversation is paused: neither CLI's
input line can be read reliably, as both show placeholder text there.

The full suite ran 142 tests: four opt-in skips and the known scrollbar
pixel failure. The pause test fails without the screen reset.

## Agent activity in chat for 0.18.3

Tool calls show between replies. The reader keeps each call as a step with a
build-log title: Claude's own description of a command, the file a read or an
edit touched, a search's pattern, a page's host. Consecutive steps share one
row that summarises them by kind, counting a file once however often it was
read or edited, and opens to one line per step. While a turn runs, the
working line names the latest step. Claude logs a step as it starts; Codex
and Hermes log one when it ends, so for them the line trails by a step.

Before this the chat dropped every tool row, and a long task showed only
"is working" until the reply. Codex steps come from the items it completes,
which name the command and files, rather than from the script its own tool
calls wrap them in. A command Codex could parse becomes one step per part,
and a timer wait is not a step.

On 2026-10-12 the reader ran over real logs: this session's Claude log gave
459 steps in 66 rows, a Codex session 183 in 21 and a Hermes session 67 in
44. The row was rendered open and closed at 800 and 440 points, and a long
step truncates instead of wrapping.
The full suite ran 140 tests: four opt-in skips and the known scrollbar
pixel failure.

## Formatted replies in chat for 0.18.2

Replies show their Markdown structure. Bullets and numbers become hanging
indents, nested items step in under their parent, quotes carry a rule at the
left, and headings are set larger. Lists, quotes and headings stay inside the
reply's text view, so a selection still crosses them. Tables and dividers are
blocks of their own: a table keeps its columns' natural widths when it fits,
and otherwise its narrow columns stay whole while the wide ones share the
rest.

In the two weeks to 2026-10-12, half of Claude's longer replies contained a
bulleted list and a fifth a numbered one, all shown as raw text before.

On 2026-10-12 a reply using every construct was rendered at 800 and 440
points, and a real ten-item reply in dark and light appearance. The full
suite ran 137 tests: four opt-in skips, the known scrollbar pixel failure,
and one intermittent failure in the queued-question draft test, where an
extra character reached the draft; it passed on two of three reruns.

## Who wrote what in chat for 0.18.1

The chat view and Shared chat separate the speakers. Your messages sit in
blocks at the right, sized to their text; replies run full width under the
provider's mark, shown once for consecutive messages from the same speaker.
Message text now starts at its label: the chat text view's line padding was
never removed, because its initializer set it on the nil argument rather
than on the container in use.

On 2026-10-12 the chat layout test checked, at both widths, that your
messages end at the column's right edge and fit their text. Renders in dark
and light appearance were inspected. The full suite matched 0.18.0: 133
tests, four opt-in skips, and the same scrollbar pixel failure.

## Hermes as a third provider for 0.18.0

Hermes Agent joins Claude and Codex as a hosted provider. It runs from its
own home and active profile instead of a private profile, and the app only
reads that home: its session database supplies titles, ordering,
restoration, and the chat view, following a compressed conversation into
its continuation. The launcher starts `hermes chat --cli`, passes the
toolbar's reasoning level, resumes with `--resume`, opens `hermes model` to
log in, and reports `hermes auth status` for the configured provider. A new
conversation takes its ID from the banner Hermes opens with.

The composer sends only at Hermes's bare `❯`. Hermes marks its input in
every other state and numbers approval and confirmation choices inside
panels; either signal blocks sending on its own. While Hermes works, the
message waits in the field. Hermes sends no terminal notifications, so its
questions are read from the screen to mark the session. Side by side stays
Claude and Codex, Shared chat can send a reviewed task to Hermes, and the
narrow toolbar shows provider marks without names.

On 2026-10-12, 133 Swift tests ran with four opt-in tests skipped and one
failure, `TerminalScrollbackTests.testScrollbarDrawsVisibleThumbAtEachReadingPosition`,
a pixel check of the scrollbar marker that fails identically on the
unchanged 0.17.0 source on this Mac and passed in CI. Launcher checks
passed, including Hermes arguments, home, session ID validation, and
account states. The opt-in live test ran the installed Hermes 0.20.0
through the launcher and a hosted terminal, against a local test model in a
throwaway Hermes home, four times: the banner ID was bound, the message was
delivered, the approval was raised and refused by the composer, attention
was marked, the denial was answered, and the conversation reached History
and the chat view. The idle and approval screens in the unit tests were
captured from Hermes 0.20.0. Release packaging and signature checks passed
for 0.18.0 (build 47), installed in ~/Applications. The packaged app has
not been exercised with the user's own Hermes, whose Nous Portal login had
no access token, and the native checks listed for 0.17.0 remain open.

## Reviewed implementation tasks and update repair for 0.17.0

Shared chat now prepares a task for either provider through the existing
editable handoff form. The user writes the implementation task and reviews
the completed discussion before launching a separate conversation in its
project and account profile. Unsent room text and unfinished replies are not
included. Handoff recovery preserves whether the reference is a discussion
or a terminal excerpt, including older saved drafts.

Updates replace the running installation and remove successfully installed
staged copies. Restart disarms completed or outdated pending updates; an
explicit rollback still applies when quitting the session that staged it.
Backups flush cached discussions and include default and named-profile
project/discussion records without copying provider credentials. Local
installation defaults to ~/Applications and retains the previous app.
Packaged apps record the source revision and whether the checkout was dirty.

Regression checks cover signed app swaps, failed installation, rollback
copies, stale update markers, backup coverage, reviewed handoff delivery,
profile changes, and draft preservation. Verification logs and previews are
in `outputs/stabilization-2026-10-05/`. Native authenticated packaged-app
interaction remains a separate runtime check.

## Shared chat for 0.15.0

Claude, Codex, and the user can hold one shared discussion. The host runs
separate provider conversations, forwards only successfully completed replies,
and resumes each provider with the messages it has not yet received. The room
supports a bounded automatic exchange, direct @claude/@codex requests, Stop,
saved discussions, draft recovery, and separate project/account histories.
Closing the room or quitting stops the exchange; restoration never starts it.
This version is for discussion and project inspection, with implementation
remaining in the existing terminal conversations.

On 2026-10-03, the full Swift suite passed 90 tests with three opt-in tests
skipped. The first full-suite attempt reported two failures; its bounded
terminal output omitted the failure details. The complete logged rerun passed,
so the initial cause is unestablished. Launcher checks passed. The dedicated
authenticated shared-chat test completed four real replies, two from each
provider, including both session resumes, in 21.8 seconds. It requested no
tools or file changes and ran through the SwiftPM build.

The shared room was rendered and inspected at 840×760 and 720×620; four layout
tests passed again after the final toolbar and room adjustments. Release
packaging and signature verification passed for 0.15.0 (build 40). The new
package has not been installed or exercised through its shared-chat UI with
authenticated providers. Logs and previews are in
`outputs/shared-chat-verification/`.

## Reliability and performance

- Keep terminal output, typing, resizing, and project switching responsive during long sessions and concurrent agent work.
- Prevent overlapping prompt delivery, preserve per-session drafts, and cancel pending delivery when a process stops.
- Bound account checks and history loading. Keep disk operations off the interface thread.
- Restore the correct conversations after restart and recover clearly from missing tools, unavailable folders, and failed launches.
- Verify idle resource use and sustained output with reproducible measurements.

## Collaboration

- Both providers can work in one project and keep independent conversations.
- Let the user review task and context before handing work to the other provider.
- Support durable project briefs, task ownership, and inspectable handoff history.
- Support isolated Git worktrees for concurrent editing, with explicit review and integration.
- Show both agents' status and results without hiding approvals or confusing a quiet terminal with successful completion.

## Software delivery

- Run Swift, launcher, and release build checks in GitHub CI.
- Separate packaging from installation; produce reproducible versioned artifacts.
- Verify the actual packaged app with both providers, including images, handoffs, restoration, and shutdown.
- Keep app setup and recovery understandable without requiring knowledge of the host implementation.

## Verification for 0.10.4

Shared briefs, owned tasks, editable handoffs with durable history, and isolated Git worktrees are implemented. Task completion and branch integration remain explicit user decisions.

Automated checks cover concurrent hosted processes, project routing, cancellation and draft recovery, bounded commands and history, shared worktree context, restoration, shutdown, and interface layout. Terminal stress tests measure responsiveness under concurrent output.

The packaged release passed real Claude and Codex prompts, cross-provider handoff, conversation restoration, image delivery, and shutdown. A five-second idle sample with both terminals open measured 0.35% CPU and 95 MB resident memory on the development machine; this is a local sample, not a guarantee for every machine or workload. Extended provider checks also passed multiple images and image delivery after resizing.

GitHub CI runs Swift tests, launcher checks, release packaging, and artifact upload. Authenticated provider checks are opt-in local checks because CI has no user credentials.

## External release preparation for 0.11.1

Swift checks passed on 2026-09-30: 42 tests, one opt-in test skipped, zero
failures. Launcher isolation checks passed. The packaged 0.11.1 app passed
real Claude and Codex prompts, images, handoff, durable history, resumption,
and shutdown. Its local idle sample measured 0.96% CPU and 101 MB resident
memory. These measurements do not certify other machines or workloads.

Packaging now supports Developer ID signing, hardened runtime, notarization,
stapling, Gatekeeper checks, and SHA-256 checksums. The local package and
checksum passed verification. The production path has not been exercised:
this Mac currently has no Developer ID Application certificate.

The GitHub repository is public under MIT. Sir selected source distribution
on 2026-09-30 and explicitly excluded paid Apple signing from the current
release. GitHub supplies source archives; local and CI packages use ad hoc
signing. Notarization and clean-machine Gatekeeper verification are future
work if signed app downloads are introduced.

## Scrollback repair for 0.11.2

Historical prompt glyphs could trigger the CLI input cover and black out the
conversation below them. The cover now applies only at the live bottom of
the terminal and lets pointer and scroll events reach the terminal. Live
terminals retain 10,000 lines rather than SwiftTerm's 500-line default.

Six regression tests cover both providers' historical prompts, partial
scrolling, returning to the live input, pointer routing, and long history.
The performance check now uses a hosted terminal with 10,000 lines. A fast
status read uses the live viewport; when scrolled back, menu checks still
read the active screen instead of the historical prompt on screen.

On 2026-09-30, 43 Swift checks ran with one opt-in skip and no failures after
excluding image tests that require macOS services unavailable in the command
sandbox. The full suite confirmed three such image/clipboard cases fail in
this environment. Launcher checks and release packaging passed. Debug
live-screen read latency was 1.53 ms at the 95th percentile. Interactive
scrolling in the packaged update remains to be verified after installation.


## Scrollbar and terminal focus for 0.11.8

The host owns one scrollbar control with matching drawing and hit geometry.
It sits beside the terminal, independent of SwiftTerm's native scroller and
renderer layout. Track clicks, dragging to both ends, wheel scrolling, window
resizing, and accessibility navigation are covered by AppKit event tests.

Live approvals, unnumbered menus, and confirmation prompts bring the terminal
to the latest output and take focus once per question. Returning to the normal
prompt restores message focus. Deferred composer focus requests check the
live terminal state before moving focus, preserving drafts and allowing the
reader to inspect history while the same question remains open.

On 2026-10-01, 63 Swift tests ran with one opt-in provider test skipped and no
failures. Launcher checks passed. Native key-window tests launch inert Claude
and Codex fixtures, deliver arrow-down and Return through the responder chain,
and check the exact bytes received by each PTY. Composite pixel checks verify
the thumb before and after answering, using the same layer-backed containment
as the app. Preview images are in outputs/scroll-focus-verification. These
fixtures exercise host routing; authenticated provider tests were not rerun.


## Scrollbar position visibility for 0.11.9

The scrollbar thumb now uses the app's lime signal color against its ink track
and fills more of the narrow control. Its position maps from the oldest output
at the top to the live end at the bottom.

## Position marker and release label for 0.11.10

A contrasting crossbar identifies the exact viewport position even when the
proportional thumb fills most of the track. A faint release label sits in the
lower right corner of the terminal area.

## Fresh conversation on launch for 0.11.11

Each launch starts one blank conversation in the last-used project with the
last-used provider. Previous conversations remain restored and idle until
selected. Repeated startup callbacks do not create extra conversations, and
an unavailable project folder does not redirect the CLI to another folder.

On 2026-10-02, 65 Swift tests ran with one optional live-provider test skipped
and no failures. Both providers were exercised with inert CLI fixtures, and
the hosted SwiftUI window verified one fresh chat alongside two idle restored
chats. Launcher checks and signed release packaging passed. Authenticated
provider tests were not rerun for this update.

## Production workspace controls for 0.12.0

The workspace tools now combine ten production capabilities: named provider
profiles; a bounded and cancellable session queue; Git change review against
session start snapshots; configurable Swift, launcher, and release checks;
repeatable workflows with explicit agent review and completion gates; durable
text and image draft recovery; handoffs enriched with project notes, open tasks,
Git changes, and recorded checks; provider setup diagnostics; session resource
and lifecycle controls; and staged app updates with a retained rollback copy.
New-session prompts use the terminal input path, so delivery is visible to the
recovery system and task text is not exposed in process arguments.

Checks and Git inspection run away from the UI thread. Command output and
runtime are bounded, cancellation terminates the command process group, and
workflow checks record source fingerprints so a passing result becomes stale
after relevant project files change. Quiet terminals remain a status signal,
not evidence of task completion. Agent review and final workflow decisions
require user action.

The release build completed on 2026-10-02. The Swift test suite was not rerun
for this release; earlier integration work exposed queue-related failures that
were addressed in the launch transition before the release build. Runtime
checks against authenticated providers and the installed packaged app remain
unverified for 0.12.0.

## Dictation for 0.13.0

The composer takes dictation from the microphone, started and finished with
Caps Lock or the microphone button. Recognized words stream into the draft
of the session on screen and are saved with it once they settle; nothing is
sent until Return. Transcription runs on device: SpeechTranscriber where it
covers the language, otherwise the system dictation model. Dictation
finishes when the app deactivates or the conversation changes, and refuses
to start in a build without microphone usage text, which macOS would end.

On 2026-10-02, 77 Swift tests ran with two opt-in tests skipped and no
failures. The opt-in speech test transcribed synthesized speech through the
same feed and recognizer the microphone uses. SpeechTranscriber returned the
sentence exactly, with 24 progressive updates, settling 0.2 to 0.3 seconds
after the audio ended; the system dictation model returned it with two word
errors. No speech-recognition authorization was needed. Microphone capture,
the permission prompt, Caps Lock, and the Swedish model download were not
exercised by automated checks and need a person at the packaged app. The
production signing path now requests the audio-input entitlement; like the
rest of that path it is unexercised without a Developer ID certificate.

## Side by side for 0.14.0

Claude and Codex can share the window, each provider's selected session in
its own pane with its own terminal, composer, draft, dictation target, and
dropped images. The pane with the keyboard drives the toolbar. A pane not in
use brings a new question into view without taking the keyboard, and takes
focus for it when that pane is used. Both visible sessions count as seen for
attention, prompt readiness, and restoration. The layout persists.

On 2026-10-02, 79 Swift tests ran with two opt-in tests skipped and no
failures, including the terminal focus and key routing tests, which use the
same deck. A hosted-session test starts both providers from their own panes
while Claude keeps the keyboard, and each fixture CLI receives only its own
prompt. A rendered SwiftUI window test finds two terminal decks, one per
provider, with automatic focus only in the pane in use, at 1440 by 820 and at
the 960 by 600 minimum. Clicking between panes and answering a real approval
in the pane not in use were not exercised with authenticated providers.
