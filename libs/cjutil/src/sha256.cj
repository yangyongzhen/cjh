package cjutil

/**
 * SHA256 校验和工具（V3 信任链 Step 1）
 *
 * 用途：
 *   - 插件目录递归 hash（检测篡改）
 *   - .cjp 包本体校验（打包/安装时）
 *
 * 设计：
 *   - 文件按相对路径排序后逐个 hash，保证跨平台确定性
 *   - 每个文件：hash(相对路径) + hash(文件内容)
 *   - 最终拼接所有文件 hash 再做一次 SHA256，得到目录指纹
 *
 * 仓颉 API：stdx.crypto.digest.SHA256
 *   - 实例化后 hasher.write(bytes) 分段写入
 *   - hasher.finish() 返回 Array<Byte>（32 字节摘要）
 *   - finish 后需 reset 才能复用
 */

import stdx.crypto.digest.*
import std.fs.*
import std.collection.*

/**
 * 计算字节数组的 SHA256 摘要
 * @return 32 字节摘要的十六进制字符串（小写）
 */
public func sha256Hex(data: Array<Byte>): String {
    let hasher = SHA256()
    hasher.write(data)
    return bytesToHex(hasher.finish())
}

/**
 * 计算字符串的 SHA256 摘要
 * @return 32 字节摘要的十六进制字符串（小写）
 */
public func sha256HexStr(s: String): String {
    return sha256Hex(stringToBytes(s))
}

/**
 * 递归计算目录的 SHA256 指纹
 *
 * 算法（确定性、跨平台）：
 *   1. 递归收集目录下所有文件，按相对路径字典序排序
 *   2. 对每个文件：update(hash(相对路径) || hash(文件内容))
 *   3. 最终 finish() 得到 32 字节目录指纹
 *
 * @param dirPath  目录绝对路径
 * @return 32 字节摘要的十六进制字符串；目录不存在返回 ""
 */
public func sha256Dir(dirPath: String): String {
    if (!exists(dirPath)) {
        return ""
    }

    // 收集所有文件的相对路径
    // 仓颉 lambda 不能捕获 mutable 变量，用 let ArrayList 引用（内部可变）
    let allFiles = ArrayList<FileInfo>()
    Directory.walk(dirPath, { fi =>
        if (!fi.isDirectory()) {
            allFiles.add(fi)
        }
        return true
    })

    if (allFiles.size == 0) {
        return sha256HexStr("")
    }

    // 转为相对路径列表
    var relPaths = ArrayList<String>()
    for (fi in allFiles) {
        let full = fi.path.toString()
        var rel = full
        if (full.startsWith(dirPath)) {
            rel = full[dirPath.size..full.size]
        }
        rel = rel.replace("\\", "/")
        if (rel.startsWith("/")) {
            rel = rel[1..rel.size]
        }
        relPaths.add(rel)
    }

    // 按相对路径字典序排序（简单冒泡，避免 API 不确定性）
    for (i in 0..relPaths.size) {
        for (j in (i + 1)..relPaths.size) {
            if (relPaths[i] > relPaths[j]) {
                let tmp = relPaths[i]
                relPaths[i] = relPaths[j]
                relPaths[j] = tmp
            }
        }
    }

    // 逐个文件 update
    let hasher = SHA256()
    for (relPath in relPaths) {
        let fullPath = dirPath + "/" + relPath
        try {
            let content = File.readFrom(fullPath)
            hasher.write(stringToBytes(relPath))
            hasher.write(content)
        } catch (e: Exception) {
            // 读不出的文件跳过
        }
    }

    return bytesToHex(hasher.finish())
}

/**
 * 计算文件的 SHA256 摘要
 * @return 32 字节摘要的十六进制字符串；文件不存在返回 ""
 */
public func sha256File(filePath: String): String {
    if (!exists(filePath)) {
        return ""
    }
    try {
        let content = File.readFrom(filePath)
        return sha256Hex(content)
    } catch (e: Exception) {
        return ""
    }
}

/**
 * 计算目录的 SHA256 指纹，排除指定文件名
 *
 * 用途：插件校验和计算时排除 plugin.json 自身
 * （plugin.json 里存了 checksum，hash 它会循环依赖）
 *
 * @param dirPath       目录路径
 * @param excludeFile   要排除的文件名（相对目录根，如 "plugin.json"）
 * @return 32 字节摘要的十六进制字符串；目录不存在返回 ""
 */
public func sha256DirExcluding(dirPath: String, excludeFile: String): String {
    if (!exists(dirPath)) {
        return ""
    }

    // 收集所有文件的 FileInfo（仓颉 lambda 不能捕获 mutable 变量）
    let allFiles = ArrayList<FileInfo>()
    Directory.walk(dirPath, { fi =>
        if (!fi.isDirectory()) {
            allFiles.add(fi)
        }
        return true
    })

    if (allFiles.size == 0) {
        return sha256HexStr("")
    }

    // 转为相对路径列表，排除指定文件
    var relPaths = ArrayList<String>()
    for (fi in allFiles) {
        let full = fi.path.toString()
        var rel = full
        if (full.startsWith(dirPath)) {
            rel = full[dirPath.size..full.size]
        }
        rel = rel.replace("\\", "/")
        if (rel.startsWith("/")) {
            rel = rel[1..rel.size]
        }
        // 排除指定文件
        if (rel != excludeFile) {
            relPaths.add(rel)
        }
    }

    if (relPaths.size == 0) {
        return sha256HexStr("")
    }

    // 按相对路径字典序排序（简单冒泡）
    for (i in 0..relPaths.size) {
        for (j in (i + 1)..relPaths.size) {
            if (relPaths[i] > relPaths[j]) {
                let tmp = relPaths[i]
                relPaths[i] = relPaths[j]
                relPaths[j] = tmp
            }
        }
    }

    // 逐个文件 update
    let hasher = SHA256()
    for (relPath in relPaths) {
        let fullPath = dirPath + "/" + relPath
        try {
            let content = File.readFrom(fullPath)
            hasher.write(stringToBytes(relPath))
            hasher.write(content)
        } catch (e: Exception) {
            // 读不出的文件跳过
        }
    }

    return bytesToHex(hasher.finish())
}

/**
 * 字节数组转十六进制字符串（小写）
 */
public func bytesToHex(bytes: Array<Byte>): String {
    let hexChars = "0123456789abcdef"
    let runes = hexChars.toRuneArray()
    let sb = StringBuilder()
    for (b in bytes) {
        let v = UInt64(b)
        let high = (v >> 4) & 0x0F
        let low = v & 0x0F
        sb.append(String(runes[Int64(high)]))
        sb.append(String(runes[Int64(low)]))
    }
    return sb.toString()
}

/**
 * 十六进制字符串转字节数组
 * @return 解析失败返回空数组
 */
public func hexToBytes(hex: String): Array<Byte> {
    if (hex.size % 2 != 0) {
        return Array<Byte>(0, repeat: UInt8(0))
    }
    var bytes = Array<Byte>(hex.size / 2, repeat: UInt8(0))
    for (i in 0..hex.size / 2) {
        // String 索引返回 Byte（UTF-8 编码字节）；ASCII hex 字符单字节
        let high = hexCharToValue(UInt8(hex[i * 2]))
        let low = hexCharToValue(UInt8(hex[i * 2 + 1]))
        if (high < 0 || low < 0) {
            return Array<Byte>(0, repeat: UInt8(0))
        }
        let val = (UInt64(high) << 4) | UInt64(low)
        bytes[i] = UInt8(val)
    }
    return bytes
}

/**
 * 单个十六进制字符转数值（0-15），非法字符返回 -1
 * @param b ASCII 字节（'0'-'9','a'-'f','A'-'F'）
 */
private func hexCharToValue(b: UInt8): Int64 {
    // 用常量字节值，避免 Rune → UInt8 转换问题
    let v = UInt64(b)
    let zero = UInt64(48)   // '0' ASCII
    let nine = UInt64(57)   // '9' ASCII
    let a = UInt64(97)      // 'a' ASCII
    let f = UInt64(102)     // 'f' ASCII
    let A = UInt64(65)      // 'A' ASCII
    let F = UInt64(70)      // 'F' ASCII
    if (v >= zero && v <= nine) {
        return Int64(v - zero)
    }
    if (v >= a && v <= f) {
        return Int64(v - a) + 10
    }
    if (v >= A && v <= F) {
        return Int64(v - A) + 10
    }
    return -1
}

/**
 * String 转 UTF-8 字节数组
 */
public func stringToBytes(s: String): Array<Byte> {
    let runes = s.toRuneArray()
    var bytes = ArrayList<Byte>()
    for (r in runes) {
        let v = UInt64(UInt32(r))
        if (v < 0x80) {
            bytes.add(UInt8(v))
        } else if (v < 0x800) {
            bytes.add(UInt8(0xC0 | (v >> 6)))
            bytes.add(UInt8(0x80 | (v & 0x3F)))
        } else if (v < 0x10000) {
            bytes.add(UInt8(0xE0 | (v >> 12)))
            bytes.add(UInt8(0x80 | ((v >> 6) & 0x3F)))
            bytes.add(UInt8(0x80 | (v & 0x3F)))
        } else {
            bytes.add(UInt8(0xF0 | (v >> 18)))
            bytes.add(UInt8(0x80 | ((v >> 12) & 0x3F)))
            bytes.add(UInt8(0x80 | ((v >> 6) & 0x3F)))
            bytes.add(UInt8(0x80 | (v & 0x3F)))
        }
    }
    // ArrayList<Byte> → Array<Byte>
    var result = Array<Byte>(bytes.size, repeat: UInt8(0))
    for (i in 0..bytes.size) {
        result[i] = bytes[i]
    }
    return result
}
