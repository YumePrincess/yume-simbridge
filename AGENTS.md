# Yume SIM Hub maintenance

- Increase `version.json`'s build by one for every app release; synchronize the `Server/package.json` build field and the fallback Go build value. Keep the marketing version unchanged unless the user requests a version change.
- `scripts/build-mac.sh` additionally guarantees that a locally installed update has a higher `CFBundleVersion` than the currently installed app. Preserve that behavior and keep local build metadata out of tracked source files.
- Credentials and mutable runtime files belong under `~/Library/Application Support/YumeSimHub`, with owner-only permissions. App updates must preserve them and must not access Keychain.
- Never write Python bytecode or downloaded runtime files into the signed app bundle. Verify the staged app signature and replace the entire old bundle rather than merging files.
- Worker updates deploy through the existing Cloudflare Builds GitHub connection on `main`; do not add GitHub Actions or preview Workers.
- Client display language and cloud service language are separate settings. The latter controls both telephone prompts and Gotify descriptions. Preserve raw SMS text and original numbers.

- Worker code and its Cloudflare Builds root are under `Server/`. Native UI is `MacApp/`; module runtime is `Mac/`.
- The app is Apple Silicon only and requires macOS 26 or later. Preserve the five native `.lproj` localizations and live menu-bar translation.

- Each App release must include a matching DMG and SHA-256 checksum uploaded to a GitHub Release. Never package local credentials or host-specific bootstrap paths.
- Let macOS load the bundle icon; do not override NSApp.applicationIconImage. Keep menu localization event-driven and idempotent; no polling timers or menu.update() feedback loops.
