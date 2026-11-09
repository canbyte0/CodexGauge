# CodexGauge

Codex 额度仪表 · A lightweight macOS companion for Codex with quota details, reset countdowns, and automatic refresh.

一个用 Swift、AppKit 和 SwiftUI 编写的 macOS 辅助应用。在 Codex 桌面应用最左侧窄栏显示固定的仪表图标，点击即可查看当前 CLI 登录账号的额度。

按钮由独立的 `QuotaButton.app` 绘制并跟随宿主窗口。额度范围取决于 CLI 登录账号，不能据按钮所在位置推断为当前聊天或工作区额度。

## 功能

- 查看 **5h 剩余额度**、**周剩余额度**及各自的重置日期。
- 侧栏图标使用完整浅色圆环轨道，深色弧从顶部顺时针展示 **5h 剩余额度百分比**；圆内直接显示剩余数字，不带 `%` 符号。
- 查看服务端提供的 **限额重置剩余次数**，按到期时间排列逐条明细；此应用只读取和展示额度。
- 在重置日期右侧、每条到期明细中显示独立倒计时，例如 `4天15时`、`3时42分`、`42分18秒`。
- 启动时读取一次，成功读取后约每 **60 秒**后台刷新；支持手动刷新，反复打开详情不额外发起读取。
- 详情宽度为 **320 pt**，位于按钮右侧，外框底边与图标可见下沿对齐；高度随实际内容调整，空间不足时限高滚动。
- 再次点击按钮、按 `Escape`、关闭详情窗口或点击外部可收起详情。切换应用或最小化宿主时隐藏按钮。
- 保留最后成功更新时间，区分未知、未提供、异常及上次记录；到期倒计时不会在本地修改额度百分比或重置次数。
- 每次启动或在已运行时再次打开 App，自动登记当前 Codex 的版本身份并重新载入兼容配置。

日期按 `Asia/Shanghai` 显示。倒计时复用现有一秒时钟，额度重置到时显示“等待更新”，明细到时显示“已到期”，未知或不过期显示“—”。

## 当前状态

**2026-11-09**，**a1-c44** 已改为每次启动或已运行时再次打开App自动登记当前Codex身份并重新载入配置，无需手动命令。首次初始化、保留历史、同版本键更新哈希、幂等、坏文件保护和写入失败等独立39项检查通过；实现侧限定15项检查通过，两组覆盖有交叉，不相加。三包身份/严格签名及11+11+1输入绑定通过，其他9份产品源、UI、刷新行为、AppIcon和内置种子保持。已按用户要求重启到c44，实际首次启动自动创建外置配置并登记build25894，再次原生打开记录unchanged，同一进程与配置字节/mtime保持。状态`PASS_AUTO_CONFIGURATION_LIFECYCLE_UI_UNVERIFIED`：配置生命周期已验证，没有新增真实Codex界面验收。

**2026-11-06**，**a1-c43** 已支持外置宿主兼容配置。首次换用此版后，确认普通Codex新版本兼容时，可登记用户目录中的JSON并重启额度App，免于重新编译/打包。外置缺失时使用包内默认记录，存在但无效时拒绝匹配；四项宿主身份精确校验和窗口守卫保持。实现侧25项配置及5项工具检查通过，独立21项核心检查、8例新旧verifier协议核对，以及解压工具17项配置更新流程检查通过，App全文件哈希/签名不变。三包身份/严格签名、11+11+1输入、默认资源/工具/ZIP一致性通过，其他9份产品源和AppIcon保持。状态`PASS_EXTERNAL_CONFIGURATION_DELIVERY_UI_UNVERIFIED`，没有修改UI或新增实际宿主界面验收。

**2026-11-06**，按用户要求重新生成 **a1-c42**，沿用c41的圆环和中间数字。当前Codex公开包版本已更新，故仅将三个宿主版本配置常量及查验日期更新为build25241 / 26.1103.31037，其他9份产品源、AppIcon及构建脚本保持。三包身份/严格签名、10+10+1源绑定和host profile核对通过；正式ZIP独立解压后的全文件哈希/权限清单与原包一致，解压包严格签名通过。状态`PASS_BUILD_DELIVERY_UI_UNVERIFIED`：重新构建交付已完成，没有启动新候选或新增真实界面验收，c41人工结论不自动继承到新宿主。

**2026-11-06**，**a1-c41** 将圆环中间三线替换为当前5h剩余数字，沿用详情格式并省略%符号；未知显示`—`，外圈连续进度保持。实现窗口数字定向检查26项通过；独立生产按钮浅/深色14张无窗口图确认数字完整居中、与圆环留有间隙，可见大小仍58×58px。三包身份/严格签名、10+10+1输入绑定、其他9份产品源与AppIcon保持、host profile核对通过，最终构建源匹配渲染输入。用户随后明确反馈“数字和其他显示都正常”，当前真实数字与详情一致、完整居中清晰、外圈比例、图标大小/间距及详情底边/外点关闭/重开通过本机验收，状态`PASS_USER_CONFIRMED_CURRENT_ENVIRONMENT`。其他真实数字格式和环境仍不由此确认。

**2026-11-06**，**a1-c40** 将图标外圈改为完整浅色轨道和5h剩余额度的顺时针进度弧，内部三线分档保留。实现窗口定向检查100项通过；独立生产按钮浅/深色12张无窗口渲染及像素测量通过，可见大小仍58×58px，三包严格签名、10+10+1输入绑定、其他9份产品源及AppIcon保持、当前host profile核对通过。用户随后明确反馈“圆环比例和交互都正常”，当前真实5h比例、图标大小/间距、详情底边对齐和外点关闭/重开通过本机验收，状态 `PASS_USER_CONFIRMED_CURRENT_ENVIRONMENT`。其他真实百分比档位仍以合成验证为依据。

**2026-11-05**，**a1-c39** 已将详情面板改为底边对齐额度图标的可见下沿，替代此前的垂直居中。自然高度与有效高度分开保留，上方空间不足时限高，空间增大后恢复；250ms测量回退采用相同上限。独立运行既有详情布局检查17项通过，三包签名、输入绑定、源范围和宿主profile核对通过。用户随后明确反馈“全部正常”，当前环境的底边对齐、移动/高度变化后的跟随、当前内容完整及外点关闭/重开通过，状态为 `PASS_USER_CONFIRMED_CURRENT_ENVIRONMENT`。此确认不扩展到实体长内容滚动或跨屏场景。

**2026-11-05**，用户已确认 **a1-c38**“预览时保留，隐藏和恢复也正常”：当前小型控制预览场景及切换其他App、最小化后的隐藏/恢复通过本机验收。一个合格主窗口配小型辅助预览时继续定位到主窗口，只有小窗或多个合格主窗口时仍隐藏。两条定位路径共用纯选择器；14例独立合成检查、源码范围、三包签名、输入绑定和profile核对通过。本次人工反馈不扩展到任意预览尺寸或跨屏环境。

**2026-11-05**，用户已确认 **a1-c37**“大小、居中和间距已一致”，本次底部图标视觉对齐通过。c36生产组件及用户截图提供58×58px可见大小证据；c37将位置向右0.5pt、向下1pt微调，leftInset9.5pt、中心距宿主底部136.0pt，宿主适配24614 / 26.1029.61003。源码差异、三包签名、输入绑定和profile核对已通过；本次人工反馈仅覆盖可见大小、水平居中和上下间距，窗口跟随及交互没有新增结论。

截至 **2026-11-02**，最新本机验收记录为 **a1-c32**：Codex更新至build 24141后，旧版额度App因版本保护隐藏按钮；c32适配当前宿主，用户确认“按钮恢复，交互正常”，覆盖按钮恢复、位置和详情打开、外点关闭及重开。

此前 **a1-c31** 已记录用户确认“当前档位正确，其他正常”。70%/20%/0%阈值、同一按钮后台更新、四档组件位图、输入和签名独立检查通过；该人工反馈只覆盖当时真实档位，四档仍以合成验证为依据。c32仅更新宿主身份配置及相邻注释，其余九份产品输入保持一致。

此前 **a1-c28** 已记录用户对两类额度和每条明细的倒计时、完整日期、外点关闭及重开正常的确认。格式边界、生产详情视图测量、请求计数、构建输入和签名的独立核对见 [验证说明](docs/VALIDATION.md)。

此结论覆盖记录中的本机环境。真实账号实际到期事件、跨显示器、睡眠与唤醒、深色模式和实体长内容滚动没有新增完整验收；时钟推进和请求计数使用合成数据验证。项目仍以本机构建候选交付，没有完成面向公众发布的完整验证。

仓库提供源码、脚本和图标，使用时按下文构建本机候选。App 可执行文件及历史本机验收证据未纳入源码仓库。

## 环境与适配范围

| 项目 | 当前要求 |
| --- | --- |
| 系统与架构 | macOS 14.0 及以上，Apple Silicon；脚本目标为 `arm64-apple-macosx14.0` |
| 构建工具 | 提供 `xcrun swiftc`、macOS SDK 和 `codesign` 的 Xcode / Command Line Tools |
| 宿主 Bundle ID | `com.openai.codex` |
| 内置兼容配置种子 | `26.1103.31037`，build `25241`；首次启动以此初始化，再自动加入当前宿主身份 |
| 默认记录的宿主 Info.plist SHA-256 | `bed7f5674232b8749daec398acd4c3edfc3b30ee1611ffeac6cd346c23fdc4ba` |
| 窗口条件 | 唯一一个至少 `900 × 700 pt` 的合格可见主窗口；小型辅助窗口不计入主窗口唯一性，按钮处于屏幕可见区域 |
| 数据前提 | 固定路径下的随应用打包 CLI 可用、签名校验通过，并已登录可读取额度的账号 |

位置参数位于 [QuotaAnchoredButton.swift](Sources/QuotaAnchoredButton.swift)。宿主白名单使用schemaVersion=1的JSON，默认资源为 [QuotaHostCompatibility.json](Resources/QuotaHostCompatibility.json)。运行时读取宿主公开Info.plist，精确匹配Bundle ID、build、版本号与文件SHA-256；目标Bundle ID固定为`com.openai.codex`。

自动登记失败、配置无效、没有合格主窗口、多个合格主窗口、定位不唯一或位置不满足条件时会隐藏按钮。实际切换其他App或宿主最小化时继续隐藏。普通版本身份变化由每次打开App时自动登记处理；布局、接口或程序逻辑需要调整时仍可能需要更新App。

## 使用

1. 启动已核对版本的 `QuotaButton.app`，将符合适配条件的 Codex 主窗口置于前台。
2. 点击最左窄栏底部、原生圆形按钮上一行的仪表图标，打开额度详情。
3. 等待启动读取，或点击详情底部的小刷新按钮；若出现多个可选额度来源，可通过选择器切换。
4. 再次点击仪表图标、按 `Escape`、点击外部或关闭详情窗口，收起面板。
5. 退出辅助应用时，先打开详情，再使用“额度按钮”应用菜单中的“退出额度按钮”或按 `⌘Q`。

关闭详情后后台刷新继续；退出辅助应用时会停止模型、清理其 CLI 子进程并移除 PID 文件。请只运行一个正式候选。

## 自动兼容配置

从 **a1-c44** 开始，每次启动App，或App已运行时再次在Finder打开，都会自动读取`/Applications/ChatGPT.app/Contents/Info.plist`，将当前有效的Codex身份登记到`~/Library/Application Support/CodexGauge/host-compatibility.json`，重新载入后定位按钮。日常使用无需运行命令，也不需要因普通版本号变化重新打包。

外置文件不存在时，从签名包内种子初始化并加入当前身份；存在时保留历史条目。相同版本键的Info.plist哈希变化会更新该条目；完整身份未变时不重复写文件。配置损坏、不可读或路径异常时保留原文件并停止匹配，不会静默覆盖修复。

这项登记仅处理版本身份，四项精确匹配及原有窗口守卫继续生效。新Codex的布局和接口变化仍可能需要程序适配；自动登记本身不代表真实界面验收通过。点击额度按钮、切换前后台及后台额度刷新不会触发配置写入，原有额度读取节奏保持。

以下工具保留为可选诊断入口，默认只读查看当前公开宿主身份：

```bash
python3 scripts/update-quota-host-compatibility.py
```

需要手动登记时仍可显式执行：

```bash
python3 scripts/update-quota-host-compatibility.py --approve-current-host
```

工具原子写入外置文件，重复登记不新增条目，不修改已签名App；同版本键哈希变化的自动处理由App完成。发布ZIP中附带工具、模板和中文说明。移走外置文件后，下一次打开App会重新用种子及当前身份初始化。以上自动行为需要先换用a1-c44或更新版本。

## 从源码构建

先获取源码：

```bash
git clone https://github.com/canbyte0/CodexGauge.git
cd CodexGauge
```

以下命令均在项目根目录执行。当前构建入口为 `scripts/build-anchored-quota-button-a1-c1.sh`；文件名沿用首版，候选编号由 `QUOTA_BUTTON_REVISION` 指定。脚本要求编号形如 `a1-c29`，并拒绝覆盖已有同名目录。

可先核对宿主的公开包元数据；目标Bundle ID固定，当前版本身份由App启动时自动登记，无需将内置种子改为每个新版本：

```bash
HOST_INFO='/Applications/ChatGPT.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HOST_INFO"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOST_INFO"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$HOST_INFO"
shasum -a 256 "$HOST_INFO"
```

下面使用 `a1-c29` 作为新候选示例；如果该目录已经存在，请选择尚未使用的编号。builder复制默认兼容JSON并写入schema元数据，不再使用四项`QUOTA_BUTTON_PROFILE_HOST_*`变量；旧参数会被明确拒绝，避免出现两份相互矛盾的配置。

```bash
QUOTA_BUTTON_REVISION=a1-c29 \
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

侧栏额度按钮使用「完整百分比圆环＋额度数字」单色图标。浅色轨道始终完整，深色弧从12点方向顺时针展示当前5h剩余额度，100%为完整深圈，0%只留浅色轨道；圆内以11pt半粗等宽字形显示数字，格式与详情一致并省略%符号，例如`75`、`100`、`<1`、`>99`。数据未知时显示`—`且不绘制进度，当前有效上次记录保留原比例和数字及状态说明。圆环由SwiftUI `Shape`绘制，设计路径采用24单位坐标，当前渲染画布为36 pt，描边1.8 pt，实际可见轮廓约28.8 pt，使用系统次要标签色，点击区域为44 × 44 pt。矢量设计源文件为 `Resources/SidebarQuotaIcon.svg`。

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
