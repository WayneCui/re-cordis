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
| `mount-entry-list` | 递归挂载 |
| `dump-entry-block` | YAML 风格打印（供 `--dump-config`） |
| `reload-plugin ctx name path` | 同像热替换：`do path` 得到新插件 → `registry/reload` 换名下的 fiber；加载失败或形状不对时旧插件原样保留 |

## reload 语义

- 文件必须求值为插件 object（`name` / `inject` / `apply`）。
- 旧 fiber 先 dispose（effect 逆序：服务 unprovide、listener 摘除），新插件按旧 fiber 的 config + parent ctx 重新挂载。
- 挂载失败回滚：旧 callback 重新 `plugin()`。
- 依赖该服务的 fiber 经 `reflect/notify` 走 epoch 重载链。
