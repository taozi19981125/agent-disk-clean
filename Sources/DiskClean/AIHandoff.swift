import AppKit

/// 电脑上没装命令行 AI 时的备用办法：阿扫在本地扫描，把结果整理成文字复制给网页版 AI（家目录换成 ~，不带用户名）
enum AIHandoff {
    static func copyScanReport(done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let scan = MCP.runSelf(["scan"]).1
            let ai = MCP.runSelf(["ai"]).1
            let text = """
            下面是我这台 Mac 的磁盘扫描结果（开源工具「阿扫」在本地生成）。请帮我分析：空间主要被谁占了？哪些可以放心清理、哪些要谨慎、哪些别动？清理我会自己在阿扫里点，你只需要给建议。

            \(scan)
            \(ai)
            """.replacingOccurrences(of: home, with: "~")
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                done("扫描结果已复制（只有文件夹和大小），贴给你常用的 AI 就行")
            }
        }
    }
}
