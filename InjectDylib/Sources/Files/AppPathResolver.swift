//
//  AppPathResolver.swift — 路径 → 属于哪个 App（包体 / 数据容器），带缓存
//
//  用途：文件页与替换页的目标目录浏览器，进到某个 App 的包体或数据容器时，
//  顶部要显示这个 App 的图标与桌面名字（而不是一串 UUID）。
//
//  识别方式（只认容器 UUID，不做全盘扫描）：
//    包体：/var/containers/Bundle/Application/<UUID>/<X>.app
//    数据：/var/mobile/Containers/Data/Application/<UUID>
//  两边的 UUID 都从 AppScanner 的 InstalledApp（bundlePath / dataPath）里提取，建成 UUID→App 的字典，
//  查一次 O(1)。AppScanner 自己有 60 秒缓存，这里跟着它的结果走。
//

import Foundation

enum AppPathKind {
    case bundle
    case data

    var title: String {
        switch self {
        case .bundle: return "包体"
        case .data: return "数据容器"
        }
    }
}

struct ResolvedAppPath {
    let app: InstalledApp
    let kind: AppPathKind
    /// 容器根目录（包体时是 .app 所在的那层 UUID 目录，数据容器时是 UUID 目录本身）
    let containerRoot: String
}

final class AppPathResolver {

    static let shared = AppPathResolver()

    private var bundleByUUID: [String: InstalledApp] = [:]
    private var dataByUUID: [String: InstalledApp] = [:]
    private var builtAt: Date?
    private var builtCount = -1
    private let lock = NSLock()

    private static let bundleRoot = "/var/containers/Bundle/Application"
    private static let dataRoot = "/var/mobile/Containers/Data/Application"

    /// 路径落在哪个 App 的包体/数据容器里；不属于任何 App 时返回 nil（调用方静默不显示横幅）
    func resolve(path: String) -> ResolvedAppPath? {
        guard !path.isEmpty else { return nil }
        let normalized = normalize(path)

        if normalized == Self.bundleRoot || normalized.hasPrefix(Self.bundleRoot + "/") {
            let rest = String(normalized.dropFirst(Self.bundleRoot.count + 1))
            guard let uuid = rest.split(separator: "/").first.map(String.init), !uuid.isEmpty else { return nil }
            rebuildIfNeeded()
            guard let app = bundleByUUID[uuid] else { return nil }
            return ResolvedAppPath(app: app, kind: .bundle, containerRoot: Self.bundleRoot + "/" + uuid)
        }

        if normalized == Self.dataRoot || normalized.hasPrefix(Self.dataRoot + "/") {
            let rest = String(normalized.dropFirst(Self.dataRoot.count + 1))
            guard let uuid = rest.split(separator: "/").first.map(String.init), !uuid.isEmpty else { return nil }
            rebuildIfNeeded()
            guard let app = dataByUUID[uuid] else { return nil }
            return ResolvedAppPath(app: app, kind: .data, containerRoot: Self.dataRoot + "/" + uuid)
        }

        return nil
    }

    func invalidate() {
        lock.lock()
        builtAt = nil
        builtCount = -1
        lock.unlock()
    }

    // MARK: - 内部

    private func rebuildIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        let apps = AppScanner.installedApps()
        if builtCount == apps.count, let builtAt = builtAt, Date().timeIntervalSince(builtAt) < 60 {
            return
        }

        var bundles: [String: InstalledApp] = [:]
        var datas: [String: InstalledApp] = [:]
        for app in apps {
            if let uuid = Self.uuidComponent(of: app.bundlePath, under: Self.bundleRoot) {
                bundles[uuid] = app
            }
            if let dataPath = app.dataPath, let uuid = Self.uuidComponent(of: dataPath, under: Self.dataRoot) {
                datas[uuid] = app
            }
        }
        bundleByUUID = bundles
        dataByUUID = datas
        builtAt = Date()
        builtCount = apps.count
    }

    private static func uuidComponent(of path: String, under root: String) -> String? {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard normalized.hasPrefix(root + "/") else { return nil }
        let rest = String(normalized.dropFirst(root.count + 1))
        guard let first = rest.split(separator: "/").first else { return nil }
        return String(first)
    }

    private func normalize(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
