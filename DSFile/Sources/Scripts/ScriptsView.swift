//
//  ScriptsView.swift — 脚本页（导入 / 新建 / 选目标 App / 预演 / 执行 / 看日志）
//
//  用户带过来的「脚本」有两种：
//    * 配方（recipe.json）：声明式，一步步 replace/copy/delete/chmod…，可预演、可回滚；
//    * Shell（run.sh）：直接交给 /bin/sh 跑（免越狱环境可能被沙盒拒绝 process-exec，会明确报错）。
//

import SwiftUI
import Foundation
import UIKit

// MARK: - 脚本列表

struct ScriptsView: View {

    @ObservedObject private var library = ScriptLibrary.shared
    @ObservedObject private var kernel = KernelCenter.shared

    @State private var detailScript: ScriptItem?
    @State private var newScriptVisible = false
    @State private var importError: String?

    var body: some View {
        NavigationView {
            Group {
                if library.scripts.isEmpty {
                    emptyState
                } else {
                    scriptList
                }
            }
            .navigationTitle("脚本")
            .toolbar { toolbarContent }
            .sheet(item: $detailScript) { script in
                ScriptDetailView(script: script)
            }
            .sheet(isPresented: $newScriptVisible) {
                NewScriptSheet { name, kind in
                    _ = ScriptLibrary.shared.createScript(name: name, kind: kind)
                }
            }
            .alert("导入失败", isPresented: importErrorBinding) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }

    private var scriptList: some View {
        List {
            Section {
                ForEach(library.scripts) { script in
                    Button {
                        detailScript = script
                    } label: {
                        ScriptRow(script: script, payloadCount: library.payloadFiles(for: script).count)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            library.delete(script)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            DSPickers.presentShareSheet(urls: [URL(fileURLWithPath: library.directory(for: script))])
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                }
            } footer: {
                Text("脚本保存在本机 App 的 Documents/Scripts 里，可以用「文件」页或 iTunes 文件共享导出。执行前会先做前置检查，任何被覆盖的文件都会先整份备份到「记录」页。")
            }

            Section("导入") {
                Button {
                    importScriptFiles()
                } label: {
                    Label("导入脚本文件（.json / .sh / .txt）", systemImage: "doc.badge.plus")
                }
                Button {
                    importScriptFolder()
                } label: {
                    Label("导入脚本包（文件夹）", systemImage: "folder.badge.plus")
                }
                Button {
                    newScriptVisible = true
                } label: {
                    Label("新建脚本", systemImage: "plus.circle")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("还没有脚本").font(.headline)
            Text("用右上角「+」导入你准备好的配方（recipe.json）或 shell 脚本，也可以先新建一个模板看看格式。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    newScriptVisible = true
                } label: {
                    Label("新建脚本", systemImage: "plus.circle")
                }
                Button {
                    importScriptFiles()
                } label: {
                    Label("导入脚本文件", systemImage: "doc.badge.plus")
                }
                Button {
                    importScriptFolder()
                } label: {
                    Label("导入脚本包（文件夹）", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    // MARK: - 导入

    /// 导入中转目录：选择器给的是沙盒外 URL（asCopy 已被 UIKit 禁止，见 DSPickers.h 文件头），
    /// 先让 DSPickers 拷进这里，再交给 ScriptLibrary，避免安全作用域过期后读不到内容。
    private var importInboxDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        let path = (docs as NSString).appendingPathComponent("ImportInbox")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func importScriptFiles() {
        DSPickers.presentOpenPickerCopying(into: URL(fileURLWithPath: importInboxDirectory),
                                            utis: ["public.json", "public.shell-script", "public.plain-text"],
                                        multiple: true,
                                      completion: { copied, error in
            var failures: [String] = []
            if let error = error { failures.append("导入：\(error.localizedDescription)") }
            for url in copied {
                do {
                    _ = try ScriptLibrary.shared.importFile(at: url, kind: nil)
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                importError = failures.joined(separator: "\n")
            }
        },
                                          cancel: nil)
    }

    private func importScriptFolder() {
        DSPickers.presentFolderPickerCopying(into: URL(fileURLWithPath: importInboxDirectory),
                                          completion: { copied, error in
            if let error = error {
                importError = "导入文件夹失败：\(error.localizedDescription)"
                return
            }
            guard let copied = copied else { return }
            do {
                _ = try ScriptLibrary.shared.importFolder(at: copied)
            } catch {
                importError = error.localizedDescription
            }
        }, cancel: nil)
    }

    private var importErrorBinding: Binding<Bool> {
        return Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }
}

// MARK: - 列表行

struct ScriptRow: View {

    let script: ScriptItem
    let payloadCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: script.kind.iconName)
                .font(.title3)
                .foregroundColor(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(script.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(script.kind.label) · \(script.fileName)\(payloadCount > 0 ? " · payload \(payloadCount) 项" : "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !script.note.isEmpty {
                    Text(script.note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 新建脚本

struct NewScriptSheet: View {

    let onCreate: (String, ScriptKind) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var name: String = ""
    @State private var kind: ScriptKind = .recipe

    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("脚本名称", text: $name)
                    Picker("类型", selection: $kind) {
                        Text("配方（JSON）").tag(ScriptKind.recipe)
                        Text("Shell 脚本").tag(ScriptKind.shell)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text(kind == .recipe
                         ? "配方是声明式的步骤列表，跑之前可以预演，被覆盖的文件会自动备份、可一键回滚。"
                         : "Shell 脚本会直接交给 /bin/sh 执行。免越狱 + DarkSword 环境下沙盒可能拒绝执行进程，这时会明确报错。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("新建脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        onCreate(name, kind)
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 脚本详情

struct ScriptDetailView: View {

    let script: ScriptItem

    @ObservedObject private var library = ScriptLibrary.shared
    @ObservedObject private var kernel = KernelCenter.shared

    @Environment(\.presentationMode) private var presentationMode

    @State private var recipe: ScriptRecipe?
    @State private var recipeError: String?
    @State private var selectedApp: InstalledApp?
    @State private var showAppPicker = false
    @State private var showEditor = false
    @State private var showRunConfirm = false
    @State private var busy = false
    @State private var outcome: RunOutcome?
    @State private var shellLog: [String] = []
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Form {
                targetSection
                if script.kind == .recipe {
                    stepsSection
                    optionsSection
                } else {
                    shellSection
                }
                payloadSection
                executeSection
                if let outcome = outcome {
                    resultSection(outcome)
                }
                if !shellLog.isEmpty {
                    logSection(shellLog.joined(separator: "\n"), title: "脚本输出")
                }
                fileSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(script.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .sheet(isPresented: $showAppPicker) {
                AppsPickerView { app in
                    selectedApp = app
                    showAppPicker = false
                }
            }
            .sheet(isPresented: $showEditor) {
                ScriptEditorView(script: script)
            }
            .confirmationDialog("确认执行这个脚本？", isPresented: $showRunConfirm, titleVisibility: .visible) {
                Button("执行", role: .destructive) { startRun(dryRun: false) }
                Button("取消", role: .cancel) { }
            } message: {
                Text("会按步骤修改目标 App 的文件。被覆盖的文件会先备份到「记录」页，可以一键还原。")
            }
            .alert("出错了", isPresented: errorBinding) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .onAppear(perform: loadRecipeIfNeeded)
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 各段

    private var targetSection: some View {
        Section {
            Button {
                showAppPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "app.badge")
                        .font(.title3)
                        .foregroundColor(.blue)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedApp?.name ?? "选择目标 App")
                            .font(.subheadline)
                        Text(targetSubtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
            }

            if let resolved = resolvedTarget {
                VStack(alignment: .leading, spacing: 4) {
                    Text("包体：\(resolved.bundlePath)")
                    Text("数据：\(resolved.dataPath.isEmpty ? "—" : resolved.dataPath)")
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            }

            if !kernel.phase.isActive {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                    Text("尚未激活内核访问，沙盒外的路径写不进去").font(.caption2).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button("激活") { kernel.activate() }
                        .font(.caption)
                        .disabled(kernel.busy)
                }
            }
        } header: {
            Text("目标")
        } footer: {
            Text("配方里可以用 {app.bundle} / {app.data} / {app.bundleId} / {app.name} / {app.executable} 这些占位符，指向这里选定的 App。")
        }
    }

    private var stepsSection: some View {
        Section {
            if let recipe = recipe {
                if recipe.steps.isEmpty {
                    Text("配方里没有步骤").font(.footnote).foregroundColor(.secondary)
                } else {
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) { pair in
                        stepRow(index: pair.offset + 1, step: pair.element)
                    }
                }
            } else if let recipeError = recipeError {
                Text(recipeError).font(.footnote).foregroundColor(.red)
            } else {
                Text("读取中…").font(.footnote).foregroundColor(.secondary)
            }
        } header: {
            Text("配方步骤")
        } footer: {
            if let recipe = recipe, let note = recipe.note {
                Text(note)
            }
        }
    }

    private func stepRow(index: Int, step: ScriptRecipe.Step) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: step.op))
                .font(.title3)
                .foregroundColor(color(for: step.op))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index). \(step.op)").font(.subheadline)
                if let source = step.source {
                    Text(source).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let dest = step.dest {
                    Text("→ \(dest)").font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let mode = step.mode {
                    Text("mode \(mode)").font(.caption2).foregroundColor(.secondary)
                }
                if let owner = step.owner {
                    Text("owner \(owner)").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    private var optionsSection: some View {
        Section {
            if let recipe = recipe {
                Toggle("执行前自动备份", isOn: optionBinding(\.backup, default: true))
                Toggle("结束后关闭目标 App", isOn: optionBinding(\.killTarget, default: true))
                Toggle("出错即停", isOn: optionBinding(\.stopOnError, default: true))
                Toggle("自动修属主（内核接口）", isOn: optionBinding(\.fixOwnership, default: true))
            } else {
                Text("读取配方后才能修改选项").font(.footnote).foregroundColor(.secondary)
            }
        } header: {
            Text("选项")
        } footer: {
            Text("这些开关会写回 recipe.json。备份默认开启：被覆盖或被删除的文件都会先整份拷到「记录」页的备份里。")
        }
    }

    private var shellSection: some View {
        Section {
            Text("会以 /bin/sh 执行 \(script.fileName)，工作目录就是这个脚本目录。")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("可用环境变量：DS_TARGET_BUNDLE / DS_TARGET_DATA / DS_TARGET_BUNDLE_ID / DS_TARGET_EXEC / DS_SCRIPT_DIR")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
        } header: {
            Text("Shell")
        } footer: {
            Text("免越狱 + DarkSword 环境下沙盒可能仍拒绝执行进程（posix_spawn 返回 EPERM），这时请改用配方脚本。")
        }
    }

    private var payloadSection: some View {
        Section {
            let files = library.payloadFiles(for: script)
            if files.isEmpty {
                Text("payload 目录还是空的").font(.footnote).foregroundColor(.secondary)
            } else {
                ForEach(files) { file in
                    HStack(spacing: 12) {
                        Image(systemName: file.iconName)
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                            Text(file.sizeString).font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button {
                            library.removePayloadFile(at: file.path, from: script)
                        } label: {
                            Image(systemName: "trash").foregroundColor(.red)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            Button {
                addPayload()
            } label: {
                Label("添加 payload 文件", systemImage: "tray.and.arrow.down")
            }
        } header: {
            Text("payload")
        } footer: {
            Text("配方里的 source 写相对路径时（例如 payload/config.json）就是从这里取文件。")
        }
    }

    private var executeSection: some View {
        Section {
            if script.kind == .recipe {
                Button {
                    startRun(dryRun: true)
                } label: {
                    HStack {
                        Spacer()
                        if busy {
                            ProgressView()
                            Text("处理中…").fontWeight(.semibold)
                        } else {
                            Image(systemName: "eye")
                            Text("预演（不改任何文件）").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(busy || recipe == nil)

                Button {
                    showRunConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "play.fill")
                        Text("执行替换").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(busy || recipe == nil)
            } else {
                Button {
                    startShellRun()
                } label: {
                    HStack {
                        Spacer()
                        if busy {
                            ProgressView()
                            Text("执行中…").fontWeight(.semibold)
                        } else {
                            Image(systemName: "play.fill")
                            Text("运行脚本").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(busy)
            }
        } header: {
            Text("执行")
        } footer: {
            Text("建议先预演一遍：预演只做检查，不会修改任何文件。")
        }
    }

    private func resultSection(_ outcome: RunOutcome) -> some View {
        Section {
            ForEach(outcome.outcomes) { step in
                HStack(spacing: 12) {
                    Image(systemName: statusIcon(step.status))
                        .font(.title3)
                        .foregroundColor(statusColor(step.status))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(step.index). \(step.op) · \(step.status.label)").font(.subheadline)
                        Text(step.summary)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if !step.message.isEmpty {
                            Text(step.message).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }
            if let backupId = outcome.backupId {
                Text("备份：\(backupId)（到「记录」页可以一键回滚）")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text(outcome.success ? "结果 · \(outcome.summary)" : "结果 · 有失败")
        }
    }

    private func logSection(_ text: String, title: String) -> some View {
        Section(title) {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 180, maxHeight: 260)
        }
    }

    private var fileSection: some View {
        Section("脚本文件") {
            Button {
                showEditor = true
            } label: {
                Label("编辑脚本内容", systemImage: "square.and.pencil")
            }
            Button {
                DSPickers.presentShareSheet(urls: [URL(fileURLWithPath: library.directory(for: script))])
            } label: {
                Label("分享整个脚本目录", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                library.delete(script)
                presentationMode.wrappedValue.dismiss()
            } label: {
                Label("删除脚本", systemImage: "trash")
            }
        }
    }

    // MARK: - 计算属性

    private var resolvedTarget: ResolvedTarget? {
        guard let recipe = recipe else {
            if let app = selectedApp {
                return ResolvedTarget(bundleId: app.bundleId, name: app.name, bundlePath: app.bundlePath,
                                      dataPath: app.dataPath ?? "", executableName: app.executableName)
            }
            return nil
        }
        return TargetResolver.resolve(recipe: recipe, override: selectedApp)
    }

    private var targetSubtitle: String {
        if let app = selectedApp {
            return "\(app.bundleId) · v\(app.displayVersion)"
        }
        if let spec = recipe?.target {
            if let bundleId = spec.bundleId { return "配方指定：\(bundleId)" }
            if let path = spec.bundlePath { return "配方指定：\(path)" }
        }
        return "还没有选定目标"
    }

    private var errorBinding: Binding<Bool> {
        return Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    // MARK: - 逻辑

    private func loadRecipeIfNeeded() {
        guard script.kind == .recipe, recipe == nil else { return }
        do {
            recipe = try library.loadRecipe(for: script)
            recipeError = nil
        } catch {
            recipeError = "解析 recipe.json 失败：\(error.localizedDescription)"
            DSLog.shared.error("脚本 \(script.name) 解析失败：\(error.localizedDescription)", source: "脚本")
        }
    }

    private func optionBinding(_ keyPath: WritableKeyPath<ScriptRecipe.Options, Bool>, default defaultValue: Bool) -> Binding<Bool> {
        return Binding(
            get: {
                guard let recipe = recipe else { return defaultValue }
                return recipe.options?[keyPath: keyPath] ?? defaultValue
            },
            set: { newValue in
                guard var recipe = recipe else { return }
                var options = recipe.options ?? ScriptRecipe.Options()
                options[keyPath: keyPath] = newValue
                recipe.options = options
                self.recipe = recipe
                persistRecipe(recipe)
            }
        )
    }

    private func persistRecipe(_ recipe: ScriptRecipe) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(recipe),
              let text = String(data: data, encoding: .utf8) else { return }
        do {
            try library.saveContent(text, for: script)
        } catch {
            errorText = "写回 recipe.json 失败：\(error.localizedDescription)"
        }
    }

    private func addPayload() {
        // 选择器给的是沙盒外 URL（asCopy 已被 UIKit 禁止）：先拷进中转目录，再交给 ScriptLibrary
        DSPickers.presentOpenPickerCopying(into: URL(fileURLWithPath: importInboxDirectory),
                                            utis: nil,
                                        multiple: true,
                                      completion: { copied, error in
            if let error = error {
                errorText = "导入 payload 失败：\(error.localizedDescription)"
                if copied.isEmpty { return }
            }
            guard !copied.isEmpty else { return }
            do {
                _ = try library.addPayloadFiles(copied, to: script)
            } catch {
                errorText = error.localizedDescription
            }
        }, cancel: nil)
    }

    private func startRun(dryRun: Bool) {
        guard let recipe = recipe else { return }
        busy = true
        outcome = nil
        shellLog = []

        let target = TargetResolver.resolve(recipe: recipe, override: selectedApp)
        let runner = RecipeRunner(script: script, recipe: recipe, target: target)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = dryRun ? runner.dryRun() : runner.run()
            DispatchQueue.main.async {
                busy = false
                outcome = result
                let record = RunRecord(
                    id: RunStore.makeRunId(scriptName: script.name),
                    date: Date(),
                    scriptName: script.name,
                    scriptKind: script.kind.rawValue,
                    targetSummary: target?.summary ?? "未指定目标",
                    success: result.success,
                    dryRun: dryRun,
                    summary: result.summary,
                    backupId: result.backupId,
                    logPath: nil
                )
                _ = RunStore.shared.appendRun(record, log: result.log.joined(separator: "\n"))
                DSLog.shared.info("脚本 \(script.name) \(dryRun ? "预演" : "执行")：\(result.summary)", source: "脚本")
            }
        }
    }

    private func startShellRun() {
        busy = true
        shellLog = []
        outcome = nil

        let target = resolvedTarget
        let runner = ShellScriptRunner(script: script, target: target)

        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            let result = runner.run(timeout: 120) { line in
                lines.append(line)
            }
            let success = result.error == nil && result.code == 0
            let summary: String
            if let error = result.error {
                summary = error
            } else {
                summary = "退出码 \(result.code)"
            }

            DispatchQueue.main.async {
                busy = false
                shellLog = lines + (result.error != nil ? ["[错误] \(result.error ?? "")"] : [])
                let logText = shellLog.joined(separator: "\n")
                let record = RunRecord(
                    id: RunStore.makeRunId(scriptName: script.name),
                    date: Date(),
                    scriptName: script.name,
                    scriptKind: script.kind.rawValue,
                    targetSummary: target?.summary ?? "未指定目标",
                    success: success,
                    dryRun: false,
                    summary: summary,
                    backupId: nil,
                    logPath: nil
                )
                _ = RunStore.shared.appendRun(record, log: logText)
                DSLog.shared.info("Shell 脚本 \(script.name)：\(summary)", source: "脚本")
            }
        }
    }

    // MARK: - 小图标

    private func iconName(for op: String) -> String {
        switch op.lowercased() {
        case "replace": return "arrow.triangle.2.circlepath"
        case "copy": return "doc.on.doc"
        case "move": return "arrow.right"
        case "mkdir": return "folder.badge.plus"
        case "delete": return "trash"
        case "chmod": return "lock.open"
        case "chown": return "person.crop.circle"
        case "kill": return "xmark.circle"
        case "note": return "text.bubble"
        default: return "questionmark.circle"
        }
    }

    private func color(for op: String) -> Color {
        switch op.lowercased() {
        case "delete", "kill": return .red
        case "replace", "move": return .orange
        case "chmod", "chown": return .blue
        default: return .secondary
        }
    }

    private func statusIcon(_ status: StepOutcome.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        case .planned: return "circle.dashed"
        }
    }

    private func statusColor(_ status: StepOutcome.Status) -> Color {
        switch status {
        case .ok: return .green
        case .failed: return .red
        case .skipped: return .secondary
        case .planned: return .orange
        }
    }
}

// MARK: - 脚本内容编辑

struct ScriptEditorView: View {

    let script: ScriptItem

    @Environment(\.presentationMode) private var presentationMode
    @State private var text: String = ""
    @State private var savedAt: Date?
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Text(ScriptLibrary.shared.scriptPath(for: script))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)

                if let savedAt = savedAt {
                    Text("已保存 \(DSLog.timeFormatter.string(from: savedAt))")
                        .font(.caption2)
                        .foregroundColor(.green)
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle("编辑脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .alert("保存失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .onAppear {
                text = ScriptLibrary.shared.content(of: script)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        do {
            try ScriptLibrary.shared.saveContent(text, for: script)
            savedAt = Date()
            DSLog.shared.info("已保存脚本 \(script.fileName)", source: "脚本")
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 目标 App 选择

struct AppsPickerView: View {

    let onSelect: (InstalledApp) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject private var kernel = KernelCenter.shared

    @State private var apps: [InstalledApp] = []
    @State private var filter: String = ""
    @State private var loading: Bool = true
    @State private var scanNote: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.footnote)
                    TextField("搜索名称或 bundle id", text: $filter)
                        .font(.footnote)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemBackground))

                content
            }
            .navigationTitle("选择目标 App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        scan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear(perform: scan)
        }
        .navigationViewStyle(.stack)
    }

    private var filtered: [InstalledApp] {
        guard !filter.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.bundleId.localizedCaseInsensitiveContains(filter)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在扫描已安装的 App…").font(.footnote).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if apps.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
                Text("读不到已安装 App 列表").font(.headline)
                Text(scanNote ?? "通常是因为还没激活内核访问；到设置页激活后再回来。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filtered) { app in
                Button {
                    onSelect(app)
                } label: {
                    appRow(app)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .listStyle(.insetGrouped)
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            if let iconPath = app.iconPath, let image = UIImage(contentsOfFile: iconPath) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .cornerRadius(6)
            } else {
                Image(systemName: "app")
                    .font(.title3)
                    .foregroundColor(.blue)
                    .frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.subheadline).lineLimit(1)
                Text("\(app.bundleId) · v\(app.displayVersion)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(app.dataPath == nil ? "无数据容器" : "数据容器已找到")
                    .font(.caption2)
                    .foregroundColor(app.dataPath == nil ? .orange : .green)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func scan() {
        loading = true
        scanNote = nil
        let escaped = DSKernel.isEscaped()
        DispatchQueue.global(qos: .userInitiated).async {
            let list = escaped ? AppScanner.installedApps(force: true) : []
            DispatchQueue.main.async {
                apps = list
                loading = false
                if list.isEmpty {
                    scanNote = escaped
                        ? "已安装 App 目录是空的，或者系统还没有刷新缓存；可以下拉重试。"
                        : "尚未激活内核访问，无法读取 /var/containers/Bundle/Application。"
                }
            }
        }
    }
}
