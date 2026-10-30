Yume SIM Hub 27.2.0 · Build 27026

- 修复 Mac/OpenWrt 切换后旧短信再次推送：使用原始 PDU 的稳定指纹进行云端去重。
- 短信在云端保存并确认 Gotify 投递后，从模块逐条核对并清理；失败和不完整短信保留。
- 空闲时将模块拨出、已接、未接历史保存到云端归档，再核对槽位内容清理；SIM 联系人保留。
- 完善 OpenWrt Python 依赖、云端请求兼容性和服务子进程退出管理。
- Mac、LuCI、路由器运行时和云端统一使用 27.2.0 / Build 27026。

支持 Apple Silicon / macOS 26+。附 DMG、签名更新 ZIP 和 SHA-256 校验文件；OpenWrt 另附 IPK。
