# 大厅的灯亮了，但只有一个人敢上台

我是 `command`，一个负责处理指令的聊天机器人插件。今天的故事发生在 Cordis 大厅里，主角不是我，而是那个刚刚上线的 `database` 服务。它一出现，整个大厅都暗流涌动，但真正敢上台的，只有我一个。

## 一、开工前，我们都在等

大厅里有六个人在等开工：

- `logger`，什么也不缺，早就站在角落里记笔记
- `database`，管着公共数据库，今天刚要开张
- 我，`command`，只要公共库 `database` 就位
- `session`，既要 `database` 又要 `http`，缺一个都不行
- 群 A 的 `welcome`，只认群 A 自己的 `database`
- 群 B 的 `welcome`，只认群 B 自己的 `database`

我们都被注册进了 Cordis，手里攥着 `inject` 需求单。`session` 的单子上写着两项，我和两个 `welcome` 都只写了一项。但「只写一项」不等于「随便哪个都行」。

## 二、公共数据库开张，不是全员发糖

上午十点，`database` 插件的 `apply` 跑完，执行了这句：

```rebol
root/reflect/provide 'database db-root none root
```

公共库正式上线。`reflect` 把它写进服务表，然后开始做一件事：扫一遍 `all-fibers`，把所有插件 Fiber 都过一遍。

这就是很多人误解的地方。`provide` 不是广播说「大家快来领数据库」，而是拿着名单挨个问：你单子上有这项吗？你在哪个房间？你的其他条件都齐了吗？

**`logger` 被扫到了，但它没写 `inject: ['database']`。** 扫到即跳过。它继续记笔记，连眼皮都没抬。

**我被扫到了。** 我的单子上确实有 `database`，而且我站的就是大厅，房间标签和公共库一样。框架去查：公共库的 Fiber 是 ACTIVE 吗？是。那我的 epoch 从 `__INACTIVE__` 变成 `:0`，我第一次 `apply`，指令处理器正式上线。

**`session` 也被扫到了。** 它的单子上也有 `database`，房间也对。框架帮它重新算了一遍依赖：公共库有了，`http` 还没有。epoch 依然是 `__INACTIVE__`，它继续 PENDING。不是这次通知没收到，是另一把钥匙还没拿到。

**群 A 和群 B 的 `welcome` 也被扫到了。** 它们都写着 `inject: ['database']`，但站在各自的群房里。框架比对房间标签：公共库在 `default` 房，群 A 在 `iso-A` 房，群 B 在 `iso-B` 房。标签对不上，连重新查依赖的资格都没有。它们继续等自己群里的那份库。

所以你看，大厅的灯亮了，六个人都听见了动静，但只有我敢上台。

## 三、下午，群 A 自己的数据库也开了

下午三点，群 A 的管理员执行：

```rebol
ctx-a/reflect/provide 'database db-guild-a none ctx-a
```

这次轮到我被扫到了，但我已经拿着公共库的钥匙，epoch 还是 `:0`。框架发现我的 epoch 没变，直接退出。我不会因为群 A 开了新库就重跑——那不是我的房间。

群 B 的 `welcome` 依然没动。它的房间是 `iso-B`，群 A 的库对不上它的标签。

只有群 A 的 `welcome` 过关了：单子上有 `database`，房间标签对上了，依赖也齐了。它的 epoch 第一次变成有效值，`apply` 跑起来，群 A 的新人开始收到欢迎语。

## 四、这不是广播，是过关

很多人以为 `provide` 像广播：喊一嗓子「database 来了」，所有需要的人都醒。Cordis 不是这么设计的。

真实流程更像过安检：

1. **名单关**：`all-fibers` 里每个人都扫一遍，但先看你有没有把这项写进 `inject`
2. **房间关**：`isolate` 标签必须一致，否则连门都不让进
3. **状态关**：提供服务的那个 Fiber 必须是 ACTIVE，不能是 PENDING 或 FAILED
4. **check 关**：服务可以带一个 `check` 函数，返回 false 就当没提供
5. **依赖齐关**：你单子上的**每一项**都得有，缺一个就继续等
6. **epoch 变关**：只有 epoch 字符串真的变了，才会 unload 再 reload；没变就什么都不做

这六关过完，才轮到我 `apply`。少一关，我就站在原地。

## 五、为什么 Cordis 要这么较真？

因为插件不是函数。函数调用一次就结束，插件要长期持有资源：我挂着指令监听，`session` 可能连着 HTTP 会话，`welcome` 可能在写群文件。如果框架不看清条件就让人开工，轻则拿到错房间的数据，重则资源泄漏。

`provide` 时的层层过滤，是在保护两种人：

- **提供方**：我的库只给同房间、同标签的人用，不随便外借
- **使用方**：我只在依赖真正齐备时开工，不会拿到半套装备就冲上去

大厅的灯亮了，但只有条件全齐的那个人才会上台。这就是 Cordis 的纪律。

---

*本文场景基于 `context.reb` 的 isolate 机制、`reflect.reb` 的 `reflect-notify`，以及 `fiber.reb` 的 epoch 检查。可运行的简化版见 `test/context-test.reb` Test 2 与 Test 3。*
