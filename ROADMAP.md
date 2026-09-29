# Product requirements

m4ix.CLI should be a reliable macOS workspace for using Claude and Codex together on real software projects. Success requires runtime evidence as well as passing unit tests.

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

The editable handoff and prompt reliability changes are a first implementation. Worktree collaboration, durable task coordination, performance measurements, and packaged runtime verification remain open.
