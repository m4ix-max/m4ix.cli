# Product requirements

m4ix.CLI should be a reliable macOS workspace for using Claude and Codex together on real software projects. Success requires runtime evidence as well as passing unit tests.

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
