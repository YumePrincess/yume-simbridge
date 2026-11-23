[English](README.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md)

<p align="center"><img src="MacApp/SimHubLogo.png" alt="Yume SIMBridge logo" width="180"></p>

# Yume SIMBridge

Yume SIMBridge connects a compatible physical SIM module to a Mac or an OpenWrt router. It brings cellular SMS and calls into one self-hosted system, with a Cloudflare Worker coordinating the clients.

## Features

- Native macOS app and LuCI interface for ARM64 OpenWrt routers.
- USB integration for compatible DJI and Quectel cellular modules.
- SMS inbox, history, Gotify notifications, and email-to-SMS automation.
- Two-way call routing through Twilio SIP, with authentication controls and call history.
- Encrypted cloud call recordings with playback, download, retention, and deletion controls.
- English, French, Japanese, Simplified Chinese, and Traditional Chinese interfaces. The cloud service language is configured separately from the client display language.

## Requirements

- **Mac:** Apple Silicon and macOS 26 or later.
- **Router:** ARM64 OpenWrt with LuCI, USB access to a supported module, and the required audio and Python packages.
- **Cloud services:** A Cloudflare account for Workers, D1, and R2; a Twilio account for SIP and telephony; optional Gotify and Cloudflare Email Routing for notifications and email-to-SMS.

## Use Yume SIMBridge

Use the signed **DMG** from GitHub Releases for a first Mac installation or reinstall. Releases include the DMG but not a Mac update ZIP. The app's update assistant accepts a separately supplied signed ZIP and verifies its signing identity and newer build.

To build and install the Mac app from source:

```sh
git clone https://github.com/YumePrincess/yume-simbridge.git
cd yume-simbridge
scripts/install-mac.sh --install
```

Connect the USB module, open Yume SIMBridge, and enter the Worker origin and client token supplied by your deployment. Select the module, enable the service, then configure routing, authentication, notifications, and recording preferences. The app bundles its Python, PyUSB, libusb, and CA certificates.

On OpenWrt, install the matching `luci-app-yume-simbridge` IPK from a release, then open **Services → Yume SIMBridge** in LuCI and configure the same Worker connection. The installer carries forward the previous `yume-simhub` router configuration and credentials when upgrading.

## Deploy the cloud service

1. Connect this GitHub repository to the existing **Cloudflare Builds** integration. Set `Server/` as the build root and `main` as the production branch.
2. Configure the D1 database named `yume-simbridge`, the `yume-oss` R2 bucket, and the `yume-gotify` service binding. Apply the SQL migrations in `Server/migrations` through the deployment process before serving traffic.
3. Add the required Worker secrets: `MASTER_KEY`, `EDGE_TOKEN`, and `RECORDING_KEY`. Keep them in Cloudflare’s secret store; never commit them.
4. Set the deployment-specific variables in `Server/wrangler.jsonc`, including `PUBLIC_ORIGIN`, `TWILIO_ACCOUNT_SID`, `TWILIO_NUMBER`, and `EMAIL_ADDRESS`. Replace every example value with values provisioned for your own services.
5. Configure Twilio as described below. For email-to-SMS, configure Cloudflare Email Routing and ensure incoming messages pass aligned DKIM verification. Configure Gotify separately if notifications are needed.
6. Save the Worker origin and `EDGE_TOKEN` in each client. The Mac app keeps credentials and mutable runtime data under `~/Library/Application Support/YumeSimHub` with owner-only permissions; this legacy directory name is retained for upgrades.

Cloudflare deployments are made by the repository’s Cloudflare Builds connection on `main`. Do not put credentials in source files or release packages.

### Configure Twilio

1. In Twilio Console, select a voice-enabled phone number. Set `TWILIO_ACCOUNT_SID` and `TWILIO_NUMBER` in the Worker configuration, and set `PUBLIC_ORIGIN` to the deployed HTTPS Worker origin.
2. Store the Twilio Auth Token in `.secrets/twilio-token` with file permissions `0600`. Keep `.secrets/` private and out of Git.
3. With the Worker deployed, run the setup script from the repository root, supplying the Account SID, phone number, and public origin in the environment:

   ```sh
   TWILIO_ACCOUNT_SID='<Account SID>' TWILIO_NUMBER='<E.164 phone number>' PUBLIC_ORIGIN='https://<your-worker-host>' node Server/scripts/configure-twilio.mjs
   ```

   The script creates or reuses a Twilio SIP credential list, configures `yume-simbridge.sip.twilio.com`, and points the SIP Domain Voice URL at `/twilio/cellular`. It writes the generated SIP password and resource IDs to `.secrets/twilio-setup.json`.
4. After verifying that the Worker is live, add `--activate` to set the Twilio phone number's Voice URL to `/twilio/voice`. Then enter the Twilio Auth Token, SIP domain, username `simhub`, and generated SIP password in the Yume SIMBridge cloud settings. The Auth Token is encrypted in D1 with `MASTER_KEY`.

Twilio requires a credential list to be mapped to a SIP Domain, and uses the domain Voice URL to request call instructions. See [Twilio SIP](https://www.twilio.com/docs/voice/sip) and [Voice webhooks](https://www.twilio.com/docs/usage/webhooks/voice-webhooks).

## Build release artifacts

On a supported Mac build host, prepare the bundled runtime, build the app, then create the DMG and update ZIP:

```sh
scripts/build-mac.sh
python3 -m pip install -r scripts/requirements-dmg.txt
scripts/build-dmg.sh
```

For the OpenWrt ARM64 package and router archive, prepare the pinned runtime assets and run:

```sh
python3.12 scripts/prepare-runtime.py
openwrt/build.sh
```

GitHub Releases include the Mac DMG, OpenWrt IPK, and router archive with matching SHA-256 checksums; they omit the Mac update ZIP. Keep the shared version and build values synchronized in `version.json` and `Server/package.json`.

## Copyright and license

Copyright © 2026 **Yume internet LLC**. The project is licensed under **GNU General Public License v3.0 only** (`GPL-3.0-only`); see [LICENSE](LICENSE). Components with their own license notices retain those terms; see the relevant files under `Mac/`.
