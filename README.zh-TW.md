[English](README.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md)

<p align="center"><img src="MacApp/SimHubLogo.png" alt="Yume SIMBridge 圖示" width="180"></p>

# Yume SIMBridge

Yume SIMBridge 將相容的實體 SIM 模組連接至 Mac 或 OpenWrt 路由器，並透過 Cloudflare Worker 協調用戶端，將行動網路簡訊與通話整合至一套自架系統。

## 功能

- 原生 macOS App，以及適用於 ARM64 OpenWrt 路由器的 LuCI 管理介面。
- 透過 USB 連接相容的 DJI 與 Quectel 行動通訊模組。
- 簡訊收件匣與歷史紀錄、Gotify 通知、電子郵件轉簡訊自動化。
- 透過 Twilio SIP 雙向路由電話，支援身分驗證與通話歷史紀錄。
- 加密雲端通話錄音，並提供播放、下載、保留期限與刪除管理。
- 支援英文、法文、日文、簡體中文與繁體中文。雲端服務語言與用戶端顯示語言分開設定。

## 系統需求

- **Mac：** Apple Silicon 與 macOS 26 或更新版本。
- **路由器：** ARM64 OpenWrt 與 LuCI，可透過 USB 存取相容模組，並安裝所需的音訊與 Python 套件。
- **雲端服務：** Cloudflare Workers、D1 與 R2 帳戶；用於 SIP 與電話服務的 Twilio 帳戶；通知及電子郵件轉簡訊可選用 Gotify 與 Cloudflare Email Routing。

## 使用 Yume SIMBridge

請使用 GitHub Releases 中已簽署的 **DMG** 安裝或重新安裝 Mac App。Release 不附上 Mac 更新 ZIP。App 內更新助手仍可安裝另外提供的已簽署 ZIP，並驗證簽署身分及較新的 Build。

從原始碼建置並安裝 Mac App：

```sh
git clone https://github.com/YumePrincess/yume-simbridge.git
cd yume-simbridge
scripts/install-mac.sh --install
```

連接 USB 模組並開啟 Yume SIMBridge，輸入部署提供的 Worker 位址與用戶端權杖。選取模組並啟用服務，再設定電話路由、身分驗證、通知與錄音選項。App 已內含 Python、PyUSB、libusb 與 CA 憑證。

在 OpenWrt 上安裝對應版本的 `luci-app-yume-simbridge` IPK，接著在 LuCI 的 **服務 → Yume SIMBridge** 設定相同的 Worker 連線。升級時，安裝程式會遷移原有 `yume-simhub` 路由器設定與憑證。

## 部署雲端服務

1. 將 GitHub 儲存庫連接至既有的 **Cloudflare Builds** 整合，建置根目錄設為 `Server/`，正式分支設為 `main`。
2. 設定名為 `yume-simbridge` 的 D1 資料庫、`yume-oss` R2 儲存桶，以及 `yume-gotify` Service Binding。接收正式流量前，透過部署流程套用 `Server/migrations` 中的 SQL 遷移。
3. 設定 Worker 必要的 Secret：`MASTER_KEY`、`EDGE_TOKEN` 與 `RECORDING_KEY`。將它們存放在 Cloudflare Secret Store，勿提交至儲存庫。
4. 在 `Server/wrangler.jsonc` 設定部署專用變數，包括 `PUBLIC_ORIGIN`、`TWILIO_ACCOUNT_SID`、`TWILIO_NUMBER` 與 `EMAIL_ADDRESS`。所有範例值都必須換成你自己服務的值。
5. 依下文設定 Twilio。電子郵件轉簡訊須設定 Cloudflare Email Routing，並確保原始郵件通過對齊的 DKIM 驗證。有通知需求時另行設定 Gotify。
6. 在每個用戶端儲存 Worker 位址與 `EDGE_TOKEN`。Mac App 以僅限擁有者存取的權限，將憑證與執行資料保存在 `~/Library/Application Support/YumeSimHub`；為相容既有安裝，保留此舊目錄名稱。

Cloudflare 部署透過 `main` 上既有的 Cloudflare Builds GitHub 整合執行。請勿將憑證寫入原始碼或發布套件。

### 設定 Twilio

1. 在 Twilio Console 選擇支援語音通話的電話號碼。在 Worker 設定中指定 `TWILIO_ACCOUNT_SID` 和 `TWILIO_NUMBER`，並將 `PUBLIC_ORIGIN` 設為 Worker 公開的 HTTPS 網址來源。
2. 將 Twilio Auth Token 存入 `.secrets/twilio-token`，並將檔案權限設為 `0600`。保持 `.secrets/` 私有，不要提交至 Git。
3. Worker 部署後，在儲存庫根目錄以環境變數提供 Account SID、電話號碼與公開網址來源，然後執行設定腳本：

   ```sh
   TWILIO_ACCOUNT_SID='<Account SID>' TWILIO_NUMBER='<E.164 電話號碼>' PUBLIC_ORIGIN='https://<worker-host>' node Server/scripts/configure-twilio.mjs
   ```

   腳本會建立或重用 SIP Credential List、設定 `yume-simbridge.sip.twilio.com`，並將 SIP 網域的 Voice URL 指向 `/twilio/cellular`。產生的 SIP 密碼與資源 ID 會存入 `.secrets/twilio-setup.json`。
4. 確認 Worker 已上線後，再加上 `--activate`，將 Twilio 電話號碼的 Voice URL 切換至 `/twilio/voice`。在 Yume SIMBridge 雲端設定中填入 Twilio Auth Token、SIP 網域、使用者 `simhub` 與產生的 SIP 密碼。Auth Token 會使用 `MASTER_KEY` 加密後存入 D1。

Twilio SIP 網域必須映射 Credential List，並透過網域 Voice URL 取得通話指令。請參閱 [Twilio SIP](https://www.twilio.com/docs/voice/sip) 與 [Voice webhooks](https://www.twilio.com/docs/usage/webhooks/voice-webhooks)。

## 建置發布檔案

在受支援的 Mac 建置環境中準備內建執行環境、建置 App，再產生 DMG 與本機更新 ZIP：

```sh
scripts/build-mac.sh
python3 -m pip install -r scripts/requirements-dmg.txt
scripts/build-dmg.sh
```

建置 OpenWrt ARM64 套件與路由器封存檔前，先準備固定版本的執行環境資源：

```sh
python3.12 scripts/prepare-runtime.py
openwrt/build.sh
```

GitHub Release 會附上 Mac DMG、OpenWrt IPK 與路由器封存檔及其 SHA-256 checksum，不附上 Mac 更新 ZIP。請保持 `version.json` 與 `Server/package.json` 中的版本及 Build 一致。

## 著作權與授權

Copyright © 2026 **Yume internet LLC**。本專案僅依 **GNU General Public License 第 3 版**（`GPL-3.0-only`）授權，詳見 [LICENSE](LICENSE)。具有個別授權聲明的元件仍適用其各自條款，請參閱 `Mac/` 下相關檔案。
