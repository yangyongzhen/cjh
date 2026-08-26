package gen_signed_demo

/**
 * 签名生成小程序（V3 信任链 Step 2 演示）
 *
 * 用途：给 example/plugins/signed-demo 插件生成真实的 SM2 签名，
 *       把 checksum/publisher/pubkey/signature 四个字段写回 plugin.json。
 *
 * 流程：
 *   1. 算 checksum = sha256DirExcluding(pluginDir, "plugin.json")
 *   2. 生成 SM2 密钥对（演示用，真实场景私钥离线保管）
 *   3. 导出公钥 DER → hex
 *   4. 用私钥签 checksum 的字节 → signature hex
 *   5. 读 plugin.json，写入四个字段
 *
 * 运行：cjpm run -p gen_signed_demo
 */

import stdx.crypto.keys.*
import stdx.crypto.x509.DerBlob
import stdx.encoding.json.*
import std.fs.*
import cjutil.*

main(): Int64 {
    let pluginDir = "example/plugins/signed-demo"
    let publisher = "github:cjh-demo"
    let jsonPath = pluginDir + "/plugin.json"

    // 1. 算 checksum（排除 plugin.json）
    let checksum = sha256DirExcluding(pluginDir, "plugin.json")
    println("checksum = ${checksum}")
    if (checksum.size != 64) {
        println("ERROR: checksum 长度不为 64")
        return 1
    }

    // 2. 生成 SM2 密钥对
    let privateKey = SM2PrivateKey()
    let publicKey = SM2PublicKey(privateKey)

    // 3. 导出公钥 DER → hex
    let pubkeyDer = publicKey.encodeToDer()
    let pubkeyHex = bytesToHex(pubkeyDer.body)
    println("pubkey   = ${pubkeyHex}")

    // 4. 用私钥签 checksum 的字节
    let signatureBytes = signSm2(privateKey, hexToBytes(checksum))
    let signatureHex = bytesToHex(signatureBytes)
    println("signature= ${signatureHex}")

    // 5. 自验：verifySm2 应返回 Verified
    match (verifySm2(pubkeyHex, signatureHex, checksum)) {
        case Sm2VerifyResult.Verified =>
            println("self-verify: OK")
        case _ =>
            println("ERROR: 自验失败")
            return 1
    }

    // 6. 读 plugin.json，写入四个字段
    let raw = safeFromUtf8(File.readFrom(jsonPath))
    let obj = JsonValue.fromStr(raw).asObject()
    obj.put("checksum", JsonString(checksum))
    obj.put("publisher", JsonString(publisher))
    obj.put("pubkey", JsonString(pubkeyHex))
    obj.put("signature", JsonString(signatureHex))
    File.writeTo(jsonPath, stringToBytes(obj.toJsonString()))

    println("Done! plugin.json updated with SM2 signature.")
    return 0
}
