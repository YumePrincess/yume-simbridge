import Darwin
import AVFoundation
import AppKit
import CoreImage.CIFilterBuiltins
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct Settings: Codable {
  var serviceLanguage: String? = "en"
  var authMode: String? = "password"
  var totpConfigured: Bool? = false
  var forwardTo = "+12025550123"
  var incomingAnswerMode: String? = "confirmed"
  var forwardConfirmEnabled: Bool? = true
  var forwardConfirmSeconds: Int? = 10
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
struct TOTPEnrollment: Codable {
  var secret: String
  var uri: String
  var expires: Double
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
  @Published var availableModules: [HardwareHealth.Module] = []
  @Published var selectedModule = UserDefaults.standard.string(forKey: "selectedModule") ?? "" {
    didSet { UserDefaults.standard.set(selectedModule, forKey: "selectedModule") }
  }
  @Published var selectedTab = 0
  private var refreshInFlight = false
  private var stateRefreshAfter = Date.distantPast
  private var recordingsRefreshAfter = Date.distantPast
  private var resolvedLanguage = ClientLanguage.current()
  @Published var language = ClientLanguage.loadSelection() {
    didSet {
      UserDefaults.standard.set(language, forKey: "clientLanguage")
      resolvedLanguage = ClientLanguage.current()
      ClientLanguage.applySelection()
    }
  }
  @Published var appearance = UserDefaults.standard.string(forKey: "clientAppearance") ?? "system" {
    didSet {
      UserDefaults.standard.set(appearance, forKey: "clientAppearance")
      applyAppearance()
    }
  }
  @Published var showAbout = false
  func applyAppearance() {
    switch appearance {
    case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
    case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    default: NSApplication.shared.appearance = nil
    }
  }
  func refreshSystemPreferences() {
    let current = ClientLanguage.current()
    guard language == "system", current != resolvedLanguage else { return }
    resolvedLanguage = current
    objectWillChange.send()
    ClientLanguage.applySelection()
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
  @Published var showTOTPSetup = false
  @Published var totpBusy = false
  @Published var totpEnrollment: TOTPEnrollment?
  @Published var totpCode = ""
  @Published var totpError = ""
  @Published var gotifyToken = ""
  @Published var twilioToken = ""
  @Published var sipPassword = ""
  @Published var senderText = "sender@example.com"
  @Published var accessToken = ""
  @Published var saving = false
  @Published var log = ""
  @Published var loginItem = false
  @Published private(set) var loaded = false
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
    resolvedLanguage = ClientLanguage.current()
    ClientLanguage.applySelection()
    applyAppearance()
    for path in [
      folder.appendingPathComponent("credentials.json"), folder.appendingPathComponent("edge.json"),
    ] {
      if let boot = try? CredentialStore.read(path) {
        token = boot.token
        break
      }
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
      Task { @MainActor in await self?.refresh(force: false) }
    }
    Task {
      await refresh()
      if UserDefaults.standard.bool(forKey: "autoRun") && !token.isEmpty { start() }
    }
  }
  var versionLabel: String {
    let info = Bundle.main.infoDictionary ?? [:]
    return
      "\(info["CFBundleShortVersionString"] as? String ?? "27.2.0") · Build \(info["CFBundleVersion"] as? String ?? "27021")"
  }
  @Published var releaseURL = "https://github.com/YumePrincess/yume-simhub/releases/latest"
  func openReleasePage() {
    if let url = URL(string: releaseURL) { NSWorkspace.shared.open(url) }
  }
  func setup(_ mode: String) async {
    guard !setupBusy, let resources = Bundle.main.resourceURL else { return }
    setupBusy = true
    defer { setupBusy = false }
    do {
      switch mode {
      case "--check":
        setupLog = try await BundledRuntime.run(
          resources: resources,
          arguments: [
            "-c",
            "import sys; sys.path.insert(0, sys.argv[1]); import usb_backend, certifi; assert usb_backend.backend is not None; print('Python / pyusb / libusb / TLS certificates: OK')",
            resources.appendingPathComponent("Mac/tools").path,
          ])
        UserDefaults.standard.set(true, forKey: "setupCompleted")
      case "--check-update":
        let release = try JSONDecoder().decode(
          ClientRelease.self, from: await request("/edge/release"))
        guard release.url.hasPrefix("https://github.com/YumePrincess/yume-simhub/releases/") else {
          throw CocoaError(.fileReadCorruptFile)
        }
        releaseURL = release.url
        let current = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
        setupLog =
          release.build > current
          ? L("发现新版本，请打开下载页获取更新 ZIP。") + "\n\(release.version) · Build \(release.build)"
          : L("当前已是最新版本。")
      case "--update":
        guard edge.busy != true else {
          setupLog = L("请先结束通话，再安装更新。")
          return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L("请选择从 GitHub Release 下载的更新 ZIP。")
        guard panel.runModal() == .OK, let archive = panel.url else { return }
        let scoped = archive.startAccessingSecurityScopedResource()
        defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
        guard let signer = Bundle.main.infoDictionary?["SIMHubSignerFingerprint"] as? String else {
          throw CocoaError(.fileReadCorruptFile)
        }
        let wasRunning = running
        stop(persist: false)
        for _ in 0..<80 {
          if !running { break }
          try? await Task.sleep(for: .milliseconds(250))
        }
        guard !running else {
          setupLog = L("模块服务仍在退出，请稍后重试")
          return
        }
        do {
          setupLog = try await BundledRuntime.run(
            resources: resources,
            arguments: [
              resources.appendingPathComponent("Mac/tools/install_update.py").path, "--archive",
              archive.path, "--destination", Bundle.main.bundleURL.path, "--signer", signer,
              "--current-build", Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            ])
          needsRelaunch = true
          UserDefaults.standard.set(wasRunning, forKey: "autoRun")
        } catch {
          if wasRunning { start() }
          throw error
        }
      default: break
      }
    } catch { setupLog = error.localizedDescription }
  }
  func relaunch() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [
      "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
      "simhub-relaunch", String(ProcessInfo.processInfo.processIdentifier),
      Bundle.main.bundleURL.path,
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
    availableModules = HardwareHealth.modules()
    let selection = (try? Data(contentsOf: folder.appendingPathComponent("runtime/module-selection.json"))).flatMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: String]
    }?["location"] ?? ""
    let bound = selectedModule.isEmpty ? selection : selectedModule
    let present = bound.isEmpty ? availableModules.count == 1 : availableModules.contains { $0.id == bound }
    let connected =
      running && present && age >= 0 && age < 12000
      && local?.modemConnected == true
    edge.online = connected
    edge.voiceReady = connected && local?.voiceReady == true
    edge.sipRegistered = connected && local?.sipRegistered == true
    edge.busy = connected ? local?.busy : nil
  }
  func refresh(force: Bool = true) async {
    guard !refreshInFlight else { return }
    let visible = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain }
    guard force || visible else { return }
    refreshInFlight = true
    defer { refreshInFlight = false }
    let now = Date()
    if force || now >= stateRefreshAfter {
      stateRefreshAfter = now.addingTimeInterval(60)
      do {
        let s = try JSONDecoder().decode(Snapshot.self, from: await request("/edge/state"))
        if !loaded {
          settings = s.settings
          senderText = s.settings.allowedSenders.joined(separator: "\n")
          loaded = true
        }
        edge = s.edge
        messages = s.events
        jobs = s.jobs
      } catch {
        stateRefreshAfter = Date().addingTimeInterval(300)
        if !loaded { notice = error.localizedDescription }
      }
    }
    if selectedTab == 4 && (force || now >= recordingsRefreshAfter) {
      recordingsRefreshAfter = now.addingTimeInterval(60)
      do {
        recordings = try JSONDecoder().decode([RecordingInfo].self, from: await request("/edge/recordings"))
      } catch { recordingsRefreshAfter = Date().addingTimeInterval(300) }
    }
    refreshLocalHealth()
    readLog()
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
      wakeRuntime()
      notice = L("配置已保存")
      await refresh()
    } catch { notice = error.localizedDescription }
  }
  func selectAuthMode(_ mode: String) {
    if mode == "totp" && settings.totpConfigured != true {
      Task { await beginTOTP() }
    } else { settings.authMode = mode }
  }
  func beginTOTP() async {
    guard !totpBusy else { return }
    totpBusy = true
    defer { totpBusy = false }
    do {
      totpEnrollment = try JSONDecoder().decode(TOTPEnrollment.self,
        from: await request("/edge/totp/setup", method: "POST", body: [:]))
      totpCode = ""
      totpError = ""
      showTOTPSetup = true
    } catch { notice = L(error.localizedDescription) }
  }
  func confirmTOTP() async {
    guard !totpBusy else { return }
    totpBusy = true
    defer { totpBusy = false }
    do {
      _ = try await request("/edge/totp/confirm", method: "POST", body: ["code": totpCode])
      settings.authMode = "totp"
      settings.totpConfigured = true
      pin = ""
      showTOTPSetup = false
      clearTOTPSetup()
      notice = L("2FA 已绑定并启用；电话验证请使用下一组验证码。")
    } catch { totpError = L(error.localizedDescription) }
  }
  func clearTOTPSetup() {
    totpEnrollment = nil
    totpCode = ""
    totpError = ""
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
  func wakeRuntime() {
    let path = folder.appendingPathComponent("runtime/cloud-wake")
    try? Data().write(to: path, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  }
  func start() {
    guard process == nil else { return }
    availableModules = HardwareHealth.modules()
    guard !selectedModule.isEmpty || availableModules.count <= 1 else {
      notice = L("检测到多个模块，请先选择要启用的模块。")
      return
    }
    shouldRun = true
    do {
      guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileReadCorruptFile) }
      let python = resources.appendingPathComponent("Python/bin/python3.12").path
      guard FileManager.default.isExecutableFile(atPath: python) else {
        throw CocoaError(.fileNoSuchFile)
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
      _ = fcntl(logFile.fileDescriptor, F_SETFL, fcntl(logFile.fileDescriptor, F_GETFL) | O_APPEND)
      let p = Process()
      p.executableURL = URL(
        fileURLWithPath: python)
      p.arguments = [
        "-s", "-B", "-u", resources.appendingPathComponent("Mac/supervisor.py").path, "--config",
        cfg.path,
        "--data", folder.appendingPathComponent("runtime").path,
      ]
      p.currentDirectoryURL = resources
      var environment = BundledRuntime.environment(resources: resources)
      if !selectedModule.isEmpty { environment["SIMHUB_MODULE_LOCATION"] = selectedModule }
      else if availableModules.count == 1 { environment["SIMHUB_MODULE_LOCATION"] = availableModules[0].id }
      p.environment = environment
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
    let cache = folder.appendingPathComponent("Playback", isDirectory: true)
    try FileManager.default.createDirectory(
      at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let target = cache.appendingPathComponent(UUID().uuidString + ".mp3")
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
  func removeHistory(inbox: Bool, id: String? = nil) async {
    if id == nil {
      let alert = NSAlert()
      alert.messageText = L("清空列表？")
      alert.informativeText = L("仅移除历史列表，保留内部去重信息；不会中断待办任务或删除通话录音。")
      alert.addButton(withTitle: L("清空列表")); alert.addButton(withTitle: L("取消"))
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    do {
      let escaped = id?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#")))
      _ = try await request("/edge/history/" + (inbox ? "sms" : "jobs") + (escaped.map { "/" + $0 } ?? ""), method: "DELETE")
      if inbox { messages.removeAll { id == nil || $0.id == id } }
      else { jobs.removeAll { id == nil || $0.id == id } }
      notice = L("历史列表已更新")
    } catch { notice = error.localizedDescription }
  }
  func clearRecordings() async {
    let alert = NSAlert()
    alert.messageText = L("清空全部通话录音？")
    alert.informativeText = L("将永久删除全部云端录音及 Twilio 副本，包括未显示的更早录音，无法恢复。")
    alert.addButton(withTitle: L("清空全部录音")); alert.addButton(withTitle: L("取消"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      _ = try await request("/edge/recordings", method: "DELETE")
      stopPlayback()
      notice = L("录音已加入删除队列")
      await refresh()
    } catch { notice = error.localizedDescription }
  }
  func clearLocalLog() {
    do {
      let file = try FileHandle(forWritingTo: folder.appendingPathComponent("runtime.log"))
      defer { try? file.close() }
      try file.truncate(atOffset: 0)
      log = ""
    } catch { notice = error.localizedDescription }
  }
  func dateString(_ value: Double) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: ClientLanguage.current())
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
  private var terminating = false
  func applicationDidFinishLaunching(_ notification: Notification) {
    MenuLocalization.install()

  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminating else { return .terminateLater }
    model?.stopPlayback()
    guard model?.running == true else { return .terminateNow }
    terminating = true
    model?.stop(persist: false)
    Task { @MainActor in
      for _ in 0..<80 {
        if model?.running != true { break }
        try? await Task.sleep(for: .milliseconds(250))
      }
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct SimHubApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model = Model()
  var body: some Scene {
    WindowGroup("Yume SIM Hub") {
      Content(model: model).frame(minWidth: 1000, minHeight: 700).onAppear { delegate.model = model }
    }.defaultSize(width: 1180, height: 820)
      .commands {
        CommandGroup(replacing: .appInfo) {
          Button(L("关于 Yume SIM Hub")) { model.showAbout = true }
        }
      }
    SwiftUI.Settings { ClientPreferences(model: model).frame(width: 560, height: 300) }

  }
}
struct LanguageOptions: View {
  var includesSystem = false
  var body: some View {
    Group {
      if includesSystem { Text(L("跟随系统")).tag("system") }
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
        ClientLanguagePicker(model: model)
        Text(L("客户端语言同步到 macOS 菜单栏，也可在系统设置中选择应用语言。")).font(.caption).foregroundStyle(.secondary)
        AppearancePicker(model: model)
        Button(L("关于 Yume SIM Hub")) { model.showAbout = true }
      }
    }.formStyle(.grouped)
      .sheet(isPresented: $model.showAbout) { AboutView(model: model) }
  }
}

struct TOTPSetupView: View {
  @ObservedObject var model: Model
  private func qrImage(_ uri: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(uri.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
      let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
        from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L("绑定 Google Authenticator")).font(.title2.bold())
      Text(L("使用 Google Authenticator 或兼容的验证器扫描二维码，也可手动输入绑定密钥。"))
      Text(L("新绑定成功后，旧密钥和未完成的电话验证立即失效。")).font(.caption).foregroundStyle(.secondary)
      if let enrollment = model.totpEnrollment {
        if let image = qrImage(enrollment.uri) {
          HStack { Spacer(); Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
              .frame(width: 240, height: 240).padding(12).background(.white); Spacer() }
        }
        Text(L("绑定密钥")).font(.caption).foregroundStyle(.secondary)
        Text(enrollment.secret).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        Text(L("六位数字 · 每 30 秒更新 · 密钥和二维码仅在本窗口显示，请妥善保管。"))
          .font(.caption).foregroundStyle(.secondary)
        SecureField(L("输入验证器当前六位验证码"), text: $model.totpCode)
        Text(L("验证成功后立即启用 2FA；取消不会更改当前验证方式。绑定页面 10 分钟后失效。"))
          .font(.caption).foregroundStyle(.secondary)
      }
      if !model.totpError.isEmpty { Text(model.totpError).foregroundStyle(.red) }
      HStack {
        Button(L("取消")) { model.showTOTPSetup = false }.disabled(model.totpBusy)
        Spacer()
        Button(L("验证并启用 2FA")) { Task { await model.confirmTOTP() } }
          .buttonStyle(.borderedProminent)
          .disabled(model.totpBusy || model.totpCode.count != 6 || !model.totpCode.allSatisfy { $0.isASCII && $0.isNumber })
      }
    }.padding(26).frame(width: 600).interactiveDismissDisabled(model.totpBusy)
  }
}
