# done 帧为什么只加一个 `truncated`：一次对外协议扩展的完整推演

> 背景：`cjh` 的内置 Web 通道用 WebSocket 把 Agent 回合推给浏览器/桌面客户端。
> 协议已经有 `finish_reason`（回合结束原因），某天需要回答一个新问题：
> **"这段答案是被上游 `max_tokens` 截断的，还是真的说完了？"**

答案看起来很简单——加个新取值不就行了？这篇讲的正是为什么不能，以及最后怎么加才不留坑。

## 一、第一直觉：给 `finish_reason` 加第四个值 `length`

OpenAI 风格的 `finish_reason` 早就有 `length` 这个值，直觉上照抄最省事：

```jsonc
{ "type": "done", "finish_reason": "length" }
```

但如果这个协议已经发出去了、已有客户端在跑，这个改动是**破坏性**的。

原因是 `finish_reason` 在这里是**封闭枚举**，客户端会这么写：

```js
switch (frame.finish_reason) {
  case "stop":      finishOk(); break;
  case "cancelled": markInterrupted(); break;
  case "error":     showError(); break;
  default:          /* 老客户端：不知道这是什么 */
}
```

老客户端遇到 `length` 会掉进 `default`，或者更糟——某个把 `switch` 写成
`if (r === 'stop') {...} else { /* 视为正常结束 */ }` 的实现，会把**被截断的半截回答
当成完整结果**展示给用户。这不是显示小瑕疵，是让用户以为模型说了"以上就是全部"。

所以：**新增取值 = 让老客户端的行为不可预测**。这条线不能越。

## 二、方案：加一个「可选布尔」，只在真截断时出现

```jsonc
{ "type": "done", "finish_reason": "stop", "truncated": true }
```

三条设计约束：

1. **默认不出现**。只有真的被上游 `max_tokens` 截断时才序列化 `truncated`。
   缺键 = 未截断。这样绝大多数 done 帧的字节数一个都没变。
2. **不新增取值，只新增字段**。老客户端不认识 `truncated` 会忽略它，行为与今天完全一致；
   新客户端读到 `true` 才提示"回答可能不完整"。
3. **`finish_reason` 仍是封闭三值** `stop / cancelled / error`，并在代码注释里写死理由，
   防止后人"顺手"把它扩成四值。

这段注释就留在 `DoneEvent` 的文档注释里：

```cangjie
/**
 * finish_reason：stop（正常收尾）/ cancelled（回合被中断）/ error（回合内异常）。
 * 三值封闭，**不**为 max_tokens 截断新增第四个取值（那对老客户端是破坏性扩展）；
 * 截断改由可选布尔 truncated 承载——只在真被截断时出现，缺键即"未截断"。
 */
public class DoneEvent {
    public var finishReason: String = "stop"
    // 最终回复被上游 max_tokens 截断（可选键：仅 true 时序列化）
    public var truncated: Bool = false
}
```

序列化侧：

```cangjie
if (this.truncated) { obj.put("truncated", JsonBool(true)) }
```

注意这里是"仅 true 时写"，不是"总是写"。永远写 `false` 也不算错，但会让每个 done 帧
都多一个键——一旦哪天有人把语义改成"缺键 = 未知"，历史帧就解释不清了。保持"缺键即默认值
= false"，语义最干净。

## 三、信号从哪来：一条 5 跳的链路

协议的字段不难写，难的是**信号别在中途蒸发**。截断信号的真实来源在上游 provider：

```
provider.cj  StreamAccumulator.truncated   ← 上游 finish_reason == "length" 时置位
      ↓
loop.cj      最终回复 / 工具调用参数被截断时读取该标志
      ↓
RunSummary   回合总结里携带 truncated
      ↓
网关 done 帧  组装 DoneEvent
      ↓
DoneEvent.toJson → 浏览器 / 桌面客户端
```

两条来源要分开看：

- **工具调用参数被截断**（`provider.cj` 的 tool_call 分支）：写文件类工具最容易中招——
  上游把 `write_file` 的 `content` 参数截在半截 JSON 里。这类需要的是**修复截断 JSON**
  （优先处理"字符串被截断"的情形：先补 `"` 闭合 content，再补 `}` 闭合对象），
  和对外 `truncated` 是两件事。
- **最终回复被截断**：这才是要告诉用户"回答不完整"的场景。

## 四、最容易丢字段的地方：白名单重建

链路里有一跳最容易出事，也是这次真正踩到的坑：

`web_channel.sendDone` 不是把 `RunSummary` 直接丢给 `toJson`，而是**按字段白名单
重建一个 `DoneEvent`**：

```cangjie
public func sendDone(_: String, meta: FrameMeta, summary: RunSummary): Unit {
    var ev = DoneEvent()
    ev.rounds = summary.rounds
    ev.tools = summary.toolCalls
    ev.durationMs = summary.durationMs
    ev.tokens = summary.tokens
    ev.cached = summary.cached
    ev.finishReason = summary.finishReason
    // ← 少了这一行，前面四跳全白干
    ev.truncated = summary.truncated
    ...
}
```

这就是"新增对外键必须逐跳数清"的原因：字段在模型层有了、在 `RunSummary` 有了、
`toJson` 也写了——它照样可能在你没数到的那一跳被扔掉，而且**编译不报错**，
测试不覆盖的话上线才发现。

这次写测试时还顺带抓到一个替身问题：测试用 `StubProvider` 直接塞了一个现成的 done JSON，
却没经过 `sendDone` 的重建，于是索引越界（`IndexOutOfBoundsException`）——**替身走的路
必须和真实路径同构**，否则测试测的是替身自己。

## 五、截断 ≠ 失败：两套信号不要混

`cancelled`（用户中断）、`error`（回合内异常）、`truncated`（上游截断）是三种不同的事，
混在一起会让客户端文案彻底错乱：

| 情形 | 帧 | 客户端该做什么 |
|---|---|---|
| 正常收尾 | `done{finish_reason:"stop"}` | 展示完毕 |
| 用户取消 | `done{finish_reason:"cancelled"}` | 标记中断、保留已有内容 |
| 回合内异常 | `error{code,retryable}` 然后 `done{finish_reason:"error"}` | 按 code 给文案，可重试的给重试按钮 |
| 上游截断 | `done{finish_reason:"stop",truncated:true}` | 提示"回答可能不完整" |

失败分类器独立成文件（`src/agent/failure.cj`），只产出四类可判定错误：
`provider_unreachable` / `provider_auth_error` / `provider_rate_limited` / `provider_error`，
每类带 `retryable` 语义。`cancelled` 优先——用户自己按了停止，不该被报成 provider 出错。

还有一条容易写错的细则：**`truncated` 只在最终回复真被上游 max_tokens 截断时置位**。
中断、异常、本地硬顶（比如自己设的输出上限）都不置位。否则客户端每次中断都看到
"回答不完整"，这个提示很快就没人看了。

## 六、能力自述：让客户端不必猜

字段加了，客户端怎么知道对端支持？答案是 `capabilities` 帧——但要**如实枚举**，
不能"报即将支持"：

```jsonc
{
  "protocol": 2,
  "ws_in":  ["chat", "abort", "cancel", "switch_model", "new_session", "resume_session", "compact", "approval_response"],
  "ws_out": ["delta", "tool_start", "tool_result", "done", "error", "tasks", "approval_request", ...],
  "features": {
    "finish_reasons": ["stop", "cancelled", "error"],   // 封闭三值，不含 length
    "structured_errors": true,
    "diff_in_tool_result": true,
    "control_frame_acks": true,
    "cancel_receipt": true
  }
}
```

两点经验：

1. **能从帧清单推导的位就别手写**。`control_frame_acks` 是
   `ws_in 含 switch_model 且含 compact` 推出来的，`cancel_receipt` 是 `ws_in 含 cancel`
   推出来的——清单变了，能力位自动跟着变，不会与实现漂移。
2. **`finish_reasons` 显式列三值**。这是把"我们没有 length"从口头约定变成可读契约：
   客户端可以直接断言"服务端只可能返回这三种"，不用担心哪天冒出第四种。

## 七、测试怎么写

四个用例足够把这个字段钉死：

1. `truncated = true` 时序列化出该键，且 `finish_reason` 仍是 `stop`
2. `truncated = false` 时**不出现**该键（缺键语义）
3. 从 `RunSummary.truncated` 经 `sendDone` 到 `toJson` 的**透传**（专门盯白名单那一跳）
4. 中断/异常场景**不置位**（防误报）

第 3 条是最有价值的：它专门覆盖"中间层重建丢字段"这类编译期无感知的错误。

## 八、新增对外键的五步清单

从这次总结出来，之后每加一个对外键都照这条走：

1. **产生处**：信号在哪个结构体里产生，谁置位
2. **模型层**：回合总结（`RunSummary`）是否携带
3. **事件层**：事件类有没有这个字段、默认值是什么
4. **序列化**：是"总是写"还是"仅非默认写"，缺键语义写进注释
5. **客户端**：收到后的行为，老客户端的降级行为是什么

跳任何一跳的表现都是：单测绿、端到端绿、客户端永远收不到。所以第 5 步之后再加一条
**透传测试**，把中间层也钉住。

## 小结

- 已发布的封闭枚举上**不加新取值**，改用可选字段承载新信息
- 可选字段遵循"缺键 = 默认值"，只在偏离默认时序列化
- 新信号必须逐跳数清，并在中间层补透传测试
- 截断、中断、失败是三件事，各自的信号不要互相顶替
- 能力自述如实枚举：能推导的推导，不能推导的显式列契约
