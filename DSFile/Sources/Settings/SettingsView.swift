//
//  SettingsView.swift — 设置页（内核访问 / 诊断 / 更新日志 / 日志 / 关于）
//
//  约定：
//  1. 只观察 KernelCenter.shared、DSLog.shared、RunStore.shared 三个单例，不二次创建（因此用 @ObservedObject，不用 @StateObject）；
//  2. 所有内核动作都经 KernelCenter 转发，本页面不直接调用 DSKernel 的漏洞接口；
//  3. 只用 iOS 15 就有的 API：NavigationView / Form / Section / Toggle / .alert / ScrollViewReader；
//  4. 颜色全部用系统语义色，说明文案一律放 Section 的 footer。
//

import SwiftUI
import Foundation
import UIKit

// MARK: - 更新日志数据

private struct ChangeEntry: Identifiable {
    var version: String
    var date: String
    var items: [String]
    var id: String { version }
}

// MARK: - 设置页

struct SettingsView: View {

    // MARK: 依赖（单例只观察，不重新创建）

    @ObservedObject private var kernel = KernelCenter.shared
    @ObservedObject private var log = DSLog.shared
    @ObservedObject private var store = RunStore.shared

    // MARK: 本地状态

    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var alertVisible: Bool = false
    @State private var elevateConfirmVisible: Bool = false
    /// 点「重新探测环境」时换一个 token，逼 SwiftUI 重建这一块
    @State private var environmentRefreshToken = UUID()

    // MARK: 常量

    private static let appName = "myfilza"
    private static let appVersion = "0.5.0"
    private static let appBuild = "1"
    private static let maxVisibleLogLines = 300

    private static let changeLog: [ChangeEntry] = [
        ChangeEntry(version: "0.5.0", date: "2026-10-03", items: [
            "**新增第二个内核模式「3105」**（设置 → 内核模式里切换，默认仍是 FilzaJailedDS 2.2）：3105 自带更新的 offset 表，声明支持 iOS 17.0–18.7.1 / 26.0–26.6.1 / 27 beta，比现有后端覆盖更宽",
            "两个模式**互相独立**：各自跑自己的代码、各自的就绪状态，切换后需要重新点一次「激活内核访问」；默认模式的行为与之前完全一致（只做加法，没有合并）",
            "设置页现在会显示**每个模式的适用范围**、**你的设备/系统是否在范围内**，并给出一句推荐；如果所选模式不在范围内，激活前就会提示并给一个「切换到另一个模式」按钮",
            "3105 模式在沙盒逃逸失败时还会自动尝试它的另一条路（`bad_query`：用 ContainerManager 查询越权换取沙盒扩展令牌），这也是它能在 iOS 26+ 上工作的原因",
            "失败信息会写清**用的是哪个模式、卡在哪一阶段**（内核读写 / 定位进程 / 沙盒逃逸 / bad_query 回退）"
        ]),
        ChangeEntry(version: "0.4.0", date: "2026-10-03", items: [
            "**目录浏览器交互统一**：点文件 = 选中（可多选，行尾打勾、顶部显示「已选 N 项」）；点文件夹 = 进入；长按文件夹 = 把它选为目标；右上角「**确定**」永远可用——有选中就提交选中的，没选中就把**当前所在目录**当目标（在根目录按它 = 整个 .app / 数据容器）",
            "修掉「选不中文件夹」和「选了文件但确定点不动」两个问题（根因是确认按钮和选择态绑在了一起）",
            "**包体(.app)模式按你的原意重做**：不是替换整个 .app，而是在 .app 内部挑**文件（可多选）和文件夹**当目标，每个目标自动配本机同名源；没有同名源就点那一行挑",
            "**去掉「镜像 / 合并」两个模式**，改成执行区一个选项：**「目标文件夹里多出来的文件：保留（默认）/ 删除」**——保留只覆盖同名文件，删除让目标文件夹和你的源保持一致",
            "文件模式同样支持把**文件夹**当目标（在本机按同名自动配源文件夹）"
        ]),
        ChangeEntry(version: "0.3.9", date: "2026-10-03", items: [
            "**三种模式都能选文件夹了**：文件模式里在目标浏览器进到某个文件夹后点右上角「选择此文件夹」，会新增一条「文件夹绑定」（整目录镜像替换 + 递归备份），紧接着弹本机选择器让你挑源文件夹；取消就什么都不加",
            "包体模式还没添加源文件夹时按「选择此文件夹」，现在会**直接进入选源文件夹的流程**并自动绑到你刚选的目标（不再只弹一句提示）",
            "**过渡动画重做**：去掉全宽位移（位移 + 异步加载容易闪/顿），改成克制的**淡入淡出**（0.18 秒 easeOut），目标浏览器与「文件」页都生效",
            "切换目录时**不再把列表换成转圈**（那会闪出半屏空白），现在保留上一级内容、只在上面显示一行「正在读取…」",
            "修复：文件模式里「选择此文件夹」原本被置灰不可用"
        ]),
        ChangeEntry(version: "0.3.8", date: "2026-10-03", items: [
            "目录浏览器右上角现在**始终有「选择此文件夹」**：在包体(.app)模式里进到某一层文件夹按它，就直接把**这个文件夹**当成目标（在根目录按 = 整个 .app）；文件夹模式同样可用",
            "文件模式只能选文件时，这个按钮会置灰并在下方写明原因，不会再让人以为坏了",
            "多选勾选状态下按钮文案变成「用此文件夹」，语义不变（把当前文件夹作为一条绑定加进去），不会和「选择」混淆",
            "**目录切换加了过渡动画**：进子目录从右侧滑入、返回上级从左侧滑入，都带淡入淡出（0.22 秒 easeInOut）；「文件」页与目标浏览器都生效",
            "修复：包体模式还没添加源文件夹时按「选择此文件夹」原本静默无反应，现在会明确提示先添加源文件夹"
        ]),
        ChangeEntry(version: "0.3.7", date: "2026-10-03", items: [
            "新增「目标优先」绑定：在文件模式与包体(.app)模式里，先点「添加目标文件」在目标 App 目录里挑出**要替换掉的那个文件**（支持多选），App 会自动在本机找同名文件配上；同名多处让你选，一个都没有就直接弹本机选择器让你挑",
            "这样绑定的目标路径会被锁定，自动匹配不会再把它改掉；点那一行 = 更换本地替换文件，长按可重新选目标路径 / 手填 / 清除绑定",
            "原来的「本机优先」流程保留为次按钮：「添加本机文件（按名自动匹配目标）」",
            "按钮名称统一：打开目标目录的叫「添加目标文件」，打开本机选择器的叫「添加本机文件」"
        ]),
        ChangeEntry(version: "0.3.6", date: "2026-10-03", items: [
            "修复：点「添加源文件夹」会弹出「folder import is not supported, use asCopy:false」并失败——Apple 不允许用 asCopy 选文件夹。现在所有选择器一律 asCopy:NO，改由 App 自己用安全作用域把内容拷进沙盒（iCloud 未下载的文件会先协调下载），失败会给出明确原因",
            "修复：导入文件 / 导入脚本 / 添加 payload 也一并换成新的导入通道，选中文件夹不会再抛异常",
            "大文件夹（例如整个 .app）导入时拷贝需要一点时间，界面会短暂无反应，属正常"
        ]),
        ChangeEntry(version: "0.3.5", date: "2026-10-03", items: [
            "修复：点「添加源文件夹」会把 App 直接搞崩（系统选择器在转场中被重复呈现）。现在所有系统选择器 / 分享面板都从专用宿主排队呈现，出错只会提示并写日志",
            "修复：激活成功后替换页一直显示「获取到 0 个 app」，要先去文件页逛一圈才恢复。现在激活成功会立刻作废缓存并重扫 App 列表",
            "「目标 App」区新增「重新扫描 App」按钮，空列表时也有明确出路提示",
            "应用管理器与文件页也会在权限变化后自动刷新"
        ]),
        ChangeEntry(version: "0.3.4", date: "2026-10-03", items: [
            "「替换」页新增包体(.app)模式：目标锁定为所选 App 的包体，可以放一个源文件夹（整包换 / 并入）或若干文件（按文件名匹配进 .app）",
            "包体模式可选语义：「镜像替换」（整个 .app 换掉）或「仅覆盖同名文件」（合并，推荐）；两种都会先整棵递归备份",
            "自动化改成「保存的任务 + 你自己运行」：点「保存当前设置为自动化任务」存成命名任务，之后在列表里点「运行」执行；可载入编辑 / 重命名 / 删除",
            "去掉了「启动时自动执行」与「激活成功后自动执行」两个开关：App 不会在后台或启动时自动改文件",
            "旧的自动任务会自动迁移成一条保存任务，不会丢配置"
        ]),
        ChangeEntry(version: "0.3.3", date: "2026-10-03", items: [
            "新增「应用管理器」（文件页左上角方格图标）：列出已安装 App，长按一行可直接打开它的 .app 目录或数据容器",
            "应用管理器支持按 App 名 / bundle id 搜索；详情页可复制包体路径、数据容器路径、bundle id",
            "应用管理器里可以把某个 App「设为替换页目标 App」，自动切到替换页并选中它",
            "文件页与替换页的目标目录浏览器：进到某个 App 的包体或数据容器时，顶部显示它的图标与桌面名字，标题也换成 App 名",
            "App 图标三级回退（包内图标文件 → 系统私有接口 → 占位图标），任何一步拿不到都不会崩"
        ]),
        ChangeEntry(version: "0.3.2", date: "2026-10-03", items: [
            "「替换」页新增文件夹模式：选一个本地文件夹，整体镜像替换目标 App 里的某个文件夹（目标里源没有的旧文件会被移除）",
            "文件夹模式强制开启备份：替换前把整个目标文件夹递归备份，回滚走同一套「一键回滚」",
            "目标目录浏览器新增「选择此文件夹」，文件夹模式下用它挑目标文件夹",
            "新增「自动化」：可以设置「启动时自动执行」与「激活成功后自动执行」，也可以点「现在运行一次」",
            "自动执行一律强制备份、写运行记录、可一键回滚；没有沙盒外读写权限时会跳过并写明原因，不静默",
            "绑定改动会自动保存成自动任务（Documents/AutoTasks/auto.json），下次打开还在"
        ]),
        ChangeEntry(version: "0.3.1", date: "2026-10-03", items: [
            "「替换」页把「执行前自动备份」做成可见开关，关掉会明确提示没有回滚兜底",
            "每次替换后给结果卡片，并新增「最近的替换」：逐条可回滚 / 看日志 / 删记录",
            "目标 App 列表改成固定高度可滑动；选中后只留那一行 + 「更换」，不再撑满整屏",
            "新增「浏览目标 App 目录」：数据容器 / 包体可切换，进目录看面包屑，点文件直接当目标路径",
            "适配越狱环境：经典越狱 / rootless（/var/jb）/ roothide / TrollStore 可直接读写，不再强制先跑内核漏洞",
            "设置页新增「环境」区块：一眼看到越狱类型、内核逃逸状态、是否已具备 root",
            "关于页补上作者：端木awa"
        ]),
        ChangeEntry(version: "0.3.0", date: "2026-10-03", items: [
            "改名 myfilza（bundle id 不变，覆盖升级不会丢脚本、备份和日志）",
            "「提权到 root」加固：没激活内核访问时明确提示并弹窗说明；执行前先弹确认；每一次写入前都过地址闸门；写完回读 cr_uid / cr_ruid / cr_svuid / cr_groups / cr_rgid / cr_svgid 写进日志",
            "逃逸与提权都不再走那条会野读 0x378、让 App 直接退到桌面的旧路径"
        ]),
        ChangeEntry(version: "0.2.0", date: "2026-10-03", items: [
            "新增「替换」页：选目标 App，把本地文件加进来，按文件名自动在它的数据容器里找到同名文件，一键替换",
            "同名多处或找不到时，点那一行从候选里选，或手填完整路径",
            "每次替换前自动整份备份，替换完当场可一键回滚，「记录」页也能回滚",
            "替换前先检查内核访问：没激活就明确提示去设置页激活，不会静默失败"
        ]),
        ChangeEntry(version: "0.1.0", date: "2026-10-03", items: [
            "全新文件管理器：整机文件浏览、文本编辑、十六进制查看、权限与属主修改",
            "脚本页：导入自己准备好的配方（JSON）或 shell 脚本，一键替换目标 App 里指定的文件",
            "每次替换前自动整份备份，记录页可一键回滚",
            "内核访问改为手动触发并带自检，激活失败会明确告诉你原因"
        ])
    ]

    // MARK: - 页面

    var body: some View {
        NavigationView {
            Form {
                backendSection
                kernelSection
                environmentSection
                diagnosticsSection
                changeLogSection
                logSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .alert(isPresented: $alertVisible) {
                Alert(title: Text(alertTitle),
                      message: Text(alertMessage),
                      dismissButton: .default(Text("好")))
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - 环境（越狱 / rootless / roothide / TrollStore）

    private var environmentSection: some View {
        let info = EnvironmentProbe.info()
        return Section {
            ForEach(info.badges, id: \.title) { badge in
                HStack(spacing: 12) {
                    Image(systemName: badge.icon)
                        .font(.title3)
                        .foregroundColor(badge.ok ? .green : .secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(badge.title)
                            .font(.subheadline)
                        Text(badge.value)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }

            Button {
                EnvironmentProbe.invalidate()
                environmentRefreshToken = UUID()
                kernel.refresh()
            } label: {
                Label("重新探测环境", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("环境")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(info.summary)
                Text("越狱 / roothide / TrollStore 环境下文件操作直接走 POSIX，不需要先跑内核漏洞；未越狱时才必须激活内核访问。")
                if info.isRoot {
                    Text("当前进程已是 uid 0（root），可以写 root 属主的文件。")
                }
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .id(environmentRefreshToken)
    }

    // MARK: - 0. 内核模式（两套后端，用户自己选）

    /// 与 DS3105Kernel.h 里的常量保持一致（改一处要同步改另一处）
    private static let backendFilzaValue = "filzajailedds"
    private static let backend3105Value = "3105"

    @AppStorage("myfilza.kernelBackend") private var kernelBackend: String = "filzajailedds"

    private var backendSection: some View {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let major = v.majorVersion, minor = v.minorVersion, patch = v.patchVersion

        // 适用范围与 3105 的 ExploitSupportPolicy.swift 一致
        let t3105InRange = (major == 17 && minor <= 7)
            || (major == 18 && (minor < 7 || (minor == 7 && patch <= 1)))
            || (major == 26 && (minor < 6 || (minor == 6 && patch <= 1)))
            || (major == 27 && minor == 0)
        let filzaInRange = (major == 17 || major == 18)

        let device = DSKernel.deviceModelIdentifier()
        let os = "iOS \(DSKernel.systemVersion())"
        let using3105 = (kernelBackend == Self.backend3105Value)
        let selectedInRange = using3105 ? t3105InRange : filzaInRange

        return Section {
            Picker("内核模式", selection: $kernelBackend) {
                Text("FilzaJailedDS 2.2").tag(Self.backendFilzaValue)
                Text("3105").tag(Self.backend3105Value)
            }
            .pickerStyle(.segmented)

            backendRow(name: "FilzaJailedDS 2.2",
                       range: "iOS 17.x – 18.x",
                       inRange: filzaInRange,
                       selected: !using3105,
                       note: "默认模式。老实现，本机（iPhone13,4 / 18.5）已实测可逃逸。")

            backendRow(name: "3105",
                       range: "iOS 17.0–18.7.1 / 26.0–26.6.1 / 27 beta",
                       inRange: t3105InRange,
                       selected: using3105,
                       note: "上游 3105 自带更新的 offset 表，覆盖到 26.x / 27 beta；逃逸失败时还会自动尝试 bad_query（MCM 沙盒扩展令牌）。")

            if !selectedInRange {
                VStack(alignment: .leading, spacing: 6) {
                    Label("当前所选模式未声明支持你的系统", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.subheadline)
                    Text("\(device) / \(os)：\(using3105 ? "3105" : "FilzaJailedDS 2.2") 的适用范围是 \(using3105 ? "17.0–18.7.1 / 26.0–26.6.1 / 27 beta" : "17.x–18.x")。激活前建议先切换。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        kernelBackend = using3105 ? Self.backendFilzaValue : Self.backend3105Value
                    } label: {
                        Label("切换到另一个模式", systemImage: "arrow.left.arrow.right")
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("内核模式")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(recommendationText(filzaInRange: filzaInRange, t3105InRange: t3105InRange, device: device, os: os))
                Text("两个模式互相独立、各跑各的代码；切换后需要重新点一次「激活内核访问」。默认模式的行为与之前完全一致。")
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
    }

    private func recommendationText(filzaInRange: Bool, t3105InRange: Bool, device: String, os: String) -> String {
        if filzaInRange && t3105InRange {
            return "推荐：\(device) / \(os) 两个模式都支持，先用 FilzaJailedDS 2.2（本机已验证）；失败或需要 26.x / 27 时再切 3105。"
        }
        if t3105InRange && !filzaInRange {
            return "推荐：\(device) / \(os) 只有 3105 声明支持，请选 3105。"
        }
        if filzaInRange && !t3105InRange {
            return "推荐：\(device) / \(os) 只有 FilzaJailedDS 2.2 声明支持，请用它。"
        }
        return "\(device) / \(os)：两个模式都未声明支持你的系统，激活很可能失败（仍可尝试，失败会写明原因）。"
    }

    private func backendRow(name: String, range: String, inRange: Bool, selected: Bool, note: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.title3)
                .foregroundColor(selected ? .accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(selected ? .semibold : .regular)
                Text("适用范围：\(range)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(inRange ? "支持" : "未声明")
                .font(.caption2)
                .foregroundColor(inRange ? .green : .orange)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 1. 内核访问

    private var kernelSection: some View {
        Section {
            statusRow
            ForEach(deviceItems) { item in
                InfoRow(icon: item.icon,
                        tint: item.tint,
                        title: item.label,
                        detail: item.value,
                        monospaced: item.monospaced)
            }
            activationRow
            elevateRow
            autoActivateToggle
        } header: {
            Text("内核访问")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(kernel.phase.detail)
                Text("「提权到 root」只在遇到 root 拥有的文件写不进去时才需要，失败也不会影响已经拿到的能力。")
                Text("每次冷启动都要重新激活；内核漏洞有小概率导致设备重启，动手前请先保存好手头的工作；所有操作都由你自己手动触发，只作用于本机。")
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
    }

    /// 一行状态：标题用语义色，副标题给运行期摘要
    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: phaseIcon)
                .font(.title3)
                .foregroundColor(phaseColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(kernel.phase.title)
                    .font(.subheadline)
                    .foregroundColor(phaseColor)
                Text(kernel.busy ? "正在执行，请勿退出 App" : runtimeSummary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 主按钮：未激活 → 激活；已激活 → 已激活 + 重新检测；只差沙盒改写 → 重试沙盒改写
    private var activationRow: some View {
        HStack(spacing: 12) {
            Spacer()
            if kernel.busy {
                ProgressView()
                Text("激活中…")
                    .fontWeight(.semibold)
            } else if kernel.phase.isActive {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                Text("已激活")
                    .fontWeight(.semibold)
                    .foregroundColor(.green)
                Button("重新检测") {
                    kernel.refresh()
                    DSLog.shared.info("手动重新检测内核状态", source: "设置")
                }
                .font(.footnote)
            } else if isExploitOnly {
                Button(action: { kernel.retryEscape() }) {
                    Text("重试沙盒改写")
                        .fontWeight(.semibold)
                }
            } else {
                Button(action: { kernel.activate() }) {
                    Text("激活内核访问")
                        .fontWeight(.semibold)
                }
            }
            Spacer()
        }
        .disabled(kernel.busy)
    }

    /// 提权行：没激活时点它给「请先激活」提示；激活后点它先弹确认说明后果
    private var elevateRow: some View {
        Button(action: {
            guard !kernel.busy else { return }
            guard DSKernel.isExploitDone() else {
                DSLog.shared.warn("「提权到 root」需要先有内核读写：请先点上面的「激活内核访问」", source: "设置")
                presentAlert("请先激活内核访问",
                             "提权要改写内核里的凭据，必须先成功跑完一次「激活内核访问」。激活成功后再点这一项。")
                return
            }
            elevateConfirmVisible = true
        }) {
            HStack(spacing: 12) {
                Image(systemName: "lock.open.fill")
                    .font(.title3)
                    .foregroundColor(kernel.isRoot ? .green : (DSKernel.isExploitDone() ? .orange : .secondary))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("提权到 root")
                        .font(.subheadline)
                    Text(elevateSubtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if kernel.busy {
                    ProgressView()
                }
            }
        }
        .disabled(kernel.busy || kernel.isRoot)
        .confirmationDialog("确认把本进程提权到 root？",
                            isPresented: $elevateConfirmVisible,
                            titleVisibility: .visible) {
            Button("确认提权（不可逆）", role: .destructive) {
                DSLog.shared.info("用户确认提权到 root，开始改写 posix_cred", source: "设置")
                kernel.elevateToRoot()
            }
            Button("取消", role: .cancel) {
                DSLog.shared.info("用户取消了提权", source: "设置")
            }
        } message: {
            Text("本进程的 uid 会变成 0（root）：这是内核里的凭据改写，重启 App 才会恢复，App 自身行为也可能因此变化。失败不会影响已经拿到的沙盒逃逸。")
        }
    }

    private var elevateSubtitle: String {
        if kernel.isRoot { return "当前已经是 root（uid 0）" }
        if !DSKernel.isExploitDone() { return "需要先「激活内核访问」；没激活时点它会提示你去激活" }
        return "把本进程的 uid 改成 0，写 root 文件更省事；执行前会先弹确认"
    }

    /// 自动激活开关
    private var autoActivateToggle: some View {
        Toggle(isOn: $kernel.autoActivate) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.title3)
                    .foregroundColor(.orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("启动时自动激活")
                        .font(.subheadline)
                    Text(kernel.autoActivate ? "冷启动后自动尝试一次，仍需要内核自检通过" : "只有手动点按钮才会激活")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 2. 诊断

    private var diagnosticsSection: some View {
        Section {
            InfoRow(icon: "externaldrive.fill",
                    tint: .blue,
                    title: "本地备份",
                    detail: "\(store.backups.count) 份备份 · \(store.runs.count) 条运行记录")
            InfoRow(icon: "folder.fill",
                    tint: .blue,
                    title: "备份目录",
                    detail: store.backupsRoot,
                    monospaced: true)
            actionRow(icon: "doc.on.doc.fill",
                      tint: .blue,
                      title: "复制诊断信息",
                      subtitle: "机型 / 系统 / 内核状态一次性复制到剪贴板") {
                copyDiagnostics()
            }
            actionRow(icon: "square.and.arrow.up",
                      tint: .blue,
                      title: "分享诊断信息",
                      subtitle: "导出成文本文件，方便回传排查") {
                shareDiagnostics()
            }
            actionRow(icon: "doc.text.magnifyingglass",
                      tint: .blue,
                      title: "分享日志文件",
                      subtitle: logFileSubtitle) {
                shareLogFile()
            }
            actionRow(icon: "exclamationmark.triangle",
                      tint: .orange,
                      title: "分享崩溃报告",
                      subtitle: "上一次崩溃的信号与回溯（Documents/Logs/crash-*.log）") {
                if let crashPath = DSCrash.latestCrashReportPath() {
                    DSLog.shared.info("分享崩溃报告 \(crashPath)", source: "设置")
                    DSPickers.presentShareSheet(urls: [URL(fileURLWithPath: crashPath)])
                } else {
                    presentAlert("还没有崩溃报告",
                                 "目前没有记录到崩溃。注意：如果 App 是被系统看门狗杀掉、或者设备直接重启，这里可能不会生成文件。")
                }
            }
            actionRow(icon: "checkmark.shield",
                      tint: .blue,
                      title: "现场自检文件系统",
                      subtitle: "马上做一次真实的写盘探针，不读缓存") {
                probeFilesystem()
            }
        } header: {
            Text("诊断")
        } footer: {
            Text("自检不依赖缓存：在沙盒外写一个探针文件再删掉，能过才说明整机读写真的可用。")
                .font(.footnote)
        }
    }

    /// 统一的「动作行」：28pt 图标 + 标题 + 说明 + 右侧箭头
    private func actionRow(icon: String,
                           tint: Color,
                           title: String,
                           subtitle: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 3. 更新日志

    private var changeLogSection: some View {
        Section {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.changeLog) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(entry.version) · \(entry.date)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            ForEach(entry.items, id: \.self) { item in
                                Text("• \(item)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 180, maxHeight: 260)
        } header: {
            Text("更新日志")
        }
    }

    // MARK: - 4. 日志

    private var logSection: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(recentLines) { line in
                            Text(line.displayText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(levelColor(line.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 180, maxHeight: 260)
                .onAppear {
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .onChange(of: log.lines.count) { _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
            }
            actionRow(icon: "trash",
                      tint: .red,
                      title: "清空界面日志",
                      subtitle: "只清空界面显示，落盘的日志文件不动") {
                clearLog()
            }
        } header: {
            Text("日志")
        } footer: {
            Text("界面最多显示最近 \(Self.maxVisibleLogLines) 条（当前 \(recentLines.count) 条）；完整日志按会话写在 Documents/Logs 下，可以用上面的「分享日志文件」导出。")
                .font(.footnote)
        }
    }

    // MARK: - 5. 关于

    private var aboutSection: some View {
        Section {
            InfoRow(icon: "info.circle",
                    tint: .blue,
                    title: "名称",
                    detail: Self.appName)
            InfoRow(icon: "number",
                    tint: .blue,
                    title: "版本",
                    detail: "\(Self.appVersion)（Build \(Self.appBuild)）")
            InfoRow(icon: "person.crop.circle",
                    tint: .orange,
                    title: "作者",
                    detail: "端木awa")
            InfoRow(icon: "heart.fill",
                    tint: .pink,
                    title: "致谢",
                    detail: "内核漏洞与沙盒逃逸来自公开项目 FilzaJailedDS / darksword-kexploit-fun / lara，本项目只做 UI 与脚本引擎。")
        } header: {
            Text("关于")
        } footer: {
            Text("仅供在自己的设备上管理自己的数据；替换他人 App 的文件前请确认你有权这么做；动手之前务必自行备份。")
                .font(.footnote)
        }
    }

    // MARK: - 计算属性

    private var isExploitOnly: Bool {
        if case .exploitOnly = kernel.phase {
            return true
        }
        return false
    }

    private var phaseColor: Color {
        switch kernel.phase {
        case .escaped:
            return .green
        case .running:
            return .orange
        case .failed, .unsupported:
            return .red
        case .idle, .exploitOnly:
            return .secondary
        }
    }

    private var phaseIcon: String {
        switch kernel.phase {
        case .escaped:
            return "checkmark.seal.fill"
        case .running:
            return "hourglass"
        case .failed, .unsupported:
            return "exclamationmark.triangle.fill"
        case .exploitOnly:
            return "exclamationmark.circle.fill"
        case .idle:
            return "power"
        }
    }

    private var runtimeSummary: String {
        let base: String
        if kernel.kernelBase == 0 {
            base = "内核基址未获取"
        } else {
            base = String(format: "内核基址 0x%llx", kernel.kernelBase)
        }
        return base + " · " + (kernel.isRoot ? "uid 0" : "uid mobile")
    }

    private var deviceItems: [DeviceInfoItem] {
        var items: [DeviceInfoItem] = []
        items.append(DeviceInfoItem(icon: "iphone", tint: .blue, label: "机型",
                                    value: DSKernel.deviceModelIdentifier(), monospaced: true))
        items.append(DeviceInfoItem(icon: "gear", tint: .blue, label: "系统",
                                    value: "iOS \(DSKernel.systemVersion())", monospaced: true))
        items.append(DeviceInfoItem(icon: "cpu", tint: .purple, label: "芯片",
                                    value: DSKernel.cpuFamilyName(), monospaced: false))
        items.append(DeviceInfoItem(icon: "checkmark.shield",
                                    tint: DSKernel.isSystemVersionSupported() ? .green : .red,
                                    label: "支持情况",
                                    value: DSKernel.supportSummary(),
                                    monospaced: false))
        items.append(DeviceInfoItem(icon: "shield", tint: .blue, label: "内核基址",
                                    value: kernelBaseText, monospaced: true))
        items.append(DeviceInfoItem(icon: "person.fill",
                                    tint: kernel.isRoot ? .green : .secondary,
                                    label: "当前身份",
                                    value: kernel.isRoot ? "root（uid 0）" : "mobile（uid 501）",
                                    monospaced: false))
        items.append(DeviceInfoItem(icon: "bolt.fill",
                                    tint: DSKernel.isExploitDone() ? .green : .secondary,
                                    label: "内核读写",
                                    value: DSKernel.isExploitDone() ? "已拿到（本次运行有效）" : "还没拿到",
                                    monospaced: false))
        items.append(DeviceInfoItem(icon: "lock.open.fill",
                                    tint: DSKernel.isEscaped() ? .green : .secondary,
                                    label: "沙盒逃逸",
                                    value: DSKernel.isEscaped() ? "已逃逸，可访问整机文件" : "未逃逸，只能访问自己的沙盒",
                                    monospaced: false))
        return items
    }

    private var kernelBaseText: String {
        if kernel.kernelBase == 0 {
            return "—"
        }
        return String(format: "0x%llx", kernel.kernelBase)
    }

    private var recentLines: [DSLogLine] {
        let all = log.lines
        if all.count <= Self.maxVisibleLogLines {
            return all
        }
        return Array(all.suffix(Self.maxVisibleLogLines))
    }

    private var logFileSubtitle: String {
        guard let url = log.logFileURL else {
            return "本次会话的日志文件还没生成"
        }
        return url.lastPathComponent
    }

    private func levelColor(_ level: DSLogLevel) -> Color {
        switch level {
        case .info:
            return .primary
        case .warn:
            return .orange
        case .error:
            return .red
        case .kernel:
            return .teal
        }
    }

    // MARK: - 动作

    private func presentAlert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        alertVisible = true
    }

    private func copyDiagnostics() {
        UIPasteboard.general.string = DSKernel.diagnosticsText()
        DSLog.shared.info("已复制诊断信息到剪贴板", source: "设置")
        presentAlert("诊断信息已复制", "现在可以直接粘贴到聊天窗口或备忘录里。")
    }

    private func shareDiagnostics() {
        let text = DSKernel.diagnosticsText()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("myfilza-诊断.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            DSLog.shared.error("导出诊断信息失败：\(error.localizedDescription)", source: "设置")
            presentAlert("导出失败", error.localizedDescription)
            return
        }
        DSLog.shared.info("导出诊断信息到 \(url.path)", source: "设置")
        DSPickers.presentShareSheet(urls: [url])
    }

    private func shareLogFile() {
        guard let url = log.logFileURL else {
            presentAlert("日志文件还没准备好", "本次会话的日志文件尚未创建，稍后再试。")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentAlert("日志文件不存在", "找不到 \(url.lastPathComponent)，可能已经被清理掉了。")
            return
        }
        DSLog.shared.info("分享日志文件 \(url.lastPathComponent)", source: "设置")
        DSPickers.presentShareSheet(urls: [url])
    }

    private func probeFilesystem() {
        if DSKernel.probeFilesystemAccess() {
            DSLog.shared.info("现场自检通过：沙盒外读写可用", source: "设置")
            presentAlert("自检通过", "刚刚在沙盒外成功写入并删除了一笔探针文件，当前可以读写整机文件。")
        } else {
            DSLog.shared.warn("现场自检没通过：沙盒外读写不可用", source: "设置")
            presentAlert("自检没通过", "这次探针写盘失败了。如果状态显示「已激活」，可以先点「重试沙盒改写」，或者试一次「提权到 root」。")
        }
    }

    private func clearLog() {
        DSLog.shared.clear()
        DSLog.shared.info("界面日志已清空", source: "设置")
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let last = recentLines.last else { return }
        if animated {
            withAnimation(.linear(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

// MARK: - 行模型

private struct DeviceInfoItem: Identifiable {
    var icon: String
    var tint: Color
    var label: String
    var value: String
    var monospaced: Bool
    var id: String { label }
}

// MARK: - 信息行（28pt 图标 + 标题 + 元信息）

private struct InfoRow: View {

    var icon: String
    var tint: Color
    var title: String
    var detail: String? = nil
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                if let detail = detail, !detail.isEmpty {
                    Text(detail)
                        .font(monospaced ? Font.system(.caption2, design: .monospaced) : Font.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(monospaced ? 1 : nil)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }
}
