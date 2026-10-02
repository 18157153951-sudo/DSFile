//
//  DSLog.swift — 会话日志（界面里滚动显示 + 同步落盘，设备重启后还能捞）
//

import Foundation
import Combine

enum DSLogLevel: String {
    case info
    case warn
    case error
    case kernel

    var label: String {
        switch self {
        case .info: return "信息"
        case .warn: return "警告"
        case .error: return "错误"
        case .kernel: return "内核"
        }
    }
}

struct DSLogLine: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: DSLogLevel
    let source: String
    let text: String

    var displayText: String {
        let formatter = DSLog.timeFormatter
        return "\(formatter.string(from: date))  \(text)"
    }
}

final class DSLog: ObservableObject {

    static let shared = DSLog()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    @Published private(set) var lines: [DSLogLine] = []
    @Published private(set) var logFileURL: URL?

    private let writeQueue = DispatchQueue(label: "com.dsfile.log.write")
    private var fileHandle: FileHandle?
    private let maxLines = 4000

    private init() {
        openSessionFile()
    }

    // MARK: - 对外接口

    func info(_ text: String, source: String = "DSFile") { add(text, level: .info, source: source) }
    func warn(_ text: String, source: String = "DSFile") { add(text, level: .warn, source: source) }
    func error(_ text: String, source: String = "DSFile") { add(text, level: .error, source: source) }
    func kernel(_ text: String) { add(text, level: .kernel, source: "DarkSword") }

    func add(_ text: String, level: DSLogLevel, source: String) {
        let stamp = Date()
        let parts = text.components(separatedBy: "\n")
        var newLines: [DSLogLine] = []
        for part in parts where !part.isEmpty {
            newLines.append(DSLogLine(date: stamp, level: level, source: source, text: part))
        }
        guard !newLines.isEmpty else { return }

        let payload = newLines.map { line -> String in
            "[\(DSLog.timeFormatter.string(from: line.date))][\(line.level.rawValue)][\(line.source)] \(line.text)\n"
        }.joined()

        writeQueue.async { [weak self] in
            guard let self = self, let handle = self.fileHandle else { return }
            if let data = payload.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lines.append(contentsOf: newLines)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { self.lines.removeAll() }
    }

    var plainText: String {
        return lines.map { "[\(DSLog.timeFormatter.string(from: $0.date))][\($0.level.rawValue)] \($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: - 落盘

    private func openSessionFile() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("Logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("session-\(formatter.string(from: Date())).log")
        fm.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        logFileURL = url

        writeQueue.async { [weak self] in
            guard let self = self, let handle = self.fileHandle else { return }
            let header = "=== DSFile 会话日志 \(Date()) ===\n"
            if let data = header.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }

    func closeFile() {
        writeQueue.sync {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }
}
