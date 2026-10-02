//
//  PathItem.swift — 目录项模型
//

import Foundation
import Darwin

struct PathItem: Identifiable, Hashable {

    let path: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date?
    let mode: UInt16
    let uid: Int32
    let gid: Int32

    var id: String { path }

    var isHidden: Bool { name.hasPrefix(".") }

    var parentPath: String {
        (path as NSString).deletingLastPathComponent
    }

    // MARK: - 展示

    var sizeString: String {
        if isDirectory { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var modifiedString: String {
        guard let modified = modified else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: modified)
    }

    var modeString: String {
        let type: Character
        let raw = Int32(mode) & Int32(S_IFMT)
        switch raw {
        case Int32(S_IFDIR): type = "d"
        case Int32(S_IFLNK): type = "l"
        case Int32(S_IFCHR): type = "c"
        case Int32(S_IFBLK): type = "b"
        case Int32(S_IFSOCK): type = "s"
        default: type = "-"
        }
        let flags: [(UInt16, Character)] = [
            (UInt16(S_IRUSR), "r"), (UInt16(S_IWUSR), "w"), (UInt16(S_IXUSR), "x"),
            (UInt16(S_IRGRP), "r"), (UInt16(S_IWGRP), "w"), (UInt16(S_IXGRP), "x"),
            (UInt16(S_IROTH), "r"), (UInt16(S_IWOTH), "w"), (UInt16(S_IXOTH), "x")
        ]
        var result = String(type)
        for (bit, character) in flags {
            result.append((mode & bit) != 0 ? character : "-")
        }
        return result
    }

    var octalMode: String {
        String(format: "%03o", mode & 0o7777)
    }

    var ownerString: String {
        let owner = PathItem.userName(for: uid)
        let group = PathItem.groupName(for: gid)
        return "\(owner):\(group)"
    }

    var kindName: String {
        if isSymlink { return "符号链接" }
        if isDirectory { return "文件夹" }
        switch (name as NSString).pathExtension.lowercased() {
        case "plist": return "属性列表"
        case "json": return "JSON"
        case "txt", "md", "log", "conf", "ini", "cfg", "xml", "yml", "yaml": return "文本"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff": return "图片"
        case "mp3", "m4a", "wav", "aac", "caf": return "音频"
        case "mp4", "mov", "m4v", "avi": return "视频"
        case "zip", "ipa", "deb", "tar", "gz", "7z", "rar": return "压缩包"
        case "dylib", "so": return "动态库"
        case "sh": return "Shell 脚本"
        case "dylib.bak", "bak": return "备份"
        case "ttf", "otf", "ttc": return "字体"
        case "strings", "plist.bak": return "文本"
        default: return "文件"
        }
    }

    var iconName: String {
        if isSymlink { return "arrow.turn.down.right" }
        if isDirectory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "plist", "json", "xml", "yml", "yaml": return "curlybraces"
        case "txt", "md", "log", "conf", "ini", "cfg", "sh", "strings": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff": return "photo"
        case "mp3", "m4a", "wav", "aac", "caf": return "music.note"
        case "mp4", "mov", "m4v", "avi": return "film"
        case "zip", "ipa", "deb", "tar", "gz", "7z", "rar": return "archivebox"
        case "dylib", "so": return "shippingbox"
        case "ttf", "otf", "ttc": return "textformat"
        default:
            if name == "Info.plist" { return "info.circle" }
            return "doc"
        }
    }

    // MARK: - POSIX 名字

    private static var userNameCache: [Int32: String] = [:]
    private static var groupNameCache: [Int32: String] = [:]

    static func userName(for uid: Int32) -> String {
        if uid == 0 { return "root" }
        if uid == 501 { return "mobile" }
        if let cached = userNameCache[uid] { return cached }
        var name = "uid \(uid)"
        if let pw = getpwuid(uid), let raw = pw.pointee.pw_name {
            name = String(cString: raw)
        }
        userNameCache[uid] = name
        return name
    }

    static func groupName(for gid: Int32) -> String {
        if gid == 0 { return "wheel" }
        if gid == 501 { return "mobile" }
        if let cached = groupNameCache[gid] { return cached }
        var name = "gid \(gid)"
        if let gr = getgrgid(gid), let raw = gr.pointee.gr_name {
            name = String(cString: raw)
        }
        groupNameCache[gid] = name
        return name
    }

    // MARK: - 构造

    /// 用 lstat 直接构造，比 FileManager 逐条取属性快很多（大目录能差一个数量级）
    static func make(path: String) -> PathItem? {
        var st = Darwin.stat()
        let result = path.withCString { lstat($0, &st) }
        guard result == 0 else { return nil }

        let rawMode = Int32(st.st_mode) & Int32(S_IFMT)
        let isDirectory = rawMode == Int32(S_IFDIR)
        let isSymlink = rawMode == Int32(S_IFLNK)

        var modified: Date?
        let seconds = st.st_mtimespec.tv_sec
        if seconds > 0 {
            modified = Date(timeIntervalSince1970: TimeInterval(seconds))
        }

        return PathItem(
            path: path,
            name: (path as NSString).lastPathComponent,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: isDirectory ? 0 : Int64(st.st_size),
            modified: modified,
            mode: UInt16(st.st_mode),
            uid: Int32(st.st_uid),
            gid: Int32(st.st_gid)
        )
    }
}

enum PathSortKey: String, CaseIterable, Identifiable {
    case name
    case size
    case date
    case kind

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .date: return "修改时间"
        case .kind: return "类型"
        }
    }
}
