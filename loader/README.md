# loader

职责：把 entry 列表挂到 `ctx/registry/plugin`；`dump-entry-block` 打印组装后的树。

不做什么：不读文件（include）、不 HMR、不 npm import。

## Entry 字段

| 字段 | 含义 |
|------|------|
| `id` | 稳定 id（patch 目标） |
| `name` | plugin-map 中的 word（如 `host` → `host-plugin`） |
| `config` | 传给 `registry/plugin` 的 map |
| `group` | 真 → `config` 为子 entry 块 |
| `disabled` | 真 → 跳过挂载 |
| `isolate` | `service: label` 挂到隔离 ctx |
| `intercept` | `service: {config}` 前置到 ctx intercept-chain；`llm`/`agent-loop` 经 `service-resolve-config` 消费 |

## API

| 函数 | 语义 |
|------|------|
| `mount-entry-list` | 递归挂载；全量，不做增量 |
| `dump-entry-block` | YAML 风格打印（供 `--dump-config`） |
| `reload-plugin ctx name path` | 同像热替换：`do path` 得到新插件 → `registry/reload` 换名下的 fiber；加载失败或形状不对时旧插件原样保留 |
| `make-entry-reconciler root plugin-map` | **M2** 按稳定 `id` 增量 reconcile（`loader/reconcile.reb`） |

## Entry Reconciler（M2）

与 `mount-entry-list` 并列：后者全量挂载，前者按 id diff。

```
r: make-entry-reconciler root plugin-map
r/reconcile entries
r/get "a"             ; handle: options / fiber / mount-ctx / parent-id / child-ids
r/size
r/stop
```

| 情况 | 行为 |
|------|------|
| 同 id + options 深相等 | 保持（不 remount） |
| 仅 `config`（及非身份字段）变化 | leaf 走 `fiber/update`；group 只改 options |
| `name` / `isolate` / `intercept` / `inject` / `group` 变化，或 parent 移动 | dispose + remount |
| desired 中消失，或 `disabled` | dispose 子树 |
| `group` | 无 fiber；子节点挂到 group 的 `mount-ctx`（比 `mount-entry-list` 对 group 更完整） |

无 `id` 时写入合成键 `"reconcile-id"`（Rebol word 不能含 `$`）。

验收：`test/reconcile-test.reb`、`scenarios/m2-reconcile.reb`。

## reload 语义

- 文件必须求值为插件 object（`name` / `inject` / `apply`）。
- 旧 fiber 先 dispose（effect 逆序：服务 unprovide、listener 摘除），新插件按旧 fiber 的 config + parent ctx 重新挂载。
- 挂载失败回滚：旧 callback 重新 `plugin()`。
- 依赖该服务的 fiber 经 `reflect/notify` 走 epoch 重载链。
