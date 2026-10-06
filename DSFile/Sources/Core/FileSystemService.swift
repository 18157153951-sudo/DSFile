//
//  FileSystemService.swift — 目录列举 / 属性读取（全部走 POSIX，逃逸后可直接读系统路径）
//

import Foundation
import Darwin

enum FileSystemError: LocalizedError {
    case listingFailed(String, Int32)
    case notFound(String)
    case denied(String)
    case invalidName
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .listingFailed(let path, let code):
            // 没权限时把话说清：App 列表能列出来（走系统接口），但容器内容要激活后才能读。
            if code == EACCES || code == EPERM {
                if !EnvironmentProbe.hasFileSystemAccess() {
                    return "无法读取 \(path)（errno \(code)）：需要先激活访问才能读取容器内容 —— "
                         + "去「设置」页激活，或换成可用的访问路径。"
                         + "当前环境：\(EnvironmentProbe.accessDeniedDiagnosis())"
                }
                return "无法读取 \(path)（errno \(code): \(String(cString: strerror(code))))："
                     + "已激活但仍被拒绝，说明该路径不在本次取得的权限范围内"
            }
            return "无法读取 \(path)（errno \(code): \(String(cString: strerror(code))))"
        case .notFound(let path):
            return "路径不存在：\(path)"
        case .denied(let path):
            return "权限不足：\(path)（需要先激活访问）"
        case .invalidName:
            return "名称不合法"
        case .failed(let message):
            return message
        }
    }
}

enum FileSystemService {

    // MARK: - 列举

    static func list(path: String, showHidden: Bool, sortKey: PathSortKey, ascending: Bool) throws -> [PathItem] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw FileSystemError.notFound(path)
        }

        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            let code = (error as NSError).code
            if code == Int(ENOENT) { throw FileSystemError.notFound(path) }
            throw FileSystemError.listingFailed(path, Int32(code))
        }

        var items: [PathItem] = []
        items.reserveCapacity(names.count)
        for name in names {
            if !showHidden && name.hasPrefix(".") { continue }
            let full = join(path, name)
            if let item = PathItem.make(path: full) {
                items.append(item)
            }
        }
        return sort(items, key: sortKey, ascending: ascending)
    }

    static func sort(_ items: [PathItem], key: PathSortKey, ascending: Bool) -> [PathItem] {
        let sorted = items.sorted { lhs, rhs in
            // 文件夹永远排在前面
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch key {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                return lhs.size < rhs.size
            case .date:
                return (lhs.modified ?? .distantPast) < (rhs.modified ?? .distantPast)
            case .kind:
                let l = (lhs.name as NSString).pathExtension.lowercased()
                let r = (rhs.name as NSString).pathExtension.lowercased()
                if l == r { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return l < r
            }
        }
        return ascending ? sorted : sorted.reversed()
    }

    static func item(at path: String) -> PathItem? {
        return PathItem.make(path: path)
    }

    static func exists(_ path: String) -> Bool {
        return FileManager.default.fileExists(atPath: path)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return ok && isDir.boolValue
    }

    static func join(_ base: String, _ name: String) -> String {
        if base == "/" { return "/" + name }
        return (base as NSString).appendingPathComponent(name)
    }

    static func parent(of path: String) -> String? {
        if path == "/" || path.isEmpty { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func components(of path: String) -> [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        guard path != "/" else { return result }
        var accumulating = ""
        for part in path.split(separator: "/") {
            accumulating += "/" + part
            result.append((String(part), accumulating))
        }
        return result
    }

    // MARK: - 大小 / 统计

    /// 目录递归统计（有深度上限，避免在 / 上卡死）
    static func aggregateSize(of path: String, maxDepth: Int = 6) -> Int64 {
        let item = PathItem.make(path: path)
        if item?.isDirectory != true { return item?.size ?? 0 }

        var total: Int64 = 0
        var depth = 0
        var stack: [(String, Int)] = [(path, 0)]
        while let (current, currentDepth) = stack.popLast() {
            depth = max(depth, currentDepth)
            guard currentDepth <= maxDepth else { continue }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current) else { continue }
            for name in names {
                let child = join(current, name)
                guard let childItem = PathItem.make(path: child) else { continue }
                if childItem.isDirectory && !childItem.isSymlink {
                    stack.append((child, currentDepth + 1))
                } else {
                    total += childItem.size
                }
            }
        }
        return total
    }

    // MARK: - 磁盘空间

    static func volumeInfo(for path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path) else { return nil }
        let total = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let used = max(0, total - free)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let percent = total > 0 ? Int((Double(used) / Double(total)) * 100) : 0
        return "已用 \(formatter.string(fromByteCount: used)) / \(formatter.string(fromByteCount: total))（\(percent)%）"
    }
}
