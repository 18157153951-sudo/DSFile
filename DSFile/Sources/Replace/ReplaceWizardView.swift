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
    /// 需要用户去设置页激活时置真，视图据此弹提示
    @Published var needsActivation = false

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

    // MARK: - 执行

    var boundCount: Int { files.filter { ($0.targetPath ?? "").isEmpty == false }.count }
    var readyToRun: Bool { selectedApp != nil && boundCount > 0 && !isRunning }

    func startReplace() {
        guard let app = selectedApp else {
            append("请先在上方选择目标 App", .error)
            return
        }
        guard DSKernel.isEscaped() else {
            needsActivation = true
            append("尚未激活内核访问：沙盒外的路径写不进去。请到「设置」页点『激活内核访问』，成功后再回来。", .error)
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
        append("=== 开始替换：\(bound.count) 个文件 → \(app.name) ===", .info)

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
                                  options: ScriptRecipe.Options(backup: true,
                                                                killTarget: false,
                                                                stopOnError: true,
                                                                fixOwnership: true),
                                  steps: steps)

        let target = ResolvedTarget(bundleId: app.bundleId,
                                    name: app.name,
                                    bundlePath: app.bundlePath,
                                    dataPath: app.dataPath ?? "",
                                    executableName: app.executableName)

        let script = ScriptItem(name: "一键替换",
                                kind: .recipe,
                                fileName: "recipe.json",
                                folderName: "一键替换")

        let runner = RecipeRunner(script: script, recipe: recipe, target: target)

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
    @State private var appFilter: String = ""
    @State private var activationAlert = false
    @State private var rollbackConfirm = false
    @State private var loaded = false

    var body: some View {
        NavigationView {
            Form {
                targetSection
                fileSection
                runSection
                resultSection
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
            } else {
                if model.apps.count > 25 {
                    TextField("按名字或 bundle id 过滤", text: $appFilter)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                ForEach(filteredApps) { app in
                    Button {
                        model.toggleSelection(app)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: model.selectedApp?.bundleId == app.bundleId ? "largecircle.fill.circle" : "circle")
                                .font(.title3)
                                .foregroundColor(model.selectedApp?.bundleId == app.bundleId ? .accentColor : .secondary)
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
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("目标 App")
        } footer: {
            Text("单选：点一下选中，再点一下取消。下面会自动在它的数据容器里递归找同名文件。")
        }
    }

    private var filteredApps: [InstalledApp] {
        let keyword = appFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return model.apps }
        return model.apps.filter {
            $0.name.lowercased().contains(keyword) || $0.bundleId.lowercased().contains(keyword)
        }
    }

    /// 内核访问是否已激活（读一下 kernel.phase，让 SwiftUI 跟踪激活状态的变化）
    private var kernelReady: Bool {
        _ = kernel.phase
        return DSKernel.isEscaped()
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
                    case .notFound:
                        manualSheet = file
                    case .unique, .manual:
                        // 已经绑定好了：再点一次可以改
                        manualSheet = file
                    }
                } label: {
                    WizardFileRow(file: file)
                }
                .buttonStyle(.plain)
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
            Text("替换文件（按文件名自动匹配）")
        } footer: {
            Text("唯一同名 → 自动绑定并在下面显示目标路径；同名多处或没找到 → 点那一行选择或手填。左滑从列表移除（文件本体留在 ReplaceInbox）。")
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
                    Text(kernelReady ? "内核访问已激活" : "尚未激活内核访问")
                        .font(.subheadline)
                    Text(kernelReady
                         ? "目标 App 沙盒外的路径可以直接读写"
                         : "请到「设置」页点『激活内核访问』，否则替换会失败")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)

            HStack {
                Text("待替换")
                Spacer()
                Text("\(model.boundCount) / \(model.files.count) 个已绑定")
                    .foregroundColor(model.boundCount > 0 ? .secondary : .orange)
            }
        } footer: {
            Text("执行前会把每个被覆盖的目标整份备份到 Documents/Backups；写之前自动把目标父目录属主改成 mobile:mobile。")
        }
    }

    // MARK: 完成后

    @ViewBuilder
    private var resultSection: some View {
        if let summary = model.lastRunSummary {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: model.lastBackupId != nil ? "checkmark.circle.fill" : "info.circle.fill")
                        .font(.title3)
                        .foregroundColor(model.lastBackupId != nil ? .green : .secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary)
                            .font(.subheadline)
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
                Text(model.lastBackupId == nil
                     ? "这次没有产生备份（没有文件被真正覆盖），所以没有可回滚的内容。"
                     : "回滚会把备份里的原件拷回原位，并恢复权限与属主。")
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
