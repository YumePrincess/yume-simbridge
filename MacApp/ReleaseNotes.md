Yume SIM Hub 27.2.0 · Build 27007

- 独立运行：App 内置 Python、pyusb、libusb、CA 证书与语音组件；日常运行不再访问源码目录、外置 SSD 或 Homebrew。
- 固定本地签名身份，跨更新保持相同的 designated requirement；切换至该身份后可能需最后授权一次麦克风。
- 向导改为运行环境检查、在线版本检查、私有 GitHub 下载页面及签名 ZIP 安装，不再在用户 Mac 编译源码。
- 修复新进程跳过模块旧语音路由清理的问题；重建真实 D4/UAC 通路，增加无音频内容的双向传输计数。
- 修复合法 iCloud 邮件被误退：不依赖可能缺失的 Cloudflare Authentication-Results，直接验证域名对齐的 DKIM 签名及完整命令内容。
- 移除顶部菜单栏常驻图标；关闭窗口继续运行，Dock 重新打开窗口，退出应用才停止服务。
- 提供 DMG 拖放安装包，支持 Apple Silicon，最低 macOS 26。
- 五语言客户端：简体中文、繁體中文、日本語、English、Français；窗口顶部和“设置…”均可切换，菜单栏实时同步，修复中文与系统语言反复切换。
- 图标与 Yume Life After 使用完全相同的资源，移除启动后的运行时覆盖。
- 模块状态依据实际 USB、AT 响应、音频组件与 SIP 注册；断开后停止运行组件并使旧状态失效，重连后恢复。
- 通话、短信及录音显示来去方向、对方号码与转接目标。
- 电话/Gotify 服务语言与客户端语言分别设置；本地号码与 +国际号码均受支持。
- 更新保留本机凭据，不再读取钥匙串；每次 App 更新递增 Build。
- Worker 与 Mac 项目分目录；Worker 继续通过 Cloudflare Builds 的 GitHub main 连接自动部署。

安装：打开 DMG，将 App 拖入 Applications。无需安装运行依赖或开发工具；分发包不含访问令牌，首次使用需导入客户端凭据。后续更新下载 ZIP 后在 App 内选择安装。需保持 Mac 开机及模块连接。

验证：Worker 的 31 项测试、Go 通话/AT/短信/数据库测试及 Python 新进程路由清理回归测试通过；签名、DMG 校验及安装包机密扫描通过。本机拔插后已恢复 USB、音频与 SIP。用户已实测修复版来电、外呼均双向有声，邮件短信发送成功；银行菜单按键仍需实际业务验收。

本包使用持久本地签名，尚无 Apple Developer ID 公证。签名私钥不包含在安装包中。
