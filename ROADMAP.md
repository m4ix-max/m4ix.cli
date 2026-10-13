# Roadmap

m4ix.CLI should be a reliable macOS workspace for using Claude, Codex, and Hermes Agent together on real software projects. Success requires runtime evidence as well as passing unit tests.

What each release changed and how it was checked is in `VERIFICATION.md`;
notes for users are in `Packaging/RELEASE-NOTES.md`.

## Next

Three items at most. One is added only when another leaves.

1. Close the open runtime checks below at the installed app. Strike each as
   it passes, or drop the claim it supports.
2. Publish the current source as a GitHub release. The latest release is
   0.11.1 from 2026-09-30, which predates Shared chat and Hermes.
3. Check each CLI update before relying on it. Claude, Codex, and Hermes
   update every few days, and the app reads their screens and session logs,
   none of which is a documented format. The composer already refuses a
   screen it does not recognise, so a change shows up as a message that
   never sends. Running the captured screens and log readers against each new
   version would find the change first and name it.

## Open runtime checks

Paths used every day, such as sending, reading, scrolling, and history, are
exercised by use and not listed. These are not:

- The packaged-app verifier, `Tools/verify-packaged-app.sh`, with both
  providers logged in. It last produced a report on 2026-09-30, for 0.11.1.
  Its runs on 2026-10-02 and 2026-10-05 ended without one, for reasons not
  established.
- Dictation (0.13.0): the microphone permission prompt, starting and
  finishing with Caps Lock, and the Swedish model download on first use.
- Side by side (0.14.0): clicking between panes, and answering a real
  approval in the pane not in use.
- Shared chat (0.15.0): a discussion through the installed app with both
  providers logged in.
- Hermes (0.18.0): the installed app with the user's own Hermes, whose Nous
  Portal login had no access token when 0.18.0 was checked.

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
