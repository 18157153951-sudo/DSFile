//
//  RunStore.swift — 备份与运行历史（可回滚）
//
//  Documents/
//    Backups/<时间戳-脚本名>/
//      manifest.json
//      files/<序号>-<文件名>            ← 覆盖/删除前的原件
//    Runs/<时间戳-脚本名>.json + .log   ← 运行历史
//

import Foundation
import Combine

struct BackupEntry: Codable, Identifiable {

    var id: String { originalPath }

    var originalPath: String
    /// 相对 manifest 所在目录的路径
    var relativePath: String
    /// 覆盖前原本是否存在（false 表示这是脚本新建的文件，回滚时要删掉）
    var existed: Bool
    var mode: String?
    var uid: Int32?
    var gid: Int32?
    var size: Int64
}

struct BackupRecord: Codable, Identifiable {
    var id: String
    var createdAt: Date
    var scriptName: String
    var targetSummary: String
    var directoryPath: String
    var entries: [BackupEntry]
    var restoredAt: Date?

    var sizeString: String {
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

struct RunRecord: Codable, Identifiable {
    var id: String
    var date: Date
    var scriptName: String
    var scriptKind: String
    var targetSummary: String
    var success: Bool
    var dryRun: Bool
    var summary: String
    var backupId: String?
    var logPath: String?
}

/// 一次备份会话：逐个登记要动的文件，最后 commit
final class BackupSession {

    let id: String
    let directory: String
    let scriptName: String
    let targetSummary: String

    private(set) var entries: [BackupEntry] = []
    private let filesDirectory: String
    private var index = 0

    init(id: String, directory: String, scriptName: String, targetSummary: String) {
        self.id = id
        self.directory = directory
        self.scriptName = scriptName
        self.targetSummary = targetSummary
        self.filesDirectory = (directory as NSString).appendingPathComponent("files")
        try? FileManager.default.createDirectory(atPath: filesDirectory, withIntermediateDirectories: true)
    }

    /// 登记一个即将被覆盖/删除的路径（存在则拷贝原件，不存在则记 existed=false）
    @discardableResult
    func capture(_ path: String, recursive: Bool = true) -> BackupEntry? {
        guard !path.isEmpty, path.hasPrefix("/") else { return nil }
        if entries.contains(where: { $0.originalPath == path }) { return nil }

        guard let item = PathItem.make(path: path) else {
            let entry = BackupEntry(originalPath: path, relativePath: "", existed: false,
                                    mode: nil, uid: nil, gid: nil, size: 0)
            entries.append(entry)
            return entry
        }

        index += 1
        let name = "\(String(format: "%03d", index))-\((path as NSString).lastPathComponent)"
        let relative = "files/" + name
        let destination = (directory as NSString).appendingPathComponent(relative)

        do {
            if item.isDirectory && !item.isSymlink {
                if recursive {
                    try FileManager.default.copyItem(atPath: path, toPath: destination)
                } else {
                    try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                }
            } else {
                try FileManager.default.copyItem(atPath: path, toPath: destination)
            }
        } catch {
            // 拷不动就退化成「记录存在但没内容」，回滚会提示用户
            DSLog.shared.warn("备份 \(path) 失败：\(error.localizedDescription)", source: "备份")
            let entry = BackupEntry(originalPath: path, relativePath: "", existed: item.isDirectory ? false : true,
                                    mode: item.octalMode, uid: item.uid, gid: item.gid, size: item.size)
            entries.append(entry)
            return entry
        }

        let entry = BackupEntry(originalPath: path, relativePath: relative, existed: true,
                                mode: item.octalMode, uid: item.uid, gid: item.gid, size: item.size)
        entries.append(entry)
        return entry
    }

    func commit(restoredAt: Date? = nil) -> BackupRecord {
        let record = BackupRecord(id: id, createdAt: Date(), scriptName: scriptName,
                                  targetSummary: targetSummary, directoryPath: directory,
                                  entries: entries, restoredAt: restoredAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            try? data.write(to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent("manifest.json")))
        }
        return record
    }
}

final class RunStore: ObservableObject {

    static let shared = RunStore()

    @Published private(set) var backups: [BackupRecord] = []
    @Published private(set) var runs: [RunRecord] = []

    private let fileManager = FileManager.default

    private var documentsPath: String {
        return fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
    }

    var backupsRoot: String { (documentsPath as NSString).appendingPathComponent("Backups") }
    var runsRoot: String { (documentsPath as NSString).appendingPathComponent("Runs") }

    private init() {
        try? fileManager.createDirectory(atPath: backupsRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(atPath: runsRoot, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - 读取

    func reload() {
        var loadedBackups: [BackupRecord] = []
        if let folders = try? fileManager.contentsOfDirectory(atPath: backupsRoot) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for folder in folders {
                let manifest = (backupsRoot as NSString).appendingPathComponent(folder + "/manifest.json")
                guard let data = fileManager.contents(atPath: manifest),
                      let record = try? decoder.decode(BackupRecord.self, from: data) else { continue }
                loadedBackups.append(record)
            }
        }
        backups = loadedBackups.sorted { $0.createdAt > $1.createdAt }

        var loadedRuns: [RunRecord] = []
        if let files = try? fileManager.contentsOfDirectory(atPath: runsRoot) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for file in files where file.hasSuffix(".json") {
                let path = (runsRoot as NSString).appendingPathComponent(file)
                guard let data = fileManager.contents(atPath: path),
                      let record = try? decoder.decode(RunRecord.self, from: data) else { continue }
                loadedRuns.append(record)
            }
        }
        runs = loadedRuns.sorted { $0.date > $1.date }
    }

    // MARK: - 备份

    func beginBackup(scriptName: String, targetSummary: String) -> BackupSession {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeName = scriptName.replacingOccurrences(of: "/", with: "-")
        let id = "\(formatter.string(from: Date()))-\(safeName)"
        let directory = (backupsRoot as NSString).appendingPathComponent(id)
        try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return BackupSession(id: id, directory: directory, scriptName: scriptName, targetSummary: targetSummary)
    }

    func add(_ record: BackupRecord) {
        // 脚本执行在后台队列，@Published 的更新统一回主线程
        DispatchQueue.main.async {
            self.backups.insert(record, at: 0)
        }
    }

    func deleteBackup(_ record: BackupRecord) {
        try? fileManager.removeItem(atPath: record.directoryPath)
        backups.removeAll { $0.id == record.id }
        DSLog.shared.info("删除备份 \(record.id)", source: "备份")
    }

    /// 回滚：把原件放回去，脚本新建的文件删掉
    @discardableResult
    func restore(_ record: BackupRecord) throws -> Int {
        var restored = 0
        var failures: [String] = []

        for entry in record.entries {
            if entry.existed && !entry.relativePath.isEmpty {
                let source = (record.directoryPath as NSString).appendingPathComponent(entry.relativePath)
                guard fileManager.fileExists(atPath: source) else {
                    failures.append("备份文件缺失：\(entry.originalPath)")
                    continue
                }
                let parent = (entry.originalPath as NSString).deletingLastPathComponent
                _ = FileOperations.makeWritable(parent)
                do {
                    if fileManager.fileExists(atPath: entry.originalPath) {
                        try fileManager.removeItem(atPath: entry.originalPath)
                    }
                    try fileManager.copyItem(atPath: source, toPath: entry.originalPath)
                    if let mode = entry.mode, let value = UInt16(mode, radix: 8) {
                        _ = DSKernel.setMode(path: entry.originalPath, mode: mode_t(value))
                    }
                    if let uid = entry.uid, let gid = entry.gid {
                        _ = DSKernel.setOwner(path: entry.originalPath, uid: uid, gid: gid, recursive: false)
                    }
                    restored += 1
                } catch {
                    failures.append("\(entry.originalPath)：\(error.localizedDescription)")
                }
            } else if fileManager.fileExists(atPath: entry.originalPath) {
                // 覆盖前不存在 → 这是脚本新建的文件，回滚时移除
                _ = FileOperations.makeWritable((entry.originalPath as NSString).deletingLastPathComponent)
                try? fileManager.removeItem(atPath: entry.originalPath)
                restored += 1
            }
        }

        if !failures.isEmpty {
            throw FileSystemError.failed("部分文件回滚失败：\n" + failures.joined(separator: "\n"))
        }

        var updated = record
        updated.restoredAt = Date()
        // 回滚可能是在后台队列里跑的，@Published 的更新统一回主线程
        DispatchQueue.main.async {
            if let index = self.backups.firstIndex(where: { $0.id == record.id }) {
                self.backups[index] = updated
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(updated) {
            try? data.write(to: URL(fileURLWithPath: (record.directoryPath as NSString).appendingPathComponent("manifest.json")))
        }

        DSLog.shared.info("回滚完成，恢复 \(restored) 项（备份 \(record.id)）", source: "备份")
        return restored
    }

    // MARK: - 运行历史

    @discardableResult
    func appendRun(_ record: RunRecord, log: String) -> RunRecord {
        let jsonPath = (runsRoot as NSString).appendingPathComponent("\(record.id).json")
        let logPath = (runsRoot as NSString).appendingPathComponent("\(record.id).log")
        try? log.write(toFile: logPath, atomically: true, encoding: .utf8)

        var stored = record
        stored.logPath = logPath

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(stored) {
            try? data.write(to: URL(fileURLWithPath: jsonPath))
        }
        DispatchQueue.main.async {
            self.runs.insert(stored, at: 0)
        }
        return stored
    }

    func deleteRun(_ record: RunRecord) {
        let jsonPath = (runsRoot as NSString).appendingPathComponent("\(record.id).json")
        let logPath = (runsRoot as NSString).appendingPathComponent("\(record.id).log")
        try? fileManager.removeItem(atPath: jsonPath)
        try? fileManager.removeItem(atPath: logPath)
        runs.removeAll { $0.id == record.id }
    }

    func logText(for record: RunRecord) -> String {
        guard let path = record.logPath else { return "" }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// 生成一个基于时间的记录 id
    static func makeRunId(scriptName: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(scriptName.replacingOccurrences(of: "/", with: "-"))"
    }
}
