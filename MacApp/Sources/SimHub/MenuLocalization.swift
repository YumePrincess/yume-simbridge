import AppKit

@MainActor enum ClientLanguage {
  static let supported = ["en", "fr", "ja", "zh-Hans", "zh-Hant"]
  static func normalize(_ value: String) -> String? {
    if value.hasPrefix("zh-Hant") || value.hasPrefix("zh-TW") || value.hasPrefix("zh-HK") {
      return "zh-Hant"
    }
    if value.hasPrefix("zh") { return "zh-Hans" }
    for code in ["en", "fr", "ja"] where value.hasPrefix(code) { return code }
    return nil
  }
  static func current() -> String {
    if let preferred = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first,
      let language = normalize(preferred)
    {
      return language
    }
    return UserDefaults.standard.string(forKey: "clientLanguage") ?? "zh-Hans"
  }
}
@MainActor enum MenuLocalization {
  // Use the same live AppKit translation strategy as Yume Life After.
  static let titles: [String: [String: String]] = [
    "File": ["fr": "Fichier", "ja": "ファイル", "zh-Hans": "文件", "zh-Hant": "檔案"],
    "Edit": ["fr": "Édition", "ja": "編集", "zh-Hans": "编辑", "zh-Hant": "編輯"],
    "View": ["fr": "Présentation", "ja": "表示", "zh-Hans": "显示", "zh-Hant": "檢視"],
    "Window": ["fr": "Fenêtre", "ja": "ウインドウ", "zh-Hans": "窗口", "zh-Hant": "視窗"],
    "Help": ["fr": "Aide", "ja": "ヘルプ", "zh-Hans": "帮助", "zh-Hant": "說明"],
    "Settings…": ["fr": "Réglages…", "ja": "設定…", "zh-Hans": "设置…", "zh-Hant": "設定…"],
    "Close Window": [
      "fr": "Fermer la fenêtre", "ja": "ウインドウを閉じる", "zh-Hans": "关闭窗口", "zh-Hant": "關閉視窗",
    ],
    "New Window": [
      "fr": "Nouvelle fenêtre", "ja": "新規ウインドウ", "zh-Hans": "新建窗口", "zh-Hant": "新增視窗",
    ],
    "Undo": ["fr": "Annuler", "ja": "取り消す", "zh-Hans": "撤销", "zh-Hant": "還原"],
    "Redo": ["fr": "Rétablir", "ja": "やり直す", "zh-Hans": "重做", "zh-Hant": "重做"],
    "Cut": ["fr": "Couper", "ja": "カット", "zh-Hans": "剪切", "zh-Hant": "剪下"],
    "Copy": ["fr": "Copier", "ja": "コピー", "zh-Hans": "复制", "zh-Hant": "複製"],
    "Paste": ["fr": "Coller", "ja": "ペースト", "zh-Hans": "粘贴", "zh-Hant": "貼上"],
    "Select All": ["fr": "Tout sélectionner", "ja": "すべてを選択", "zh-Hans": "全选", "zh-Hant": "全選"],
    "Minimize": ["fr": "Réduire", "ja": "しまう", "zh-Hans": "最小化", "zh-Hant": "縮小"],
    "Zoom": ["fr": "Zoom", "ja": "拡大／縮小", "zh-Hans": "缩放", "zh-Hant": "縮放"],
    "Bring All to Front": [
      "fr": "Tout ramener au premier plan", "ja": "すべてを手前に移動", "zh-Hans": "全部前置",
      "zh-Hant": "全部移到最前面",
    ],
    "Enter Full Screen": [
      "fr": "Activer le mode plein écran", "ja": "フルスクリーンにする", "zh-Hans": "进入全屏幕",
      "zh-Hant": "進入全螢幕",
    ],
    "Exit Full Screen": [
      "fr": "Quitter le mode plein écran", "ja": "フルスクリーンを解除", "zh-Hans": "退出全屏幕",
      "zh-Hant": "離開全螢幕",
    ],
    "Hide Yume SIM Hub": [
      "fr": "Masquer Yume SIM Hub", "ja": "Yume SIM Hub を非表示", "zh-Hans": "隐藏 Yume SIM Hub",
      "zh-Hant": "隱藏 Yume SIM Hub",
    ],
    "Hide Others": [
      "fr": "Masquer les autres", "ja": "ほかを非表示", "zh-Hans": "隐藏其他", "zh-Hant": "隱藏其他",
    ],
    "Show All": ["fr": "Tout afficher", "ja": "すべてを表示", "zh-Hans": "全部显示", "zh-Hant": "顯示全部"],
    "Quit Yume SIM Hub": [
      "fr": "Quitter Yume SIM Hub", "ja": "Yume SIM Hub を終了", "zh-Hans": "退出 Yume SIM Hub",
      "zh-Hant": "結束 Yume SIM Hub",
    ],
    "About Yume SIM Hub": [
      "fr": "À propos de Yume SIM Hub", "ja": "Yume SIM Hub について", "zh-Hans": "关于 Yume SIM Hub",
      "zh-Hant": "關於 Yume SIM Hub",
    ],
  ]
  private static var applying = false
  private static var observers: [NSObjectProtocol] = []
  static func install() {
    for name in [
      NSMenu.didChangeItemNotification, NSMenu.didAddItemNotification,
      NSApplication.didBecomeActiveNotification,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { apply(language: ClientLanguage.current()) }
        })
    }
    apply(language: ClientLanguage.current())
  }
  static func apply(language: String) {
    guard !applying else { return }
    applying = true
    defer { applying = false }
    guard let menu = NSApp.mainMenu else { return }
    for item in menu.items { apply(item, language: language, top: true) }

  }
  private static func apply(_ item: NSMenuItem, language: String, top: Bool) {
    let key = titles.keys.first {
      $0 == item.title || titles[$0]?.values.contains(item.title) == true
        || ["顯示方式": "View", "輔助說明": "Help"][item.title] == $0
    }
    if let key {
      let title = language == "en" ? key : titles[key]?[language] ?? key
      if item.title != title { item.title = title }
      if top && item.attributedTitle?.string != title {
        item.attributedTitle = NSAttributedString(
          string: title, attributes: [.font: NSFont.menuBarFont(ofSize: NSFont.systemFontSize)])
      }
      if item.submenu?.title != title { item.submenu?.title = title }
    }
    item.submenu?.items.forEach { apply($0, language: language, top: false) }
  }
}
