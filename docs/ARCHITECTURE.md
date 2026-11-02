# CodexGauge 架构

CodexGauge 是独立的 macOS 辅助应用。正式入口为 `QuotaButton.app`，构建目标为 Apple Silicon / macOS 14.0 及以上，使用 AppKit 管理窗口、SwiftUI 绘制详情。

## 模块

| 文件 | 职责 |
| --- | --- |
| `Sources/QuotaAnchoredButton.swift` | App 入口、宿主版本配置、窗口定位、固定按钮、详情与退出清理 |
| `Sources/QuotaWindowReal.swift` | 共享额度视图；固定按钮使用 `anchoredCompact` 模式 |
| `Sources/QuotaRealModel.swift` | 账号确认、刷新调度、退避、通知和旧回调隔离 |
| `Sources/QuotaRealProvider.swift` | CLI 签名校验、本地 stdio RPC 与子进程生命周期 |
| `Sources/QuotaRealData.swift` | 额度及重置明细解析、字段状态和展示顺序 |
| `Sources/QuotaCountdown.swift` | 纯倒计时格式化 |
| `Sources/QuotaWindowLayout.swift` | 详情自然高度、屏幕限制与窗口放置 |

## 数据流

```text
QuotaButton.app
  → QuotaWindowModel
  → QuotaRealProvider
  → bundled Codex CLI app-server (stdio)
  → account/read + account/rateLimits/read
```

额度来自 CLI 当前登录账号。响应保存在内存中，不能据宿主窗口位置推断为某个聊天或工作区的额度。Provider 不创建聊天、不提交模型任务，也不实现限额重置操作。

正式按钮采用后台刷新策略：启动首读，成功读取后约60秒再次读取；失败时退避并尊重服务端重试时间。详情开关与每秒显示 tick 不额外读取额度。本地倒计时到期只改变显示文案，百分比和次数继续以服务端为准。

## 宿主定位

定位器检查前台应用身份及版本，使用公开窗口列表获取几何位置。当前实现依赖特定宿主版本的固定位置参数，并要求单个可见标准窗口。宿主版本、窗口数量或位置条件不满足时隐藏按钮。版本配置与构建参数见 [README](../README.md)。

详情通常显示在按钮右侧并按中心对齐；内容自然高度受屏幕可见范围约束。再次点击、Escape、关闭窗口或点击外部可收起详情。外部点击通过应用失活与本地鼠标事件等路径处理。

## 模拟与历史原型

`QuotaButtonMockHost.swift` 提供自有模拟宿主。`QUOTA_ANCHORED_TESTING` 只切换宿主定位，仍使用真实数据 Provider。离线检查通过 `QUOTA_TESTING`、内存 transport 与本地假 app-server 注入数据，见 [验证说明](VALIDATION.md)。

`OverlayA.swift`、`OverlayADemoHost.swift`、`QuotaWindowDemo.swift` 及对应脚本保留早期原型，验收范围各自独立。

## 仓库内容

仓库保留源码、脚本、测试、正式图标及公开说明。构建目录、运行日志、编辑器状态、设计导出图和历史本机验收证据由 `.gitignore` 排除。本地历史记录不属于公开仓库的构建依赖。
