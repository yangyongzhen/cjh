package cjcfg

import std.collection.*
import stdx.encoding.json.*
import cjutil.*

/**
 * 能力安全检查决策
 */
public enum CapDecision {
    | Allow
    | Deny(String)
    | NeedApproval(String)
}

/**
 * 三域 capability 安全模型（v2 架构文档 4.2 节）
 *
 * settings.json 可选字段，未配置时 enabled=false（宽松：全部允许，保持向后兼容）：
 * ```json
 * "capability": {
 *   "identifier": "default",
 *   "commands": ["greet", "system:*"],        // bash 命令白名单（前缀匹配，支持 * 通配）
 *   "tools":   ["bash", "read_file"],          // 工具白名单（未列出即拒绝）
 *   "resources": {
 *     "fs":  ["$HOME/project/" + "**", "!/tmp/secret/" + "**"],  // 文件路径 glob（! 前缀 = 排除，** 递归）
 *     "net": ["api.deepseek.com"],             // 网络白名单（预留）
 *     "proc": ["!rm", "!mkfs"]                 // 危险命令黑名单（! 前缀 = 禁止）
 *   },
 *   "approval": ["bash:write", "proc:*"]       // 需人工确认的操作
 * }
 * ```
 *
 * 原则：事前最小权限（非事后审批），未声明即拒绝；审批链对危险操作生效；
 * 模型独立于 LLM 层，任何 provider 都受同一安全边界约束。
 * （注：仓颉块注释内不能出现 斜杠+星号 的嵌套注释序列，示例 glob 已拆分书写）
 */
public class Capability {
    // 是否启用严格模式（settings.json 配置了 capability 字段才为 true）
    public var enabled: Bool = false
    public var identifier: String = "default"

    // 三域白名单
    public var commands: ArrayList<String> = ArrayList<String>()   // bash 命令白名单
    public var tools: ArrayList<String> = ArrayList<String>()      // 工具白名单
    public var fsAllow: ArrayList<String> = ArrayList<String>()    // 文件路径 glob 白名单
    public var fsDeny: ArrayList<String> = ArrayList<String>()     // 文件路径 glob 排除
    public var netAllow: ArrayList<String> = ArrayList<String>()   // 网络白名单（预留）
    public var procDeny: ArrayList<String> = ArrayList<String>()   // 危险命令黑名单（去掉 ! 后的命令名）

    // 审批链：需人工确认的操作标识（工具名 / "bash:write" / "proc:*" / "*:*"）
    public var approval: ArrayList<String> = ArrayList<String>()

    public init() {}

    /**
     * 从 settings.json 的 capability 字段解析；None 表示未配置（宽松模式）
     */
    public static func fromJson(json: Option<JsonValue>): Capability {
        let cap = Capability()
        if (json.isNone()) {
            // 未配置 capability 字段：宽松模式，全部放行
            return cap
        }
        let v = json.getOrThrow()
        match (v.kind()) {
            case JsonKind.JsObject =>
                let obj = v.asObject()
                // enabled 开关：默认 false（宽松模式全部放行）
                // 用户设 true 才启用严格模式（未声明即拒绝）
                if (let Some(en) <- obj.get("enabled")) {
                    match (en.kind()) {
                        case JsonKind.JsBool => cap.enabled = en.asBool().getValue()
                        case _ => ()
                    }
                }
                if (let Some(id) <- obj.get("identifier")) {
                    match (id.kind()) {
                        case JsonKind.JsString => cap.identifier = id.asString().getValue()
                        case _ => ()
                    }
                }
                cap.commands = parseStrArray(obj.get("commands"))
                cap.tools = parseStrArray(obj.get("tools"))
                // resources 对象
                if (let Some(res) <- obj.get("resources")) {
                    match (res.kind()) {
                        case JsonKind.JsObject =>
                            let ro = res.asObject()
                            cap.fsAllow = parseGlobArray(ro.get("fs"), false)
                            cap.fsDeny = parseGlobArray(ro.get("fs"), true)
                            cap.netAllow = parseStrArray(ro.get("net"))
                            cap.procDeny = parseGlobArray(ro.get("proc"), false)
                        case _ => ()
                    }
                }
                cap.approval = parseStrArray(obj.get("approval"))
            case _ => ()
        }
        return cap
    }

    /**
     * 解析字符串数组字段
     */
    private static func parseStrArray(field: Option<JsonValue>): ArrayList<String> {
        var list = ArrayList<String>()
        if (field.isNone()) {
            return list
        }
        let v = field.getOrThrow()
        match (v.kind()) {
            case JsonKind.JsArray =>
                let arr = v.asArray()
                for (i in 0..arr.size()) {
                    if (let Some(item) <- arr.get(i)) {
                        match (item.kind()) {
                            case JsonKind.JsString => list.add(item.asString().getValue())
                            case _ => ()
                        }
                    }
                }
            case _ => ()
        }
        return list
    }

    /**
     * 解析 glob 数组：! 前缀条目进 deny 列表，其余进 allow 列表（仅传 wantDeny 对应列表）
     */
    private static func parseGlobArray(field: Option<JsonValue>, wantDeny: Bool): ArrayList<String> {
        var list = ArrayList<String>()
        if (field.isNone()) {
            return list
        }
        let v = field.getOrThrow()
        match (v.kind()) {
            case JsonKind.JsArray =>
                let arr = v.asArray()
                for (i in 0..arr.size()) {
                    if (let Some(item) <- arr.get(i)) {
                        match (item.kind()) {
                            case JsonKind.JsString =>
                                let s = item.asString().getValue()
                                let isDeny = s.startsWith("!")
                                if (isDeny == wantDeny) {
                                    if (isDeny) {
                                        list.add(s[1..s.size])
                                    } else {
                                        list.add(s)
                                    }
                                }
                            case _ => ()
                        }
                    }
                }
            case _ => ()
        }
        return list
    }

    // ─── 检查接口 ─────────────────────────────────────────────

    /**
     * 工具域检查：白名单内允许；approval 命中的工具需审批；否则拒绝
     */
    public func checkTool(name: String): CapDecision {
        if (!this.enabled) {
            return CapDecision.Allow
        }
        for (t in this.tools) {
            if (t == name) {
                if (this.approvalHit(name, name)) {
                    return CapDecision.NeedApproval("工具 ${name} 需人工确认")
                }
                return CapDecision.Allow
            }
        }
        // 未列入白名单：若在 approval 中显式声明（如 "*:*" 或 "name:*"）则需审批，否则拒绝
        if (this.approvalHit(name, name)) {
            return CapDecision.NeedApproval("工具 ${name} 未列入白名单，需人工确认")
        }
        return CapDecision.Deny("工具 ${name} 不在 capability.tools 白名单（未声明即拒绝）")
    }

    /**
     * 命令域检查：bash 命令白名单 + 危险命令黑名单 + 审批
     */
    public func checkCommand(cmd: String): CapDecision {
        if (!this.enabled) {
            return CapDecision.Allow
        }
        // 危险命令黑名单（proc: ["!rm", "!mkfs"]）
        let first = firstToken(cmd)
        for (d in this.procDeny) {
            if (tokenMatch(first, d)) {
                return CapDecision.Deny("危险命令被禁止（capability.resources.proc: ${d}）")
            }
        }
        // 命令白名单（前缀匹配，支持 system:* 通配）
        for (c in this.commands) {
            if (tokenMatch(first, c)) {
                // 白名单命中：检查是否需审批（bash:write 写操作 / proc:* 全命令）
                if (this.approvalHit("bash", cmd)) {
                    return CapDecision.NeedApproval("命令需人工确认: ${cmd}")
                }
                return CapDecision.Allow
            }
        }
        // 未在白名单：approval 显式声明才可能放行
        if (this.approvalHit("bash", cmd)) {
            return CapDecision.NeedApproval("命令未列入白名单，需人工确认: ${cmd}")
        }
        return CapDecision.Deny("命令不在 capability.commands 白名单（未声明即拒绝）: ${cmd}")
    }

    /**
     * 资源域检查：文件路径 glob（fs）白名单 + 排除 + 审批
     * write=true 表示写操作（write_file）
     */
    public func checkPath(path: String, write: Bool): CapDecision {
        if (!this.enabled) {
            return CapDecision.Allow
        }
        let norm = normalizePath(path)
        // 排除规则优先
        for (d in this.fsDeny) {
            if (globMatch(d, norm) || globMatch(d, path)) {
                return CapDecision.Deny("路径被排除（capability.resources.fs: ${d}）: ${path}")
            }
        }
        // 白名单
        for (a in this.fsAllow) {
            if (globMatch(a, norm) || globMatch(a, path)) {
                if (write && this.approvalHit("fs:write", path)) {
                    return CapDecision.NeedApproval("写文件需人工确认: ${path}")
                }
                return CapDecision.Allow
            }
        }
        if (this.approvalHit("fs", path)) {
            return CapDecision.NeedApproval("文件操作需人工确认: ${path}")
        }
        return CapDecision.Deny("路径不在 capability.resources.fs 白名单（未声明即拒绝）: ${path}")
    }

    // ─── 内部：审批匹配 ───────────────────────────────────────

    /**
     * 审批命中：approval 条目匹配工具/操作。
     * rule 形式：精确工具名（write_file）、bash:write（bash 写类命令）、proc:*（bash 全命令）、*:*（全部）
     */
    private func approvalHit(domain: String, detail: String): Bool {
        for (rule in this.approval) {
            if (rule == "*:*") {
                return true
            }
            if (rule == domain) {
                return true
            }
            if (domain == "bash" && rule == "proc:*") {
                return true
            }
            if (domain == "bash" && rule == "bash:write") {
                if (isWriteCommand(detail)) {
                    return true
                }
            }
            if (rule == "${domain}:*") {
                return true
            }
        }
        return false
    }

    /**
     * 判断 shell 命令是否含写类操作（>、>>、tee、rm、mv、mkdir、touch、chmod 等）
     */
    private static func isWriteCommand(cmd: String): Bool {
        let lower = cmd
        let tokens = [" > ", " >> ", "> ", ">>", " tee ", " rm ", " mv ", " mkdir", " touch ", " chmod ", " chown ", " dd ", " mkfs", " echo "]
        for (t in tokens) {
            if (lower.contains(t)) {
                return true
            }
        }
        return false
    }

    // ─── 内部：token / 路径 / glob 匹配 ───────────────────────

    /**
     * 取命令第一个 token（命令名）
     */
    private static func firstToken(cmd: String): String {
        let parts = cmd.trimAscii().split(" ", -1)
        if (parts.size > 0 && parts[0].size > 0) {
            return parts[0]
        }
        return cmd.trimAscii()
    }

    /**
     * token 匹配规则：精确相等，或规则含 * 时按 glob 匹配
     */
    private static func tokenMatch(token: String, rule: String): Bool {
        if (rule.contains("*")) {
            return globMatch(rule, token)
        }
        return token == rule
    }

    /**
     * 路径规范化：展开 $HOME / ~ 前缀
     */
    private static func normalizePath(path: String): String {
        if (path.startsWith("$HOME")) {
            let home = EnvFfi.homeDir()
            return home + path[5..path.size]
        }
        if (path.startsWith("~/")) {
            let home = EnvFfi.homeDir()
            return home + path[1..path.size]
        }
        return path
    }

    /**
     * glob 匹配：支持 *（不跨 /）、**（跨 /）、?（单字符）。
     * 递归实现，pattern/text 均按字节索引（String 索引得 Byte，与项目既有约定一致）。
     */
    public static func globMatch(pattern: String, text: String): Bool {
        return globAt(pattern, 0, text, 0)
    }

    private static func globAt(pat: String, pi: Int64, text: String, ti: Int64): Bool {
        let plen = pat.size
        let tlen = text.size
        if (pi >= plen) {
            return ti >= tlen
        }
        let pc = pat[pi]
        if (pc == 42u8) {  // '*'
            // '**'：跨目录任意匹配（含空）
            if (pi + 1 < plen && pat[pi + 1] == 42u8) {
                // 跳过连续的 **
                var np = pi + 2
                while (np < plen && pat[np] == 42u8) {
                    np += 1
                }
                // ** 后紧跟 / 时，允许整体跳过该段（如 a/**/b 匹配 a/b）
                if (np < plen && pat[np] == 47u8) {
                    np += 1
                }
                var j = ti
                while (j <= tlen) {
                    if (globAt(pat, np, text, j)) {
                        return true
                    }
                    j += 1
                }
                return false
            }
            // '*'：匹配任意数量的非 / 字符
            var j = ti
            while (j <= tlen) {
                if (globAt(pat, pi + 1, text, j)) {
                    return true
                }
                if (j < tlen && text[j] == 47u8) {
                    break
                }
                j += 1
            }
            return false
        }
        // '/**' 结尾（或 / ** 形态）：目录自身也算匹配（a/** 匹配 a 和 a/x）
        if (pc == 47u8 && pi + 2 < plen && pat[pi + 1] == 42u8 && pat[pi + 2] == 42u8) {
            var np = pi + 3
            while (np < plen && pat[np] == 42u8) {
                np += 1
            }
            if (np < plen && pat[np] == 47u8) {
                np += 1
            }
            var j = ti
            while (j <= tlen) {
                if (globAt(pat, np, text, j)) {
                    return true
                }
                j += 1
            }
            return false
        }
        if (ti >= tlen) {
            return false
        }
        if (pc == 63u8) {  // '?'
            return globAt(pat, pi + 1, text, ti + 1)
        }
        if (pc == text[ti]) {
            return globAt(pat, pi + 1, text, ti + 1)
        }
        return false
    }
}
