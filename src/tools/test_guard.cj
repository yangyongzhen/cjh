package cjh.tools

import std.fs.*
import stdx.encoding.json.*
import cjutil.*

/**
 * 测试契约护栏：识别"改写测试文件里的断言"的写操作。
 *
 * 背景（2026-11-22 实测）：模型跑测试失败后，直接把自己的测试断言从
 * `== 1` 改成 `== 2`，测试变绿但实现缺陷还在。测试是契约，改断言必须
 * 经过用户批准，而不是模型自证正确。
 *
 * 这里只做"是否命中"的判定；真正的放行/拒绝由 Agent.executeGuarded 的
 * onApproval 审批链完成（TUI 弹窗、Web approval_request、无头默认拒绝）。
 */
public func isTestFilePath(path: String): Bool {
    let normalized = path.replace("\\", "/").toAsciiLower()
    let parts = normalized.split("/")
    for (part in parts) {
        if (part == "tests" || part == "test" || part == "spec" || part == "__tests__") {
            return true
        }
    }
    var name = normalized
    match (normalized.lastIndexOf("/")) {
        case Some(idx) => name = normalized[(idx + 1)..normalized.size]
        case None => ()
    }
    if (name.endsWith("_test.cj") || name.endsWith("_test.py") || name.endsWith("_test.go") ||
        name.endsWith("_test.rb") || name.endsWith("_test.rs") || name.endsWith("_test.js") ||
        name.endsWith("_test.ts") || name.endsWith("_test.tsx") || name.endsWith("_test.jsx")) {
        return true
    }
    if (name.startsWith("test_")) {
        return true
    }
    if (name.contains(".test.") || name.contains(".spec.")) {
        return true
    }
    if (name.endsWith("test.java") || name.endsWith("tests.java") ||
        name.endsWith("test.cs") || name.endsWith("tests.cs") ||
        name.endsWith("test.kt") || name.endsWith("tests.kt") ||
        name.endsWith("test.php")) {
        return true
    }
    return false
}

/**
 * 文本里是否含测试断言/期望。
 *
 * 故意保守：只要出现 assert/expect/@Assert/@Expect 等词就视为断言相关，
 * 宁可多问一次用户，也不静默让失败测试"变绿"。
 */
public func containsTestAssertion(text: String): Bool {
    let lower = text.toAsciiLower()
    if (lower.contains("assert") || lower.contains("@expect")) {
        return true
    }
    if (lower.contains("expect(") || lower.contains("expect (") || lower.contains("expect.")) {
        return true
    }
    if (lower.contains("should.") || lower.contains("should(") || lower.contains("pytest.raises")) {
        return true
    }
    return false
}

func argText(args: JsonObject, key: String): ?String {
    match (args.get(key)) {
        case Some(v) =>
            try {
                return Some(v.asString().getValue())
            } catch (e: Exception) {
                return None
            }
        case None => return None
    }
}

func existingText(path: String): ?String {
    try {
        if (!exists(path)) {
            return None
        }
        if (FileInfo(path).size > 2 * 1024 * 1024) {
            return None
        }
        return Some(safeFromUtf8(File.readFrom(path)))
    } catch (e: Exception) {
        return None
    }
}

/**
 * 判断本次写操作是否在修改测试断言。
 *
 * 返回原因字符串表示需要审批；None 表示放行：
 * - edit：old_string 或 new_string 含断言
 * - hashline_edit：patch 含断言
 * - write_file：目标已存在且是测试文件，旧内容含断言（新建测试文件不拦）
 * - append_file：目标已存在且是测试文件，追加内容含断言
 *
 * bash/sed 改写测试不在本函数识别范围（仍由 capability 命令域约束）；
 * 这是有意的边界：文本启发式无法可靠解析任意 shell 命令。
 */
public func testContractChangeReason(name: String, args: JsonObject): ?String {
    let pathOpt = argText(args, "path")
    if (!pathOpt.isSome()) {
        return None
    }
    let path = pathOpt.getOrThrow()
    if (!isTestFilePath(path)) {
        return None
    }
    var hit = false
    if (name == "edit") {
        let oldText = argText(args, "old_string")
        let newText = argText(args, "new_string")
        if (let Some(o) <- oldText) {
            if (containsTestAssertion(o)) {
                hit = true
            }
        }
        if (let Some(n) <- newText) {
            if (containsTestAssertion(n)) {
                hit = true
            }
        }
    } else if (name == "hashline_edit") {
        if (let Some(patch) <- argText(args, "patch")) {
            if (containsTestAssertion(patch)) {
                hit = true
            }
        }
    } else if (name == "write_file") {
        if (let Some(oldText) <- existingText(path)) {
            if (containsTestAssertion(oldText)) {
                hit = true
            }
        }
    } else if (name == "append_file") {
        if (let Some(content) <- argText(args, "content")) {
            if (containsTestAssertion(content) && existingText(path).isSome()) {
                hit = true
            }
        }
    }
    if (!hit) {
        return None
    }
    return Some("修改测试断言：${path}（测试是契约；测试失败优先修实现，确需改契约须用户批准）")
}
