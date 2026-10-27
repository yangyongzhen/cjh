package cjh.tests

import cjutil.*

import std.fs.*
import std.process.*

/**
 * 测试辅助：临时文件/目录创建、读写、清理
 *
 * 约定：每个测试类用独立目录名（/tmp/cjh_ut_<name>），
 * 用例内创建、用例后或断言前清理，避免测试间互相污染。
 */

/**
 * 创建并返回测试目录（已清理旧目录，保证从空目录开始）
 */
func testTempDir(name: String): String {
    let dir = tmpPath("cjh_ut_") + name
    removeTree(dir)
    Directory.create(dir, recursive: true)
    return dir
}

/**
 * 重复字符串 n 次（String.repeat 在仓颉 std 不可靠，自建）
 */
func repeatStr(s: String, n: Int64): String {
    var sb = StringBuilder()
    for (i in 0..n) {
        sb.append(s)
    }
    return sb.toString()
}

/**
 * 写文本文件（UTF-8）
 */
func writeTextFile(path: String, content: String): Unit {
    File.writeTo(path, content.toArray())
}

/**
 * 读文本文件（UTF-8）
 */
func readTextFile(path: String): String {
    return String.fromUtf8(File.readFrom(path))
}

/**
 * 递归删除文件/目录
 *
 * Cangjie 1.2.0 迁移：改用 `std.fs.removeIfExists(path, recursive: true)`。
 * 原实现 shell 出去调 `/bin/bash -c "rm -rf"`——Windows 上 `/bin/bash` 不存在（异常被
 * catch 吞掉），清理静默失败 → 下一次 `Directory.create` 报 "path is already exists"，
 * 于是 skills/trust/ast_grep 等用例在重复运行/Windows 上直接 ERROR。
 */
func removeTree(path: String): Unit {
    try {
        removeIfExists(path, recursive: true)
    } catch (e: Exception) {
        // 清理失败不影响测试结果
    }
}
