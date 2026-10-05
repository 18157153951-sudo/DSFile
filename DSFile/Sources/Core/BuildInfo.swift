//
//  BuildInfo.swift — CI 会在构建时把 git 短哈希与时间戳塞进 stamp
//
//  另外负责回答一个很容易搞混的问题：**这次跑的是哪个版本形态**。
//  我们同一个 App 有三种产物：
//    · 侧载版      —— bundle id = com.dsfile.app（eSign / 证书重签安装）
//    · MHA 变体    —— bundle id = com.apple.mobile.MobileHouseArrest（零内核那条路）
//    · 越狱版(.deb)—— bundle id = com.dsfile.app.jb（Sileo / Zebra 装进 <jbroot>/Applications/）
//  0.9.0 的越狱版和侧载版**共用** com.dsfile.app，结果装上去互相顶、日志也分不清谁在跑，
//  所以 0.9.1 给越狱版单独一个 bundle id，并在这里如实打印"版本形态 + bundle id 原文"。
//

import Foundation

enum BuildInfo {
    /// 由 GitHub Actions 用 sed 替换，本地构建时保持 "dev"
    static let stamp = "dev"
    static let version = "0.9.2"

    /// 越狱版（.deb）的 bundle id 后缀（完整值是 com.dsfile.app.jb）
    static let jailbreakBundleIDSuffix = ".jb"

    /// 本 App 的 bundle id（读不到就如实说读不到，不猜）
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "(读取不到)"
    }

    /// 本次运行的版本形态 —— 只看 bundle id，简单可靠：
    ///   · 以 .jb 结尾            → 越狱版(.deb)
    ///   · == com.apple.mobile.MobileHouseArrest → MHA 变体
    ///   · 其它                   → 侧载版
    static var flavor: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        if id.hasSuffix(jailbreakBundleIDSuffix) { return "越狱版(.deb)" }
        if id == DSSignatureExpectedIdentifier { return "MHA 变体" }
        return "侧载版"
    }

    /// 启动日志用的一行：版本形态 + bundle id 原文
    static var flavorSummary: String {
        "版本形态 = \(flavor)（bundle id = \(bundleIdentifier)）"
    }
}
