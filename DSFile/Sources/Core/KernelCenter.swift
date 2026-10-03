//
//  KernelCenter.swift — 激活状态机（谁都不许绕过它直接调漏洞）
//

import Foundation
import Combine

enum KernelPhase: Equatable {
    case idle
    case running
    case escaped
    case exploitOnly
    case unsupported(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "未激活"
        case .running: return "激活中…"
        case .escaped: return "已激活"
        case .exploitOnly: return "内核已就绪（沙盒未通）"
        case .unsupported: return "不支持"
        case .failed: return "激活失败"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "点一下激活，本次运行就能读写沙盒外的文件。"
        case .running:
            return "正在执行内核漏洞，可能耗时数秒；期间界面无响应属正常。"
        case .escaped:
            return "本进程已可访问整机文件系统（每次冷启动都要重新激活）。"
        case .exploitOnly:
            return "内核读写已拿到，但沙盒改写没通过；可单独重试，或试一次提权。"
        case .unsupported(let reason):
            return reason
        case .failed(let reason):
            return reason
        }
    }

    var isActive: Bool {
        if case .escaped = self { return true }
        return false
    }
}

final class KernelCenter: ObservableObject {

    static let shared = KernelCenter()

    @Published private(set) var phase: KernelPhase = .idle
    @Published private(set) var isRoot: Bool = false
    @Published private(set) var kernelBase: UInt64 = 0
    @Published private(set) var busy: Bool = false

    @Published var autoActivate: Bool {
        didSet { UserDefaults.standard.set(autoActivate, forKey: KernelCenter.autoActivateKey) }
    }

    private static let autoActivateKey = "DSFile.autoActivateKernel"
    private let queue = DispatchQueue(label: "com.dsfile.kernel", qos: .userInitiated)
    private var watchdog: DispatchWorkItem?

    // MARK: - 看门狗

    /// 内核漏洞后端在异常路径上可能是死循环（不是返回错误），所以必须有个超时兜底，
    /// 否则界面会永远停在「激活中」。
    private func armWatchdog(seconds: Double) {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.busy else { return }
            self.busy = false
            self.phase = .failed("激活超过 \(Int(seconds)) 秒没有结束：多半是漏洞卡在 race 里了。请从后台完全退出 App，重开后再试一次。")
            DSLog.shared.error("激活超时（\(Int(seconds))s）：已视为失败并恢复界面（后台那个线程可能还卡着，重启 App 才会清掉）", source: "内核")
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func disarmWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private init() {
        let stored = UserDefaults.standard.object(forKey: KernelCenter.autoActivateKey) as? Bool
        // 默认不自动跑内核漏洞：必须在设置页手动点「激活」，或自己把开关打开
        autoActivate = stored ?? false
        refresh()
    }

    // MARK: - 状态刷新

    func refresh() {
        kernelBase = DSKernel.kernelBase()
        isRoot = DSKernel.isRunningAsRoot()
        if DSKernel.isEscaped() {
            phase = .escaped
        } else if busy {
            phase = .running
        } else if DSKernel.isExploitDone() {
            phase = .exploitOnly
        } else if phase.isActive || phase == .exploitOnly {
            phase = .idle
        }
    }

    // MARK: - 激活

    func activateIfNeeded() {
        guard autoActivate else { return }
        guard !DSKernel.isEscaped(), !busy else { return }
        activate()
    }

    func activate() {
        guard !busy else {
            DSLog.shared.warn("已经有一次激活在进行中，忽略这次点击（重复执行漏洞极易把设备搞崩）", source: "内核")
            return
        }
        if !DSKernel.isSystemVersionSupported() {
            phase = .unsupported(DSKernel.supportSummary())
            DSLog.shared.warn(DSKernel.supportSummary(), source: "内核")
            return
        }
        if DSKernel.isEscaped() {
            phase = .escaped
            DSLog.shared.info("沙盒已经是逃逸状态，无需重复激活", source: "内核")
            return
        }

        busy = true
        phase = .running
        DSLog.shared.info("开始激活内核访问（\(DSKernel.deviceModelIdentifier()) / iOS \(DSKernel.systemVersion()) / \(DSKernel.cpuFamilyName())）", source: "内核")

        let sink: DSKernelLogBlock = { line in
            DSLog.shared.kernel(line)
        }

        queue.async { [weak self] in
            let result = DSKernel.activate(log: sink)
            DispatchQueue.main.async {
                self?.finish(result)
            }
        }
        armWatchdog(seconds: 90)
    }

    /// 漏洞已成功、只补沙盒改写
    func retryEscape() {
        guard !busy, DSKernel.isExploitDone() else { return }
        busy = true
        phase = .running
        let sink: DSKernelLogBlock = { line in DSLog.shared.kernel(line) }
        queue.async { [weak self] in
            let result = DSKernel.retrySandboxEscape(log: sink)
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    func elevateToRoot() {
        guard !busy, DSKernel.isExploitDone() else { return }
        busy = true
        let sink: DSKernelLogBlock = { line in DSLog.shared.kernel(line) }
        queue.async { [weak self] in
            let result = DSKernel.elevateToRoot(log: sink)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                self.refresh()
                if result.rawValue == 0 || result.rawValue == 1 {
                    DSLog.shared.info("已提权到 root（uid=0）", source: "内核")
                } else {
                    DSLog.shared.warn("提权失败，继续用沙盒逃逸 + 内核改属主的方式工作", source: "内核")
                }
            }
        }
    }

    private func finish(_ result: DSKernelResult) {
        disarmWatchdog()
        busy = false
        kernelBase = DSKernel.kernelBase()
        isRoot = DSKernel.isRunningAsRoot()

        switch result.rawValue {
        case 0, 1:
            phase = .escaped
            // 逃逸成功：刷新环境探测，并触发「激活成功后自动执行」的替换任务（没开就是空操作）
            EnvironmentProbe.refreshKernelState()
            ReplaceAutoRunner.runIfEnabledAfterActivation()
        case -1:
            phase = .unsupported(DSKernel.supportSummary())
        case -2:
            phase = .failed("内核漏洞执行失败：通常是机型 / 系统版本不在 offset 表内。设备没有重启就已经是最好的结果，可以再试一次。")
        case -3:
            if DSKernel.isExploitDone() {
                phase = .exploitOnly
            } else {
                phase = .failed("沙盒改写失败")
            }
        case -4:
            phase = .running
        default:
            phase = .failed("激活过程中出现未知错误")
        }
    }
}
