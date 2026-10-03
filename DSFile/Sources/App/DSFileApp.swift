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
                    // 「启动时自动执行」：没有沙盒外读写权限时会跳过并在日志里写明原因
                    ReplaceAutoRunner.runIfEnabledOnLaunch()
                }
        }
    }
}

struct RootTabView: View {

    @EnvironmentObject private var kernel: KernelCenter

    /// 用 selection 绑定，好让「替换」页完成后能跳回「记录」页看那条运行记录
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            FilesView()
                .tabItem { Label("文件", systemImage: "folder") }
                .tag(0)

            ScriptsView()
                .tabItem { Label("脚本", systemImage: "square.stack.3d.up") }
                .tag(1)

            TasksView()
                .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
                .tag(2)

            ReplaceWizardView(onOpenRecords: { selection = 2 })
                .tabItem { Label("替换", systemImage: "arrow.2.squarepath") }
                .tag(3)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(4)
        }
        .accentColor(.blue)
    }
}
