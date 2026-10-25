import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct Settings: Codable {
  var serviceLanguage: String? = "en"
  var forwardTo = "+12025550123"
  var gotifyUrl = "https://gotify.example.com"
  var allowedSenders = ["sender@example.com"]
  var sipDomain = "yume-simhub.sip.twilio.com"
  var sipUser = "simhub"
  var inboundEnabled = false
  var outboundEnabled = false
  var emailEnabled = true
  var gotifyConfigured = false
  var pinConfigured = false
  var twilioConfigured = false
  var sipConfigured = false
}
struct Edge: Codable {
  var online: Bool?
  var modemConnected: Bool?
  var updated: Double?
  var sim: String?
  var registration: String?
  var `operator`: String?
  var voiceReady: Bool?
  var sipRegistered: Bool?
  var busy: Bool?
  var lastSeen: Double?
}
struct Record: Codable, Identifiable {
  var id: String
  var kind: String
  var payload: String
  var created: Double
  var status: String?
  var result: String?
  var notified: Int?
  var attempts: Int?
  var data: [String: String] {
    (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: String] ?? [:]
  }
}
struct Snapshot: Codable {
  var settings: Settings
  var edge: Edge
  var jobs: [Record]
  var events: [Record]
}
struct RecordingInfo: Codable, Identifiable {
  var direction: String?
  var peer: String?
  var target: String?
  var sid: String
  var call: String
  var duration: Double
  var created: Double
  var size: Int
  var status: String
  var attempts: Int
  var twilioDeleted: Bool
  var id: String { sid }
}
struct Bootstrap: Codable {
  var origin: String
  var token: String
}
@MainActor final class Model: ObservableObject {
  private var healthTimer: Timer?
  @Published var language = ClientLanguage.current() {
    didSet {
      UserDefaults.standard.set(language, forKey: "clientLanguage")
      UserDefaults.standard.set([language], forKey: "AppleLanguages")
      MenuLocalization.apply(language: language)
    }
  }
  @Published var showSetup = false
  @Published var setupBusy = false
  @Published var setupLog = ""
  @Published var needsRelaunch = false
  private var setupProcess: Process?
  private var setupTimer: Timer?
  @Published var recordings: [RecordingInfo] = []
  @Published var playing: String?
  private var player: AVPlayer?
  private var playbackFile: URL?
  @Published var settings = Settings()
  @Published var edge = Edge()
  @Published var messages: [Record] = []
  @Published var jobs: [Record] = []
  @Published var running = false
  @Published var notice = ""
  @Published var pin = ""
  @Published var gotifyToken = ""
  @Published var twilioToken = ""
  @Published var sipPassword = ""
  @Published var senderText = "sender@example.com"
  @Published var accessToken = ""
  @Published var saving = false
  @Published var log = ""
  @Published var loginItem = false
  private var loaded = false
  private var process: Process?
  private var shouldRun = false
  private var timer: Timer?
  private let base = "https://worker.example.com"
  private var token = ""
  private var activity: NSObjectProtocol?
  private let folder = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
      "YumeSimHub", isDirectory: true)
  init() {
    for path in [
      folder.appendingPathComponent("credentials.json"), folder.appendingPathComponent("edge.json"),
    ] {
      if let boot = try? CredentialStore.read(path) {
        token = boot.token
        break
      }
    }
    if token.isEmpty,
      let resource = Bundle.main.resourceURL?.appendingPathComponent("installation.json"),
      let data = try? Data(contentsOf: resource),
      let install = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      let path = install["bootstrap"],
      let boot = try? CredentialStore.read(URL(fileURLWithPath: path))
    {
      token = boot.token
    }
    if !token.isEmpty
      && !FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("credentials.json").path)
    {
      do { try CredentialStore.save(Bootstrap(origin: base, token: token), folder: folder) } catch {
        notice = error.localizedDescription
      }
    }
    showSetup = !UserDefaults.standard.bool(forKey: "setupCompleted")
    loginItem = SMAppService.mainApp.status == .enabled
    healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshLocalHealth() }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.refresh() }
    }
    Task {
      await refresh()
      if UserDefaults.standard.bool(forKey: "autoRun") && !token.isEmpty { start() }
    }
  }
  var versionLabel: String {
    let info = Bundle.main.infoDictionary ?? [:]
    return
      "\(info["CFBundleShortVersionString"] as? String ?? "27.2.0") · Build \(info["CFBundleVersion"] as? String ?? "27003")"
  }
  func setup(_ mode: String) async {
    guard !setupBusy else { return }
    setupBusy = true
    defer {
      setupBusy = false
      setupTimer?.invalidate()
      setupTimer = nil
    }
    let wasRunning = running
    if ["--install", "--update"].contains(mode) {
      stop(persist: false)
      for _ in 0..<60 {
        if !running { break }
        try? await Task.sleep(for: .milliseconds(250))
      }
      guard !running else {
        setupLog = L("模块服务仍在退出，请稍后重试")
        return
      }
    }
    do {
      guard let r = Bundle.main.resourceURL,
        let install = try JSONSerialization.jsonObject(
          with: Data(contentsOf: r.appendingPathComponent("installation.json")))
          as? [String: String], let root = install["sourceRoot"]
      else {
        throw NSError(
          domain: "SimHub", code: 7,
          userInfo: [NSLocalizedDescriptionKey: L("找不到项目路径，请从源项目重新构建客户端")])
      }
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let logURL = folder.appendingPathComponent("setup.log")
      try Data().write(to: logURL)
      let out = try FileHandle(forWritingTo: logURL)
      defer { try? out.close() }
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/bin/bash")
      p.arguments = [
        URL(fileURLWithPath: root).appendingPathComponent("scripts/install-mac.sh").path, mode,
      ]
      p.currentDirectoryURL = URL(fileURLWithPath: root)
      p.standardOutput = out
      p.standardError = out
      p.environment = ProcessInfo.processInfo.environment.merging([
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "PYTHONDONTWRITEBYTECODE": "1",
      ]) { _, new in new }
      setupProcess = p
      setupTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        Task { @MainActor in
          if let d = try? Data(contentsOf: logURL) {
            self?.setupLog = String(decoding: d.suffix(25000), as: UTF8.self)
          }
        }
      }
      let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        p.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
        do { try p.run() } catch { continuation.resume(throwing: error) }
      }
      setupProcess = nil
      if let d = try? Data(contentsOf: logURL) {
        setupLog = String(decoding: d.suffix(25000), as: UTF8.self)
      }
      if status == 0 {
        if mode == "--check" || mode == "--install" || mode == "--update" {
          UserDefaults.standard.set(true, forKey: "setupCompleted")
        }
        if ["--install", "--update"].contains(mode) {
          needsRelaunch = true
          UserDefaults.standard.set(wasRunning, forKey: "autoRun")
        }
      } else {
        setupLog +=
          "\n" + L("操作未完成（退出码 %@），可根据日志修复后重试。").replacingOccurrences(of: "%@", with: String(status))
      }
    } catch { setupLog = error.localizedDescription }
  }
  func relaunch() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [
      "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
      "simhub-relaunch", String(ProcessInfo.processInfo.processIdentifier),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Applications/Yume SIM Hub.app"
      ).path,
    ]
    try? p.run()
    NSApp.terminate(nil)
  }
  func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws
    -> Data
  {
    guard !token.isEmpty else {
      throw NSError(
        domain: "SimHub", code: 1, userInfo: [NSLocalizedDescriptionKey: L("请先在接入配置中保存客户端凭据")])
    }
    var req = URLRequest(url: URL(string: base + path)!)
    req.httpMethod = method
    req.timeoutInterval = 20
    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if let body {
      req.httpBody = try JSONSerialization.data(withJSONObject: body)
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, res) = try await URLSession.shared.data(for: req)
    guard let http = res as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let e = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
      throw NSError(
        domain: "SimHub", code: 2, userInfo: [NSLocalizedDescriptionKey: e?["error"] ?? L("云端请求失败")]
      )
    }
    return data
  }
  func refreshLocalHealth() {
    let url = folder.appendingPathComponent("runtime/edge-health.json")
    let local = (try? Data(contentsOf: url)).flatMap {
      try? JSONDecoder().decode(Edge.self, from: $0)
    }
    let age = Date().timeIntervalSince1970 * 1000 - (local?.updated ?? 0)
    let connected =
      running && HardwareHealth.modulePresent() && age >= 0 && age < 12000
      && local?.modemConnected == true
    edge.online = connected
    edge.voiceReady = connected && local?.voiceReady == true
    edge.sipRegistered = connected && local?.sipRegistered == true
    edge.busy = connected ? local?.busy : nil
  }
  func refresh() async {
    do {
      let s = try JSONDecoder().decode(Snapshot.self, from: await request("/edge/state"))
      if !loaded {
        settings = s.settings
        senderText = s.settings.allowedSenders.joined(separator: "\n")
        loaded = true
      }
      edge = s.edge
      refreshLocalHealth()
      messages = s.events
      jobs = s.jobs
      recordings = try JSONDecoder().decode(
        [RecordingInfo].self, from: await request("/edge/recordings"))
      readLog()
    } catch { if !loaded { notice = error.localizedDescription } }
  }
  func save() async {
    saving = true
    defer { saving = false }
    do {
      var v =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
      v["allowedSenders"] = senderText.components(separatedBy: CharacterSet(charactersIn: "\n,"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      v["pin"] = pin
      v["gotifyToken"] = gotifyToken
      v["twilioToken"] = twilioToken
      v["sipPassword"] = sipPassword
      settings = try JSONDecoder().decode(
        Settings.self, from: await request("/edge/settings", method: "PUT", body: v))
      pin = ""
      gotifyToken = ""
      twilioToken = ""
      sipPassword = ""
      notice = L("配置已保存")
      await refresh()
    } catch { notice = error.localizedDescription }
  }
  func importToken() {
    do {
      let t = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
      guard t.count >= 32 else {
        throw NSError(
          domain: "SimHub", code: 3, userInfo: [NSLocalizedDescriptionKey: L("客户端凭据格式不正确")])
      }
      try CredentialStore.save(Bootstrap(origin: base, token: t), folder: folder)
      token = t
      accessToken = ""
      loaded = false
      Task { await refresh() }
      notice = L("客户端凭据已保存到本机受限配置")
    } catch { notice = error.localizedDescription }
  }
  func setLoginItem(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      loginItem = enabled
    } catch { notice = error.localizedDescription }
  }
  func start() {
    guard process == nil else { return }
    shouldRun = true
    do {
      guard let resources = Bundle.main.resourceURL,
        let install = try JSONSerialization.jsonObject(
          with: Data(contentsOf: resources.appendingPathComponent("installation.json")))
          as? [String: String], let python = install["python"]
      else {
        throw NSError(
          domain: "SimHub", code: 4, userInfo: [NSLocalizedDescriptionKey: L("运行时安装配置缺失")])
      }
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let cfg = folder.appendingPathComponent("edge.json")
      try JSONEncoder().encode(Bootstrap(origin: base, token: token)).write(
        to: cfg, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cfg.path)
      let logURL = folder.appendingPathComponent("runtime.log")
      if let a = try? FileManager.default.attributesOfItem(atPath: logURL.path),
        let size = a[.size] as? Int, size > 2_000_000
      {
        try? FileManager.default.removeItem(at: logURL)
      }
      if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(
          atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      let logFile = try FileHandle(forWritingTo: logURL)
      try logFile.seekToEnd()
      let p = Process()
      p.executableURL = URL(fileURLWithPath: python)
      p.arguments = [
        "-u", resources.appendingPathComponent("Mac/supervisor.py").path, "--config", cfg.path,
        "--data", folder.appendingPathComponent("runtime").path,
      ]
      p.environment = ProcessInfo.processInfo.environment.merging([
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "PYTHONDONTWRITEBYTECODE": "1",
      ]) { _, new in new }
      p.standardOutput = logFile
      p.standardError = logFile
      p.terminationHandler = { [weak self] _ in
        Task { @MainActor in
          self?.running = false
          self?.process = nil
          self?.releaseActivity()
          if self?.shouldRun == true {
            try? await Task.sleep(for: .seconds(3))
            if self?.shouldRun == true { self?.start() }
          }
        }
      }
      try p.run()
      process = p
      running = true
      UserDefaults.standard.set(true, forKey: "autoRun")
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
        reason: "SIM gateway requires USB and SIP connectivity")
      notice = L("Mac 服务已启动，正在连接模块与 SIP")
    } catch { notice = error.localizedDescription }
  }
  func releaseActivity() {
    if let activity {
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }
  }
  func stop(persist: Bool = true) {
    shouldRun = false
    if persist { UserDefaults.standard.set(false, forKey: "autoRun") }
    process?.terminate()
    notice = L("正在停止服务与通话")
  }
  func readLog() {
    if let data = try? Data(contentsOf: folder.appendingPathComponent("runtime.log")) {
      log = String(decoding: data.suffix(18000), as: UTF8.self)
    }
  }
  func recordingFile(_ r: RecordingInfo) async throws -> URL {
    var req = URLRequest(url: URL(string: base + "/edge/recordings/" + r.sid + "/audio?download")!)
    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 300
    let (url, response) = try await URLSession.shared.download(for: req)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
      throw NSError(
        domain: "SimHub", code: 5, userInfo: [NSLocalizedDescriptionKey: L("录音尚未归档或下载失败")])
    }
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".mp3")
    try FileManager.default.moveItem(at: url, to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    return target
  }
  func stopPlayback() {
    player?.pause()
    player = nil
    playing = nil
    if let playbackFile {
      try? FileManager.default.removeItem(at: playbackFile)
      self.playbackFile = nil
    }
  }
  func play(_ r: RecordingInfo) async {
    if playing == r.sid {
      stopPlayback()
      return
    }
    stopPlayback()
    do {
      let url = try await recordingFile(r)
      playbackFile = url
      player = AVPlayer(url: url)
      playing = r.sid
      player?.play()
    } catch { notice = error.localizedDescription }
  }
  func download(_ r: RecordingInfo) async {
    let panel = NSSavePanel()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let peer = (r.peer ?? "unknown").filter { "+0123456789".contains($0) }
    panel.nameFieldStringValue =
      L(r.direction == "outbound" ? "去电" : "来电") + "-" + (peer.isEmpty ? "unknown" : peer) + "-"
      + formatter.string(from: Date(timeIntervalSince1970: r.created / 1000)) + ".mp3"
    panel.allowedContentTypes = [.mp3]
    guard panel.runModal() == .OK, let target = panel.url else { return }
    do {
      let url = try await recordingFile(r)
      defer { try? FileManager.default.removeItem(at: url) }
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.copyItem(at: url, to: target)
      notice = L("录音已下载")
    } catch { notice = error.localizedDescription }
  }
  func deleteRecording(_ r: RecordingInfo) async {
    let alert = NSAlert()
    alert.messageText = L("删除这段录音？")
    alert.informativeText = L("将删除云端归档及仍存在的 Twilio 副本，无法恢复。")
    alert.addButton(withTitle: L("删除"))
    alert.addButton(withTitle: L("取消"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      _ = try await request("/edge/recordings/" + r.sid, method: "DELETE")
      notice = L("录音已加入删除队列")
      await refresh()
    } catch { notice = error.localizedDescription }
  }
  func retryRecording(_ r: RecordingInfo) async {
    do {
      _ = try await request("/edge/recordings/" + r.sid + "/retry", method: "POST", body: [:])
      notice = L("已安排录音重试")
    } catch { notice = error.localizedDescription }
  }
  func olderRecordings() async {
    guard let last = recordings.last else { return }
    do {
      let more = try JSONDecoder().decode(
        [RecordingInfo].self,
        from: await request("/edge/recordings?before=" + String(Int(last.created))))
      recordings.append(contentsOf: more.filter { r in !recordings.contains { $0.sid == r.sid } })
    } catch { notice = error.localizedDescription }
  }
  func testNotify() async {
    do {
      let data = try await request("/edge/notify-test", method: "POST", body: [:])
      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      notice =
        result?["delivered"] as? Bool == true
        ? L("测试通知已送达 Gotify") : L("Gotify 推送失败") + ": " + (result?["error"] as? String ?? "")
    } catch { notice = error.localizedDescription }
  }
  func dateString(_ value: Double) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: language)
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter.string(from: Date(timeIntervalSince1970: value / 1000))
  }
  func retry() async {
    do {
      _ = try await request("/edge/notify-retry", method: "POST", body: [:])
      notice = L("已安排重试推送")
    } catch { notice = error.localizedDescription }
  }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  var model: Model?
  private var menuTimer: Timer?
  func applicationDidFinishLaunching(_ notification: Notification) {
    MenuLocalization.apply(language: ClientLanguage.current())
    menuTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
      Task { @MainActor in MenuLocalization.apply(language: ClientLanguage.current()) }
    }

    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
      let icon = NSImage(contentsOf: url)
    {
      NSApp.applicationIconImage = icon
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    model?.stopPlayback()
    model?.stop(persist: false)
    return .terminateNow
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct SimHubApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model = Model()
  var body: some Scene {
    WindowGroup("Yume SIM Hub") {
      Content(model: model).frame(minWidth: 900, minHeight: 650).onAppear { delegate.model = model }
    }.defaultSize(width: 1060, height: 790)
    SwiftUI.Settings { ClientPreferences(model: model).frame(width: 520, height: 230) }
    MenuBarExtra("SIM Hub", systemImage: model.running ? "simcard.fill" : "simcard") {
      Text(model.edge.online == true ? L("模块在线") : L("模块离线"))
      Button(model.running ? L("停止服务") : L("启动服务")) {
        if model.running { model.stop() } else { model.start() }
      }
      Button(L("显示窗口")) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
      }
      Divider()
      Button(L("退出")) { NSApp.terminate(nil) }
    }
  }
}
struct Content: View {
  @ObservedObject var model: Model

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Yume SIM Hub").font(.largeTitle.bold())
          Text(L("Mac 蜂窝通信中枢 · ") + model.versionLabel).foregroundStyle(.secondary)
        }
        Spacer()
        Picker(L("客户端语言"), selection: $model.language) { LanguageOptions() }.frame(width: 210)
        Button(model.running ? L("停止服务") : L("启动服务")) {
          if model.running { model.stop() } else { model.start() }
        }.buttonStyle(.borderedProminent).tint(model.running ? .orange : .accentColor)
      }
      HStack(spacing: 12) {
        status(L("模块"), model.edge.online == true ? L("在线") : L("离线"), model.edge.online == true)
        status(
          L("音频"), model.edge.voiceReady == true ? L("就绪") : L("未就绪"), model.edge.voiceReady == true
        )
        status(
          "SIP", model.edge.sipRegistered == true ? L("已注册") : L("未注册"),
          model.edge.sipRegistered == true)
        status(
          L("通话"),
          model.edge.online != true ? L("不可用") : (model.edge.busy == true ? L("使用中") : L("空闲")),
          model.edge.online == true && model.edge.busy != true)
      }
      if !model.notice.isEmpty {
        Text(L(model.notice)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
      }
      TabView {
        Form {
          Section(L("电话路由")) {
            Picker(
              L("服务提示语言（电话 / Gotify）"),
              selection: Binding(
                get: { model.settings.serviceLanguage ?? "en" },
                set: { model.settings.serviceLanguage = $0 })
            ) { languageOptions }
            Text(L("独立于客户端语言；同时控制电话提示音和 Gotify 通知说明，短信原文不变。")).font(.caption).foregroundStyle(
              .secondary)
            TextField(L("SIM 来电转接号码"), text: $model.settings.forwardTo)
            Toggle(L("启用 SIM 来电 → Twilio → 目标号码"), isOn: $model.settings.inboundEnabled)
            SecureField(
              model.settings.pinConfigured ? L("电话密码（已设置，留空保持）") : L("电话密码（6–12 位数字）"),
              text: $model.pin)
            Toggle(L("启用 Twilio 密码验证 → SIM 外呼"), isOn: $model.settings.outboundEnabled)
            Text(L("拨打 +12025550124 → 密码 + # → 本地号码或 *国际号码 + #")).font(.caption)
              .foregroundStyle(
                .secondary)
          }
          Section(L("Gotify 短信推送")) {
            TextField(L("服务地址"), text: $model.settings.gotifyUrl)
            SecureField(
              model.settings.gotifyConfigured ? L("应用 token（已配置，留空保持）") : L("应用 token"),
              text: $model.gotifyToken)
          }
          HStack {
            Button(L("发送测试通知")) { Task { await model.testNotify() } }
            Spacer()
          }
          Section(L("邮件发送短信")) {
            Toggle(L("启用邮件发送短信"), isOn: $model.settings.emailEnabled)
            Text(L("sms@example.com · 主题填 +国际号码或本地号码，纯文本正文为短信")).font(.caption).textSelection(
              .enabled)
            TextField(L("允许的发件人（逗号分隔）"), text: $model.senderText)
            Text(L("要求 Cloudflare 验证 DMARC 通过；Mac 离线时任务会排队。")).font(.caption).foregroundStyle(
              .secondary)
          }
          HStack {
            Button(L("保存配置")) { Task { await model.save() } }.buttonStyle(.borderedProminent)
              .disabled(
                model.saving)
            Spacer()
            Text(model.edge.operator ?? "").font(.caption)
          }
        }.formStyle(.grouped).tabItem { Label(L("配置"), systemImage: "slider.horizontal.3") }.tag(0)
        records(model.messages, inbox: true).tabItem { Label(L("短信收件箱"), systemImage: "message") }
          .tag(
            1)
        records(model.jobs, inbox: false).tabItem { Label(L("发送与通话"), systemImage: "clock") }.tag(2)
        VStack {
          List(model.recordings) { r in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(
                  (r.direction == "outbound" ? L("去电") : L("来电")) + " · " + (r.peer ?? L("未知号码"))
                ).font(.headline).textSelection(.enabled)
                Spacer()
                Text(L(r.status)).font(.caption)
              }
              Text(
                "\(model.dateString(r.created)) · \(Int(r.duration)) "
                  + L("秒") + " · "
                  + ByteCountFormatter.string(fromByteCount: Int64(r.size), countStyle: .file)
              ).font(.caption).foregroundStyle(.secondary)
              HStack {
                Button(model.playing == r.sid ? L("停止播放") : L("播放")) {
                  Task { await model.play(r) }
                }
                .disabled(!["archived", "purge"].contains(r.status))
                Button(L("下载")) { Task { await model.download(r) } }.disabled(
                  !["archived", "purge"].contains(r.status))
                Button(L("重试")) { Task { await model.retryRecording(r) } }
                Spacer()
                Button(L("删除"), role: .destructive) { Task { await model.deleteRecording(r) } }
              }
            }.padding(.vertical, 8)
          }
          HStack {
            Text(L("录音从振铃到挂断 · 双声道 · R2 simhub/ 加密归档")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L("更早录音")) { Task { await model.olderRecordings() } }
          }
        }.padding(12).tabItem { Label(L("通话录音"), systemImage: "waveform") }.tag(4)
        Form {
          Section("Twilio / SIP") {
            SecureField(L("Twilio Auth Token（留空保持）"), text: $model.twilioToken)
            TextField(L("SIP 域名"), text: $model.settings.sipDomain)
            TextField(L("SIP 用户名"), text: $model.settings.sipUser)
            SecureField(L("SIP 密码（留空保持）"), text: $model.sipPassword)
            Button(L("保存接入配置")) { Task { await model.save() } }
          }
          Section(L("安装与更新")) {
            Button(L("打开安装 / 更新向导")) { model.showSetup = true }
            Text(model.versionLabel).font(.caption)
          }
          Section(L("本机")) {
            Picker(L("客户端语言"), selection: $model.language) { languageOptions }
            Toggle(
              L("登录 Mac 后启动"),
              isOn: Binding(get: { model.loginItem }, set: { model.setLoginItem($0) })
            )
            Text(L("关闭窗口会继续运行；退出客户端会停止模块服务。运行时防止 Mac 自动睡眠。")).font(.caption)
            SecureField(L("客户端凭据（保存在本机受限配置）"), text: $model.accessToken)
            Button(L("保存客户端凭据")) { model.importToken() }
          }
          Section(L("运行日志")) {
            ScrollView {
              Text(model.log.isEmpty ? L("暂无日志") : model.log).font(
                .system(.caption, design: .monospaced)
              ).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 190)
          }
        }.formStyle(.grouped).tabItem { Label(L("接入与运行"), systemImage: "network") }.tag(3)
      }
      HStack {
        Text(L("worker.example.com · 配置仅在客户端访问")).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(L("刷新")) { Task { await model.refresh() } }
      }
    }.environment(\.locale, Locale(identifier: model.language)).padding(24).sheet(
      isPresented: $model.showSetup
    ) {
      VStack(alignment: .leading, spacing: 18) {
        Text(L("安装与更新向导")).font(.title.bold())
        Text(model.versionLabel).foregroundStyle(.secondary)
        Picker(L("客户端语言"), selection: $model.language) { languageOptions }
        Text(L("① 检测系统与依赖  →  ② 安装运行环境  →  ③ 检查 GitHub 更新  →  ④ 安装并重启")).font(.callout)
        Text(
          L("运行环境：Python 3.12 / pyusb / libusb；构建工具：Go / Xcode Command Line Tools。客户端不需要 Node.js。")
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button(L("检测依赖")) { Task { await model.setup("--check") } }
          Button(L("安装 / 修复依赖")) { Task { await model.setup("--install") } }
          Button(L("检查项目更新")) { Task { await model.setup("--check-update") } }
          Button(L("安装项目更新")) { Task { await model.setup("--update") } }
        }.disabled(model.setupBusy)
        if model.setupBusy { ProgressView(L("正在处理，请保持客户端打开…")) }
        ScrollView {
          Text(
            model.setupLog.isEmpty ? L("请选择一个步骤开始。安装和更新会暂时停止模块服务，保留本机凭据与运行数据。") : model.setupLog
          )
          .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(
            maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        HStack {
          Button(L("关闭")) { model.showSetup = false }.disabled(model.setupBusy)
          Spacer()
          if model.needsRelaunch {
            Button(L("完成并重启客户端")) { model.relaunch() }.buttonStyle(.borderedProminent)
          }
        }
      }.padding(26).frame(width: 820, height: 540).interactiveDismissDisabled(model.setupBusy)
    }
  }
  var languageOptions: some View {
    Group {
      Text("English").tag("en")
      Text("Français").tag("fr")
      Text("日本語").tag("ja")
      Text("简体中文").tag("zh-Hans")
      Text("繁體中文").tag("zh-Hant")
    }
  }
  func status(_ title: String, _ value: String, _ good: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Label(value, systemImage: good ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(
        good ? .green : .secondary)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(
      .quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }
  func recordTitle(_ r: Record, inbox: Bool) -> String {
    if inbox { return L("短信接收") + " · " + (r.data["from"] ?? L("未知号码")) }
    switch r.kind {
    case "incoming": return L("来电") + " · " + (r.data["from"] ?? L("未知号码"))
    case "dial": return L("去电") + " · " + (r.data["to"] ?? L("未知号码"))
    default: return L("短信发出") + " · " + (r.data["to"] ?? L("未知号码"))
    }
  }
  func recordRoute(_ r: Record, inbox: Bool) -> String {
    if inbox { return (r.data["from"] ?? L("未知号码")) + " → " + L("本机 SIM") }
    if r.kind == "incoming" { return L("转接目标") + ": " + (r.data["to"] ?? L("未知号码")) }
    let route = L("本机 SIM") + " → " + (r.data["to"] ?? L("未知号码"))
    return r.data["source"] == "email"
      ? route + " · " + L("来源邮箱") + ": " + (r.data["from"] ?? "") : route
  }
  func records(_ rows: [Record], inbox: Bool) -> some View {
    VStack {
      if inbox {
        HStack {
          Spacer()
          Button(L("重试待推送短信")) { Task { await model.retry() } }
        }
      }
      List(rows) { r in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(recordTitle(r, inbox: inbox)).font(.headline)
            Spacer()
            Text(L(inbox ? (r.notified == 1 ? L("已推送") : L("待推送")) : (r.status ?? ""))).font(
              .caption)
          }
          Text(recordRoute(r, inbox: inbox)).font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
          if let body = r.data["body"] { Text(body).textSelection(.enabled) }
          Text(model.dateString(r.created)).font(.caption)
            .foregroundStyle(.secondary)
          if let result = r.result { Text(result).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 8)
      }
      if rows.isEmpty { Text(L("暂无记录")).foregroundStyle(.secondary) }
      if !inbox {
        Text(L("unknown = 提交结果不明确，系统不会自动重发；sent = 模块已接受，非运营商送达回执。")).font(.caption).foregroundStyle(
          .secondary)
      }
    }.padding(12)
  }
}

struct LanguageOptions: View {
  var body: some View {
    Group {
      Text("English").tag("en")
      Text("Français").tag("fr")
      Text("日本語").tag("ja")
      Text("简体中文").tag("zh-Hans")
      Text("繁體中文").tag("zh-Hant")
    }
  }
}
struct ClientPreferences: View {
  @ObservedObject var model: Model
  var body: some View {
    Form {
      Section(L("客户端设置")) {
        Picker(L("客户端语言"), selection: $model.language) { LanguageOptions() }
        Text(L("客户端语言同步到 macOS 菜单栏，也可在系统设置中选择应用语言。")).font(.caption).foregroundStyle(.secondary)
        Text(model.versionLabel).font(.caption)
      }
    }.formStyle(.grouped)
  }
}
