package cjcfg

/**
 * 工作区管理：多项目目录注册、持久化、最近访问排序
 *
 * 存储位置：~/.cjh/workspaces.json
 * 格式：[{ "path": "/abs/dir", "name": "my-project", "lastAccess": 1787000000 }, ...]
 *
 * 设计原则：单一职责（仅工作区 CRUD），供 cjh.web 等上层包复用。
 */

import std.collection.*
import std.convert.*
import std.fs.*
import std.time.*
import stdx.encoding.json.*

/**
 * 工作区条目
 */
public class Workspace {
    public var path: String
    public var name: String
    public var lastAccess: Int64

    public init(path: String, name: String, lastAccess: Int64) {
        this.path = path
        this.name = name
        this.lastAccess = lastAccess
    }

    /**
     * 序列化为 JsonObject
     */
    public func toJson(): JsonObject {
        var obj = JsonObject()
        obj.put("path", JsonString(this.path))
        obj.put("name", JsonString(this.name))
        obj.put("lastAccess", JsonInt(this.lastAccess))
        return obj
    }

    /**
     * 从 JsonObject 反序列化
     */
    public static func fromJson(obj: JsonObject): Workspace {
        var path = ""
        var name = ""
        var lastAccess: Int64 = 0
        if (let Some(v) <- obj.get("path")) {
            match (v.kind()) {
                case JsonKind.JsString => path = v.asString().getValue()
                case _ => ()
            }
        }
        if (let Some(v) <- obj.get("name")) {
            match (v.kind()) {
                case JsonKind.JsString => name = v.asString().getValue()
                case _ => ()
            }
        }
        if (let Some(v) <- obj.get("lastAccess")) {
            match (v.kind()) {
                case JsonKind.JsInt => lastAccess = v.asInt().getValue()
                case _ => ()
            }
        }
        return Workspace(path, name, lastAccess)
    }
}

/**
 * 工作区管理器：CRUD + 持久化
 *
 * 持久化文件：~/.cjh/workspaces.json
 * 排序：按 lastAccess 倒序（最近访问在前）
 */
public class WorkspaceManager {
    private let storePath: String
    private var workspaces: ArrayList<Workspace> = ArrayList<Workspace>()

    public init(configDir: String) {
        this.storePath = configDir + "/workspaces.json"
        this.load()
    }

    /**
     * 从磁盘加载工作区列表
     */
    private func load(): Unit {
        if (!exists(this.storePath)) {
            return
        }
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.storePath)))
            match (json.kind()) {
                case JsonKind.JsArray =>
                    let arr = json.asArray()
                    for (i in 0..arr.size()) {
                        let item = arr[i]
                        var isObj = false
                        match (item.kind()) {
                            case JsonKind.JsObject => isObj = true
                            case _ => ()
                        }
                        if (isObj) {
                            this.workspaces.add(Workspace.fromJson(item.asObject()))
                        }
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            // 解析失败：忽略，用空列表
        }
    }

    /**
     * 持久化工作区列表到磁盘
     */
    public func save(): Unit {
        let dir = this.storePath[0..this.storePath.lastIndexOf("/").getOrThrow()]
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        let arr = JsonArray()
        for (i in 0..this.workspaces.size) {
            arr.add(this.workspaces[i].toJson())
        }
        File.writeTo(this.storePath, arr.toJsonString().toArray())
    }

    /**
     * 列出所有工作区（按 lastAccess 倒序）
     */
    public func list(): ArrayList<Workspace> {
        // 复制到新列表，按 lastAccess 倒序排序（简单选择排序）
        let sorted = ArrayList<Workspace>()
        for (w in this.workspaces) {
            sorted.add(w)
        }
        // 冒泡排序：lastAccess 大的在前
        var n = sorted.size
        while (n > 1) {
            var newN = 0
            for (i in 1..n) {
                if (sorted[i - 1].lastAccess < sorted[i].lastAccess) {
                    let tmp = sorted[i - 1]
                    sorted[i - 1] = sorted[i]
                    sorted[i] = tmp
                    newN = i
                }
            }
            n = newN
        }
        return sorted
    }

    /**
     * 添加工作区（path 唯一；已存在则更新 name + lastAccess）
     * @param path 工作区绝对路径
     * @param name 显示名（空则用路径最后一段）
     * @return 添加/更新后的 Workspace
     */
    public func add(path: String, name: String): Workspace {
        // 默认名称：路径最后一段
        let finalName = if (name.size > 0) { name } else {
            let slashIdx = path.lastIndexOf("/")
            if (slashIdx.isSome()) {
                let idx = slashIdx.getOrThrow()
                if (idx + 1 < path.size) { path[idx + 1..] } else { path }
            } else {
                path
            }
        }
        let now = DateTime.now().toUnixTimeStamp().toSeconds()
        // 查找是否已存在同 path 的工作区
        for (i in 0..this.workspaces.size) {
            if (this.workspaces[i].path == path) {
                this.workspaces[i].name = finalName
                this.workspaces[i].lastAccess = now
                return this.workspaces[i]
            }
        }
        // 新增
        let w = Workspace(path, finalName, now)
        this.workspaces.add(w)
        return w
    }

    /**
     * 删除工作区（按 path）
     */
    public func remove(path: String): Bool {
        var found = false
        var i = 0
        while (i < this.workspaces.size) {
            if (this.workspaces[i].path == path) {
                this.workspaces.remove(i..i + 1)
                found = true
            } else {
                i += 1
            }
        }
        return found
    }

    /**
     * 更新最后访问时间（切换工作区时调用）
     */
    public func touch(path: String): Unit {
        let now = DateTime.now().toUnixTimeStamp().toSeconds()
        for (i in 0..this.workspaces.size) {
            if (this.workspaces[i].path == path) {
                this.workspaces[i].lastAccess = now
                return
            }
        }
    }
}
