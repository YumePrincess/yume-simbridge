import AppKit
import SwiftUI

/// Measures each column at its actual width, then proposes the tallest height to all cards.
struct EqualHeightRow: Layout {
  var spacing: CGFloat = 16
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard !subviews.isEmpty else { return .zero }
    let width = proposal.width ?? 760
    let column = max(0, (width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
    let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
    return CGSize(width: width, height: height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard !subviews.isEmpty else { return }
    let column = max(0, (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
    for (index, view) in subviews.enumerated() {
      view.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (column + spacing), y: bounds.minY),
        anchor: .topLeading, proposal: ProposedViewSize(width: column, height: bounds.height))
    }
  }
}

struct HubLogo: View {
  var size: CGFloat = 84
  var body: some View {
    if let url = Bundle.main.url(forResource: "SimHubLogo", withExtension: "png"), let image = NSImage(contentsOf: url) {
      Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
  }
}

struct AppearancePicker: View {
  @ObservedObject var model: Model
  var body: some View {
    Picker(L("外观"), selection: $model.appearance) {
      Text(L("跟随系统")).tag("system")
      Text(L("浅色")).tag("light")
      Text(L("深色")).tag("dark")
    }
  }
}

struct AboutView: View {
  @ObservedObject var model: Model
  @Environment(\.dismiss) private var dismiss
  private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "27.2.0" }
  private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
  var body: some View {
    VStack(spacing: 24) {
      HubLogo(size: 100)
      VStack(spacing: 8) {
        Text("Yume SIM Hub").font(.system(size: 26, weight: .bold, design: .rounded))
        Text(L("Mac 蜂窝通信中枢")).font(.callout).foregroundStyle(.secondary)
        Text(L("连接实体 SIM，让通话与消息自在流转。"))
          .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      HStack(spacing: 20) {
        detail("版本", value: version, note: "Build " + build)
        Divider().frame(height: 48)
        detail("平台", value: "Apple Silicon", note: "macOS 26+ · arm64")
      }.padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
      Text(L("版权所有 © 2026 Yume Internet LLC. 保留所有权利。"))
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }.padding(32).padding(.top, 16).frame(width: 480)
      .background(Color(nsColor: .windowBackgroundColor))
      .overlay(alignment: .topTrailing) {
        Button { dismiss() } label: {
          Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 30, height: 30)
        }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
          .accessibilityLabel(L("关闭")).padding(14)
      }
  }
  private func detail(_ title: String, value: String, note: String) -> some View {
    VStack(spacing: 6) {
      Text(L(title)).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.callout.weight(.semibold)).monospacedDigit()
      Text(note).font(.caption.monospaced()).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity).textSelection(.enabled)
  }
}
