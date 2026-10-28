import SwiftUI

/// 「AI 占用」页和「记录」页的数据
final class AIModel: ObservableObject {
    @Published var usage: [AIUsageEntry] = []
    @Published var models: [LocalModel] = []
    @Published var growth: [Growth.Grower] = []
    @Published var activity: [Activity.Entry] = []
    @Published var loading = false
    @Published var expanded: Set<String> = []
    @Published var deleting: String?

    func load() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let u = AIUsage.scan(), ms = ModelStore.scan(), g = Growth.top(), a = Activity.load()
            DispatchQueue.main.async {
                self.usage = u; self.models = ms; self.growth = g; self.activity = a; self.loading = false
            }
        }
    }

    func reloadActivity() { activity = Activity.load() }

    func delete(_ m: LocalModel, _ mode: ModelStore.DeleteMode, done: @escaping (String) -> Void) {
        deleting = m.id
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ModelStore.delete(m, mode: mode)
            DispatchQueue.main.async {
                self.deleting = nil
                done(r.message)
                self.load()
            }
        }
    }
}

extension ContentView {
    // MARK: 选哪个 AI：装了的命令行 AI + 自定义命令

    var aiChoices: [AIAdvisor.Backend] { AIAdvisor.installed + [AIAdvisor.custom(aiCustomCommand)].compactMap { $0 } }
    var currentAI: AIAdvisor.Backend? { aiChoices.first { $0.id == aiBackend } ?? aiChoices.first }

    var aiPicker: some View {
        Menu {
            ForEach(aiChoices) { b in
                Button { aiBackend = b.id } label: {
                    if b.id == currentAI?.id { Label(b.shellCommand ?? b.name, systemImage: "checkmark") } else { Text(b.shellCommand ?? b.name) }
                }
            }
            if !aiChoices.isEmpty { Divider() }
            Button(aiCustomCommand.isEmpty ? "自定义命令…" : "修改自定义命令…") { customDraft = aiCustomCommand; showCustomAI = true }
        } label: {
            HStack(spacing: 3) {
                Text(currentAI.map { "用 \($0.name)" } ?? "选择 AI").font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("选择用哪个 AI 来看扫描结果")
        .popover(isPresented: $showCustomAI, arrowEdge: .top) { customAIEditor }
    }

    var customAIEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("自定义 AI 命令").font(.system(size: 13, weight: .medium))
            TextField("比如 ollama run qwen3:8b", text: $customDraft).textFieldStyle(.roundedBorder)
            Text("阿扫会把提示词从标准输入传给这条命令，并读取它打印的回答。可以用本地模型完全离线，例如 ollama run qwen3:8b；也可以用 gemini -p 之类的命令行 AI。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !aiCustomCommand.isEmpty {
                    Button("删除") { aiCustomCommand = ""; if aiBackend == "custom" { aiBackend = "" }; showCustomAI = false }
                }
                Spacer()
                Button("取消") { showCustomAI = false }
                Button("保存并使用") {
                    aiCustomCommand = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !aiCustomCommand.isEmpty { aiBackend = "custom" }
                    showCustomAI = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 360)
    }

    // MARK: AI 建议（清理页顶部）

    @ViewBuilder
    var advicePanel: some View {
        if let who = m.advising {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("\(who) 正在看扫描结果，大约 10–30 秒。它只看不删。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let a = m.advice {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    eyebrow("AI 建议 · \(a.backend)")
                    Spacer()
                    Button { m.advice = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("收起 AI 建议")
                }
                Text(a.summary).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text("建议清理的已帮你勾好，最后由你决定。").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) { Rectangle().fill(Palette.ink).frame(width: 2) }
        }
    }

    func adviceLine(_ a: AIAdvisor.Advice.Item) -> some View {
        let tag = ["clean": "AI：建议清", "review": "AI：你看一眼", "keep": "AI：先别动"][a.verdict.rawValue] ?? ""
        return HStack(spacing: 6) {
            Text(tag).font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(a.verdict == .clean ? Palette.onInk : Palette.ink)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(a.verdict == .clean ? Palette.ink : .clear)
                .overlay(Rectangle().strokeBorder(Palette.ink.opacity(a.verdict == .clean ? 0 : 0.4), lineWidth: 0.5))
            Text(a.reason).font(.system(size: 11.5)).foregroundStyle(.primary.opacity(0.8))
        }
        .padding(.top, 3)
    }

    // MARK: AI 占用

    var aiTable: some View {
        ScrollView {
            VStack(spacing: 0) {
                if ai.usage.isEmpty && ai.loading {
                    HStack { ProgressView().controlSize(.small); Text("正在统计…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(30)
                }
                growthRows
                ForEach(Array(ai.usage.enumerated()), id: \.element.id) { i, u in
                    usageRow(u, label: i == 0 ? "AI 工具" : "")
                }
                ForEach(Array(ai.models.enumerated()), id: \.element.id) { i, mo in
                    modelRow(mo, label: i == 0 ? "本地模型" : "")
                }
                if !ai.models.isEmpty {
                    line(label: "") {
                        Spacer().frame(width: 26)
                        Text("模型只能在这里由你自己删除，agent 删不了。「最后使用」是系统记录的读取时间，只能当参考。")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .confirmationDialog(modelToDelete.map { "删除 \($0.name)？" } ?? "", isPresented: Binding(get: { modelToDelete != nil }, set: { if !$0 { modelToDelete = nil } }), titleVisibility: .visible) {
            if let mo = modelToDelete {
                if mo.source == .ollama {
                    Button("用 ollama rm 删除（\(fmtSize(mo.size))）", role: .destructive) { deleteModel(mo, .permanent) }
                } else {
                    Button("直接删除，马上腾出 \(fmtSize(mo.size))", role: .destructive) { deleteModel(mo, .permanent) }
                    Button("移到废纸篓（还能找回，清空后才腾出空间）") { deleteModel(mo, .trash) }
                }
                Button("取消", role: .cancel) {}
            }
        } message: {
            if let mo = modelToDelete {
                Text("\(mo.source.rawValue) · \(fmtSize(mo.size))\n删了以后，用到它的程序会重新下载，可能要很久。")
            }
        }
    }

    func deleteModel(_ mo: LocalModel, _ mode: ModelStore.DeleteMode) {
        ai.delete(mo, mode) { msg in
            m.message = msg
            m.disk = DiskSpace.current()
        }
    }

    @ViewBuilder
    var growthRows: some View {
        if ai.growth.isEmpty {
            line(label: "涨得最快") {
                Spacer().frame(width: 26)
                Text(Growth.load().count < 2 ? "阿扫每天记一次各文件夹的大小，明天起这里会显示谁涨得最快。" : "最近一周没有哪个文件夹涨超过 100 MB。")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        } else {
            let maxDelta = ai.growth.map(\.delta).max() ?? 1
            ForEach(Array(ai.growth.enumerated()), id: \.element.id) { i, g in
                line(label: i == 0 ? "\(g.days) 天涨得最快" : "") {
                    Spacer().frame(width: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(g.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        GeometryReader { geo in
                            Rectangle().fill(Palette.chart[1]).frame(width: max(2, geo.size.width * CGFloat(Double(g.delta) / Double(maxDelta))))
                        }
                        .frame(height: 4)
                    }
                    Spacer(minLength: 16)
                    Text("+" + fmtSize(g.delta)).font(.system(size: 13)).monospacedDigit().frame(width: 90, alignment: .trailing)
                }
            }
        }
    }

    func usageRow(_ u: AIUsageEntry, label: String) -> some View {
        let open = ai.expanded.contains(u.id)
        let maxTotal = ai.usage.first?.total ?? 1
        return line(label: label) {
            Spacer().frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(u.group.name).font(.system(size: 13))
                Text(u.group.note).font(.system(size: 11.5)).foregroundStyle(.secondary)
                GeometryReader { geo in
                    Rectangle().fill(Palette.chart[0]).frame(width: max(2, geo.size.width * CGFloat(Double(u.total) / Double(max(maxTotal, 1)))))
                }
                .frame(height: 4).padding(.top, 2)
                if open {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(u.parts, id: \.path) { part in
                            Button { NSWorkspace.shared.selectFile(part.path, inFileViewerRootedAtPath: "") } label: {
                                HStack {
                                    Text(part.path.replacingOccurrences(of: home, with: "~")).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(fmtSize(part.size)).font(.system(size: 11.5)).monospacedDigit()
                                }
                                .foregroundStyle(.secondary).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help("在访达中显示")
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if open { ai.expanded.remove(u.id) } else { ai.expanded.insert(u.id) } }
            .help(open ? "收起" : "点击查看在哪些文件夹")
            Spacer(minLength: 16)
            Text(fmtSize(u.total)).font(.system(size: 13)).monospacedDigit().frame(width: 90, alignment: .trailing)
        }
    }

    func modelRow(_ mo: LocalModel, label: String) -> some View {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .full
        var info = [mo.source.rawValue]
        if let d = mo.lastUsed { info.append("最后使用 " + f.localizedString(for: d, relativeTo: Date())) }
        if let d = mo.downloaded { info.append("下载于 " + d.formatted(.dateTime.year().month().day())) }
        return line(label: label) {
            Spacer().frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(mo.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text(info.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if ai.deleting == mo.id {
                ProgressView().controlSize(.mini).frame(width: 44)
            } else {
                Button { modelToDelete = mo } label: {
                    Text("删除").font(.system(size: 11.5)).padding(.horizontal, 10).padding(.vertical, 3)
                        .overlay(Rectangle().strokeBorder(Palette.ink.opacity(0.4), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(ai.deleting != nil)
            }
            Text(fmtSize(mo.size)).font(.system(size: 13)).monospacedDigit().frame(width: 90, alignment: .trailing)
        }
    }

    // MARK: 记录

    var logTable: some View {
        ScrollView {
            VStack(spacing: 0) {
                if ai.activity.isEmpty {
                    line(label: "记录") {
                        Spacer().frame(width: 26)
                        Text("还没有清理记录。以后不管是你在这里点清理，还是 agent 通过阿扫清理，都会记在这里。")
                            .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    }
                }
                ForEach(ai.activity) { e in
                    activityRow(e)
                }
            }
        }
        .scrollIndicators(.hidden)
        .onAppear { ai.reloadActivity() }
    }

    func activityRow(_ e: Activity.Entry) -> some View {
        let open = ai.expanded.contains(e.id)
        return line(label: e.at.formatted(.dateTime.month().day().hour().minute())) {
            Spacer().frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.actor).font(.system(size: 13))
                Text(e.what.joined(separator: "、") + (e.skipped > 0 ? "（跳过 \(e.skipped) 项）" : ""))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if open {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(e.details.enumerated()), id: \.offset) { _, d in
                            Text(d.replacingOccurrences(of: home, with: "~")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if open { ai.expanded.remove(e.id) } else { ai.expanded.insert(e.id) } }
            .help(open ? "收起" : "点击查看删了哪些文件")
            Spacer(minLength: 16)
            Text(fmtSize(e.freed)).font(.system(size: 13)).monospacedDigit().frame(width: 90, alignment: .trailing)
        }
    }
}
