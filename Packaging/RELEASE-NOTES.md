# 0.11.1

m4ix.CLI hosts locally installed Claude and Codex in separate private profiles,
with persistent sessions, project briefs, reviewed handoffs, and Git workspaces.

This update adds a production packaging path with Developer ID signing,
hardened runtime, Apple notarization, stapled tickets, Gatekeeper assessment,
and SHA-256 checksums. Local and CI builds retain ad hoc signing.

Requires macOS 13 or later. Current locally verified binaries target Apple
silicon. Install and authenticate Claude and Codex separately. Neither CLI,
account credentials, licensed fonts, nor optional animation tools are bundled.

Source is available under the MIT license. Production signing remains pending. No public production
artifact has been published. This file is a release draft until those checks
and clean-machine verification are complete.
