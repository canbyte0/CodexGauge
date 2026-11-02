# CodexGauge

Codex 额度仪表 · A lightweight macOS companion for Codex with quota details, reset countdowns, and automatic refresh.

一个用 Swift、AppKit 和 SwiftUI 编写的 macOS 辅助应用。在 Codex 桌面应用最左侧窄栏显示固定的仪表图标，点击即可查看当前 CLI 登录账号的额度。

按钮由独立的 `QuotaButton.app` 绘制并跟随宿主窗口。额度范围取决于 CLI 登录账号，不能据按钮所在位置推断为当前聊天或工作区额度。

## 功能

- 查看 **5h 剩余额度**、**周剩余额度**及各自的重置日期。
- 查看服务端提供的 **限额重置剩余次数**，按到期时间排列逐条明细；此应用只读取和展示额度。
- 在重置日期右侧、每条到期明细中显示独立倒计时，例如 `4天15时`、`3时42分`、`42分18秒`。
- 启动时读取一次，成功读取后约每 **60 秒**后台刷新；支持手动刷新，反复打开详情不额外发起读取。
- 详情宽度为 **320 pt**，高度随实际内容调整，并受屏幕可见区域限制；通常在按钮右侧与其中心对齐。
- 再次点击按钮、按 `Escape`、关闭详情窗口或点击外部可收起详情。切换应用或最小化宿主时隐藏按钮。
- 保留最后成功更新时间，区分未知、未提供、异常及上次记录；到期倒计时不会在本地修改额度百分比或重置次数。

日期按 `Asia/Shanghai` 显示。倒计时复用现有一秒时钟，额度重置到时显示“等待更新”，明细到时显示“已到期”，未知或不过期显示“—”。

## 当前状态

截至 **2026-11-02**，最新本机验收记录为 **a1-c28**：用户已确认两类额度和每条明细的倒计时、完整日期、外点关闭及重开正常。格式边界、生产详情视图测量、请求计数、构建输入和签名的独立核对见 [验证说明](docs/VALIDATION.md)。

此结论覆盖记录中的本机环境。真实账号实际到期事件、跨显示器、睡眠与唤醒、深色模式和实体长内容滚动没有新增完整验收；时钟推进和请求计数使用合成数据验证。项目仍以本机构建候选交付，没有完成面向公众发布的完整验证。

仓库提供源码、脚本和图标，使用时按下文构建本机候选。App 可执行文件及历史本机验收证据未纳入源码仓库。

## 环境与适配范围

| 项目 | 当前要求 |
| --- | --- |
| 系统与架构 | macOS 14.0 及以上，Apple Silicon；脚本目标为 `arm64-apple-macosx14.0` |
| 构建工具 | 提供 `xcrun swiftc`、macOS SDK 和 `codesign` 的 Xcode / Command Line Tools |
| 宿主 Bundle ID | `com.openai.codex` |
| 源码支持的宿主版本 | `26.1027.51404`，build `23880` |
| 宿主 Info.plist SHA-256 配置值 | `7a3920d56d052cdf4bf803a92e2098be015eaf9263589d51e04ac4121f16eed7` |
| 窗口条件 | 单个可见标准主窗口，至少 `900 × 700 pt`，按钮处于屏幕可见区域 |
| 数据前提 | 固定路径下的随应用打包 CLI 可用、签名校验通过，并已登录可读取额度的账号 |

宿主白名单和位置参数位于 [QuotaAnchoredButton.swift](Sources/QuotaAnchoredButton.swift)。程序核对运行宿主的 Bundle ID、版本及 build，并要求候选包中的四项 profile 配置与源码一致。表中的 Info.plist 哈希用于构建配置和独立核对，运行时定位器不重新计算宿主文件哈希。

宿主版本不匹配、多个可见宿主窗口、定位不唯一或位置不满足条件时会隐藏按钮。宿主更新后需要重新核对版本与位置适配；仅重新填写构建环境变量不会更新源码白名单。

## 使用

1. 启动已核对版本的 `QuotaButton.app`，将符合适配条件的 Codex 主窗口置于前台。
2. 点击最左窄栏中分支图标下一行的仪表图标，打开额度详情。
3. 等待启动读取，或点击详情底部的小刷新按钮；若出现多个可选额度来源，可通过选择器切换。
4. 再次点击仪表图标、按 `Escape`、点击外部或关闭详情窗口，收起面板。
5. 退出辅助应用时，先打开详情，再使用“额度按钮”应用菜单中的“退出额度按钮”或按 `⌘Q`。

关闭详情后后台刷新继续；退出辅助应用时会停止模型、清理其 CLI 子进程并移除 PID 文件。请只运行一个正式候选。

## 从源码构建

先获取源码：

```bash
git clone https://github.com/canbyte0/CodexGauge.git
cd CodexGauge
```

以下命令均在项目根目录执行。当前构建入口为 `scripts/build-anchored-quota-button-a1-c1.sh`；文件名沿用首版，候选编号由 `QUOTA_BUTTON_REVISION` 指定。脚本要求编号形如 `a1-c29`，并拒绝覆盖已有同名目录。

先核对宿主的公开包元数据，与上方支持范围一致后再构建：

```bash
HOST_INFO='/Applications/ChatGPT.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HOST_INFO"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOST_INFO"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$HOST_INFO"
shasum -a 256 "$HOST_INFO"
```

下面使用 `a1-c29` 作为新候选示例；如果该目录已经存在，请选择尚未使用的编号。四项 profile 环境变量需完整提供，默认不带 profile 的生产包会隐藏按钮。

```bash
QUOTA_BUTTON_REVISION=a1-c29 \
QUOTA_BUTTON_PROFILE_HOST_BUNDLE_IDENTIFIER=com.openai.codex \
QUOTA_BUTTON_PROFILE_HOST_BUILD_VERSION=23880 \
QUOTA_BUTTON_PROFILE_HOST_SHORT_VERSION=26.1027.51404 \
QUOTA_BUTTON_PROFILE_HOST_INFO_PLIST_SHA256=7a3920d56d052cdf4bf803a92e2098be015eaf9263589d51e04ac4121f16eed7 \
bash scripts/build-anchored-quota-button-a1-c1.sh
```

产物位于 `build/anchored-quota-button/revisions/a1-c29/`：

| 相对产物路径 | 用途 |
| --- | --- |
| `candidates/QuotaButton.app` | 使用真实宿主定位的正式候选 |
| `test-candidates/QuotaButtonMock.app` | 面向自有模拟宿主的按钮候选 |
| `mock-host/QuotaButtonMockHost.app` | 提供可控窗口和位置状态的模拟宿主 |

脚本同时保存编译输入、哈希、编译输出、包身份和签名核验记录。构建使用 ad-hoc 签名；构建成功不代表新候选已经通过交互验收，也不包含安装或自启动设置。

需要使用新候选时，先退出旧的额度按钮，再手动打开对应产物，例如：

```bash
open 'build/anchored-quota-button/revisions/a1-c29/candidates/QuotaButton.app'
```

### 图标

正式 App 使用已选定的“暖白底＋橙金阶梯刻度”图标。构建会复制 `Resources/AppIcon.icns`、写入 `CFBundleIconFile` 后签名；资源缺失时会停止构建。

如需从现有 PNG 重新生成 ICNS，运行：

```bash
bash scripts/generate-app-icon.sh
```

资源来源与尺寸说明见 [Resources/README.md](Resources/README.md)。

## 数据与刷新

数据通路为 `QuotaButton → QuotaWindowModel → QuotaRealProvider → Codex CLI app-server`。CLI 路径固定为：

```text
/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
```

Provider 先校验 CLI 签名，再通过 `app-server --listen stdio://` 建立本地子进程会话，完成 `initialize` / `initialized` 握手，调用 `account/read` 与 `account/rateLimits/read` 读取账号及额度。代码不创建聊天或提交模型任务。

刷新由模型串行调度。正常情况下每次成功读取后约60秒再次读取，失败时退避，并尊重服务端重试时间；账号变更时重新确认身份，隔离旧回调。打开、关闭详情及倒计时到期不额外触发额度请求。

额度响应保存在进程内存。Provider 不保留原始 stderr；运行日志记录请求状态、定位及生命周期等事件。保持默认候选目录结构时，正式按钮的日志和 PID 位于对应 revision 下：

```text
runtime/local.msl.QuotaButton.Anchored/quota-button.log
runtime/local.msl.QuotaButton.Anchored/quota-button.pid
```

## 验证与模拟

文档链接、命令及源码对应关系可以独立核查；界面交互仍需在目标环境验证。以下是现有验证入口。

### 离线检查

后台刷新检查使用内存 transport 和本地假 app-server，同时覆盖账号切换、旧回调隔离及旧的按可见性刷新模式：

```bash
bash scripts/check-quota-90-background-refresh.sh
```

倒计时纯格式检查可单独编译运行，不启动 GUI 或真实 CLI：

```bash
CHECK_DIR="$(mktemp -d /private/tmp/quota-countdown-check.XXXXXX)"
xcrun swiftc -parse-as-library \
  -module-cache-path "$CHECK_DIR/module-cache" \
  Sources/QuotaCountdown.swift validation/QuotaCountdownFormatCheck.swift \
  -o "$CHECK_DIR/countdown-check"
"$CHECK_DIR/countdown-check"
```

其他检查位于 `validation/`：

| 文件 | 覆盖内容 |
| --- | --- |
| `QuotaRealDataCheck.swift` | 额度解析、未知与异常字段、重置明细及次数一致性 |
| `QuotaRealStateCheck.swift`、`Quota85StateCheck.swift` | 状态与账号切换等模型行为 |
| `Quota85TransportCheck.swift` | 传输断开与子进程故障 |
| `QuotaWindowLayoutCheck.swift`、`QuotaAnchoredDetailsLayoutCheck.swift` | 窗口放置和详情高度边界 |

这些 Swift 检查需要与对应生产源文件一起编译。生产详情的内容测量、位图及倒计时请求计数证据见 [验证说明](docs/VALIDATION.md)。

### 自有模拟宿主

完成上述新候选构建后，可用同一编号启动模拟组合：

```bash
QUOTA_BUTTON_REVISION=a1-c29 bash scripts/run-anchored-quota-button-mock-a1-c1.sh
```

完成操作后停止：

```bash
QUOTA_BUTTON_REVISION=a1-c29 bash scripts/stop-anchored-quota-button-mock-a1-c1.sh
```

模拟组合只替换定位宿主，`QuotaButtonMock.app` 仍使用真实 `QuotaRealProvider`，启动会尝试读取 CLI 账号额度；离线数据验证应使用前面的检查入口。模拟结果也不能代替正式宿主的位置和交互验收。

## 项目结构

```text
Resources/    App 图标与资源说明
Sources/      Swift 生产代码及历史原型
scripts/      构建、启动、停止和验证入口
validation/   解析、状态、传输、布局与倒计时检查
docs/         公开架构与验证说明
build/        本机构建产物与运行记录（不上传）
```

当前按钮入口与宿主定位在 `QuotaAnchoredButton.swift`；共享详情视图在 `QuotaWindowReal.swift`；解析、传输、刷新状态分别在 `QuotaRealData.swift`、`QuotaRealProvider.swift`、`QuotaRealModel.swift`；倒计时格式在 `QuotaCountdown.swift`，窗口几何在 `QuotaWindowLayout.swift`。

`OverlayA.swift`、`QuotaWindowDemo.swift` 及对应脚本保留早期透明覆盖层和独立窄窗实验。它们的候选与验收范围各自独立，当前产品入口以固定额度按钮为准。

## 项目文档

- [架构与模块说明](docs/ARCHITECTURE.md)
- [验证入口与已知范围](docs/VALIDATION.md)
- [图标资源](Resources/README.md)

`.gitignore` 排除构建产物、日志、PID、IDE 配置、设计导出及历史本机验收记录。源码、验证脚本与正式图标可独立用于构建；本地历史记录保留在原目录。
