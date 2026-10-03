//
//  ReplaceTask.swift — 「替换」页的共享任务模型
//
//  这里放四样东西，供向导页与自动执行共用，避免两套逻辑：
//    1) ReplaceMode / 绑定结构体          —— 文件模式与文件夹模式的数据
//    2) ReplaceAutoTask + ReplaceAutoStore —— 自动任务（Documents/AutoTasks/auto.json）
//    3) ReplaceTaskBuilder                —— 把绑定组装成 ScriptRecipe 并交给既有 RecipeRunner
//    4) ReplaceAutoRunner + ReplaceRunGate —— 「启动时」「激活成功后」两个触发点 + 并发闸门
//
//  关键约定：替换/备份/回滚一律走既有引擎（RecipeRunner + RunStore），这里不新写文件逻辑。
//

import Foundation
import Combine

// MARK: - 模式

enum ReplaceMode: String, Codable, CaseIterable, Identifiable {
    case files
    case folders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "文件模式"
        case .folders: return "文件夹模式"
        }
    }

    var icon: String {
        switch self {
        case .files: return "doc.on.doc"
        case .folders: return "folder"
        }
    }

    /// 运行记录用的脚本名（两种模式都以「一键替换」开头，好让「最近的替换」统一过滤）
    var scriptName: String {
        switch self {
        case .files: return "一键替换"
        case .folders: return "一键替换·文件夹"
        }
    }

    /// 「最近的替换」按这个前缀过滤
    static let runPrefix = "一键替换"
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

// MARK: - 自动任务

struct ReplaceAutoTask: Codable {

    var bundleId: String
    var appName: String
    var bundlePath: String
    var dataPath: String
    var executableName: String

    var mode: ReplaceMode
    var files: [ReplaceFileBinding]
    var folders: [ReplaceFolderBinding]
    /// 自动执行时强制为 true（写盘前一定有备份）
    var backup: Bool
    var updatedAt: Date

    var itemCount: Int { mode == .files ? files.count : folders.count }
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

// MARK: - 持久化

enum ReplaceAutoStore {

    static var directory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent("AutoTasks")
    }

    static var filePath: String {
        (directory as NSString).appendingPathComponent("auto.json")
    }

    static func load() -> ReplaceAutoTask? {
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReplaceAutoTask.self, from: data)
    }

    @discardableResult
    static func save(_ task: ReplaceAutoTask) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(task) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: filePath))) != nil
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: filePath)
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }
}

// MARK: - 并发闸门（手动执行与自动执行互斥）

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

// MARK: - 组装与执行（向导 / 自动执行共用）

enum ReplaceTaskBuilder {

    static func makeScriptItem(mode: ReplaceMode) -> ScriptItem {
        ScriptItem(name: mode.scriptName,
                   kind: .recipe,
                   fileName: "recipe.json",
                   folderName: mode.scriptName)
    }

    static func makeRecipe(task: ReplaceAutoTask) -> ScriptRecipe {
        var steps: [ScriptRecipe.Step] = []

        if task.mode == .files {
            for binding in task.files {
                steps.append(ScriptRecipe.Step(op: "replace",
                                               source: binding.localPath,
                                               dest: binding.targetPath,
                                               mode: nil,
                                               owner: nil,
                                               note: nil,
                                               optional: false))
            }
        } else {
            for binding in task.folders {
                steps.append(ScriptRecipe.Step(op: "replaceDir",
                                               source: binding.localPath,
                                               dest: binding.targetPath,
                                               mode: nil,
                                               owner: nil,
                                               note: nil,
                                               optional: false))
            }
        }

        let note = task.mode == .files
            ? "由「替换」页向导生成：每个文件替换前都会整份备份。"
            : "由「替换」页文件夹模式生成：整个目标文件夹会被镜像替换，替换前递归备份。"

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
        DispatchQueue.main.async { RunStore.shared.reload() }
        return result
    }
}

// MARK: - 自动执行

enum ReplaceAutoRunner {

    /// 自动执行跑完（成功或失败）都会发这个通知，界面据此刷新「最近的替换」
    static let didRunNotification = Notification.Name("myfilza.replaceAutoDidRun")

    static let runOnLaunchKey = "myfilza.replaceAutoRunOnLaunch"
    static let runAfterActivationKey = "myfilza.replaceAutoRunAfterActivation"

    static var runOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: runOnLaunchKey) }
        set { UserDefaults.standard.set(newValue, forKey: runOnLaunchKey) }
    }

    static var runAfterActivation: Bool {
        get { UserDefaults.standard.bool(forKey: runAfterActivationKey) }
        set { UserDefaults.standard.set(newValue, forKey: runAfterActivationKey) }
    }

    static var isEnabled: Bool { runOnLaunch || runAfterActivation }

    /// App 启动时调用
    static func runIfEnabledOnLaunch() {
        guard runOnLaunch else { return }
        trigger(reason: "启动时自动执行")
    }

    /// 内核激活成功（沙盒逃逸成功）后调用
    static func runIfEnabledAfterActivation() {
        guard runAfterActivation else { return }
        trigger(reason: "激活成功后自动执行")
    }

    /// 「现在运行一次」按钮
    static func runNow() {
        trigger(reason: "手动触发一次自动任务")
    }

    private static func trigger(reason: String) {
        guard let task = ReplaceAutoStore.load(), !task.isEmpty else {
            DSLog.shared.warn("\(reason)：还没有保存的自动任务（先在「替换」页选好目标与内容）", source: "自动执行")
            postDidRun(success: false, summary: "没有保存的自动任务")
            return
        }

        // 环境门：越狱环境可达 或 内核逃逸成功，否则跳过并写明原因，绝不静默
        guard EnvironmentProbe.hasFileSystemAccess() else {
            DSLog.shared.warn("\(reason)：跳过——现在没有沙盒外读写权限（去设置页点『激活内核访问』；越狱 / roothide / TrollStore 环境可直接用）", source: "自动执行")
            postDidRun(success: false, summary: "没有沙盒外读写权限，已跳过")
            return
        }

        // 并发门：用户正在手动执行就不重复触发
        guard ReplaceRunGate.acquire() else {
            DSLog.shared.warn("\(reason)：跳过——已经有一次替换在执行中", source: "自动执行")
            return
        }

        DSLog.shared.info("\(reason)：\(task.summary)（已强制开启备份）", source: "自动执行")

        DispatchQueue.global(qos: .userInitiated).async {
            var task = task
            task.backup = true            // 自动执行一律备份
            let result = ReplaceTaskBuilder.run(task: task)
            ReplaceRunGate.release()

            DSLog.shared.info("自动执行结束：\(result.summary)", source: "自动执行")
            postDidRun(success: result.success, summary: result.summary)
        }
    }

    private static func postDidRun(success: Bool, summary: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didRunNotification,
                                            object: nil,
                                            userInfo: ["success": success, "summary": summary])
        }
    }
}
