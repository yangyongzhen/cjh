package cjh.web

/**
 * Web 接口对外自述的版本号
 *
 * 历史坑：`/api/health` 里把版本写死成 "1.3.0" 后一直没人改，发到 1.5.x 仍报 1.3.0，
 * 客户端据此判断服务端能力的就会踩空。这里收成单一常量，两个 health 处理函数共用，
 * 发版时与根 cjpm.toml 的 version、cjterm 的 Logo.VERSION 一起同步
 * （`WebVersionSyncTest` 会断言它与 Logo.VERSION 一致，改漏会红）。
 */
public let CJH_WEB_VERSION: String = "1.6.0"
