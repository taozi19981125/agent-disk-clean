import SwiftUI

/// 空间占用图：只看不删
final class SizeNode: Identifiable {
    let id = UUID()
    let name: String
    let path: String?
    var size: Int64
    var children: [SizeNode]
    init(name: String, path: String?, size: Int64, children: [SizeNode] = []) {
        self.name = name; self.path = path; self.size = size; self.children = children
    }
}

enum SizeScanner {
    /// 小于这个大小的条目合并成「其他小文件」，避免树太大
    static let minNode: Int64 = 20_000_000
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey]

    static func scanDisk(progress: @escaping (String) -> Void) -> SizeNode {
        let homeNode = scan(URL(fileURLWithPath: home), progress: progress)
        let apps = scan(URL(fileURLWithPath: "/Applications"), progress: progress)
        let homeLabel = SizeNode(name: "你的个人文件夹", path: home, size: homeNode.size, children: homeNode.children)
        let appsLabel = SizeNode(name: "应用程序", path: "/Applications", size: apps.size, children: apps.children)
        var top = [homeLabel, appsLabel]
        if let d = DiskSpace.current() {
            let other = d.total - d.free - homeNode.size - apps.size
            if other > 0 { top.append(SizeNode(name: "系统和其他", path: nil, size: other)) }
        }
        return SizeNode(name: "整个磁盘", path: nil, size: top.reduce(0) { $0 + $1.size }, children: top)
    }

    static func scan(_ url: URL, progress: @escaping (String) -> Void, depth: Int = 0) -> SizeNode {
        if depth <= 2 { progress(url.path.replacingOccurrences(of: home, with: "~")) }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else {
            return SizeNode(name: url.lastPathComponent, path: url.path, size: 0)
        }
        var kids: [SizeNode] = []
        var small: Int64 = 0
        for item in items {
            let v = try? item.resourceValues(forKeys: Set(keys))
            let node: SizeNode
            if v?.isSymbolicLink == true {
                continue
            } else if v?.isDirectory == true && v?.isPackage != true {
                node = scan(item, progress: progress, depth: depth + 1)
            } else if v?.isDirectory == true {
                // .app、照片图库这类包当成一个整体
                node = SizeNode(name: item.lastPathComponent, path: item.path, size: packageSize(item))
            } else {
                node = SizeNode(name: item.lastPathComponent, path: item.path, size: Int64(v?.totalFileAllocatedSize ?? 0))
            }
            if node.size >= minNode { kids.append(node) } else { small += node.size }
        }
        kids.sort { $0.size > $1.size }
        if small >= minNode { kids.append(SizeNode(name: "其他小文件", path: nil, size: small)) }
        let total = kids.reduce(0) { $0 + $1.size } + (small >= minNode ? 0 : small)
        return SizeNode(name: url.lastPathComponent, path: url.path, size: total, children: kids)
    }

    static func packageSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: { _, _ in true })
        while let u = e?.nextObject() as? URL {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// 方块切分（squarified treemap）
enum TreemapLayout {
    static func layout(_ nodes: [SizeNode], in rect: CGRect) -> [(SizeNode, CGRect)] {
        let total = nodes.reduce(0) { $0 + Double($1.size) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        var out: [(SizeNode, CGRect)] = []
        var rest = nodes.filter { $0.size > 0 }
        var r = rect
        while !rest.isEmpty {
            let side = Double(min(r.width, r.height))
            var row: [SizeNode] = []
            var best = Double.infinity
            for n in rest {
                let trial = row + [n]
                let w = worst(trial.map { Double($0.size) * scale }, side)
                if w > best { break }
                best = w; row = trial
            }
            rest.removeFirst(row.count)
            let rowArea = row.reduce(0) { $0 + Double($1.size) * scale }
            let thick = CGFloat(rowArea / side)
            var offset: CGFloat = 0
            for n in row {
                let len = CGFloat(Double(n.size) * scale) / max(thick, 0.0001)
                let cell = r.width >= r.height
                    ? CGRect(x: r.minX, y: r.minY + offset, width: thick, height: len)
                    : CGRect(x: r.minX + offset, y: r.minY, width: len, height: thick)
                out.append((n, cell)); offset += len
            }
            r = r.width >= r.height
                ? CGRect(x: r.minX + thick, y: r.minY, width: r.width - thick, height: r.height)
                : CGRect(x: r.minX, y: r.minY + thick, width: r.width, height: r.height - thick)
        }
        return out
    }

    static func worst(_ areas: [Double], _ side: Double) -> Double {
        let s = areas.reduce(0, +)
        guard let mx = areas.max(), let mn = areas.min(), s > 0, mn > 0 else { return .infinity }
        return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
    }
}

final class TreemapModel: ObservableObject {
    @Published var root: SizeNode?
    @Published var stack: [SizeNode] = []
    @Published var scanning = false
    @Published var current = ""
    /// 储存横条用的五类：系统、资源库、文稿与下载、应用、缓存与开发
    @Published var usage: [(name: String, size: Int64)] = []

    func start() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            var last = Date.distantPast
            let r = SizeScanner.scanDisk { p in
                guard Date().timeIntervalSince(last) > 0.1 else { return }
                last = Date()
                DispatchQueue.main.async { self.current = p }
            }
            let u = Self.breakdown(r)
            // 顺便记下今天各文件夹的大小，给「涨得最快」用
            Growth.record(r)
            DispatchQueue.main.async {
                // 默认打开个人文件夹，最外层只有三大块，看不出什么
                self.root = r; self.stack = [r] + r.children.filter { $0.path == home }; self.usage = u; self.scanning = false
            }
        }
    }

    /// 从扫描结果里归出五类。缓存与开发 = ~/Library/Caches + 家目录里的隐藏文件夹
    static func breakdown(_ root: SizeNode) -> [(name: String, size: Int64)] {
        let homeNode = root.children.first { $0.path == home }
        let apps = root.children.first { $0.path == "/Applications" }?.size ?? 0
        let lib = homeNode?.children.first { $0.name == "Library" }
        let caches = lib?.children.first { $0.name == "Caches" }?.size ?? 0
        let dots = homeNode?.children.filter { $0.name.hasPrefix(".") }.reduce(0) { $0 + $1.size } ?? 0
        let library = (lib?.size ?? 0) - caches
        let docs = (homeNode?.size ?? 0) - (lib?.size ?? 0) - dots
        let system = root.children.first { $0.path == nil }?.size ?? 0
        return [("系统", system), ("资源库", library), ("文稿与下载", docs), ("应用", apps), ("缓存与开发", caches + dots)]
    }
}

struct TreemapView: View {
    @ObservedObject var m: TreemapModel
    @State var hover: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let node = m.stack.last {
                breadcrumb
                HStack(alignment: .top, spacing: 22) {
                    GeometryReader { geo in
                        let cells = TreemapLayout.layout(node.children, in: CGRect(origin: .zero, size: geo.size))
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(cells.enumerated()), id: \.element.0.id) { i, cell in
                                block(cell.0, cell.1, index: i)
                            }
                        }
                    }
                    legend(node).frame(width: 200)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("正在统计 \(m.current)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
                    Text("第一次统计时系统可能会问能不能访问某些文件夹，点「允许」才算得准。")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    var breadcrumb: some View {
        HStack(spacing: 6) {
            ForEach(Array(m.stack.enumerated()), id: \.element.id) { i, n in
                if i > 0 { Text("›").foregroundStyle(.tertiary) }
                Button(n.name) { m.stack.removeLast(m.stack.count - 1 - i) }
                    .buttonStyle(.plain)
                    .fontWeight(i == m.stack.count - 1 ? .semibold : .regular)
                    .foregroundStyle(i == m.stack.count - 1 ? .primary : .secondary)
            }
            Text(fmtSize(m.stack.last?.size ?? 0)).foregroundStyle(.secondary)
            Spacer()
            Button("重新分析") { m.start() }.buttonStyle(.plain).foregroundStyle(.tertiary).disabled(m.scanning)
        }
        .font(.system(size: 12))
    }

    /// 图表色：前五块用分类色盘，后面的和点不进去的「其他」用灰色
    func color(_ i: Int, _ n: SizeNode) -> Color {
        n.path == nil || i >= Palette.chart.count ? Palette.chartOther : Palette.chart[i]
    }

    func textColor(_ i: Int, _ n: SizeNode) -> Color {
        n.path == nil || i >= Palette.chart.count ? .primary : .white
    }

    func block(_ n: SizeNode, _ r: CGRect, index: Int) -> some View {
        let canOpen = !n.children.isEmpty
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color(index, n))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white.opacity(hover == n.id ? 0.9 : 0), lineWidth: 2))
            if r.width > 56 && r.height > 30 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(n.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(fmtSize(n.size)).font(.system(size: 11)).monospacedDigit()
                }
                .foregroundStyle(textColor(index, n))
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        .frame(width: max(r.width - 2, 0), height: max(r.height - 2, 0))
        .offset(x: r.minX + 1, y: r.minY + 1)
        .onHover { hover = $0 ? n.id : (hover == n.id ? nil : hover) }
        .onTapGesture { if canOpen { m.stack.append(n) } }
        .help("\(n.path?.replacingOccurrences(of: home, with: "~") ?? n.name)  \(fmtSize(n.size))\(canOpen ? "\n点击往里看" : "")")
        .contextMenu {
            if let p = n.path {
                Button("在访达中显示") { NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "") }
            }
        }
    }

    func legend(_ node: SizeNode) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { i, c in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(color(i, c)).frame(width: 9, height: 9)
                        Text(c.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(fmtSize(c.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 6)
                    .background(hover == c.id ? Color.primary.opacity(0.05) : .clear)
                    .contentShape(Rectangle())
                    .onHover { hover = $0 ? c.id : (hover == c.id ? nil : hover) }
                    .onTapGesture { if !c.children.isEmpty { m.stack.append(c) } }
                    .contextMenu {
                        if let p = c.path {
                            Button("在访达中显示") { NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "") }
                        }
                    }
                    Divider()
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
