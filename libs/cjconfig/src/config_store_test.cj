package cjconfig

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/**
 * ConfigStore 单元测试：三层优先级/类型读取/保留未知/模板生成/持久化往返
 */
@Test
public class ConfigStoreTest {

    private func newStore(name: String): ConfigStore {
        // 独立测试目录（固定名：roundtrip 用例靠 save 覆盖）
        return ConfigStore(name, "/tmp/cjconfig_test_" + name)
    }



    @TestCase
    public func testDefaultValues(): Unit {
        let cfg = newStore("defaults")
        cfg.defineStr("model", "gpt-4o-mini", "", "模型")
        cfg.defineInt("max_iters", 10, "", "最大迭代")
        cfg.defineBool("verbose", false, "", "详细输出")
        cfg.load()
        @Assert(cfg.getStr("model"), "gpt-4o-mini")
        @Assert(cfg.getInt("max_iters"), 10)
        @Assert(cfg.getBool("verbose"), false)
    }

    @TestCase
    public func testEnvOverrides(): Unit {
        let cfg = newStore("env")
        cfg.defineStr("model", "gpt-4o-mini", "CJCONFIG_TEST_MODEL", "模型")
        cfg.load()
        // 无 env：默认值
        @Assert(cfg.getStr("model"), "gpt-4o-mini")
        // 设置 env → 覆盖
        setEnvForTest("CJCONFIG_TEST_MODEL", "deepseek-chat")
        @Assert(cfg.getStr("model"), "deepseek-chat")
        // 类型转换：int env
        cfg.defineInt("max_iters", 10, "CJCONFIG_TEST_ITERS", "")
        setEnvForTest("CJCONFIG_TEST_ITERS", "42")
        @Assert(cfg.getInt("max_iters"), 42)
    }

    @TestCase
    public func testSaveLoadRoundTrip(): Unit {
        let cfg = newStore("roundtrip")
        cfg.defineStr("model", "gpt-4o-mini", "", "模型")
        cfg.defineInt("max_iters", 10, "", "最大迭代")
        cfg.load()
        cfg.setStr("model", "deepseek-chat")
        cfg.setInt("max_iters", 50)
        cfg.save()
        // 新实例从磁盘加载
        let cfg2 = newStore("roundtrip")
        cfg2.defineStr("model", "gpt-4o-mini", "", "模型")
        cfg2.defineInt("max_iters", 10, "", "最大迭代")
        cfg2.load()
        @Assert(cfg2.getStr("model"), "deepseek-chat")
        @Assert(cfg2.getInt("max_iters"), 50)
    }

    @TestCase
    public func testTemplateGeneration(): Unit {
        let cfg = newStore("template")
        cfg.defineStr("model", "gpt-4o-mini", "", "模型名")
        cfg.defineBool("enabled", true, "", "是否启用")
        cfg.load()
        cfg.save()   // 首次：生成模板
        @Assert(exists(cfg.configPath()), true)
        let content = String.fromUtf8(File.readFrom(cfg.configPath()))
        @Assert(content.contains("_说明"), true)
        @Assert(content.contains("gpt-4o-mini"), true)
    }

    @TestCase
    public func testFirstSaveUsesSetValues(): Unit {
        let cfg = newStore("firstset")
        cfg.defineStr("model", "gpt-4o-mini", "", "模型")
        cfg.load()
        cfg.setStr("model", "deepseek-chat")   // 首次 save 前修改
        cfg.save()
        let content = String.fromUtf8(File.readFrom(cfg.configPath()))
        @Assert(content.contains("deepseek-chat"), true)   // 模板应含 set 值
    }

    @TestCase
    public func testPreservesUnknownFields(): Unit {
        let cfg = newStore("unknown")
        cfg.defineStr("model", "gpt-4o-mini", "", "模型")
        cfg.load()
        cfg.setStr("model", "deepseek-chat")
        cfg.save()
        // 用户手写扩展字段
        let root = JsonObject()
        root.put("model", JsonString("deepseek-chat"))
        root.put("user_custom_field", JsonString("keep-me"))
        File.writeTo(cfg.configPath(), root.toJsonString().toArray())
        // 再保存：未知字段保留
        cfg.load()
        cfg.setStr("model", "glm-4")
        cfg.save()
        let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(cfg.configPath())))
        var isObj = false
        match (json.kind()) {
            case JsonKind.JsObject => isObj = true
            case _ => ()
        }
        @Assert(isObj, true)
        let obj = json.asObject()
        var hasCustom = false
        if (let Some(v) <- obj.get("user_custom_field")) {
            match (v.kind()) {
                case JsonKind.JsString => hasCustom = (v.asString().getValue() == "keep-me")
                case _ => ()
            }
        }
        @Assert(hasCustom, true)
    }

    @TestCase
    public func testTypeSafety(): Unit {
        let cfg = newStore("types")
        cfg.defineFloat("temperature", 0.7, "", "温度")
        cfg.load()
        @Assert(cfg.getFloat("temperature") > 0.69 && cfg.getFloat("temperature") < 0.71, true)
        // 未知 key → 默认空/0
        @Assert(cfg.getStr("nope"), "")
        @Assert(cfg.getInt("nope"), 0)
        // 数组字段
        var tagArr = JsonArray()
        tagArr.add(JsonString("a"))
        tagArr.add(JsonString("b"))
        cfg.defineJson("tags", tagArr, "", "")
        let tags = cfg.getJson("tags")
        match (tags.kind()) {
            case JsonKind.JsArray => @Assert(tags.asArray().size(), 2)
            case _ => @Assert(true, false)
        }
    }
}
