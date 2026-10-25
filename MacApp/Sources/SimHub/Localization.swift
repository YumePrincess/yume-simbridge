import Foundation

@MainActor enum Localization {
  static let entries: [String: [String: String]] = {
    guard let url = Bundle.main.url(forResource: "Translations", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let value = try? JSONDecoder().decode([String: [String: String]].self, from: data)
    else { return [:] }
    return value
  }()
  static let states = [
    "queued": "排队中", "running": "处理中", "sent": "已发送", "submitted": "结果不明确", "unknown": "结果不明确",
    "failed": "失败", "pending": "待归档", "archiving": "正在归档", "archived": "归档完成", "purge": "正在清理源副本",
    "deleting": "正在删除", "deleted": "已删除", "claimed": "已领取", "connected": "已接通", "ended": "已结束",
    "expired": "已过期",
  ]
}
@MainActor func L(_ key: String) -> String {
  let candidate = Localization.states[key] ?? key
  let source =
    Localization.entries[candidate] != nil
    ? candidate
    : Localization.entries.first(where: { $0.value.values.contains(candidate) })?.key ?? candidate
  let language = ClientLanguage.current()
  return language == "zh-Hans" ? source : Localization.entries[source]?[language] ?? source
}

@MainActor func localizedLog(_ text: String) -> String {
  text.components(separatedBy: "\n").map { line in
    if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
      let prefix = String(line[...end])
      return prefix + " "
        + L(String(line[line.index(after: end)...]).trimmingCharacters(in: .whitespaces))
    }
    return L(line)
  }.joined(separator: "\n")
}
