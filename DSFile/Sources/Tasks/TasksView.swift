//
//  TasksView.swift — 「记录」页：运行历史 + 备份（可一键回滚）
//
//  数据全部来自 RunStore（内存里的两个数组是只读的，只能通过它的方法增删）。
//  页面结构：NavigationView → Picker 分两段 → 运行历史 / 备份。
//  目标 iOS 15：不用 NavigationStack / ShareLink / ContentUnavailableView 等新 API。
//

import SwiftUI
import Foundation
import UIKit

// MARK: - 分段

/// 「记录」页的两个分段
private enum RecordSection: String, CaseIterable, Identifiable {
    case runs
    case backups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runs: return "运行历史"
        case .backups: return "备份"
        }
    }
}

// MARK: - 待确认删除的条目（Identifiable 便于 confirmationDialog 读文案）

private struct RunToDelete: Identifiable {
    let id: String
    let name: String

    init(_ record: RunRecord) {
        self.id = record.id
        self.name = record.scriptName
    }
}

private struct BackupToDelete: Identifiable {
    let id: String
    let count: Int

    init(_ record: BackupRecord) {
        self.id = record.id
        self.count = record.entries.count
    }
}

// MARK: - 记录页

struct TasksView: View {

    @ObservedObject private var store = RunStore.shared

    @State private var section: RecordSection = .runs
    @State private var runToDelete: RunToDelete?
    @State private var backupToDelete: BackupToDelete?

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("", selection: $section) {
                        ForEach(RecordSection.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                content
            }
            .listStyle(.insetGrouped)
            .navigationTitle("记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        store.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新")
                }
            }
            .confirmationDialog(
                runToDelete.map { "确定删除「\($0.name)」这条运行记录？" } ?? "",
                isPresented: runDeleteBinding,
                titleVisibility: .visible
            ) {
                Button("删除记录", role: .destructive) { performRunDelete() }
                Button("取消", role: .cancel) { runToDelete = nil }
            } message: {
                Text("日志文件会一起删掉，操作不可撤销。")
            }
            .confirmationDialog(
                backupToDelete.map { "确定删除这个备份（\($0.count) 项）？" } ?? "",
                isPresented: backupDeleteBinding,
                titleVisibility: .visible
            ) {
                Button("删除备份", role: .destructive) { performBackupDelete() }
                Button("取消", role: .cancel) { backupToDelete = nil }
            } message: {
                Text("备份目录会被整份移除，之后无法再回滚这次改动。")
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 分段内容

    @ViewBuilder
    private var content: some View {
        switch section {
        case .runs:
            runsContent
        case .backups:
            backupsContent
        }
    }

    @ViewBuilder
    private var runsContent: some View {
        if store.runs.isEmpty {
            emptyStateRow(
                icon: "clock.arrow.circlepath",
                title: "还没有运行记录",
                detail: "到「脚本」页选一个脚本跑一次，这里会留下完整记录"
            )
        } else {
            Section {
                ForEach(store.runs) { record in
                    runRow(record)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                runToDelete = RunToDelete(record)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var backupsContent: some View {
        if store.backups.isEmpty {
            emptyStateRow(
                icon: "archivebox",
                title: "还没有备份",
                detail: "执行脚本前会自动备份被覆盖的文件，这里可以一键还原"
            )
        } else {
            Section {
                ForEach(store.backups) { record in
                    NavigationLink(destination: BackupDetailView(record: record)) {
                        backupRow(record)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            backupToDelete = BackupToDelete(record)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: 行

    private func runRow(_ record: RunRecord) -> some View {
        NavigationLink(destination: RunDetailView(record: record)) {
            HStack(spacing: 12) {
                Image(systemName: record.statusIconName)
                    .font(.title3)
                    .foregroundColor(record.statusColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.scriptName)
                        .font(.subheadline)
                        .lineLimit(1)

                    Text(Self.dateText(record.date))
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(record.targetSummary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)
            }
        }
    }

    private func backupRow(_ record: BackupRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox.fill")
                .font(.title3)
                .foregroundColor(record.restoredAt == nil ? .secondary : .green)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.id)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(Self.dateText(record.createdAt)) · \(record.sizeString) · \(record.entries.count) 项")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if record.restoredAt != nil {
                    Text("已回滚过")
                        .font(.footnote)
                        .foregroundColor(.green)
                }
            }

            Spacer(minLength: 4)
        }
    }

    private func emptyStateRow(icon: String, title: String, detail: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)

                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 32)
            Spacer(minLength: 0)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: 删除绑定（confirmationDialog 需要 Binding<Bool>）

    private var runDeleteBinding: Binding<Bool> {
        Binding(
            get: { runToDelete != nil },
            set: { newValue in if !newValue { runToDelete = nil } }
        )
    }

    private var backupDeleteBinding: Binding<Bool> {
        Binding(
            get: { backupToDelete != nil },
            set: { newValue in if !newValue { backupToDelete = nil } }
        )
    }

    private func performRunDelete() {
        guard let target = runToDelete else { return }
        if let record = store.runs.first(where: { $0.id == target.id }) {
            store.deleteRun(record)
            DSLog.shared.info("删除运行记录 \(record.id)", source: "记录")
        }
        runToDelete = nil
    }

    private func performBackupDelete() {
        guard let target = backupToDelete else { return }
        if let record = store.backups.first(where: { $0.id == target.id }) {
            store.deleteBackup(record)
        }
        backupToDelete = nil
    }

    // MARK: 工具

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 统一格式化日期（iOS 15 上 DateFormatter 最稳）
    static func dateText(_ date: Date) -> String {
        return dateFormatter.string(from: date)
    }
}

// MARK: - 运行记录详情

private struct RunDetailView: View {

    let record: RunRecord

    @ObservedObject private var store = RunStore.shared

    /// 日志文本：优先从落盘的 log 文件读，读不到就用 summary 兜底
    private var logContent: String {
        let text = store.logText(for: record)
        if !text.isEmpty { return text }
        return record.summary.isEmpty ? "（这次运行没有留下日志）" : record.summary
    }

    var body: some View {
        List {
            Section {
                detailRow(label: "结果", value: record.statusText, tint: record.statusColor)
                detailRow(label: "时间", value: TasksView.dateText(record.date))
                detailRow(label: "脚本类型", value: record.scriptKind)
                detailRow(label: "预演", value: record.dryRun ? "是（只检查，未改动文件）" : "否")
                detailRow(label: "目标", value: record.targetSummary)
                detailRow(label: "关联备份", value: record.backupId ?? "无")
            }

            if !record.summary.isEmpty {
                Section(header: Text("结果摘要")) {
                    Text(record.summary)
                        .font(.footnote)
                }
            }

            Section(header: Text("日志")) {
                logView
            }

            Section {
                shareButton
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("运行详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 子视图

    private var logView: some View {
        ScrollView(.vertical) {
            Text(logContent)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(6)
        }
        .frame(minHeight: 200, maxHeight: 320)
    }

    private var shareButton: some View {
        Button {
            shareLog()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                Text("分享日志")
            }
            .frame(maxWidth: .infinity)
            .font(.body.weight(.semibold))
        }
    }

    private func detailRow(label: String, value: String, tint: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.subheadline)
                .foregroundColor(tint ?? .primary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: 分享日志

    private func shareLog() {
        let directory = NSTemporaryDirectory()
        let path = (directory as NSString).appendingPathComponent("\(record.id).log")
        let url = URL(fileURLWithPath: path)

        do {
            try logContent.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            DSLog.shared.warn("写日志临时文件失败：\(error.localizedDescription)", source: "记录")
            return
        }

        // 分享面板必须在主线程弹
        DispatchQueue.main.async {
            DSPickers.presentShareSheet(urls: [url])
        }
    }
}

// MARK: - 备份详情

private struct BackupDetailView: View {

    let record: BackupRecord

    @ObservedObject private var store = RunStore.shared

    @State private var showRestoreConfirm = false
    @State private var isRestoring = false
    @State private var alertMessage: String?

    var body: some View {
        List {
            Section(header: Text("概要")) {
                infoRow(label: "时间", value: TasksView.dateText(record.createdAt))
                infoRow(label: "脚本", value: record.scriptName)
                infoRow(label: "备份 ID", value: record.id)
                infoRow(label: "目标", value: record.targetSummary)
                infoRow(label: "占用", value: "\(record.sizeString) · \(record.entries.count) 项")

                if let restoredAt = record.restoredAt {
                    infoRow(label: "上次回滚", value: TasksView.dateText(restoredAt), tint: .green)
                }
            }

            Section(header: Text("包含的文件（\(record.entries.count) 项）")) {
                if record.entries.isEmpty {
                    Text("这份备份里没有登记文件")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    entryList
                }
            }

            Section {
                restoreButton
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("备份详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "回滚这次改动？",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("回滚", role: .destructive) { startRestore() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("会把备份里的原件覆盖回原路径；脚本新建的文件会被删除。当前这些位置上的内容会被覆盖，操作不可撤销。")
        }
        .alert(isPresented: alertBinding) {
            Alert(
                title: Text("回滚结果"),
                message: Text(alertMessage ?? ""),
                dismissButton: .default(Text("好"))
            )
        }
    }

    // MARK: 子视图

    private var entryList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(record.entries) { entry in
                    entryRow(entry)
                    if entry.id != record.entries.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 120, maxHeight: 320)
    }

    private func entryRow(_ entry: BackupEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.existed ? "doc.fill" : "plus.circle.fill")
                .font(.footnote)
                .foregroundColor(entry.existed ? .secondary : .green)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.originalPath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(entryMeta(entry))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var restoreButton: some View {
        HStack(spacing: 10) {
            if isRestoring {
                ProgressView()
            }

            Button {
                showRestoreConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                    Text(isRestoring ? "正在回滚…" : "回滚这次改动")
                        .font(.body.weight(.semibold))
                }
                .foregroundColor(.red)
                .frame(maxWidth: .infinity)
            }
            .disabled(isRestoring)
        }
    }

    private func infoRow(label: String, value: String, tint: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.subheadline)
                .foregroundColor(tint ?? .primary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: 回滚

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { newValue in if !newValue { alertMessage = .none } }
        )
    }

    private func entryMeta(_ entry: BackupEntry) -> String {
        let kind = entry.existed ? "原件" : "新建"
        var parts: [String] = [kind]
        if let mode = entry.mode, !mode.isEmpty {
            parts.append("mode \(mode)")
        }
        if let uid = entry.uid, let gid = entry.gid {
            parts.append("uid \(uid):\(gid)")
        }
        return parts.joined(separator: " · ")
    }

    /// 回滚在后台队列跑（要拷文件、可能很慢），结果回主线程更新 UI
    private func startRestore() {
        guard !isRestoring else { return }
        isRestoring = true

        let target = record
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String
            do {
                let restored = try RunStore.shared.restore(target)
                DSLog.shared.info("回滚备份 \(target.id)，恢复 \(restored) 项", source: "记录")
                message = "已恢复 \(restored) 项"
            } catch {
                DSLog.shared.error("回滚失败：\(error.localizedDescription)", source: "记录")
                message = error.localizedDescription
            }

            DispatchQueue.main.async {
                isRestoring = false
                store.reload()
                alertMessage = .some(message)
            }
        }
    }
}

// MARK: - RunRecord 的展示辅助（只在本文件内使用）

private extension RunRecord {

    var statusIconName: String {
        if dryRun { return "eye.circle.fill" }
        return success ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    var statusColor: Color {
        if dryRun { return .orange }
        return success ? .green : .red
    }

    var statusText: String {
        if dryRun { return "预演" }
        return success ? "成功" : "失败"
    }
}
