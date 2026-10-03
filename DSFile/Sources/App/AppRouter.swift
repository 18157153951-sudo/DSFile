//
//  AppRouter.swift — 跨页跳转与「把某个 App 设成替换页目标」的传递通道
//
//  为什么需要它：应用管理器在「文件」页的 sheet 里，但它要能
//    1) 让「文件」页跳到某个 App 的 .app / 数据容器目录（复用同一个 BrowserModel）；
//    2) 切到「替换」页并把它选成目标 App。
//  TabView 的 selection 原本是 RootTabView 的局部 @State，这里提到单例里共享。
//

import Foundation
import Combine

/// 底部 Tab 的下标（与 RootTabView 里的 tag 一一对应）
enum AppTab: Int {
    case files = 0
    case scripts = 1
    case records = 2
    case replace = 3
    case settings = 4
}

final class AppRouter: ObservableObject {

    static let shared = AppRouter()

    @Published var tab: Int = AppTab.files.rawValue

    private init() {}

    func go(to tab: AppTab) {
        self.tab = tab.rawValue
    }
}

/// 「设为替换页目标 App」的一次性请求：应用管理器写入，替换页消费
final class ReplaceTargetBus: ObservableObject {

    static let shared = ReplaceTargetBus()

    @Published var pendingBundleId: String?

    private init() {}

    func request(bundleId: String) {
        guard !bundleId.isEmpty else { return }
        pendingBundleId = bundleId
    }

    func consume() -> String? {
        let value = pendingBundleId
        pendingBundleId = nil
        return value
    }
}
