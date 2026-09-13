# Image Harbor

Native SwiftUI macOS image capture application. Support macOS 13+ on arm64 and x86_64.

- Read README.md and docs/RELEASING.md before changing packaging or updates.
- `release/config.json` is the sole version/dependency source. `./build.sh arm64` and `./build.sh x86_64` build separate native distributions.
- Run `./scripts/test.sh` for behavior changes. `Tests/SystemConfigurationIntegration.swift` needs administrator rights and only targets an isolated preferences file; do not change the developer's live system proxy during unattended tests.
- Preserve write-ahead proxy backups and restore system settings before closing the listener or installing updates.
- Certificate import targets the current user's login keychain explicitly. Trust changes require the user's macOS confirmation. Explain closing the certificate window and completing password confirmation before checking trust.
- Keep the UI native and instructions one step at a time. Do not bring back a special browser or large illustrated tutorial.
- Do not commit generated binaries, captured traffic, user data, keychains, CA private keys, signing keys or credentials. Work under ignored `work/`; artifacts under ignored `dist/`.
- Sparkle update archives must be EdDSA-signed. Never change the public key without a deliberate migration. The private key lives in macOS Keychain and the repository's Actions secret, never in git.
- CI builds/tests both actual architectures. Tag `v<version>` only after main CI passes. Release jobs publish both architectures and appcasts as one completed GitHub release.
- No need to start Unity; this is a native macOS project.
