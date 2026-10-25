import SwiftUI
import AppKit
import Security
import ServiceManagement
import AVFoundation
import UniformTypeIdentifiers

struct Settings: Codable {
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
 var data: [String:String] { (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String:String] ?? [:] }
}
struct Snapshot: Codable { var settings: Settings; var edge: Edge; var jobs: [Record]; var events: [Record] }
struct RecordingInfo: Codable, Identifiable {
 var sid:String; var call:String; var duration:Double; var created:Double; var size:Int; var status:String; var attempts:Int; var twilioDeleted:Bool
 var id:String{sid}
}
struct Bootstrap: Codable { var origin: String; var token: String }
@MainActor enum Vault {
 static let key: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"zone.yume.simhub",kSecAttrAccount as String:"edge"]
 static func read() -> String? { var q=key;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne;var item:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess,let data=item as? Data else{return nil};return String(data:data,encoding:.utf8) }
 static func save(_ value:String) throws { var q=key;q[kSecValueData as String]=Data(value.utf8);q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;let status=SecItemAdd(q as CFDictionary,nil);if status==errSecDuplicateItem {let s=SecItemUpdate(key as CFDictionary,[kSecValueData as String:Data(value.utf8)] as CFDictionary);guard s==errSecSuccess else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(s))}}else if status != errSecSuccess{throw NSError(domain:NSOSStatusErrorDomain,code:Int(status))} }
}
@MainActor final class Model: ObservableObject {
 @Published var recordings:[RecordingInfo]=[]
 @Published var playing:String?
 private var player:AVPlayer?
 private var playbackFile:URL?
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
 private var timer: Timer?
 private let base = "https://worker.example.com"
 private var token = ""
 private var activity: NSObjectProtocol?
 private let folder = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("YumeSimHub",isDirectory:true)
 init() {
  token=Vault.read() ?? ""
  if token.isEmpty,let resource=Bundle.main.resourceURL?.appendingPathComponent("installation.json"),let data=try? Data(contentsOf:resource),let install=try? JSONSerialization.jsonObject(with:data) as? [String:String],let path=install["bootstrap"],let bootData=try? Data(contentsOf:URL(fileURLWithPath:path)),let boot=try? JSONDecoder().decode(Bootstrap.self,from:bootData) {
   do {try Vault.save(boot.token);token=boot.token} catch {notice="无法保存钥匙串凭据：\(error.localizedDescription)"}
  }
  loginItem=SMAppService.mainApp.status == .enabled
  timer=Timer.scheduledTimer(withTimeInterval:10,repeats:true){[weak self]_ in Task{@MainActor in await self?.refresh()}}
  Task { await refresh(); if UserDefaults.standard.bool(forKey:"autoRun") && !token.isEmpty {start()} }
 }
 func request(_ path:String,method:String="GET",body:[String:Any]?=nil) async throws -> Data {
  guard !token.isEmpty else{throw NSError(domain:"SimHub",code:1,userInfo:[NSLocalizedDescriptionKey:"请先在接入配置中保存客户端凭据"])}
  var req=URLRequest(url:URL(string:base+path)!);req.httpMethod=method;req.timeoutInterval=20;req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");if let body{req.httpBody=try JSONSerialization.data(withJSONObject:body);req.setValue("application/json",forHTTPHeaderField:"Content-Type")}
  let(data,res)=try await URLSession.shared.data(for:req);guard let http=res as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {let e=(try? JSONSerialization.jsonObject(with:data)) as? [String:String];throw NSError(domain:"SimHub",code:2,userInfo:[NSLocalizedDescriptionKey:e?["error"] ?? "云端请求失败"])};return data
 }
 func refresh() async {
  do {let s=try JSONDecoder().decode(Snapshot.self,from:await request("/edge/state"));if !loaded{settings=s.settings;senderText=s.settings.allowedSenders.joined(separator:"\n");loaded=true};edge=s.edge;messages=s.events;jobs=s.jobs;recordings=try JSONDecoder().decode([RecordingInfo].self,from:await request("/edge/recordings"));readLog()}catch{if !loaded{notice=error.localizedDescription}}
 }
 func save() async {
  saving=true;defer{saving=false}
  do {var v=try JSONSerialization.jsonObject(with:JSONEncoder().encode(settings)) as! [String:Any];v["allowedSenders"]=senderText.components(separatedBy:CharacterSet(charactersIn:"\n,")).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty};v["pin"]=pin;v["gotifyToken"]=gotifyToken;v["twilioToken"]=twilioToken;v["sipPassword"]=sipPassword
   settings=try JSONDecoder().decode(Settings.self,from:await request("/edge/settings",method:"PUT",body:v));pin="";gotifyToken="";twilioToken="";sipPassword="";notice="配置已保存";await refresh()
  }catch{notice=error.localizedDescription}
 }
 func importToken(){do{let t=accessToken.trimmingCharacters(in:.whitespacesAndNewlines);guard t.count>=32 else{throw NSError(domain:"SimHub",code:3,userInfo:[NSLocalizedDescriptionKey:"客户端凭据格式不正确"])};try Vault.save(t);token=t;accessToken="";loaded=false;Task{await refresh()};notice="客户端凭据已保存到钥匙串"}catch{notice=error.localizedDescription}}
 func setLoginItem(_ enabled:Bool){do{if enabled{try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()};loginItem=enabled}catch{notice=error.localizedDescription}}
 func start() {
  guard process == nil else{return}
  do {
   guard let resources=Bundle.main.resourceURL,let install=try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("installation.json"))) as? [String:String],let python=install["python"] else {throw NSError(domain:"SimHub",code:4,userInfo:[NSLocalizedDescriptionKey:"运行时安装配置缺失"])}
   try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
   let cfg=folder.appendingPathComponent("edge.json");try JSONEncoder().encode(Bootstrap(origin:base,token:token)).write(to:cfg,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:cfg.path)
   let logURL=folder.appendingPathComponent("runtime.log");if let a=try? FileManager.default.attributesOfItem(atPath:logURL.path),let size=a[.size] as? Int,size>2_000_000{try? FileManager.default.removeItem(at:logURL)}
   if !FileManager.default.fileExists(atPath:logURL.path){FileManager.default.createFile(atPath:logURL.path,contents:nil,attributes:[.posixPermissions:0o600])};let logFile=try FileHandle(forWritingTo:logURL);try logFile.seekToEnd()
   let p=Process();p.executableURL=URL(fileURLWithPath:python);p.arguments=["-u",resources.appendingPathComponent("local/supervisor.py").path,"--config",cfg.path,"--data",folder.appendingPathComponent("runtime").path];p.environment=ProcessInfo.processInfo.environment.merging(["PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]){_,new in new};p.standardOutput=logFile;p.standardError=logFile
   p.terminationHandler={[weak self]_ in Task{@MainActor in self?.running=false;self?.process=nil;self?.releaseActivity()}}
   try p.run();process=p;running=true;UserDefaults.standard.set(true,forKey:"autoRun");activity=ProcessInfo.processInfo.beginActivity(options:[.idleSystemSleepDisabled,.suddenTerminationDisabled],reason:"SIM gateway requires USB and SIP connectivity");notice="Mac 服务已启动，正在连接模块与 SIP"
  }catch{notice=error.localizedDescription}
 }
 func releaseActivity(){if let activity{ProcessInfo.processInfo.endActivity(activity);self.activity=nil}}
 func stop(persist:Bool=true){if persist{UserDefaults.standard.set(false,forKey:"autoRun")};process?.terminate();notice="正在停止服务与通话"}
 func readLog(){if let data=try? Data(contentsOf:folder.appendingPathComponent("runtime.log")){log=String(decoding:data.suffix(18000),as:UTF8.self)}}
 func recordingFile(_ r:RecordingInfo) async throws -> URL {
  var req=URLRequest(url:URL(string:base+"/edge/recordings/"+r.sid+"/audio?download")!);req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");req.timeoutInterval=300
  let (url,response)=try await URLSession.shared.download(for:req);guard let response=response as? HTTPURLResponse,response.statusCode==200 else{throw NSError(domain:"SimHub",code:5,userInfo:[NSLocalizedDescriptionKey:"录音尚未归档或下载失败"])}
  let target=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp3");try FileManager.default.moveItem(at:url,to:target);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path);return target
 }
 func stopPlayback(){player?.pause();player=nil;playing=nil;if let playbackFile{try? FileManager.default.removeItem(at:playbackFile);self.playbackFile=nil}}
 func play(_ r:RecordingInfo) async{if playing==r.sid{stopPlayback();return};stopPlayback();do{let url=try await recordingFile(r);playbackFile=url;player=AVPlayer(url:url);playing=r.sid;player?.play()}catch{notice=error.localizedDescription}}
 func download(_ r:RecordingInfo) async{let panel=NSSavePanel();panel.nameFieldStringValue=r.sid+".mp3";panel.allowedContentTypes=[.mp3];guard panel.runModal() == .OK,let target=panel.url else{return};do{let url=try await recordingFile(r);defer{try? FileManager.default.removeItem(at:url)};if FileManager.default.fileExists(atPath:target.path){try FileManager.default.removeItem(at:target)};try FileManager.default.copyItem(at:url,to:target);notice="录音已下载"}catch{notice=error.localizedDescription}}
 func deleteRecording(_ r:RecordingInfo) async{let alert=NSAlert();alert.messageText="删除这段录音？";alert.informativeText="将删除云端归档及仍存在的 Twilio 副本，无法恢复。";alert.addButton(withTitle:"删除");alert.addButton(withTitle:"取消");guard alert.runModal() == .alertFirstButtonReturn else{return};do{_ = try await request("/edge/recordings/"+r.sid,method:"DELETE");notice="录音已加入删除队列";await refresh()}catch{notice=error.localizedDescription}}
 func retryRecording(_ r:RecordingInfo) async{do{_ = try await request("/edge/recordings/"+r.sid+"/retry",method:"POST",body:[:]);notice="已安排录音重试"}catch{notice=error.localizedDescription}}
 func olderRecordings() async{guard let last=recordings.last else{return};do{let more=try JSONDecoder().decode([RecordingInfo].self,from:await request("/edge/recordings?before="+String(Int(last.created))));recordings.append(contentsOf:more.filter{r in !recordings.contains{$0.sid==r.sid}})}catch{notice=error.localizedDescription}}
 func retry() async{do{_ = try await request("/edge/notify-retry",method:"POST",body:[:]);notice="已安排重试推送"}catch{notice=error.localizedDescription}}
}
@MainActor final class AppDelegate: NSObject,NSApplicationDelegate {
 var model:Model?
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {model?.stopPlayback();model?.stop(persist:false);return .terminateNow}
 func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
}
@main struct SimHubApp: App {
 @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
 @StateObject private var model=Model()
 var body: some Scene {
  WindowGroup("Yume SIM Hub") { Content(model:model).frame(minWidth:900,minHeight:650).onAppear{delegate.model=model} }.defaultSize(width:1060,height:790)
  MenuBarExtra("SIM Hub",systemImage:model.running ? "simcard.fill":"simcard") {
   Text(model.edge.online == true ? "模块在线":"模块离线")
   Button(model.running ? "停止服务":"启动服务"){if model.running{model.stop()}else{model.start()}}
   Button("显示窗口"){NSApp.activate(ignoringOtherApps:true);NSApp.windows.first{$0.canBecomeMain}?.makeKeyAndOrderFront(nil)}
   Divider();Button("退出"){NSApp.terminate(nil)}
  }
 }
}
struct Content:View {
 @ObservedObject var model:Model
 
 var body:some View {
  VStack(alignment:.leading,spacing:20){
   HStack{VStack(alignment:.leading,spacing:4){Text("Yume SIM Hub").font(.largeTitle.bold());Text("Mac 蜂窝通信中枢").foregroundStyle(.secondary)};Spacer();Button(model.running ? "停止服务":"启动服务"){if model.running{model.stop()}else{model.start()}}.buttonStyle(.borderedProminent).tint(model.running ? .orange:.accentColor)}
   HStack(spacing:12){status("模块",model.edge.online == true ? "在线":"离线",model.edge.online == true);status("音频",model.edge.voiceReady == true ? "就绪":"未就绪",model.edge.voiceReady == true);status("SIP",model.edge.sipRegistered == true ? "已注册":"未注册",model.edge.sipRegistered == true);status("通话",model.edge.busy == true ? "使用中":"空闲",model.edge.busy != true)}
   if !model.notice.isEmpty {Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)}
   TabView{
    Form {
     Section("电话路由") {
      TextField("SIM 来电转接号码",text:$model.settings.forwardTo)
      Toggle("启用 SIM 来电 → Twilio → 目标号码",isOn:$model.settings.inboundEnabled)
      SecureField(model.settings.pinConfigured ? "电话密码（已设置，留空保持）":"电话密码（6–12 位数字）",text:$model.pin)
      Toggle("启用 Twilio 密码验证 → SIM 外呼",isOn:$model.settings.outboundEnabled)
      Text("拨打 +12025550124 → 密码 + # → 含国家码的号码 + #").font(.caption).foregroundStyle(.secondary)
     }
     Section("Gotify 短信推送") {TextField("服务地址",text:$model.settings.gotifyUrl);SecureField(model.settings.gotifyConfigured ? "应用 token（已配置，留空保持）":"应用 token",text:$model.gotifyToken)}
     Section("邮件发送短信") {Toggle("启用邮件发送短信",isOn:$model.settings.emailEnabled);Text("sms@example.com · 主题为 +国际号码，纯文本正文为短信内容").font(.caption).textSelection(.enabled);TextField("允许的发件人（逗号分隔）",text:$model.senderText);Text("要求 Cloudflare 验证 DMARC 通过；Mac 离线时任务会排队。").font(.caption).foregroundStyle(.secondary)}
     HStack{Button("保存配置"){Task{await model.save()}}.buttonStyle(.borderedProminent).disabled(model.saving);Spacer();Text(model.edge.operator ?? "").font(.caption)}
    }.formStyle(.grouped).tabItem{Label("配置",systemImage:"slider.horizontal.3")}.tag(0)
    records(model.messages,inbox:true).tabItem{Label("短信收件箱",systemImage:"message")}.tag(1)
    records(model.jobs,inbox:false).tabItem{Label("发送与通话",systemImage:"clock")}.tag(2)
    VStack {
     List(model.recordings){r in
      VStack(alignment:.leading,spacing:8){
       HStack{Text(r.sid).font(.system(.caption,design:.monospaced)).textSelection(.enabled);Spacer();Text(r.status).font(.caption)}
       Text("\(Date(timeIntervalSince1970:r.created/1000).formatted()) · \(Int(r.duration)) 秒 · \(ByteCountFormatter.string(fromByteCount:Int64(r.size),countStyle:.file))").font(.caption).foregroundStyle(.secondary)
       HStack{Button(model.playing==r.sid ? "停止播放":"播放"){Task{await model.play(r)}}.disabled(!["archived","purge"].contains(r.status));Button("下载"){Task{await model.download(r)}}.disabled(!["archived","purge"].contains(r.status));Button("重试"){Task{await model.retryRecording(r)}};Spacer();Button("删除",role:.destructive){Task{await model.deleteRecording(r)}}}
      }.padding(.vertical,8)
     }
     HStack{Text("录音从振铃到挂断 · 双声道 · R2 simhub/ 加密归档").font(.caption).foregroundStyle(.secondary);Spacer();Button("更早录音"){Task{await model.olderRecordings()}}}
    }.padding(12).tabItem{Label("通话录音",systemImage:"waveform")}.tag(4)
    Form {
     Section("Twilio / SIP") {SecureField("Twilio Auth Token（留空保持）",text:$model.twilioToken);TextField("SIP 域名",text:$model.settings.sipDomain);TextField("SIP 用户名",text:$model.settings.sipUser);SecureField("SIP 密码（留空保持）",text:$model.sipPassword);Button("保存接入配置"){Task{await model.save()}}}
     Section("本机") {Toggle("登录 Mac 后启动",isOn:Binding(get:{model.loginItem},set:{model.setLoginItem($0)}));Text("关闭窗口会继续运行；退出客户端会停止模块服务。运行时防止 Mac 自动睡眠。").font(.caption);SecureField("客户端凭据（保存在钥匙串）",text:$model.accessToken);Button("保存客户端凭据"){model.importToken()}}
     Section("运行日志") {ScrollView{Text(model.log.isEmpty ? "暂无日志":model.log).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(height:190)}
    }.formStyle(.grouped).tabItem{Label("接入与运行",systemImage:"network")}.tag(3)
   }
   HStack{Text("worker.example.com · 配置仅在客户端访问").font(.caption).foregroundStyle(.secondary);Spacer();Button("刷新"){Task{await model.refresh()}}}
  }.padding(24)
 }
 func status(_ title:String,_ value:String,_ good:Bool)->some View{VStack(alignment:.leading,spacing:8){Text(title).font(.caption).foregroundStyle(.secondary);Label(value,systemImage:good ? "checkmark.circle.fill":"circle.dashed").foregroundStyle(good ? .green:.secondary)}.frame(maxWidth:.infinity,alignment:.leading).padding(14).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:12))}
 func records(_ rows:[Record],inbox:Bool)->some View{VStack{if inbox{HStack{Spacer();Button("重试待推送短信"){Task{await model.retry()}}}};List(rows){r in VStack(alignment:.leading,spacing:8){HStack{Text(r.data[inbox ? "from":"to"] ?? r.data["from"] ?? "来电").font(.headline);Spacer();Text(inbox ? (r.notified == 1 ? "已推送":"待推送"):(r.status ?? "")).font(.caption)};if let body=r.data["body"]{Text(body).textSelection(.enabled)};Text(Date(timeIntervalSince1970:r.created/1000).formatted()).font(.caption).foregroundStyle(.secondary);if let result=r.result{Text(result).font(.caption).foregroundStyle(.secondary)}}.padding(.vertical,8)};if rows.isEmpty{Text("暂无记录").foregroundStyle(.secondary)};if !inbox{Text("unknown = 提交结果不明确，系统不会自动重发；sent = 模块已接受，非运营商送达回执。").font(.caption).foregroundStyle(.secondary)}}.padding(12)}
}
