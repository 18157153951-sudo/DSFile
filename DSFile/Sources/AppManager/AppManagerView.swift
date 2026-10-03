//
//  AppManagerView.swift — 应用管理器（长按可打开它的 .app 目录 / 数据容器）
//
//  入口在「文件」页工具栏（square.grid.2x2），以 sheet 形式打开，内部自带 NavigationView。
//  数据来自 AppScanner（与替换页同一份扫描结果，60 秒缓存）。
//  图标走 AppIconLoader 的三级回退；权限不足时给明确空状态，不留白也不无限转圈。
//

import SwiftUI
import UIKit

struct AppManagerView: View {

    @EnvironmentObject private var browser: BrowserModel
    @Environment(\.dismiss) private var dismiss

    @State private var apps: [InstalledApp] = []
    @State private var isLoading = true
    @State private var query = ""
    @State private var hasAccess = true

    private var filtered: [InstalledApp] {
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleId.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationView {
            content
                .navigationTitle("应用管理器")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索 App 名或 bundle id")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
                .onAppear(perform: prepare)
                .onReceive(NotificationCenter.default.publisher(for: .myfilzaFileSystemAccessChanged)) { _ in
                    // 激活成功 / 提权成功：权限变了，重扫一次（否则会一直显示激活前的空列表）
                    hasAccess = EnvironmentProbe.hasFileSystemAccess()
                    if hasAccess { load(force: true) }
                }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        // 注意：**不再因为「没权限」就不显示列表**。
        // 列表现在优先来自 LSApplicationWorkspace（不需要任何权限），
        // 没权限只影响「能不能读容器内容」，不影响「能不能列出 App」。
        if isLoading {
            loadingState
        } else if apps.isEmpty {
            hasAccess ? emptyState : noAccessState
        } else if filtered.isEmpty {
            noMatchState
        } else {
            appList
        }
    }

    private var appList: some View {
        List {
            if !hasAccess {
                noAccessBanner
            }
            Section {
                ForEach(filtered) { app in
                    NavigationLink(destination: AppManagerDetailView(app: app, onClose: { dismiss() })) {
                        AppManagerRow(app: app)
                    }
                    .contextMenu { actions(for: app) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("共 \(apps.count) 个 App（列表来源：\(AppScanner.lastReport.sourceDescription)）。长按一行可以直接打开它的 .app 目录或数据容器。")
                    Text("图标优先读包内图标文件，读不到时用系统私有接口；都拿不到就显示占位图标。")
                }
                .font(.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { load(force: true) }
    }

    /// 没有文件系统访问时也要把话说清：**能看列表 ≠ 能读容器内容**。
    private var noAccessBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("App 列表来自系统接口（不需要权限）", systemImage: "list.bullet.rectangle")
                    .font(.footnote.weight(.semibold))
                Text("名字、图标、容器路径都能显示。但读取容器里的文件需要先激活访问：点进目录若提示读不到，请到「设置」页激活，或换一个可用的访问路径。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var loadingState: some View {
        List {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在扫描已安装 App…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var noAccessState: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.slash")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("现在读不到已安装 App 的目录")
                .font(.headline)
            Text("请到「设置」页点『激活内核访问』；越狱 / roothide / TrollStore 环境下直接就能读。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("没有扫描到已安装 App")
                .font(.headline)
            Text("确认已经激活内核访问（或处于越狱环境）后下拉刷新。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("没有匹配的 App")
                .font(.headline)
            Text("换个关键词试试。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 行内动作（长按菜单 + 详情页共用同一套行为）

    @ViewBuilder
    private func actions(for app: InstalledApp) -> some View {
        Button {
            openInFiles(app.bundlePath)
        } label: {
            Label("打开 .app 目录", systemImage: "shippingbox")
        }

        if let dataPath = app.dataPath, !dataPath.isEmpty {
            Button {
                openInFiles(dataPath)
            } label: {
                Label("打开数据容器", systemImage: "internaldrive")
            }
        }

        Button {
            copyToPasteboard(app.bundleId, what: "bundle id")
        } label: {
            Label("复制 bundle id", systemImage: "doc.on.doc")
        }

        Button {
            copyToPasteboard(app.bundlePath, what: "包体路径")
        } label: {
            Label("复制路径", systemImage: "doc.on.clipboard")
        }

        Button {
            setAsReplaceTarget(app)
        } label: {
            Label("设为替换页目标 App", systemImage: "arrow.2.squarepath")
        }
    }

    // MARK: - 行为

    private func prepare() {
        hasAccess = EnvironmentProbe.hasFileSystemAccess()
        // 以前这里「没权限就直接 return」，导致未激活时永远看到空白 ✗。
        // 现在列表由 LSApplicationWorkspace 提供（不需要权限），所以**总是加载**。
        load(force: false)
    }

    private func load(force: Bool) {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppScanner.installedApps(force: force)
            DispatchQueue.main.async {
                self.apps = list
                self.isLoading = false
            }
        }
    }

    private func openInFiles(_ path: String) {
        guard !path.isEmpty else { return }
        browser.load(path: path)
        AppRouter.shared.go(to: .files)
        dismiss()
    }

    private func setAsReplaceTarget(_ app: InstalledApp) {
        ReplaceTargetBus.shared.request(bundleId: app.bundleId)
        DSLog.shared.info("已把 \(app.name) 设为替换页目标 App", source: "应用管理器")
        AppRouter.shared.go(to: .replace)
        dismiss()
    }

    private func copyToPasteboard(_ text: String, what: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        DSLog.shared.info("已复制\(what)：\(text)", source: "应用管理器")
    }
}

// MARK: - 列表行

struct AppManagerRow: View {

    let app: InstalledApp

    @State private var icon: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(image: icon, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(app.bundleId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("v\(app.displayVersion) · \(app.dataPath ?? "无数据容器")")
                    .font(.caption2)
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
        AppIconLoader.shared.load(bundleId: app.bundleId, iconPath: app.iconPath) { image in
            self.icon = image
        }
    }
}

// MARK: - 详情页

struct AppManagerDetailView: View {

    let app: InstalledApp
    let onClose: () -> Void

    @EnvironmentObject private var browser: BrowserModel

    @State private var icon: UIImage?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AppIconView(image: icon, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(app.bundleId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("版本 \(app.displayVersion)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("路径") {
                pathRow(title: "包体", path: app.bundlePath)
                if let dataPath = app.dataPath, !dataPath.isEmpty {
                    pathRow(title: "数据容器", path: dataPath)
                }
                if !app.executableName.isEmpty {
                    pathRow(title: "可执行文件", path: app.executablePath)
                }
            }

            Section {
                Button {
                    openInFiles(app.bundlePath)
                } label: {
                    actionLabel(title: "打开 .app 目录", systemImage: "shippingbox", color: .blue)
                }

                if let dataPath = app.dataPath, !dataPath.isEmpty {
                    Button {
                        openInFiles(dataPath)
                    } label: {
                        actionLabel(title: "打开数据容器", systemImage: "internaldrive", color: .green)
                    }
                }

                Button {
                    ReplaceTargetBus.shared.request(bundleId: app.bundleId)
                    DSLog.shared.info("已把 \(app.name) 设为替换页目标 App", source: "应用管理器")
                    AppRouter.shared.go(to: .replace)
                    onClose()
                } label: {
                    actionLabel(title: "设为替换页目标 App", systemImage: "arrow.2.squarepath", color: .orange)
                }
            } footer: {
                Text("「打开目录」会切到「文件」页并定位到该路径，方便直接翻它的包体或数据容器。")
                    .font(.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadIcon)
    }

    private func pathRow(title: String, path: String) -> some View {
        Button {
            UIPasteboard.general.string = path
            DSLog.shared.info("已复制\(title)路径：\(path)", source: "应用管理器")
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 28)
            Text(title)
                .font(.subheadline)
                .foregroundColor(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func loadIcon() {
        guard icon == nil else { return }
        AppIconLoader.shared.load(bundleId: app.bundleId, iconPath: app.iconPath) { image in
            self.icon = image
        }
    }

    private func openInFiles(_ path: String) {
        guard !path.isEmpty else { return }
        browser.load(path: path)
        AppRouter.shared.go(to: .files)
        onClose()
    }
}
