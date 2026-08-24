# include

职责：从 YAML 读 entry 列表、用 Rebol patch 块改写、与 Loader 共用同一套 patch 语义；支持多层 patch 叠层（bundle → profile → home → CLI）。

不做什么：不挂载插件、不解析 `!!js`、不做 HMR。

## API

| 函数 | 语义 |
|------|------|
| `read-entry-yaml` | 读最小 cordis.yml 风格列表 |
| `load-reb-patches` | `load/all` patch 文件，归一化 `make map!` 行 |
| `apply-entry-patches` | 与 dsh include 对齐的 patch 算法 |
| `compose-entry-config` | base yaml + 多个 patch 文件 |
| `compose-entry-layers` | 从空 entry 列表起，按层顺序 `apply-entry-patches` |

叠层顺序（与 dsh `composeEntries` 一致）：**bundle patches → profile `cordis.patch.reb` → home `cordis.patch.reb` → CLI `--patch` 文件**。

Patch 文件用 `load/all` 读取；嵌套 `config` 请用 `compose` 求值：

```rebol
; cordis.patch.reb
[
    make map! compose [
        id "llm"
        config (make map! [script %echo.reb])
    ]
]
```

根 insert（从空列表装配）示例见 `harness-spine/bundles/spine-base/cordis.patch.reb`。
