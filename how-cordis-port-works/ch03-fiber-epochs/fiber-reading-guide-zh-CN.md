# Day 3：`fiber.reb` 逐函数阅读清单

> 配套：`ch03-fiber-epochs-zh-CN/translation.md`、`test/fiber-test.reb`、`ref/core/fiber.ts`  
> 验证：`cd ch03-fiber-epochs/code && bash run.sh`（55 passed）

---

## 阅读前：三条主线

读任何函数前先问自己它属于哪条线：

| 主线 | 问题 | 关键函数 |
|------|------|----------|
| **A. 依赖纪元** | 注入的服务齐了没？provider uid 串是什么？ | `fiber-check-impl` → `fiber-refresh` → `fiber-set-epoch` |
| **B. 加载/卸载** | apply 何时跑？副作用何时清？ | `fiber-reload` ↔ `fiber-unload` |
| **C. 作用域清理** | 单次 effect 如何注册、逆序 dispose？ | `fiber-effect` |

完整触发链（Test 1 必背）：

```text
reflect/provide('foo')
  → reflect/notify(['foo])
  → fiber-check-impl + fiber-refresh（对每个 inject 'foo 的 fiber）
  → fiber-set-epoch（epoch 从 __INACTIVE__ 变为 :<rootUid>）
  → fiber-reload → plugin/apply → disposer 入 disposables
  → state = ACTIVE

reflect dispose / unprovide
  → epoch → __INACTIVE__
  → fiber-unload → disposables 逆序 dispose → store = none
  → state = PENDING
```

---

## 第 0 段：文件头 + 类型壳（33–76）

| 行号 | 符号 | 读什么 | 测试锚点 |
|------|------|--------|----------|
| 33 | `inactive-epoch` | 魔法字符串 `"__INACTIVE__"`，表示「依赖未齐」 | Test 1：`fb1/state` PENDING 时 `epoch` 即此值 |
| 35–42 | `fiber-state` | 六态枚举；Rebol 用整数，TS 用 enum | Test 1/2/3 各覆盖不同终态 |
| 45 | `all-fibers` | 全局 plugin fiber 注册表；stub reflect 的 notify 遍历它 | fiber-test 里 `notify-impls` |
| 51–76 | `fiber-type` | 字段含义 + 方法壳（委托给独立函数，Rebol 对象不能闭包帧变量） | Test 12：root `uid=0`, `name="root"` |

**字段速记**

- `inject`：word! → config，声明依赖名
- `store`：当前 epoch 下已解析的 impl 快照（ACTIVE 时有值，unload 后 `none`）
- `epoch`：provider uid 拼接串，或 `inactive-epoch`
- `disposables`：`DisposableList`，unload 时 **clear 后逆序 dispose**
- `hooks`：`internal-update` 专用 listener 列表（events 写入）
- `inertia`：同步版重入锁，防止 set-epoch 递归失控

**自测**：为什么方法都写成 `fiber-effect self :execute label` 而不是对象内直接写逻辑？

---

## 第 1 段：小工具（82–111）

| 行号 | 符号 | 作用 |
|------|------|------|
| 82–88 | `map-remove-key` | 不可变式删 map 键（Rebol map 无 delete） |
| 90–100 | `block-remove-same` | 按 identity 从 block 删一项 |
| 106–111 | `resolve-config` | 调 runtime/Config 校验 config；P7 前多为透传 |

可跳过细读，遇到 `fiber-update` / `make-plugin-fiber` 时再回来看。

---

## 第 2 段：状态查询与边界通知（117–157）

| 行号 | 符号 | 读什么 | 测试锚点 |
|------|------|--------|----------|
| 117–131 | `fiber-get-state` | **派生状态**：`uid=none`→DISPOSED；有 error→FAILED；epoch 非 inactive→ACTIVE；否则 PENDING | 与 `fb/state` 字段可能短暂不一致，以 update-state 为准 |
| 137–143 | `fiber-notify-active` | fiber 变为/离开 ACTIVE 时，通知 reflect 重算 **由本 fiber provide 的服务** | 连接 reflect 与 fiber；必须用 `same?` 比较 ctx/fiber（注释 135–136 防 segfault） |
| 146–157 | `fiber-update-state` | 写 `state`、emit `internal-status`、ACTIVE 边界时调 notify-active | 观察插件 ACTIVE↔PENDING 切换 |

**实验**：在 Test 1 的 `simulate-provide` 后加 `print [fb1/state fb1/epoch mold fb1/store]`。

---

## 第 3 段：依赖解析核心（163–231）⭐ 最重要

### 3a `fiber-check-impl`（163–186）

对一个 inject 名：

1. `reflect/get-impl name true ctx`
2. 有 `impl/check` 则调用，失败或 false → 从 store 移除
3. 否则写入 `fb/store`

**测试**：Test 6 consumer 在 apply 里读 `ctx/reflect/store 'provider`（apply 运行时 store 已快照）。

### 3b `fiber-refresh`（188–204）

1. 对每个 inject 名调 `fiber-check-impl`
2. 拼接 epoch：`":uid1:uid2..."`；任一缺失 → `inactive-epoch` 并 break
3. 调 `fiber-set-epoch`

**实验（ch03 建议 2）**：在此函数末尾临时加：

```rebol
print ["refresh uid=" fb/uid " epoch=" epoch-str]
```

双依赖插件（ch03 建议 3）应看到 `:1:2` 这类串。

### 3c `fiber-set-epoch`（207–231）⭐ 状态机枢纽

| epoch 变化 | 动作 |
|------------|------|
| → `inactive-epoch` | UNLOADING → `fiber-unload` |
| `inactive` → 非 inactive | LOADING → `fiber-reload` |
| 非 inactive → 非 inactive（换 provider） | UNLOADING → unload（unload 末尾可能 reload） |

`inertia` 防止重入；末尾若 epoch 在执行中被改掉，递归再调自己。

**对照 TS**：`ref/core/fiber.ts` 的 `_setEpoch()` — 异步变同步，逻辑同构。

**测试映射**

| 测试 | 验证点 |
|------|--------|
| Test 1 | provide/unprovide/re-provide 全程 |
| Test 6 | update 后 consumer 重跑但 provider impl 不变 |

---

## 第 4 段：reload / unload（237–289）⭐

### 4a `fiber-reload`（237–264）

1. 快照 `store`
2. `try [runtime/callback/apply ctx config]`
3. **失败**：log → `error` → epoch=inactive → FAILED → **再 unload 清 disposables**（Test 2）
4. **成功**：apply 返回值 push 到 disposables（object 或 block）
5. epoch 未变 → ACTIVE；变了 → unload（apply 期间依赖又变了）

apply 返回 disposer 是 Cordis 插件约定：`make object! [dispose: func [...]]`。

### 4b `fiber-unload`（266–289）

1. `disposables/clear` 得到列表，**foreach 顺序 = 插入序，但 clear 返回后逐个 dispose**（配合 DisposableList 语义 = LIFO 清理）
2. `store: none`
3. 分支：
   - `uid=none` → DISPOSED
   - 有 error → FAILED
   - epoch inactive → PENDING
   - epoch 仍有效 → LOADING → **fiber-reload**（换 provider 场景）

**测试映射**

| 测试 | 验证点 |
|------|--------|
| Test 2 | apply 抛错 → FAILED + unload |
| Test 3 | unload 时 disposer 抛错 → logger.error，不崩溃 |
| Test 11 | 嵌套 plugin LIFO：outer-stop 先于 inner-stop |

**实验（ch03 建议 1）**：把 `foreach d ds` 改成 `foreach d reverse ds`，Test 9/11 应失败。

---

## 第 5 段：effect 作用域（300–357）⭐

### `fiber-effect`（300–348）

1. `uid=none` → INACTIVE_EFFECT 字符串（registry Test 6）
2. **立即** `try [execute]` — 不是 lazy
3. 返回值：object / block of objects / none
4. 带 `meta` 的子 effect 从 disposables 删掉、挂到 wrapper/meta/children（嵌套树）
5. 包装成 wrapper（含 label、items、幂等 dispose），push 到 `fb/disposables`

**错误路径**：execute 抛错 → 已收集的 local-list **逆序 dispose** → 返回 error（Test 10：seq10 长度仍为 0）

**测试映射**

| 测试 | 验证点 |
|------|--------|
| Test 7 | plugin apply 里 `ctx/fiber/effect` |
| Test 8 | root fiber 手动 effect |
| Test 9 | block 返回 + 嵌套 → 清理顺序 [3 2 1] |
| Test 10 | execute 中途报错无部分残留 |

### `fiber-get-effects`（350–357）

遍历 disposables，收集带 `meta` 的 label/children — 调试/introspection 用。

---

## 第 6 段：对外 API（363–411）

| 行号 | 符号 | 作用 | 测试 |
|------|------|------|------|
| 363–368 | `fiber-assert-active` | uid=none 时报 INACTIVE_EFFECT | registry Test 6 |
| 370–380 | `fiber-name` | 沿 parent 链找 runtime/name | Test 12 |
| 386–390 | `fiber-await` | 同步空操作；有 error 则返回 error | — |
| 392–397 | `fiber-restart` | epoch→inactive → refresh → await | Test 5 |
| 399–411 | `fiber-update` | resolve-config → `events/waterfall 'internal-update` → 最终 restart | Test 4, 6 |

`fiber-update` 是配置热更新的入口：waterfall 让 internal-update listener 链式处理，最后 `final-w` 写 config 并 restart。

---

## 第 7 段：构造器（417–496）⭐ 与 registry 交界

### `make-fiber-root`（417–433）

- `uid: 0`，`state: ACTIVE`，`epoch: ""`
- `dispose` = restart（root 永不 DISPOSED，只清空重载）

### `make-plugin-fiber`（437–496）

插件 fiber  birth 全流程：

```text
1. 分配 uid，PENDING，epoch=inactive
2. parent.extend({ fiber: this }) → 子 ctx（插件有自己的 ctx）
3. emit internal-plugin
4. 对每个 inject 名 fiber-check-impl
5. parent.fiber/effect(ex) 注册 dispose 入口
   ex 立即执行：
     - runtime/fibers push 本 fb
     - resolve-config + fiber-refresh  → 可能触发首次 reload
     - 返回 dispose-fn（uid→none，registry 清理，epoch→inactive）
```

**关键**：`fb/dispose` 是挂在 **父 ctx 的 root fiber** 上的 effect，不是 plugin fiber 自己的 disposables 列表的入口标签 `"ctx.plugin()"`。

**测试**：Test 11 outer apply 里调 `make-plugin-fiber` 创建 inner。

---

## 建议阅读顺序（约 3 小时）

| 时段 | 段落 | 同步跑测试 |
|------|------|------------|
| 0:00–0:30 | 0 + 2（状态） | Test 12 |
| 0:30–1:15 | 3（check/refresh/set-epoch） | Test 1 |
| 1:15–1:45 | 4（reload/unload） | Test 2, 3 |
| 1:45–2:15 | 5（effect） | Test 7–10 |
| 2:15–2:45 | 6 + 7（update + 构造） | Test 4–6, 11 |
| 2:45–3:00 | 对照 `ref/core/fiber.ts` `_checkImpl/_refresh/_setEpoch/_reload/_unload/effect` | `bash run.sh` 全绿 |

---

## 破坏性实验清单

| # | 改动 | 预期 |
|---|------|------|
| 1 | `fiber-unload` 中 `foreach d reverse ds` 改回正序 | Test 9 `[3 2 1]` 失败；Test 11 LIFO 失败 |
| 2 | `fiber-refresh` 打印 epoch-str | provide/unprovide 时观察 `:0` ↔ `__INACTIVE__` |
| 3 | 双 inject 插件 | epoch 形如 `:1:2`，缺一变 inactive |
| 4 | `fiber-reload` 去掉失败后的 `fiber-unload` | Test 2 disposables 泄漏 / 状态异常 |

---

## 与 TypeScript 对照表

| Rebol | TypeScript | 差异 |
|-------|------------|------|
| `fiber-set-epoch` | `_setEpoch` | 同步 + `inertia` 代替 Promise 链 |
| `fiber-effect` | `effect()` + generator | block 代替 generator yield |
| `make-plugin-fiber` | Fiber 构造函数 + registry | dispose 注册在 parent fiber |
| `fiber-get-state` | getter `state` | 显式函数 + 缓存字段 `fb/state` |

---

## 读完自测（闭卷）

1. `provide 'foo` 后，哪个函数第一个把 plugin 从 PENDING 推向 LOADING？
2. apply 返回的 disposer 存在哪里？unload 谁触发 dispose？
3. 为何 Test 10 要求 `seq10` 长度为 0？
4. root fiber 的 `dispose` 和 plugin 的 `fb/dispose` 行为有何不同？
5. epoch 从 `:1` 变为 `:2`（同一服务换了 provider fiber）走哪条 unload/reload 分支？

全部能答 → Day 3 合格，进入 Day 4 `reflect.reb`。
