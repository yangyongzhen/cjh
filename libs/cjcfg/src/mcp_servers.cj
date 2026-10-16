package cjcfg

import std.collection.*
import stdx.encoding.json.*

/**
 * MCP 服务器配置的解析 / 序列化 / 脱敏（settings.json "mcp_servers" 段）
 *
 * 两种形态：
 *   - 对象形态（settings.json 落盘）：{ "<name>": {transport, command, args, url, env}, ... }
 *   - 数组形态（Web API 传输）：     [ {name, transport, command, args, url, env}, ... ]
 *
 * 校验失败一律返回 (空列表, 可读错误)，**不抛异常**——Web 层据此回 {"ok":false,"error":...}；
 * 这样 `POST /api/settings` 能在写盘前整体拒绝无效配置，不会落半截配置。
 */

/**
 * 解析 Web 侧提交的 mcpServers（数组形态）。返回 (列表, 错误)；成功时错误为 ""。
 *
 * 校验规则：必须是数组；每项必须是对象且 name 非空唯一；transport 仅 stdio/sse（缺省 stdio）；
 * stdio 必须有 command，sse 必须有 url。
 */
public func parseMcpServersJson(v: JsonValue): (ArrayList<McpServerConfig>, String) {
    let empty = ArrayList<McpServerConfig>()
    match (v.kind()) {
        case JsonKind.JsArray => ()
        case _ => return (empty, "mcpServers 必须是数组：[{name, transport, command/url, ...}]")
    }
    let arr = v.asArray()
    let list = ArrayList<McpServerConfig>()
    let seenNames = ArrayList<String>()
    for (i in 0..arr.size()) {
        let item = match (arr.get(i)) {
            case Some(x) => x
            case None => return (empty, "第 ${i + 1} 项缺失")
        }
        match (item.kind()) {
            case JsonKind.JsObject => ()
            case _ => return (empty, "第 ${i + 1} 项必须是对象")
        }
        let o = item.asObject()
        var name = ""
        if (let Some(n) <- o.get("name")) {
            match (n.kind()) {
                case JsonKind.JsString => name = n.asString().getValue()
                case _ => ()
            }
        }
        if (name.size == 0) {
            return (empty, "第 ${i + 1} 项缺少非空 name")
        }
        var dup = false
        for (j in 0..seenNames.size) {
            if (seenNames[j] == name) {
                dup = true
            }
        }
        if (dup) {
            return (empty, "服务器名重复: ${name}")
        }
        seenNames.add(name)
        let cfg = McpServerConfig(name)
        // transport（缺省 stdio）
        var transport = "stdio"
        if (let Some(t) <- o.get("transport")) {
            match (t.kind()) {
                case JsonKind.JsString => transport = t.asString().getValue()
                case _ => ()
            }
        }
        if (transport != "stdio" && transport != "sse") {
            return (empty, "${name}: 非法 transport '${transport}'（仅支持 stdio / sse）")
        }
        cfg.transport = transport
        // command（stdio 启动命令）
        if (let Some(c) <- o.get("command")) {
            match (c.kind()) {
                case JsonKind.JsString => cfg.command = c.asString().getValue()
                case _ => ()
            }
        }
        // args（命令参数数组）
        if (let Some(a) <- o.get("args")) {
            match (a.kind()) {
                case JsonKind.JsArray =>
                    let argsArr = a.asArray()
                    for (k in 0..argsArr.size()) {
                        match (argsArr.get(k)) {
                            case Some(argItem) =>
                                match (argItem.kind()) {
                                    case JsonKind.JsString => cfg.args.add(argItem.asString().getValue())
                                    case _ => ()
                                }
                            case None => ()
                        }
                    }
                case _ => ()
            }
        }
        // url（sse 远端）
        if (let Some(u) <- o.get("url")) {
            match (u.kind()) {
                case JsonKind.JsString => cfg.url = u.asString().getValue()
                case _ => ()
            }
        }
        // env（子进程环境变量）
        if (let Some(e) <- o.get("env")) {
            match (e.kind()) {
                case JsonKind.JsObject =>
                    for ((k, vv) in e.asObject().getFields()) {
                        match (vv.kind()) {
                            case JsonKind.JsString => cfg.env.add(k, vv.asString().getValue())
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        }
        // 传输相关必填项
        if (transport == "stdio" && cfg.command.size == 0) {
            return (empty, "${name}: stdio 传输必须提供 command")
        }
        if (transport == "sse" && cfg.url.size == 0) {
            return (empty, "${name}: sse 传输必须提供 url")
        }
        list.add(cfg)
    }
    return (list, "")
}

/**
 * 序列化为数组形态（Web API 用）。maskEnv=true 时 env 值以 *** 占位（避免密钥回显）。
 */
public func mcpServersToJsonArray(list: ArrayList<McpServerConfig>, maskEnv: Bool): JsonArray {
    let arr = JsonArray()
    for (i in 0..list.size) {
        let s = list[i]
        let o = JsonObject()
        o.put("name", JsonString(s.name))
        o.put("transport", JsonString(s.transport))
        o.put("command", JsonString(s.command))
        let argsArr = JsonArray()
        for (j in 0..s.args.size) {
            argsArr.add(JsonString(s.args[j]))
        }
        o.put("args", argsArr)
        o.put("url", JsonString(s.url))
        let envObj = JsonObject()
        for ((k, v) in s.env) {
            let shown = if (maskEnv) { "***" } else { v }
            envObj.put(k, JsonString(shown))
        }
        o.put("env", envObj)
        arr.add(o)
    }
    return arr
}

/**
 * 序列化为对象形态（settings.json "mcp_servers" 段，{name: {...}}），env 保留原值。
 */
public func mcpServersToJsonObject(list: ArrayList<McpServerConfig>): JsonObject {
    let root = JsonObject()
    for (i in 0..list.size) {
        let s = list[i]
        let o = JsonObject()
        o.put("transport", JsonString(s.transport))
        o.put("command", JsonString(s.command))
        let argsArr = JsonArray()
        for (j in 0..s.args.size) {
            argsArr.add(JsonString(s.args[j]))
        }
        o.put("args", argsArr)
        o.put("url", JsonString(s.url))
        let envObj = JsonObject()
        for ((k, v) in s.env) {
            envObj.put(k, JsonString(v))
        }
        o.put("env", envObj)
        root.put(s.name, o)
    }
    return root
}
