package cjh.tests

import std.collection.*
import stdx.encoding.json.*
import cjh.web.*

/**
 * 能力自述（GET /api/capabilities）测试
 *
 * 关键断言：清单里每一项都真的存在。报出服务端其实不处理的帧，
 * 比不报更糟——客户端会照清单写代码，然后踩空。
 */

/**
 * 按事件名给一个真实构造的样帧（无对应构造方式 → 返回空对象，断言即失败）
 */
func sampleEventObj(name: String): JsonObject {
    match (name) {
        case "delta" => return JsonValue.fromStr(DeltaEvent("x").toJson()).asObject()
        case "tool_start" =>
            return JsonValue.fromStr(ToolStartEvent("t", JsonObject()).toJson()).asObject()
        case "tool_result" =>
            return JsonValue.fromStr(ToolResultEvent("t", "c", false).toJson()).asObject()
        case "done" => return JsonValue.fromStr(DoneEvent(0, 0, 0, 0, 0).toJson()).asObject()
        case "error" =>
            return JsonValue.fromStr(ErrorEvent("e", "internal", false).toJson()).asObject()
        case "ack" => return JsonValue.fromStr(AckEvent("switch_model").toJson()).asObject()
        case "cancelled" =>
            return JsonValue.fromStr(CancelledEvent("s", false).toJson()).asObject()
        case "approval_request" =>
            return JsonValue.fromStr(
                ApprovalRequestEvent("r1", "bash", JsonObject(), "危险命令").toJson()).asObject()
        case "tasks" => return JsonValue.fromStr(tasksFrameJson(JsonArray())).asObject()
        case "history_messages" =>
            return JsonValue.fromStr(historyMessagesJson("s", JsonArray())).asObject()
        case _ => return JsonObject()
    }
}

/**
 * 帧名是否被识别（枚举不能直接 == 比较，统一在 match 里转 Bool）
 */
func frameNameUnknown(name: String): Bool {
    match (parseMsgType("{\"type\": \"${name}\"}")) {
        case WsMsgType.Unknown => return true
        case _ => return false
    }
}

/**
 * JSON 字符串数组是否与清单逐项相等（含顺序与长度）
 */
func arrayMatches(list: ArrayList<String>, value: JsonValue): Bool {
    match (value.kind()) {
        case JsonKind.JsArray =>
            let arr = value.asArray()
            if (arr.size() != list.size) {
                return false
            }
            for (i in 0..list.size) {
                match (arr[i].kind()) {
                    case JsonKind.JsString =>
                        if (arr[i].asString().getValue() != list[i]) {
                            return false
                        }
                    case _ => return false
                }
            }
            return true
        case _ => return false
    }
}

/**
 * 在清单里查名字（与 capabilities.cj 的同名逻辑一致，测试侧独立实现）
 */
func nameListed(list: ArrayList<String>, name: String): Bool {
    for (i in 0..list.size) {
        if (list[i] == name) {
            return true
        }
    }
    return false
}

@Test
public class CapabilitiesTest {

    @TestCase
    public func testInboundFramesAreParsable(): Unit {
        // 报出的每个入站帧名，parseMsgType 必须认得（否则客户端发的帧会被当垃圾丢掉）
        let inbound = inboundFrameNames()
        @Assert(inbound.size > 0, true)
        var unknown = ""
        for (i in 0..inbound.size) {
            let name = inbound[i]
            if (frameNameUnknown(name)) {
                unknown += name + ";"
            }
        }
        @Assert(unknown, "")
    }

    @TestCase
    public func testOutboundEventsCanBeBuilt(): Unit {
        // 报出的每个出站事件名，都必须真能构造出同 type 的帧
        let outbound = outboundEventNames()
        @Assert(outbound.size > 0, true)
        var bad = ""
        for (i in 0..outbound.size) {
            let name = outbound[i]
            if (getStr(sampleEventObj(name), "type") != name) {
                bad += name + ";"
            }
        }
        @Assert(bad, "")
    }

    @TestCase
    public func testDocumentListsMatchSourceLists(): Unit {
        // 文档里的三份清单必须与源清单逐项一致（不能手写一份文档去漂移）
        let doc = capabilitiesJson()
        match (doc.get("ws_in")) {
            case Some(v) => @Assert(arrayMatches(inboundFrameNames(), v), true)
            case None => @Assert("ws_in 缺失", "")
        }
        match (doc.get("ws_out")) {
            case Some(v) => @Assert(arrayMatches(outboundEventNames(), v), true)
            case None => @Assert("ws_out 缺失", "")
        }
        match (doc.get("http")) {
            case Some(v) => @Assert(arrayMatches(httpEndpointNames(), v), true)
            case None => @Assert("http 缺失", "")
        }
    }

    @TestCase
    public func testDerivedFeatureFlagsFollowFrameLists(): Unit {
        // 能从帧清单推导的能力位必须真的由清单推导：清单变了它就跟着变，
        // 不会出现"handlers 删了 approval_response，能力位还报 true"
        let doc = capabilitiesJson()
        match (doc.get("features")) {
            case Some(v) =>
                let f = v.asObject()
                let inbound = inboundFrameNames()
                @Assert(getBool(f, "approval_over_ws"), nameListed(inbound, "approval_response"))
                @Assert(getBool(f, "history_replay"), nameListed(inbound, "resume_session"))
                @Assert(getBool(f, "cancel_receipt"), nameListed(inbound, "cancel"))
                @Assert(getBool(f, "control_frame_acks"),
                    nameListed(inbound, "switch_model") && nameListed(inbound, "compact"))
                // 协议版本与回合身份绑定：v>=2 才报 true
                @Assert(getBool(f, "turn_ids"), capabilityProtocolVersion() >= 2)
            case None => @Assert("features 缺失", "")
        }
    }

    @TestCase
    public func testHttpEndpointsDeclaredWithMethod(): Unit {
        // 每个端点必须是"方法 路径"形状；能力端点自己也必须在清单里
        let endpoints = httpEndpointNames()
        @Assert(nameListed(endpoints, "GET /api/capabilities"), true)
        var bad = ""
        for (i in 0..endpoints.size) {
            let e = endpoints[i]
            let hasMethod = e.startsWith("GET ") || e.startsWith("POST ") ||
                e.startsWith("PATCH ") || e.startsWith("DELETE ")
            if (!hasMethod) {
                bad += e + ";"
            }
        }
        @Assert(bad, "")
    }
}
