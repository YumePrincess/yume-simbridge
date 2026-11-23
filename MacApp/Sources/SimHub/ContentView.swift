import AppKit
import SwiftUI

// Select the back-deployable property wrapper when SDK 27 also exposes the State macro.
private typealias HubViewState<Value> = SwiftUI.State<Value>

private struct HubDestination: Identifiable {
  let id: Int
  let title: String
  let symbol: String
  let tint: Color
}

struct Content: View {
  @ObservedObject var model: Model
  @HubViewState private var search = ""
  @HubViewState private var advanced = false
  @HubViewState private var showLog = false
  private let communication = [
    HubDestination(id: 0, title: "概览", symbol: "square.grid.2x2", tint: .blue),
    HubDestination(id: 1, title: "短信收件箱", symbol: "bubble.left.and.bubble.right", tint: .green),
    HubDestination(id: 2, title: "发送与通话", symbol: "clock.arrow.circlepath", tint: .orange),
    HubDestination(id: 4, title: "通话录音", symbol: "waveform", tint: .purple),
  ]
  private let configuration = [
    HubDestination(id: 5, title: "电话路由", symbol: "arrow.triangle.branch", tint: .blue),
    HubDestination(id: 6, title: "消息自动化", symbol: "bolt.badge.clock", tint: .orange),
    HubDestination(id: 7, title: "模块与接入", symbol: "simcard", tint: .teal),
    HubDestination(id: 3, title: "应用设置", symbol: "gearshape", tint: .gray),
  ]
  private var destination: HubDestination {
    (communication + configuration).first { $0.id == model.selectedTab } ?? communication[0]
  }
  private var configuredPage: Bool { [5, 6, 7].contains(model.selectedTab) }
  private var ready: Bool {
    model.edge.online == true && model.edge.voiceReady == true && model.edge.sipRegistered == true
  }
  private var serviceTitle: String {
    !model.running ? "服务已停止" : (ready ? "通信已就绪" : "正在连接设备")
  }
  private var activeModule: String {
    if let item = model.availableModules.first(where: { $0.id == model.selectedModule }) { return item.label }
    if model.selectedModule.isEmpty && model.availableModules.count == 1 { return model.availableModules[0].label }
    return model.selectedModule.isEmpty ? L("自动选择（仅连接一个模块时）") : L("未连接") + " · USB " + model.selectedModule
  }
  private var usefulNotice: String {
    if ready && L(model.notice) == L("Mac 服务已启动，正在连接模块与 SIP") { return "" }
    return model.notice
  }

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 230, ideal: 244, max: 280)
    } detail: {
      VStack(spacing: 0) {
        if !usefulNotice.isEmpty { noticeBanner }
        page
      }
      .background(Color(nsColor: .windowBackgroundColor))
      .navigationTitle(L(destination.title))
      .toolbar { toolbar }
    }
    .navigationSplitViewStyle(.balanced)
    .environment(\.locale, Locale(identifier: ClientLanguage.current()))
    .onChange(of: model.selectedTab) { _, _ in
      search = ""
      Task { await model.refresh(force: false) }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      model.refreshSystemPreferences()
      Task { await model.refresh(force: false) }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
      model.refreshSystemPreferences()
    }
    .sheet(isPresented: $model.showAbout) { AboutView(model: model) }
    .sheet(isPresented: $model.showTOTPSetup, onDismiss: { model.clearTOTPSetup() }) {
      TOTPSetupView(model: model)
    }
    .sheet(isPresented: $model.showSetup) { SetupAssistantView(model: model) }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        HubLogo(size: 48)
        VStack(alignment: .leading, spacing: 2) {
          Text("Yume SIMBridge").font(.headline)
          Text(L("Mac 蜂窝通信中枢")).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 16)
      List(selection: Binding<Int?>(get: { model.selectedTab }, set: { if let value = $0 { model.selectedTab = value } })) {
        Section(L("通信")) {
          ForEach(communication) { item in destinationRow(item) }
        }
        Section(L("管理")) {
          ForEach(configuration) { item in destinationRow(item) }
        }
      }.listStyle(.sidebar)
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 7) {
          Circle().fill(ready ? .green : (model.running ? .orange : .secondary)).frame(width: 7, height: 7)
          Text(L(serviceTitle)).font(.callout.weight(.medium))
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
    }
  }
  private func destinationRow(_ item: HubDestination) -> some View {
    Label {
      Text(L(item.title))
    } icon: {
      Image(systemName: item.symbol).foregroundStyle(item.tint).symbolRenderingMode(.hierarchical)
    }.tag(item.id).padding(.vertical, 3)
  }
  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button { Task { await model.refresh() } } label: { Label(L("刷新"), systemImage: "arrow.clockwise") }
        .help(L("刷新")).keyboardShortcut("r", modifiers: .command)
      if configuredPage {
        Button { Task { await model.save() } } label: {
          if model.saving { ProgressView().controlSize(.small) }
          else { Label(L("保存配置"), systemImage: "checkmark") }
        }.buttonStyle(.borderedProminent).disabled(model.saving || !model.loaded)
          .keyboardShortcut("s", modifiers: .command)
      }
      if model.running {
        Button { model.stop() } label: { Label(L("停止服务"), systemImage: "stop.circle") }
      } else {
        Button { model.start() } label: { Label(L("启动服务"), systemImage: "power") }
          .buttonStyle(.borderedProminent)
      }
    }
  }
  private var noticeBanner: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "info.circle").foregroundStyle(.secondary)
      Text(L(usefulNotice)).font(.callout).textSelection(.enabled)
      Spacer(minLength: 8)
      Button { model.notice = "" } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
        .buttonStyle(.plain).accessibilityLabel(L("关闭"))
    }.padding(.horizontal, 24).padding(.vertical, 12).background(.quaternary.opacity(0.3))
  }
  @ViewBuilder private var page: some View {
    switch model.selectedTab {
    case 1: history(inbox: true)
    case 2: history(inbox: false)
    case 4: recordingPage
    case 5: routingPage
    case 6: automationPage
    case 7: modulePage
    case 3: preferencesPage
    default: overview
    }
  }

  private var overview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(spacing: 18) {
          Image(systemName: ready ? "antenna.radiowaves.left.and.right" : "simcard")
            .font(.system(size: 30, weight: .medium)).foregroundStyle(.tint)
            .frame(width: 64, height: 64).background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
          VStack(alignment: .leading, spacing: 6) {
            Text(L(serviceTitle)).font(.system(size: 27, weight: .bold))
            Text(L("模块、通话与消息，一处管理。")).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
        }.padding(.top, 8)
        EqualHeightRow(spacing: 12) {
          healthTile("模块", value: model.edge.online == true ? "在线" : "离线", symbol: "simcard", good: model.edge.online == true)
          healthTile("音频", value: model.edge.voiceReady == true ? "就绪" : "未就绪", symbol: "waveform", good: model.edge.voiceReady == true)
          healthTile("SIP", value: model.edge.sipRegistered == true ? "已注册" : "未注册", symbol: "network", good: model.edge.sipRegistered == true)
          healthTile("通话", value: model.edge.online != true ? "不可用" : (model.edge.busy == true ? "使用中" : "空闲"), symbol: "phone", good: model.edge.online == true)
        }
        overviewRoutes
        EqualHeightRow(spacing: 16) {
          HubCard(title: L("消息自动化"), symbol: "bolt.badge.clock", fillsHeight: true) {
            summaryLine("Gotify 短信推送", value: model.settings.gotifyConfigured ? "已配置" : "未配置")
            summaryLine("邮件发送短信", value: model.settings.emailEnabled ? "已启用" : "已停用")
            Button(L("管理消息自动化")) { model.selectedTab = 6 }.buttonStyle(.link)
          }
          HubCard(title: L("当前模块"), symbol: "simcard", fillsHeight: true) {
            Text(activeModule).font(.callout.weight(.medium)).textSelection(.enabled)
            Text(L("设备与音频绑定至同一 USB 端口。"))
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L("管理模块与接入")) { model.selectedTab = 7 }.buttonStyle(.link)
          }
        }
        HubCard(title: L("最近活动"), symbol: "clock") {
          if model.jobs.isEmpty {
            Text(L("新的通话和短信会显示在这里。")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
          } else {
            ForEach(Array(model.jobs.prefix(3))) { record in
              HStack(spacing: 12) {
                Image(systemName: record.kind == "sms" ? "message" : "phone").foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                  Text(recordTitle(record, inbox: false)).font(.callout.weight(.medium))
                  Text(model.dateString(record.created)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HubBadge(value: L(record.status ?? ""), tone: statusTone(record.status ?? ""))
              }.padding(.vertical, 5)
            }
          }
          Button(L("查看全部活动")) { model.selectedTab = 2 }.buttonStyle(.link)
        }
      }.padding(28).frame(maxWidth: 1060)
        .frame(maxWidth: .infinity)
    }
  }
  private var overviewRoutes: some View {
    HubCard(title: L("电话路由"), symbol: "arrow.triangle.branch") {
      HStack {
        Label(L("SIM 来电"), systemImage: "phone.arrow.down.left").frame(width: 130, alignment: .leading)
        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
        Text(model.settings.forwardTo).font(.body.monospacedDigit()).textSelection(.enabled)
        Spacer()
        HubBadge(value: L(model.settings.inboundEnabled ? "已启用" : "已停用"), tone: model.settings.inboundEnabled ? .green : .secondary)
      }.padding(.vertical, 5)
      Divider()
      HStack {
        Label(L("Twilio 来电"), systemImage: "phone.arrow.up.right").frame(width: 130, alignment: .leading)
        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
        Text(L("身份验证后使用 SIM 外呼")).font(.callout)
        Spacer()
        HubBadge(value: L(model.settings.outboundEnabled ? "已启用" : "已停用"), tone: model.settings.outboundEnabled ? .green : .secondary)
      }.padding(.vertical, 5)
      HStack {
        Text(L(model.settings.incomingAnswerMode == "waiting" ? "先接听并播放提示和音乐" : "目标方确认后接听（默认）"))
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(L("管理电话路由")) { model.selectedTab = 5 }.buttonStyle(.link)
      }.padding(.top, 4)
    }
  }
  private func healthTile(_ title: String, value: String, symbol: String, good: Bool) -> some View {
    VStack(alignment: .leading, spacing: 13) {
      Label(L(title), systemImage: symbol).font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        Image(systemName: good ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(good ? .green : .secondary)
        Text(L(value)).font(.callout.weight(.semibold))
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.35)))
  }
  private func summaryLine(_ title: String, value: String) -> some View {
    HStack { Text(L(title)).font(.callout); Spacer(); Text(L(value)).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 2)
  }

  private var routingPage: some View {
    Form {
      Section {
        pageIntro("电话路由", subtitle: "分别管理 SIM 来电转接与 Twilio 验证外呼。", symbol: "arrow.triangle.branch")
      }
      Section(L("服务提示语言")) {
        Picker(L("服务提示语言（电话 / Gotify）"), selection: serviceLanguage) { LanguageOptions() }
        help("独立于客户端语言；同时控制电话提示音和 Gotify 通知说明，短信原文不变。")
      }
      Section(L("SIM 来电转接")) {
        Toggle(L("启用 SIM 来电 → Twilio → 目标号码"), isOn: $model.settings.inboundEnabled)
        TextField(L("SIM 来电转接号码"), text: $model.settings.forwardTo)
        Picker(L("模块来电接听模式"), selection: Binding(get: { model.settings.incomingAnswerMode ?? "confirmed" }, set: { model.settings.incomingAnswerMode = $0 })) {
          Text(L("目标方确认后接听（默认）")).tag("confirmed")
          Text(L("先接听并播放提示和音乐")).tag("waiting")
        }
        help(model.settings.incomingAnswerMode == "waiting"
          ? "模块先接听，播放中英文接通提示和等待音乐；失败时播放中英文提示。"
          : "模块保持振铃，目标方确认后才接听；等待时为运营商回铃音，不播放音乐或自定义失败提示，等待受运营商时限影响。")
        Toggle(L("转接接听后按 1 确认"), isOn: Binding(get: { model.settings.forwardConfirmEnabled ?? true }, set: { model.settings.forwardConfirmEnabled = $0 }))
        if model.settings.forwardConfirmEnabled ?? true {
          Stepper(value: Binding(get: { model.settings.forwardConfirmSeconds ?? 10 }, set: { model.settings.forwardConfirmSeconds = $0 }), in: 1...60) {
            HStack { Text(L("确认等待时长（秒）")); Spacer(); Text("\(model.settings.forwardConfirmSeconds ?? 10)").monospacedDigit() }
          }
          help("接听者须在服务语言提示结束后设定秒数内按 1；确认前不会转播目标方的声音。")
        } else { help("关闭按键确认后，转接号码的语音信箱可能直接接通。") }
      }
      Section(L("Twilio 验证外呼")) {
        Toggle(L("启用 Twilio 身份验证 → SIM 外呼"), isOn: $model.settings.outboundEnabled)
        Picker(L("电话验证模式"), selection: Binding(get: { model.settings.authMode ?? "password" }, set: { model.selectAuthMode($0) })) {
          Text(L("密码模式")).tag("password")
          Text(L("2FA 模式（验证器）")).tag("totp")
        }.disabled(model.totpBusy)
        if model.settings.authMode == "totp" {
          LabeledContent {
            Button(L("重设 2FA")) { Task { await model.beginTOTP() } }.disabled(model.totpBusy)
          } label: { Label(L("验证器已绑定"), systemImage: "checkmark.shield") }
          help("拨打 Twilio 后输入验证器的六位验证码，再按 #；验证码只能使用一次。")
        } else {
          SecureField(model.settings.pinConfigured ? L("电话密码（已设置，留空保持）") : L("电话密码（6–12 位数字）"), text: $model.pin)
        }
        help("拨打 +12025550124 → 身份验证 + # → 本地号码或 *国际号码 + #")
      }
    }.formStyle(.grouped)
  }
  private var automationPage: some View {
    Form {
      Section { pageIntro("消息自动化", subtitle: "短信通知与邮件指令，按需启用。", symbol: "bolt.badge.clock") }
      Section(L("Gotify 短信推送")) {
        TextField(L("服务地址"), text: $model.settings.gotifyUrl)
        SecureField(model.settings.gotifyConfigured ? L("应用 token（已配置，留空保持）") : L("应用 token"), text: $model.gotifyToken)
        Button { Task { await model.testNotify() } } label: { Label(L("发送测试通知"), systemImage: "paperplane") }
      }
      Section(L("邮件发送短信")) {
        Toggle(L("启用邮件发送短信"), isOn: $model.settings.emailEnabled)
        LabeledContent(L("收件地址")) { Text("sms@example.com").textSelection(.enabled) }
        help("sms@example.com · 主题填 +国际号码或本地号码，纯文本正文为短信")
        TextField(L("允许的发件人（逗号分隔）"), text: $model.senderText)
        help("邮件须通过发件人签名验证；Mac 离线时任务会排队。")
      }
      Section(L("服务提示语言")) {
        Picker(L("服务提示语言（电话 / Gotify）"), selection: serviceLanguage) { LanguageOptions() }
        help("独立于客户端语言；同时控制电话提示音和 Gotify 通知说明，短信原文不变。")
      }
    }.formStyle(.grouped)
  }
  private var modulePage: some View {
    Form {
      Section { pageIntro("模块与接入", subtitle: "选择设备，并管理 Twilio 连接。", symbol: "simcard") }
      Section(L("运行设备")) {
        Text(L("同一时间仅一个设备运行，配置始终一致。")).font(.caption).foregroundStyle(.secondary)
        ForEach(model.runtimeDevices) { device in
          LabeledContent(device.label) {
            if model.runtimeOwner == device.id {
              Text(L("当前运行")).foregroundStyle(.green)
            } else {
              Button(L("切换到此设备")) { Task { await model.selectRuntimeDevice(device.id) } }
                .disabled(model.runtimeBusy)
            }
          }
        }
      }
      Section(L("模块选择")) {
        Picker(L("启用的 DJI 模块"), selection: $model.selectedModule) {
          Text(L("自动选择（仅连接一个模块时）")).tag("")
          ForEach(model.availableModules) { module in Text(module.label).tag(module.id) }
          if !model.selectedModule.isEmpty && !model.availableModules.contains(where: { $0.id == model.selectedModule }) {
            Text(L("未连接") + " · USB " + model.selectedModule).tag(model.selectedModule)
          }
        }.disabled(model.running)
        help("按 USB 端口绑定；更换端口后请重新选择。先停止服务再切换模块；所选模块拔出时不会改用其他模块。")
        LabeledContent(L("模块")) { Text(L(model.edge.online == true ? "在线" : "离线")) }
        LabeledContent(L("音频")) { Text(L(model.edge.voiceReady == true ? "就绪" : "未就绪")) }
        LabeledContent("SIP") { Text(L(model.edge.sipRegistered == true ? "已注册" : "未注册")) }
      }
      Section(L("云端接入")) {
        LabeledContent(L("服务地址")) { Text("worker.example.com").textSelection(.enabled) }
        DisclosureGroup("Twilio / SIP", isExpanded: $advanced) {
          SecureField(L("Twilio Auth Token（留空保持）"), text: $model.twilioToken)
          TextField(L("SIP 域名"), text: $model.settings.sipDomain)
          TextField(L("SIP 用户名"), text: $model.settings.sipUser)
          SecureField(L("SIP 密码（留空保持）"), text: $model.sipPassword)
        }
      }
    }.formStyle(.grouped)
  }
  private var preferencesPage: some View {
    Form {
      Section { pageIntro("应用设置", subtitle: "语言、更新与本机诊断。", symbol: "gearshape") }
      Section(L("客户端设置")) {
        ClientLanguagePicker(model: model)
        help("跟随系统使用首选语言；不支持的系统语言使用英语。客户端语言同步到 macOS 菜单栏。")
        AppearancePicker(model: model)
        Toggle(L("登录 Mac 后启动"), isOn: Binding(get: { model.loginItem }, set: { model.setLoginItem($0) }))
        help("关闭窗口会继续运行；退出客户端会停止模块服务。运行时防止 Mac 自动睡眠。")
      }
      Section(L("安装与更新")) {
        Button { model.showSetup = true } label: { Label(L("打开安装 / 更新向导"), systemImage: "arrow.down.app") }
      }
      Section(L("关于")) {
        Button { model.showAbout = true } label: { Label(L("关于 Yume SIMBridge"), systemImage: "info.circle") }
      }
      Section(L("客户端接入凭据")) {
        SecureField(L("客户端凭据（保存在本机受限配置）"), text: $model.accessToken)
        Button(L("保存客户端凭据")) { model.importToken() }
      }
      Section(L("运行日志")) {
        DisclosureGroup(L("查看本机日志"), isExpanded: $showLog) {
          ScrollView {
            Text(model.log.isEmpty ? L("暂无日志") : model.log).font(.system(.caption, design: .monospaced))
              .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          }.frame(height: 240)
          HStack {
            Spacer()
            Button(L("清空本机日志"), role: .destructive) { model.clearLocalLog() }.buttonStyle(.borderless)
          }
        }
      }
    }.formStyle(.grouped)
  }
  private var serviceLanguage: Binding<String> {
    Binding(get: { model.settings.serviceLanguage ?? "en" }, set: { model.settings.serviceLanguage = $0 })
  }
  private func pageIntro(_ title: String, subtitle: String, symbol: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 36, height: 38)
      VStack(alignment: .leading, spacing: 5) {
        Text(L(title)).font(.title2.weight(.bold))
        Text(L(subtitle)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(.vertical, 8)
  }
  private func help(_ text: String) -> some View {
    Text(L(text)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }

  private func history(inbox: Bool) -> some View {
    let source = inbox ? model.messages : model.jobs
    let rows = source.filter { search.isEmpty || ($0.payload + L($0.status ?? "") + recordTitle($0, inbox: inbox)).localizedCaseInsensitiveContains(search) }
    return VStack(spacing: 0) {
      listHeader(inbox ? "短信收件箱" : "发送与通话", subtitle: inbox ? "接收的短信与推送状态。" : "短信发送、来电转接与外呼记录。") {
        if inbox { Button(L("重试待推送短信")) { Task { await model.retry() } } }
        Button(L("清空列表"), role: .destructive) { Task { await model.removeHistory(inbox: inbox) } }.disabled(source.isEmpty)
      }
      if rows.isEmpty {
        emptyState(symbol: inbox ? "bubble.left.and.bubble.right" : "clock", subtitle: "新的通话和短信会显示在这里。")
      } else {
        List(rows) { record in historyRow(record, inbox: inbox) }
          .listStyle(.inset).scrollContentBackground(.hidden)
      }
      listFooter(rows.count, note: inbox ? "短信原文与原始号码保持不变。" : "unknown = 提交结果不明确，系统不会自动重发；sent = 模块已接受，非运营商送达回执。")
    }
  }
  private func historyRow(_ record: Record, inbox: Bool) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: inbox || record.kind == "sms" ? "message.fill" : (record.kind == "incoming" ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill"))
        .font(.body).foregroundStyle(inbox || record.kind == "sms" ? .green : .blue)
        .frame(width: 34, height: 34).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 7) {
        HStack(alignment: .firstTextBaseline) {
          Text(recordTitle(record, inbox: inbox)).font(.headline).textSelection(.enabled)
          Spacer()
          HubBadge(value: L(inbox ? (record.notified == 1 ? "已推送" : "待推送") : (record.status ?? "")), tone: inbox ? (record.notified == 1 ? .green : .orange) : statusTone(record.status ?? ""))
        }
        Text(recordRoute(record, inbox: inbox)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if let body = record.data["body"] { Text(body).font(.body).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        HStack {
          Text(model.dateString(record.created)).font(.caption).foregroundStyle(.tertiary)
          if let result = record.result, !result.isEmpty { Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
      }
      Menu {
        Button(L("删除"), role: .destructive) { Task { await model.removeHistory(inbox: inbox, id: record.id) } }
      } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("记录操作"))
    }.padding(.vertical, 10).listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 8))
  }
  private var recordingPage: some View {
    let rows = model.recordings.filter { search.isEmpty || (($0.peer ?? "") + ($0.target ?? "") + $0.sid).localizedCaseInsensitiveContains(search) }
    return VStack(spacing: 0) {
      listHeader("通话录音", subtitle: "按来去方向与号码查找、播放或下载录音。") {
        Button(L("更早录音")) { Task { await model.olderRecordings() } }.disabled(model.recordings.isEmpty)
        Divider()
        Button(L("清空全部录音"), role: .destructive) { Task { await model.clearRecordings() } }.disabled(model.recordings.isEmpty)
      }
      if rows.isEmpty { emptyState(symbol: "waveform", subtitle: "通话结束后，归档录音会显示在这里。") }
      else {
        List(rows) { recording in recordingRow(recording) }
          .listStyle(.inset).scrollContentBackground(.hidden).buttonStyle(.borderless)
      }
      listFooter(rows.count, note: "录音从振铃到挂断 · 双声道 · R2 simhub/ 加密归档")
    }
  }
  private func recordingRow(_ r: RecordingInfo) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Button { Task { await model.play(r) } } label: {
        Image(systemName: model.playing == r.sid ? "stop.fill" : "play.fill")
          .font(.body.weight(.semibold)).frame(width: 42, height: 42)
      }.buttonStyle(.bordered).buttonBorderShape(.circle)
        .disabled(!["archived", "purge"].contains(r.status))
        .help(L(model.playing == r.sid ? "停止播放" : "播放"))
        .accessibilityLabel(L(model.playing == r.sid ? "停止播放" : "播放"))
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label(L(r.direction == "outbound" ? "去电" : "来电") + " · " + (r.peer ?? L("未知号码")), systemImage: r.direction == "outbound" ? "phone.arrow.up.right" : "phone.arrow.down.left")
            .font(.headline).textSelection(.enabled)
          Spacer()
          HubBadge(value: L(r.status), tone: statusTone(r.status))
        }
        Text("\(model.dateString(r.created)) · \(Int(r.duration)) " + L("秒") + " · " + ByteCountFormatter.string(fromByteCount: Int64(r.size), countStyle: .file))
          .font(.caption).foregroundStyle(.secondary)
      }.padding(.top, 4)
      Button { Task { await model.download(r) } } label: { Image(systemName: "arrow.down.to.line").frame(width: 24, height: 24) }
        .disabled(!["archived", "purge"].contains(r.status)).help(L("下载")).accessibilityLabel(L("下载"))
      Menu {
        Button(L("重试")) { Task { await model.retryRecording(r) } }
        Divider()
        Button(L("删除"), role: .destructive) { Task { await model.deleteRecording(r) } }
      } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("记录操作"))
    }.padding(.vertical, 10).listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 8))
  }
  private func listHeader<Actions: View>(_ title: String, subtitle: String, @ViewBuilder actions: () -> Actions) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(L(title)).font(.title2.weight(.bold))
          Text(L(subtitle)).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Menu(content: actions) { Image(systemName: "ellipsis.circle").font(.title3) }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("列表操作"))
      }
      TextField(L("搜索号码或内容"), text: $search).textFieldStyle(.roundedBorder).controlSize(.large)
    }.padding(24)
  }
  private func emptyState(symbol: String, subtitle: String) -> some View {
    ContentUnavailableView(L(search.isEmpty ? "暂无记录" : "没有匹配的记录"), systemImage: search.isEmpty ? symbol : "magnifyingglass", description: Text(L(search.isEmpty ? subtitle : "尝试其他号码或关键词。")))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private func listFooter(_ count: Int, note: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text("\(count) " + L("条记录")).monospacedDigit().fixedSize()
      Spacer()
      Text(L(note)).multilineTextAlignment(.trailing)
    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 14)
  }
  private func recordTitle(_ r: Record, inbox: Bool) -> String {
    if inbox { return L("短信接收") + " · " + (r.data["from"] ?? L("未知号码")) }
    switch r.kind {
    case "incoming": return L("来电") + " · " + (r.data["from"] ?? L("未知号码"))
    case "dial": return L("去电") + " · " + (r.data["to"] ?? L("未知号码"))
    default: return L("短信发出") + " · " + (r.data["to"] ?? L("未知号码"))
    }
  }
  private func recordRoute(_ r: Record, inbox: Bool) -> String {
    if inbox { return (r.data["from"] ?? L("未知号码")) + " → " + L("本机 SIM") }
    if r.kind == "incoming" { return L("转接目标") + ": " + (r.data["to"] ?? L("未知号码")) }
    let route = L("本机 SIM") + " → " + (r.data["to"] ?? L("未知号码"))
    return r.data["source"] == "email" ? route + " · " + L("来源邮箱") + ": " + (r.data["from"] ?? "") : route
  }
  private func statusTone(_ status: String) -> Color {
    if ["failed", "unknown", "submitted"].contains(status) { return .orange }
    if ["sent", "archived", "connected"].contains(status) { return .green }
    return .secondary
  }
}

private struct HubCard<Content: View>: View {
  let title: String
  let symbol: String
  var fillsHeight = false
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(title, systemImage: symbol).font(.headline)
      content
    }.padding(20).frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.35)))
  }
}
private struct HubBadge: View {
  let value: String
  let tone: Color
  var body: some View {
    Text(value).font(.caption.weight(.medium)).foregroundStyle(tone)
      .padding(.horizontal, 9).padding(.vertical, 4)
      .background(tone.opacity(0.08), in: Capsule())
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct SetupAssistantView: View {
  @ObservedObject var model: Model
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 14) {
        Image(systemName: "arrow.down.app").font(.largeTitle).foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 5) {
          Text(L("安装与更新向导")).font(.title2.bold())
          Text(model.versionLabel).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
      }
      ClientLanguagePicker(model: model)
      Text(L("运行环境已包含在 App 内，无需安装开发工具。配置与运行数据仅保存在本机 Application Support。"))
        .font(.callout).foregroundStyle(.secondary)
      VStack(spacing: 0) {
        step("1", title: "检查运行环境", symbol: "checkmark.shield") { Task { await model.setup("--check") } }
        Divider().padding(.leading, 58)
        step("2", title: "检查更新", symbol: "arrow.clockwise") { Task { await model.setup("--check-update") } }
        Divider().padding(.leading, 58)
        step("3", title: "打开下载页", symbol: "arrow.down.to.line") { model.openReleasePage() }
      }.padding(.horizontal, 14).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
        .disabled(model.setupBusy)
      if model.setupBusy { ProgressView(L("正在处理，请保持客户端打开…")).controlSize(.small) }
      ScrollView {
        Text(model.setupLog.isEmpty ? L("首次安装使用 DMG，应用内更新选择 ZIP。更新会校验签名并保留本机凭据与数据。") : model.setupLog)
          .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }.frame(minHeight: 80, maxHeight: 145).padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
      HStack {
        Button(L("关闭")) { model.showSetup = false }.keyboardShortcut(.cancelAction).disabled(model.setupBusy)
        Spacer()
        if model.needsRelaunch {
          Button(L("完成并重启客户端")) { model.relaunch() }.buttonStyle(.borderedProminent)
        } else {
          Button(L("安装已下载更新")) { Task { await model.setup("--update") } }.buttonStyle(.borderedProminent).disabled(model.setupBusy)
        }
      }
    }.padding(28).frame(width: 650).interactiveDismissDisabled(model.setupBusy)
  }
  private func step(_ number: String, title: String, symbol: String, action: @escaping () -> Void) -> some View {
    HStack(spacing: 13) {
      Text(number).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 26, height: 26).background(.quaternary, in: Circle())
      Label(L(title), systemImage: symbol).font(.callout.weight(.medium))
      Spacer()
      Button(L("继续"), action: action).buttonStyle(.bordered).accessibilityLabel(L(title))
    }.padding(.vertical, 14)
  }
}
