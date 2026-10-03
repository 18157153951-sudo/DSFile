//
//  AppIconLoader.swift — 已安装 App 图标加载（三级回退，任何一步失败都不崩）
//
//  一级：包内松散图标文件（AppScanner 已经解析出 iconPath）
//  二级：私有 API LSApplicationProxy 的 iconDataForVariant:（运行时查找，不引私有头文件）
//  三级：返回 nil，调用方画占位（SF Symbol app.fill）
//
//  图标在后台线程加载、内存缓存（NSCache），回调统一在主线程。
//

import UIKit

final class AppIconLoader {

    static let shared = AppIconLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "com.dsfile.appicon", qos: .userInitiated)

    private init() {
        cache.countLimit = 256
    }

    func cached(bundleId: String) -> UIImage? {
        guard !bundleId.isEmpty else { return nil }
        return cache.object(forKey: bundleId as NSString)
    }

    /// 异步取图标；completion 在主线程回调，取不到时给 nil（调用方画占位）
    func load(bundleId: String, iconPath: String?, completion: @escaping (UIImage?) -> Void) {
        if let hit = cached(bundleId: bundleId) {
            completion(hit)
            return
        }
        queue.async { [weak self] in
            var image: UIImage?
            if let fromBundle = Self.iconFromBundle(iconPath: iconPath) {
                image = fromBundle
            } else if let fromProxy = Self.iconFromProxy(bundleId: bundleId) {
                image = fromProxy
            }
            if let image = image, !bundleId.isEmpty {
                self?.cache.setObject(image, forKey: bundleId as NSString)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    // MARK: - 一级：包内图标文件

    private static func iconFromBundle(iconPath: String?) -> UIImage? {
        guard let path = iconPath, !path.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return UIImage(contentsOfFile: path)
    }

    // MARK: - 二级：LSApplicationProxy（私有 API，全部运行时查找 + 容错）

    private static func iconFromProxy(bundleId: String) -> UIImage? {
        guard !bundleId.isEmpty else { return nil }
        guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type else { return nil }

        let proxySelector = NSSelectorFromString("applicationProxyForIdentifier:")
        guard proxyClass.responds(to: proxySelector) else { return nil }
        guard let proxy = proxyClass.perform(proxySelector, with: bundleId)?.takeUnretainedValue() as? NSObject else { return nil }

        let dataSelector = NSSelectorFromString("iconDataForVariant:")
        guard proxy.responds(to: dataSelector) else { return nil }
        guard let method = proxy.method(for: dataSelector) else { return nil }

        // iconDataForVariant: 的参数是 int，perform(_:with:) 只能传对象，所以直接按 IMP 调
        typealias IconDataFn = @convention(c) (AnyObject, Selector, Int32) -> Unmanaged<NSData>?
        let fn = unsafeBitCast(method, to: IconDataFn.self)

        for variant in [2, 3, 1, 0] as [Int32] {
            guard let data = fn(proxy, dataSelector, variant)?.takeUnretainedValue() else { continue }
            if let image = UIImage(data: data as Data) {
                return image
            }
        }
        return nil
    }
}
