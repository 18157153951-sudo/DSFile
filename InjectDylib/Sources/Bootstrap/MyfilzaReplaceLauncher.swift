//
//  MyfilzaReplaceLauncher.swift — 注入版入口：悬浮按钮 + 替换向导 sheet
//
//  运行环境：本 dylib 被注入进宿主 App（3105）后，代码运行在**已经有容器访问权限**的
//  宿主进程里，所以我们不需要内核漏洞、也不需要沙盒逃逸。
//
//  行为：
//   1. 宿主 UI 就绪后（延迟约 1.5s，另外还会轮询等 key window）在屏幕上挂一个可拖动的
//      圆形悬浮按钮「替换」；
//   2. 点击 → 以 sheet 打开替换向导（ReplaceWizardView，与 myfilza 里完全同一套逻辑）；
//   3. 位置与「最小化」状态持久化；长按切换最小化（半透明小圆点），再长按恢复；
//   4. 所有关键动作都写一份文件日志（宿主 Documents/myfilza-inject.log），方便用户回传。
//

import UIKit
import SwiftUI

// MARK: - 文件日志（宿主沙盒内，方便用户回传）

enum ReplaceDylibLog {

    private static let queue = DispatchQueue(label: "com.myfilza.inject.log")
    private static var fileURL: URL? = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let dir = docs?.appendingPathComponent("Logs", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("myfilza-inject.log")
    }()

    static func write(_ message: String) {
        NSLog("[MyfilzaReplace] %@", message)
        queue.async {
            guard let url = fileURL else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.synchronize()          // 关键：即使宿主被杀，日志尾巴也在
            } else {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - 悬浮按钮

private final class ReplaceFloatingButton: UIButton {

    private static let centerXKey = "MyfilzaReplace.buttonCenterX"
    private static let centerYKey = "MyfilzaReplace.buttonCenterY"
    private static let minimizedKey = "MyfilzaReplace.buttonMinimized"

    private var minimized: Bool = UserDefaults.standard.bool(forKey: minimizedKey)

    static func make() -> ReplaceFloatingButton {
        let button = ReplaceFloatingButton(type: .custom)
        button.frame = CGRect(x: 0, y: 0, width: 58, height: 58)
        button.layer.cornerRadius = 29
        button.layer.masksToBounds = false
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.28
        button.layer.shadowRadius = 6
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.88)
        button.setTitle("替换", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.accessibilityLabel = "打开 myfilza 替换向导"

        button.addTarget(button, action: #selector(handleTap), for: .touchUpInside)
        let pan = UIPanGestureRecognizer(target: button, action: #selector(handlePan(_:)))
        button.addGestureRecognizer(pan)
        let longPress = UILongPressGestureRecognizer(target: button, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.6
        button.addGestureRecognizer(longPress)

        button.applyMinimized(button.minimized, animated: false)
        return button
    }

    // MARK: 交互

    @objc private func handleTap() {
        ReplaceDylibLog.write("点击悬浮按钮 → 打开替换向导")
        MyfilzaReplaceLauncher.presentWizard()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }
        let translation = gesture.translation(in: superview)
        center = CGPoint(x: center.x + translation.x, y: center.y + translation.y)
        gesture.setTranslation(.zero, in: superview)
        clampInside(superview)

        if gesture.state == .ended || gesture.state == .cancelled {
            UserDefaults.standard.set(Double(center.x), forKey: Self.centerXKey)
            UserDefaults.standard.set(Double(center.y), forKey: Self.centerYKey)
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        minimized.toggle()
        UserDefaults.standard.set(minimized, forKey: Self.minimizedKey)
        applyMinimized(minimized, animated: true)
        ReplaceDylibLog.write("长按悬浮按钮 → \(minimized ? "已最小化（再长按恢复）" : "已恢复")")
    }

    private func applyMinimized(_ flag: Bool, animated: Bool) {
        let changes = {
            self.alpha = flag ? 0.4 : 1.0
            self.transform = flag ? CGAffineTransform(scaleX: 0.62, y: 0.62) : .identity
            self.setTitle(flag ? "" : "替换", for: .normal)
        }
        if animated {
            UIView.animate(withDuration: 0.18, animations: changes)
        } else {
            changes()
        }
    }

    /// 摆放：优先用上次保存的位置；没有就放右侧中间
    func place(in container: UIView) {
        let bounds = container.bounds
        let savedX = UserDefaults.standard.object(forKey: Self.centerXKey) as? Double
        let savedY = UserDefaults.standard.object(forKey: Self.centerYKey) as? Double
        if let x = savedX, let y = savedY, x > 0, y > 0 {
            center = CGPoint(x: x, y: y)
        } else {
            center = CGPoint(x: bounds.maxX - 42, y: bounds.midY)
        }
        clampInside(container)
    }

    private func clampInside(_ container: UIView) {
        let bounds = container.bounds
        let half = bounds.width > 0 ? frame.width / 2 : 29
        let halfH = frame.height / 2
        center.x = min(max(center.x, half + 4), bounds.maxX - half - 4)
        center.y = min(max(center.y, halfH + 60), bounds.maxY - halfH - 40)
    }
}

// MARK: - 入口

@objc public final class MyfilzaReplaceLauncher: NSObject {

    private static weak var button: ReplaceFloatingButton?
    private static var pollCount = 0

    /// 由 ObjC 的 constructor 调用（主线程）
    @objc public static func start() {
        ReplaceDylibLog.write("注入版启动：宿主 = \(Bundle.main.bundleIdentifier ?? "?")，等待 UI 就绪…")
        waitForWindowAndAttach()
    }

    private static func waitForWindowAndAttach() {
        guard let window = keyWindow(), window.bounds.width > 0 else {
            pollCount += 1
            if pollCount > 100 {                     // 约 30 秒还没窗口就放弃（不阻塞、不崩）
                ReplaceDylibLog.write("等待 key window 超时，放弃挂载悬浮按钮")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waitForWindowAndAttach() }
            return
        }
        attach(to: window)
    }

    private static func attach(to window: UIWindow) {
        if let existing = button, existing.superview != nil { return }
        let button = ReplaceFloatingButton.make()
        window.addSubview(button)
        button.place(in: window)
        Self.button = button
        ReplaceDylibLog.write("悬浮按钮已挂载（拖动可移动，长按可最小化，点击打开替换向导）")
    }

    // MARK: 呈现向导

    @objc public static func presentWizard() {
        guard let presenter = topViewController() else {
            ReplaceDylibLog.write("找不到可用于呈现的 view controller，取消本次打开")
            return
        }
        if presenter is UIHostingController<AnyView> || presenter.presentedViewController != nil {
            ReplaceDylibLog.write("当前已有 sheet 在展示，先关闭再打开")
            presenter.dismiss(animated: true) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { presentWizard() }
            }
            return
        }

        let root = AnyView(
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.2.squarepath")
                        .foregroundColor(.accentColor)
                    Text("myfilza 替换")
                        .font(.headline)
                    Spacer()
                    Button("关闭") { dismissTop() }
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemBackground))

                ReplaceWizardView(onOpenRecords: {
                    ReplaceDylibLog.write("向导请求「查看运行记录」：注入版没有记录页，已在向导内展示")
                })
            }
        )

        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            if let sheet = host.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = true
            }
        }
        presenter.present(host, animated: true) {
            ReplaceDylibLog.write("替换向导已打开")
        }
    }

    private static func dismissTop() {
        topViewController()?.dismiss(animated: true) {
            ReplaceDylibLog.write("替换向导已关闭")
        }
    }

    // MARK: 工具

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    private static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
