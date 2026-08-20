# 打烊五分钟：我的 Fiber 是怎么清场再重跑的

我是 `command`，大厅里处理指令的插件。今天不讲我怎么开工，讲我怎么**收工**——以及为什么收工收得好，下次开工才不踩到上一班的烂摊子。

## 一、下午两点零三分，我被通知「换约」

`http` 插件升级，Provider 从工号 `2` 换成工号 `5`。我的 epoch 从 `:1:2` 变成 `:1:5`。

`fiber-set-epoch` 一看：旧合同 `:1:2`，新合同 `:1:5`，不一样。于是它把我的状态打成 `UNLOADING`，然后调 `fiber-unload`。

从这一刻起，我不再接新活。大厅里有人喊 `guest-arrived`，我也不会应了。不是我不想干，是 Cordis 先把我请下了台。

## 二、清场：逆序执行，一件都不能少

`fiber-unload` 做的第一件事，是把我 Fiber 里的 `disposables` 列表清空。

注意，这个「清空」不是把列表扔了，而是**把里面所有 disposer 都拿出来，按逆序跑一遍**。

我上一轮 `apply` 里登记了三样东西：

1. `ctx/events/on 'command-received ...`——监听指令事件
2. `ctx/fiber/effect ...`——一个定时器，每 30 秒检查一次会话超时
3. `ctx/reflect/provide 'session-stats ...`——我对外提供的状态服务

`fiber-unload` 会按 **3 → 2 → 1** 的顺序执行：

```text
先撤掉 session-stats 服务登记
再关掉定时器
最后摘掉事件监听
```

为什么逆序？因为后登记的往往依赖先登记的。`session-stats` 可能正在被别的插件用，得先断；定时器可能在读我的状态，得先停；事件监听是最外层，最后摘。

如果中间某个 disposer 抛错，Cordis 不会停。它会记进 `logger/error-log`，继续清剩下的。一个插件的死亡不能拖垮整个系统。

## 三、清场完毕： store 清零，状态待定

disposers 跑完后，`fiber-unload` 把我的 `store` 置为 `none`。

`store` 是我开工时依赖项的快照：`database` 是谁、`http` 是谁。清场时把它抹掉，表示我当前不再持有任何依赖的实现。

然后 `fiber-unload` 看情况：

- 我的 `uid` 还在吗？在，说明我不是被永久 dispose
- 我有 error 吗？没有
- 新 epoch 是 `:1:5`，不是 `__INACTIVE__`

于是它把我的状态打成 `LOADING`，调 `fiber-reload`。

## 四、重跑：apply 带着新合同再上岗

`fiber-reload` 先重新算一遍 `store`：`database` 还是工号 `1`，`http` 现在是工号 `5`。快照建好，然后调我的 `apply`。

我的 `apply` 再跑一次：

1. 重新 `ctx/events/on 'command-received ...`
2. 重新开定时器
3. 重新 `provide 'session-stats ...`

一切看起来和上午一样，但有两处不同：

- `http` 服务的实现已经换了，我拿到的是新 Provider
- 我的 `disposables` 列表是全新的，上一轮的 disposer 已经执行完毕，不会重复清

`apply` 跑完，epoch 没变，状态变成 `ACTIVE`。我重新开张。

## 五、从旧合同到新合同，中间发生了什么？

```text
旧 epoch :1:2
    ↓
fiber-set-epoch 发现变成 :1:5
    ↓
状态 UNLOADING
    ↓
fiber-unload: 逆序执行 disposers，store 清零
    ↓
状态 LOADING
    ↓
fiber-reload: 重新 apply，新 disposables 入列
    ↓
状态 ACTIVE，新 epoch :1:5
```

这五步就是「清场再重跑」。Cordis 不会让我在旧副作用还没清干净的情况下，直接跑新逻辑。它宁可让我空转几秒，也要保证：

- 旧事件监听不会在新逻辑里触发
- 旧定时器不会在新配置下继续走
- 旧服务登记不会和新服务冲突

## 六、为什么不是「直接改配置」？

很多人会问：如果只是 `http` 换了实现，为什么我不直接改一下引用，非要全拆全建？

因为 Cordis 不知道我的 `apply` 里干了什么。我可能开了数据库连接、注册了事件、起了定时器、写了文件。框架没法判断哪些该留、哪些该换。

它唯一能确定的是：**我上一轮登记的所有副作用，都必须能撤销。** 所以最安全的做法就是：全部撤销，再全部重建。

这就是为什么 `disposables` 必须逆序、必须完整、必须幂等。清场清得好，重跑才不乱。

## 七、一句话记住

epoch 变了，Cordis 不是「热更新」我的字段，而是**让我先打烊、再开张**。打烊时逆序清场，开张时重新登记。中间那几分钟的 `UNLOADING` 和 `LOADING`，就是框架在替我收拾烂摊子。

理解了清场再重跑，你就理解了为什么 Cordis 插件敢说自己「可靠」——它不是不会死，而是每次死都死得干净，每次活都活得清白。

---

*本文机制对应 `fiber.reb` 的 `fiber-unload` 与 `fiber-reload`，验证见 `test/fiber-test.reb` Test 4、Test 6、Test 9。*
