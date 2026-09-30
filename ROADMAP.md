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
