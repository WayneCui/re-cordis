# 换厨子那天，我重新签了一份合同

我是 `session`，一个既要 `database` 又要 `http` 的聊天机器人插件。今天不讲我怎么干活，讲我口袋里那张「合同」——Cordis 叫它 `epoch`——是怎么变了又变，逼得我几上几下。

## 一、我的合同上必须同时盖两个章

我的 `inject` 单子上写着两项：

```rebol
inject: ['database 'http]
```

这意味着：我的合同要生效，必须同时拿到 `database` 和 `http` 两个服务的章。缺一个，合同上就只有一行大字：`__INACTIVE__`。

上午九点，`database` 上线了。框架扫到我，帮我重新算合同：database 的 Provider 工号是 `1`，但 `http` 还空着。合同状态仍然是 `__INACTIVE__`。我继续坐在工位上等。

## 二、第一次变：从「缺人」到「齐活」

上午十点，`http` 插件也上线了。框架再次扫到我，这次两个章都齐了：

- `database` 的 Provider 工号 `1`
- `http` 的 Provider 工号 `2`

合同从 `__INACTIVE__` 变成 `:1:2`。

这就是 epoch 第一次变。**不是「database 来了」或「http 来了」单独触发的，而是「最后一项缺的补齐了」触发的。** 只要还有一项缺着，前面来多少项都没用。

合同一变，我的 Fiber 从 `PENDING` 变成 `LOADING`，`apply` 跑起来。我正式开工。

## 三、第二次变：同一个名字，换了一个人

下午两点，运维说 `http` 要升级。旧 `http` 插件先 dispose，新 `http` 插件马上 provide 了同名服务。

但新插件的 Fiber 工号是 `5`，不是原来的 `2`。

框架扫到我，重新拼合同：`:1:5`。

我的合同从 `:1:2` 变成 `:1:5`。虽然 `database` 还在，虽然服务名还是 `http`，但**给我干活的那组人换了**。Cordis 认为：旧合同作废，必须重新签。

于是我的 Fiber 先 `UNLOADING`：把上一轮 `apply` 里登记的所有副作用逆序清掉。然后 `LOADING`：`apply` 再跑一次。我重新开工，但已经是新合同下的我。

如果新 `http` 插件的 Fiber 工号还是 `2`——比如它重启后 uid 没变——那合同字符串还是 `:1:2`。`fiber-set-epoch` 发现没变，直接退出，我不会重跑。**epoch 认的是 Provider 的身份，不是服务的名字。**

## 四、第三次变：有人主动撕合同

下午四点，管理员调了配置，执行：

```rebol
session-fb/update make map! [timeout: 5000] false
```

`fiber-update` 不会直接改我的字段。它先把我的合同撕成 `__INACTIVE__`，再调 `fiber-refresh` 重新算。

如果 `database` 和 `http` 都还在，合同会从 `__INACTIVE__` 变回 `:1:5`。这个「先撕再签」的过程就是一次完整的换约：旧副作用清掉，新配置生效，`apply` 带着新 config 重跑。

`fiber-restart` 也是同一招：先把 epoch 打成 inactive，再 refresh。

## 五、什么时候合同不变？

很多人以为「服务被 provide 了，插件就该重跑」。不对。以下情况，我的合同纹丝不动：

- 我根本没 `inject` 这个名字
- 服务在别的 isolate 房间提供，标签对不上
- 服务的 `check` 函数返回 false，当没提供
- 我还有其他依赖没齐，合同一直是 `__INACTIVE__`
- Provider 的工号没变，拼出来还是同一串

`fiber-set-epoch` 的第一行就是：

```rebol
if equal? epoch-str old [exit]
```

合同没变，后面什么都不发生。

## 六、一句话记住 epoch

epoch 不是「版本号」，也不是「时间戳」。它是**当前给我干活的那组 Provider 的工号串**。

- 从无到有：合同生效，我开工
- 从有到无：合同作废，我清场
- 从一组人到另一组人：合同换签，我重跑
- 同一组人还在岗：合同不动，我照常

理解 epoch 的关键，是把它从「状态标记」看成「身份清单」。只要清单上的人没变，Cordis 就不会让我无故折腾。

---

*本文机制对应 `fiber.reb` 的 `fiber-refresh` 与 `fiber-set-epoch`，验证脚本见 `how-cordis-port-works/ch03-fiber-epochs/code/probe-epoch.reb`。*
