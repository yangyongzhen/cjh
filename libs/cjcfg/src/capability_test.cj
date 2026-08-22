package cjcfg

import std.collection.*
import stdx.encoding.json.*

/**
 * Capability 三域安全模型单元测试（拒绝/审批/放行三条路径）
 * 配置样例对齐 v2 架构文档 4.2 节
 */
@Test
public class CapabilityTest {

    /**
     * 构造 capability 配置 JSON：
     *   commands: ["ls", "git *", "system:*"]  （git * 实际为字面，测试前缀匹配用 system:*）
     *   tools: ["bash", "read_file"]
     *   resources.fs: 项目目录递归 glob + secret 子目录排除
     *   resources.proc: ["!rm"]
     *   approval: ["write_file", "proc:*"]
     *   （注：块注释内不写 glob 字面量，避免 斜杠+星号 嵌套注释）
     */
    private func buildCapability(): Capability {
        var obj = JsonObject()
        obj.put("identifier", JsonString("test"))
        var cmds = ArrayList<JsonValue>()
        cmds.add(JsonString("ls"))
        cmds.add(JsonString("system:*"))
        obj.put("commands", JsonArray(cmds))
        var tools = ArrayList<JsonValue>()
        tools.add(JsonString("bash"))
        tools.add(JsonString("read_file"))
        obj.put("tools", JsonArray(tools))
        var resources = JsonObject()
        var fs = ArrayList<JsonValue>()
        fs.add(JsonString("/home/user/project/**"))
        fs.add(JsonString("!/home/user/project/secret/**"))
        resources.put("fs", JsonArray(fs))
        var proc = ArrayList<JsonValue>()
        proc.add(JsonString("!rm"))
        resources.put("proc", JsonArray(proc))
        obj.put("resources", resources)
        var approval = ArrayList<JsonValue>()
        approval.add(JsonString("write_file"))
        approval.add(JsonString("proc:*"))
        obj.put("approval", JsonArray(approval))
        return Capability.fromJson(Some(obj))
    }

    @TestCase
    public func testDisabledIsPermissive(): Unit {
        // 未配置 capability：宽松模式，全部放行
        let cap = Capability.fromJson(None)
        match (cap.checkTool("anything")) {
            case CapDecision.Allow => ()
            case _ => @Assert("permissive", "denied")
        }
        match (cap.checkCommand("rm -rf /")) {
            case CapDecision.Allow => ()
            case _ => @Assert("permissive", "denied")
        }
        match (cap.checkPath("/any/path", false)) {
            case CapDecision.Allow => ()
            case _ => @Assert("permissive", "denied")
        }
    }

    @TestCase
    public func testToolWhitelist(): Unit {
        let cap = this.buildCapability()
        // 白名单内：允许
        match (cap.checkTool("read_file")) {
            case CapDecision.Allow => ()
            case _ => @Assert("read_file", "not allow")
        }
        // 未声明：拒绝
        match (cap.checkTool("list_dir")) {
            case CapDecision.Deny(reason) => @Assert(reason.size > 0, true)
            case _ => @Assert("list_dir", "not denied")
        }
        // approval 中声明的 write_file：即使不在 tools 也需审批（而非直接拒绝）
        match (cap.checkTool("write_file")) {
            case CapDecision.NeedApproval(_) => ()
            case _ => @Assert("write_file", "not need approval")
        }
    }

    @TestCase
    public func testCommandWhitelist(): Unit {
        // 不带 approval 的独立配置：验证命令白名单匹配本身（proc 黑名单保留）
        var obj = JsonObject()
        var cmds = ArrayList<JsonValue>()
        cmds.add(JsonString("ls"))
        cmds.add(JsonString("system*"))
        obj.put("commands", JsonArray(cmds))
        var resources = JsonObject()
        var proc = ArrayList<JsonValue>()
        proc.add(JsonString("!rm"))
        resources.put("proc", JsonArray(proc))
        obj.put("resources", resources)
        let cap = Capability.fromJson(Some(obj))
        // 白名单精确匹配：ls
        match (cap.checkCommand("ls -la")) {
            case CapDecision.Allow => ()
            case _ => @Assert("ls", "not allow")
        }
        // 通配符前缀匹配：system* 匹配 systemctl 等 system 命令族
        match (cap.checkCommand("systemctl status nginx")) {
            case CapDecision.Allow => ()
            case _ => @Assert("system*", "not allow")
        }
        // 未声明：拒绝
        match (cap.checkCommand("curl http://x")) {
            case CapDecision.Deny(reason) => @Assert(reason.size > 0, true)
            case _ => @Assert("curl", "not denied")
        }
        // 危险命令黑名单：rm 禁止（proc 黑名单优先于白名单）
        match (cap.checkCommand("rm -rf /tmp/x")) {
            case CapDecision.Deny(reason) => @Assert(reason.size > 0, true)
            case _ => @Assert("rm", "not denied by proc")
        }
    }

    @TestCase
    public func testCommandApproval(): Unit {
        let cap = this.buildCapability()
        // approval "proc:*"：白名单命中的命令也需人工确认
        match (cap.checkCommand("ls -la")) {
            case CapDecision.NeedApproval(_) => ()
            case _ => @Assert("ls under proc:*", "not need approval")
        }
    }

    @TestCase
    public func testPathGlob(): Unit {
        let cap = this.buildCapability()
        // 白名单命中：允许读
        match (cap.checkPath("/home/user/project/src/main.cj", false)) {
            case CapDecision.Allow => ()
            case _ => @Assert("project file", "not allow")
        }
        // 排除规则命中：拒绝（优先于白名单）
        match (cap.checkPath("/home/user/project/secret/key.txt", false)) {
            case CapDecision.Deny(reason) => @Assert(reason.size > 0, true)
            case _ => @Assert("secret file", "not denied")
        }
        // 白名单外：拒绝
        match (cap.checkPath("/etc/passwd", false)) {
            case CapDecision.Deny(reason) => @Assert(reason.size > 0, true)
            case _ => @Assert("/etc/passwd", "not denied")
        }
        // $HOME 展开：白名单用 $HOME 时也能匹配
        var obj = JsonObject()
        var fs = ArrayList<JsonValue>()
        fs.add(JsonString("$HOME/project/**"))
        var res = JsonObject()
        res.put("fs", JsonArray(fs))
        obj.put("resources", res)
        var cap2 = Capability.fromJson(Some(obj))
        match (cap2.checkPath("$HOME/project/a.txt", false)) {
            case CapDecision.Allow => ()
            case _ => @Assert("home project", "not allow")
        }
    }

    @TestCase
    public func testGlobMatch(): Unit {
        // 基础 glob 语义
        @Assert(Capability.globMatch("/a/**", "/a/b/c.txt"), true)
        @Assert(Capability.globMatch("/a/*", "/a/b/c.txt"), false)
        @Assert(Capability.globMatch("/a/*.cj", "/a/main.cj"), true)
        @Assert(Capability.globMatch("/a/?", "/a/b"), true)
        @Assert(Capability.globMatch("/a/**", "/a"), true)
    }
}
