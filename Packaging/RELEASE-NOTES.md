# m4ix.CLI 0.11.1

First public MIT open-source release of the macOS workspace for Claude and
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

Swift checks: 42 tests, one opt-in test skipped, no failures. Launcher isolation
checks and release packaging passed. Local packaged-app checks passed real
Claude and Codex prompts, images, cross-provider handoff, durable history,
resumption, and shutdown.

Optional Developer ID and notarization tooling remains available for future
distribution, but is not required for this source release.
