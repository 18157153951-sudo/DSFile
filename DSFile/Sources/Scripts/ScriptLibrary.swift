//
//  ScriptLibrary.swift — 脚本库（存在 App 自己的 Documents 里，随时可导出）
//
//  Documents/
//    Scripts/
//      index.json                  ← 脚本清单
//      <脚本目录>/
//        recipe.json | run.sh
//        payload/                  ← 要替换进去的文件
//

import Foundation
import Combine

enum ScriptKind: String, Codable {
    case recipe
    case shell

    var label: String {
        switch self {
        case .recipe: return "配方"
        case .shell: return "Shell"
        }
    }

    var iconName: String {
        switch self {
        case .recipe: return "list.bullet.rectangle"
        case .shell: return "terminal"
        }
    }
}

struct ScriptItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: ScriptKind
    var fileName: String
    var note: String = ""
    var addedAt: Date = Date()
    var folderName: String
}

final class ScriptLibrary: ObservableObject {

    static let shared = ScriptLibrary()

    @Published private(set) var scripts: [ScriptItem] = []

    private let fileManager = FileManager.default

    // MARK: - 目录

    var rootDirectory: String {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent("Scripts")
    }

    func directory(for script: ScriptItem) -> String {
        return (rootDirectory as NSString).appendingPathComponent(script.folderName)
    }

    func scriptPath(for script: ScriptItem) -> String {
        return (directory(for: script) as NSString).appendingPathComponent(script.fileName)
    }

    func payloadDirectory(for script: ScriptItem) -> String {
        return (directory(for: script) as NSString).appendingPathComponent("payload")
    }

    private var indexURL: URL {
        return URL(fileURLWithPath: (rootDirectory as NSString).appendingPathComponent("index.json"))
    }

    // MARK: - 载入 / 保存

    init() {
        createRootIfNeeded()
        load()
    }

    private func createRootIfNeeded() {
        if !fileManager.fileExists(atPath: rootDirectory) {
            try? fileManager.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
        }
    }

    func load() {
        createRootIfNeeded()
        guard let data = fileManager.contents(atPath: indexURL.path),
              let items = try? JSONDecoder().decode([ScriptItem].self, from: data) else {
            scripts = []
            return
        }
        scripts = items.sorted { $0.addedAt > $1.addedAt }
    }

    private func save() {
        createRootIfNeeded()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(scripts) {
            try? data.write(to: indexURL)
        }
    }

    // MARK: - 增删

    @discardableResult
    func createScript(name: String, kind: ScriptKind, note: String = "") -> ScriptItem? {
        createRootIfNeeded()
        let folderName = uniqueFolderName(for: name)
        let item = ScriptItem(
            name: name.isEmpty ? "未命名脚本" : name,
            kind: kind,
            fileName: kind == .recipe ? "recipe.json" : "run.sh",
            note: note,
            folderName: folderName
        )

        let dir = directory(for: item)
        try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(atPath: payloadDirectory(for: item), withIntermediateDirectories: true)

        let content = kind == .recipe ? ScriptRecipe.template : ScriptLibrary.shellTemplate
        try? content.write(toFile: scriptPath(for: item), atomically: true, encoding: .utf8)

        scripts.insert(item, at: 0)
        save()
        DSLog.shared.info("新建脚本 \(item.name)（\(kind.label)）", source: "脚本")
        return item
    }

    func delete(_ script: ScriptItem) {
        try? fileManager.removeItem(atPath: directory(for: script))
        scripts.removeAll { $0.id == script.id }
        save()
        DSLog.shared.info("删除脚本 \(script.name)", source: "脚本")
    }

    func rename(_ script: ScriptItem, to newName: String) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[index].name = newName
        save()
    }

    func updateNote(_ script: ScriptItem, note: String) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[index].note = note
        save()
    }

    // MARK: - 读取 / 写入脚本内容

    func content(of script: ScriptItem) -> String {
        return (try? String(contentsOfFile: scriptPath(for: script), encoding: .utf8)) ?? ""
    }

    func saveContent(_ text: String, for script: ScriptItem) throws {
        try text.write(toFile: scriptPath(for: script), atomically: true, encoding: .utf8)
    }

    func loadRecipe(for script: ScriptItem) throws -> ScriptRecipe {
        let data = try Data(contentsOf: URL(fileURLWithPath: scriptPath(for: script)))
        return try ScriptRecipe.decode(from: data)
    }

    // MARK: - 导入

    /// 导入一个文件（.json/.sh/.txt）为脚本
    @discardableResult
    func importFile(at url: URL, kind: ScriptKind?) throws -> ScriptItem {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let baseName = url.deletingPathExtension().lastPathComponent
        let detectedKind = kind ?? ScriptLibrary.detectKind(fileName: url.lastPathComponent, data: data)

        guard let item = createScript(name: baseName, kind: detectedKind) else {
            throw FileSystemError.failed("无法创建脚本")
        }

        var target = scriptPath(for: item)
        // 扩展名和默认文件名不一致时，改存成同名文件
        let desiredName = url.lastPathComponent
        if detectedKind == .recipe && desiredName.lowercased().hasSuffix(".json") {
            let newPath = (directory(for: item) as NSString).appendingPathComponent(desiredName)
            try data.write(to: URL(fileURLWithPath: newPath))
            try? fileManager.removeItem(atPath: target)
            target = newPath
            updateFileName(item, fileName: desiredName)
        } else if detectedKind == .shell {
            try data.write(to: URL(fileURLWithPath: target))
        } else {
            try data.write(to: URL(fileURLWithPath: target))
        }

        // 同名 payload 目录：如果导入的是文件夹里的文件，调用方会用 importFolder
        DSLog.shared.info("导入脚本 \(item.name) ← \(url.lastPathComponent)，\(data.count) 字节", source: "脚本")
        return scripts.first { $0.id == item.id } ?? item
    }

    /// 导入一个脚本包目录（内含 recipe.json / run.sh + payload/）
    @discardableResult
    func importFolder(at url: URL) throws -> ScriptItem {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let names = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
        var kind: ScriptKind = .recipe
        var mainFile: String? = nil

        if names.contains("recipe.json") {
            kind = .recipe
            mainFile = "recipe.json"
        } else if let shell = names.first(where: { $0.hasSuffix(".sh") }) {
            kind = .shell
            mainFile = shell
        } else if let json = names.first(where: { $0.hasSuffix(".json") }) {
            kind = .recipe
            mainFile = json
        }

        guard let main = mainFile else {
            throw FileSystemError.failed("这个文件夹里既没有 recipe.json，也没有 .sh 脚本")
        }

        guard let item = createScript(name: url.lastPathComponent, kind: kind) else {
            throw FileSystemError.failed("无法创建脚本")
        }
        let destination = directory(for: item)
        try fileManager.removeItem(atPath: destination)
        try FileOperations.copyDirectoryContents(from: url, to: URL(fileURLWithPath: destination))

        updateFileName(item, fileName: main)
        if !fileManager.fileExists(atPath: payloadDirectory(for: item)) {
            try? fileManager.createDirectory(atPath: payloadDirectory(for: item), withIntermediateDirectories: true)
        }

        DSLog.shared.info("导入脚本包 \(item.name)（\(main)）", source: "脚本")
        return scripts.first { $0.id == item.id } ?? item
    }

    /// 往脚本的 payload 目录里放文件
    func addPayloadFiles(_ urls: [URL], to script: ScriptItem) throws -> [String] {
        var added: [String] = []
        let payload = payloadDirectory(for: script)
        try? fileManager.createDirectory(atPath: payload, withIntermediateDirectories: true)

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            var destination = (payload as NSString).appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destination) {
                destination = FileOperations.uniquePath(for: destination)
            }
            if FileSystemService.isDirectory(url.path) {
                try FileOperations.copyDirectoryContents(from: url, to: URL(fileURLWithPath: destination))
            } else {
                try fileManager.copyItem(at: url, to: URL(fileURLWithPath: destination))
            }
            added.append((destination as NSString).lastPathComponent)
        }

        DSLog.shared.info("脚本 \(script.name) 的 payload 新增 \(added.count) 项", source: "脚本")
        return added
    }

    func payloadFiles(for script: ScriptItem) -> [PathItem] {
        let payload = payloadDirectory(for: script)
        return (try? FileSystemService.list(path: payload, showHidden: false, sortKey: .name, ascending: true)) ?? []
    }

    func removePayloadFile(at path: String, from script: ScriptItem) {
        try? fileManager.removeItem(atPath: path)
    }

    private func updateFileName(_ script: ScriptItem, fileName: String) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[index].fileName = fileName
        save()
    }

    // MARK: - 工具

    private func uniqueFolderName(for name: String) -> String {
        let slug = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let base = slug.isEmpty ? "script" : slug
        var candidate = base
        var index = 1
        while fileManager.fileExists(atPath: (rootDirectory as NSString).appendingPathComponent(candidate)) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    static func detectKind(fileName: String, data: Data) -> ScriptKind {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".sh") { return .shell }
        if lower.hasSuffix(".json") { return .recipe }
        if let text = String(data: data.prefix(200), encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return .recipe
        }
        return .shell
    }

    static let shellTemplate = """
    #!/bin/sh
    # myfilza Shell 脚本
    # 运行时可用环境变量：
    #   DS_TARGET_BUNDLE     目标 App 包体路径
    #   DS_TARGET_DATA       目标 App 数据容器路径
    #   DS_TARGET_BUNDLE_ID  目标 App bundle id
    #   DS_TARGET_EXEC       目标可执行文件路径
    #   DS_SCRIPT_DIR        本脚本所在目录
    #
    # 注意：免越狱 + DarkSword 环境下沙盒可能仍拒绝执行进程，
    # 这时 posix_spawn 会直接失败 —— 请改用配方脚本。

    set -e
    echo "目标: $DS_TARGET_BUNDLE_ID"
    echo "包体: $DS_TARGET_BUNDLE"
    echo "数据: $DS_TARGET_DATA"
    echo "脚本目录: $DS_SCRIPT_DIR"

    # 示例：把 payload 里的文件拷过去
    # cp -f "$DS_SCRIPT_DIR/payload/config.json" "$DS_TARGET_DATA/Documents/config.json"
    """
}
