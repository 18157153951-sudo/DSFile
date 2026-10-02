//
//  FileViewers.swift — 文件查看器三件套（文本编辑器 / 十六进制查看器 / 属性面板）
//
//  这个文件是 DSFile（暗剑文件）的「打开文件」这一层，只放三个可以被其它界面以 sheet
//  形式弹出的 View，以及它们内部用到的私有小组件。对外只暴露三个类型，初始化签名固定：
//
//      TextFileView(path: String)                                 // 文本编辑（UTF-8 / Latin1 自动识别）
//      HexViewerView(path: String)                                // 分页十六进制查看
//      FileInfoView(path: String, onChange: @escaping () -> Void) // 属性 / 权限 / 属主 / 增删改
//
//  设计约定（和工程里其它界面保持一致）：
//  1. 三个 View 各自带自己的 NavigationView + navigationTitle + 右上角「完成」按钮，
//     调用方直接 `.sheet { TextFileView(path: xxx) }` 即可，不需要再包一层导航容器。
//  2. 颜色只用系统语义色：.secondary（次要信息）、.green（成功）、.red（失败/危险）、
//     .orange（进行中/警告）、.accentColor（普通动作）。
//  3. 行模式统一为 HStack(spacing: 12)：28pt 宽的 SF Symbol（.title3）+ VStack（标题
//     .subheadline、元信息 .caption2 + .secondary）+ 行尾动作图标。
//  4. 主按钮统一为整行 Button：HStack { Spacer(); 图标+文字; Spacer() }，文字
//     .fontWeight(.semibold)，运行中内嵌 ProgressView() 并 .disabled。
//  5. 空状态 / 加载中统一走 EmptyStateView（44pt 图标 → .headline → .footnote）。
//  6. 多动作用 .confirmationDialog，错误统一用 .alert 显示 error.localizedDescription。
//
//  兼容性：目标 iOS 15 / Swift 5.0，所以刻意不用 NavigationStack、ShareLink、
//  .scrollContentBackground、Grid、ContentUnavailableView、@Observable、宏。
//  分享面板走 DSPickers.presentShareSheet(urls:)（UIKit 实现，iPad 有 popover 锚点）。
//
//  权限自愈：所有写操作都走 FileOperations，它在被拒时会把 owner 改成 mobile:mobile
//  再重试一次，所以这里不需要自己处理 EACCES。
//

import SwiftUI
import Foundation
import UIKit

// MARK: - 通用小工具

/// 字节数格式化（和 PathItem.sizeString 保持一样的 countStyle，避免同一个大小两种说法）
private func dsFileSizeString(_ bytes: Int64) -> String {
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// 后台算完回到主线程执行（iOS 15 下比 Task/async 更稳，不会踩并发的坑）
private func dsOnMain(_ work: @escaping () -> Void) {
    DispatchQueue.main.async(execute: work)
}

// MARK: - 空状态 / 占位视图

/// 居中空状态：44pt 图标 + 一句话 + 操作指引
private struct EmptyStateView: View {

    let icon: String
    let title: String
    let hint: String
    let tint: Color
    let showsProgress: Bool

    init(icon: String, title: String, hint: String, tint: Color = .secondary, showsProgress: Bool = false) {
        self.icon = icon
        self.title = title
        self.hint = hint
        self.tint = tint
        self.showsProgress = showsProgress
    }

    var body: some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .scaleEffect(1.2)
                    .padding(.bottom, 2)
            }
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(tint)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(hint)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 信息行

/// 统一的信息行：28pt 图标 + 标题（+ 可选副标题）+ 行尾内容
private struct InfoRow<Trailing: View>: View {

    let icon: String
    let tint: Color
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(icon: String,
         tint: Color = .accentColor,
         title: String,
         subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(tint)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.vertical, 2)
    }
}

/// 行尾的值文本：右对齐、等宽、可选中（长路径用中间截断）
private struct InfoValueText: View {

    let text: String
    let monospaced: Bool
    let selectable: Bool

    init(_ text: String, monospaced: Bool = false, selectable: Bool = true) {
        self.text = text
        self.monospaced = monospaced
        self.selectable = selectable
    }

    var body: some View {
        if selectable {
            content.textSelection(.enabled)
        } else {
            content
        }
    }

    private var content: some View {
        Group {
            if monospaced {
                Text(text).font(.system(.subheadline, design: .monospaced))
            } else {
                Text(text).font(.subheadline)
            }
        }
        .foregroundColor(.secondary)
        .multilineTextAlignment(.trailing)
    }
}

/// 整行主按钮：图标 + 文字居中，运行中换成 ProgressView 并禁用
private struct ActionRowButton: View {

    let icon: String
    let title: String
    let subtitle: String?
    let tint: Color
    let running: Bool
    let disabled: Bool
    let action: () -> Void

    init(icon: String,
         title: String,
         subtitle: String? = nil,
         tint: Color = .accentColor,
         running: Bool = false,
         disabled: Bool = false,
         action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.running = running
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                if running {
                    ProgressView()
                        .padding(.trailing, 6)
                } else {
                    Image(systemName: icon)
                        .font(.body)
                }
                VStack(spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.semibold)
                    if let subtitle = subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .foregroundColor(tint)
        .disabled(disabled || running)
    }
}

/// 顶部 / 底部的一行反馈文字（保存成功、还原成功之类）
private struct FeedbackBanner: View {

    let text: String
    let tint: Color
    let icon: String

    init(text: String, tint: Color = .green, icon: String = "checkmark.circle.fill") {
        self.text = text
        self.tint = tint
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
            Text(text)
                .font(.footnote)
            Spacer()
        }
        .foregroundColor(tint)
    }
}

/// 文本文件页脚：路径（等宽、中间截断）+ 大小 + 修改时间
private struct FileStatFooter: View {

    let path: String
    let item: PathItem?

    init(path: String, item: PathItem?) {
        self.path = path
        self.item = item
    }

    private var sizeText: String {
        guard let item = item else { return "—" }
        if item.isDirectory { return "文件夹" }
        return dsFileSizeString(item.size)
    }

    private var modifiedText: String {
        guard let item = item else { return "—" }
        return item.modifiedString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 12) {
                Text(sizeText)
                Text(modifiedText)
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 打开文本文件失败时的兜底视图（可能是二进制，引导去十六进制查看）
private struct UnreadableTextView: View {

    let path: String
    let message: String
    let onHex: () -> Void

    init(path: String, message: String, onHex: @escaping () -> Void) {
        self.path = path
        self.message = message
        self.onHex = onHex
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text("无法以文本方式打开")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(action: onHex) {
                HStack(spacing: 6) {
                    Image(systemName: "number.square")
                    Text("用十六进制查看")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(8)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 通用「输入一行文字」的 sheet：iOS 15/16 的 alert 里放 TextField 在新系统上会被忽略，
/// 所以重命名、移动到目录这两个入口都用这个表单，行为在 15 和 16+ 上完全一致。
/// 提交后由表单自己关掉；父视图如果有错误，会在表单关闭之后再弹 alert。
private struct TextInputSheet: View {

    let title: String
    let label: String
    let placeholder: String
    let confirmTitle: String
    let footerHint: String
    let onSubmit: (String) -> Void

    @State private var text: String = ""
    @Environment(\.presentationMode) private var presentationMode

    init(title: String,
         label: String,
         placeholder: String,
         confirmTitle: String = "确定",
         footerHint: String = "提示：路径要写完整，例如 /var/mobile/Documents",
         onSubmit: @escaping (String) -> Void) {
        self.title = title
        self.label = label
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.footerHint = footerHint
        self.onSubmit = onSubmit
    }

    private var trimmed: String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        return !trimmed.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit(trimmed)
        presentationMode.wrappedValue.dismiss()
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(placeholder, text: $text)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text(label)
                } footer: {
                    Text(footerHint)
                        .font(.caption2)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: submit)
                        .disabled(!canSubmit)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

/// 「跳转到偏移」的小面板：支持 0x1F40 / 1F40 / 8000 三种写法
private struct HexJumpSheet: View {

    let onJump: (Int64) -> Void

    @State private var offsetText: String = ""
    @Environment(\.presentationMode) private var presentationMode

    init(onJump: @escaping (Int64) -> Void) {
        self.onJump = onJump
    }

    private var resolvedOffset: Int64? {
        return HexViewerView.parseOffset(offsetText)
    }

    private func submit() {
        guard let value = resolvedOffset else { return }
        onJump(value)
        presentationMode.wrappedValue.dismiss()
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("十六进制或十进制，例如 0x1F40", text: $offsetText)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("偏移量")
                } footer: {
                    if let value = resolvedOffset {
                        Text("将跳转到字节 \(value)（0x\(String(value, radix: 16, uppercase: true))）")
                            .font(.caption2)
                    } else {
                        Text("输入 0x 开头的十六进制，或纯数字（十进制）")
                            .font(.caption2)
                    }
                }
            }
            .navigationTitle("跳转到偏移")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("跳转", action: submit)
                        .disabled(resolvedOffset == nil)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - TextFileView

/// 纯文本查看 / 编辑。
/// - 载入：FileOperations.readText（UTF-8 → Latin1 → 二进制可打印化，三级兜底）
/// - 保存：FileOperations.writeText(text, to:, makeBackup: true)，默认在旁边留 .dsfbak
/// - 还原：把 .dsfbak 拷回原路径（只有备份存在时才显示这个入口）
/// - 未保存时点「完成」会弹 confirmationDialog 问要不要先保存
struct TextFileView: View {

    let path: String

    @State private var text: String = ""
    @State private var loadedText: String = ""
    @State private var item: PathItem?
    @State private var isLoaded: Bool = false
    @State private var loadError: String?
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var statusText: String = ""
    @State private var isSaving: Bool = false
    @State private var isRestoring: Bool = false
    @State private var hasBackup: Bool = false
    @State private var showDoneDialog: Bool = false
    @State private var showReloadDialog: Bool = false
    @State private var showRestoreDialog: Bool = false
    @State private var showHexSheet: Bool = false

    @Environment(\.presentationMode) private var presentationMode

    init(path: String) {
        self.path = path
    }

    // MARK: 状态

    /// 只有一个换行符的差异就认为没改过，避免「载入即脏」
    private var isDirty: Bool {
        return text != loadedText
    }

    private var titleText: String {
        return (path as NSString).lastPathComponent
    }

    private var editorBinding: Binding<String> {
        return Binding<String>(
            get: { self.text },
            set: { self.text = $0 }
        )
    }

    // MARK: 主体

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let message = loadError {
                    UnreadableTextView(path: path, message: message) {
                        showHexSheet = true
                    }
                } else if isLoaded {
                    editorAndStatus
                } else {
                    EmptyStateView(icon: "doc.text",
                                   title: "正在读取文件",
                                   hint: "大文件会先判断体积，超过 4 MB 请改用十六进制查看",
                                   showsProgress: true)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear(perform: load)
        .sheet(isPresented: $showHexSheet) {
            HexViewerView(path: path)
        }
        .confirmationDialog("还有未保存的改动", isPresented: $showDoneDialog) {
            Button("保存并关闭") {
                if save() {
                    presentationMode.wrappedValue.dismiss()
                }
            }
            Button("放弃改动并关闭", role: .destructive) {
                presentationMode.wrappedValue.dismiss()
            }
            Button("继续编辑", role: .cancel) { }
        } message: {
            Text("关闭后未保存的内容会丢失。")
        }
        .confirmationDialog("重新载入会丢弃当前改动", isPresented: $showReloadDialog) {
            Button("重新载入", role: .destructive, action: load)
            Button("取消", role: .cancel) { }
        } message: {
            Text("当前编辑器里的内容尚未保存。")
        }
        .confirmationDialog("从 .dsfbak 备份还原？", isPresented: $showRestoreDialog) {
            Button("还原", role: .destructive, action: restoreBackup)
            Button("取消", role: .cancel) { }
        } message: {
            Text("会用备份覆盖当前文件，编辑器内容会重新载入。")
        }
        .alert("操作失败", isPresented: $showError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    /// 编辑器 + 反馈条 + 页脚（拆成独立属性，避免 body 里 ViewBuilder 分支过多）
    @ViewBuilder
    private var editorAndStatus: some View {
        TextEditor(text: editorBinding)
            .font(.system(.body, design: .monospaced))
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .padding(.horizontal, 8)
            .padding(.top, 4)

        if !statusText.isEmpty {
            FeedbackBanner(text: statusText)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }

        if isDirty {
            HStack(spacing: 8) {
                Image(systemName: "pencil.circle.fill")
                    .font(.footnote)
                Text("有未保存的改动")
                    .font(.footnote)
                Spacer()
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }

        Divider()

        FileStatFooter(path: path, item: item)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

        if isSaving || isRestoring {
            HStack(spacing: 8) {
                ProgressView()
                Text(isSaving ? "正在写入…" : "正在还原…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("完成") {
                if isDirty {
                    showDoneDialog = true
                } else {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { _ = save() } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .disabled(!isLoaded || isSaving || loadError != nil)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button(action: load) {
                    Label("重新载入", systemImage: "arrow.clockwise")
                }
                Button {
                    if isDirty {
                        showReloadDialog = true
                    } else {
                        load()
                    }
                } label: {
                    Label("丢弃改动并重新载入", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!isDirty)

                Button {
                    showRestoreDialog = true
                } label: {
                    Label("还原改动（.dsfbak）", systemImage: "clock.arrow.circlepath")
                }
                .disabled(!hasBackup || isRestoring)

                Button {
                    showHexSheet = true
                } label: {
                    Label("十六进制查看", systemImage: "number.square")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(!isLoaded && loadError == nil)
        }
    }

    // MARK: 读写

    private func load() {
        do {
            let content = try FileOperations.readText(path)
            text = content
            loadedText = content
            loadError = nil
            statusText = ""
            isLoaded = true
            refreshItem()
            DSLog.shared.info("打开文本 \(path)（\(content.count) 字符）", source: "查看器")
        } catch {
            let message = error.localizedDescription
            loadError = message
            isLoaded = false
            errorMessage = message
            showError = true
            DSLog.shared.error("读取文本失败：\(message)", source: "查看器")
        }
    }

    private func refreshItem() {
        let snapshot: PathItem? = FileSystemService.item(at: path)
        item = snapshot
        hasBackup = FileSystemService.exists(path + ".dsfbak")
    }

    /// 返回是否写入成功（「完成」按钮要靠它决定关不关窗）
    @discardableResult
    private func save() -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try FileOperations.writeText(text, to: path, makeBackup: true)
            loadedText = text
            statusText = "已保存（原文件备份为 \(titleText).dsfbak）"
            refreshItem()
            DSLog.shared.info("已保存 \(path)（\(text.count) 字符，留 .dsfbak 备份）", source: "查看器")
            return true
        } catch {
            let message = error.localizedDescription
            errorMessage = message
            showError = true
            DSLog.shared.error("保存失败：\(message)", source: "查看器")
            return false
        }
    }

    private func restoreBackup() {
        let backupPath = path + ".dsfbak"
        guard FileSystemService.exists(backupPath) else {
            errorMessage = "没有找到备份文件：\(backupPath)"
            showError = true
            return
        }
        isRestoring = true
        defer { isRestoring = false }
        do {
            try FileOperations.copy(backupPath, to: path)
            statusText = "已从备份还原"
            load()
            DSLog.shared.info("已用 \(backupPath) 还原 \(path)", source: "查看器")
        } catch {
            let message = error.localizedDescription
            errorMessage = message
            showError = true
            DSLog.shared.error("还原失败：\(message)", source: "查看器")
        }
    }
}

// MARK: - HexViewerView

/// 分页十六进制查看器。
/// - 每页固定 8192 字节，用 FileOperations.readBytes(path, offset:length:) 按页读
/// - 每行格式：`偏移量(8 位 hex)  16 字节 hex  |ascii|`
/// - 整页拼成一个字符串再交给一个 Text 渲染（512 个 Text 会明显掉帧），
///   外面套竖直 ScrollView + 横向 ScrollView 处理超宽行
/// - 字符串拼接放后台队列，读大文件不阻塞滚动
struct HexViewerView: View {

    let path: String

    /// 每页字节数（16 字节 × 512 行）
    static let pageSize: Int = 8192
    /// 每行字节数
    static let bytesPerLine: Int = 16

    @State private var pageIndex: Int = 0
    @State private var totalSize: Int64 = 0
    @State private var pageText: String = ""
    @State private var pageBytes: Int = 0
    @State private var isLoading: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var showJumpSheet: Bool = false

    @Environment(\.presentationMode) private var presentationMode

    init(path: String) {
        self.path = path
    }

    // MARK: 计算属性

    private var pageCount: Int {
        if totalSize <= 0 { return 1 }
        let size = Int64(HexViewerView.pageSize)
        return Int((totalSize + size - 1) / size)
    }

    private var pageOffset: Int64 {
        return Int64(pageIndex) * Int64(HexViewerView.pageSize)
    }

    private var currentRangeText: String {
        guard totalSize > 0 else { return "空文件" }
        let end = min(totalSize, pageOffset + Int64(pageBytes)) - 1
        if pageBytes <= 0 { return "空" }
        return "0x\(HexViewerView.hexOffset(pageOffset)) – 0x\(HexViewerView.hexOffset(end))"
    }

    /// 把用户输入解析成字节偏移：0x1F40 / 1F40 / 8000
    static func parseOffset(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("0x") {
            let body = String(lowered.dropFirst(2))
            guard !body.isEmpty else { return nil }
            return Int64(body, radix: 16)
        }
        if let decimal = Int64(trimmed) {
            return decimal
        }
        // 没写 0x 的纯十六进制（比如 1F40），按十六进制再试一次
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdefABCDEF")) != nil {
            return Int64(trimmed, radix: 16)
        }
        return nil
    }

    private static func hexOffset(_ value: Int64) -> String {
        return String(format: "%08llX", value)
    }

    // MARK: 主体

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isLoading && pageText.isEmpty {
                    EmptyStateView(icon: "number.square",
                                   title: "正在读取",
                                   hint: "正在把这一页格式化成十六进制",
                                   showsProgress: true)
                } else if pageText.isEmpty {
                    EmptyStateView(icon: "doc",
                                   title: totalSize == 0 ? "空文件" : "这一页没有内容",
                                   hint: "共 \(dsFileSizeString(totalSize))，可以用下方控件翻页")
                } else {
                    hexScroll
                }

                Divider()
                pageInfoBar
                Divider()
                pageControls
            }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear(perform: prepare)
        .sheet(isPresented: $showJumpSheet) {
            HexJumpSheet { offset in
                jump(to: offset)
            }
        }
        .alert("操作失败", isPresented: $showError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    /// 十六进制正文：竖直滚动 + 横向滚动（16 字节一行在 iPhone 上放不下）
    private var hexScroll: some View {
        ScrollView(.vertical, showsIndicators: true) {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(pageText)
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: 220, maxHeight: 460)
    }

    /// 当前范围 / 总大小 / 页码
    private var pageInfoBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.footnote)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(currentRangeText)  ·  本页 \(pageBytes) 字节")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("总大小 \(dsFileSizeString(totalSize))  ·  第 \(pageIndex + 1) / \(pageCount) 页  ·  每页 \(HexViewerView.pageSize) 字节")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// 翻页 / 跳转控件
    private var pageControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    if pageIndex > 0 {
                        pageIndex -= 1
                        reloadPage()
                    }
                } label: {
                    controlLabel(icon: "chevron.left", title: "上一页")
                }
                .disabled(pageIndex <= 0 || isLoading)

                Button {
                    if pageIndex + 1 < pageCount {
                        pageIndex += 1
                        reloadPage()
                    }
                } label: {
                    controlLabel(icon: "chevron.right", title: "下一页")
                }
                .disabled(pageIndex + 1 >= pageCount || isLoading)
            }

            HStack(spacing: 10) {
                Button {
                    showJumpSheet = true
                } label: {
                    controlLabel(icon: "arrow.right.to.line", title: "跳转到偏移")
                }
                .disabled(totalSize == 0)

                Button {
                    pageIndex = 0
                    reloadPage()
                } label: {
                    controlLabel(icon: "backward.end", title: "回到开头")
                }
                .disabled(pageIndex == 0 || isLoading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func controlLabel(icon: String, title: String) -> some View {
        HStack {
            Spacer()
            Image(systemName: icon)
                .font(.footnote)
            Text(title)
                .font(.footnote)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
        .cornerRadius(8)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("完成") {
                presentationMode.wrappedValue.dismiss()
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                pageIndex = 0
                reloadPage()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
    }

    // MARK: 数据

    private func prepare() {
        guard FileSystemService.exists(path) else {
            totalSize = 0
            pageText = ""
            pageBytes = 0
            isLoading = false
            errorMessage = "文件不存在或无法读取：\(path)"
            showError = true
            DSLog.shared.error("十六进制查看失败：找不到 \(path)", source: "查看器")
            return
        }
        totalSize = FileOperations.fileSize(path)
        DSLog.shared.info("十六进制查看 \(path)（\(dsFileSizeString(totalSize))）", source: "查看器")
        reloadPage()
    }

    private func reloadPage() {
        let targetOffset = pageOffset
        let expectedPage = pageIndex
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let data = FileOperations.readBytes(path: path,
                                                offset: targetOffset,
                                                length: HexViewerView.pageSize) ?? Data()
            let text = HexViewerView.dump(data: data, baseOffset: targetOffset)
            let count = data.count
            dsOnMain {
                // 翻页太快时可能已经有更新的请求了，用页码挡掉过期结果
                guard expectedPage == pageIndex else { return }
                pageText = text
                pageBytes = count
                isLoading = false
            }
        }
    }

    /// 把一页数据格式化成整块文本：
    /// `00000000  41 42 43 ...  |ABC.............|`
    private static func dump(data: Data, baseOffset: Int64) -> String {
        guard !data.isEmpty else { return "" }
        let bytes: [UInt8] = [UInt8](data)
        let perLine: Int = HexViewerView.bytesPerLine
        var output: String = ""
        var index: Int = 0
        while index < bytes.count {
            let end = min(index + perLine, bytes.count)
            let lineOffset = baseOffset + Int64(index)

            var hexPart: String = ""
            var asciiPart: String = ""
            var column: Int = 0
            for position in index..<end {
                let byte: UInt8 = bytes[position]
                hexPart += String(format: "%02X ", byte)
                if byte >= 0x20 && byte < 0x7F {
                    asciiPart.append(Character(UnicodeScalar(byte)))
                } else {
                    asciiPart.append(".")
                }
                column += 1
            }
            // 补空格，保证右边竖线对齐
            if column < perLine {
                hexPart += String(repeating: "   ", count: perLine - column)
            }

            let offsetText = String(format: "%08llX", lineOffset)
            output += offsetText + "  " + hexPart + " |" + asciiPart + "|\n"
            index = end
        }
        return output
    }

    private func jump(to offset: Int64) {
        guard totalSize > 0 else { return }
        let clamped = max(0, min(offset, totalSize - 1))
        let target = Int(clamped / Int64(HexViewerView.pageSize))
        pageIndex = max(0, min(target, pageCount - 1))
        reloadPage()
    }
}

// MARK: - FileInfoView

/// 文件 / 目录属性面板：基本信息、目录统计、权限属主、常用动作（分享 / 复制路径 /
/// 重命名 / 复制一份 / 移动 / 删除）。
/// - 目录统计（递归体积 + 卷容量）全部在后台队列算，算完回主线程写状态
/// - 任何会改变文件系统的操作成功后都会调 onChange()，让外面的列表刷新
/// - 删除成功后自己关掉 sheet
struct FileInfoView: View {

    let path: String
    let onChange: () -> Void

    @State private var item: PathItem?
    @State private var path_: String = ""
    @State private var isLoading: Bool = true
    @State private var totalSize: Int64 = 0
    @State private var volumeText: String = ""
    @State private var metricsLoading: Bool = false
    @State private var metricsGeneration: Int = 0

    @State private var modeText: String = ""
    @State private var ownerText: String = ""
    @State private var chownRecursive: Bool = false
    @State private var isApplyingMode: Bool = false
    @State private var isApplyingOwner: Bool = false
    /// 有动作正在跑时把其它动作按钮一起禁掉，避免并发改同一个路径
    @State private var isBusy: Bool = false
    @State private var isDuplicating: Bool = false
    @State private var isDeleting: Bool = false

    @State private var showRenameSheet: Bool = false
    @State private var showMoveSheet: Bool = false
    @State private var showDeleteDialog: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var statusText: String = ""

    @Environment(\.presentationMode) private var presentationMode

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        _path_ = State(initialValue: path)
    }

    // MARK: 计算属性

    private var isDirectory: Bool {
        return item?.isDirectory ?? false
    }

    private var displayName: String {
        return item?.name ?? (path_ as NSString).lastPathComponent
    }

    private var sizeValue: String {
        guard let item = item else { return "—" }
        if item.isDirectory { return "文件夹（见下方递归统计）" }
        return dsFileSizeString(item.size)
    }

    private var kindValue: String {
        return item?.kindName ?? "—"
    }

    private var modifiedValue: String {
        return item?.modifiedString ?? "—"
    }

    private var modeValue: String {
        guard let item = item else { return "—" }
        return "\(item.modeString)  (\(item.octalMode))"
    }

    private var ownerValue: String {
        guard let item = item else { return "—" }
        return "\(item.ownerString)  (\(item.uid):\(item.gid))"
    }

    // MARK: 主体

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    EmptyStateView(icon: "info.circle",
                                   title: "正在读取属性",
                                   hint: "稍等一下，正在向文件系统取信息",
                                   showsProgress: true)
                } else {
                    infoForm
                }
            }
            .navigationTitle("属性")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear(perform: load)
        .sheet(isPresented: $showRenameSheet) {
            TextInputSheet(title: "重命名",
                           label: "新名称",
                           placeholder: displayName,
                           footerHint: "只能改名字，不能带「/」；父目录不变。") { newName in
                rename(to: newName)
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            TextInputSheet(title: "移动到目录",
                           label: "目标目录或完整目标路径",
                           placeholder: "/var/mobile/Documents",
                           confirmTitle: "移动",
                           footerHint: "填目录会把文件搬进去；填完整路径则直接用它当新位置。") { directory in
                move(to: directory)
            }
        }
        .confirmationDialog("确定删除？", isPresented: $showDeleteDialog) {
            Button("删除", role: .destructive, action: performDelete)
            Button("取消", role: .cancel) { }
        } message: {
            Text(isDirectory
                 ? "「\(displayName)」及其全部内容会被永久删除，无法撤销。"
                 : "「\(displayName)」会被永久删除，无法撤销。")
        }
        .alert("操作失败", isPresented: $showError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private var infoForm: some View {
        Form {
            if !statusText.isEmpty {
                Section {
                    FeedbackBanner(text: statusText)
                }
            }

            basicSection
            if isDirectory {
                directorySection
            }
            permissionSection
            actionSection
        }
        .listStyle(.insetGrouped)
    }

    // MARK: 1. 基本信息

    private var basicSection: some View {
        Section {
            InfoRow(icon: "doc", title: "名称") {
                InfoValueText(displayName).lineLimit(2)
            }
            InfoRow(icon: "arrow.turn.down.right", title: "完整路径") {
                InfoValueText(path_, monospaced: true)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            InfoRow(icon: "square.grid.2x2", title: "类型") {
                InfoValueText(kindValue)
            }
            InfoRow(icon: "internaldrive", title: "大小") {
                InfoValueText(sizeValue)
            }
            InfoRow(icon: "clock", title: "修改时间") {
                InfoValueText(modifiedValue)
            }
            InfoRow(icon: "lock.shield", title: "权限") {
                InfoValueText(modeValue, monospaced: true)
            }
            InfoRow(icon: "person.crop.circle", title: "属主") {
                InfoValueText(ownerValue)
            }
        } header: {
            Text("基本信息")
        }
    }

    // MARK: 2. 目录统计

    private var directorySection: some View {
        Section {
            InfoRow(icon: "sum", tint: .orange, title: "递归体积",
                    subtitle: "最深统计 6 层，符号链接只算自身") {
                if metricsLoading {
                    ProgressView()
                } else {
                    InfoValueText(dsFileSizeString(totalSize))
                }
            }
            InfoRow(icon: "externaldrive", tint: .orange, title: "所在卷") {
                if metricsLoading {
                    ProgressView()
                } else {
                    InfoValueText(volumeText.isEmpty ? "—" : volumeText)
                }
            }
        } header: {
            Text("目录统计")
        } footer: {
            Text("统计在后台线程完成，大目录可能需要几秒。")
                .font(.caption2)
        }
    }

    // MARK: 3. 权限 / 属主

    private var permissionSection: some View {
        Section {
            InfoRow(icon: "lock.shield", tint: .secondary, title: "八进制模式",
                    subtitle: "例如 0644 / 0755 / 0777") {
                TextField("0644", text: $modeText)
                    .font(.system(.subheadline, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .frame(maxWidth: 110)
            }

            ActionRowButton(icon: "checkmark.seal",
                            title: "应用权限",
                            tint: .accentColor,
                            running: isApplyingMode,
                            disabled: item == nil || isBusy) {
                applyMode()
            }

            InfoRow(icon: "person.crop.circle", tint: .secondary, title: "属主",
                    subtitle: "用户名或 uid，可写 mobile:mobile") {
                TextField("mobile:mobile", text: $ownerText)
                    .font(.system(.subheadline, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .frame(maxWidth: 150)
            }

            Toggle(isOn: $chownRecursive) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.title3)
                        .foregroundColor(.orange)
                        .frame(width: 28, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("递归")
                            .font(.subheadline)
                        Text("连子目录和文件一起改")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            ActionRowButton(icon: "person.badge.key",
                            title: "应用属主",
                            tint: .accentColor,
                            running: isApplyingOwner,
                            disabled: item == nil) {
                applyOwner()
            }
        } header: {
            Text("权限 / 属主")
        } footer: {
            Text("被系统拒绝时会先尝试用内核接口把 on-disk owner 改成 mobile:mobile 再重试。")
                .font(.caption2)
        }
    }

    // MARK: 4. 动作

    private var actionSection: some View {
        Section {
            ActionRowButton(icon: "square.and.arrow.up",
                            title: "分享",
                            subtitle: "AirDrop / 存储到「文件」",
                            disabled: isBusy) {
                share()
            }
            ActionRowButton(icon: "doc.on.doc",
                            title: "复制路径",
                            tint: .secondary,
                            disabled: isBusy) {
                copyPath()
            }
            ActionRowButton(icon: "pencil",
                            title: "重命名",
                            tint: .orange,
                            disabled: isBusy) {
                showRenameSheet = true
            }
            ActionRowButton(icon: "plus.square.on.square",
                            title: "复制一份",
                            subtitle: "自动用 -1、-2 避开重名",
                            running: isDuplicating,
                            disabled: isBusy) {
                duplicate()
            }
            ActionRowButton(icon: "arrow.right.doc.on.clipboard",
                            title: "移动到目录",
                            tint: .orange,
                            disabled: isBusy) {
                showMoveSheet = true
            }
            ActionRowButton(icon: "trash",
                            title: "删除",
                            subtitle: "不可撤销",
                            tint: .red,
                            running: isDeleting,
                            disabled: isBusy) {
                showDeleteDialog = true
            }
        } header: {
            Text("文件操作")
        }
    }

    // MARK: 读取

    private func load() {
        let snapshot: PathItem? = FileSystemService.item(at: path_)
        item = snapshot
        isLoading = false

        if let current = snapshot {
            modeText = current.octalMode
            ownerText = current.ownerString
        } else {
            // 路径都没了（比如被别的进程删掉），给一个空壳方便用户看到问题
            errorMessage = "路径不存在或无法读取：\(path_)"
            showError = true
            DSLog.shared.warn("属性面板打不开 \(path_)", source: "查看器")
        }
        refreshMetrics()
    }

    private func refreshMetrics() {
        guard isDirectory else {
            totalSize = 0
            volumeText = ""
            metricsLoading = false
            return
        }
        let targetPath = path_
        metricsGeneration += 1
        let generation = metricsGeneration
        metricsLoading = true
        DispatchQueue.global(qos: .utility).async {
            let size = FileSystemService.aggregateSize(of: targetPath, maxDepth: 6)
            let volume = FileSystemService.volumeInfo(for: targetPath) ?? ""
            dsOnMain {
                guard generation == metricsGeneration else { return }
                totalSize = size
                volumeText = volume
                metricsLoading = false
            }
        }
    }

    /// 操作完成后重新读一遍属性，并且通知外面的列表刷新
    private func reloadAfterChange() {
        let snapshot: PathItem? = FileSystemService.item(at: path_)
        item = snapshot
        if let current = snapshot {
            modeText = current.octalMode
            ownerText = current.ownerString
        }
        onChange()
        refreshMetrics()
    }

    private func fail(_ error: Error, what: String) {
        let message = error.localizedDescription
        errorMessage = message
        showError = true
        statusText = ""
        DSLog.shared.error("\(what)失败：\(message)", source: "查看器")
    }

    // MARK: 权限 / 属主

    private func applyMode() {
        let raw = modeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            errorMessage = "请先填写八进制模式，例如 0644"
            showError = true
            return
        }
        isApplyingMode = true
        isBusy = true
        do {
            try FileOperations.chmod(path_, octal: raw)
            statusText = "权限已改为 \(raw)"
            DSLog.shared.info("已把 \(path_) 的权限改为 \(raw)", source: "查看器")
            reloadAfterChange()
        } catch {
            fail(error, what: "修改权限")
        }
        isApplyingMode = false
        isBusy = false
    }

    private func applyOwner() {
        let raw = ownerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            errorMessage = "请先填写属主，例如 mobile:mobile"
            showError = true
            return
        }
        isApplyingOwner = true
        isBusy = true
        do {
            try FileOperations.chown(path_, owner: raw, recursive: chownRecursive)
            statusText = chownRecursive ? "属主已递归改为 \(raw)" : "属主已改为 \(raw)"
            DSLog.shared.info("已把 \(path_) 的属主改为 \(raw)（递归：\(chownRecursive ? "是" : "否")）", source: "查看器")
            reloadAfterChange()
        } catch {
            fail(error, what: "修改属主")
        }
        isApplyingOwner = false
        isBusy = false
    }

    // MARK: 动作

    private func share() {
        guard FileSystemService.exists(path_) else {
            errorMessage = "文件已经不存在了：\(path_)"
            showError = true
            return
        }
        // 分享面板由 UIKit 自己持有并展示，这里不需要等待回调
        DSPickers.presentShareSheet(urls: [URL(fileURLWithPath: path_)])
        DSLog.shared.info("已弹出分享面板：\(path_)", source: "查看器")
    }

    private func copyPath() {
        UIPasteboard.general.string = path_
        statusText = "路径已复制到剪贴板"
        DSLog.shared.info("已复制路径 \(path_)", source: "查看器")
    }

    private func rename(to newName: String) {
        isBusy = true
        do {
            let target = try FileOperations.rename(path_, to: newName)
            path_ = target
            statusText = "已重命名为 \(newName)"
            DSLog.shared.info("已把 \(path_) 重命名为 \(target)", source: "查看器")
            reloadAfterChange()
        } catch {
            fail(error, what: "重命名")
        }
        isBusy = false
    }

    private func duplicate() {
        isDuplicating = true
        isBusy = true
        do {
            let target = try FileOperations.duplicate(path_)
            statusText = "已复制为 \((target as NSString).lastPathComponent)"
            DSLog.shared.info("已复制 \(path_) → \(target)", source: "查看器")
            onChange()
        } catch {
            fail(error, what: "复制")
        }
        isDuplicating = false
        isBusy = false
    }

    /// 目标目录存在时把文件名接上去；填的就是完整目标路径时直接用
    private func move(to destination: String) {
        var target = destination
        if FileSystemService.isDirectory(target) {
            target = FileSystemService.join(target, displayName)
        }
        guard target != path_ else {
            errorMessage = "目标路径和当前位置一样"
            showError = true
            return
        }
        isBusy = true
        do {
            try FileOperations.move(path_, to: target)
            path_ = target
            statusText = "已移动到 \(target)"
            DSLog.shared.info("已把 \(path_) 移动到 \(target)", source: "查看器")
            reloadAfterChange()
        } catch {
            fail(error, what: "移动")
        }
        isBusy = false
    }

    private func performDelete() {
        isDeleting = true
        isBusy = true
        do {
            try FileOperations.delete(path_)
            DSLog.shared.info("已删除 \(path_)", source: "查看器")
            onChange()
            isDeleting = false
            isBusy = false
            presentationMode.wrappedValue.dismiss()
        } catch {
            fail(error, what: "删除")
            isDeleting = false
            isBusy = false
        }
    }
}
