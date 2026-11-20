package cjh.tests

import stdx.encoding.json.*
import cjh.tools.*

/**
 * MCP HTTP 传输的纯函数单测（parseMcpHttpRpcBody）。
 *
 * 网络连通性不做单测（实机验证为准）：这类用例对 Huawei KMS 端点的
 * 手工探针记录见 docs/ 与 lingqu 仓 skills/t2h-ohos-port/references。
 */

@Test
public func testParseMcpHttpRpcBodyPlainJson(): Unit {
    // 主流形态：整段就是 JSON-RPC 响应
    let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}"
    if (let Some(o) <- parseMcpHttpRpcBody(body)) {
        @Assert(o.containsKey("result"), true)
    } else {
        @Assert(true, false)
    }
}

@Test
public func testParseMcpHttpRpcBodySseFrame(): Unit {
    // SSE 形态：JSON-RPC 包在 "data:" 行里（最后一条生效）
    let body = "event: message\n" +
        "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"placeholder\":true}}\n" +
        "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"searchDocuments\"}]}}\n"
    if (let Some(o) <- parseMcpHttpRpcBody(body)) {
        @Assert(o.containsKey("result"), true)
    } else {
        @Assert(true, false)
    }
}

@Test
public func testParseMcpHttpRpcBodyRejectsGarbage(): Unit {
    @Assert(parseMcpHttpRpcBody("").isNone(), true)
    match (parseMcpHttpRpcBody("not json at all")) {
        case Some(_) => @Assert(true, false)
        case None => @Assert(true, true)
    }
}
