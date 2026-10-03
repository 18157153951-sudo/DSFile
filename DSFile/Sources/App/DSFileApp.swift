//
//  DSFileApp.swift — App 入口与五页骨架
//
//  骨架照参考包：TabView 五页（文件 / 脚本 / 记录 / 替换 / 设置），每页自带 NavigationView + .stack 样式，
//  全局状态用单例 ObservableObject 注入，页面里用 @ObservedObject 取。
//

import SwiftUI
import Foundation

@main
struct DSFileApp: App {

    @StateObject private var kernel = KernelCenter.shared
    @StateObject private var browser = BrowserModel()

    init() {
        // 越早越好：内核漏洞跑挂时，把信号与回溯写进 Documents/Logs/crash-*.log
        DSCrash.install()
        // 系统选择器 / 分享面板出错时，把原因写进会话日志。
        // DSPickers 内部全程 @try/@catch，所以最坏情况是「提示 + 日志」，不会把 App 带走。
        DSPickers.setErrorLogHandler { message in
            DSLog.shared.error(message, source: "选择器")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(kernel)
                .environmentObject(browser)
                .onAppear {
                    DSLog.shared.info("myfilza \(BuildInfo.version) (build \(BuildInfo.stamp)) 启动：\(DSKernel.deviceModelIdentifier()) / iOS \(DSKernel.systemVersion()) / \(DSKernel.cpuFamilyName())", source: "启动")
                    DSLog.shared.info(DSKernel.supportSummary(), source: "启动")
                    kernel.refresh()
                    browser.load(path: BrowserModel.defaultStartPath())
                    kernel.activateIfNeeded()
                }
        }
    }
}

struct RootTabView: View {

    @EnvironmentObject private var kernel: KernelCenter

    /// 用单例 router 的 selection：应用管理器等页面也能切 Tab（例如「设为替换页目标 App」）
    @ObservedObject private var router = AppRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            FilesView()
                .tabItem { Label("文件", systemImage: "folder") }
                .tag(AppTab.files.rawValue)

            ScriptsView()
                .tabItem { Label("脚本", systemImage: "square.stack.3d.up") }
                .tag(AppTab.scripts.rawValue)

            TasksView()
                .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.records.rawValue)

            ReplaceWizardView(onOpenRecords: { router.go(to: .records) })
                .tabItem { Label("替换", systemImage: "arrow.2.squarepath") }
                .tag(AppTab.replace.rawValue)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppTab.settings.rawValue)
        }
        .accentColor(.blue)
    }
}
