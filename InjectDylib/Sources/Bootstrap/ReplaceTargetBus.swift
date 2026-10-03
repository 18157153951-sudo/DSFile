//
//  ReplaceTargetBus.swift — 注入版的最小替身
//
//  在 myfilza App 里，这个类由「应用管理器」写入、替换页消费（点「设为替换页目标 App」）。
//  注入版（dylib）没有应用管理器，但替换向导仍然引用它，所以这里保留**同样的 API**，
//  行为保持原样（写入 / 消费一次性请求），只是当前没有任何地方会写入它。
//
//  这样替换向导那份代码（从 DSFile/Sources 复制过来）可以**一行不改**。
//

import Foundation
import Combine

/// 「设为替换页目标 App」的一次性请求：写入方 + 替换页消费
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
