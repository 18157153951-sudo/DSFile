//
//  ReplaceWizardView.swift — 「替换」页：一键把本地文件替换进目标 App
//
//  交互照 Morph（原 TweakBuilder）的 AdapterView：
//    目标单选（点已选中的可取消）→ 替换文件按文件名自动匹配（多候选/找不到点行弹 sheet）→
//    一个主按钮 → 固定高度日志区 → 完成后给「查看运行记录 / 一键回滚」。
//
//  替换逻辑**不新写**：把绑定好的 (本地文件 → 目标路径) 组装成一份内存里的 ScriptRecipe，
//  交给现有 RecipeRunner 执行 —— 于是自动获得：执行前整份备份（RunStore）、运行记录（Runs/）、
//  记录页一键回滚、fixOwnership（写前把父目录属主改成 mobile:mobile）。
//

import SwiftUI
import UIKit

// MARK: - 状态

final class ReplaceWizardModel: ObservableObject {

    enum FileState {
        case unique
        case ambiguous
        case notFound
        case manual

        var hint: String {
            switch self {
            case .unique: return "已自动匹配"
            case .ambiguous: return "同名多处，点这里选择"
            case .notFound: return "没找到同名文件，点这里手填"
            case .manual: return "已手动指定"
            }
        }
    }

    struct WizardFile: Identifiable, Hashable {
        let id = UUID()
        var localPath: String
        let name: String
        var sizeText: String
        /// 只读转储用不到，但保留字段方便以后扩展
        var targetPath: String?
        var candidates: [String] = []
        var state: FileState = .notFound
        /// true = 这一行的「目标路径」是用户在目标目录里亲手挑的（目标优先绑定）：
        /// 自动匹配不许覆盖它；点这一行的默认动作变成「挑/换本地替换文件」。
        var targetLocked: Bool = false

        var hintText: String {
            if localPath.isEmpty {
                return "还没选本地替换文件：点这一行挑一个"
            }
            if let target = targetPath, !target.isEmpty {
                return "→ \(target)"
            }
            return state.hint
        }
    }

    struct WizardFolder: Identifiable, Hashable {
        let id = UUID()
        let localPath: String
        let name: String
        var itemCount: Int = 0
        var sizeText: String = ""
        var targetPath: String?

        var hintText: String {
            if let target = targetPath, !target.isEmpty {
                return "→ \(target)"
            }
            return "还没选目标文件夹：点这一行去浏览目标 App 目录"
        }
    }

    struct LogLine: Identifiable {
        enum Level {
            case info
            case warning
            case error
            case success
        }

        let id = UUID()
        let level: Level
        let text: String
    }

    // MARK: 状态

    @Published var selectedApp: InstalledApp?
    @Published var files: [WizardFile] = []
    @Published var folders: [WizardFolder] = []
    @Published var logs: [LogLine] = []
    @Published var isRunning = false
    @Published var isRestoring = false
    @Published var isScanningApps = false
    @Published var apps: [InstalledApp] = []
    @Published var lastRunSummary: String?
    @Published var lastBackupId: String?
    @Published var lastRunSucceeded = false
    /// 这一次执行是不是开着自动备份（决定「一键回滚」能不能用）
    @Published var lastBackupEnabled = true
    /// 需要用户去设置页激活时置真，视图据此弹提示
    @Published var needsActivation = false
    /// 上一次运行是不是「整目录」模式（文件夹 / 包体；结果卡片据此显示目录图标）
    @Published var lastRunWasFolders = false
    /// 用户显式保存的自动化任务（只在点「运行」时执行，App 不会自动跑）
    @Published var savedTasks: [ReplaceSavedTask] = []
    /// 当前绑定有没有改动还没保存成任务
    @Published var hasUnsavedChanges = false

    /// 三种模式（持久化；三套绑定互不干扰）
    @Published var mode: ReplaceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            // 文件夹 / 包体模式强制开备份：它们会整目录动文件，没有备份就没有兜底
            if mode == .folders || mode == .bundle {
                autoBackup = true
            }
        }
    }

    /// 「执行前自动备份」开关（持久化；关掉就没有回滚兜底）
    @Published var autoBackup: Bool {
        didSet { UserDefaults.standard.set(autoBackup, forKey: Self.autoBackupKey) }
    }

    /// 包体(.app)模式的语义（镜像 / 合并），持久化
    @Published var bundleSemantics: ReplaceBundleSemantics {
        didSet { UserDefaults.standard.set(bundleSemantics.rawValue, forKey: Self.bundleSemanticsKey) }
    }

    /// 包体模式的源文件（按文件名匹配进 .app）
    @Published var bundleFiles: [WizardFile] = []
    /// 包体模式的源文件夹（最多一个：换 / 并入整个 .app）
    @Published var bundleFolder: WizardFolder?

    static let autoBackupKey = "myfilza.replaceAutoBackup"
    static let modeKey = "myfilza.replaceMode"
    static let bundleSemanticsKey = "myfilza.replaceBundleSemantics"
    /// 本页产生的运行记录统一用这个名字，「最近的替换」按它过滤
    static let runScriptName = ReplaceMode.runPrefix

    init() {
        if let stored = UserDefaults.standard.object(forKey: Self.autoBackupKey) as? Bool {
            autoBackup = stored
        } else {
            autoBackup = true
        }
        if let raw = UserDefaults.standard.string(forKey: Self.modeKey),
           let stored = ReplaceMode(rawValue: raw) {
            mode = stored
        } else {
            mode = .files
        }
        if let raw = UserDefaults.standard.string(forKey: Self.bundleSemanticsKey),
           let stored = ReplaceBundleSemantics(rawValue: raw) {
            bundleSemantics = stored
        } else {
            bundleSemantics = .mirror
        }
        savedTasks = ReplaceTaskStore.load()
    }

    let inboxDirectory: String = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent("ReplaceInbox")
    }()

    /// 文件夹模式的源文件夹根目录
    let folderSourceDirectory: String = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent("ReplaceSources")
    }()

    private var matchToken = UUID()

    // MARK: - 目标 App

    func loadApps(force: Bool = false) {
        isScanningApps = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppScanner.installedApps(force: force)
            DispatchQueue.main.async {
                self.apps = list
                self.isScanningApps = false
                let access = EnvironmentProbe.hasFileSystemAccess()
                self.append("扫描到 \(list.count) 个已安装 App（文件系统访问=\(access ? "是" : "否")）",
                            list.isEmpty ? .warning : .info)
            }
        }
    }

    /// 双保险：DSPickers 内部已经 catch 了所有异常，这里再包一层，
    /// 保证「添加源文件夹」这类入口在任何情况下都只是提示 + 写日志，不会把 App 带走。
    func withPickerSafety(_ label: String, _ body: () -> Void) {
        let ok = DSPickers.performSafely({ body() }, label: label)
        if !ok {
            append("\(label) 失败：系统选择器打不开（原因已写进日志）。", .error)
        }
    }

    /// 进页面时用：列表是空的、而且现在已经有权限 → 强制重扫一次。
    /// （激活成功后列表本来就会被通知刷新；这里兜住「先开替换页、后激活」的顺序。）
    func loadAppsIfNeeded() {
        if apps.isEmpty && EnvironmentProbe.hasFileSystemAccess() {
            loadApps(force: true)
        } else {
            loadApps()
        }
    }

    /// 点已选中的一行 = 取消选择（与 Morph 的适配页一致）
    func toggleSelection(_ app: InstalledApp) {
        if selectedApp?.bundleId == app.bundleId {
            selectedApp = nil
            append("已取消目标选择", .info)
        } else {
            selectedApp = app
            append("目标：\(app.name)（\(app.bundleId)）", .info)
        }
        rematchAll()
        markDirty()
    }

    /// 应用管理器「设为替换页目标 App」：按 bundle id 选中（列表还没加载完就先拉一次）
    func selectAppByBundleId(_ bundleId: String) {
        guard !bundleId.isEmpty else { return }
        if let app = apps.first(where: { $0.bundleId == bundleId }) {
            applySelection(app)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppScanner.installedApps(force: true)
            DispatchQueue.main.async {
                self.apps = list
                if let app = list.first(where: { $0.bundleId == bundleId }) {
                    self.applySelection(app)
                } else {
                    self.append("没找到 bundle id 为 \(bundleId) 的 App", .warning)
                }
            }
        }
    }

    private func applySelection(_ app: InstalledApp) {
        selectedApp = app
        append("目标：\(app.name)（\(app.bundleId)）", .info)
        rematchAll()
        markDirty()
    }

    /// 「更换」按钮：清掉目标（列表重新展开）
    func clearSelection() {
        selectedApp = nil
        append("已取消目标选择", .info)
        rematchAll()
        markDirty()
    }

    // MARK: - 本地文件

    func reloadInbox() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: inboxDirectory, withIntermediateDirectories: true)

        let previous = Dictionary(uniqueKeysWithValues: files.map { ($0.localPath, $0) })
        let names = (try? fm.contentsOfDirectory(atPath: inboxDirectory))?.sorted() ?? []

        var rebuilt: [WizardFile] = []
        for name in names where !name.hasPrefix(".") {
            let full = (inboxDirectory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            if var existing = previous[full] {
                rebuilt.append(existing)
            } else {
                let size = ((try? fm.attributesOfItem(atPath: full))?[.size] as? NSNumber)?.int64Value ?? 0
                rebuilt.append(WizardFile(localPath: full, name: name, sizeText: Self.sizeText(size)))
            }
        }
        files = rebuilt
    }

    func importFiles() {
        // asCopy 已被 UIKit 禁止（选中文件夹会抛异常）：统一走「选完拷进沙盒」的入口
        withPickerSafety("添加文件") { DSPickers.presentOpenPickerCopying(into: URL(fileURLWithPath: self.inboxDirectory),
                                                                          utis: nil,
                                                                      multiple: true,
                                                                    completion: { copied, error in
            if let error = error {
                self.append("导入失败：\(error.localizedDescription)", .error)
            }
            guard !copied.isEmpty else {
                if error == nil { self.append("没有导入任何文件", .warning) }
                return
            }
            self.append("已导入 \(copied.count) 个文件", .success)
            self.reloadInbox()
            self.rematchAll()
            self.markDirty()
        }, cancel: nil) }
    }

    func removeFiles(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where index < files.count {
            let removed = files.remove(at: index)
            append("已从列表移除 \(removed.name)（文件本体保留在 ReplaceInbox）", .info)
        }
        markDirty()
    }

    func removeFile(id: UUID) {
        files.removeAll { $0.id == id }
        markDirty()
    }

    private func uniqueInboxPath(for name: String) -> String {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = (inboxDirectory as NSString).appendingPathComponent(name)
        var counter = 1
        while fm.fileExists(atPath: candidate) {
            let next = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = (inboxDirectory as NSString).appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }

    // MARK: - 目标优先绑定（先浏览目标目录挑文件，再配本地替换源）

    /// 「目标优先」流程里还没配到本地文件的那一条
    struct UnmatchedTarget: Identifiable, Hashable {
        let id: UUID
        let target: String
    }

    /// 在本机 Documents 下按文件名找同名文件（递归；跳过备份/记录/日志等系统目录；最多 12 个）
    func findLocalMatches(name: String) -> [String] {
        guard !name.isEmpty else { return [] }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        // 这些是 App 自己的系统目录，里面的同名文件不算「用户的替换源」
        let skip: Set<String> = ["Backups", "Runs", "Logs", "AutoTasks", "ImportInbox", "Adapted", "Artifacts"]
        var results: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        if let enumerator = fm.enumerator(at: docs,
                                          includingPropertiesForKeys: keys,
                                          options: [.skipsHiddenFiles],
                                          errorHandler: { _, _ in true }) {
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > 200_000 || results.count >= 12 { break }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir && skip.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.lastPathComponent == name, !isDir else { continue }
                results.append(url.path)
            }
        }
        return results
    }

    /// 目标优先：把用户挑好的目标路径变成绑定。
    /// 本机同名唯一 → 直接配上；多处 → 记候选让用户选；一个都没有 → 返回给界面去弹本机选择器。
    @discardableResult
    func addTargets(_ targetPaths: [String], inBundle: Bool) -> [UnmatchedTarget] {
        var unmatched: [UnmatchedTarget] = []
        var added = 0
        for target in targetPaths {
            let name = (target as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            let matches = findLocalMatches(name: name)
            let row: WizardFile
            switch matches.count {
            case 0:
                row = WizardFile(localPath: "",
                                 name: name,
                                 sizeText: "",
                                 targetPath: target,
                                 candidates: [],
                                 state: .notFound,
                                 targetLocked: true)
                unmatched.append(UnmatchedTarget(id: row.id, target: target))
            case 1:
                row = WizardFile(localPath: matches[0],
                                 name: name,
                                 sizeText: Self.sizeText(FileOperations.fileSize(matches[0])),
                                 targetPath: target,
                                 candidates: [],
                                 state: .manual,
                                 targetLocked: true)
            default:
                row = WizardFile(localPath: matches[0],
                                 name: name,
                                 sizeText: Self.sizeText(FileOperations.fileSize(matches[0])),
                                 targetPath: target,
                                 candidates: matches,
                                 state: .ambiguous,
                                 targetLocked: true)
            }
            if inBundle { bundleFiles.append(row) } else { files.append(row) }
            added += 1
        }
        if added > 0 {
            markDirty()
            append("已按目标目录加入 \(added) 条：本机同名唯一 \(added - unmatched.count) 条，需要你挑本地文件 \(unmatched.count) 条",
                   unmatched.isEmpty ? .success : .warning)
        }
        return unmatched
    }

    /// 目标优先：给某一行的目标配上本地文件（用户从本机选择器挑完、或从同名候选里选）
    func bindLocalFile(_ localPath: String, to id: UUID, inBundle: Bool) {
        if inBundle {
            guard let index = bundleFiles.firstIndex(where: { $0.id == id }) else { return }
            bundleFiles[index].localPath = localPath
            bundleFiles[index].sizeText = Self.sizeText(FileOperations.fileSize(localPath))
            bundleFiles[index].state = .manual
            bundleFiles[index].candidates = []
        } else {
            guard let index = files.firstIndex(where: { $0.id == id }) else { return }
            files[index].localPath = localPath
            files[index].sizeText = Self.sizeText(FileOperations.fileSize(localPath))
            files[index].state = .manual
            files[index].candidates = []
        }
        append("已绑定本地替换文件：\((localPath as NSString).lastPathComponent)", .success)
        markDirty()
    }

    /// 目标优先：为某一行挑本地替换文件（打开本机选择器 → 拷进沙盒 → 绑定到该行的目标路径）
    func pickLocalFile(for id: UUID, inBundle: Bool) {
        withPickerSafety("选择本地替换文件") {
            DSPickers.presentOpenPickerCopying(into: URL(fileURLWithPath: self.inboxDirectory),
                                               utis: nil,
                                           multiple: false,
                                         completion: { copied, error in
                if let error = error {
                    self.append("选择本地文件失败：\(error.localizedDescription)", .error)
                }
                guard let first = copied.first else { return }
                self.bindLocalFile(first.path, to: id, inBundle: inBundle)
            }, cancel: nil)
        }
    }

    /// 目标优先：为「还没配上本地文件」的那些目标批量挑本地文件（按文件名一一配对）
    func pickLocalFiles(for targets: [UnmatchedTarget], inBundle: Bool) {
        guard !targets.isEmpty else { return }
        withPickerSafety("选择本地替换文件") {
            DSPickers.presentOpenPickerCopying(into: URL(fileURLWithPath: self.inboxDirectory),
                                               utis: nil,
                                           multiple: true,
                                         completion: { copied, error in
                if let error = error {
                    self.append("选择本地文件失败：\(error.localizedDescription)", .error)
                }
                guard !copied.isEmpty else { return }
                var pending = targets
                for url in copied {
                    let name = url.lastPathComponent
                    guard let index = pending.firstIndex(where: {
                        ($0.target as NSString).lastPathComponent == name
                    }) else { continue }
                    let match = pending.remove(at: index)
                    self.bindLocalFile(url.path, to: match.id, inBundle: inBundle)
                }
                if !pending.isEmpty {
                    self.append("还有 \(pending.count) 个目标没配上本地文件：点对应那一行单独挑", .warning)
                }
            }, cancel: nil)
        }
    }

    // MARK: - 自动匹配（一次遍历，按文件名建索引）

    func rematchAll() {
        reloadInbox()
        guard !files.isEmpty else { return }

        let token = UUID()
        matchToken = token

        guard let app = selectedApp, let dataPath = app.dataPath, !dataPath.isEmpty else {
            for index in files.indices {
                files[index].targetPath = nil
                files[index].candidates = []
                files[index].state = .notFound
            }
            append(files.isEmpty ? "还没有本地文件" : "还没选目标 App（或它没有数据容器），先选目标再匹配", .info)
            return
        }

        let wanted = Set(files.map { $0.name })
        append("正在 \(app.name) 的数据容器里递归查找同名文件…", .info)

        DispatchQueue.global(qos: .userInitiated).async {
            var index: [String: [String]] = [:]
            var visited = 0
            let fm = FileManager.default

            if let enumerator = fm.enumerator(atPath: dataPath) {
                while let relative = enumerator.nextObject() as? String {
                    visited += 1
                    if visited > 200_000 { break }
                    let name = (relative as NSString).lastPathComponent
                    guard wanted.contains(name) else { continue }
                    if index[name]?.count ?? 0 >= 12 { continue }
                    let full = (dataPath as NSString).appendingPathComponent(relative)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                        index[name, default: []].append(full)
                    }
                }
            }

            DispatchQueue.main.async {
                guard self.matchToken == token else { return }
                var unique = 0, ambiguous = 0, missing = 0
                for position in self.files.indices {
                    // 目标优先绑定过的行：目标路径是用户亲手挑的，不许被自动匹配覆盖
                    if self.files[position].targetLocked { continue }
                    // 手动指定过的条目不动
                    if self.files[position].state == .manual, let path = self.files[position].targetPath, !path.isEmpty {
                        continue
                    }
                    let name = self.files[position].name
                    let hits = index[name] ?? []
                    self.files[position].candidates = hits
                    switch hits.count {
                    case 0:
                        self.files[position].targetPath = nil
                        self.files[position].state = .notFound
                        missing += 1
                    case 1:
                        self.files[position].targetPath = hits[0]
                        self.files[position].state = .unique
                        unique += 1
                    default:
                        self.files[position].targetPath = nil
                        self.files[position].state = .ambiguous
                        ambiguous += 1
                    }
                }
                self.append("匹配完成：自动绑定 \(unique) 个，多处同名 \(ambiguous) 个，没找到 \(missing) 个（扫描 \(visited) 项）",
                            ambiguous > 0 || missing > 0 ? .warning : .success)
            }
        }
    }

    func setTarget(path: String, for id: UUID, manual: Bool) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        files[index].targetPath = trimmed.isEmpty ? nil : trimmed
        if trimmed.isEmpty {
            files[index].state = files[index].candidates.count > 1 ? .ambiguous : .notFound
        } else {
            files[index].state = manual ? .manual : .unique
        }
        append(trimmed.isEmpty ? "已清除 \(files[index].name) 的目标路径" : "\(files[index].name) → \(trimmed)", .info)
        markDirty()
    }

    /// 清除某一条的绑定（长按菜单用）
    func clearTarget(for id: UUID) {
        setTarget(path: "", for: id, manual: false)
    }

    // MARK: - 包体(.app)模式

    /// 包体模式的源文件列表（与文件模式共用 ReplaceInbox，避免多一份拷贝）
    func reloadBundleFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: inboxDirectory, withIntermediateDirectories: true)

        let previous = Dictionary(uniqueKeysWithValues: bundleFiles.map { ($0.localPath, $0) })
        let names = (try? fm.contentsOfDirectory(atPath: inboxDirectory))?.sorted() ?? []

        var rebuilt: [WizardFile] = []
        for name in names where !name.hasPrefix(".") {
            let full = (inboxDirectory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            if let existing = previous[full] {
                rebuilt.append(existing)
            } else {
                let size = ((try? fm.attributesOfItem(atPath: full))?[.size] as? NSNumber)?.int64Value ?? 0
                rebuilt.append(WizardFile(localPath: full, name: name, sizeText: Self.sizeText(size)))
            }
        }
        bundleFiles = rebuilt
    }

    func importBundleFiles() {
        withPickerSafety("添加文件") { DSPickers.presentOpenPickerCopying(into: URL(fileURLWithPath: self.inboxDirectory),
                                                                          utis: nil,
                                                                      multiple: true,
                                                                    completion: { copied, error in
            if let error = error {
                self.append("导入失败：\(error.localizedDescription)", .error)
            }
            guard !copied.isEmpty else {
                if error == nil { self.append("没有导入任何文件", .warning) }
                return
            }
            self.append("已导入 \(copied.count) 个文件（包体模式）", .success)
            self.reloadBundleFiles()
            self.rematchBundle()
            self.markDirty()
        }, cancel: nil) }
    }

    /// 在目标 App 的 .app 包里递归找同名文件（唯一命中自动绑定）
    func rematchBundle() {
        reloadBundleFiles()
        guard !bundleFiles.isEmpty else { return }

        let token = UUID()
        matchToken = token

        guard let app = selectedApp, !app.bundlePath.isEmpty else {
            for index in bundleFiles.indices {
                bundleFiles[index].targetPath = nil
                bundleFiles[index].candidates = []
                bundleFiles[index].state = .notFound
            }
            append("还没选目标 App，先选目标再匹配", .info)
            return
        }

        let bundlePath = app.bundlePath
        let wanted = Set(bundleFiles.map { $0.name })
        append("正在 \(app.name) 的包体(.app)里递归查找同名文件…", .info)

        DispatchQueue.global(qos: .userInitiated).async {
            var index: [String: [String]] = [:]
            var visited = 0
            let fm = FileManager.default
            if let enumerator = fm.enumerator(atPath: bundlePath) {
                while let relative = enumerator.nextObject() as? String {
                    visited += 1
                    if visited > 200_000 { break }
                    let name = (relative as NSString).lastPathComponent
                    guard wanted.contains(name) else { continue }
                    if index[name]?.count ?? 0 >= 12 { continue }
                    let full = (bundlePath as NSString).appendingPathComponent(relative)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                        index[name, default: []].append(full)
                    }
                }
            }

            DispatchQueue.main.async {
                guard self.matchToken == token else { return }
                var unique = 0, ambiguous = 0, missing = 0
                for position in self.bundleFiles.indices {
                    // 目标优先绑定过的行：目标路径是用户亲手挑的，不许被自动匹配覆盖
                    if self.bundleFiles[position].targetLocked { continue }
                    if self.bundleFiles[position].state == .manual,
                       let path = self.bundleFiles[position].targetPath, !path.isEmpty {
                        continue
                    }
                    let name = self.bundleFiles[position].name
                    let hits = index[name] ?? []
                    self.bundleFiles[position].candidates = hits
                    switch hits.count {
                    case 0:
                        self.bundleFiles[position].targetPath = nil
                        self.bundleFiles[position].state = .notFound
                        missing += 1
                    case 1:
                        self.bundleFiles[position].targetPath = hits[0]
                        self.bundleFiles[position].state = .unique
                        unique += 1
                    default:
                        self.bundleFiles[position].targetPath = nil
                        self.bundleFiles[position].state = .ambiguous
                        ambiguous += 1
                    }
                }
                self.append("包体匹配完成：自动绑定 \(unique) 个，多处同名 \(ambiguous) 个，没找到 \(missing) 个（扫描 \(visited) 项）",
                            ambiguous > 0 || missing > 0 ? .warning : .success)
            }
        }
    }

    func setBundleTarget(path: String, for id: UUID, manual: Bool) {
        guard let index = bundleFiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        bundleFiles[index].targetPath = trimmed.isEmpty ? nil : trimmed
        if trimmed.isEmpty {
            bundleFiles[index].state = bundleFiles[index].candidates.count > 1 ? .ambiguous : .notFound
        } else {
            bundleFiles[index].state = manual ? .manual : .unique
        }
        append(trimmed.isEmpty ? "已清除 \(bundleFiles[index].name) 的目标路径" : "\(bundleFiles[index].name) → \(trimmed)", .info)
        markDirty()
    }

    func clearBundleTarget(for id: UUID) {
        setBundleTarget(path: "", for: id, manual: false)
    }

    func removeBundleFile(id: UUID) {
        bundleFiles.removeAll { $0.id == id }
        markDirty()
    }

    /// 包体模式：导入一个源文件夹（整包换 / 并入）
    /// 文件夹**不能** asCopy:YES（UIKit 会抛异常），所以走「选完由 DSPickers 拷进沙盒」的入口；
    /// 大文件夹（例如整个 .app）拷贝要花点时间，界面会短暂无反应，属正常。
    func importBundleFolder() {
        withPickerSafety("添加源文件夹") { DSPickers.presentFolderPickerCopying(into: URL(fileURLWithPath: self.folderSourceDirectory),
                                                                           completion: { copied, error in
            if let error = error {
                self.append("导入文件夹失败：\(error.localizedDescription)", .error)
            }
            guard let copied = copied else {
                if error == nil { self.append("没有选择文件夹", .warning) }
                return
            }
            self.append("已导入源文件夹 \(copied.lastPathComponent)", .success)
            self.reloadBundleFolder(preferred: copied.path)
            self.markDirty()
        }, cancel: nil) }
    }

    /// 重新统计包体模式的源文件夹（保留已绑定的目标；新导入时默认目标就是目标 App 的 .app）
    func reloadBundleFolder(preferred: String? = nil) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: folderSourceDirectory, withIntermediateDirectories: true)
        guard let path = preferred ?? bundleFolder?.localPath, fm.fileExists(atPath: path) else {
            bundleFolder = nil
            return
        }
        var folder = WizardFolder(localPath: path, name: (path as NSString).lastPathComponent)
        folder.targetPath = bundleFolder?.targetPath ?? selectedApp?.bundlePath
        let stats = Self.folderStats(path)
        folder.itemCount = stats.count
        folder.sizeText = Self.sizeText(stats.size)
        bundleFolder = folder
    }

    func setBundleFolderTarget(path: String) {
        guard var folder = bundleFolder else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.targetPath = trimmed.isEmpty ? nil : trimmed
        bundleFolder = folder
        append(trimmed.isEmpty ? "已清除源文件夹的目标路径" : "源文件夹 → \(trimmed)", .info)
        markDirty()
    }

    func removeBundleFolder() {
        bundleFolder = nil
        markDirty()
    }

    // MARK: - 文件夹模式：源文件夹

    func reloadFolders() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: folderSourceDirectory, withIntermediateDirectories: true)

        let previous = Dictionary(uniqueKeysWithValues: folders.map { ($0.localPath, $0) })
        let names = (try? fm.contentsOfDirectory(atPath: folderSourceDirectory))?.sorted() ?? []

        var rebuilt: [WizardFolder] = []
        for name in names where !name.hasPrefix(".") {
            let full = (folderSourceDirectory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }

            var folder = previous[full] ?? WizardFolder(localPath: full, name: name)
            folder.targetPath = previous[full]?.targetPath
            rebuilt.append(folder)
        }
        folders = rebuilt

        // 文件数/体积统计放后台，避免大文件夹卡住界面
        let snapshot = rebuilt
        DispatchQueue.global(qos: .utility).async {
            var stats: [String: (Int, Int64)] = [:]
            for folder in snapshot {
                stats[folder.localPath] = Self.folderStats(folder.localPath)
            }
            DispatchQueue.main.async {
                for index in self.folders.indices {
                    guard let stat = stats[self.folders[index].localPath] else { continue }
                    self.folders[index].itemCount = stat.0
                    self.folders[index].sizeText = Self.sizeText(stat.1)
                }
            }
        }
    }

    func importFolders() {
        withPickerSafety("添加源文件夹") { DSPickers.presentFolderPickerCopying(into: URL(fileURLWithPath: self.folderSourceDirectory),
                                                                           completion: { copied, error in
            if let error = error {
                self.append("导入文件夹失败：\(error.localizedDescription)", .error)
            }
            guard let copied = copied else {
                if error == nil { self.append("没有选择文件夹", .warning) }
                return
            }
            self.append("已导入文件夹 \(copied.lastPathComponent)", .success)
            self.reloadFolders()
            self.markDirty()
        }, cancel: nil) }
    }

    func removeFolder(id: UUID) {
        folders.removeAll { $0.id == id }
        markDirty()
    }

    /// 绑定（或清除）某个源文件夹的目标文件夹
    func setFolderTarget(path: String, for id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[index].targetPath = trimmed.isEmpty ? nil : trimmed
        append(trimmed.isEmpty
               ? "已清除 \(folders[index].name) 的目标文件夹"
               : "\(folders[index].name) → \(trimmed)", .info)
        markDirty()
    }

    func clearFolderTarget(for id: UUID) {
        setFolderTarget(path: "", for: id)
    }

    private func uniqueFolderSourcePath(for name: String) -> String {
        let fm = FileManager.default
        var candidate = (folderSourceDirectory as NSString).appendingPathComponent(name)
        var counter = 1
        while fm.fileExists(atPath: candidate) {
            candidate = (folderSourceDirectory as NSString).appendingPathComponent("\(name)-\(counter)")
            counter += 1
        }
        return candidate
    }

    /// 文件夹里的文件数与总大小（用于行内展示）
    static func folderStats(_ path: String) -> (count: Int, size: Int64) {
        let fm = FileManager.default
        var count = 0
        var size: Int64 = 0
        guard let enumerator = fm.enumerator(atPath: path) else { return (0, 0) }
        for case let relative as String in enumerator {
            let full = (path as NSString).appendingPathComponent(relative)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue { continue }
            count += 1
            size += ((try? fm.attributesOfItem(atPath: full))?[.size] as? NSNumber)?.int64Value ?? 0
            if count > 50_000 { break }
        }
        return (count, size)
    }

    // MARK: - 执行

    var boundCount: Int { files.filter { ($0.targetPath ?? "").isEmpty == false }.count }
    var boundFolderCount: Int { folders.filter { ($0.targetPath ?? "").isEmpty == false }.count }
    var boundBundleFileCount: Int { bundleFiles.filter { ($0.targetPath ?? "").isEmpty == false }.count }
    var boundBundleFolderCount: Int { (bundleFolder?.targetPath ?? "").isEmpty ? 0 : 1 }
    /// 当前模式下已绑定的条目数
    var currentBoundCount: Int {
        switch mode {
        case .files: return boundCount
        case .folders: return boundFolderCount
        case .bundle: return boundBundleFileCount + boundBundleFolderCount
        }
    }
    /// 当前模式下的条目总数
    var currentItemCount: Int {
        switch mode {
        case .files: return files.count
        case .folders: return folders.count
        case .bundle: return bundleFiles.count + (bundleFolder == nil ? 0 : 1)
        }
    }
    var readyToRun: Bool { selectedApp != nil && currentBoundCount > 0 && !isRunning }

    /// 把当前界面上的绑定收成一份配置（保存任务 / 立即执行共用同一份数据）
    func currentTask(forceBackup: Bool = false) -> ReplaceAutoTask {
        let app = selectedApp
        let sourceFiles: [WizardFile]
        let sourceFolders: [WizardFolder]
        switch mode {
        case .files:
            sourceFiles = files
            sourceFolders = []
        case .folders:
            sourceFiles = []
            sourceFolders = folders
        case .bundle:
            sourceFiles = bundleFiles
            sourceFolders = bundleFolder.map { [$0] } ?? []
        }

        return ReplaceAutoTask(bundleId: app?.bundleId ?? "",
                               appName: app?.name ?? "",
                               bundlePath: app?.bundlePath ?? "",
                               dataPath: app?.dataPath ?? "",
                               executableName: app?.executableName ?? "",
                               mode: mode,
                               files: sourceFiles.compactMap { file in
                                   guard let target = file.targetPath, !target.isEmpty else { return nil }
                                   // 目标优先绑定但还没配本地文件的条目不进配方（避免空 source）
                                   guard !file.localPath.isEmpty else { return nil }
                                   return ReplaceFileBinding(localPath: file.localPath,
                                                             name: file.name,
                                                             targetPath: target)
                               },
                               folders: sourceFolders.compactMap { folder in
                                   guard let target = folder.targetPath, !target.isEmpty else { return nil }
                                   return ReplaceFolderBinding(localPath: folder.localPath,
                                                               name: folder.name,
                                                               targetPath: target)
                               },
                               semantics: mode == .bundle ? bundleSemantics : nil,
                               backup: forceBackup ? true : autoBackup,
                               updatedAt: Date())
    }

    // MARK: - 自动化任务（用户显式保存 + 手动运行）

    /// 绑定有改动：标记「未保存」，不再自动写盘
    func markDirty() {
        hasUnsavedChanges = true
    }

    func reloadSavedTasks() {
        savedTasks = ReplaceTaskStore.load()
        hasUnsavedChanges = false
    }

    /// 建议的任务名（App 名 · 模式 · 时间）
    func suggestedTaskName() -> String {
        ReplaceSavedTask.defaultName(for: currentTask(forceBackup: mode != .files))
    }

    /// 把当前设置保存成一条命名任务
    @discardableResult
    func saveCurrentAsTask(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = currentTask(forceBackup: mode != .files)
        guard !task.bundleId.isEmpty else {
            append("保存失败：还没有选择目标 App", .error)
            return false
        }
        guard !task.isEmpty else {
            append("保存失败：还没有绑定任何替换内容（先把目标路径选好）", .error)
            return false
        }
        let finalName = trimmed.isEmpty ? ReplaceSavedTask.defaultName(for: task) : trimmed
        let saved = ReplaceSavedTask(id: UUID().uuidString, name: finalName, createdAt: Date(), task: task)
        var list = savedTasks
        list.insert(saved, at: 0)
        guard ReplaceTaskStore.save(list) else {
            append("保存失败：写 \(ReplaceTaskStore.filePath) 出错", .error)
            return false
        }
        savedTasks = list
        hasUnsavedChanges = false
        append("已保存任务「\(finalName)」：\(saved.summary)。要执行时点它的「运行」。", .success)
        return true
    }

    func renameTask(_ saved: ReplaceSavedTask, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = savedTasks
        guard let index = list.firstIndex(where: { $0.id == saved.id }) else { return }
        list[index].name = trimmed
        if ReplaceTaskStore.save(list) {
            savedTasks = list
            append("任务已改名为「\(trimmed)」", .info)
        } else {
            append("改名失败：写盘出错", .error)
        }
    }

    func deleteTask(_ saved: ReplaceSavedTask) {
        let list = savedTasks.filter { $0.id != saved.id }
        if ReplaceTaskStore.save(list) {
            savedTasks = list
            append("已删除任务「\(saved.name)」", .info)
        } else {
            append("删除失败：写盘出错", .error)
        }
    }

    /// 用一条绑定生成向导里的文件行（sizeText 现算）
    private func makeWizardFile(localPath: String, name: String, targetPath: String?) -> WizardFile {
        WizardFile(localPath: localPath,
                   name: name,
                   sizeText: Self.sizeText(FileOperations.fileSize(localPath)),
                   targetPath: targetPath,
                   candidates: [],
                   state: .manual)
    }

    /// 把任务载入编辑区（按模式恢复到对应绑定）
    func loadTaskIntoEditor(_ saved: ReplaceSavedTask) {
        let task = saved.task
        mode = task.mode
        if let app = apps.first(where: { $0.bundleId == task.bundleId }) {
            applySelection(app)
        }
        switch task.mode {
        case .files:
            files = task.files.map { makeWizardFile(localPath: $0.localPath, name: $0.name, targetPath: $0.targetPath) }
        case .folders:
            folders = task.folders.map { binding in
                var folder = WizardFolder(localPath: binding.localPath, name: binding.name)
                folder.targetPath = binding.targetPath
                return folder
            }
        case .bundle:
            bundleFiles = task.files.map { makeWizardFile(localPath: $0.localPath, name: $0.name, targetPath: $0.targetPath) }
            if let first = task.folders.first {
                var folder = WizardFolder(localPath: first.localPath, name: first.name)
                folder.targetPath = first.targetPath
                bundleFolder = folder
            } else {
                bundleFolder = nil
            }
            bundleSemantics = task.effectiveSemantics
        }
        autoBackup = task.backup
        hasUnsavedChanges = false
        append("已载入任务「\(saved.name)」：\(task.summary)", .info)
    }

    /// 运行一条已保存的任务（强制备份 + 环境门 + 并发门）
    func runSavedTask(_ saved: ReplaceSavedTask) {
        ReplaceTaskRunner.run(saved)
    }

    func startReplace() {
        guard let app = selectedApp else {
            append("请先在上方选择目标 App", .error)
            return
        }
        guard EnvironmentProbe.hasFileSystemAccess() else {
            needsActivation = true
            append("还没有沙盒外读写权限：请到「设置」页点『激活内核访问』；越狱 / roothide / TrollStore 环境下可以直接用。", .error)
            return
        }

        let task = currentTask(forceBackup: mode != .files)
        guard !task.isEmpty else {
            switch mode {
            case .files:
                append("还没有可替换的条目：每个文件都要先绑定一个目标路径", .error)
            case .folders:
                append("还没有可替换的文件夹：每个源文件夹都要先绑定一个目标文件夹", .error)
            case .bundle:
                append("还没有可替换的内容：加一个源文件夹（整包换 / 并入），或加文件让它在 .app 里按文件名匹配", .error)
            }
            return
        }
        guard ReplaceRunGate.acquire() else {
            append("已经有一次替换在执行中，这次先不重复跑。", .warning)
            return
        }

        isRunning = true
        lastRunSummary = nil
        lastBackupId = nil
        lastRunSucceeded = false
        lastBackupEnabled = task.backup
        lastRunWasFolders = (mode != .files)

        let modeText: String
        switch mode {
        case .files: modeText = "文件"
        case .folders: modeText = "文件夹"
        case .bundle: modeText = "包体(.app)"
        }
        append("=== 开始\(modeText)替换：\(task.itemCount) 项 → \(app.name) ===", .info)
        if mode == .folders {
            append("镜像语义：目标文件夹会被源文件夹整体替换（目标里源没有的旧文件会被移除）；替换前已强制整棵递归备份。", .warning)
        } else if mode == .bundle {
            append("包体语义：\(bundleSemantics.title)——\(bundleSemantics.subtitle)；替换前整棵递归备份。", .warning)
            append("⚠️ 改自签 App 的包体会破坏它的签名校验，可能导致 App 直接打不开；动手前确认你有重装手段。", .warning)
        }
        if !task.backup {
            append("⚠️ 本次关闭了「执行前自动备份」：覆盖后无法回滚，请自行确认。", .warning)
        }

        let backupRequested = task.backup
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ReplaceTaskBuilder.run(task: task)
            ReplaceRunGate.release()

            DispatchQueue.main.async {
                self.isRunning = false
                for line in result.log {
                    let level: LogLine.Level
                    if line.hasPrefix("❌") {
                        level = .error
                    } else if line.hasPrefix("⚠️") {
                        level = .warning
                    } else if line.hasPrefix("✅") {
                        level = .success
                    } else {
                        level = .info
                    }
                    self.append(line, level)
                }
                self.lastRunSummary = result.summary
                self.lastBackupId = result.backupId
                self.lastRunSucceeded = result.success
                self.lastBackupEnabled = backupRequested
                RunStore.shared.reload()
                DSLog.shared.info("一键替换 \(task.target.summary)：\(result.summary)", source: "替换")
            }
        }
    }

    // MARK: - 回滚

    var lastBackup: BackupRecord? {
        guard let id = lastBackupId else { return nil }
        return RunStore.shared.backups.first { $0.id == id }
    }

    func rollbackLastRun() {
        guard let record = lastBackup else {
            append("这次运行没有可回滚的备份（可能一个目标都没被覆盖）", .warning)
            return
        }
        guard !isRestoring else { return }
        isRestoring = true
        append("开始回滚备份 \(record.id)（\(record.entries.count) 项）…", .info)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let restored = try RunStore.shared.restore(record)
                DispatchQueue.main.async {
                    self.isRestoring = false
                    RunStore.shared.reload()
                    self.append("已回滚：恢复 \(restored) 项", .success)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRestoring = false
                    self.append("回滚失败：\(error.localizedDescription)", .error)
                }
            }
        }
    }

    // MARK: - 最近的替换（与「记录」页共用同一份 RunStore 数据）

    /// 只列本页产生的替换记录
    var recentReplaceRuns: [RunRecord] {
        RunStore.shared.runs.filter { $0.scriptName.hasPrefix(Self.runScriptName) }
    }

    func backupRecord(for run: RunRecord) -> BackupRecord? {
        guard let id = run.backupId else { return nil }
        return RunStore.shared.backups.first { $0.id == id }
    }

    func canRollback(_ run: RunRecord) -> Bool {
        return backupRecord(for: run) != nil
    }

    /// 回滚某一条替换记录（统一走 RunStore.restore，不另写回滚逻辑）
    func rollback(run: RunRecord) {
        guard let backup = backupRecord(for: run) else {
            append("这条记录没有可回滚的备份（当时可能关掉了自动备份，或没有文件被覆盖）", .warning)
            return
        }
        guard !isRestoring else { return }
        isRestoring = true
        append("开始回滚 \(Self.timeText(run.date))（备份 \(backup.id)，\(backup.entries.count) 项）…", .info)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let restored = try RunStore.shared.restore(backup)
                DispatchQueue.main.async {
                    self.isRestoring = false
                    RunStore.shared.reload()
                    self.append("已回滚：恢复 \(restored) 项", .success)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRestoring = false
                    self.append("回滚失败：\(error.localizedDescription)", .error)
                }
            }
        }
    }

    func deleteRun(_ run: RunRecord) {
        RunStore.shared.deleteRun(run)
        append("已删除记录 \(Self.timeText(run.date))", .info)
    }

    func logText(for run: RunRecord) -> String {
        let text = RunStore.shared.logText(for: run)
        return text.isEmpty ? "（这条记录没有日志文件）" : text
    }

    static func timeText(_ date: Date) -> String {
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - 日志

    func append(_ text: String, _ level: LogLine.Level = .info) {
        let stamp = DSLog.timeFormatter.string(from: Date())
        logs.append(LogLine(level: level, text: "\(stamp)  \(text)"))
        if logs.count > 600 {
            logs.removeFirst(logs.count - 600)
        }
    }

    func clearLogs() { logs.removeAll() }

    var plainLogText: String { logs.map(\.text).joined(separator: "\n") }

    static func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - 页面

struct ReplaceWizardView: View {

    /// 完成后「查看运行记录」用：切到记录页
    let onOpenRecords: () -> Void

    @StateObject private var model = ReplaceWizardModel()
    @ObservedObject private var kernel = KernelCenter.shared

    @State private var candidateSheet: ReplaceWizardModel.WizardFile?
    @State private var manualSheet: ReplaceWizardModel.WizardFile?
    @State private var browserRequest: BrowserRequest?
    @State private var folderBrowserRequest: FolderBrowserRequest?
    @State private var bundleCandidateSheet: ReplaceWizardModel.WizardFile?
    @State private var bundleManualSheet: ReplaceWizardModel.WizardFile?
    @State private var bundleBrowserRequest: BrowserRequest?
    @State private var bundleFolderBrowserRequest: FolderBrowserRequest?
    /// 目标优先：正在浏览哪个 App 的目标目录（多选，先挑目标文件）
    @State private var targetFirstRequest: TargetFirstRequest?
    /// 目标优先：某一行有多个同名本地候选，让用户挑一个
    @State private var localCandidateSheet: ReplaceWizardModel.WizardFile?
    @State private var localCandidateInBundle = false
    /// 目标优先：某一行还没配上本地文件，待弹本机文件选择器
    @State private var pendingLocalPick: PendingLocalPick?
    @State private var appFilter: String = ""
    @State private var activationAlert = false
    @State private var rollbackConfirm = false
    @State private var logSheetRun: RunRecord?
    @State private var pendingRollbackRun: RunRecord?
    @State private var loaded = false
    // 自动化任务的命名 / 改名 / 删除
    @State private var namingTask = false
    @State private var newTaskName = ""
    @State private var renameTarget: ReplaceSavedTask?
    @State private var renameText = ""
    @State private var deleteTarget: ReplaceSavedTask?

    var body: some View {
        NavigationView {
            Form {
                modeSection
                targetSection
                switch model.mode {
                case .files:
                    fileSection
                case .folders:
                    folderSection
                case .bundle:
                    bundleSection
                }
                runSection
                savedTasksSection
                resultSection
                recentSection
                logSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("替换")
            // 应用管理器里点「设为替换页目标 App」：这里接住那次请求并选中
            .onReceive(ReplaceTargetBus.shared.$pendingBundleId) { bundleId in
                guard let bundleId = bundleId, !bundleId.isEmpty else { return }
                _ = ReplaceTargetBus.shared.consume()
                model.selectAppByBundleId(bundleId)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: plusAction) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $candidateSheet) { file in
                CandidateTargetSheet(file: file) { path in
                    model.setTarget(path: path, for: file.id, manual: false)
                    candidateSheet = nil
                }
            }
            .sheet(item: $manualSheet) { file in
                ManualTargetSheet(initial: file.targetPath,
                                  dataPath: model.selectedApp?.dataPath,
                                  name: file.name) { path in
                    model.setTarget(path: path, for: file.id, manual: true)
                    manualSheet = nil
                }
            }
            .sheet(item: $browserRequest) { request in
                TargetFileBrowserSheet(app: request.app,
                                       localFileName: request.file.name,
                                       initialTarget: request.file.targetPath) { path in
                    model.setTarget(path: path, for: request.file.id, manual: true)
                    browserRequest = nil
                }
            }
            .sheet(item: $folderBrowserRequest) { request in
                TargetFileBrowserSheet(app: request.app,
                                       localFileName: request.folder.name,
                                       initialTarget: request.folder.targetPath,
                                       pickFolders: true) { path in
                    model.setFolderTarget(path: path, for: request.folder.id)
                    folderBrowserRequest = nil
                }
            }
            .sheet(item: $bundleCandidateSheet) { file in
                CandidateTargetSheet(file: file) { path in
                    model.setBundleTarget(path: path, for: file.id, manual: false)
                    bundleCandidateSheet = nil
                }
            }
            .sheet(item: $bundleManualSheet) { file in
                ManualTargetSheet(initial: file.targetPath,
                                  dataPath: model.selectedApp?.bundlePath,
                                  name: file.name) { path in
                    model.setBundleTarget(path: path, for: file.id, manual: true)
                    bundleManualSheet = nil
                }
            }
            .sheet(item: $bundleBrowserRequest) { request in
                TargetFileBrowserSheet(app: request.app,
                                       localFileName: request.file.name,
                                       initialTarget: request.file.targetPath,
                                       lockedRoot: request.app.bundlePath) { path in
                    model.setBundleTarget(path: path, for: request.file.id, manual: true)
                    bundleBrowserRequest = nil
                }
            }
            .sheet(item: $bundleFolderBrowserRequest) { request in
                TargetFileBrowserSheet(app: request.app,
                                       localFileName: request.folder.name,
                                       initialTarget: request.folder.targetPath,
                                       pickFolders: true,
                                       lockedRoot: request.app.bundlePath) { path in
                    model.setBundleFolderTarget(path: path)
                    bundleFolderBrowserRequest = nil
                }
            }
            .sheet(item: $targetFirstRequest) { request in
                TargetFileBrowserSheet(app: request.app,
                                       localFileName: "",
                                       initialTarget: nil,
                                       lockedRoot: request.inBundle ? request.app.bundlePath : nil,
                                       allowsMultipleSelection: true,
                                       onPickMany: { paths in
                                           let unmatched = model.addTargets(paths, inBundle: request.inBundle)
                                           targetFirstRequest = nil
                                           if let first = unmatched.first {
                                               pendingLocalPick = PendingLocalPick(rowID: first.id,
                                                                                  target: first.target,
                                                                                  inBundle: request.inBundle)
                                           }
                                       },
                                       onPick: { _ in })
            }
            .sheet(item: $localCandidateSheet) { file in
                CandidateTargetSheet(file: file, kind: .local) { path in
                    model.bindLocalFile(path, to: file.id, inBundle: localCandidateInBundle)
                    localCandidateSheet = nil
                }
            }
            .onChange(of: pendingLocalPick) { pick in
                guard let pick = pick else { return }
                pendingLocalPick = nil
                // 等 sheet 收完再弹本机选择器，避免两个呈现打架
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    model.pickLocalFiles(for: [ReplaceWizardModel.UnmatchedTarget(id: pick.rowID,
                                                                                 target: pick.target)],
                                         inBundle: pick.inBundle)
                }
            }
            .alert("保存为自动化任务", isPresented: $namingTask) {
                TextField("任务名", text: $newTaskName)
                Button("保存") { model.saveCurrentAsTask(name: newTaskName) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只保存配置；要执行时到「自动化任务」列表里点它的「运行」。")
            }
            .alert("重命名任务",
                   isPresented: Binding(get: { renameTarget != nil },
                                        set: { if !$0 { renameTarget = nil } })) {
                TextField("任务名", text: $renameText)
                Button("保存") {
                    if let target = renameTarget { model.renameTask(target, to: renameText) }
                    renameTarget = nil
                }
                Button("取消", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog("删除这条任务？",
                                isPresented: Binding(get: { deleteTarget != nil },
                                                     set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let target = deleteTarget { model.deleteTask(target) }
                    deleteTarget = nil
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("只删这条保存的配置，不会动已经改过的文件（回滚请用「记录」页或「最近的替换」）。")
            }
            .sheet(item: $logSheetRun) { run in
                RunLogSheet(title: "\(ReplaceWizardModel.timeText(run.date)) · \(run.summary)",
                            text: model.logText(for: run))
            }
            .confirmationDialog("回滚这次替换？",
                                isPresented: Binding(
                                    get: { pendingRollbackRun != nil },
                                    set: { if !$0 { pendingRollbackRun = nil } }
                                ),
                                titleVisibility: .visible) {
                Button("回滚（把原件拷回去）", role: .destructive) {
                    if let run = pendingRollbackRun {
                        model.rollback(run: run)
                        pendingRollbackRun = nil
                    }
                }
                Button("取消", role: .cancel) { pendingRollbackRun = nil }
            } message: {
                Text("会用备份里的原件覆盖目标，并恢复原来的权限与属主；这次替换新建的文件会被删掉。")
            }
            .confirmationDialog("回滚这次替换？",
                                isPresented: $rollbackConfirm,
                                titleVisibility: .visible) {
                Button("回滚（把原件拷回去）", role: .destructive) {
                    model.rollbackLastRun()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会用备份里的原件覆盖目标，并恢复原来的权限与属主；脚本新建的文件会被删掉。")
            }
            .alert("还没激活内核访问", isPresented: $activationAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text("替换目标 App 里的文件需要先获得沙盒外写入权限：请到「设置」页点『激活内核访问』。")
            }
            .onAppear { handleFirstAppear() }
            .onReceive(NotificationCenter.default.publisher(for: ReplaceTaskRunner.didRunNotification)) { note in
                handleTaskRunNotification(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .myfilzaFileSystemAccessChanged)) { _ in
                handleFileSystemAccessChanged()
            }
            .onChange(of: model.needsActivation) { needs in
                handleNeedsActivationChanged(needs)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: 生命周期与通知（拆成独立方法，避免视图构建器类型检查超时）

    private func handleFirstAppear() {
        guard !loaded else { return }
        loaded = true
        model.reloadInbox()
        model.reloadFolders()
        model.reloadBundleFiles()
        model.reloadBundleFolder()
        model.reloadSavedTasks()
        model.loadAppsIfNeeded()
        model.append("提示：每次替换前都会整份备份（文件夹 / 包体模式是整棵递归备份），随时可以在下方或「记录」页一键回滚。", .info)
    }

    private func handleTaskRunNotification(_ note: Notification) {
        let success = (note.userInfo?["success"] as? Bool) ?? false
        let summary = (note.userInfo?["summary"] as? String) ?? ""
        RunStore.shared.reload()
        model.reloadSavedTasks()
        let stateText: String = success ? "成功" : "未成功"
        let stateLevel: ReplaceWizardModel.LogLine.Level = success ? .success : .warning
        model.append("替换任务：\(stateText) · \(summary)", stateLevel)
    }

    private func handleFileSystemAccessChanged() {
        // 激活成功 / 提权成功：权限变了，之前那次「没权限」的扫描结果必须作废重扫
        model.append("文件系统权限已变化：正在重新扫描 App 列表…", .info)
        model.loadApps(force: true)
    }

    private func handleNeedsActivationChanged(_ needs: Bool) {
        if needs {
            activationAlert = true
            model.needsActivation = false
        }
    }

    // MARK: 模式

    /// 工具栏「+」：按当前模式走对应的导入入口。
    /// 单独抽成方法是为了给 SwiftUI 的 body 减负——整段 body 表达式过于复杂时，
    /// 编译器会报 "unable to type-check this expression in reasonable time"。
    private func plusAction() {
        switch model.mode {
        case .files:
            model.importFiles()
        case .folders:
            model.importFolders()
        case .bundle:
            model.importBundleFiles()
        }
    }

    private var modeSection: some View {
        Section {
            Picker("替换方式", selection: $model.mode) {
                ForEach(ReplaceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("替换方式")
        } footer: {
            switch model.mode {
            case .files:
                Text("文件模式：把本地文件按文件名替换进目标 App（自动匹配 / 浏览目录 / 手填三条路）。")
            case .folders:
                Text("文件夹模式：把本地文件夹整体**镜像替换**进目标文件夹——目标里源没有的旧文件会被移除，替换前强制整棵递归备份。")
            case .bundle:
                Text("包体(.app)模式：目标锁定为所选 App 的包体，可以放一个源文件夹（整包换 / 并入）或若干文件（按文件名匹配进 .app）。")
            }
        }
    }

    // MARK: 目标 App

    private var targetSection: some View {
        Section {
            if let app = model.selectedApp {
                HStack(spacing: 12) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(app.bundleId)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text(app.dataPath ?? "（没有数据容器）")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
            }

            if model.isScanningApps {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在扫描已安装 App…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if model.apps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("未获取到 App：请先在「设置」页点『激活内核访问』（越狱环境可直接点下面重扫）。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button {
                        model.loadApps(force: true)
                    } label: {
                        Label("重新扫描 App", systemImage: "arrow.clockwise")
                            .font(.footnote)
                    }
                }
            } else if let selected = model.selectedApp {
                // 选中后只留这一行 + 「更换」，不再让一屏列表占满页面
                appRow(selected, checked: true)
                Button {
                    model.clearSelection()
                } label: {
                    Label("更换目标 App", systemImage: "arrow.triangle.2.circlepath")
                }
            } else {
                if model.apps.count > 25 {
                    TextField("按名字或 bundle id 过滤", text: $appFilter)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                // 固定高度、内部可滑动（照参考文档里日志区的做法）
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredApps) { app in
                            Button {
                                model.toggleSelection(app)
                            } label: {
                                appRow(app, checked: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180, maxHeight: 260)
            }
        } header: {
            Text("目标 App")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("单选：点一下选中，点「更换」可取消重选。选中后下面会自动在它的数据容器里递归找同名文件。")
                Button {
                    model.loadApps(force: true)
                } label: {
                    Label("重新扫描 App", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .disabled(model.isScanningApps)
            }
        }
    }

    /// 目标 App 的统一行样式（与 Morph 的行模式一致）
    private func appRow(_ app: InstalledApp, checked: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: checked ? "largecircle.fill.circle" : "circle")
                .font(.title3)
                .foregroundColor(checked ? .accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(app.bundleId)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let data = app.dataPath {
                    Text(data)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("没有数据容器")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var filteredApps: [InstalledApp] {
        let keyword = appFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return model.apps }
        return model.apps.filter {
            $0.name.lowercased().contains(keyword) || $0.bundleId.lowercased().contains(keyword)
        }
    }

    /// 是否已经能读写沙盒外路径（内核逃逸 **或** 越狱/TrollStore 环境；读一下 kernel.phase 让 SwiftUI 跟着刷新）
    private var kernelReady: Bool {
        _ = kernel.phase
        return EnvironmentProbe.hasFileSystemAccess()
    }

    // MARK: 替换文件

    private var fileSection: some View {
        Section {
            if model.files.isEmpty {
                Text("还没有待替换的本地文件：点右上角「＋」从「文件」App 选，选完会自动拷进 App 的 ReplaceInbox。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            ForEach(model.files) { file in
                Button {
                    if file.targetLocked {
                        // 目标优先绑定过的行：点一下 = 挑/换本地替换文件
                        handleTargetLockedRow(file, inBundle: false)
                        return
                    }
                    switch file.state {
                    case .ambiguous:
                        candidateSheet = file
                    case .notFound, .unique, .manual:
                        // 默认动作改成「浏览目标 App 目录」；手填路径挪到长按菜单里
                        openBrowser(for: file)
                    }
                } label: {
                    WizardFileRow(file: file)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if file.targetLocked {
                        Button {
                            model.pickLocalFile(for: file.id, inBundle: false)
                        } label: {
                            Label("更换本地替换文件", systemImage: "doc.badge.plus")
                        }
                    }
                    Button {
                        openBrowser(for: file)
                    } label: {
                        Label("重新选择目标路径", systemImage: "folder")
                    }
                    Button {
                        manualSheet = file
                    } label: {
                        Label("手填完整路径", systemImage: "keyboard")
                    }
                    Button {
                        model.clearTarget(for: file.id)
                    } label: {
                        Label("清除绑定", systemImage: "xmark.circle")
                    }
                }
            }
            .onDelete { offsets in
                model.removeFiles(at: offsets)
            }

            Button {
                openTargetFirst(inBundle: false)
            } label: {
                Label("添加目标文件（浏览数据容器）", systemImage: "folder.badge.plus")
            }

            Button {
                model.importFiles()
            } label: {
                Label("添加本机文件（按名自动匹配目标）", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("替换文件（目标优先 / 本机优先）")
        } footer: {
            Text("目标优先：先点「添加目标文件」在目标 App 数据容器里挑出要替换掉的文件，App 会自动在本机找同名文件配上（同名多处会让你选，一个都没有会弹本机选择器）；这样绑定的目标路径会被**锁定**，不会被自动匹配改掉。本机优先：点「添加本机文件」，再按文件名自动匹配目标。左滑从列表移除（文件本体留在 ReplaceInbox）。")
        }
    }

    /// 打开目标 App 目录浏览器（先确保选了目标 App）
    private func openBrowser(for file: ReplaceWizardModel.WizardFile) {
        guard let app = model.selectedApp else {
            model.append("请先在上面选一个目标 App，再浏览它的目录", .error)
            return
        }
        browserRequest = BrowserRequest(file: file, app: app)
    }

    /// 目标优先：先浏览目标目录，挑出「要被替换掉的那个文件」
    private func openTargetFirst(inBundle: Bool) {
        guard let app = model.selectedApp else {
            model.append("请先在上面选一个目标 App，再浏览它的目录", .error)
            return
        }
        targetFirstRequest = TargetFirstRequest(app: app, inBundle: inBundle)
    }

    /// 目标优先的行：点一下 = 挑/换本地替换文件（有多个同名候选就先让用户选）
    private func handleTargetLockedRow(_ file: ReplaceWizardModel.WizardFile, inBundle: Bool) {
        if !file.candidates.isEmpty {
            localCandidateInBundle = inBundle
            localCandidateSheet = file
            return
        }
        model.pickLocalFile(for: file.id, inBundle: inBundle)
    }

    // MARK: 文件夹模式

    private var folderSection: some View {
        Section {
            if model.folders.isEmpty {
                Text("还没有源文件夹：点下面的「添加文件夹…」，选完会整份拷进 App 的 ReplaceSources。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            ForEach(model.folders) { folder in
                Button {
                    openFolderBrowser(for: folder)
                } label: {
                    FolderRow(folder: folder)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        openFolderBrowser(for: folder)
                    } label: {
                        Label("选择目标文件夹", systemImage: "folder")
                    }
                    Button {
                        model.clearFolderTarget(for: folder.id)
                    } label: {
                        Label("清除绑定", systemImage: "xmark.circle")
                    }
                    Button(role: .destructive) {
                        model.removeFolder(id: folder.id)
                    } label: {
                        Label("从列表移除", systemImage: "trash")
                    }
                }
            }

            Button {
                model.importFolders()
            } label: {
                Label("添加文件夹…", systemImage: "folder.badge.plus")
            }
        } header: {
            Text("源文件夹 → 目标文件夹（镜像替换）")
        } footer: {
            Text("点某一行去浏览目标 App 目录，进到要替换的那个文件夹后点右上角「选择此文件夹」。执行时目标文件夹会被源文件夹整体替换（目标里源没有的旧文件会被移除），替换前强制整棵递归备份。")
        }
    }

    /// 打开目标文件夹选择器（先确保选了目标 App）
    private func openFolderBrowser(for folder: ReplaceWizardModel.WizardFolder) {
        guard let app = model.selectedApp else {
            model.append("请先在上面选一个目标 App，再浏览它的目录", .error)
            return
        }
        folderBrowserRequest = FolderBrowserRequest(folder: folder, app: app)
    }

    // MARK: 包体(.app)模式

    private var bundleSection: some View {
        Section {
            if let app = model.selectedApp {
                HStack(spacing: 12) {
                    Image(systemName: "app.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("目标包体（已锁定）")
                            .font(.subheadline)
                        Text(app.bundlePath)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text("先在上面选一个目标 App，包体会自动锁定为它的 .app。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Picker("语义", selection: $model.bundleSemantics) {
                ForEach(ReplaceBundleSemantics.allCases) { semantics in
                    Text(semantics.title).tag(semantics)
                }
            }
            .pickerStyle(.segmented)

            Text(model.bundleSemantics.subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)

            if let folder = model.bundleFolder {
                Button {
                    openBundleFolderBrowser(for: folder)
                } label: {
                    FolderRow(folder: folder)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        openBundleFolderBrowser(for: folder)
                    } label: {
                        Label("选择目标文件夹", systemImage: "folder")
                    }
                    Button {
                        model.setBundleFolderTarget(path: "")
                    } label: {
                        Label("清除绑定", systemImage: "xmark.circle")
                    }
                    Button(role: .destructive) {
                        model.removeBundleFolder()
                    } label: {
                        Label("移除源文件夹", systemImage: "trash")
                    }
                }
            }

            Button {
                model.importBundleFolder()
            } label: {
                Label(model.bundleFolder == nil ? "添加源文件夹（整包换 / 并入）" : "替换源文件夹…",
                      systemImage: "folder.badge.plus")
            }

            if model.bundleFiles.isEmpty {
                Text("也可以加单个 / 多个文件：它们会在 .app 里按文件名自动匹配。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            ForEach(model.bundleFiles) { file in
                Button {
                    if file.targetLocked {
                        // 目标优先绑定过的行：点一下 = 挑/换本地替换文件
                        handleTargetLockedRow(file, inBundle: true)
                        return
                    }
                    switch file.state {
                    case .ambiguous:
                        bundleCandidateSheet = file
                    case .notFound, .unique, .manual:
                        openBundleBrowser(for: file)
                    }
                } label: {
                    WizardFileRow(file: file)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if file.targetLocked {
                        Button {
                            model.pickLocalFile(for: file.id, inBundle: true)
                        } label: {
                            Label("更换本地替换文件", systemImage: "doc.badge.plus")
                        }
                    }
                    Button {
                        openBundleBrowser(for: file)
                    } label: {
                        Label("重新选择目标路径", systemImage: "folder")
                    }
                    Button {
                        bundleManualSheet = file
                    } label: {
                        Label("手填完整路径", systemImage: "keyboard")
                    }
                    Button {
                        model.clearBundleTarget(for: file.id)
                    } label: {
                        Label("清除绑定", systemImage: "xmark.circle")
                    }
                    Button(role: .destructive) {
                        model.removeBundleFile(id: file.id)
                    } label: {
                        Label("从列表移除", systemImage: "trash")
                    }
                }
            }

            Button {
                openTargetFirst(inBundle: true)
            } label: {
                Label("添加目标文件（浏览 .app）", systemImage: "folder.badge.plus")
            }

            Button {
                model.importBundleFiles()
            } label: {
                Label("添加本机文件（按名自动匹配 .app 内目标）", systemImage: "doc.badge.plus")
            }
        } header: {
            Text("包体(.app) 内容")
        } footer: {
            Text("目标固定为所选 App 的包体。**目标优先**：点「添加目标文件（浏览 .app）」在 .app 里挑出要替换掉的文件，App 会自动在本机找同名文件配上（多处会让你选，一个都没有会弹本机选择器），并把目标路径锁定；**本机优先**：点「添加本机文件」，再按文件名自动匹配 .app 内的目标。\(model.bundleSemantics == .mirror ? "镜像替换会把 .app 里你这份没有的文件删掉。" : "合并只覆盖同名文件，其余保持不动（改 .app 更安全）。")执行前强制整棵递归备份。⚠️ 改自签 App 的包体会破坏签名校验，可能导致它直接打不开；动手前确认你有重装手段（回滚需要备份完好）。")
        }
    }

    /// 打开 .app 目录浏览器（根锁定为包体）
    private func openBundleBrowser(for file: ReplaceWizardModel.WizardFile) {
        guard let app = model.selectedApp else {
            model.append("请先在上面选一个目标 App，再浏览它的包体", .error)
            return
        }
        bundleBrowserRequest = BrowserRequest(file: file, app: app)
    }

    private func openBundleFolderBrowser(for folder: ReplaceWizardModel.WizardFolder) {
        guard let app = model.selectedApp else {
            model.append("请先在上面选一个目标 App，再浏览它的包体", .error)
            return
        }
        bundleFolderBrowserRequest = FolderBrowserRequest(folder: folder, app: app)
    }

    // MARK: 自动化任务（用户显式保存 + 手动运行）

    private var savedTasksSection: some View {
        Section {
            Button {
                newTaskName = model.suggestedTaskName()
                namingTask = true
            } label: {
                Label("保存当前设置为自动化任务", systemImage: "square.and.arrow.down")
            }

            if model.hasUnsavedChanges {
                Text("当前绑定有改动还没保存——保存后才会出现在下面的任务列表里。")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            if model.savedTasks.isEmpty {
                Text("还没有保存的任务：先把上面的模式、目标 App 与替换内容选好，再点「保存当前设置为自动化任务」。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                // 固定高度可滚动（照 Morph 的日志区做法），任务多了也不遮屏
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.savedTasks) { saved in
                            SavedTaskRow(saved: saved) {
                                model.runSavedTask(saved)
                            }
                            .contextMenu {
                                Button {
                                    model.loadTaskIntoEditor(saved)
                                } label: {
                                    Label("载入编辑", systemImage: "square.and.pencil")
                                }
                                Button {
                                    renameTarget = saved
                                    renameText = saved.name
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    deleteTarget = saved
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 260)
            }
        } header: {
            Text("自动化任务")
        } footer: {
            Text("这些任务只有你点「运行」才会执行：App 不会在后台、也不会在启动时自动改文件。运行时一律强制开启备份并写运行记录，可在下方或「记录」页一键回滚；没有沙盒外读写权限时会提示先去设置页激活内核访问。")
        }
    }

    // MARK: 执行

    private var runSection: some View {
        Section {
            Button {
                model.startReplace()
            } label: {
                HStack {
                    Spacer()
                    if model.isRunning {
                        ProgressView()
                            .padding(.trailing, 8)
                    }
                    Image(systemName: "arrow.2.squarepath")
                    Text(model.isRunning ? "替换中…" : "开始替换")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(!model.readyToRun)

            HStack(spacing: 12) {
                Image(systemName: kernelReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(kernelReady ? .green : .orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kernelReady ? "已具备沙盒外读写" : "还没有沙盒外读写权限")
                        .font(.subheadline)
                    Text(kernelReady
                         ? EnvironmentProbe.info().summary
                         : "请到「设置」页点『激活内核访问』；越狱 / roothide / TrollStore 环境可直接用")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)

            Toggle(isOn: $model.autoBackup) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("执行前自动备份")
                        .font(.subheadline)
                    Text(model.mode == .files
                         ? (model.autoBackup
                            ? "覆盖前把原件整份存到 Documents/Backups，随时可一键回滚"
                            : "已关闭：覆盖后没有回滚兜底")
                         : (model.mode == .folders
                            ? "文件夹模式强制开启：目标文件夹会被整棵递归备份"
                            : "包体模式强制开启：.app 会被整棵递归备份"))
                        .font(.caption2)
                        .foregroundColor(model.autoBackup ? .secondary : .orange)
                }
            }
            .disabled(model.mode != .files)

            HStack {
                Text(model.mode == .files ? "待替换文件" : (model.mode == .folders ? "待替换文件夹" : "待替换内容"))
                Spacer()
                Text("\(model.currentBoundCount) / \(model.currentItemCount) 个已绑定")
                    .foregroundColor(model.currentBoundCount > 0 ? .secondary : .orange)
            }
        } footer: {
            switch model.mode {
            case .files:
                Text(model.autoBackup
                     ? "执行前会把每个被覆盖的目标整份备份到 Documents/Backups；写之前自动把目标父目录属主改成 mobile:mobile。"
                     : "⚠️ 自动备份已关闭：覆盖后无法回滚，需要兜底就把上面的开关打开。")
            case .folders:
                Text("文件夹模式为镜像替换：目标文件夹里源没有的旧文件会被移除。替换前会把整个目标文件夹递归备份到 Documents/Backups，写之前自动把目标父目录属主改成 mobile:mobile。")
            case .bundle:
                Text("包体模式会把整个 .app 递归备份到 Documents/Backups，写之前自动把包体父目录属主改成 mobile:mobile。改自签 App 的包体可能让它打不开，回滚需要备份完好。")
            }
        }
    }

    // MARK: 完成后

    @ViewBuilder
    private var resultSection: some View {
        if let summary = model.lastRunSummary {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: model.lastRunSucceeded
                          ? "checkmark.circle.fill"
                          : "xmark.octagon.fill")
                        .font(.title3)
                        .foregroundColor(model.lastRunSucceeded ? .green : .red)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.lastRunWasFolders
                             ? (model.lastRunSucceeded ? "整目录替换成功" : "整目录替换未完全成功")
                             : (model.lastRunSucceeded ? "替换成功" : "替换未完全成功"))
                            .font(.subheadline)
                        Text(summary)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        if let id = model.lastBackupId {
                            Text("备份：\(id)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.vertical, 2)

                Button {
                    onOpenRecords()
                } label: {
                    Label("查看运行记录", systemImage: "clock.arrow.circlepath")
                }

                Button(role: .destructive) {
                    rollbackConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        if model.isRestoring {
                            ProgressView()
                        }
                        Label(model.isRestoring ? "回滚中…" : "一键回滚这次替换", systemImage: "arrow.uturn.backward")
                    }
                }
                .disabled(model.lastBackupId == nil || model.isRestoring)
            } header: {
                Text("这次的结果")
            } footer: {
                if !model.lastBackupEnabled {
                    Text("⚠️ 这次执行时「执行前自动备份」是关的，所以没有备份、无法回滚。")
                } else if model.lastBackupId == nil {
                    Text("这次没有产生备份（没有文件被真正覆盖），所以没有可回滚的内容。")
                } else {
                    Text("回滚会把备份里的原件拷回原位，并恢复权限与属主。")
                }
            }
        }
    }

    // MARK: 最近的替换

    @ViewBuilder
    private var recentSection: some View {
        let runs = model.recentReplaceRuns
        if !runs.isEmpty {
            Section {
                ForEach(Array(runs.prefix(8))) { run in
                    RecentRunRow(run: run,
                                 canRollback: model.canRollback(run),
                                 isRestoring: model.isRestoring,
                                 rollback: { pendingRollbackRun = run },
                                 showLog: { logSheetRun = run },
                                 delete: { model.deleteRun(run) })
                }
            } header: {
                Text("最近的替换")
            } footer: {
                Text("回滚走的是和「记录」页同一套（RunStore.restore）；这里只列本页产生的替换记录，最多显示最近 8 条。")
            }
        }
    }

    // MARK: 日志

    private var logSection: some View {
        Section {
            if model.logs.isEmpty {
                Text("暂无日志")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.logs) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(color(for: line.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 180, maxHeight: 260)

                HStack {
                    Button {
                        UIPasteboard.general.string = model.plainLogText
                    } label: {
                        Label("复制日志", systemImage: "doc.on.doc")
                    }
                    Spacer()
                    Button("清空日志") {
                        model.clearLogs()
                    }
                }
                .font(.footnote)
            }
        } header: {
            Text("替换日志")
        }
    }

    private func color(for level: ReplaceWizardModel.LogLine.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

// MARK: - 行

private struct WizardFileRow: View {
    let file: ReplaceWizardModel.WizardFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundColor(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.hintText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(hintColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if file.state == .ambiguous || file.state == .notFound {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch file.state {
        case .unique: return "checkmark.circle.fill"
        case .manual: return "hand.point.right.fill"
        case .ambiguous: return "questionmark.circle.fill"
        case .notFound: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch file.state {
        case .unique: return .green
        case .manual: return .accentColor
        case .ambiguous: return .orange
        case .notFound: return .red
        }
    }

    private var hintColor: Color {
        switch file.state {
        case .unique, .manual: return .secondary
        case .ambiguous: return .orange
        case .notFound: return .red
        }
    }
}

// MARK: - 文件夹行

// MARK: - 自动化任务一行

private struct SavedTaskRow: View {
    let saved: ReplaceSavedTask
    let onRun: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: saved.task.mode.icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(saved.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(saved.summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(saved.task.mode == .bundle ? saved.task.bundlePath
                                                : (saved.task.dataPath.isEmpty ? saved.task.bundlePath : saved.task.dataPath))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                onRun()
            } label: {
                Label("运行", systemImage: "play.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

private struct FolderRow: View {
    let folder: ReplaceWizardModel.WizardFolder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.targetPath == nil ? "folder" : "folder.fill")
                .font(.title3)
                .foregroundColor(folder.targetPath == nil ? .orange : .accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(folder.itemCount) 个文件 · \(folder.sizeText)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(folder.hintText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(folder.targetPath == nil ? .orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if folder.targetPath == nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 选择候选目标

private struct CandidateTargetSheet: View {
    /// 选什么：目标路径（本机优先流程）还是本地替换文件（目标优先流程）
    enum Kind {
        case target
        case local
    }

    let file: ReplaceWizardModel.WizardFile
    let kind: Kind
    let onPick: (String) -> Void

    init(file: ReplaceWizardModel.WizardFile,
         kind: Kind = .target,
         onPick: @escaping (String) -> Void) {
        self.file = file
        self.kind = kind
        self.onPick = onPick
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(file.candidates, id: \.self) { candidate in
                        Button {
                            onPick(candidate)
                        } label: {
                            Text(candidate)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                        }
                    }
                } footer: {
                    Text(kind == .local
                         ? "这些是本机 Documents 里的同名文件。选一个作为本地替换源——它会覆盖上面已经锁定的目标路径。"
                         : "这些都在目标 App 的数据容器里、且文件名和本地文件相同。选一个作为替换目标。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - 手填目标路径

private struct ManualTargetSheet: View {
    let initial: String?
    let dataPath: String?
    let name: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("/var/mobile/Containers/Data/Application/…/config.json", text: $path)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("目标完整路径")
                } footer: {
                    Text("必须写绝对路径（以 / 开头）。目标不存在时会作为新文件写进去，同样会被备份会话记录，可一键回滚。")
                }

                if let dataPath = dataPath, !dataPath.isEmpty {
                    Section {
                        Button {
                            path = (dataPath as NSString).appendingPathComponent(name)
                        } label: {
                            Label("用数据容器 + 这个文件名", systemImage: "wand.and.stars")
                        }
                    } footer: {
                        Text(dataPath)
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
            }
            .navigationTitle("指定 \(name) 的目标")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                path = initial ?? ""
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        onConfirm(path)
                        dismiss()
                    }
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - 浏览请求（把目标 App 一起带进 sheet）

struct BrowserRequest: Identifiable {
    let id = UUID()
    let file: ReplaceWizardModel.WizardFile
    let app: InstalledApp
}

/// 文件夹模式的浏览请求（复用同一个浏览器，只是打开「选择此文件夹」）
struct FolderBrowserRequest: Identifiable {
    let id = UUID()
    let folder: ReplaceWizardModel.WizardFolder
    let app: InstalledApp
}

/// 目标优先：浏览目标目录并多选文件（先挑「要被替换掉的那个文件」，再配本地替换源）
struct TargetFirstRequest: Identifiable {
    let id = UUID()
    let app: InstalledApp
    /// true = 浏览包体(.app)；false = 浏览数据容器
    let inBundle: Bool
}

/// 目标优先：某一条目标还没配上本地文件，等本机选择器选完绑上去
struct PendingLocalPick: Identifiable {
    let id = UUID()
    let rowID: UUID
    let target: String
    let inBundle: Bool
}

// MARK: - 单条记录的日志

private struct RunLogSheet: View {
    let title: String
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .navigationTitle("替换日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - 「最近的替换」一行

private struct RecentRunRow: View {

    let run: RunRecord
    let canRollback: Bool
    let isRestoring: Bool
    let rollback: () -> Void
    let showLog: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: run.scriptName.contains("文件夹")
                      ? "folder.fill"
                      : (run.success ? "checkmark.circle.fill" : "xmark.octagon.fill"))
                    .font(.title3)
                    .foregroundColor(run.success ? .green : .red)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ReplaceWizardModel.timeText(run.date))
                        .font(.subheadline)
                    Text(run.summary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Text(run.targetSummary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            HStack(spacing: 16) {
                if canRollback {
                    Button(role: .destructive) {
                        rollback()
                    } label: {
                        Label(isRestoring ? "回滚中…" : "回滚", systemImage: "arrow.uturn.backward")
                            .font(.footnote)
                    }
                    .disabled(isRestoring)
                } else {
                    Text("无备份")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Button {
                    showLog()
                } label: {
                    Label("查看日志", systemImage: "doc.text.magnifyingglass")
                        .font(.footnote)
                }

                Button(role: .destructive) {
                    delete()
                } label: {
                    Label("删除记录", systemImage: "trash")
                        .font(.footnote)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}
