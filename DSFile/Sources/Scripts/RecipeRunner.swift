//
//  RecipeRunner.swift — 配方脚本执行器（预演 / 执行 / 备份）
//
//  安全约定：
//  * 默认先「预演」，只做检查不改任何文件；
//  * 真正执行时，任何要被覆盖或删除的目标都会先整份拷进备份会话；
//  * 备份会话在结束时写 manifest.json，设置页/记录页可以一键回滚。
//

import Foundation

struct StepOutcome: Identifiable {
    enum Status: String {
        case planned
        case ok
        case skipped
        case failed

        var label: String {
            switch self {
            case .planned: return "将执行"
            case .ok: return "成功"
            case .skipped: return "跳过"
            case .failed: return "失败"
            }
        }
    }

    let id = UUID()
    let index: Int
    let op: String
    let summary: String
    var status: Status
    var message: String
}

struct RunOutcome {
    var outcomes: [StepOutcome]
    var success: Bool
    var summary: String
    var log: [String]
    var backupId: String?

    var failedCount: Int { outcomes.filter { $0.status == .failed }.count }
}

final class RecipeRunner {

    private let script: ScriptItem
    private let recipe: ScriptRecipe
    private let target: ResolvedTarget?
    private let scriptDirectory: String
    private let options: ScriptRecipe.Options

    init(script: ScriptItem, recipe: ScriptRecipe, target: ResolvedTarget?) {
        self.script = script
        self.recipe = recipe
        self.target = target
        self.scriptDirectory = ScriptLibrary.shared.directory(for: script)
        self.options = recipe.effectiveOptions
    }

    // MARK: - 预检

    private func preflight() -> [String] {
        var problems: [String] = []

        // 0.9.5：这里必须是「统一访问判定」，不能用 DSKernel.isEscaped()（那只是内核逃逸标志）。
        // 越狱版（.deb 装进 <jbroot>/Applications/）、MHA/MCM 租约（26/27 零内核）、
        // TrollStore 带 platform-application 的只读可达，都不经过内核逃逸 —— 用旧判据会把这些
        // 已经具备权限的用户误拦在配方/替换之外（0.9.4 真机反馈就是这个）。
        if !EnvironmentProbe.hasFileSystemAccess() {
            problems.append("尚未具备沙盒外访问（\(EnvironmentProbe.accessDeniedDiagnosis())）："
                + "涉及沙盒外路径的操作会失败。请到设置页点「激活」，"
                + "或改用越狱版安装（.deb）／MHA 身份包。")
        }

        let needsTarget = recipe.steps.contains { PlaceholderResolver.usesTarget($0.source) || PlaceholderResolver.usesTarget($0.dest) }
        if needsTarget && target == nil {
            problems.append("配方里用了 {app.*} 占位符，但没有选定目标 App，或目标 App 找不到。")
        }

        if recipe.steps.isEmpty {
            problems.append("配方里没有任何步骤。")
        }

        for (index, step) in recipe.steps.enumerated() {
            let op = step.op.lowercased()
            if !["replace", "copy", "move", "replacedir", "mergedir", "mkdir", "delete", "chmod", "chown", "kill", "note"].contains(op) {
                problems.append("第 \(index + 1) 步的操作名不认识：\(step.op)")
            }
            if ["replace", "copy", "move", "replacedir", "mergedir"].contains(op) && (step.source ?? "").isEmpty {
                problems.append("第 \(index + 1) 步（\(op)）缺少 source")
            }
            if op != "kill" && op != "note" && (step.dest ?? "").isEmpty {
                problems.append("第 \(index + 1) 步（\(op)）缺少 dest")
            }
        }

        return problems
    }

    // MARK: - 预演

    func dryRun() -> RunOutcome {
        var log: [String] = []
        log.append("=== 预演：\(recipe.displayName) ===")
        for problem in preflight() {
            log.append("⚠️ \(problem)")
        }
        if let target = target {
            log.append("目标：\(target.summary)")
            log.append("包体：\(target.bundlePath)")
            log.append("数据：\(target.dataPath)")
        }

        var outcomes: [StepOutcome] = []
        for (index, step) in recipe.steps.enumerated() {
            let outcome = perform(step: step, index: index, apply: false, session: nil, log: &log)
            outcomes.append(outcome)
        }

        let problems = preflight()
        let success = problems.isEmpty && !outcomes.contains { $0.status == .failed }
        log.append(success ? "预演通过：可以执行。" : "预演发现 \(problems.count + outcomes.filter { $0.status == .failed }.count) 个问题。")

        return RunOutcome(outcomes: outcomes, success: success,
                          summary: success ? "预演通过（\(outcomes.count) 步）" : "预演未通过",
                          log: log, backupId: nil)
    }

    // MARK: - 执行

    func run(progress: ((StepOutcome) -> Void)? = nil) -> RunOutcome {
        var log: [String] = []
        log.append("=== 执行：\(recipe.displayName) ===")

        let problems = preflight()
        if !problems.isEmpty {
            for problem in problems { log.append("❌ \(problem)") }
            return RunOutcome(outcomes: [], success: false, summary: "前置检查未通过", log: log, backupId: nil)
        }

        var session: BackupSession?
        if options.backup {
            session = RunStore.shared.beginBackup(scriptName: script.name,
                                                  targetSummary: target?.summary ?? "未指定目标")
            log.append("备份会话：\(session?.id ?? "-")")
        }

        if let target = target {
            log.append("目标：\(target.summary)")
            log.append("包体：\(target.bundlePath)")
            log.append("数据：\(target.dataPath)")
        }

        var outcomes: [StepOutcome] = []
        for (index, step) in recipe.steps.enumerated() {
            let outcome = perform(step: step, index: index, apply: true, session: session, log: &log)
            outcomes.append(outcome)
            progress?(outcome)
            if outcome.status == .failed && options.stopOnError {
                log.append("遇到失败且配置为「出错即停」，中止后续步骤。")
                break
            }
        }

        // 需要时结束目标 App（放在文件替换之后）
        if options.killTarget, !stepIncludesKill() {
            let name = target?.executableName ?? ""
            if !name.isEmpty {
                let killed = DSProcess.killProcesses(matchingExecutableName: name)
                log.append(killed > 0 ? "已结束目标进程 \(name)（\(killed) 个）" : "目标进程 \(name) 当前没有在运行")
            }
        }

        var backupId: String?
        if let session = session {
            let record = session.commit()
            RunStore.shared.add(record)
            backupId = record.id
            log.append("备份已保存：\(record.id)（\(record.entries.count) 项）")
        }

        let failed = outcomes.filter { $0.status == .failed }
        let success = failed.isEmpty
        let summary = success
            ? "完成：\(outcomes.count) 步全部成功"
            : "完成但有失败：\(failed.count)/\(outcomes.count) 步失败"
        log.append(success ? "✅ \(summary)" : "⚠️ \(summary)")

        return RunOutcome(outcomes: outcomes, success: success, summary: summary, log: log, backupId: backupId)
    }

    private func stepIncludesKill() -> Bool {
        return recipe.steps.contains { $0.op.lowercased() == "kill" }
    }

    // MARK: - 单步执行

    private func perform(step: ScriptRecipe.Step,
                         index: Int,
                         apply: Bool,
                         session: BackupSession?,
                         log: inout [String]) -> StepOutcome {

        let op = step.op.lowercased()
        let number = index + 1

        func make(_ summary: String, _ status: StepOutcome.Status, _ message: String) -> StepOutcome {
            log.append("[\(number)] \(op) \(summary) → \(status.label)\(message.isEmpty ? "" : "（\(message)）")")
            return StepOutcome(index: number, op: op, summary: summary, status: status, message: message)
        }

        let sourcePath: String? = step.source.map {
            PlaceholderResolver.resolvePath($0, target: target, scriptDirectory: scriptDirectory)
        }
        let destPath: String? = step.dest.map {
            PlaceholderResolver.resolvePath($0, target: target, scriptDirectory: scriptDirectory)
        }

        do {
            switch op {

            case "note":
                return make(step.note ?? "说明", .skipped, step.note ?? "")

            case "replace", "copy", "move":
                guard let sourcePath = sourcePath, let destPath = destPath else {
                    return make("参数不完整", .failed, "source/dest 不能为空")
                }
                guard FileSystemService.exists(sourcePath) else {
                    return step.optional == true
                        ? make(sourcePath, .skipped, "源文件不存在（可选步骤）")
                        : make(sourcePath, .failed, "源文件不存在")
                }
                let destExists = FileSystemService.exists(destPath)
                if apply {
                    if options.fixOwnership {
                        let parent = (destPath as NSString).deletingLastPathComponent
                        _ = FileOperations.makeWritable(parent)
                    }
                    if options.backup, destExists {
                        session?.capture(destPath)
                    }
                    if op == "move" {
                        try FileOperations.move(sourcePath, to: destPath)
                    } else {
                        try FileOperations.copy(sourcePath, to: destPath)
                    }
                    if options.fixOwnership {
                        _ = FileOperations.makeWritable(destPath)
                    }
                }
                return make("\((sourcePath as NSString).lastPathComponent) → \(destPath)",
                            apply ? .ok : .planned,
                            destExists ? (apply ? "已覆盖（原文件已备份）" : "将覆盖已有文件") : "新建")

            case "replacedir":
                // 「多出来的文件：删除」：把 dest 现有内容整棵删掉，再把 source 整棵拷进去
                guard let sourcePath = sourcePath, let destPath = destPath else {
                    return make("参数不完整", .failed, "source/dest 不能为空")
                }
                guard FileSystemService.exists(sourcePath) else {
                    return step.optional == true
                        ? make(sourcePath, .skipped, "源文件夹不存在（可选步骤）")
                        : make(sourcePath, .failed, "源文件夹不存在")
                }
                let dirDestExists = FileSystemService.exists(destPath)
                if apply {
                    if options.fixOwnership {
                        _ = FileOperations.makeWritable((destPath as NSString).deletingLastPathComponent)
                    }
                    if options.backup {
                        // 整棵递归备份；dest 不存在时登记 existed=false，回滚会把它删掉
                        session?.capture(destPath, recursive: true)
                    }
                    try FileOperations.replaceDirectory(source: sourcePath, dest: destPath)
                    if options.fixOwnership {
                        _ = FileOperations.makeWritable(destPath)
                    }
                }
                return make("\((sourcePath as NSString).lastPathComponent) → \(destPath)",
                            apply ? .ok : .planned,
                            dirDestExists
                                ? (apply ? "已替换整个文件夹（原目录整棵已备份，多出来的旧文件已移除）" : "将替换整个文件夹（多出来的旧文件会被移除）")
                                : (apply ? "已新建" : "将新建"))

            case "mergedir":
                // 「多出来的文件：保留」：只把源里有的文件写过去，目标里其余文件保持不动
                guard let sourcePath = sourcePath, let destPath = destPath else {
                    return make("参数不完整", .failed, "source/dest 不能为空")
                }
                guard FileSystemService.exists(sourcePath) else {
                    return step.optional == true
                        ? make(sourcePath, .skipped, "源文件夹不存在（可选步骤）")
                        : make(sourcePath, .failed, "源文件夹不存在")
                }
                let mergeDestExists = FileSystemService.exists(destPath)
                if apply {
                    if options.fixOwnership {
                        _ = FileOperations.makeWritable((destPath as NSString).deletingLastPathComponent)
                    }
                    if options.backup {
                        // 合并可能覆盖目录里任意同名文件，所以整棵递归备份
                        session?.capture(destPath, recursive: true)
                    }
                    try FileOperations.mergeDirectory(source: sourcePath, dest: destPath)
                    if options.fixOwnership {
                        _ = FileOperations.makeWritable(destPath)
                    }
                }
                return make("\((sourcePath as NSString).lastPathComponent) → \(destPath)",
                            apply ? .ok : .planned,
                            mergeDestExists
                                ? (apply ? "已覆盖同名文件（原目录整棵已备份，目标里其余文件保留）" : "将覆盖同名文件，目标里其余文件保留")
                                : (apply ? "已新建" : "将新建"))

            case "mkdir":
                guard let destPath = destPath else {
                    return make("参数不完整", .failed, "dest 不能为空")
                }
                let exists = FileSystemService.exists(destPath)
                if apply && !exists {
                    if options.fixOwnership {
                        _ = FileOperations.makeWritable((destPath as NSString).deletingLastPathComponent)
                    }
                    try FileManager.default.createDirectory(atPath: destPath, withIntermediateDirectories: true)
                }
                return make(destPath, apply ? .ok : .planned, exists ? "目录已存在" : (apply ? "已创建" : "将创建"))

            case "delete":
                guard let destPath = destPath else {
                    return make("参数不完整", .failed, "dest 不能为空")
                }
                guard FileSystemService.exists(destPath) else {
                    return step.optional == true
                        ? make(destPath, .skipped, "本来就不存在（可选步骤）")
                        : make(destPath, .failed, "目标不存在")
                }
                if apply {
                    if options.fixOwnership {
                        _ = FileOperations.makeWritable((destPath as NSString).deletingLastPathComponent)
                    }
                    if options.backup {
                        session?.capture(destPath)
                    }
                    try FileOperations.delete(destPath)
                }
                return make(destPath, apply ? .ok : .planned, apply ? "已删除（原件已备份）" : "将删除")

            case "chmod":
                guard let destPath = destPath, let mode = step.mode else {
                    return make("参数不完整", .failed, "dest/mode 不能为空")
                }
                if apply {
                    try FileOperations.chmod(destPath, octal: mode)
                }
                return make("\(destPath) → \(mode)", apply ? .ok : .planned, "")

            case "chown":
                guard let destPath = destPath, let owner = step.owner else {
                    return make("参数不完整", .failed, "dest/owner 不能为空")
                }
                if apply {
                    try FileOperations.chown(destPath, owner: owner, recursive: false)
                }
                return make("\(destPath) → \(owner)", apply ? .ok : .planned, "")

            case "kill":
                let name = target?.executableName ?? ""
                guard !name.isEmpty else {
                    return make("结束目标进程", .skipped, "没有可用的可执行文件名")
                }
                if apply {
                    let killed = DSProcess.killProcesses(matchingExecutableName: name)
                    return make("结束 \(name)", killed > 0 ? .ok : .skipped,
                                killed > 0 ? "已结束 \(killed) 个进程" : "目标没有在运行")
                }
                return make("结束 \(name)", .planned, "")

            default:
                return make(op, .failed, "不认识的操作")
            }
        } catch {
            return make(destPath ?? sourcePath ?? op, .failed, error.localizedDescription)
        }
    }
}

// MARK: - Shell 脚本执行

struct ShellScriptRunner {

    let script: ScriptItem
    let target: ResolvedTarget?

    func run(timeout: TimeInterval = 120, output: @escaping (String) -> Void) -> (code: Int32, error: String?) {
        let directory = ScriptLibrary.shared.directory(for: script)
        let path = ScriptLibrary.shared.scriptPath(for: script)

        var environment: [String: String] = [
            "DS_SCRIPT_DIR": directory,
            "DS_SCRIPT_NAME": script.name
        ]
        if let target = target {
            environment["DS_TARGET_BUNDLE"] = target.bundlePath
            environment["DS_TARGET_DATA"] = target.dataPath
            environment["DS_TARGET_BUNDLE_ID"] = target.bundleId
            environment["DS_TARGET_EXEC"] = target.executablePath
        }

        if !DSShell.isShellAvailable() {
            return (-1, "/bin/sh 不存在或不可执行，这个环境跑不了 shell 脚本")
        }

        var shellError: NSError?
        let code = DSShell.execScript(path,
                                      arguments: [],
                                      directory: directory,
                                      environment: environment,
                                      timeout: timeout,
                                      output: output,
                                      error: &shellError)
        if let shellError = shellError {
            return (-1, shellError.localizedDescription)
        }
        return (code, nil)
    }
}

// MARK: - 目标解析

enum TargetResolver {

    /// 从配方 + 用户选择解析出最终目标
    static func resolve(recipe: ScriptRecipe, override: InstalledApp?) -> ResolvedTarget? {
        if let app = override {
            return ResolvedTarget(bundleId: app.bundleId,
                                  name: app.name,
                                  bundlePath: app.bundlePath,
                                  dataPath: app.dataPath ?? "",
                                  executableName: app.executableName)
        }

        guard let spec = recipe.target else { return nil }

        if let bundleId = spec.bundleId, let app = AppScanner.app(withBundleId: bundleId) {
            return ResolvedTarget(bundleId: app.bundleId, name: app.name, bundlePath: app.bundlePath,
                                  dataPath: app.dataPath ?? "", executableName: app.executableName)
        }
        if let bundlePath = spec.bundlePath, let app = AppScanner.app(withBundlePath: bundlePath) {
            return ResolvedTarget(bundleId: app.bundleId, name: app.name, bundlePath: app.bundlePath,
                                  dataPath: app.dataPath ?? "", executableName: app.executableName)
        }
        // 只有原始路径也能跑（占位符会退化成配方里写死的路径）
        if let bundlePath = spec.bundlePath {
            return ResolvedTarget(bundleId: spec.bundleId ?? "",
                                  name: (bundlePath as NSString).lastPathComponent,
                                  bundlePath: bundlePath,
                                  dataPath: spec.dataPath ?? "",
                                  executableName: "")
        }
        return nil
    }
}
