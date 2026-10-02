//
//  FileOperations.swift — 文件操作（权限被拒时自动用内核接口把 owner 改成 mobile 再重试）
//

import Foundation
import Darwin

enum FileOperations {

    // MARK: - 权限自愈

    /// 用内核接口把路径的 on-disk owner 改成 mobile:mobile（绕过 DAC，root 的文件也能改）
    @discardableResult
    static func makeWritable(_ path: String, recursive: Bool = false) -> Bool {
        guard DSKernel.isExploitDone() else { return false }
        let owned = DSKernel.setOwner(path: path, uid: 501, gid: 501, recursive: recursive)
        if owned {
            DSLog.shared.info("已把 \(path) 的属主改为 mobile:mobile", source: "权限")
        }
        return owned
    }

    /// 先试一次，被拒就把目标与父目录的属主改成 mobile 再试一次
    private static func withPermissionRetry(_ paths: [String], _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            var fixedAny = false
            for path in paths {
                let parent = (path as NSString).deletingLastPathComponent
                if FileSystemService.exists(path) {
                    fixedAny = makeWritable(path) || fixedAny
                }
                if !parent.isEmpty && FileSystemService.exists(parent) {
                    fixedAny = makeWritable(parent) || fixedAny
                }
            }
            guard fixedAny else { throw error }
            try body()
        }
    }

    /// 目标 App 内部的文件经常是 root 拥有的，写之前先把它的目录树放开
    @discardableResult
    static func prepareContainerForWrite(_ directory: String) -> Bool {
        guard DSKernel.isExploitDone() else { return false }
        return DSKernel.setOwner(path: directory, uid: 501, gid: 501, recursive: true)
    }

    // MARK: - 增删改

    static func createFolder(in parent: String, name: String) throws -> String {
        let clean = try sanitize(name)
        let target = FileSystemService.join(parent, clean)
        try withPermissionRetry([parent]) {
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
        }
        return target
    }

    static func createFile(in parent: String, name: String) throws -> String {
        let clean = try sanitize(name)
        let target = FileSystemService.join(parent, clean)
        try withPermissionRetry([parent]) {
            guard FileManager.default.createFile(atPath: target, contents: Data()) else {
                throw FileSystemError.failed("创建文件失败：\(target)")
            }
        }
        return target
    }

    static func delete(_ path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try withPermissionRetry([path, parent]) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    static func copy(_ source: String, to destination: String) throws {
        let parent = (destination as NSString).deletingLastPathComponent
        try withPermissionRetry([source, destination, parent]) {
            if FileSystemService.exists(destination) {
                try FileManager.default.removeItem(atPath: destination)
            }
            try FileManager.default.copyItem(atPath: source, toPath: destination)
        }
    }

    static func move(_ source: String, to destination: String) throws {
        let sourceParent = (source as NSString).deletingLastPathComponent
        let destParent = (destination as NSString).deletingLastPathComponent
        try withPermissionRetry([source, destination, sourceParent, destParent]) {
            if FileSystemService.exists(destination) {
                try FileManager.default.removeItem(atPath: destination)
            }
            try FileManager.default.moveItem(atPath: source, toPath: destination)
        }
    }

    @discardableResult
    static func rename(_ path: String, to newName: String) throws -> String {
        let clean = try sanitize(newName)
        let parent = (path as NSString).deletingLastPathComponent
        let target = FileSystemService.join(parent, clean)
        try move(path, to: target)
        return target
    }

    @discardableResult
    static func duplicate(_ path: String) throws -> String {
        let target = uniquePath(for: path)
        try copy(path, to: target)
        return target
    }

    static func copyIntoDirectory(_ source: String, directory: String) throws -> String {
        let name = (source as NSString).lastPathComponent
        var target = FileSystemService.join(directory, name)
        if FileSystemService.exists(target) {
            target = uniquePath(for: target)
        }
        try copy(source, to: target)
        return target
    }

    /// 生成一个不冲突的目标路径：a.txt → a-1.txt → a-2.txt
    static func uniquePath(for path: String) -> String {
        guard FileSystemService.exists(path) else { return path }
        let ext = (path as NSString).pathExtension
        let base = (path as NSString).deletingPathExtension
        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            if !FileSystemService.exists(candidate) { return candidate }
            index += 1
            if index > 9999 { return "\(base)-\(UUID().uuidString.prefix(4))" }
        }
    }

    private static func sanitize(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            throw FileSystemError.invalidName
        }
        return trimmed
    }

    // MARK: - 权限 / 属主

    static func chmod(_ path: String, octal: String) throws {
        let cleaned = octal.replacingOccurrences(of: "0o", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = UInt16(cleaned, radix: 8) else {
            throw FileSystemError.failed("模式必须是八进制，例如 0644")
        }
        // 先走内核接口（root 文件需要），失败再退回 chmod(2)
        if DSKernel.setMode(path: path, mode: mode_t(value)) { return }
        if chmod(path, mode_t(value)) == 0 { return }
        throw FileSystemError.denied(path)
    }

    /// owner 支持 "mobile"、"mobile:mobile"、"501:501"
    static func chown(_ path: String, owner: String, recursive: Bool) throws {
        let parts = owner.split(separator: ":").map(String.init)
        let userPart = parts.first ?? "mobile"
        let groupPart = parts.count > 1 ? parts[1] : parts.first ?? "mobile"

        let uid = try resolveUID(userPart)
        let gid = try resolveGID(groupPart)

        if recursive {
            let ok = DSKernel.setOwner(path: path, uid: uid, gid: gid, recursive: true)
            if !ok { throw FileSystemError.failed("递归改属主失败（可能尚未激活内核访问）") }
            return
        }

        var changed = DSKernel.setOwner(path: path, uid: uid, gid: gid, recursive: false)
        if !changed {
            changed = (chown(path, uid, gid) == 0)
        }
        if !changed { throw FileSystemError.denied(path) }
    }

    private static func resolveUID(_ text: String) throws -> uid_t {
        if let value = Int32(text) { return uid_t(value) }
        if let pw = getpwnam(text) { return pw.pointee.pw_uid }
        throw FileSystemError.failed("找不到用户：\(text)")
    }

    private static func resolveGID(_ text: String) throws -> gid_t {
        if let value = Int32(text) { return gid_t(value) }
        if let gr = getgrnam(text) { return gr.pointee.gr_gid }
        throw FileSystemError.failed("找不到用户组：\(text)")
    }

    // MARK: - 文本读写

    static func readText(_ path: String, maxBytes: Int = 4 * 1024 * 1024) throws -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            throw FileSystemError.notFound(path)
        }
        guard size.intValue <= maxBytes else {
            throw FileSystemError.failed("文件太大（\(ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file))），请用十六进制查看")
        }

        if let text = try? String(contentsOfFile: path, encoding: .utf8) { return text }
        if let text = try? String(contentsOfFile: path, encoding: .isoLatin1) { return text }

        // 再不行就当二进制，做可打印字符替换，至少让用户看到结构
        guard let data = FileManager.default.contents(atPath: path) else {
            throw FileSystemError.denied(path)
        }
        return data.map { byte -> String in
            (byte >= 32 && byte < 127) ? String(UnicodeScalar(byte)) : "·"
        }.joined()
    }

    /// 写文本；makeBackup 时先在旁边留一份 .dsfbak
    static func writeText(_ text: String, to path: String, makeBackup: Bool = true) throws {
        if makeBackup && FileSystemService.exists(path) {
            let backup = path + ".dsfbak"
            if !FileSystemService.exists(backup) {
                try? copy(path, to: backup)
            }
        }
        let parent = (path as NSString).deletingLastPathComponent
        try withPermissionRetry([path, parent]) {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 二进制读取（十六进制查看器用）

    static func readBytes(_ path: String, offset: Int64, length: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return handle.readData(ofLength: length)
        } catch {
            return nil
        }
    }

    static func fileSize(_ path: String) -> Int64 {
        return PathItem.make(path: path)?.size ?? 0
    }

    // MARK: - 递归拷贝目录（导入脚本包用）

    static func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw FileSystemError.failed("无法遍历 \(source.path)")
        }
        for case let entry as URL in enumerator {
            let relative = entry.path.replacingOccurrences(of: source.path, with: "")
            let target = URL(fileURLWithPath: destination.path + relative)
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: entry, to: target)
            }
        }
    }
}
