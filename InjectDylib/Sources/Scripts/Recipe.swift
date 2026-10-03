//
//  Recipe.swift — 配方脚本（JSON）模型与占位符解析
//
//  配方文件放在：Documents/Scripts/<脚本目录>/recipe.json
//  payload 放在：Documents/Scripts/<脚本目录>/payload/
//

import Foundation

// MARK: - 配方

struct ScriptRecipe: Codable {

    struct TargetSpec: Codable {
        var bundleId: String?
        var bundlePath: String?
        var dataPath: String?
    }

    struct Options: Codable {
        var backup: Bool
        var killTarget: Bool
        var stopOnError: Bool
        var fixOwnership: Bool

        init(backup: Bool = true,
             killTarget: Bool = true,
             stopOnError: Bool = true,
             fixOwnership: Bool = true) {
            self.backup = backup
            self.killTarget = killTarget
            self.stopOnError = stopOnError
            self.fixOwnership = fixOwnership
        }

        /// 缺字段时按「安全默认」补齐：备份开、结束目标开、出错即停开、自动修属主开
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            backup = try container.decodeIfPresent(Bool.self, forKey: .backup) ?? true
            killTarget = try container.decodeIfPresent(Bool.self, forKey: .killTarget) ?? true
            stopOnError = try container.decodeIfPresent(Bool.self, forKey: .stopOnError) ?? true
            fixOwnership = try container.decodeIfPresent(Bool.self, forKey: .fixOwnership) ?? true
        }

        static var `default`: Options { Options() }
    }

    struct Step: Codable {
        /// replace / copy / move / replaceDir / mkdir / delete / chmod / chown / kill / note
        var op: String
        var source: String?
        var dest: String?
        var mode: String?
        var owner: String?
        var note: String?
        /// 目标不存在时不报错
        var optional: Bool?
    }

    var schema: Int?
    var name: String?
    var note: String?
    var target: TargetSpec?
    var options: Options?
    var steps: [Step]

    var displayName: String { name ?? "未命名配方" }
    var effectiveOptions: Options {
        return options ?? .default
    }

    static func decode(from data: Data) throws -> ScriptRecipe {
        let decoder = JSONDecoder()
        return try decoder.decode(ScriptRecipe.self, from: data)
    }

    static let template = """
    {
      "schema": 1,
      "name": "示例：替换目标 App 的一个资源文件",
      "note": "把 payload 里的文件覆盖到目标 App 里；跑之前会先自动备份。",
      "target": { "bundleId": "com.example.target" },
      "options": { "backup": true, "killTarget": true, "stopOnError": true, "fixOwnership": true },
      "steps": [
        { "op": "replace", "source": "payload/config.json", "dest": "{app.data}/Documents/config.json" },
        { "op": "replace", "source": "payload/AppIcon60x60@2x.png", "dest": "{app.bundle}/AppIcon60x60@2x.png" },
        { "op": "chmod", "dest": "{app.data}/Documents/config.json", "mode": "0644" },
        { "op": "kill" }
      ]
    }
    """
}

// MARK: - 目标

struct ResolvedTarget {
    let bundleId: String
    let name: String
    let bundlePath: String
    let dataPath: String
    let executableName: String

    var executablePath: String {
        executableName.isEmpty ? bundlePath : bundlePath + "/" + executableName
    }

    var summary: String {
        "\(name) · \(bundleId)"
    }
}

// MARK: - 占位符

enum PlaceholderResolver {

    /// 支持：{app.bundle} {app.data} {app.bundleId} {app.name} {app.executable}
    ///       {script.dir} {script.payload} {docs}
    static func expand(_ raw: String, target: ResolvedTarget?, scriptDirectory: String) -> String {
        var text = raw
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""

        let pairs: [(String, String)] = [
            ("{app.bundle}", target?.bundlePath ?? ""),
            ("{app.data}", target?.dataPath ?? ""),
            ("{app.bundleId}", target?.bundleId ?? ""),
            ("{app.name}", target?.name ?? ""),
            ("{app.executable}", target?.executablePath ?? ""),
            ("{script.dir}", scriptDirectory),
            ("{script.payload}", scriptDirectory + "/payload"),
            ("{docs}", docs)
        ]
        for (token, value) in pairs {
            text = text.replacingOccurrences(of: token, with: value)
        }
        return text
    }

    /// 相对路径（如 payload/a.png）解析到脚本目录；绝对路径原样返回
    static func resolvePath(_ raw: String, target: ResolvedTarget?, scriptDirectory: String) -> String {
        let expanded = expand(raw, target: target, scriptDirectory: scriptDirectory)
        if expanded.hasPrefix("/") { return expanded }
        if expanded.isEmpty { return expanded }
        return (scriptDirectory as NSString).appendingPathComponent(expanded)
    }

    static func usesTarget(_ raw: String?) -> Bool {
        guard let raw = raw else { return false }
        return raw.contains("{app.")
    }
}
