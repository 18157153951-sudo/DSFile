//
//  EnvironmentProbe.swift — 运行环境探测（越狱类型 / TrollStore / 沙盒可达性 / uid）
//
//  为什么要有它：免越狱时文件操作必须靠内核逃逸（DSKernel.isEscaped()），
//  但在越狱 / roothide / TrollStore 环境下 POSIX 本来就能直接读写系统路径，
//  这时不该再强制要求先跑内核漏洞。统一入口就是 EnvironmentProbe.hasFileSystemAccess()。
//
//  判定原则：
//    ① **能读能写才算数** —— 不只看标志位，真的去列一下/写一下沙盒外的路径
//       （逐路径 + 真实 errno，见 DSFSAccessProbe：EPERM=沙盒拒绝 / EACCES=权限不足 / ENOENT=不存在）；
//    ② **认不出来就说"未检测到越狱特征"，绝不说"未越狱"** —— 并列出试过哪些信号、各自结果；
//    ③ TrollStore 用**签名信息**判定（TeamIdentifier == TROLLTROLL，不需要任何权限，
//       真机日志已证明可读），文件系统痕迹只作补充。
//
//  探测结果缓存 30 秒（可在设置页点刷新，或 EnvironmentProbe.invalidate()）。
//

import Foundation
import Darwin

extension Notification.Name {
    /// 沙盒外访问权限发生变化（内核逃逸成功 / 提权成功 / 环境重探）：
    /// 替换页与应用管理器监听它，立刻重扫 App 列表（否则会一直显示激活前的空列表）。
    static let myfilzaFileSystemAccessChanged = Notification.Name("myfilza.fileSystemAccessChanged")
}

// MARK: - 越狱类型

enum JailbreakFlavor: String {
    case none
    case classic
    case rootless
    case roothide

    var title: String {
        switch self {
        case .none: return "未检测到越狱特征"
        case .classic: return "经典越狱（rootful）"
        case .rootless: return "rootless（/var/jb）"
        case .roothide: return "roothide"
        }
    }

    var isJailbroken: Bool { self != .none }
}

// MARK: - 探测结果

struct EnvironmentInfo {

    var flavor: JailbreakFlavor = .none
    /// TrollStore 安装了（可以独立于越狱存在；用签名信息判定）
    var trollStoreInstalled = false
    /// TrollStore 判定的依据（一句话）
    var trollStoreEvidence: String?
    /// 可用的越狱根：越狱时是 "/" 或 "/var/jb" 或 roothide 的 jbroot 前缀；未越狱为 nil
    var jailbreakRoot: String?
    /// 可用的 sh（优先越狱根下的 /bin/sh，其次 /bin/sh）
    var shellPath: String?
    var uid: uid_t = 0
    /// 真的能读到沙盒外目录（逐路径探针：/var/mobile 或容器根）
    var canReadOutsideSandbox = false
    /// 真的能往沙盒外写（/var/mobile 与 /var/tmp 各试一次）
    var canWriteOutsideSandbox = false
    /// 内核逃逸是否已就绪（由调用方填，见 refreshKernelState）
    var kernelEscaped = false
    /// 逐路径探针的完整报告（写日志 / 设置页展示）
    var accessReport = ""
    /// 探测时试过的信号与各自结果（一行一条，给日志/设置页）
    var detectionNotes: [String] = []

    var isRoot: Bool { uid == 0 }

    /// 统一入口：内核逃逸 **或** 环境本身可达沙盒外，二者之一即可做文件操作
    var hasFileSystemAccess: Bool {
        return kernelEscaped || canWriteOutsideSandbox || canReadOutsideSandbox
    }

    /// 只能读、不能写（界面提示用）
    var readOnlyOutsideSandbox: Bool {
        return canReadOutsideSandbox && !canWriteOutsideSandbox && !kernelEscaped
    }

    /// 一句人话结论，给设置页 footer / 日志用
    var summary: String {
        var parts: [String] = []
        var environment = flavor.title
        if trollStoreInstalled {
            environment += (flavor.isJailbroken ? " + TrollStore" : "（TrollStore 环境）")
        }
        parts.append("环境：\(environment)")
        parts.append(kernelEscaped ? "内核逃逸已激活" : "内核逃逸未激活")
        parts.append(isRoot ? "uid 0（已具备 root）" : "uid \(uid)")
        if !kernelEscaped && canWriteOutsideSandbox {
            parts.append("可直接读写沙盒外路径（无需内核）")
        } else if !kernelEscaped && canReadOutsideSandbox {
            parts.append("沙盒外只读可达（写仍需激活）")
        } else if !kernelEscaped {
            parts.append("沙盒外不可达")
        }
        return parts.joined(separator: " · ")
    }

    /// 检测到越狱/TrollStore 却仍然读不到系统路径时的解释（没有这种情况时为 nil）
    var sandboxHint: String? {
        guard !hasFileSystemAccess else { return nil }
        if trollStoreInstalled {
            return "检测到 TrollStore 环境，但本 App 读不到系统路径："
                + "多半是安装时没带上 platform-application 权限（用 TrollStore 重新安装本 IPA 即可），"
                + "或者本机是 roothide 的沙盒化安装（roothide 下 App 默认仍受沙盒限制）。"
        }
        if flavor == .roothide {
            return "检测到 roothide，但本 App 仍受沙盒限制 —— TrollStore 安装的 App 在 roothide 下"
                + "**不会**获得越狱权限（roothide 的设计就是让 App 看不到越狱）；"
                + "请改用越狱版（.deb）安装（Sileo / Zebra，装进 <jbroot>/Applications/），"
                + "或把「访问路径」改成「自动」/「仅内核」走内核那条。"
        }
        if flavor.isJailbroken {
            return "检测到越狱特征，但本 App 读不到系统路径：说明本 App 没有被授予沙盒例外，"
                + "请改用内核逃逸激活。"
        }
        return nil
    }

    /// 设置页「环境」Section 用的徽章：(图标, 标题, 值, 语义色)
    var badges: [(icon: String, title: String, value: String, ok: Bool)] {
        var list: [(String, String, String, Bool)] = []
        let environmentValue: String
        if flavor.isJailbroken {
            environmentValue = flavor.title
        } else if trollStoreInstalled {
            environmentValue = "未检测到越狱特征（TrollStore）"
        } else {
            environmentValue = "未检测到越狱特征"
        }
        list.append(("shippingbox", "越狱环境", environmentValue, flavor.isJailbroken || trollStoreInstalled))
        if trollStoreInstalled {
            list.append(("tray.and.arrow.down", "安装方式",
                         "TrollStore（\(trollStoreEvidence ?? "签名标记")）", true))
        }
        list.append(("lock.shield", "内核逃逸",
                     kernelEscaped ? "已激活" : "未激活",
                     kernelEscaped))
        list.append(("person.badge.key", "进程身份",
                     isRoot ? "uid 0（root）" : "uid \(uid)（mobile）",
                     isRoot))
        list.append(("externaldrive", "沙盒外读写",
                     canWriteOutsideSandbox ? "可写" : (canReadOutsideSandbox ? "只读可达" : "不可达"),
                     canWriteOutsideSandbox || canReadOutsideSandbox))
        if let root = jailbreakRoot, flavor.isJailbroken {
            list.append(("folder.badge.gearshape", "越狱根", root, true))
        }
        return list.map { (icon: $0.0, title: $0.1, value: $0.2, ok: $0.3) }
    }
}

// MARK: - 探测器

enum EnvironmentProbe {

    private static let lock = NSLock()
    private static var cached: EnvironmentInfo?
    private static var cachedAt: Date?
    private static let cacheSeconds: TimeInterval = 30

    /// 上一次写进日志的探针报告签名（避免每次刷新都刷 7 行日志）
    private static var lastLoggedReportSignature: String?

    /// 探测（默认走 30 秒缓存）
    static func info(force: Bool = false) -> EnvironmentInfo {
        lock.lock()
        defer { lock.unlock() }

        if !force, let cached = cached, let cachedAt = cachedAt,
           Date().timeIntervalSince(cachedAt) < cacheSeconds {
            return cached
        }

        var result = detect()
        // 内核状态每次都现场问一次（很便宜，且逃逸成功要立刻反映出来）
        result.kernelEscaped = DSKernel.isEscaped()
        cached = result
        cachedAt = Date()
        logIfChanged(result)
        return result
    }

    static func invalidate() {
        lock.lock()
        cached = nil
        cachedAt = nil
        lock.unlock()
    }

    /// 统一入口：能不能操作沙盒外的文件（内核逃逸 或 环境本身可达）
    static func hasFileSystemAccess() -> Bool {
        return info().hasFileSystemAccess
    }

    /// 内核状态变了之后刷新一次（激活成功/提权成功时调）
    static func refreshKernelState() {
        _ = info(force: true)
    }

    /// 权限状态变化后的**统一收尾**：清环境缓存 + 清 AppScanner 缓存 + 广播通知。
    /// 调用点：KernelCenter 激活成功、提权成功。
    /// 少了这一步，替换页/应用管理器就会一直用「激活前（没权限）扫出来的空列表」。
    static func notifyFileSystemAccessChanged() {
        invalidate()
        refreshKernelState()
        AppScanner.invalidateCache()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .myfilzaFileSystemAccessChanged, object: nil)
        }
    }

    // MARK: - 日志（只在结论变化时写，避免刷屏）

    private static func logIfChanged(_ info: EnvironmentInfo) {
        let signature = "\(info.flavor.rawValue)|\(info.trollStoreInstalled)|\(info.canReadOutsideSandbox)|\(info.canWriteOutsideSandbox)|\(info.jailbreakRoot ?? "-")"
        guard signature != lastLoggedReportSignature else { return }
        lastLoggedReportSignature = signature

        DSLog.shared.info("环境探测：\(info.summary)", source: "环境")
        for note in info.detectionNotes {
            DSLog.shared.info("环境探测信号：\(note)", source: "环境")
        }
        for line in info.accessReport.split(separator: "\n") {
            DSLog.shared.info(String(line), source: "环境")
        }
        if let hint = info.sandboxHint {
            DSLog.shared.warn(hint, source: "环境")
        }
    }

    // MARK: - 具体判定

    private static func detect() -> EnvironmentInfo {
        var info = EnvironmentInfo()
        info.uid = getuid()

        let fm = FileManager.default
        var notes: [String] = []

        // 0) TrollStore：**签名信息**判定（不需要任何权限，最可靠）
        if DSSignatureIsTrollStoreInstalled() {
            info.trollStoreInstalled = true
            info.trollStoreEvidence = DSSignatureTrollStoreEvidence()
            notes.append("TrollStore（签名）：\(info.trollStoreEvidence ?? "签名标记") ✓")
        } else {
            let team = DSSignatureTeamIdentifier() ?? "(取不到)"
            let appID = DSSignatureApplicationIdentifier() ?? "(取不到)"
            notes.append("TrollStore（签名）：TeamIdentifier=\(team)、application-identifier=\(appID) → 没有 TROLLTROLL 标记")
        }

        // 1) roothide：路径 / 环境变量 / 越狱库 / 已安装的越狱 App
        if let root = detectRoothide(fm: fm, notes: &notes) {
            info.flavor = .roothide
            info.jailbreakRoot = root
        }
        // 2) rootless（Dopamine / palera1n rootless）
        else if fm.fileExists(atPath: "/var/jb/usr") || fm.fileExists(atPath: "/var/jb/bin") {
            info.flavor = .rootless
            info.jailbreakRoot = "/var/jb"
            notes.append("rootless：/var/jb/usr 或 /var/jb/bin 存在 ✓")
        }
        // 3) 经典越狱：MobileSubstrate 或（/bin/sh 可用且我们是 root）
        else if fm.fileExists(atPath: "/Library/MobileSubstrate/MobileSubstrate.dylib")
                    || fm.fileExists(atPath: "/Library/MobileSubstrate/DynamicLibraries") {
            info.flavor = .classic
            info.jailbreakRoot = "/"
            notes.append("经典越狱：MobileSubstrate 存在 ✓")
        } else if fm.isExecutableFile(atPath: "/bin/sh") && info.uid == 0 {
            info.flavor = .classic
            info.jailbreakRoot = "/"
            notes.append("经典越狱：uid 0 且 /bin/sh 可执行 ✓")
        } else {
            notes.append("越狱特征（路径）：/var/jb、MobileSubstrate 都没看到（沙盒内读不到属正常，不代表没越狱）")
        }

        // 4) 文件系统层面的 TrollStore 痕迹（没权限时多半读不到，只作补充）
        if !info.trollStoreInstalled && detectTrollStoreArtifacts(fm: fm) {
            info.trollStoreInstalled = true
            info.trollStoreEvidence = "文件系统痕迹（TrollStore 相关文件/目录）"
            notes.append("TrollStore（文件系统痕迹）：命中 ✓")
        }

        // 5) 还没认出越狱时，用 LaunchServices 列表找越狱相关 App（不需要权限）
        if !info.flavor.isJailbroken && !info.trollStoreInstalled {
            if let hit = detectJailbreakAppViaLaunchServices() {
                info.trollStoreInstalled = true
                info.trollStoreEvidence = hit
                notes.append("LaunchServices：发现 \(hit) ✓")
            } else {
                notes.append("LaunchServices：没有发现 roothide / TrollStore / bootstrap 相关 App")
            }
        }

        // 5.5) 越狱模式模块的 jbroot 解析：roothide 会让沙盒内的 App 通过**自己容器里的
        //      `.jbroot-*` 标记**找到越狱根，这是沙盒内唯一可靠的办法（路径探测多半看不见）。
        if info.jailbreakRoot == nil, let root = DSJailbreakRootPath(), root != "/var/jb" {
            if !info.flavor.isJailbroken { info.flavor = .roothide }
            info.jailbreakRoot = root
            notes.append("jbroot（越狱模式解析）：\(root) ✓")
        } else if info.jailbreakRoot == nil {
            notes.append("jbroot（越狱模式解析）：没有解析到越狱根")
        }

        // sh 路径：越狱根优先
        info.shellPath = resolveShell(info: info)

        // 6) 真实可达性：逐路径 + 真实 errno（DSFSAccessProbe）
        info.accessReport = DSFilesystemAccessReport()
        info.canReadOutsideSandbox = DSFilesystemProbeReadable()
        info.canWriteOutsideSandbox = DSFilesystemProbeWritable()
        notes.append("文件访问：可读=\(info.canReadOutsideSandbox ? "是" : "否")、可写=\(info.canWriteOutsideSandbox ? "是" : "否")（逐路径 errno 见下面的探针报告）")

        info.detectionNotes = notes
        return info
    }

    /// roothide：路径探测保留，另加「环境变量 / 越狱库 / 越狱 App」三类沙盒内也能用的信号
    private static func detectRoothide(fm: FileManager, notes: inout [String]) -> String? {
        // ① 路径：/var/mobile/Library/roothide 或任意 .jbroot-*
        if fm.fileExists(atPath: "/var/mobile/Library/roothide") {
            notes.append("roothide（路径）：/var/mobile/Library/roothide 存在 ✓")
            return firstJBRootPrefix(fm: fm) ?? "/"
        }
        if let prefix = firstJBRootPrefix(fm: fm) {
            notes.append("roothide（路径）：找到 .jbroot-* 前缀 \(prefix) ✓")
            return prefix
        }
        notes.append("roothide（路径）：没有 /var/mobile/Library/roothide，也没有 .jbroot-*（沙盒内读不到属正常）")

        // ② 环境变量：越狱环境注入的变量（有就采信）
        let envNames = ["JBROOT", "ROOTHIDE", "THEOS_PACKAGE_INSTALL_PREFIX", "DYLD_INSERT_LIBRARIES"]
        for name in envNames {
            guard let value = environmentValue(name), !value.isEmpty else { continue }
            let lower = value.lowercased()
            if lower.contains("roothide") || lower.contains("jbroot") || lower.contains("substrate") || lower.contains("substitute") {
                notes.append("roothide（环境变量）：\(name)=\(value) ✓")
                if name == "JBROOT" || name == "ROOTHIDE" {
                    return value
                }
                return "/"
            }
        }
        notes.append("roothide（环境变量）：JBROOT / ROOTHIDE / DYLD_INSERT_LIBRARIES 都没有可用信息")

        // ③ 越狱库：先看文件在不在，再试 dlopen（只 dlopen、不调用任何函数）
        let libraryCandidates = [
            "/var/jb/usr/lib/libroothide.dylib",
            "/usr/lib/libroothide.dylib",
            "/var/jb/usr/lib/libsubstitute.dylib",
            "/usr/lib/libsubstrate.dylib",
            "/var/jb/usr/lib/libsubstrate.dylib",
        ]
        for path in libraryCandidates where fm.fileExists(atPath: path) {
            notes.append("roothide（越狱库）：\(path) 存在 ✓")
            if path.hasSuffix("libroothide.dylib") {
                if let handle = dlopen(path, RTLD_NOW) {
                    notes.append("roothide（越狱库）：dlopen \(path) 成功 ✓")
                    dlclose(handle)
                } else {
                    notes.append("roothide（越狱库）：\(path) 存在但 dlopen 失败（沙盒拒绝加载）")
                }
            }
            return "/"
        }
        notes.append("roothide（越狱库）：常见越狱库路径都不可见")
        return nil
    }

    /// 通过 LaunchServices 列表找越狱相关 App（不需要文件系统权限）
    private static func detectJailbreakAppViaLaunchServices() -> String? {
        guard let entries = DSAppListBridge.installedAppsFromLaunchServices() else { return nil }
        let keywords = ["roothide", "trollstore", "bootstrap", "sileo", "zebra", "dopamine", "palera1n", "substitute"]
        for entry in entries {
            guard let bundleId = entry[DSAppListKeyBundleId]?.lowercased() else { continue }
            if let keyword = keywords.first(where: { bundleId.contains($0) }) {
                return "\(bundleId)（含 \(keyword)）"
            }
        }
        return nil
    }

    private static func environmentValue(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        return String(cString: raw)
    }

    private static func firstJBRootPrefix(fm: FileManager) -> String? {
        let roots = ["/var/containers/Bundle/Application", "/", "/var/mobile"]
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            // roothide 官方文档：dpkg 会在每个含 Mach-O 的目录里生成 `.jbroot` 符号链接指向越狱根；
            // 实现里也见过 `.jbroot-<随机后缀>`，所以两种都认。
            if let hit = names.first(where: { $0 == ".jbroot" || $0.hasPrefix(".jbroot-") }) {
                let prefix = root == "/" ? "/" + hit : root + "/" + hit
                if fm.fileExists(atPath: prefix + "/usr") || fm.fileExists(atPath: prefix + "/bin") {
                    return prefix
                }
                return prefix
            }
        }
        return nil
    }

    private static func detectTrollStoreArtifacts(fm: FileManager) -> Bool {
        if fm.fileExists(atPath: "/var/mobile/Library/Preferences/com.opa334.trollstore.plist") {
            return true
        }
        if fm.fileExists(atPath: "/var/containers/Bundle/Application/.TrollStore") {
            return true
        }
        guard let uuids = try? fm.contentsOfDirectory(atPath: "/var/containers/Bundle/Application") else {
            return false
        }
        for uuid in uuids {
            guard let children = try? fm.contentsOfDirectory(atPath: "/var/containers/Bundle/Application/" + uuid) else { continue }
            if children.contains(where: { $0.hasPrefix("TrollStore") }) { return true }
        }
        return false
    }

    private static func resolveShell(info: EnvironmentInfo) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let root = info.jailbreakRoot, root != "/" {
            candidates.append(root + "/bin/sh")
            candidates.append(root + "/usr/bin/sh")
        }
        candidates.append("/var/jb/bin/sh")
        candidates.append("/bin/sh")
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
