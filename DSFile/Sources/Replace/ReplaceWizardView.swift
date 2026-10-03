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
        let localPath: String
        let name: String
        let sizeText: String
        /// 只读转储用不到，但保留字段方便以后扩展
        var targetPath: String?
        var candidates: [String] = []
        var state: FileState = .notFound

        var hintText: String {
            if let target = targetPath, !target.isEmpty {
                return "→ \(target)"
            }
            return state.hint
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

    /// 「执行前自动备份」开关（持久化；关掉就没有回滚兜底）
    @Published var autoBackup: Bool {
        didSet { UserDefaults.standard.set(autoBackup, forKey: Self.autoBackupKey) }
    }

    static let autoBackupKey = "myfilza.replaceAutoBackup"
    /// 本页产生的运行记录统一用这个名字，「最近的替换」按它过滤
    static let runScriptName = "一键替换"

    init() {
        if let stored = UserDefaults.standard.object(forKey: Self.autoBackupKey) as? Bool {
            autoBackup = stored
        } else {
            autoBackup = true
        }
    }

    let inboxDirectory: String = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent("ReplaceInbox")
    }()

    private var matchToken = UUID()

    // MARK: - 目标 App

    func loadApps() {
        isScanningApps = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppScanner.installedApps()
            DispatchQueue.main.async {
                self.apps = list
                self.isScanningApps = false
                self.append("扫描到 \(list.count) 个已安装 App", .info)
            }
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
    }

    /// 「更换」按钮：清掉目标（列表重新展开）
    func clearSelection() {
        selectedApp = nil
        append("已取消目标选择", .info)
        rematchAll()
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
        DSPickers.presentOpenPicker(utis: nil, multiple: true, asCopy: true, completion: { urls in
            guard !urls.isEmpty else { return }
            let fm = FileManager.default
            try? fm.createDirectory(atPath: self.inboxDirectory, withIntermediateDirectories: true)

            var added = 0
            for url in urls {
                let destination = self.uniqueInboxPath(for: url.lastPathComponent)
                do {
                    if fm.fileExists(atPath: destination) { try fm.removeItem(atPath: destination) }
                    try fm.copyItem(at: url, to: URL(fileURLWithPath: destination))
                    added += 1
                } catch {
                    self.append("导入失败 \(url.lastPathComponent)：\(error.localizedDescription)", .error)
                }
            }
            self.append(added > 0 ? "已导入 \(added) 个文件" : "没有导入任何文件", added > 0 ? .success : .warning)
            self.reloadInbox()
            self.rematchAll()
        }, cancel: nil)
    }

    func removeFiles(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where index < files.count {
            let removed = files.remove(at: index)
            append("已从列表移除 \(removed.name)（文件本体保留在 ReplaceInbox）", .info)
        }
    }

    func removeFile(id: UUID) {
        files.removeAll { $0.id == id }
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
    }

    /// 清除某一条的绑定（长按菜单用）
    func clearTarget(for id: UUID) {
        setTarget(path: "", for: id, manual: false)
    }

    // MARK: - 执行

    var boundCount: Int { files.filter { ($0.targetPath ?? "").isEmpty == false }.count }
    var readyToRun: Bool { selectedApp != nil && boundCount > 0 && !isRunning }

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

        let bound = files.filter { !(($0.targetPath ?? "").isEmpty) }
        guard !bound.isEmpty else {
            append("还没有可替换的条目：每个文件都要先绑定一个目标路径", .error)
            return
        }

        isRunning = true
        lastRunSummary = nil
        lastBackupId = nil
        lastRunSucceeded = false
        lastBackupEnabled = autoBackup
        append("=== 开始替换：\(bound.count) 个文件 → \(app.name) ===", .info)
        if !autoBackup {
            append("⚠️ 本次关闭了「执行前自动备份」：覆盖后无法回滚，请自行确认。", .warning)
        }

        var steps: [ScriptRecipe.Step] = []
        for file in bound {
            steps.append(ScriptRecipe.Step(op: "replace",
                                           source: file.localPath,
                                           dest: file.targetPath,
                                           mode: nil,
                                           owner: nil,
                                           note: nil,
                                           optional: false))
        }

        let recipe = ScriptRecipe(schema: 1,
                                  name: "一键替换（\(app.name)）",
                                  note: "由「替换」页向导生成：每个文件替换前都会整份备份。",
                                  target: nil,
                                  options: ScriptRecipe.Options(backup: autoBackup,
                                                                killTarget: false,
                                                                stopOnError: true,
                                                                fixOwnership: true),
                                  steps: steps)

        let target = ResolvedTarget(bundleId: app.bundleId,
                                    name: app.name,
                                    bundlePath: app.bundlePath,
                                    dataPath: app.dataPath ?? "",
                                    executableName: app.executableName)

        let script = ScriptItem(name: Self.runScriptName,
                                kind: .recipe,
                                fileName: "recipe.json",
                                folderName: "一键替换")

        let runner = RecipeRunner(script: script, recipe: recipe, target: target)
        let backupRequested = autoBackup

        DispatchQueue.global(qos: .userInitiated).async {
            let result = runner.run()

            let record = RunRecord(id: RunStore.makeRunId(scriptName: script.name),
                                   date: Date(),
                                   scriptName: script.name,
                                   scriptKind: script.kind.rawValue,
                                   targetSummary: target.summary,
                                   success: result.success,
                                   dryRun: false,
                                   summary: result.summary,
                                   backupId: result.backupId,
                                   logPath: nil)
            _ = RunStore.shared.appendRun(record, log: result.log.joined(separator: "\n"))

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
                DSLog.shared.info("一键替换 \(target.summary)：\(result.summary)",
                                  source: "替换")
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
    @State private var appFilter: String = ""
    @State private var activationAlert = false
    @State private var rollbackConfirm = false
    @State private var logSheetRun: RunRecord?
    @State private var pendingRollbackRun: RunRecord?
    @State private var loaded = false

    var body: some View {
        NavigationView {
            Form {
                targetSection
                fileSection
                runSection
                resultSection
                recentSection
                logSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("替换")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        model.importFiles()
                    } label: {
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
            .onAppear {
                guard !loaded else { return }
                loaded = true
                model.reloadInbox()
                model.loadApps()
                model.append("提示：每个文件替换前都会整份备份，随时可以在下方或「记录」页一键回滚。", .info)
            }
            .onChange(of: model.needsActivation) { needs in
                if needs {
                    activationAlert = true
                    model.needsActivation = false
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
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
                Text("没扫描到已安装 App。激活内核访问后再回来试试。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
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
            Text("单选：点一下选中，点「更换」可取消重选。选中后下面会自动在它的数据容器里递归找同名文件。")
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
                    Button {
                        openBrowser(for: file)
                    } label: {
                        Label("浏览目标 App 目录", systemImage: "folder")
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
                model.importFiles()
            } label: {
                Label("添加本地文件…", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("替换文件（自动匹配 / 浏览目录 / 手填）")
        } footer: {
            Text("唯一同名 → 自动绑定；同名多处 → 点那一行从候选里选；没找到 → 点那一行打开目标 App 目录浏览，或长按选「手填完整路径」。左滑从列表移除（文件本体留在 ReplaceInbox）。")
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
                    Text(model.autoBackup
                         ? "覆盖前把原件整份存到 Documents/Backups，随时可一键回滚"
                         : "已关闭：覆盖后没有回滚兜底")
                        .font(.caption2)
                        .foregroundColor(model.autoBackup ? .secondary : .orange)
                }
            }

            HStack {
                Text("待替换")
                Spacer()
                Text("\(model.boundCount) / \(model.files.count) 个已绑定")
                    .foregroundColor(model.boundCount > 0 ? .secondary : .orange)
            }
        } footer: {
            Text(model.autoBackup
                 ? "执行前会把每个被覆盖的目标整份备份到 Documents/Backups；写之前自动把目标父目录属主改成 mobile:mobile。"
                 : "⚠️ 自动备份已关闭：覆盖后无法回滚，需要兜底就把上面的开关打开。")
        }
    }

    // MARK: 完成后

    @ViewBuilder
    private var resultSection: some View {
        if let summary = model.lastRunSummary {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: model.lastRunSucceeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.title3)
                        .foregroundColor(model.lastRunSucceeded ? .green : .red)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.lastRunSucceeded ? "替换成功" : "替换未完全成功")
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

// MARK: - 选择候选目标

private struct CandidateTargetSheet: View {
    let file: ReplaceWizardModel.WizardFile
    let onPick: (String) -> Void

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
                    Text("这些都在目标 App 的数据容器里、且文件名和本地文件相同。选一个作为替换目标。")
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
                Image(systemName: run.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
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
