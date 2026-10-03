//
//  ReplaceTask.swift — 「替换」页的共享任务模型
//
//  这里放五样东西，供向导页与任务执行共用，避免两套逻辑：
//    1) ReplaceMode / ReplaceBundleSemantics / 绑定结构体 —— 三种模式的数据
//    2) ReplaceAutoTask                                   —— 一份「替换配置」（模式 + 目标 + 绑定 + 语义 + 备份开关）
//    3) ReplaceSavedTask + ReplaceTaskStore                —— 用户显式保存的自动化任务（Documents/AutoTasks/tasks.json）
//    4) ReplaceTaskBuilder                                —— 把配置组装成 ScriptRecipe 并交给既有 RecipeRunner
//    5) ReplaceTaskRunner + ReplaceRunGate                —— 「点运行」时的环境门 + 并发闸门
//
//  关键约定：
//    * 替换/备份/回滚一律走既有引擎（RecipeRunner + RunStore），这里不新写文件逻辑；
//    * **没有任何自动触发点**：任务只会在用户点「运行」时执行（App 不会在后台或启动时改文件）。
//

import Foundation
import Combine

// MARK: - 模式

enum ReplaceMode: String, Codable, CaseIterable, Identifiable {
    case files
    case folders
    case bundle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "文件模式"
        case .folders: return "文件夹模式"
        case .bundle: return "包体(.app)模式"
        }
    }

    var icon: String {
        switch self {
        case .files: return "doc.on.doc"
        case .folders: return "folder"
        case .bundle: return "app.fill"
        }
    }

    /// 运行记录用的脚本名（三种模式都以「一键替换」开头，好让「最近的替换」统一过滤）
    var scriptName: String {
        switch self {
        case .files: return "一键替换"
        case .folders: return "一键替换·文件夹"
        case .bundle: return "一键替换·包体"
        }
    }

    /// 「最近的替换」按这个前缀过滤
    static let runPrefix = "一键替换"
}

/// 包体(.app)模式的语义
enum ReplaceBundleSemantics: String, Codable, CaseIterable, Identifiable {
    /// 镜像：删掉目标现有内容再整棵拷过去（目标里源没有的文件会被移除）
    case mirror
    /// 合并：只覆盖同名文件，目标里其余文件保持不动（改 .app 更安全，默认推荐）
    case merge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mirror: return "镜像替换"
        case .merge: return "仅覆盖同名文件"
        }
    }

    var subtitle: String {
        switch self {
        case .mirror: return "整个 .app 换掉：目标里源没有的文件会被移除"
        case .merge: return "合并：只覆盖同名文件，其余保持不动（推荐）"
        }
    }

    /// 对应的配方 op
    var opName: String {
        switch self {
        case .mirror: return "replaceDir"
        case .merge: return "mergeDir"
        }
    }
}

// MARK: - 绑定

struct ReplaceFileBinding: Codable, Hashable {
    var localPath: String
    var name: String
    var targetPath: String
}

struct ReplaceFolderBinding: Codable, Hashable {
    var localPath: String
    var name: String
    var targetPath: String
}

// MARK: - 一份替换配置

struct ReplaceAutoTask: Codable, Hashable {

    var bundleId: String
    var appName: String
    var bundlePath: String
    var dataPath: String
    var executableName: String

    var mode: ReplaceMode
    /// 文件模式：逐个文件；包体模式：按文件名匹配进 .app 的文件
    var files: [ReplaceFileBinding]
    /// 文件夹模式：整目录镜像；包体模式：最多一个源文件夹（换/并入整个 .app）
    var folders: [ReplaceFolderBinding]
    /// 仅包体模式使用；旧数据没有这个字段时为 nil（按镜像处理）
    var semantics: ReplaceBundleSemantics?
    /// 执行前是否备份（运行任务时一律强制为 true）
    var backup: Bool
    var updatedAt: Date

    var effectiveSemantics: ReplaceBundleSemantics { semantics ?? .mirror }

    var itemCount: Int {
        switch mode {
        case .files: return files.count
        case .folders: return folders.count
        case .bundle: return files.count + (folders.isEmpty ? 0 : 1)
        }
    }

    var isEmpty: Bool { itemCount == 0 }

    var summary: String {
        "\(appName) · \(mode.title) · \(itemCount) 项"
    }

    var target: ResolvedTarget {
        ResolvedTarget(bundleId: bundleId,
                       name: appName,
                       bundlePath: bundlePath,
                       dataPath: dataPath,
                       executableName: executableName)
    }
}

// MARK: - 用户保存的自动化任务

struct ReplaceSavedTask: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var createdAt: Date
    var task: ReplaceAutoTask

    var itemCount: Int { task.itemCount }
    var isEmpty: Bool { task.isEmpty }

    /// 列表行里显示的元信息
    var summary: String {
        var parts: [String] = [task.mode.title]
        if task.mode == .bundle {
            parts.append(task.effectiveSemantics.title)
        }
        parts.append("\(task.itemCount) 项")
        parts.append(task.backup ? "已备份" : "不备份")
        return parts.joined(separator: " · ")
    }

    /// 默认名字：App 名 · 模式 · 时间
    static func defaultName(for task: ReplaceAutoTask, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let app = task.appName.isEmpty ? "未选目标" : task.appName
        return "\(app) · \(task.mode.title) · \(formatter.string(from: date))"
    }
}

// MARK: - 持久化（tasks.json + 旧 auto.json 迁移）

enum ReplaceTaskStore {

    static var directory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent("AutoTasks")
    }

    static var filePath: String {
        (directory as NSString).appendingPathComponent("tasks.json")
    }

    /// 旧版单任务格式（0.3.3 及之前），只用于迁移
    static var legacyFilePath: String {
        (directory as NSString).appendingPathComponent("auto.json")
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = .prettyPrinted
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// 读取任务列表；顺带做一次旧格式迁移（只做一次）
    static func load() -> [ReplaceSavedTask] {
        migrateLegacyIfNeeded()
        guard let data = FileManager.default.contents(atPath: filePath),
              let tasks = try? decoder.decode([ReplaceSavedTask].self, from: data) else {
            return []
        }
        return tasks
    }

    @discardableResult
    static func save(_ tasks: [ReplaceSavedTask]) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(tasks) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: filePath))) != nil
    }

    /// 把 0.3.3 的 auto.json（单条任务）迁进新列表，避免用户已存的配置丢失。
    /// 迁移完成后把旧文件改名为 auto.json.bak，保证只迁一次。
    private static func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyFilePath) else { return }

        var tasks: [ReplaceSavedTask] = []
        if let data = fm.contents(atPath: filePath),
           let existing = try? decoder.decode([ReplaceSavedTask].self, from: data) {
            tasks = existing
        }

        if let legacyData = fm.contents(atPath: legacyFilePath),
           let legacy = try? decoder.decode(ReplaceAutoTask.self, from: legacyData),
           !legacy.isEmpty {
            let alreadyThere = tasks.contains { $0.task.bundleId == legacy.bundleId
                && $0.task.mode == legacy.mode
                && $0.task.itemCount == legacy.itemCount }
            if !alreadyThere {
                tasks.append(ReplaceSavedTask(id: UUID().uuidString,
                                              name: ReplaceSavedTask.defaultName(for: legacy, date: legacy.updatedAt),
                                              createdAt: legacy.updatedAt,
                                              task: legacy))
                _ = save(tasks)
            }
        }

        try? fm.moveItem(atPath: legacyFilePath,
                         toPath: (directory as NSString).appendingPathComponent("auto.json.bak"))
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }
}

// MARK: - 并发闸门（任何一次替换都互斥）

enum ReplaceRunGate {

    private static let lock = NSLock()
    private static var busy = false

    /// 拿到就返回 true；已有一次替换在跑就返回 false
    static func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    static func release() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    static var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy
    }
}

// MARK: - 组装与执行（向导 / 任务列表共用）

enum ReplaceTaskBuilder {

    static func makeScriptItem(mode: ReplaceMode) -> ScriptItem {
        ScriptItem(name: mode.scriptName,
                   kind: .recipe,
                   fileName: "recipe.json",
                   folderName: mode.scriptName)
    }

    static func makeRecipe(task: ReplaceAutoTask) -> ScriptRecipe {
        var steps: [ScriptRecipe.Step] = []

        for binding in task.files {
            steps.append(ScriptRecipe.Step(op: "replace",
                                           source: binding.localPath,
                                           dest: binding.targetPath,
                                           mode: nil,
                                           owner: nil,
                                           note: nil,
                                           optional: false))
        }

        if task.mode == .folders {
            for binding in task.folders {
                steps.append(ScriptRecipe.Step(op: "replaceDir",
                                               source: binding.localPath,
                                               dest: binding.targetPath,
                                               mode: nil,
                                               owner: nil,
                                               note: nil,
                                               optional: false))
            }
        } else if task.mode == .bundle {
            // 包体模式的源文件夹：镜像或合并进 .app（op 由语义决定）
            let op = task.effectiveSemantics.opName
            for binding in task.folders {
                steps.append(ScriptRecipe.Step(op: op,
                                               source: binding.localPath,
                                               dest: binding.targetPath,
                                               mode: nil,
                                               owner: nil,
                                               note: nil,
                                               optional: false))
            }
        }

        let note: String
        switch task.mode {
        case .files:
            note = "由「替换」页向导生成：每个文件替换前都会整份备份。"
        case .folders:
            note = "由「替换」页文件夹模式生成：整个目标文件夹会被镜像替换，替换前递归备份。"
        case .bundle:
            note = "由「替换」页包体(.app)模式生成：语义为\(task.effectiveSemantics.title)，替换前整棵递归备份。"
        }

        return ScriptRecipe(schema: 1,
                            name: "\(task.mode.scriptName)（\(task.appName)）",
                            note: note,
                            target: nil,
                            options: ScriptRecipe.Options(backup: task.backup,
                                                          killTarget: false,
                                                          stopOnError: true,
                                                          fixOwnership: true),
                            steps: steps)
    }

    /// 执行一次并把运行记录写进 Runs/。**同步阻塞**，调用方自己放后台队列。
    @discardableResult
    static func run(task: ReplaceAutoTask) -> RunOutcome {
        let target = task.target
        let script = makeScriptItem(mode: task.mode)
        let recipe = makeRecipe(task: task)
        let runner = RecipeRunner(script: script, recipe: recipe, target: target)
        let result = runner.run()

        // 把目标路径也写进 targetSummary，好让「最近的替换」那一行直接看得到路径
        var targetSummary = target.summary
        if task.mode == .folders, !task.folders.isEmpty {
            targetSummary += " · → " + task.folders.map(\.targetPath).joined(separator: " · ")
        } else if task.mode == .bundle {
            if !task.bundlePath.isEmpty { targetSummary += " · → " + task.bundlePath }
        }

        let record = RunRecord(id: RunStore.makeRunId(scriptName: script.name),
                               date: Date(),
                               scriptName: script.name,
                               scriptKind: script.kind.rawValue,
                               targetSummary: targetSummary,
                               success: result.success,
                               dryRun: false,
                               summary: result.summary,
                               backupId: result.backupId,
                               logPath: nil)
        _ = RunStore.shared.appendRun(record, log: result.log.joined(separator: "\n"))
        DispatchQueue.main.async { RunStore.shared.reload() }
        return result
    }
}

// MARK: - 执行已保存的任务（只有用户点「运行」才会走这里）

enum ReplaceTaskRunner {

    /// 跑完（成功或失败）都会发这个通知，界面据此刷新「最近的替换」
    static let didRunNotification = Notification.Name("myfilza.replaceAutoDidRun")

    /// 返回是否真的开始执行（false = 被环境门/并发门挡下，日志里已写明原因）
    @discardableResult
    static func run(_ saved: ReplaceSavedTask, reason: String = "手动运行") -> Bool {
        guard !saved.isEmpty else {
            DSLog.shared.warn("\(reason)：任务「\(saved.name)」里没有任何绑定，先载入编辑补上目标路径", source: "替换任务")
            postDidRun(success: false, summary: "任务里没有绑定")
            return false
        }

        // 环境门：越狱环境可达 或 内核逃逸成功，否则明确提示，绝不静默、也绝不自动去跑漏洞
        guard EnvironmentProbe.hasFileSystemAccess() else {
            DSLog.shared.warn("\(reason)：跳过——现在没有沙盒外读写权限。请到「设置」页点『激活内核访问』（越狱 / roothide / TrollStore 环境可直接用）", source: "替换任务")
            postDidRun(success: false, summary: "没有沙盒外读写权限，请先激活内核访问")
            return false
        }

        // 并发门：已经有替换在跑就不重复
        guard ReplaceRunGate.acquire() else {
            DSLog.shared.warn("\(reason)：跳过——已经有一次替换在执行中", source: "替换任务")
            postDidRun(success: false, summary: "已有替换在执行中")
            return false
        }

        DSLog.shared.info("\(reason)：任务「\(saved.name)」（\(saved.summary)，已强制开启备份）", source: "替换任务")

        DispatchQueue.global(qos: .userInitiated).async {
            var task = saved.task
            task.backup = true            // 运行任务一律备份，保证可回滚
            let result = ReplaceTaskBuilder.run(task: task)
            ReplaceRunGate.release()

            DSLog.shared.info("任务「\(saved.name)」结束：\(result.summary)", source: "替换任务")
            postDidRun(success: result.success, summary: result.summary)
        }
        return true
    }

    private static func postDidRun(success: Bool, summary: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didRunNotification,
                                            object: nil,
                                            userInfo: ["success": success, "summary": summary])
        }
    }
}
