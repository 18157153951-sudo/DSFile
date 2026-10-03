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
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var rootMode: RootMode
    @State private var currentPath: String = ""
    @State private var items: [PathItem] = []
    @State private var errorText: String?
    @State private var isLoading = false
    @State private var showHidden = false
    @State private var hasFileAccess = true

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
         onPick: @escaping (String) -> Void) {
        self.app = app
        self.localFileName = localFileName
        self.initialTarget = initialTarget
        self.pickFolders = pickFolders
        self.onPick = onPick

        // 初始根目录：优先跟着已绑定的路径走
        let dataPath = app.dataPath ?? ""
        let useBundle = initialTarget?.hasPrefix(app.bundlePath) == true && !app.bundlePath.isEmpty
        _rootMode = State(initialValue: (useBundle || dataPath.isEmpty) ? .bundle : .data)
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("根目录", selection: $rootMode) {
                        Text("数据容器").tag(RootMode.data)
                        Text("包体").tag(RootMode.bundle)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前根目录：")
                        Text(rootPath.isEmpty ? "（没有这个容器）" : rootPath)
                            .font(.system(.caption2, design: .monospaced))
                        if pickFolders {
                            Text("进到想替换的那个文件夹里，再点右上角「选择此文件夹」。")
                                .foregroundColor(.orange)
                        }
                    }
                    .font(.footnote)
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
                } else if rootPath.isEmpty {
                    Section {
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

                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在读取…")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else if let errorText = errorText {
                        HStack(spacing: 12) {
                            Image(systemName: "xmark.octagon.fill")
                                .font(.title3)
                                .foregroundColor(.red)
                                .frame(width: 28)
                            Text(errorText)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else if items.isEmpty {
                        Text("这个目录是空的")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(items) { item in
                            Button {
                                handle(item)
                            } label: {
                                browserRow(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(pickFolders ? "选择目标文件夹" : "选择目标文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                // 注意：条件必须写在 ToolbarItem 的「内容」里。
                // 直接对 ToolbarItem 本身用 if 会走 ToolbarContentBuilder 的 buildIf（iOS 16+），
                // 而本 App 最低支持 iOS 15。
                ToolbarItem(placement: .confirmationAction) {
                    if pickFolders {
                        Button("选择此文件夹") {
                            onPick(currentPath)
                            dismiss()
                        }
                        .disabled(!hasFileAccess || currentPath.isEmpty)
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
            .onAppear(perform: prepare)
            .onChange(of: rootMode) { _ in
                currentPath = rootPath
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

            if !item.isDirectory && item.name == localFileName {
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
        switch rootMode {
        case .data: return app.dataPath ?? ""
        case .bundle: return app.bundlePath
        }
    }

    private var relativePath: String {
        guard !rootPath.isEmpty, currentPath.hasPrefix(rootPath) else { return currentPath }
        let tail = String(currentPath.dropFirst(rootPath.count))
        return tail.isEmpty ? "" : tail
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
            currentPath = item.path
            reload()
            return
        }
        // 文件夹模式只选目录：点文件不绑定（避免误把文件当文件夹目标）
        if pickFolders { return }
        onPick(item.path)
        dismiss()
    }

    private func goUp() {
        guard currentPath != rootPath, let parent = FileSystemService.parent(of: currentPath) else { return }
        if parent.count < rootPath.count {
            currentPath = rootPath
        } else {
            currentPath = parent
        }
        reload()
    }
}
