//
//  BuildInfo.swift — CI 会在构建时把 git 短哈希与时间戳塞进 stamp
//

import Foundation

enum BuildInfo {
    /// 由 GitHub Actions 用 sed 替换，本地构建时保持 "dev"
    static let stamp = "dev"
    static let version = "0.3.9"
}
