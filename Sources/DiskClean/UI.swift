import SwiftUI

final class Model: ObservableObject {
    @Published var results: [ScanResult] = []
    @Published var selected: Set<String> = []
    @Published var expanded: Set<String> = []
    @Published var scanning = false
    @Published var cleaning = false
    @Published var disk = DiskSpace.current()
    @Published var message: String?
    @Published var error: String?
    @Published var advice: AIAdvisor.Advice?
    @Published var advising: String?
    var engine: Engine?

    init() {
        do { engine = Engine(rules: try Rules.load()) } catch { self.error = error.localizedDescription }
    }

    var protectedList: [(path: String, reason: String)] {
        engine?.rules.protected.map { ($0.path, $0.reason) } ?? []
    }

    var selectedResults: [ScanResult] { results.filter { selected.contains($0.id) && $0.cleanable } }
    var selectedTotal: Int64 { selectedResults.reduce(0) { $0 + $1.total } }

    func scan() {
        guard let engine, !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = engine.scanAll()
            DispatchQueue.main.async {
                self.results = r
                // 默认只勾 safe；review 要用户自己勾
                self.selected = Set(r.filter { $0.category.risk == .safe && $0.cleanable && $0.total > 0 }.map(\.id))
                self.disk = DiskSpace.current()
                self.scanning = false
            }
        }
    }

    /// 让装好的 AI 在后台看扫描结果，按建议勾好
    func askAI(_ b: AIAdvisor.Backend) {
        guard advising == nil else { return }
        advising = b.name
        message = nil
        let snapshot = results
        DispatchQueue.global(qos: .userInitiated).async {
            let r = AIAdvisor.ask(b, results: snapshot)
            DispatchQueue.main.async {
                self.advising = nil
                switch r {
                case .success(let a):
                    self.advice = a
                    let pick = self.results.filter { a.items[$0.id]?.verdict == .clean && $0.cleanable && $0.category.risk != .report }.map(\.id)
                    self.selected = Set(pick)
                    self.message = pick.isEmpty ? "\(a.backend) 觉得暂时没有必须清的" : "已按 \(a.backend) 的建议勾好 \(pick.count) 项，看过没问题就点清理"
                case .failure(let e):
                    self.message = e.localizedDescription
                }
            }
        }
    }

    func clean() {
        guard let engine else { return }
        let targets = selectedResults
        cleaning = true
        let before = DiskSpace.current()?.free ?? 0
        DispatchQueue.global(qos: .userInitiated).async {
            let rep = engine.clean(targets)
            let after = DiskSpace.current()?.free ?? 0
            DispatchQueue.main.async {
                self.cleaning = false
                var m = "已清理 \(rep.removed) 项，可用空间 \(fmtSize(before)) → \(fmtSize(after))"
                if !rep.failures.isEmpty { m += "（\(rep.failures.count) 项正在使用或无权限，已跳过）" }
                self.message = m
                self.scan()
            }
        }
    }
}

// MARK: 雾状玻璃

/// 窗口背后的系统模糊
struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        DispatchQueue.main.async {
            v.window?.isOpaque = false
            v.window?.backgroundColor = .clear
            v.window?.titlebarAppearsTransparent = true
            v.window?.isMovableByWindowBackground = true
        }
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// 背景不带颜色：只有系统模糊 + 一层很淡的白雾
struct FogBackground: View {
    var body: some View {
        ZStack {
            WindowBlur()
            LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

extension Color {
    /// 浅色 / 深色模式各用一个值
    init(light: UInt32, dark: UInt32) {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
}

/// 定稿配色：界面只有墨黑（跟随系统文字色）和红（只用在「绝对不碰」）；
/// 图表用 dataviz 验证过的分类色盘前五位，深色模式用它配好的深色档
enum Palette {
    static let ink = Color.primary
    static let onInk = Color(nsColor: .windowBackgroundColor)
    static let stop = Color(light: 0xd93025, dark: 0xff6b5e)
    static let chart: [Color] = [
        Color(light: 0x2a78d6, dark: 0x3987e5),
        Color(light: 0xeb6834, dark: 0xd95926),
        Color(light: 0x1baf7a, dark: 0x199e70),
        Color(light: 0xeda100, dark: 0xc98500),
        Color(light: 0xe87ba4, dark: 0xd55181),
    ]
    static let chartOther = Color(light: 0xc9c8c4, dark: 0x4a4a48)
    static let track = Color.primary.opacity(0.07)
}

func gb(_ b: Int64) -> String { String(format: "%.1f", Double(b) / 1e9) }

// MARK: 主界面

enum Tab: String, CaseIterable { case clean = "清理", ai = "AI 占用", space = "空间占用", log = "记录" }

struct ContentView: View {
    @StateObject var m = Model()
    @StateObject var tm = TreemapModel()
    @StateObject var ai = AIModel()
    @State var modelToDelete: LocalModel?
    @State var tab = Tab.clean
    @State var confirming = false
    @State var showProtected = false
    @State var showAlert = false
    @State var watch = Watch.settings
    @State var customGB = ""
    @AppStorage("aiBackend") var aiBackend = ""
    @AppStorage("aiCustomCommand") var aiCustomCommand = ""
    @State var showCustomAI = false
    @State var customDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let e = m.error {
                Text("规则文件读取失败：\(e)").padding(.top, 22)
                Spacer()
            } else if tab == .clean {
                advicePanel.padding(.top, 16)
                table.padding(.top, 18)
                footer.padding(.top, 14)
            } else if tab == .ai {
                aiTable.padding(.top, 18)
                if let msg = m.message { Text(msg).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.top, 10) }
            } else if tab == .log {
                logTable.padding(.top, 18)
            } else {
                TreemapView(m: tm).padding(.top, 22)
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 16)
        .padding(.bottom, 26)
        .frame(minWidth: 760, minHeight: 680)
        .background(FogBackground())
        .onAppear { m.scan(); tm.start(); ai.load() }
        .onChange(of: m.cleaning) { _, busy in if !busy { ai.load() } }
        .confirmationDialog("确认清理？", isPresented: $confirming) {
            Button("清理 \(fmtSize(m.selectedTotal))", role: .destructive) { m.clean() }
            Button("取消", role: .cancel) {}
        } message: {
            let names = m.selectedResults.map(\.category.name).joined(separator: "、")
            let review = m.selectedResults.contains { $0.category.risk == .review }
            Text("将清理：\(names)\(review ? "\n\n其中包含需要确认的项目，删除后无法恢复。" : "")")
        }
    }

    // MARK: 顶部：超细大号可用空间 + 分段储存横条

    var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        eyebrow("可用空间")
                        if lowSpace {
                            Text("低于提醒线 \(Watch.fmtGB(watch.lowSpaceGB)) GB").font(.system(size: 11)).foregroundStyle(Palette.stop)
                        }
                    }
                    if let d = m.disk {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(gb(d.free)).font(.system(size: 72, weight: .ultraLight)).monospacedDigit().tracking(-2)
                            Text("GB / \(gb(d.total))").font(.system(size: 22)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                HStack(spacing: 22) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Button { tab = t } label: {
                            VStack(spacing: 3) {
                                Text(t.rawValue).font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                                    .foregroundStyle(tab == t ? .primary : .tertiary)
                                Rectangle().fill(tab == t ? Palette.ink : .clear).frame(height: 2)
                            }
                            .fixedSize()
                        }
                        .buttonStyle(.plain)
                    }
                    Button { m.scan(); tm.start(); ai.load() } label: {
                        if m.scanning || tm.scanning { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).frame(width: 16)
                    .disabled(m.scanning || m.cleaning || tm.scanning).help("重新扫描")
                    Button { watch = Watch.settings; customGB = ""; showAlert = true } label: {
                        Image(systemName: watch.enabled ? "bell.fill" : "bell")
                    }
                    .buttonStyle(.plain).foregroundStyle(lowSpace ? AnyShapeStyle(Palette.stop) : AnyShapeStyle(.tertiary)).frame(width: 16)
                    .help("空间不足提醒")
                    .popover(isPresented: $showAlert, arrowEdge: .bottom) { alertSettings }
                }
                .padding(.top, 2)
            }
            if let d = m.disk {
                capacityBar(d).padding(.top, 20)
                keys(d).padding(.top, 9)
            }
        }
    }

    var lowSpace: Bool { watch.enabled && (m.disk?.free ?? .max) < Int64(watch.lowSpaceGB * 1e9) }

    // MARK: 空间不足提醒设置：常用档位 + 自定义

    var alertSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("可用空间不足时提醒我", isOn: Binding(get: { watch.enabled }, set: { on in
                m.message = on ? Watch.enable(watch.lowSpaceGB) : Watch.disable()
                watch = Watch.settings
            }))
            .toggleStyle(.switch).font(.system(size: 13, weight: .medium))
            VStack(alignment: .leading, spacing: 8) {
                eyebrow("低于多少 GB 时提醒")
                HStack(spacing: 6) {
                    ForEach([10.0, 20, 50, 100], id: \.self) { v in
                        Button { setLine(v) } label: {
                            Text("\(Watch.fmtGB(v))").font(.system(size: 12)).frame(width: 40, height: 24)
                                .foregroundStyle(watch.lowSpaceGB == v ? Palette.onInk : Palette.ink)
                                .background(watch.lowSpaceGB == v ? Palette.ink : .clear)
                                .overlay(Rectangle().strokeBorder(Palette.ink.opacity(0.4), lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("自定义", text: $customGB).textFieldStyle(.roundedBorder).frame(width: 64)
                        .onSubmit { if let v = Double(customGB), v > 0 { setLine(v) } }
                    Text("GB").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("当前：\(Watch.fmtGB(watch.lowSpaceGB)) GB。自定义数字输完按回车。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("开启后每 30 分钟在后台检查一次，只发通知，不会自动删除任何东西。同一次空间变少只提醒一次，再少 5 GB 或隔一天才会再提醒。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(width: 330)
    }

    func setLine(_ v: Double) {
        var s = Watch.settings
        s.lowSpaceGB = v
        Watch.save(s, Watch.settingsPath)
        if s.enabled { m.message = Watch.enable(v) }
        watch = Watch.settings
        customGB = ""
    }

    func capacityBar(_ d: DiskSpace) -> some View {
        GeometryReader { g in
            let w = g.size.width
            let segs: [(Color, Int64)] = tm.usage.isEmpty
                ? [(Palette.chartOther, d.total - d.free)]
                : tm.usage.enumerated().map { (Palette.chart[$0.offset], $0.element.size) }
            HStack(spacing: 2) {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(s.0).frame(width: max(w * CGFloat(Double(s.1) / Double(max(d.total, 1))) - 2, 0))
                }
                Rectangle().fill(Palette.track)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .frame(height: 10)
        .animation(.easeOut(duration: 0.3), value: tm.usage.count)
    }

    func keys(_ d: DiskSpace) -> some View {
        HStack(spacing: 16) {
            if tm.usage.isEmpty {
                key(Palette.chartOther, "已用 \(gb(d.total - d.free)) GB · 正在分类…")
            } else {
                ForEach(Array(tm.usage.enumerated()), id: \.offset) { i, u in key(Palette.chart[i], "\(u.name) \(gb(u.size)) GB") }
            }
            key(Palette.track, "剩余 \(gb(d.free)) GB")
        }
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
    }

    func key(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            Text(s).monospacedDigit()
        }
    }

    func eyebrow(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).tracking(1.3).foregroundStyle(.secondary)
    }

    // MARK: 清理表格：左列写级别，不套卡片

    var table: some View {
        ScrollView {
            VStack(spacing: 0) {
                if m.results.isEmpty && m.scanning {
                    HStack { ProgressView().controlSize(.small); Text("正在扫描…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(30)
                }
                group(.safe, "可放心清理")
                group(.review, "需要确认")
                group(.report, "只提醒")
                protectedRow
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    func group(_ risk: Risk, _ title: String) -> some View {
        let all = m.results.filter { $0.category.risk == risk }
        let items = all.filter { $0.total > 0 || !$0.notes.isEmpty }
        let empty = all.count - items.count
        if !all.isEmpty {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, r in
                row(r, label: i == 0 ? title : "")
            }
            if empty > 0 {
                line(label: items.isEmpty ? title : "") {
                    Text(items.isEmpty ? "都很干净" : "另有 \(empty) 项已经很干净").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 表格的一行：级别列 112 + 勾选列 26 + 内容
    func line<C: View>(label: String, labelColor: Color = .secondary.opacity(0.7), @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Text(label).font(.system(size: 11)).tracking(0.9).foregroundStyle(labelColor)
                    .frame(width: 112, alignment: .leading).padding(.top, 2)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
        }
    }

    func checkbox(_ on: Bool) -> some View {
        ZStack {
            Rectangle().fill(on ? Palette.ink : .clear)
            Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5)
            if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Palette.onInk) }
        }
        .frame(width: 14, height: 14)
    }

    func row(_ r: ScanResult, label: String) -> some View {
        let c = r.category
        let on = m.selected.contains(r.id)
        let isOpen = m.expanded.contains(r.id)
        return line(label: label) {
            Group {
                if c.risk == .report {
                    Color.clear.frame(width: 14, height: 14)
                } else {
                    // 空心方框中间是透明的，要给整块区域加点击范围，否则只有 1.5px 的边框能点到
                    Button { if on { m.selected.remove(r.id) } else { m.selected.insert(r.id) } } label: {
                        checkbox(on).padding(6).contentShape(Rectangle())
                    }
                    .padding(-6)
                        .buttonStyle(.plain).disabled(!r.cleanable).opacity(r.cleanable ? 1 : 0.3)
                }
            }
            .frame(width: 26, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name).font(.system(size: 13))
                    if c.action == .trash {
                        Text("移到废纸篓").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).overlay(Rectangle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                    }
                }
                Text(c.description).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let a = m.advice?.items[r.id] { adviceLine(a) }
                if isOpen { details(r).padding(.top, 6) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if isOpen { m.expanded.remove(r.id) } else { m.expanded.insert(r.id) } }
            .help(isOpen ? "收起" : "点击查看具体文件")
            Spacer(minLength: 16)
            Text(c.action == .command && r.toolPath == nil ? "未安装" : fmtSize(r.total))
                .font(.system(size: 13)).monospacedDigit()
                .foregroundStyle(on ? .primary : .secondary)
                .frame(width: 90, alignment: .trailing)
        }
    }

    func details(_ r: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let tip = r.category.tip { Text(tip).font(.caption).foregroundStyle(.secondary) }
            ForEach(r.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            ForEach(r.items.prefix(15)) { it in
                HStack {
                    Text(it.path.replacingOccurrences(of: home, with: "~"))
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(fmtSize(it.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.selectFile(it.path, inFileViewerRootedAtPath: "") } label: {
                        Image(systemName: "magnifyingglass")
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("在访达中显示")
                }
            }
            if r.items.count > 15 { Text("…还有 \(r.items.count - 15) 项").font(.caption).foregroundStyle(.secondary) }
        }
    }

    var protectedRow: some View {
        line(label: "绝对不碰", labelColor: Palette.stop) {
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Palette.stop)
                .frame(width: 26, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(m.protectedList.count) 个位置").font(.system(size: 13))
                Text("文稿、照片、iCloud、钥匙串、聊天记录……任何情况下都不会删除").font(.system(size: 11.5)).foregroundStyle(.secondary)
                if showProtected {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(m.protectedList, id: \.path) { p in
                            HStack(alignment: .firstTextBaseline) {
                                Text(p.path).font(.caption.monospaced()).frame(width: 230, alignment: .leading)
                                Text(p.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            Spacer(minLength: 16)
            Button(showProtected ? "收起" : "查看") { withAnimation(.easeOut(duration: 0.18)) { showProtected.toggle() } }
                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .trailing)
        }
    }

    // MARK: 底部

    var footer: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let msg = m.message { Text(msg).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.bottom, 6) }
                eyebrow(m.selectedResults.isEmpty ? "未选择" : "已选 \(m.selectedResults.count) 项")
                Text(fmtSize(m.selectedTotal)).font(.system(size: 30, weight: .light)).monospacedDigit()
            }
            Spacer()
            if m.cleaning { ProgressView().controlSize(.small).padding(.trailing, 8) }
            aiPicker.padding(.trailing, 8)
            // 有可用的 AI 就在阿扫里直接出建议；没有就把扫描结果复制给网页版 AI
            Button {
                if let b = currentAI { m.askAI(b) }
                else {
                    m.message = "正在扫描…"
                    AIHandoff.copyScanReport { m.message = "这台电脑上没找到可用的 AI。" + $0 }
                }
            } label: {
                Text(m.advising == nil ? "让 AI 帮我看" : "AI 正在看…")
                    .font(.system(size: 13, weight: .medium)).tracking(0.6).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .overlay(Rectangle().stroke(Palette.ink, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(m.advising != nil || m.scanning || m.results.isEmpty)
            .help("AI 看一遍扫描结果，告诉你哪些能清、哪些别动，并帮你勾好。它只看不删")
            .padding(.trailing, 10)
            Button { confirming = true } label: {
                Text("清理").font(.system(size: 13, weight: .medium)).tracking(0.6).foregroundStyle(Palette.onInk)
                    .padding(.horizontal, 30).padding(.vertical, 10)
                    .background(Palette.ink)
            }
            .buttonStyle(.plain)
            .disabled(m.selectedResults.isEmpty || m.scanning || m.cleaning)
            .opacity(m.selectedResults.isEmpty || m.scanning || m.cleaning ? 0.35 : 1)
        }
    }
}

struct DiskCleanApp: App {
    var body: some Scene {
        WindowGroup("阿扫") { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
    }
}
