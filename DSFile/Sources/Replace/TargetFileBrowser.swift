//
//  TargetFileBrowser.swift — 浏览目标 App 内部目录，点一个文件就当目标路径
//
//  三条绑定路径里的第三条（另外两条：按文件名自动匹配、手填完整路径）。
//  默认根目录是目标 App 的数据容器（{app.data}），顶部可切到包体（{app.bundle}）。
//  没激活内核访问、也不是越狱环境时，这里给出明确提示而不是空白列表。
//

import SwiftUI

struct TargetFileBrowserSheet: View {

    let app: InstalledApp
    /// 本地待替换文件的文件名，只用于提示与标题
    let localFileName: String
    let initialTarget: String?
    /// true = 文件夹模式：工具栏出现「选择此文件夹」，把当前所在目录当作目标
    let pickFolders: Bool
    /// 非 nil = 根目录锁定在这个路径（包体(.app)模式用它把根固定为 .app，不显示根目录切换）
    let lockedRoot: String?
    /// true = 多选：右上角出现「选择」，勾选多个文件后一次性回调（目标优先绑定用）
    let allowsMultipleSelection: Bool
    /// 右上角「选择此文件夹」的回调（优先级最高）。
    /// 为 nil 时：pickFolders == true 就走 onPick(当前目录)；否则按钮**禁用**（禁用原因见 folderPickHint）。
    let onPickFolder: ((String) -> Void)?
    /// 不能选文件夹时，footer 里说明原因（例如「文件模式只能选文件」）
    let folderPickHint: String?
    let onPickMany: (([String]) -> Void)?
    let onPick: (String) -> Void

    /// 目录切换方向：决定过渡动画从哪一侧滑入
    private enum NavDirection { case forward, backward }

    @Environment(\.dismiss) private var dismiss

    @State private var rootMode: RootMode
    @State private var currentPath: String = ""
    @State private var items: [PathItem] = []
    @State private var errorText: String?
    @State private var isLoading = false
    @State private var showHidden = false
    @State private var hasFileAccess = true
    /// 多选模式：是否处于勾选状态、已勾选的路径
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    /// 最近一次目录切换的方向（进入子目录 = forward，返回上级 = backward），只影响过渡动画
    @State private var navDirection: NavDirection = .forward

    enum RootMode: String, CaseIterable, Identifiable {
        case data
        case bundle

        var id: String { rawValue }
        var title: String { self == .data ? "数据容器" : "包体" }
    }

    init(app: InstalledApp,
         localFileName: String,
         initialTarget: String?,
         pickFolders: Bool = false,
         lockedRoot: String? = nil,
         allowsMultipleSelection: Bool = false,
         onPickFolder: ((String) -> Void)? = nil,
         folderPickHint: String? = nil,
         onPickMany: (([String]) -> Void)? = nil,
         onPick: @escaping (String) -> Void) {
        self.app = app
        self.localFileName = localFileName
        self.initialTarget = initialTarget
        self.pickFolders = pickFolders
        self.lockedRoot = lockedRoot
        self.allowsMultipleSelection = allowsMultipleSelection
        self.onPickFolder = onPickFolder
        self.folderPickHint = folderPickHint
        self.onPickMany = onPickMany
        self.onPick = onPick

        // 初始根目录：优先跟着已绑定的路径走；锁定时固定为 .bundle 视图
        let dataPath = app.dataPath ?? ""
        let useBundle = initialTarget?.hasPrefix(app.bundlePath) == true && !app.bundlePath.isEmpty
        _rootMode = State(initialValue: (lockedRoot != nil || useBundle || dataPath.isEmpty) ? .bundle : .data)
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    if lockedRoot == nil {
                        Picker("根目录", selection: $rootMode) {
                            Text("数据容器").tag(RootMode.data)
                            Text("包体").tag(RootMode.bundle)
                        }
                        .pickerStyle(.segmented)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前根目录：")
                        Text(rootPath.isEmpty ? "（没有这个容器）" : rootPath)
                            .font(.system(.caption2, design: .monospaced))
                        Text("右上角「选择此文件夹」= 把**当前所在目录**当成目标；在根目录按它就是整个\(rootMode.title)。")
                            .foregroundColor(.orange)
                        Text("三种模式都支持：文件模式会新增一条「文件夹绑定」（整目录镜像替换 + 递归备份）；文件夹 / 包体模式会直接绑到当前源文件夹。")
                            .foregroundColor(.secondary)
                        if let hint = folderPickHint {
                            Text(hint)
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.footnote)
                }

                // 正在浏览哪个 App：顶部显示它的图标与桌面名字（解析不出来就什么都不显示）
                if AppPathResolver.shared.resolve(path: currentPath.isEmpty ? rootPath : currentPath) != nil {
                    Section {
                        AppPathHeaderIfAny(path: currentPath.isEmpty ? rootPath : currentPath)
                    }
                }

                if !hasFileAccess {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title3)
                                .foregroundColor(.orange)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("现在读不到目标 App 的目录")
                                    .font(.subheadline)
                                Text("请到「设置」页点『激活内核访问』；越狱 / roothide / TrollStore 环境下直接就能读。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } else if rootPath.isEmpty {                    Section {
                        Text("这个 App 没有可用的\(rootMode.title)路径。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        Button {
                            goUp()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.up.left")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("返回上级")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text(relativePath.isEmpty ? "/" : relativePath)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(currentPath == rootPath)
                    } header: {
                        Text("当前位置（相对\(rootMode.title)）")
                    }

                    // 加载时**保留旧内容**，只在上面加一行小进度提示。
                    // 之前是把整段列表换成转圈，切换目录时会闪出半屏空白，观感很差。
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(items.isEmpty ? "正在读取…" : "正在读取…")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let errorText = errorText, items.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "xmark.octagon.fill")
                                .font(.title3)
                                .foregroundColor(.red)
                                .frame(width: 28)
                            Text(errorText)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }

                    if items.isEmpty && !isLoading && errorText == nil {
                        Text("这个目录是空的")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    // 目录切换只做**淡入淡出**（不做全宽位移）：位移 + 异步加载容易闪/顿，观感更差；
                    // 纯淡入淡出在 iOS 15 上最稳。.id(currentPath) 让 SwiftUI 把这批行当成新内容走 transition。
                    ForEach(items) { item in
                        Button {
                            handle(item)
                        } label: {
                            browserRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                    .transition(.opacity)
                    .id(currentPath)

                    if allowsMultipleSelection && isSelecting {
                        Button {
                            let picked = items.filter { selection.contains($0.path) }.map { $0.path }
                            guard !picked.isEmpty else { return }
                            onPickMany?(picked)
                            dismiss()
                        } label: {
                            Label("添加已选 \(selection.count) 个目标文件", systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                        }
                        .disabled(selection.isEmpty)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(browserTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                // 注意：条件必须写在 ToolbarItem 的「内容」里。
                // 直接对 ToolbarItem 本身用 if 会走 ToolbarContentBuilder 的 buildIf（iOS 16+），
                // 而本 App 最低支持 iOS 15。
                //
                // 右上角这个按钮在所有模式下都存在，语义统一 =「选择当前所在的这个文件夹」：
                //   · 传了 onPickFolder（目标优先绑定等）→ 用它的回调；
                //   · pickFolders = true（文件夹模式）→ 走 onPick(当前目录)；
                //   · 都不满足（例如文件模式只能选文件）→ 按钮**禁用**，原因写在 footer 的 folderPickHint 里。
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmFolderTitle) {
                        let path = currentPath.isEmpty ? rootPath : currentPath
                        if let onPickFolder = onPickFolder {
                            onPickFolder(path)
                        } else {
                            onPick(path)
                        }
                        dismiss()
                    }
                    .disabled(!canConfirmFolder)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if allowsMultipleSelection {
                        Button(isSelecting ? "完成" : "选择") {
                            isSelecting.toggle()
                            if !isSelecting { selection.removeAll() }
                        }
                        .disabled(!hasFileAccess)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Toggle(isOn: $showHidden) {
                            Label("显示隐藏文件", systemImage: "eye")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .animation(.easeOut(duration: 0.18), value: currentPath)
            .onAppear(perform: prepare)
            .onChange(of: rootMode) { _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    navDirection = .backward
                    currentPath = rootPath
                }
                reload()
            }
            .onChange(of: showHidden) { _ in
                reload()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - 行

    private func browserRow(_ item: PathItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : item.iconName)
                .font(.title3)
                .foregroundColor(item.isDirectory ? .accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.isDirectory ? "文件夹" : "\(item.sizeString) · \(item.modifiedString)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if allowsMultipleSelection && isSelecting && !item.isDirectory {
                Image(systemName: selection.contains(item.path) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(selection.contains(item.path) ? .accentColor : .secondary)
            } else if !item.isDirectory && item.name == localFileName {
                Text("同名")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
            Image(systemName: item.isDirectory ? "chevron.right" : "arrow.down.left.circle")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 行为

    private var rootPath: String {
        // 包体(.app)模式：根锁定在 .app，不跟随根目录切换
        if let locked = lockedRoot, !locked.isEmpty { return locked }
        switch rootMode {
        case .data: return app.dataPath ?? ""
        case .bundle: return app.bundlePath
        }
    }

    /// 正在浏览哪个 App 就用它的桌面名字当标题；解析不出来时回到原来的动作名
    private var browserTitle: String {
        let path = currentPath.isEmpty ? rootPath : currentPath
        if let resolved = AppPathResolver.shared.resolve(path: path) {
            return resolved.app.name
        }
        return pickFolders ? "选择目标文件夹" : "选择目标文件"
    }

    private var relativePath: String {
        guard !rootPath.isEmpty, currentPath.hasPrefix(rootPath) else { return currentPath }
        let tail = String(currentPath.dropFirst(rootPath.count))
        return tail.isEmpty ? "" : tail
    }

    /// 右上角确认按钮的文案：多选勾选态下叫「用此文件夹」，免得和「选择」混淆
    private var confirmFolderTitle: String {
        (allowsMultipleSelection && isSelecting) ? "用此文件夹" : "选择此文件夹"
    }

    /// 能不能把「当前所在目录」当作目标。
    /// 现在三种模式（文件 / 文件夹 / 包体）都支持「选文件夹」，所以只要读得到目录、路径非空就可用。
    private var canConfirmFolder: Bool {
        guard hasFileAccess else { return false }
        let path = currentPath.isEmpty ? rootPath : currentPath
        return !path.isEmpty
    }

    private func prepare() {
        hasFileAccess = EnvironmentProbe.hasFileSystemAccess()
        if !hasFileAccess { return }
        if currentPath.isEmpty || !currentPath.hasPrefix(rootPath) {
            currentPath = rootPath
        }
        reload()
    }

    private func reload() {
        let path = currentPath
        guard !path.isEmpty else { return }
        isLoading = true
        let hidden = showHidden
        DispatchQueue.global(qos: .userInitiated).async {
            var loaded: [PathItem] = []
            var failure: String?
            do {
                loaded = try FileSystemService.list(path: path, showHidden: hidden, sortKey: .name, ascending: true)
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.items = loaded
                self.errorText = failure
                self.isLoading = false
            }
        }
    }

    private func handle(_ item: PathItem) {
        if item.isDirectory && !item.isSymlink {
            withAnimation(.easeOut(duration: 0.18)) {
                navDirection = .forward
                currentPath = item.path
            }
            reload()
            return
        }
        // 文件夹模式只选目录：点文件不绑定（避免误把文件当文件夹目标）
        if pickFolders { return }

        // 多选模式：勾选状态下点文件 = 切换勾选；不在勾选状态 = 直接选它（和单选一样快）
        if allowsMultipleSelection && isSelecting {
            if selection.contains(item.path) {
                selection.remove(item.path)
            } else {
                selection.insert(item.path)
            }
            return
        }
        onPick(item.path)
        dismiss()
    }

    private func goUp() {
        guard currentPath != rootPath, let parent = FileSystemService.parent(of: currentPath) else { return }
        let target = parent.count < rootPath.count ? rootPath : parent
        withAnimation(.easeOut(duration: 0.18)) {
            navDirection = .backward
            currentPath = target
        }
        reload()
    }
}
