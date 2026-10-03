//
//  EnvironmentProbe.swift — 运行环境探测（越狱类型 / 沙盒可达性 / uid）
//
//  为什么要有它：免越狱时文件操作必须靠内核逃逸（DSKernel.isEscaped()），
//  但在越狱 / roothide / TrollStore 环境下 POSIX 本来就能直接读写系统路径，
//  这时不该再强制要求先跑内核漏洞。统一入口就是 EnvironmentProbe.hasFileSystemAccess()。
//
//  判定原则：**能读能写才算数**——不只看标志位，真的去列一下/写一下沙盒外的路径。
//  探测结果缓存 30 秒（可在设置页点刷新，或 EnvironmentProbe.invalidate()）。
//

import Foundation
import Darwin

// MARK: - 越狱类型

enum JailbreakFlavor: String {
    case none
    case classic
    case rootless
    case roothide

    var title: String {
        switch self {
        case .none: return "未越狱"
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
    /// TrollStore 安装了（可以独立于越狱存在）
    var trollStoreInstalled = false
    /// 可用的越狱根：越狱时是 "/" 或 "/var/jb" 或 roothide 的 jbroot 前缀；未越狱为 nil
    var jailbreakRoot: String?
    /// 可用的 sh（优先越狱根下的 /bin/sh，其次 /bin/sh）
    var shellPath: String?
    var uid: uid_t = 0
    /// 真的能读到沙盒外目录
    var canReadOutsideSandbox = false
    /// 真的能往沙盒外写（在 /var/mobile 与 /var/tmp 各试一次）
    var canWriteOutsideSandbox = false
    /// 内核逃逸是否已就绪（由调用方填，见 refreshKernelState）
    var kernelEscaped = false

    var isRoot: Bool { uid == 0 }

    /// 统一入口：内核逃逸 **或** 环境本身可达沙盒外，二者之一即可做文件操作
    var hasFileSystemAccess: Bool {
        return kernelEscaped || canWriteOutsideSandbox || canReadOutsideSandbox
    }

    /// 一句人话结论，给设置页 footer / 日志用
    var summary: String {
        var parts: [String] = []
        parts.append("环境：\(flavor.title)" + (trollStoreInstalled ? " + TrollStore" : ""))
        parts.append(kernelEscaped ? "内核逃逸已激活" : "内核逃逸未激活")
        parts.append(isRoot ? "uid 0（已具备 root）" : "uid \(uid)")
        if !kernelEscaped && (canWriteOutsideSandbox || canReadOutsideSandbox) {
            parts.append("可直接读写沙盒外路径（无需内核）")
        }
        return parts.joined(separator: " · ")
    }

    /// 设置页「环境」Section 用的徽章：(图标, 标题, 值, 语义色)
    var badges: [(icon: String, title: String, value: String, ok: Bool)] {
        var list: [(String, String, String, Bool)] = []
        list.append(("shippingbox", "越狱环境",
                     flavor.isJailbroken ? flavor.title : (trollStoreInstalled ? "未越狱（TrollStore）" : "未越狱"),
                     flavor.isJailbroken || trollStoreInstalled))
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

    // MARK: - 具体判定

    private static func detect() -> EnvironmentInfo {
        var info = EnvironmentInfo()
        info.uid = getuid()

        let fm = FileManager.default

        // 1) roothide：/var/mobile/Library/roothide 或任意 .jbroot-* 目录（roothide 用它当越狱根前缀）
        if let root = detectRoothide(fm: fm) {
            info.flavor = .roothide
            info.jailbreakRoot = root
        }
        // 2) rootless（Dopamine / palera1n rootless）
        else if fm.fileExists(atPath: "/var/jb/usr") || fm.fileExists(atPath: "/var/jb/bin") {
            info.flavor = .rootless
            info.jailbreakRoot = "/var/jb"
        }
        // 3) 经典越狱：MobileSubstrate 或（/bin/sh 可用且我们是 root）
        else if fm.fileExists(atPath: "/Library/MobileSubstrate/MobileSubstrate.dylib")
                    || fm.fileExists(atPath: "/Library/MobileSubstrate/DynamicLibraries") {
            info.flavor = .classic
            info.jailbreakRoot = "/"
        } else if fm.isExecutableFile(atPath: "/bin/sh") && info.uid == 0 {
            info.flavor = .classic
            info.jailbreakRoot = "/"
        }

        // TrollStore：装过就独立标记（它的 /var/containers/Bundle/Application 里会有 TrollStore.app）
        info.trollStoreInstalled = detectTrollStore(fm: fm)

        // sh 路径：越狱根优先
        info.shellPath = resolveShell(info: info)

        // 真实可达性：先读，再写
        info.canReadOutsideSandbox = canList(fm, "/var/mobile/Library")
            || canList(fm, "/var/jb")
            || canList(fm, "/Library")
            || canList(fm, "/var/containers/Bundle/Application")

        info.canWriteOutsideSandbox = probeWrite("/var/mobile/.myfilza_env_probe")
            || probeWrite("/var/tmp/.myfilza_env_probe")

        return info
    }

    /// roothide 的越狱根形如 `/var/containers/Bundle/Application/.jbroot-XXXXXXXXXXXXXXXX`
    private static func detectRoothide(fm: FileManager) -> String? {
        if fm.fileExists(atPath: "/var/mobile/Library/roothide") {
            // 目录存在，但真正的根前缀还是要靠 .jbroot-* 找；找不到就返回 "/"
            return firstJBRootPrefix(fm: fm) ?? "/"
        }
        return firstJBRootPrefix(fm: fm)
    }

    private static func firstJBRootPrefix(fm: FileManager) -> String? {
        let roots = ["/var/containers/Bundle/Application", "/", "/var/mobile"]
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            if let hit = names.first(where: { $0.hasPrefix(".jbroot-") }) {
                let prefix = root == "/" ? "/" + hit : root + "/" + hit
                if fm.fileExists(atPath: prefix + "/usr") || fm.fileExists(atPath: prefix + "/bin") {
                    return prefix
                }
                return prefix
            }
        }
        return nil
    }

    private static func detectTrollStore(fm: FileManager) -> Bool {
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

    private static func canList(_ fm: FileManager, _ path: String) -> Bool {
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return false }
        return !names.isEmpty || fm.fileExists(atPath: path)
    }

    private static func probeWrite(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.createFile(atPath: path, contents: Data("probe".utf8)) else { return false }
        try? fm.removeItem(atPath: path)
        return true
    }
}
