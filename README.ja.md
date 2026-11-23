[English](README.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md)

<p align="center"><img src="MacApp/SimHubLogo.png" alt="Yume SIMBridge ロゴ" width="180"></p>

# Yume SIMBridge

Yume SIMBridge は、対応する物理 SIM モジュールを Mac または OpenWrt ルーターに接続します。Cloudflare Worker がクライアントを連携し、SMS と携帯電話の通話をセルフホスト環境にまとめます。

## 主な機能

- macOS ネイティブアプリと ARM64 OpenWrt ルーター向け LuCI インターフェース。
- DJI および Quectel の対応セルラーモジュールとの USB 接続。
- SMS 受信箱と履歴、Gotify 通知、メールから SMS への自動転送。
- Twilio SIP による双方向通話ルーティング、認証、通話履歴。
- 暗号化されたクラウド通話録音。再生、ダウンロード、保存期間、削除を管理できます。
- 英語、フランス語、日本語、簡体字中国語、繁体字中国語に対応。クラウドサービスの言語はクライアント表示言語とは別に設定できます。

## 動作要件

- **Mac：** Apple Silicon、macOS 26 以降。
- **ルーター：** LuCI を備えた ARM64 OpenWrt、対応モジュールへの USB アクセス、必要なオーディオおよび Python パッケージ。
- **クラウドサービス：** Workers、D1、R2 用の Cloudflare アカウントと、SIP・電話用の Twilio アカウント。通知やメールから SMS への転送には Gotify と Cloudflare Email Routing を追加できます。

## Yume SIMBridge の使用方法

GitHub Releases にある署名済み **DMG** を Mac アプリのインストールまたは再インストールに使用してください。リリースには Mac 更新用 ZIP は含まれません。アプリの更新アシスタントは別途用意された署名済み ZIP を受け取り、署名 ID と新しい Build を検証します。

ソースから Mac アプリをビルドしてインストールする場合：

```sh
git clone https://github.com/YumePrincess/yume-simbridge.git
cd yume-simbridge
scripts/install-mac.sh --install
```

USB モジュールを接続して Yume SIMBridge を開き、デプロイ時に発行した Worker URL とクライアントトークンを入力します。モジュールを選択してサービスを有効にし、通話ルーティング、認証、通知、録音の設定を行います。アプリには Python、PyUSB、libusb、CA 証明書が含まれています。

OpenWrt では該当バージョンの `luci-app-yume-simbridge` IPK をインストールし、LuCI の **サービス → Yume SIMBridge** を開いて同じ Worker 接続を設定します。アップグレード時には、旧 `yume-simhub` ルーター設定と認証情報をインストーラーが引き継ぎます。

## クラウドサービスのデプロイ

1. この GitHub リポジトリを既存の **Cloudflare Builds** 連携に接続します。ビルドルートを `Server/`、本番ブランチを `main` にします。
2. `yume-simbridge` という D1 データベース、`yume-oss` R2 バケット、`yume-gotify` サービスバインディングを構成します。トラフィックを受け付ける前に、デプロイ手順を通じて `Server/migrations` の SQL マイグレーションを適用します。
3. 必須の Worker Secret `MASTER_KEY`、`EDGE_TOKEN`、`RECORDING_KEY` を設定します。Cloudflare の Secret Store に保存し、リポジトリへコミットしないでください。
4. `Server/wrangler.jsonc` に `PUBLIC_ORIGIN`、`TWILIO_ACCOUNT_SID`、`TWILIO_NUMBER`、`EMAIL_ADDRESS` など、デプロイ固有の変数を設定します。サンプル値はすべて自分のサービス用に置き換えてください。
5. 以下の手順で Twilio を設定します。メールから SMS への転送には Cloudflare Email Routing を設定し、元メールの DKIM がアライメント検証を通過するようにします。必要な場合は Gotify も別途設定します。
6. 各クライアントに Worker URL と `EDGE_TOKEN` を保存します。Mac アプリは認証情報と実行時データを `~/Library/Application Support/YumeSimHub` に所有者のみの権限で保存します。旧フォルダー名はアップグレード互換性のため維持しています。

Cloudflare のデプロイは `main` ブランチ上で既存の Cloudflare Builds 連携を通じて行います。ソースファイルや配布パッケージに認証情報を含めないでください。

### Twilio の設定

1. Twilio Console で音声通話に対応した電話番号を選びます。Worker 設定に `TWILIO_ACCOUNT_SID` と `TWILIO_NUMBER` を指定し、`PUBLIC_ORIGIN` を Worker の公開 HTTPS オリジンに設定します。
2. Twilio Auth Token を `.secrets/twilio-token` に保存し、ファイル権限を `0600` にします。`.secrets/` は非公開にし、Git に追加しないでください。
3. Worker をデプロイした後、リポジトリのルートから Account SID、電話番号、公開オリジンを環境変数にしてセットアップスクリプトを実行します。

   ```sh
   TWILIO_ACCOUNT_SID='<Account SID>' TWILIO_NUMBER='<E.164 phone number>' PUBLIC_ORIGIN='https://<worker-host>' node Server/scripts/configure-twilio.mjs
   ```

   スクリプトは SIP Credential List を作成または再利用し、`yume-simbridge.sip.twilio.com` を設定して SIP ドメインの Voice URL を `/twilio/cellular` にします。生成した SIP パスワードとリソース ID は `.secrets/twilio-setup.json` に保存されます。
4. Worker の稼働を確認してから `--activate` を追加し、Twilio 電話番号の Voice URL を `/twilio/voice` に切り替えます。Yume SIMBridge のクラウド設定に Auth Token、SIP ドメイン、ユーザー名 `simhub`、生成された SIP パスワードを入力します。Auth Token は `MASTER_KEY` を使って D1 に暗号化保存されます。

Twilio SIP ドメインには Credential List の割り当てが必要で、ドメインの Voice URL から通話指示を取得します。[Twilio SIP](https://www.twilio.com/docs/voice/sip) と [Voice webhooks](https://www.twilio.com/docs/usage/webhooks/voice-webhooks) を参照してください。

## リリース成果物のビルド

対応する Mac ビルド環境で同梱ランタイムを準備し、アプリをビルドしてから DMG とローカル更新 ZIP を作成します。

```sh
scripts/build-mac.sh
python3 -m pip install -r scripts/requirements-dmg.txt
scripts/build-dmg.sh
```

OpenWrt ARM64 パッケージとルーター用アーカイブを作るには、固定バージョンのランタイム資産を準備してから実行します。

```sh
python3.12 scripts/prepare-runtime.py
openwrt/build.sh
```

GitHub Releases には SHA-256 チェックサム付きの Mac DMG、OpenWrt IPK、ルーター用アーカイブを含め、Mac 更新 ZIP は含めません。`version.json` と `Server/package.json` のバージョンおよび Build 値を同期します。

## 著作権とライセンス

Copyright © 2026 **Yume internet LLC**。本プロジェクトは **GNU General Public License バージョン 3 のみ**（`GPL-3.0-only`）で公開されています。詳細は [LICENSE](LICENSE) を参照してください。個別のライセンス表示があるコンポーネントにはそれぞれの条件が適用されます。`Mac/` 内の該当ファイルを確認してください。
