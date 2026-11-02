# 验证说明

检查需要 macOS、Apple Silicon 及可用的 `xcrun swiftc` 和 macOS SDK。在项目根目录执行。

## 后台刷新和账号切换

```bash
bash scripts/check-quota-90-background-refresh.sh
```

该入口编译并运行后台刷新检查、按可见性刷新状态检查、生产模型状态检查及首次额度读取期间账号切换检查。使用内存 transport 或 `validation/quota90-fake-app-server.pl`，不连接真实 CLI 账号。

## 倒计时格式

```bash
CHECK_DIR="$(mktemp -d /private/tmp/quota-countdown-check.XXXXXX)"
xcrun swiftc -parse-as-library \
  -module-cache-path "$CHECK_DIR/module-cache" \
  Sources/QuotaCountdown.swift validation/QuotaCountdownFormatCheck.swift \
  -o "$CHECK_DIR/countdown-check"
"$CHECK_DIR/countdown-check"
```

覆盖13项边界，包括天/时/分/秒、未来不足一秒、到期、无效或超大日期和时钟推进。

## 其他检查源码

| 文件 | 范围 |
| --- | --- |
| `validation/QuotaSidebarGlyphCheck.swift` | 5h图标分级阈值、异常状态、同一按钮后台订阅和组件无窗口位图 |
| `validation/QuotaRealDataCheck.swift` | 生产解析、字段异常与重置明细一致性 |
| `validation/Quota85TransportCheck.swift` | 本地假服务的退出与传输故障 |
| `validation/QuotaWindowLayoutCheck.swift` | 窗口几何边界 |
| `validation/QuotaAnchoredDetailsLayoutCheck.swift` | 自然高度、屏幕上限与居中 |
| `validation/Quota85ViewHarness.swift` | 带测试数据标识的独立视图验收入口 |

这些程序需与相关生产源文件组合编译。几何断言和无窗口测量不能代替实体交互验收。

## 已记录的本机验收范围

2026-11-02，a1-c32适配Codex build 24141 / 26.1027.61615，仅更新三个宿主身份常量及相邻注释。其余九份产品输入、AppIcon保持一致；3包严格签名、10/10+10/10+1/1输入绑定和当前宿主profile独立核对通过。用户手动切换后确认“按钮恢复，交互正常”，覆盖当前宿主中的按钮恢复、位置、详情打开、外点关闭和重开；未知未来宿主版本仍隐藏按钮。

截至2026-11-02，a1-c31 已记录用户对当前真实5h对应图标档位、按钮位置、详情打开、外点关闭与重开正常的确认。四档阈值、浅色/深色组件像素及同一按钮后台订阅使用合成数据和无窗口View验证，不代表真实账号四档均已人工测试。此前a1-c28还记录了倒计时、完整日期及详情开关确认，以及格式边界、生产详情无窗口测量和请求计数检查。

以上是已有本机验收记录的摘要，原始本机截图、日志和交付记录未纳入公开仓库。它不代表本次重新构建的新候选已完成交互验收。

真实账号实际到期事件、跨显示器、操作系统睡眠与唤醒、深色模式和实体长内容滚动尚未完成全面验收。宿主更新后应重新核对版本和布局。
