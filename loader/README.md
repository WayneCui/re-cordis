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

## API

| 函数 | 语义 |
|------|------|
| `mount-entry-list` | 递归挂载 |
| `dump-entry-block` | YAML 风格打印（供 `--dump-config`） |
