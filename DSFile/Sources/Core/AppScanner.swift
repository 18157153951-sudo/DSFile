//
//  AppScanner.swift — 已安装 App 枚举（给「替换目标文件」选目标用）
//
//  路径来源（逃逸后可直接读）：
//    包体：/var/containers/Bundle/Application/<UUID>/<Name>.app
//    数据：/var/mobile/Containers/Data/Application/<UUID>/
//         （靠 .com.apple.mobile_container_manager.metadata.plist 里的 MCMMetadataIdentifier 对应 bundle id）
//

import Foundation

struct InstalledApp: Identifiable, Hashable {

    let bundleId: String
    let name: String
    let version: String
    let bundlePath: String
    let executableName: String
    let dataPath: String?
    let iconPath: String?

    var id: String { bundleId }
    var executablePath: String { bundlePath + "/" + executableName }

    var displayVersion: String { version.isEmpty ? "—" : version }

    var shortBundlePath: String {
        bundlePath.replacingOccurrences(of: "/var/containers/Bundle/Application/", with: "…/")
    }
}

enum AppScanner {

    static let bundleRoot = "/var/containers/Bundle/Application"
    static let dataRoot = "/var/mobile/Containers/Data/Application"

    private static var cached: [InstalledApp] = []
    private static var cachedAt: Date?

    /// 扫描已安装 App（带 60 秒缓存）
    static func installedApps(force: Bool = false) -> [InstalledApp] {
        if !force, let cachedAt = cachedAt, Date().timeIntervalSince(cachedAt) < 60, !cached.isEmpty {
            return cached
        }

        var dataContainers: [String: String] = [:]
        if let uuids = try? FileManager.default.contentsOfDirectory(atPath: dataRoot) {
            for uuid in uuids {
                let metadata = dataRoot + "/" + uuid + "/.com.apple.mobile_container_manager.metadata.plist"
                guard let plist = NSDictionary(contentsOfFile: metadata),
                      let identifier = plist["MCMMetadataIdentifier"] as? String else { continue }
                dataContainers[identifier] = dataRoot + "/" + uuid
            }
        }

        var apps: [InstalledApp] = []
        if let uuids = try? FileManager.default.contentsOfDirectory(atPath: bundleRoot) {
            for uuid in uuids {
                let container = bundleRoot + "/" + uuid
                guard let children = try? FileManager.default.contentsOfDirectory(atPath: container) else { continue }
                for child in children where child.hasSuffix(".app") {
                    let bundlePath = container + "/" + child
                    let infoPath = bundlePath + "/Info.plist"
                    guard let info = NSDictionary(contentsOfFile: infoPath) else { continue }

                    let bundleId = (info["CFBundleIdentifier"] as? String) ?? ""
                    guard !bundleId.isEmpty else { continue }
                    let executable = (info["CFBundleExecutable"] as? String) ?? ""
                    let displayName = (info["CFBundleDisplayName"] as? String)
                        ?? (info["CFBundleName"] as? String)
                        ?? child.replacingOccurrences(of: ".app", with: "")
                    let version = (info["CFBundleShortVersionString"] as? String) ?? ""

                    apps.append(InstalledApp(
                        bundleId: bundleId,
                        name: displayName,
                        version: version,
                        bundlePath: bundlePath,
                        executableName: executable,
                        dataPath: dataContainers[bundleId],
                        iconPath: findIcon(in: bundlePath)
                    ))
                }
            }
        }

        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cached = apps
        cachedAt = Date()
        return apps
    }

    static func app(withBundleId bundleId: String, force: Bool = false) -> InstalledApp? {
        return installedApps(force: force).first { $0.bundleId == bundleId }
    }

    static func app(withBundlePath path: String, force: Bool = false) -> InstalledApp? {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        return installedApps(force: force).first { $0.bundlePath == normalized }
    }

    /// 在 .app 里找一个能当图标用的 png
    private static func findIcon(in bundlePath: String) -> String? {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: bundlePath) else { return nil }
        let preferred = ["AppIcon60x60@2x.png", "AppIcon60x60@3x.png", "AppIcon76x76@2x~ipad.png", "Icon.png", "AppIcon.png"]
        for name in preferred {
            let candidate = bundlePath + "/" + name
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        let icons = children.filter { $0.hasPrefix("AppIcon") && $0.hasSuffix(".png") }
        if let first = icons.sorted().last {
            return bundlePath + "/" + first
        }
        return nil
    }
}
