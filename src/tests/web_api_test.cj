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
