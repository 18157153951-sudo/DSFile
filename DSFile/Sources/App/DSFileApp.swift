//
//  DSFileApp.swift — App 入口与四页骨架
//
//  骨架照参考包：TabView 四页（文件 / 脚本 / 记录 / 设置），每页自带 NavigationView + .stack 样式，
//  全局状态用单例 ObservableObject 注入，页面里用 @ObservedObject 取。
//

import SwiftUI
import Foundation

@main
struct DSFileApp: App {

    @StateObject private var kernel = KernelCenter.shared
    @StateObject private var browser = BrowserModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(kernel)
                .environmentObject(browser)
                .onAppear {
                    DSLog.shared.info("DSFile \(BuildInfo.version) (build \(BuildInfo.stamp)) 启动：\(DSKernel.deviceModelIdentifier()) / iOS \(DSKernel.systemVersion()) / \(DSKernel.cpuFamilyName())", source: "启动")
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

    var body: some View {
        TabView {
            FilesView()
                .tabItem { Label("文件", systemImage: "folder") }

            ScriptsView()
                .tabItem { Label("脚本", systemImage: "square.stack.3d.up") }

            TasksView()
                .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .accentColor(.blue)
    }
}
