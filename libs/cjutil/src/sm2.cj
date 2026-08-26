package cjutil

/**
 * SM2 签名验证（V3 信任链 Step 2）
 *
 * 用途：
 *   - 插件加载时验签（plugin.json 的 pubkey/signature/checksum 字段）
 *   - 防供应链投毒 + 中间人篡改
 *
 * 方案：仓颉原生 stdx.crypto.keys SM2 验签
 *   - SM2PublicKey.verify(data, sig) 直接验签
 *   - SM2 采用 SM3 摘要算法（国密标准，仓颉原生支持）
 *   - 零外部依赖，高内聚
 *
 * 签名格式：SM2 签名结果为 DER 编码的 (r, s) 序列
 * 验签流程：
 *   1. pubkey hex → DerBlob → SM2PublicKey.decodeDer 重建公钥
 *   2. signature hex → Array<Byte>（DER 编码的签名）
 *   3. checksum 值 → Array<Byte>（被签名的数据）
 *   4. SM2PublicKey.verify(checksumBytes, signatureBytes) 验签
 */

import stdx.crypto.keys.*
import stdx.crypto.x509.DerBlob
import std.crypto.digest.*

/**
 * SM2 验签结果
 */
public enum Sm2VerifyResult {
    | Verified       // 验签通过
    | Invalid        // 验签失败（签名不匹配）
    | BadKey         // 公钥格式错误（DER 解码失败）
    | BadSignature   // 签名格式错误（hex 解码失败）
    | Error          // 其他错误
}

/**
 * SM2 验签
 *
 * @param pubkeyHex     发布者 SM2 公钥（DER 编码的十六进制字符串）
 * @param signatureHex  对 checksum 的 SM2 签名（DER 编码的十六进制字符串）
 * @param checksum      校验和值（64 位十六进制字符串，即被签名的数据）
 * @return Sm2VerifyResult
 */
public func verifySm2(pubkeyHex: String, signatureHex: String,
    checksum: String): Sm2VerifyResult {
    // 基本参数校验
    if (pubkeyHex.size == 0 || pubkeyHex.size % 2 != 0) {
        return Sm2VerifyResult.BadKey
    }
    if (signatureHex.size == 0 || signatureHex.size % 2 != 0) {
        return Sm2VerifyResult.BadSignature
    }
    if (checksum.size != 64) {
        return Sm2VerifyResult.Error  // checksum 应为 64 位十六进制
    }

    // 1. pubkey hex → DerBlob → SM2PublicKey
    let pubkeyBytes = hexToBytes(pubkeyHex)
    if (pubkeyBytes.size == 0) {
        return Sm2VerifyResult.BadKey
    }

    let pubkey: SM2PublicKey
    try {
        let derBlob = DerBlob(pubkeyBytes)
        pubkey = SM2PublicKey.decodeDer(derBlob)
    } catch (e: Exception) {
        return Sm2VerifyResult.BadKey
    }

    // 2. signature hex → Array<Byte>
    let signatureBytes = hexToBytes(signatureHex)
    if (signatureBytes.size == 0) {
        return Sm2VerifyResult.BadSignature
    }

    // 3. checksum 值 → Array<Byte>（被签名的数据）
    let dataBytes = hexToBytes(checksum)
    if (dataBytes.size == 0) {
        return Sm2VerifyResult.Error
    }

    // 4. SM2PublicKey.verify 验签
    try {
        let valid = pubkey.verify(dataBytes, signatureBytes)
        if (valid) {
            return Sm2VerifyResult.Verified
        } else {
            return Sm2VerifyResult.Invalid
        }
    } catch (e: Exception) {
        return Sm2VerifyResult.Error
    }
}

/**
 * SM2 签名（用于测试和发布工具）
 *
 * @param privateKey  SM2 私钥
 * @param data        待签名数据
 * @return 签名（DER 编码的 Array<Byte>）
 */
public func signSm2(privateKey: SM2PrivateKey, data: Array<Byte>): Array<Byte> {
    return privateKey.sign(data)
}
