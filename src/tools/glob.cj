package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import std.fs.*
import cjllm.ToolSpec

/**
 * glob 工具：文件名模式匹配
 *
 * 移植自 omp GlobTool。比 list_dir 递归更高效：
 * 模型常需"找所有 .ts 文件"，list_dir 逐层展开效率低。
 *
 * 支持的通配符:
 * - `*` 匹配除 / 外的任意字符, 不跨目录
 * - `**` 匹配任意层级目录, 跨目录, 含 0 层
 * - `?` 匹配单个字符
 *
 * 示例:
 * - 双星斜星点ts - 所有 .ts 文件, 含子目录
 * - src斜星点cj - src 目录下所有 .cj 文件
 * - 双星斜test_星 - 所有以 test_ 开头的文件
 *
 * gitignore 感知: 跳过 .git / node_modules / target 等常见忽略目录.
 */
public class GlobTool <: CjhTool {
    public init() {}

    public func isReadOnly(): Bool {
        return true  // 纯读：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("pattern", JsonSchema.str("Glob pattern (e.g. **/*.ts, src/*.cj). ** matches any directory depth."))
        props.add("path", JsonSchema.str("Base directory to search in (default: cwd)"))
        let schema = JsonSchema.object(props, ArrayList<String>(["pattern"]))
        return ToolSpec("glob",
            "Find files matching a glob pattern. Returns matching file paths. " +
            "Supports ** for recursive directory matching. " +
            "Examples: '**/*.ts' finds all .ts files; 'src/*.cj' finds .cj files in src/.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("pattern")) {
            return ToolResult("缺少参数: pattern", true)
        }
        let pattern = args.get("pattern").getOrThrow().asString().getValue()
        if (pattern.size == 0) {
            return ToolResult("pattern 不能为空. 示例: '**/*.ts' 匹配所有 .ts 文件.", true)
        }
        var basePath = "."
        if (let Some(p) <- args.get("path")) {
            match (p.kind()) {
                case JsonKind.JsString => basePath = p.asString().getValue()
                case _ => ()
            }
        }
        if (!exists(basePath)) {
            return ToolResult("基础路径不存在: ${basePath}", true)
        }

        // 规范化 basePath：去掉 ./ 前缀和尾部 /
        let normalizedBase = normalizePath(basePath)

        try {
            GlobState.matches = ArrayList<String>()
            GlobState.count = 0
            GlobState.pattern = pattern
            GlobState.basePath = normalizedBase

            // Directory.walk 递归遍历整个目录树
            // 回调返回 true 继续遍历，false 停止
            // 注意：lambda 不能捕获 mutable 局部变量，通过 GlobState 静态字段访问
            Directory.walk(GlobState.basePath, { fi =>
                let name = fi.name
                // 跳过隐藏文件和忽略目录
                if (shouldSkip(name)) {
                    return false  // 不进入此目录的子项
                }
                if (!fi.isDirectory()) {
                    // 文件：计算相对路径，检查 glob 匹配
                    let absPath = "${fi.path}"
                    let relPath = makeRelative(GlobState.basePath, absPath)
                    if (globMatchDirect(GlobState.pattern, 0, relPath, 0)) {
                        if (GlobState.count < 200) {
                            GlobState.matches.add(relPath)
                        }
                        GlobState.count += 1
                    }
                }
                return true
            })

            var result = StringBuilder()
            if (GlobState.matches.size == 0) {
                result.append("没有文件匹配模式: ${pattern}\n")
            } else {
                result.append("匹配 ${GlobState.matches.size} 个文件（模式: ${pattern}）：\n")
                for (m in GlobState.matches) {
                    result.append(m)
                    result.append("\n")
                }
                if (GlobState.count > 200) {
                    result.append("…（共 ${GlobState.count} 个匹配，仅显示前 200）\n")
                }
            }
            return ToolResult(result.toString(), false)
        } catch (e: Exception) {
            return ToolResult("glob 失败: ${e}", true)
        }
    }
}

/**
 * 规范化路径：去掉 ./ 前缀和尾部 /
 *
 * "./src" → "src"
 * "src/" → "src"
 * "." → "."
 * "/" → "/"
 */
func normalizePath(p: String): String {
    var s = p
    // 去掉 ./ 前缀
    if (s.startsWith("./")) {
        s = s[2..s.size]
    }
    // 去掉尾部 / (但保留根路径 /)
    if (s.size > 1 && s.endsWith("/")) {
        s = s[0..s.size - 1]
    }
    // 空字符串视为当前目录
    if (s.size == 0) {
        s = "."
    }
    return s
}

/**
 * glob 状态（仓颉 lambda 不能捕获 mutable 变量，用静态字段）
 */
class GlobState {
    static var matches: ArrayList<String> = ArrayList<String>()
    static var count: Int64 = 0
    static var pattern: String = ""
    static var basePath: String = "."
}

/**
 * 跳过隐藏文件和常见忽略目录
 */
func shouldSkip(name: String): Bool {
    if (name.startsWith(".")) {
        return true
    }
    let ignoreList = [".git", "node_modules", "target", ".next", "dist", "build",
        ".cache", "__pycache__", ".venv", ".gradle", ".idea", ".vscode"]
    for (ignore in ignoreList) {
        if (name == ignore) {
            return true
        }
    }
    return false
}

/**
 * 计算相对于 basePath 的路径
 *
 * Directory.walk 回调里 fi.path 可能是:
 * - 绝对路径: /root/test/cj/cjh/src/tools/builtin.cj
 * - 相对路径: src/tools/builtin.cj (相对于 cwd)
 *
 * 需要转为相对于 basePath 的路径用于 glob 匹配和输出.
 * 策略:
 * 1. 尝试 basePath + "/" 前缀匹配 (fi.path 是相对路径的情况)
 * 2. 尝试规范化 basePath 后的前缀匹配
 * 3. 如果都不匹配, 从 absPath 中提取文件名部分
 */
func makeRelative(basePath: String, absPath: String): String {
    // 情况 1: fi.path 是相对路径, 以 basePath + "/" 开头
    let prefix = basePath + "/"
    if (absPath.startsWith(prefix)) {
        return absPath[prefix.size..absPath.size]
    }

    // 情况 2: absPath == basePath (basePath 就是 absPath)
    if (absPath == basePath) {
        return "."
    }

    // 情况 3: fi.path 是绝对路径, 需要找到 basePath 在 absPath 中的位置
    // 例如 basePath="src/tools", absPath="/root/test/cj/cjh/src/tools/builtin.cj"
    // absPath 中 "src/tools/" 之后的部分就是相对路径
    let basePathNorm = normalizePath(basePath)
    let basePathLast: String = lastPathComponent(basePathNorm)
    // 在 absPath 中查找 basePathLast + "/" 的位置
    let searchKey = basePathLast + "/"
    let idx: Int64 = indexOfString(absPath, searchKey)
    if (idx >= 0) {
        // 找到了, 返回 searchKey 之后的部分
        let afterKey = idx + searchKey.size
        if (afterKey <= absPath.size) {
            return absPath[afterKey..absPath.size]
        }
    }

    // 情况 4: 都不匹配, 返回原始路径 (降级)
    return absPath
}

/**
 * 获取路径的最后一个组件
 * "src/tools" -> "tools"
 * "src" -> "src"
 */
func lastPathComponent(p: String): String {
    var i: Int64 = p.size - 1
    while (i >= 0) {
        if (p[i] == 47u8) {  // '/'
            return p[(i + 1)..p.size]
        }
        i -= 1
    }
    return p
}

/**
 * 在字符串 s 中查找子串 sub 的首次出现位置, 未找到返回 -1
 */
func indexOfString(s: String, sub: String): Int64 {
    if (sub.size == 0) {
        return 0
    }
    if (s.size < sub.size) {
        return -1
    }
    var i: Int64 = 0
    let limit: Int64 = s.size - sub.size
    while (i <= limit) {
        var found: Bool = true
        var j: Int64 = 0
        while (j < sub.size) {
            if (s[i + j] != sub[j]) {
                found = false
                break
            }
            j += 1
        }
        if (found) {
            return i
        }
        i += 1
    }
    return -1
}

/**
 * 直接匹配 glob 模式（递归算法，不转正则）
 *
 * 递归算法：
 * - 模式以 `**` 开头：`**` 匹配 0 个或多个字符（跨目录），然后匹配剩余模式
 * - 模式以 `*` 开头：`*` 匹配 0 个或多个非 / 字符，然后匹配剩余模式
 * - 模式以 `?` 开头：`?` 匹配 1 个非 / 字符，然后匹配剩余模式
 * - 其他字符：精确匹配
 *
 * @param pattern glob 模式
 * @param pi 模式当前位置
 * @param text 要匹配的文本
 * @param ti 文本当前位置
 */
func globMatchDirect(pattern: String, pi: Int64, text: String, ti: Int64): Bool {
    let pn = pattern.size
    let tn = text.size

    // 模式耗尽：文本也必须耗尽才算匹配
    if (pi >= pn) {
        return ti >= tn
    }

    let pc = pattern[pi]

    // ** 匹配任意字符(跨目录)
    if (pc == 42u8 && pi + 1 < pn && pattern[pi + 1] == 42u8) {
        // ** 后面可能跟 / (**/path) 或直接是路径结尾
        var nextPi = pi + 2
        if (nextPi < pn && pattern[nextPi] == 47u8) {
            nextPi += 1
        }
        // ** 匹配 0 个或多个字符, 尝试所有可能的位置
        if (nextPi >= pn) {
            return true  // ** 在模式末尾, 匹配剩余所有字符
        }
        var k = ti
        while (k <= tn) {
            if (globMatchDirect(pattern, nextPi, text, k)) {
                return true
            }
            k += 1
        }
        return false
    }

    // * 匹配 0 个或多个非 / 字符
    if (pc == 42u8) {
        // 尝试匹配 0 个字符
        if (globMatchDirect(pattern, pi + 1, text, ti)) {
            return true
        }
        // 尝试匹配 1 个或多个非 / 字符
        var k = ti
        while (k < tn && text[k] != 47u8) {
            k += 1
            if (globMatchDirect(pattern, pi + 1, text, k)) {
                return true
            }
        }
        return false
    }

    // ? 匹配 1 个非 / 字符
    if (pc == 63u8) {
        if (ti >= tn || text[ti] == 47u8) {
            return false
        }
        return globMatchDirect(pattern, pi + 1, text, ti + 1)
    }

    // 精确匹配
    if (ti >= tn) {
        return false
    }
    if (pc != text[ti]) {
        return false
    }
    return globMatchDirect(pattern, pi + 1, text, ti + 1)
}
