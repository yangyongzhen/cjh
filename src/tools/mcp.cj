package cjh.tools

/**
 * MCP 客户端（Model Context Protocol）
 *
 * 传输层：stdio（启动子进程，JSON-RPC over stdin/stdout）
 * 协议：JSON-RPC 2.0，每条消息一行（\n 分隔）
 *
 * 生命周期：
 *   1. connect()：启动子进程，发送 initialize 握手
 *   2. listTools()：发送 tools/list，解析工具列表
 *   3. callTool(name, args)：发送 tools/call，返回结果
 *   4. disconnect()：关闭子进程
 *
 * 配置参考：docs/插件系统实现方案.md § 8.2
 * 协议参考：https://modelcontextprotocol.io/specification/2025-03-26
 */

import std.collection.*
import std.process.*
import std.io.*
import stdx.encoding.json.*
import cjcfg.McpServerConfig
import cjllm.ToolSpec
import cjutil.*

/**
 * MCP 客户端：管理单个 MCP 服务器的连接和通信
 */
public class McpClient {
    private let config: McpServerConfig
    private var subProcess: ?SubProcess = None
    private var nextId: Int64 = 1
    // 已发现的工具列表（tools/list 结果）
    private var discoveredTools: ArrayList<McpToolDef> = ArrayList<McpToolDef>()

    public init(config: McpServerConfig) {
        this.config = config
    }

    /**
     * 连接 MCP 服务器
     * 1. 启动子进程
     * 2. 发送 initialize 握手
     * 3. 发送 initialized 通知
     * @return 连接成功返回 true，失败返回 false
     */
    public func connect(): Bool {
        if (this.config.transport != "stdio") {
            Log.warn("[MCP] 仅支持 stdio 传输，跳过 ${this.config.name}（transport=${this.config.transport}）")
            return false
        }
        if (this.config.command.size == 0) {
            Log.warn("[MCP] ${this.config.name} 缺少 command 字段")
            return false
        }

        // 启动子进程，设置 stdIn/stdOut/stdErr 为 Pipe
        var argv = Array<String>(this.config.args.size, repeat: "")
        for (i in 0..this.config.args.size) {
            argv[i] = this.config.args[i]
        }
        // 构建环境变量（继承当前进程 + config.env）
        var env = HashMap<String, String>()
        for ((k, v) in this.config.env) {
            env.add(k, v)
        }

        try {
            let sp = SubProcess.start(this.config.command, argv,
                stdIn: ProcessRedirect.Pipe,
                stdOut: ProcessRedirect.Pipe,
                stdErr: ProcessRedirect.Pipe,
                environment: env)
            this.subProcess = sp

            // 1. 发送 initialize 握手
            let initReq = this.buildRequest("initialize", this.initializeParams())
            if (!this.send(initReq)) {
                Log.warn("[MCP] ${this.config.name} 发送 initialize 失败")
                return false
            }
            let initResp = this.recv()
            match (initResp) {
                case Some(r) =>
                    // 验证握手响应（至少有 result 字段）
                    if (!r.containsKey("result")) {
                        Log.warn("[MCP] ${this.config.name} initialize 响应无 result 字段")
                        return false
                    }
                    Log.debug("[MCP] ${this.config.name} 握手成功")
                case None =>
                    Log.warn("[MCP] ${this.config.name} initialize 无响应")
                    return false
            }

            // 2. 发送 initialized 通知（notifications/initialized，无 id）
            let initNotif = this.buildNotification("notifications/initialized", JsonObject())
            this.send(initNotif)

            Log.info("[MCP] 已连接服务器: ${this.config.name}")
            return true
        } catch (e: Exception) {
            Log.warn("[MCP] 连接 ${this.config.name} 失败: ${e}")
            return false
        }
    }

    /**
     * 查询工具列表（tools/list）
     * @return 工具定义列表；失败返回空列表
     */
    public func listTools(): ArrayList<McpToolDef> {
        let req = this.buildRequest("tools/list", JsonObject())
        if (!this.send(req)) {
            Log.warn("[MCP] ${this.config.name} 发送 tools/list 失败")
            return ArrayList<McpToolDef>()
        }
        let resp = this.recv()
        match (resp) {
            case Some(r) =>
                match (r.get("result")) {
                    case Some(resultVal) =>
                        match (resultVal.kind()) {
                            case JsonKind.JsObject =>
                                let resultObj = resultVal.asObject()
                                match (resultObj.get("tools")) {
                                    case Some(toolsVal) =>
                                        match (toolsVal.kind()) {
                                            case JsonKind.JsArray =>
                                                let toolsArr = toolsVal.asArray()
                                                for (i in 0..toolsArr.size()) {
                                                    if (let Some(toolItem) <- toolsArr.get(i)) {
                                                        let toolDef = this.parseToolDef(toolItem)
                                                        if (toolDef.name.size > 0) {
                                                            this.discoveredTools.add(toolDef)
                                                        }
                                                    }
                                                }
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                            case _ => ()
                        }
                    case _ => ()
                }
            case None =>
                Log.warn("[MCP] ${this.config.name} tools/list 无响应")
        }
        Log.info("[MCP] ${this.config.name} 发现 ${this.discoveredTools.size} 个工具")
        return this.discoveredTools
    }

    /**
     * 调用工具（tools/call）
     * @param name  工具名
     * @param args  工具参数（JsonObject）
     * @return 工具结果文本；失败返回错误信息
     */
    public func callTool(name: String, args: JsonObject): ToolResult {
        var params = JsonObject()
        params.put("name", JsonString(name))
        params.put("arguments", args)

        let req = this.buildRequest("tools/call", params)
        if (!this.send(req)) {
            return ToolResult("[MCP] 发送 tools/call 失败", true)
        }
        let resp = this.recv()
        match (resp) {
            case Some(r) =>
                // 检查 error 字段
                match (r.get("error")) {
                    case Some(errVal) =>
                        match (errVal.kind()) {
                            case JsonKind.JsObject =>
                                let errObj = errVal.asObject()
                                var errMsg = "MCP 工具调用失败"
                                match (errObj.get("message")) {
                                    case Some(m) =>
                                        match (m.kind()) {
                                            case JsonKind.JsString => errMsg = m.asString().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                return ToolResult(errMsg, true)
                            case _ => ()
                        }
                    case _ => ()
                }
                // 解析 result.content 数组
                match (r.get("result")) {
                    case Some(resultVal) =>
                        match (resultVal.kind()) {
                            case JsonKind.JsObject =>
                                let resultObj = resultVal.asObject()
                                // 检查 isError 标志
                                var isError = false
                                match (resultObj.get("isError")) {
                                    case Some(ie) =>
                                        match (ie.kind()) {
                                            case JsonKind.JsBool => isError = ie.asBool().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                // content 是数组，每项 {type:"text", text:"..."}
                                var textParts = ArrayList<String>()
                                match (resultObj.get("content")) {
                                    case Some(contentVal) =>
                                        match (contentVal.kind()) {
                                            case JsonKind.JsArray =>
                                                let contentArr = contentVal.asArray()
                                                for (i in 0..contentArr.size()) {
                                                    if (let Some(item) <- contentArr.get(i)) {
                                                        match (item.kind()) {
                                                            case JsonKind.JsObject =>
                                                                let itemObj = item.asObject()
                                                                match (itemObj.get("text")) {
                                                                    case Some(t) =>
                                                                        match (t.kind()) {
                                                                            case JsonKind.JsString =>
                                                                                textParts.add(t.asString().getValue())
                                                                            case _ => ()
                                                                        }
                                                                    case _ => ()
                                                                }
                                                            case _ => ()
                                                        }
                                                    }
                                                }
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                // 拼接所有 text 部分作为结果
                                var resultText = ""
                                for (i in 0..textParts.size) {
                                    if (i > 0) {
                                        resultText += "\n"
                                    }
                                    resultText += textParts[i]
                                }
                                return ToolResult(resultText, isError)
                            case _ => ()
                        }
                    case _ => ()
                }
                return ToolResult("[MCP] tools/call 响应格式异常", true)
            case None =>
                return ToolResult("[MCP] tools/call 无响应", true)
        }
    }

    /**
     * 断开连接，关闭子进程
     */
    public func disconnect(): Unit {
        match (this.subProcess) {
            case Some(sp) =>
                try {
                    // 关闭 stdin，让子进程收到 EOF
                    let stdinPipe = sp.stdInPipe
                    stdinPipe.flush()
                } catch (e: Exception) {
                    // 忽略关闭错误
                }
                // 等待子进程退出（短超时）
                sp.wait()
                this.subProcess = None
                Log.debug("[MCP] ${this.config.name} 已断开")
            case None => ()
        }
    }

    // ====== JSON-RPC 消息构建 ======

    /**
     * 构建 JSON-RPC 2.0 请求（带 id）
     */
    private func buildRequest(method: String, params: JsonObject): JsonObject {
        var req = JsonObject()
        req.put("jsonrpc", JsonString("2.0"))
        req.put("id", JsonInt(this.nextId))
        req.put("method", JsonString(method))
        req.put("params", params)
        this.nextId += 1
        return req
    }

    /**
     * 构建 JSON-RPC 2.0 通知（无 id）
     */
    private func buildNotification(method: String, params: JsonObject): JsonObject {
        var req = JsonObject()
        req.put("jsonrpc", JsonString("2.0"))
        req.put("method", JsonString(method))
        req.put("params", params)
        return req
    }

    /**
     * initialize 请求参数
     */
    private func initializeParams(): JsonObject {
        var params = JsonObject()
        var clientInfo = JsonObject()
        clientInfo.put("name", JsonString("cjh"))
        clientInfo.put("version", JsonString("1.2.3"))
        var capabilities = JsonObject()
        params.put("protocolVersion", JsonString("2025-03-26"))
        params.put("capabilities", capabilities)
        params.put("clientInfo", clientInfo)
        return params
    }

    // ====== stdio 传输层 ======

    /**
     * 发送 JSON-RPC 消息（写入子进程 stdin，\n 结尾）
     * @return 发送成功返回 true
     */
    private func send(msg: JsonObject): Bool {
        match (this.subProcess) {
            case Some(sp) =>
                try {
                    let jsonStr = msg.toJsonString() + "\n"
                    let stdinPipe = sp.stdInPipe
                    let bytes = jsonStr.toArray()
                    var byteArr = Array<Byte>(bytes.size, repeat: 0)
                    for (i in 0..bytes.size) {
                        byteArr[i] = bytes[i]
                    }
                    stdinPipe.write(byteArr)
                    stdinPipe.flush()
                    return true
                } catch (e: Exception) {
                    Log.warn("[MCP] 发送消息失败: ${e}")
                    return false
                }
            case None =>
                return false
        }
    }

    /**
     * 接收 JSON-RPC 响应（从子进程 stdout 读取一行）
     * @return 解析后的 JsonObject；超时或失败返回 None
     */
    private func recv(): ?JsonObject {
        match (this.subProcess) {
            case Some(sp) =>
                try {
                    let stdoutPipe = sp.stdOutPipe
                    // 逐字节读取直到遇到 \n
                    var lineBytes = ArrayList<Byte>(0)
                    var buf = Array<Byte>(1, repeat: 0)
                    var eof = false
                    while (!eof) {
                        let n = stdoutPipe.read(buf)
                        if (n <= 0) {
                            eof = true
                            break
                        }
                        let b = buf[0]
                        if (b == 10u8) {  // \n
                            break
                        }
                        lineBytes.add(b)
                    }
                    if (lineBytes.size == 0) {
                        return None
                    }
                    // 转成 Array<Byte> 再解析
                    var arr = Array<Byte>(lineBytes.size, repeat: 0)
                    for (i in 0..lineBytes.size) {
                        arr[i] = lineBytes[i]
                    }
                    let jsonStr = safeFromUtf8(arr)
                    let v = JsonValue.fromStr(jsonStr)
                    match (v.kind()) {
                        case JsonKind.JsObject => return v.asObject()
                        case _ => return None
                    }
                } catch (e: Exception) {
                    Log.warn("[MCP] 接收消息失败: ${e}")
                    return None
                }
            case None =>
                return None
        }
    }

    /**
     * 解析单个工具定义（tools/list 数组项）
     */
    private func parseToolDef(toolItem: JsonValue): McpToolDef {
        let def = McpToolDef()
        match (toolItem.kind()) {
            case JsonKind.JsObject =>
                let toolObj = toolItem.asObject()
                // name
                match (toolObj.get("name")) {
                    case Some(n) =>
                        match (n.kind()) {
                            case JsonKind.JsString => def.name = n.asString().getValue()
                            case _ => ()
                        }
                    case _ => ()
                }
                // description
                match (toolObj.get("description")) {
                    case Some(d) =>
                        match (d.kind()) {
                            case JsonKind.JsString => def.description = d.asString().getValue()
                            case _ => ()
                        }
                    case _ => ()
                }
                // inputSchema（JSON Schema 参数定义）
                match (toolObj.get("inputSchema")) {
                    case Some(s) =>
                        match (s.kind()) {
                            case JsonKind.JsObject => def.inputSchema = s.asObject()
                            case _ => ()
                        }
                    case _ => ()
                }
                // annotations.readOnlyHint
                match (toolObj.get("annotations")) {
                    case Some(a) =>
                        match (a.kind()) {
                            case JsonKind.JsObject =>
                                let annObj = a.asObject()
                                match (annObj.get("readOnlyHint")) {
                                    case Some(r) =>
                                        match (r.kind()) {
                                            case JsonKind.JsBool => def.readOnly = r.asBool().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                            case _ => ()
                        }
                    case _ => ()
                }
            case _ => ()
        }
        return def
    }

    /**
     * 已发现的工具列表
     */
    public func getDiscoveredTools(): ArrayList<McpToolDef> {
        return this.discoveredTools
    }
}

/**
 * MCP 工具定义（tools/list 返回的单个工具）
 */
public class McpToolDef {
    public var name: String = ""
    public var description: String = ""
    public var inputSchema: JsonObject = JsonObject()
    public var readOnly: Bool = false
}

/**
 * MCP 工具：代理转发到 MCP 服务器
 * 注册到 ToolRegistry，LLM 调用时转发给对应的 McpClient
 */
public class McpTool <: CjhTool {
    private let name: String
    private let description: String
    private let inputSchema: JsonObject
    private let readOnly: Bool
    private let client: McpClient

    public init(name: String, description: String, inputSchema: JsonObject,
        readOnly: Bool, client: McpClient) {
        this.name = name
        this.description = description
        this.inputSchema = inputSchema
        this.readOnly = readOnly
        this.client = client
    }

    public func isReadOnly(): Bool {
        return this.readOnly
    }

    public override func spec(): ToolSpec {
        return ToolSpec(this.name, this.description, this.inputSchema)
    }

    public override func execute(args: JsonObject): ToolResult {
        // 转发给 MCP 服务器
        return this.client.callTool(this.name, args)
    }
}

/**
 * MCP 管理器：管理多个 MCP 服务器的连接和工具注册
 */
public class McpManager {
    private var clients: ArrayList<McpClient> = ArrayList<McpClient>()

    public init() {}

    /**
     * 连接所有配置的 MCP 服务器，注册工具到 registry
     * @param servers  MCP 服务器配置列表
     * @param registry 工具注册中心
     */
    public func connectAll(servers: ArrayList<McpServerConfig>, registry: ToolRegistry): Unit {
        for (i in 0..servers.size) {
            let serverCfg = servers[i]
            let client = McpClient(serverCfg)
            if (!client.connect()) {
                Log.warn("[MCP] 连接服务器 ${serverCfg.name} 失败，跳过")
                continue
            }
            // 查询工具列表
            let tools = client.listTools()
            // 注册每个工具
            for (j in 0..tools.size) {
                let toolDef = tools[j]
                let tool = McpTool(
                    toolDef.name,
                    toolDef.description,
                    toolDef.inputSchema,
                    toolDef.readOnly,
                    client)
                registry.register(tool)
                Log.debug("[MCP] 注册工具: ${toolDef.name} (server=${serverCfg.name})")
            }
            this.clients.add(client)
            if (tools.size > 0) {
                Log.info("[MCP] ${serverCfg.name}: 已注册 ${tools.size} 个工具")
            }
        }
    }

    /**
     * 断开所有 MCP 服务器连接
     */
    public func disconnectAll(): Unit {
        for (i in 0..this.clients.size) {
            this.clients[i].disconnect()
        }
        this.clients.clear()
    }

    /**
     * 已连接的 MCP 服务器数量
     */
    public func getConnectedCount(): Int64 {
        return this.clients.size
    }
}
