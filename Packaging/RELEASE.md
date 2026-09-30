# External release

Production releases require a Developer ID Application certificate and a
notarytool keychain profile on the packaging Mac. Apple Development and ad hoc
signatures are for local checks only.

1. Choose the source license before making the repository public. Check that
   the interface and any branding are cleared for external distribution.
2. Update `version.env` and release notes. Run `swift test --disable-sandbox`
   and `bash Tests/Launcher/agent-launcher-test.sh`.
3. Export `M4IX_SIGNING_IDENTITY` with the Developer ID Application identity
   and `M4IX_NOTARY_PROFILE` with the name of an existing keychain profile.
   Keep certificate private keys and notarization credentials out of Git.
4. Set `M4IX_OUTPUT_DIR` to a fresh absolute directory such as
   `$PWD/outputs/production` to keep production artifacts separate from local
   packages of the same version. Run `bash Packaging/build-and-package.sh --production`. It signs with
   hardened runtime, submits to Apple, staples the ticket, checks Gatekeeper,
   and creates a ZIP and SHA-256 checksum. Existing artifacts are never replaced.
5. Run `bash Tools/verify-packaged-app.sh "$M4IX_OUTPUT_DIR/m4ix.CLI 0.11.1.app"` against that exact packaged app.
   Both installed providers must be logged in and trust the source folder.
6. Test the downloaded ZIP on a separate Mac with Gatekeeper enabled. Record
   the architecture and OS tested. The package currently targets the build
   machine's architecture; an Apple silicon build does not certify Intel support.
7. Commit the reviewed source and publish it to GitHub. Wait for App checks
   to pass on the release commit. Make the repository public only after the
   source and its history have been reviewed for private material.
8. Create a GitHub release at that exact commit with the production ZIP,
   checksum, tested requirements, and release notes. CI build artifacts are
   ad hoc signed and must not be substituted for the production ZIP.

The animation tools are an optional local integration. They are not included
in this repository or required for Claude and Codex sessions.

Apple's workflow is documented at
https://developer.apple.com/documentation/security/customizing-the-notarization-workflow.
