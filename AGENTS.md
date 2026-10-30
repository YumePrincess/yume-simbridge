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

- Do not add a menu-bar status item. Closing the main window must keep the app and service alive in the Dock; quit must stop the owned runtime before the app exits.

- A fresh Python route-reset process must inspect the actual owned module helper; never use in-memory ready=False to skip cleanup. Email authentication must verify original aligned DKIM signatures rather than trusting Authentication-Results header text.

- Release Apps must be self-contained: bundled Python, pyusb, libusb and CA certificates. Installed runtime code must never depend on the source checkout, Homebrew or a venv on another disk.
- Preserve the persistent local signing identity under Application Support/YumeSimHub/Signing for developer builds. Its private build-only keychain is never opened by the running App or in-app updater; do not add it to the user's keychain search list or trust roots.
- App updates install a user-selected signed ZIP and require a newer Build plus the current certificate requirement. Publish both the first-install DMG and update ZIP with SHA-256 checksums.

- OpenWrt LuCI、路由器运行时、Mac App 与云端共用根目录 `version.json` 的营销版本和 Build，不维护独立版本序列。
