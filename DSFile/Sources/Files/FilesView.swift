//
//  FilesView.swift — 文件页（浏览 / 排序 / 过滤 / 新建 / 删除 / 打开）
//

import SwiftUI
import Foundation
import UIKit

// MARK: - 浏览状态

/// 面包屑的一节（元组不能做 ForEach 的 id，这里包一层）
struct PathCrumb: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

/// 快捷跳转书签
struct PathBookmark: Identifiable, Hashable {
    let title: String
    let path: String
    var id: String { path }
}

/// 目录切换方向：决定过渡动画从哪一侧滑入（文件页与「替换」页的目标浏览器共用同一套语义）
enum NavDirection { case forward, backward }

final class BrowserModel: ObservableObject {

    @Published var currentPath: String = "/"
    /// 最近一次目录切换的方向：只影响过渡动画（进子目录从右滑入、返回上级从左滑入）
    @Published var navDirection: NavDirection = .forward
    @Published var items: [PathItem] = []
    @Published var showHidden: Bool = false
    @Published var sortKey: PathSortKey = .name
    @Published var ascending: Bool = true
    @Published var filter: String = ""
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false
    @Published var volumeText: String = ""

    /// 没激活内核、也不是越狱/TrollStore 环境时，只能待在 App 自己的沙盒里
    static func defaultStartPath() -> String {
        if EnvironmentProbe.hasFileSystemAccess() { return "/" }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    }

    var visibleItems: [PathItem] {
        guard !filter.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var ancestors: [PathCrumb] {
        return FileSystemService.components(of: currentPath).map { component in
            PathCrumb(name: component.name, path: component.path)
        }
    }

    func load(path: String? = nil) {
        // 目录切换加一点过渡动画（与「替换」页的目标浏览器保持一致的时长与曲线）。
        // 方向自动判断：新路径比当前路径更深（是它的子路径）＝进入子目录，否则＝返回上级。
        // 这里只做轻量的 withAnimation + 路径栏的滑动过渡：文件页的 List 还挂着搜索/编辑/多选/
        // 属性面板，给它加 .id(currentPath) 会重建行标识、有打断这些状态的风险，所以列表本身
        // 只做隐式过渡（行内容变化照样有动画），行为零变化。
        if let path = path {
            let goingForward = path.count > currentPath.count && path.hasPrefix(currentPath)
            withAnimation(.easeOut(duration: 0.18)) {
                currentPath = path
                navDirection = goingForward ? .forward : .backward
            }
        }
        let target = currentPath
        let hidden = showHidden
        let key = sortKey
        let asc = ascending

        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loaded: [PathItem] = []
            var failure: String?
            do {
                loaded = try FileSystemService.list(path: target, showHidden: hidden, sortKey: key, ascending: asc)
            } catch {
                failure = error.localizedDescription
            }
            let volume = FileSystemService.volumeInfo(for: target) ?? ""
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.items = loaded
                self.errorMessage = failure
                self.volumeText = volume
                self.isLoading = false
            }
        }
    }

    func reload() { load() }

    func navigate(to path: String) { load(path: path) }

    func enter(_ item: PathItem) {
        guard item.isDirectory else { return }
        load(path: item.path)
    }

    func goUp() {
        guard let parent = FileSystemService.parent(of: currentPath) else { return }
        load(path: parent)
    }
}

// MARK: - 文件页

private enum FileSheet: Identifiable {
    case info(String)
    case text(String)
    case hex(String)
    case actions(String)

    var id: String {
        switch self {
        case .info(let path): return "info-\(path)"
        case .text(let path): return "text-\(path)"
        case .hex(let path): return "hex-\(path)"
        case .actions(let path): return "actions-\(path)"
        }
    }

    var path: String {
        switch self {
        case .info(let path), .text(let path), .hex(let path), .actions(let path): return path
        }
    }
}

struct FilesView: View {

    @EnvironmentObject private var kernel: KernelCenter
    @EnvironmentObject private var browser: BrowserModel

    @State private var sheet: FileSheet?
    @State private var pendingDelete: PathItem?
    @State private var operationError: String?
    @State private var renameTarget: PathItem?
    @State private var renameText: String = ""
    @State private var newFolderVisible = false
    @State private var newFileVisible = false
    @State private var newName: String = ""
    @State private var gotoVisible = false
    @State private var gotoText: String = ""
    @State private var appManagerVisible = false

    private let bookmarks: [PathBookmark] = [
        PathBookmark(title: "根目录", path: "/"),
        PathBookmark(title: "用户数据", path: "/var/mobile"),
        PathBookmark(title: "App 包体", path: AppScanner.bundleRoot),
        PathBookmark(title: "App 数据容器", path: AppScanner.dataRoot),
        PathBookmark(title: "系统字体", path: "/System/Library/Fonts"),
        PathBookmark(title: "偏好设置", path: "/var/mobile/Library/Preferences"),
        PathBookmark(title: "我的文件", path: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/")
    ]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !kernel.phase.isActive {
                    kernelBanner
                }
                pathBar
                filterBar
                content
            }
            .navigationTitle(appContainerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(item: $sheet) { item in
                sheetContent(for: item)
            }
            .sheet(isPresented: $appManagerVisible) {
                AppManagerView()
                    .environmentObject(browser)
            }
            .alert("新建文件夹", isPresented: $newFolderVisible) {
                TextField("文件夹名称", text: $newName)
                Button("取消", role: .cancel) { newName = "" }
                Button("创建") { createFolder() }
            }
            .alert("新建空文件", isPresented: $newFileVisible) {
                TextField("文件名", text: $newName)
                Button("取消", role: .cancel) { newName = "" }
                Button("创建") { createFile() }
            }
            .alert("跳转到路径", isPresented: $gotoVisible) {
                TextField("/var/mobile/...", text: $gotoText)
                Button("取消", role: .cancel) { gotoText = "" }
                Button("跳转") { jump() }
            }
            .alert("重命名", isPresented: renameBinding) {
                TextField("新名称", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("确定") { performRename() }
            }
            .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
                Button("删除", role: .destructive) { performDelete() }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("删除后无法恢复；如果是别人的 App，请先确认你有权修改。")
            }
            .alert("操作失败", isPresented: errorBinding) {
                Button("好", role: .cancel) { operationError = nil }
            } message: {
                Text(operationError ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 顶部区域

    private var kernelBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundColor(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("未激活内核访问").font(.subheadline)
                Text("现在只能看到 App 自己的沙盒目录。").font(.caption2).foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                kernel.activate()
            } label: {
                Text("激活").font(.footnote).fontWeight(.semibold)
            }
            .disabled(kernel.busy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
    }

    private var pathBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(browser.ancestors, id: \.path) { component in
                        Button {
                            browser.navigate(to: component.path)
                        } label: {
                            Text(component.name == "/" ? "根目录" : component.name)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(UIColor.tertiarySystemBackground))
                                .cornerRadius(6)
                        }
                        .buttonStyle(PlainButtonStyle())

                        if component.path != browser.currentPath {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 32)

            HStack(spacing: 8) {
                Text(browser.currentPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if browser.isLoading {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)

            if !browser.volumeText.isEmpty {
                Text(browser.volumeText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 6)
        // 路径栏跟着目录切换做**淡入淡出**（不做全宽位移：位移 + 异步加载观感更差）。
        // 只给这条「没有内部状态」的路径栏换标识，安全；列表本身保持 identity 不变。
        .id(browser.currentPath)
        .transition(.opacity)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.footnote)
            TextField("在当前目录里过滤", text: $browser.filter)
                .font(.footnote)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            if !browser.filter.isEmpty {
                Button {
                    browser.filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(UIColor.secondarySystemBackground))
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if let message = browser.errorMessage, browser.items.isEmpty {
            errorState(message)
        } else if browser.items.isEmpty {
            emptyState
        } else if browser.visibleItems.isEmpty {
            noMatchState
        } else {
            fileList
        }
    }

    private var fileList: some View {
        List {
            // 进到某个 App 的包体/数据容器时，顶部显示它的图标与桌面名字
            if AppPathResolver.shared.resolve(path: browser.currentPath) != nil {
                Section {
                    AppPathHeaderIfAny(path: browser.currentPath)
                }
            }
            ForEach(browser.visibleItems) { item in
                Button {
                    open(item)
                } label: {
                    FileRow(item: item)
                }
                .buttonStyle(PlainButtonStyle())
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = item
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        share(item)
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    contextMenu(for: item)
                }
            }
        }
        .listStyle(.insetGrouped)
        // 目录切换时列表内容的变化也跟着动画（行为不变，只是把突变变成 0.22s 的过渡）
        .animation(.easeOut(duration: 0.18), value: browser.currentPath)
        .refreshable {
            browser.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .myfilzaFileSystemAccessChanged)) { _ in
            // 激活成功 / 提权成功：权限变了，当前目录重新列一次（之前可能因为没权限是空的）
            browser.reload()
        }
    }

    @ViewBuilder
    private func contextMenu(for item: PathItem) -> some View {
        if !item.isDirectory {
            Button {
                sheet = .text(item.path)
            } label: {
                Label("文本编辑", systemImage: "doc.text")
            }
            Button {
                sheet = .hex(item.path)
            } label: {
                Label("十六进制查看", systemImage: "square.grid.3x3")
            }
        }
        Button {
            sheet = .info(item.path)
        } label: {
            Label("属性 / 权限", systemImage: "info.circle")
        }
        Button {
            renameTarget = item
            renameText = item.name
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button {
            UIPasteboard.general.string = item.path
            DSLog.shared.info("已复制路径 \(item.path)", source: "文件")
        } label: {
            Label("复制路径", systemImage: "doc.on.doc")
        }
        Button {
            share(item)
        } label: {
            Label("分享", systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive) {
            pendingDelete = item
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("这个目录是空的").font(.headline)
            Text("下拉可以刷新；用右上角「+」可以新建文件或文件夹。").font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("没有匹配的条目").font(.headline)
            Text("清空搜索框可以看到全部 \(browser.items.count) 项。").font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text("读不到这个目录").font(.headline)
            Text(message).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            if !kernel.phase.isActive {
                Button {
                    kernel.activate()
                } label: {
                    Text("激活内核访问").fontWeight(.semibold)
                }
                .disabled(kernel.busy)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 工具栏

    /// 当前目录属于某个 App 的包体/数据容器时，标题用它的桌面名字
    private var appContainerTitle: String {
        if let resolved = AppPathResolver.shared.resolve(path: browser.currentPath) {
            return resolved.app.name
        }
        return "文件"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                browser.goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(browser.currentPath == "/")
        }
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                appManagerVisible = true
            } label: {
                Image(systemName: "square.grid.2x2")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    newName = ""
                    newFolderVisible = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                Button {
                    newName = ""
                    newFileVisible = true
                } label: {
                    Label("新建空文件", systemImage: "doc.badge.plus")
                }
                Button {
                    gotoText = browser.currentPath
                    gotoVisible = true
                } label: {
                    Label("跳转到路径…", systemImage: "arrow.right.doc.on.clipboard")
                }
                Button {
                    browser.reload()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                ForEach(PathSortKey.allCases) { key in
                    Button {
                        browser.sortKey = key
                        browser.reload()
                    } label: {
                        if browser.sortKey == key {
                            Label(key.label, systemImage: "checkmark")
                        } else {
                            Text(key.label)
                        }
                    }
                }
                Divider()
                Button {
                    browser.ascending.toggle()
                    browser.reload()
                } label: {
                    Label(browser.ascending ? "改为降序" : "改为升序", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    browser.showHidden.toggle()
                    browser.reload()
                } label: {
                    Label(browser.showHidden ? "隐藏点文件" : "显示点文件", systemImage: "eye")
                }
                Divider()
                ForEach(bookmarks) { bookmark in
                    Button {
                        browser.navigate(to: bookmark.path)
                    } label: {
                        Label(bookmark.title, systemImage: "bookmark")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - 动作

    private func open(_ item: PathItem) {
        if item.isDirectory {
            browser.enter(item)
        } else {
            sheet = .actions(item.path)
        }
    }

    private func share(_ item: PathItem) {
        DSPickers.presentShareSheet(urls: [URL(fileURLWithPath: item.path)])
    }

    private func createFolder() {
        let name = newName
        newName = ""
        do {
            let path = try FileOperations.createFolder(in: browser.currentPath, name: name)
            DSLog.shared.info("新建文件夹 \(path)", source: "文件")
            browser.reload()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func createFile() {
        let name = newName
        newName = ""
        do {
            let path = try FileOperations.createFile(in: browser.currentPath, name: name)
            DSLog.shared.info("新建文件 \(path)", source: "文件")
            browser.reload()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func jump() {
        let target = gotoText
        gotoText = ""
        guard !target.isEmpty else { return }
        if FileSystemService.exists(target) {
            browser.navigate(to: target)
        } else {
            operationError = "路径不存在：\(target)"
        }
    }

    private func performRename() {
        guard let item = renameTarget else { return }
        let newName = renameText
        renameTarget = nil
        renameText = ""
        do {
            let path = try FileOperations.rename(item.path, to: newName)
            DSLog.shared.info("重命名 \(item.path) → \(path)", source: "文件")
            browser.reload()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func performDelete() {
        guard let item = pendingDelete else { return }
        pendingDelete = nil
        do {
            try FileOperations.delete(item.path)
            DSLog.shared.info("删除 \(item.path)", source: "文件")
            browser.reload()
        } catch {
            operationError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func sheetContent(for item: FileSheet) -> some View {
        switch item {
        case .info(let path):
            FileInfoView(path: path, onChange: { browser.reload() })
        case .text(let path):
            TextFileView(path: path)
        case .hex(let path):
            HexViewerView(path: path)
        case .actions(let path):
            FileActionsView(path: path,
                            onOpenText: { sheet = .text(path) },
                            onOpenHex: { sheet = .hex(path) },
                            onOpenInfo: { sheet = .info(path) },
                            onChange: { browser.reload() })
        }
    }

    // MARK: - 绑定

    private var deleteBinding: Binding<Bool> {
        return Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var deleteTitle: String {
        return "删除「\(pendingDelete?.name ?? "")」？"
    }

    private var renameBinding: Binding<Bool> {
        return Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        return Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )
    }
}

// MARK: - 行

struct FileRow: View {

    let item: PathItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .font(.title3)
                .foregroundColor(item.isDirectory ? .blue : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.kindName) · \(item.sizeString) · \(item.modifiedString)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text("\(item.modeString)  \(item.ownerString)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if item.isSymlink {
                Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundColor(.secondary)
            } else if item.isDirectory {
                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 文件动作面板（非目录点击后弹出）

struct FileActionsView: View {

    let path: String
    let onOpenText: () -> Void
    let onOpenHex: () -> Void
    let onOpenInfo: () -> Void
    let onChange: () -> Void

    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section("文件") {
                    if let item = PathItem.make(path: path) {
                        HStack(spacing: 12) {
                            Image(systemName: item.iconName)
                                .font(.title3)
                                .foregroundColor(.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                                Text("\(item.kindName) · \(item.sizeString) · \(item.modifiedString)")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        Text(path)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } else {
                        Text("文件已经不存在了").font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                        onOpenText()
                    } label: {
                        Label("文本编辑", systemImage: "doc.text")
                    }
                    Button {
                        presentationMode.wrappedValue.dismiss()
                        onOpenHex()
                    } label: {
                        Label("十六进制查看", systemImage: "square.grid.3x3")
                    }
                    Button {
                        DSPickers.presentShareSheet(urls: [URL(fileURLWithPath: path)])
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = path
                        onChange()
                    } label: {
                        Label("复制路径", systemImage: "doc.on.doc")
                    }
                    Button {
                        presentationMode.wrappedValue.dismiss()
                        onOpenInfo()
                    } label: {
                        Label("属性 / 权限", systemImage: "info.circle")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("打开方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
