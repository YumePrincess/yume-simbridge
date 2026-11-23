[English](README.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md)

<p align="center"><img src="MacApp/SimHubLogo.png" alt="Yume SIMBridge 图标" width="180"></p>

# Yume SIMBridge

Yume SIMBridge 将兼容的实体 SIM 模块连接到 Mac 或 OpenWrt 路由器，并通过 Cloudflare Worker 协调客户端，把蜂窝短信和电话接入一套自托管系统。

## 功能

- 原生 macOS 应用，以及适用于 ARM64 OpenWrt 路由器的 LuCI 管理界面。
- 通过 USB 接入兼容的 DJI 和 Quectel 蜂窝模块。
- 短信收件箱与历史记录、Gotify 通知、邮件转短信自动化。
- 通过 Twilio SIP 双向路由电话，支持身份验证和通话历史。
- 加密云端通话录音，并提供播放、下载、保留策略和删除管理。
- 支持英语、法语、日语、简体中文和繁体中文。云端服务语言与客户端显示语言分别设置。

## 系统要求

- **Mac：** Apple Silicon 芯片和 macOS 26 或更新版本。
- **路由器：** ARM64 OpenWrt 与 LuCI，可通过 USB 访问兼容模块，并安装所需音频和 Python 软件包。
- **云服务：** Cloudflare Workers、D1 和 R2 账户；用于 SIP 与电话服务的 Twilio 账户；通知及邮件转短信可选用 Gotify 和 Cloudflare Email Routing。

## 使用 Yume SIMBridge

请使用 GitHub Releases 中的已签名 **DMG** 安装或重新安装 Mac 应用。Release 不附带 Mac 更新 ZIP。应用内更新助手仍接受单独提供的已签名 ZIP，并会校验签名身份和更高的 Build。

从源码构建并安装 Mac 应用：

```sh
git clone https://github.com/YumePrincess/yume-simbridge.git
cd yume-simbridge
scripts/install-mac.sh --install
```

连接 USB 模块并打开 Yume SIMBridge，输入部署时提供的 Worker 地址和客户端令牌。选择模块并启用服务，然后配置电话路由、身份验证、通知和录音选项。应用已内置 Python、PyUSB、libusb 和 CA 证书。

在 OpenWrt 上安装对应版本的 `luci-app-yume-simbridge` IPK，然后在 LuCI 的 **服务 → Yume SIMBridge** 中配置相同的 Worker 连接。升级时，安装程序会迁移原 `yume-simhub` 路由器配置和凭据。

## 部署云端服务

1. 将 GitHub 仓库连接到现有的 **Cloudflare Builds** 集成，构建根目录设为 `Server/`，生产分支设为 `main`。
2. 配置名为 `yume-simbridge` 的 D1 数据库、`yume-oss` R2 存储桶，以及 `yume-gotify` Service Binding。上线接收流量前，通过部署流程应用 `Server/migrations` 中的 SQL 迁移。
3. 设置 Worker 必需的 Secret：`MASTER_KEY`、`EDGE_TOKEN` 和 `RECORDING_KEY`。将它们保存在 Cloudflare Secret Store 中，切勿提交到仓库。
4. 在 `Server/wrangler.jsonc` 中配置部署专用变量，包括 `PUBLIC_ORIGIN`、`TWILIO_ACCOUNT_SID`、`TWILIO_NUMBER` 和 `EMAIL_ADDRESS`。所有示例值都必须替换为你自己服务的值。
5. 按下文配置 Twilio。邮件转短信需要配置 Cloudflare Email Routing，并确保原始邮件通过对齐的 DKIM 验证。需要通知时另行配置 Gotify。
6. 在每个客户端保存 Worker 地址和 `EDGE_TOKEN`。Mac 应用以仅限所有者访问的权限，将凭据和运行数据保存在 `~/Library/Application Support/YumeSimHub`；为兼容已有安装，目录名保留旧名称。

Cloudflare 部署通过 `main` 上现有的 Cloudflare Builds GitHub 集成执行。不要把凭据写入源码或发布包。

### 配置 Twilio

1. 在 Twilio Console 中复制 Account SID 和 Auth Token，并选择支持语音通话的 Twilio 电话号码。在 Worker 配置中设置 `TWILIO_ACCOUNT_SID` 和 `TWILIO_NUMBER`；号码使用 E.164 格式（例如 `+12025550123`）。将 `PUBLIC_ORIGIN` 设为 Worker 公开的 HTTPS 源站，不要包含路径、查询参数或内嵌登录信息。
2. 在本地保存 Auth Token，避免将它写进 shell 历史记录。在仓库根目录运行以下命令并按提示粘贴 token：

   ```sh
   mkdir -p .secrets
   chmod 700 .secrets
   printf 'Twilio Auth Token: '
   read -r -s TWILIO_TOKEN
   printf '\n'
   umask 077
   printf '%s' "$TWILIO_TOKEN" > .secrets/twilio-token
   unset TWILIO_TOKEN
   ```

   保持 `.secrets/` 私有且不要提交到 Git。配置脚本还会将生成的 SIP 密码和 Twilio 资源 ID 保存到 `.secrets/twilio-setup.json`，该文件也应保密。
3. 通过 `main` 上的 Cloudflare Builds 部署 Worker。随后在仓库根目录运行配置脚本，并提供 Account SID、电话号码和公开源站：

   ```sh
   TWILIO_ACCOUNT_SID='<Account SID>' TWILIO_NUMBER='<E.164 电话号码>' PUBLIC_ORIGIN='https://<worker-host>' node Server/scripts/configure-twilio.mjs
   ```

   脚本会创建或复用 SIP 凭据列表，将其映射到 SIP 域名以供呼叫和注册使用，配置 `yume-simbridge.sip.twilio.com`，并将该域名的 Voice URL 指向 `/twilio/cellular`。
4. 确认已部署的 Worker 可以访问后，在同一命令末尾添加 `--activate` 再运行一次。这会将 Twilio 电话号码的 Voice URL 设为 `/twilio/voice`。
5. 在 Mac 应用中打开 **管理模块与接入 → 云端接入 → Twilio / SIP**，填写 Twilio Auth Token、SIP 域名 `yume-simbridge.sip.twilio.com`、用户名 `simhub` 和 `.secrets/twilio-setup.json` 中生成的 SIP 密码，然后保存设置。Auth Token 和 SIP 密码会使用 `MASTER_KEY` 加密后存入 D1。最后打开 **管理电话路由**，启用所需的呼叫方向。

Twilio SIP 域名需要绑定 Credential List，并通过域名 Voice URL 获取通话指令。请参阅 [Twilio SIP](https://www.twilio.com/docs/voice/sip) 和 [Voice webhooks](https://www.twilio.com/docs/usage/webhooks/voice-webhooks)。

## 构建发布文件

在受支持的 Mac 构建环境中准备内置运行时、构建应用，再生成 DMG 和本地更新 ZIP：

```sh
scripts/build-mac.sh
python3 -m pip install -r scripts/requirements-dmg.txt
scripts/build-dmg.sh
```

构建 OpenWrt ARM64 软件包和路由器归档前，先准备固定版本的运行时资源：

```sh
python3.12 scripts/prepare-runtime.py
openwrt/build.sh
```

GitHub Release 会附带 Mac DMG、OpenWrt IPK 和路由器归档及其 SHA-256 校验文件，不附带 Mac 更新 ZIP。请保持 `version.json` 与 `Server/package.json` 中的版本和 Build 一致。

## 版权与许可证

版权所有 © 2026 **Yume internet LLC**。本项目仅以 **GNU General Public License 第 3 版**（`GPL-3.0-only`）授权，详见 [LICENSE](LICENSE)。具有单独许可证声明的组件仍适用其各自条款，请查看 `Mac/` 下相应文件。
