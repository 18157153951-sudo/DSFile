//
//  TargetFileBrowser.swift — 浏览目标 App 内部目录，挑出要替换的目标（文件 / 文件夹）
//
//  统一交互（0.4.0 起，三种模式完全一致，不再有"能不能选文件夹"的差别）：
//    · 点「文件」行      = 选中 / 取消选中（可多选，行尾打勾，顶部显示「已选 N 项」）
//    · 点「文件夹」行    = 进入该目录
//    · 长按「文件夹」行  = 「选为文件夹目标」（把那个文件夹本身当成目标）
//    · 右上角「确定」    = 有选中项 → 返回全部选中项（文件/文件夹都算）；
//                          没有选中项 → 返回**当前所在目录**
//      这个按钮**永远可用**（只要路径非空且有文件系统权限）：在根目录按它 = 整个 .app / 数据容器。
//
//  没激活内核访问、也不是越狱环境时，这里给出明确提示而不是空白列表。
//

import SwiftUI

struct TargetFileBrowserSheet: View {

    let app: InstalledApp
    /// 标题兜底：解析不出 App 名字时用它（例如「选择目标文件 / 文件夹」）
    let actionTitle: String
    let initialTarget: String?
    /// 非 nil = 根目录锁定在这个路径（包体(.app)模式把根固定为 .app，不显示根目录切换）
    let lockedRoot: String?
    /// 本地待替换文件的文件名，只用于给同名行打一个「同名」标记（可为空）
    let highlightName: String?
    /// 确定回调：选中项（可能多个，文件与文件夹混选）；没有选中项时返回 [当前目录]
    let onConfirm: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var rootMode: RootMode
    @State private var currentPath: String = ""
    @State private var items: [PathItem] = []
    @State private var errorText: String?
    @State private var isLoading = false
    @State private var showHidden = false
    @State private var hasFileAccess = true
    /// 已选中的路径（文件与文件夹混放；跨目录保留）
    @State private var selection: Set<String> = []

    enum RootMode: String, CaseIterable, Identifiable {
        case data
        case bundle

        var id: String { rawValue }
        var title: String { self == .data ? "数据容器" : "包体" }
    }

    init(app: InstalledApp,
         actionTitle: String = "选择目标文件 / 文件夹",
         initialTarget: String? = nil,
         lockedRoot: String? = nil,
         highlightName: String? = nil,
         onConfirm: @escaping ([String]) -> Void) {
        self.app = app
        self.actionTitle = actionTitle
        self.initialTarget = initialTarget
        self.lockedRoot = lockedRoot
        self.highlightName = highlightName
        self.onConfirm = onConfirm

        // 初始根目录：优先跟着已绑定的路径走；锁定时固定为 .bundle 视图
        let dataPath = app.dataPath ?? ""
        let useBundle = initialTarget?.hasPrefix(app.bundlePath) == true && !app.bundlePath.isEmpty
        _rootMode = State(initialValue: (lockedRoot != nil || useBundle || dataPath.isEmpty) ? .bundle : .data)
    }

    // MARK: - 主体（拆成几个小 computed property：整段 body 过大会让 Swift 类型检查超时）

    var body: some View {
        NavigationView {
            browserList
                .listStyle(.insetGrouped)
                .navigationTitle(browserTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { browserToolbar }
                .animation(.easeOut(duration: 0.18), value: currentPath)
                .onAppear(perform: prepare)
                .onChange(of: rootMode) { _ in
                    withAnimation(.easeOut(duration: 0.18)) {
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

    private var browserList: some View {
        List {
            rootPickerSection
            appHeaderSection
            contentSection
        }
    }

    @ViewBuilder
    private var rootPickerSection: some View {
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
                Text("点文件 = 选中（可多选）；点文件夹 = 进入；长按文件夹 = 把它选为目标。右上角「确定」：有选中就提交选中的，没选中就把**当前所在目录**当目标（在根目录按它就是整个\(rootMode.title)）。")
                    .foregroundColor(.orange)
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private var appHeaderSection: some View {
        // 正在浏览哪个 App：顶部显示它的图标与桌面名字（解析不出来就什么都不显示）
        if AppPathResolver.shared.resolve(path: currentPath.isEmpty ? rootPath : currentPath) != nil {
            Section {
                AppPathHeaderIfAny(path: currentPath.isEmpty ? rootPath : currentPath)
            }
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if !hasFileAccess {
            noAccessSection
        } else if rootPath.isEmpty {
            Section {
                Text("这个 App 没有可用的\(rootMode.title)路径。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } else {
            Section {
                goUpRow

                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在读取…")
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

                itemRows
            } header: {
                Text(selection.isEmpty ? "当前位置（相对\(rootMode.title)）" : "已选 \(selection.count) 项")
            } footer: {
                if !selection.isEmpty {
                    Button(role: .destructive) {
                        selection.removeAll()
                    } label: {
                        Label("清除选择（回到「选当前文件夹」）", systemImage: "xmark.circle")
                            .font(.footnote)
                    }
                }
            }
        }
    }

    private var noAccessSection: some View {
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
    }

    private var goUpRow: some View {
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
    }

    /// 目录内容：切换目录只做淡入淡出（不做全宽位移——位移 + 异步加载容易闪/顿）
    private var itemRows: some View {
        ForEach(items) { item in
            Button {
                handle(item)
            } label: {
                browserRow(item)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if item.isDirectory {
                    Button {
                        confirm(paths: [item.path])
                    } label: {
                        Label("选为文件夹目标", systemImage: "folder.badge.plus")
                    }
                    Button {
                        enter(item)
                    } label: {
                        Label("进入这个文件夹", systemImage: "arrow.down.right")
                    }
                } else {
                    Button {
                        toggle(item.path)
                    } label: {
                        Label(selection.contains(item.path) ? "取消选中" : "选中这个文件",
                              systemImage: selection.contains(item.path) ? "circle" : "checkmark.circle")
                    }
                }
            }
        }
        .transition(.opacity)
        .id(currentPath)
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }
        }
        // 右上角「确定」：永远可用（只要路径非空 + 有权限）。
        // 有选中项 → 提交全部选中项；没有 → 提交当前所在目录。
        ToolbarItem(placement: .confirmationAction) {
            Button(confirmTitle) {
                confirm(paths: selection.isEmpty ? [currentDirectory] : Array(selection))
            }
            .disabled(!canConfirm)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Toggle(isOn: $showHidden) {
                    Label("显示隐藏文件", systemImage: "eye")
                }
                Button {
                    confirm(paths: [currentDirectory])
                } label: {
                    Label("选择当前文件夹", systemImage: "folder.badge.plus")
                }
                if !selection.isEmpty {
                    Button(role: .destructive) {
                        selection.removeAll()
                    } label: {
                        Label("清除选择", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
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

            if selection.contains(item.path) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
            } else if !item.isDirectory, let highlightName = highlightName, item.name == highlightName {
                Text("同名")
                    .font(.caption2)
                    .foregroundColor(.green)
            }

            Image(systemName: item.isDirectory ? "chevron.right" : "plus.circle")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 状态与行为

    private var rootPath: String {
        if let locked = lockedRoot, !locked.isEmpty { return locked }
        switch rootMode {
        case .data: return app.dataPath ?? ""
        case .bundle: return app.bundlePath
        }
    }

    private var currentDirectory: String {
        currentPath.isEmpty ? rootPath : currentPath
    }

    /// 正在浏览哪个 App 就用它的桌面名字当标题；解析不出来时回到动作名
    private var browserTitle: String {
        if let resolved = AppPathResolver.shared.resolve(path: currentDirectory) {
            return resolved.app.name
        }
        return actionTitle
    }

    private var relativePath: String {
        guard !rootPath.isEmpty, currentPath.hasPrefix(rootPath) else { return currentPath }
        let tail = String(currentPath.dropFirst(rootPath.count))
        return tail.isEmpty ? "" : tail
    }

    private var confirmTitle: String {
        selection.isEmpty ? "确定" : "确定(\(selection.count))"
    }

    private var canConfirm: Bool {
        hasFileAccess && !currentDirectory.isEmpty
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
        // 点文件夹 = 进入；点文件 = 选中 / 取消选中
        if item.isDirectory && !item.isSymlink {
            enter(item)
            return
        }
        toggle(item.path)
    }

    private func enter(_ item: PathItem) {
        withAnimation(.easeOut(duration: 0.18)) {
            currentPath = item.path
        }
        reload()
    }

    private func toggle(_ path: String) {
        if selection.contains(path) {
            selection.remove(path)
        } else {
            selection.insert(path)
        }
    }

    private func confirm(paths: [String]) {
        let cleaned = paths.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        onConfirm(cleaned)
        dismiss()
    }

    private func goUp() {
        guard currentPath != rootPath, let parent = FileSystemService.parent(of: currentPath) else { return }
        let target = parent.count < rootPath.count ? rootPath : parent
        withAnimation(.easeOut(duration: 0.18)) {
            currentPath = target
        }
        reload()
    }
}
