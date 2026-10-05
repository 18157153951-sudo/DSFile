//
//  AppScanner.swift — 已安装 App 枚举（给「替换目标文件」选目标用）
//
//  列表来源（两级，**没权限也要有列表**）：
//    ① LSApplicationWorkspace（私有接口，运行时查找）—— **不需要任何文件系统权限**，
//       所以还没逃逸 / 没激活时也能列出设备上的 App（3105 在 iOS 18 上就是这么做的：
//       "File browsing falls back to LSApplicationWorkspace + inode walk"）。
//       路径见 DSAppListBridge.h。
//    ② 容器扫描（有文件系统访问时才做，更准确）：
//         包体：/var/containers/Bundle/Application/<UUID>/<Name>.app
//         数据：/var/mobile/Containers/Data/Application/<UUID>/
//              （靠 .com.apple.mobile_container_manager.metadata.plist 里的
//                MCMMetadataIdentifier 对应 bundle id）
//       合并时**容器扫描的结果优先覆盖**（路径/可执行文件/图标更准）。
//
//  注意：列表里有条目 ≠ 能读容器内容。能不能读由真实探针判定（EnvironmentProbe /
//  DSKernel.probeFilesystemAccess），界面据此提示「需要激活后才能读取容器内容」。
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

    /// 可执行文件路径。没有可执行文件名时（例如只有系统接口给的列表）返回包体路径本身，
    /// 避免出现 "xxx.app/" 这种带尾斜杠的假路径。
    var executablePath: String {
        guard !executableName.isEmpty else { return bundlePath }
        return bundlePath + "/" + executableName
    }

    var displayVersion: String { version.isEmpty ? "—" : version }

    var shortBundlePath: String {
        bundlePath.replacingOccurrences(of: "/var/containers/Bundle/Application/", with: "…/")
    }
}

/// 一次扫描的来源统计（日志 / 界面提示共用，避免各处自己猜）
struct AppScanReport {
    var launchServicesAvailable = false
    var launchServicesFailure: String?
    var launchServicesCount = 0
    var containerCount = 0
    var mergedCount = 0
    var hadFileSystemAccess = false
    var at = Date()

    var sourceDescription: String {
        if launchServicesCount > 0 && containerCount > 0 { return "LSApplicationWorkspace + 容器扫描" }
        if launchServicesCount > 0 { return "LSApplicationWorkspace（无需权限）" }
        if containerCount > 0 { return "容器扫描" }
        return "无（两个来源都没拿到）"
    }
}

enum AppScanner {

    static let bundleRoot = "/var/containers/Bundle/Application"
    static let dataRoot = "/var/mobile/Containers/Data/Application"

    private static var cached: [InstalledApp] = []
    private static var cachedAt: Date?
    private static var lastReportStorage = AppScanReport()
    private static let reportLock = NSLock()

    /// 最近一次真实扫描的来源统计（命中缓存时保持上一次的值）
    static var lastReport: AppScanReport {
        reportLock.lock(); defer { reportLock.unlock() }
        return lastReportStorage
    }

    /// 扫描已安装 App（带 60 秒缓存）
    static func installedApps(force: Bool = false) -> [InstalledApp] {
        if !force, let cachedAt = cachedAt, Date().timeIntervalSince(cachedAt) < 60, !cached.isEmpty {
            return cached
        }

        let env = EnvironmentProbe.info()
        var report = AppScanReport()
        report.hadFileSystemAccess = env.hasFileSystemAccess

        var byBundleId: [String: InstalledApp] = [:]

        // MARK: ① LSApplicationWorkspace（不需要权限）
        let lsEntries = DSAppListBridge.installedAppsFromLaunchServices()
        report.launchServicesAvailable = DSAppListBridge.available()
        report.launchServicesFailure = DSAppListBridge.lastFailureReason()
        if let entries = lsEntries {
            report.launchServicesCount = entries.count
            for entry in entries {
                guard let bundleId = entry[DSAppListKeyBundleId], !bundleId.isEmpty else { continue }
                let bundlePath = entry[DSAppListKeyBundlePath] ?? ""
                let dataPath = entry[DSAppListKeyDataPath]
                let name = entry[DSAppListKeyName]?.isEmpty == false
                    ? entry[DSAppListKeyName]!
                    : (bundlePath.isEmpty ? bundleId : (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))
                byBundleId[bundleId] = InstalledApp(
                    bundleId: bundleId,
                    name: name,
                    version: entry[DSAppListKeyVersion] ?? "",
                    bundlePath: bundlePath,
                    executableName: "",
                    dataPath: (dataPath?.isEmpty == false) ? dataPath : nil,
                    iconPath: bundlePath.isEmpty ? nil : findIcon(in: bundlePath)
                )
            }
        }

        // MARK: ② 容器扫描（有文件系统访问时才做；结果覆盖上面的，路径更准）
        if env.hasFileSystemAccess {
            var dataContainers: [String: String] = [:]
            if let uuids = try? FileManager.default.contentsOfDirectory(atPath: dataRoot) {
                for uuid in uuids {
                    let metadata = dataRoot + "/" + uuid + "/.com.apple.mobile_container_manager.metadata.plist"
                    guard let plist = NSDictionary(contentsOfFile: metadata),
                          let identifier = plist["MCMMetadataIdentifier"] as? String else { continue }
                    dataContainers[identifier] = dataRoot + "/" + uuid
                }
            }

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

                        report.containerCount += 1
                        byBundleId[bundleId] = InstalledApp(
                            bundleId: bundleId,
                            name: displayName,
                            version: version,
                            bundlePath: bundlePath,
                            executableName: executable,
                            dataPath: dataContainers[bundleId] ?? byBundleId[bundleId]?.dataPath,
                            iconPath: findIcon(in: bundlePath)
                        )
                    }
                }
            }
        }

        var apps = Array(byBundleId.values)
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        report.mergedCount = apps.count
        report.at = Date()

        reportLock.lock(); lastReportStorage = report; reportLock.unlock()

        cached = apps
        cachedAt = Date()

        // 每次「真的扫描」（不是命中缓存）都记一行：下次报告能直接看出列表从哪来、有没有权限
        var line = "AppScanner: 扫描到 \(apps.count) 个 App（来源=\(report.sourceDescription)"
        line += "；LSApplicationWorkspace=\(report.launchServicesCount) 个"
        line += "，容器扫描=\(report.containerCount) 个"
        line += "，文件系统访问=\(env.hasFileSystemAccess ? "是" : "否")"
        line += "，\(env.flavor.title)，uid \(env.uid)"
        if let failure = report.launchServicesFailure, report.launchServicesCount == 0 {
            line += "；系统接口不可用：\(failure)"
        }
        line += "）"
        DSLog.shared.info(line, source: "AppScanner")

        // 系统接口一个都没拿到时，把逐步诊断也写进日志：
        // 一次上报就能看出卡在哪一步（类找不到 / 哪个 dlopen 失败 / 哪个 selector 不响应 / 返回空数组）
        if report.launchServicesCount == 0 {
            for diagLine in DSAppListBridge.lastDiagnostics() {
                DSLog.shared.warn("LS 诊断：\(diagLine)", source: "AppScanner")
            }
        }
        return apps
    }

    /// 清缓存。**激活成功 / 提权成功 / 环境变化后必须调**：
    /// 否则会一直用「还没权限时扫出来的空列表」，表现为「获取到 0 个 app」，去文件页逛一圈才恢复。
    static func invalidateCache() {
        cached = []
        cachedAt = nil
    }

    static func app(withBundleId bundleId: String, force: Bool = false) -> InstalledApp? {
        return installedApps(force: force).first { $0.bundleId == bundleId }
    }

    static func app(withBundlePath path: String, force: Bool = false) -> InstalledApp? {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        return installedApps(force: force).first { $0.bundlePath == normalized }
    }

    /// 在 .app 里找一个能当图标用的 png（没有权限时读不到 → 返回 nil，界面会回退到私有接口/占位图）
    private static func findIcon(in bundlePath: String) -> String? {
        guard !bundlePath.isEmpty else { return nil }
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
