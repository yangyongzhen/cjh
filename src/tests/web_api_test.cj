package cjh.tests

import std.collection.*
import cjh.web.*

/**
 * web REST API 纯函数单元测试（此前 web 模块零测试）：
 * maskApiKey / countJsonObjects / isSkillEnabled / jsonArrFromStrings / 类型判断
 */
@Test
public class WebApiUtilTest {

    @TestCase
    public func testMaskApiKey(): Unit {
        @Assert(maskApiKey("sk-1234567890abcdef"), "sk-1****cdef")  // 前4+后4
        @Assert(maskApiKey("short"), "****")
        @Assert(maskApiKey(""), "")
        @Assert(maskApiKey("12345678"), "****")  // 8 字符边界
        @Assert(maskApiKey("123456789"), "1234****6789")
    }

    @TestCase
    public func testCountJsonObjects(): Unit {
        @Assert(countJsonObjects("[{\"name\":\"a\"},{\"name\":\"b\"}]"), 2)
        @Assert(countJsonObjects("[]"), 0)
        @Assert(countJsonObjects("{}"), 1)
        // 嵌套对象只数顶层
        @Assert(countJsonObjects("[{\"a\":{\"b\":1}}]"), 1)
        @Assert(countJsonObjects("not json"), 0)
    }

    @TestCase
    public func testIsSkillEnabled(): Unit {
        var enabled = ArrayList<String>()
        enabled.add("a")
        enabled.add("b")
        @Assert(isSkillEnabled("a", enabled), true)
        @Assert(isSkillEnabled("c", enabled), false)
        // 空白名单 = 全部启用
        var empty = ArrayList<String>()
        @Assert(isSkillEnabled("anything", empty), true)
    }

    @TestCase
    public func testJsonArrFromStrings(): Unit {
        var list = ArrayList<String>()
        list.add("one")
        list.add("two")
        let arr = jsonArrFromStrings(list)
        @Assert(arr.size(), 2)
        // JsonArray.toJsonString 是多行格式化，用内容断言
        @Assert(arr.toJsonString().contains("\"one\""), true)
        @Assert(arr.toJsonString().contains("\"two\""), true)
        // 空列表
        let empty = jsonArrFromStrings(ArrayList<String>())
        @Assert(empty.size(), 0)
    }
}

/**
 * /api/fs/list 的 query→目录解析回归（issue #10）：
 * 此前在整段 query 上做范围切片，"path=" 位于末尾时越界抛异常，
 * 逃逸为 500 纯文本 Internal Server Error。
 */
@Test
public class FsListQueryTest {

    private static let cwd = "/default/cwd"

    @TestCase
    public func testNoQueryFallsBackToCwd(): Unit {
        @Assert(fsListDirFromQuery(None, cwd), cwd)
        @Assert(fsListDirFromQuery(Some(""), cwd), cwd)
    }

    @TestCase
    public func testEmptyPathValueFallsBackToCwd(): Unit {
        // 回归主用例：?path=（空值）此前触发切片越界 → 500 纯文本
        @Assert(fsListDirFromQuery(Some("path="), cwd), cwd)
        // 多参数时 path 为空值
        @Assert(fsListDirFromQuery(Some("a=1&path="), cwd), cwd)
    }

    @TestCase
    public func testPathParamExtracted(): Unit {
        @Assert(fsListDirFromQuery(Some("path=/tmp/x"), cwd), "/tmp/x")
        // path 不在首位
        @Assert(fsListDirFromQuery(Some("a=1&path=/tmp/y"), cwd), "/tmp/y")
        // path= 是其他参数值的一部分，不算 path 参数
        @Assert(fsListDirFromQuery(Some("filter=path=1"), cwd), cwd)
    }
}
