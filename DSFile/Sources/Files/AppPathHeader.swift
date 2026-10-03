//
//  AppPathHeader.swift — 「这是哪个 App 的目录」横幅（图标 + 桌面名字）
//
//  文件页与替换页的目标目录浏览器共用：只要当前目录落在某个 App 的包体或数据容器里，
//  就在列表顶部显示这个 App 的图标、桌面名字、包体/数据容器标签和 bundle id。
//  解析失败（不属于任何 App）时静默不显示，不弹任何错误。
//

import SwiftUI
import UIKit

/// App 图标（拿不到就画占位），尺寸由调用方给
struct AppIconView: View {

    let image: UIImage?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(.secondarySystemBackground)
                    Image(systemName: "app.fill")
                        .font(.system(size: size * 0.5))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }
}

/// 横幅本体
struct AppPathHeader: View {

    let resolved: ResolvedAppPath

    @State private var icon: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(image: icon, size: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(resolved.app.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(resolved.kind.title)
                        .font(.caption2)
                        .foregroundColor(resolved.kind == .bundle ? .blue : .green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            (resolved.kind == .bundle ? Color.blue : Color.green)
                                .opacity(0.12)
                        )
                        .clipShape(Capsule())
                }
                Text(resolved.app.bundleId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .onAppear(perform: loadIcon)
    }

    private func loadIcon() {
        guard icon == nil else { return }
        let app = resolved.app
        AppIconLoader.shared.load(bundleId: app.bundleId, iconPath: app.iconPath) { image in
            self.icon = image
        }
    }
}

/// 传路径进来，能解析出 App 才显示横幅，否则什么都不显示
struct AppPathHeaderIfAny: View {

    let path: String

    var body: some View {
        if let resolved = AppPathResolver.shared.resolve(path: path) {
            AppPathHeader(resolved: resolved)
        } else {
            EmptyView()
        }
    }
}
