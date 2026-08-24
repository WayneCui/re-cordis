# include

职责：从 YAML 读 entry 列表、用 Rebol patch 块改写、与 Loader 共用同一套 patch 语义。

不做什么：不挂载插件、不解析 `!!js`、不做 HMR。

## API

| 函数 | 语义 |
|------|------|
| `read-entry-yaml` | 读最小 cordis.yml 风格列表 |
| `load-reb-patches` | `do` patch 文件，得 block |
| `apply-entry-patches` | 与 dsh include 对齐的 patch 算法 |
| `compose-entry-config` | base yaml + 多个 patch 文件 |

Patch 文件示例：

```rebol
; cordis.patch.reb
[
    make map! [id "llm" config make map! [script %echo.reb]]
]
```
