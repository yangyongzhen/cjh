package cjh.tools

import std.collection.*
import std.fs.*
import cjutil.*

/**
 * V3 信任链 Step 3：信任列表管理（可信发布者）
 *
 * 信任列表文件：<configDir>/trusted-publishers（~/.cjh/trusted-publishers）
 *   - 每行一个条目：publisher ID（如 "github:alice"）或 SM2 公钥 hex
 *   - 空行忽略，# 开头为注释
 *
 * 信任语义：
 *   - 空列表（文件不存在或无有效行）= 开放模式：不做信任检查（默认，向后兼容）
 *   - 非空列表 = 严格模式：签名插件的 publisher/pubkey 必须命中列表，
 *     否则拒绝加载；无签名插件同样拒绝（否则信任形同虚设）
 *
 * CLI（main.cj 分发，逻辑在本文件可单测）：
 *   cjh trust <publisher>     信任发布者（追加到文件）
 *   cjh untrust <publisher>   取消信任（移除对应行）
 *   cjh trust-list            列出已信任条目
 */

/**
 * 信任操作结果
 */
public enum TrustResult {
    | Added             // 新增成功
    | AlreadyTrusted    // 已在信任列表中
    | Removed           // 移除成功
    | NotTrusted        // 不在信任列表中（未做修改）
    | EmptyEntry        // 条目为空
}

/**
 * 信任列表文件路径
 */
public func trustListPath(configDir: String): String {
    return configDir + "/trusted-publishers"
}

/**
 * 解析信任列表文本：跳过空行与 # 注释，trim 每行
 */
public func parseTrustList(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (line in text.split("\n", -1)) {
        let t = line.trimAscii()
        if (t.size == 0 || t.startsWith("#")) {
            continue
        }
        out.add(t)
    }
    return out
}

/**
 * 读取信任列表（文件不存在返回空列表 = 开放模式）
 */
public func readTrustList(path: String): ArrayList<String> {
    if (!exists(path)) {
        return ArrayList<String>()
    }
    return parseTrustList(safeFromUtf8(File.readFrom(path)))
}

/**
 * 写回信任列表（覆盖写，保留注释头）
 */
public func writeTrustList(path: String, entries: ArrayList<String>): Unit {
    var sb = StringBuilder()
    sb.append("# cjh trusted publishers (one per line; # for comments)\n")
    sb.append("# 空列表 = 开放模式；非空 = 严格模式（见 docs/插件签名与贡献指南.md）\n")
    for (e in entries) {
        sb.append(e)
        sb.append("\n")
    }
    File.writeTo(path, sb.toString().toArray())
}

/**
 * 信任发布者（幂等：已存在返回 AlreadyTrusted）
 */
public func trustAdd(path: String, entry: String): TrustResult {
    let e = entry.trimAscii()
    if (e.size == 0) {
        return TrustResult.EmptyEntry
    }
    let list = readTrustList(path)
    if (list.contains(e)) {
        return TrustResult.AlreadyTrusted
    }
    list.add(e)
    writeTrustList(path, list)
    return TrustResult.Added
}

/**
 * 取消信任（幂等：不存在返回 NotTrusted）
 */
public func trustRemove(path: String, entry: String): TrustResult {
    let e = entry.trimAscii()
    if (e.size == 0) {
        return TrustResult.EmptyEntry
    }
    let list = readTrustList(path)
    if (!list.contains(e)) {
        return TrustResult.NotTrusted
    }
    let out = ArrayList<String>()
    for (item in list) {
        if (item != e) {
            out.add(item)
        }
    }
    writeTrustList(path, out)
    return TrustResult.Removed
}

/**
 * 判断插件是否命中信任列表：publisher ID 或 SM2 公钥 hex 任一匹配即可
 */
public func isTrusted(list: ArrayList<String>, publisher: String, pubkeyHex: String): Bool {
    if (publisher.size > 0 && list.contains(publisher)) {
        return true
    }
    if (pubkeyHex.size > 0 && list.contains(pubkeyHex)) {
        return true
    }
    return false
}
