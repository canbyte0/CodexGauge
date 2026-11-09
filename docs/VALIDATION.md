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
| `validation/QuotaSidebarGlyphCheck.swift` | 5h数字与连续百分比圆环、异常/上次记录、同一按钮更新和无窗口位图；`--task109`为数字定向分支，`--task108`为历史圆环分支 |
| `validation/QuotaRealDataCheck.swift` | 生产解析、字段异常与重置明细一致性 |
| `validation/Quota85TransportCheck.swift` | 本地假服务的退出与传输故障 |
| `validation/QuotaWindowLayoutCheck.swift` | 窗口几何边界及主窗口候选选择，使用纯CGRect合成输入 |
| `validation/QuotaAnchoredDetailsLayoutCheck.swift` | 自然高度、图标底边对齐、锚点上方限高与屏幕边界 |
| `validation/QuotaHostCompatibilityCheck.swift` | 纯配置加载与四身份匹配；`--task112`限定分支检查启动自动登记、初始化/合并/同键更新、幂等、坏文件保护和写入失败 |
| `validation/Quota85ViewHarness.swift` | 带测试数据标识的独立视图验收入口 |

这些程序需与相关生产源文件组合编译。几何断言和无窗口测量不能代替实体交互验收。

自动兼容配置的限定检查使用临时路径，不读写真实Application Support：

```bash
CHECK_DIR="$(mktemp -d /private/tmp/quota-host-check.XXXXXX)"
xcrun swiftc -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$CHECK_DIR/module-cache" \
  Sources/QuotaHostCompatibility.swift validation/QuotaHostCompatibilityCheck.swift \
  -o "$CHECK_DIR/host-check"
"$CHECK_DIR/host-check" --task112 Resources/QuotaHostCompatibility.json "$CHECK_DIR/result.json"
```

## 已记录的本机验收范围

2026-11-09，a1-c44改为启动与原生reopen时自动登记宿主身份。实现窗口`--task112`限定15项通过；设计窗口冻结最终配置模块c398260…，独立39项通过，覆盖首次落盘、合成未来版本、同键SHA更新、幂等零写入、错误宿主与坏配置保护、链接/目录拒绝、写入失败、无实际持久化不能误报及新增后超限时原文件保持。两组覆盖重叠，不累加计数。控制器去掉本次生命周期/cache/log增量后逐字匹配c43；其他9份产品源、默认种子与AppIcon保持，三包严格签名、11+11+1输入绑定通过。设计窗口按用户的配置/重启授权退出精确的旧c43进程，启动c44：原外置配置不存在，新包日志记录`added/cold-start/initialized=true`，实际JSON保留25241并新增当前25894；原生再次打开记录`unchanged/reopen`，PID21742、配置字节/mtime、App可执行文件及签名保持。首次进程存活观察早于AppKit启动完成，原始早期观察单独保留，最终启动结论使用后续自身日志与实际配置，无额外重启或手动登记。配置生命周期通过，状态`PASS_AUTO_CONFIGURATION_LIFECYCLE_UI_UNVERIFIED`；未自动访问Codex UI或直接运行CLI诊断，不把登记、进程或签名等同于真实位置/交互验收。

2026-11-06，a1-c43新增外置宿主兼容配置，界面和其他9份产品源保持。实现窗口25项纯配置检查及5项工具检查通过；最终25项结果指向最终生产exe，其SHA与包一致。设计窗口冻结最终模块18b315…，独立21项核心检查通过；模块后改时仅重跑同一21项，不累加覆盖数。另用合成旧/新候选元数据核对verifier的8例迁移行为，证明legacy三方比对保留、新JSON默认/外置规则一致。独立从ZIP解压工具运行17项流程检查：默认查看不建文件/目录，显式登记合成未来版本，生产匹配器由拒绝变为允许且匹配器exe不变、重复幂等、坏文件/坏链接/超长字段不覆盖，App全文件哈希及严格签名保持。21/8/17组与实现25/5组分别记录，覆盖有交叉，不汇总成唯一用例数。三包身份/严格签名、11+11+1绑定、默认资源、AppIcon、其他9源、ZIP解压包/工具/模板一致性通过。没有向真实Application Support写配置，没有App启动或真实宿主窗口/CLI访问，状态`PASS_EXTERNAL_CONFIGURATION_DELIVERY_UI_UNVERIFIED`。

2026-11-06，按用户要求重新生成a1-c42。发现当前公开宿主元数据已为build25241 / 26.1103.31037，故仅更新QuotaAnchoredButton.swift的三个supportedHost常量及相邻查验日期；独立规范化比对确认其他代码完全相同，其他9份产品源、AppIcon和builder哈希保持c41。三包身份/严格deep签名、10+10+1源绑定、当前公开Info.plist/source/包profile一致性通过。正式ZIP经独立安全解压，App的全文件哈希及权限清单与原包一致，解压App严格签名通过。本次没有功能变更或重跑测试/渲染，没有启动/安装候选、读取真实宿主窗口或调用真实CLI。重建交付完成，状态`PASS_BUILD_DELIVERY_UI_UNVERIFIED`；c41的人工确认不自动覆盖新宿主中的c42界面。

2026-11-06，a1-c41将中间三线替换成5h剩余数字。实现窗口只运行既有检查的`--task109`短分支，26项通过，覆盖详情格式去%、0/7/75/100/<1/>99、未知/非法、精确无障碍标签、同一按钮75→7、失败保留7和清空为—，渲染不新增读取。设计窗口阅读源与结果，另冻结生产源导出浅/深色共14张实际按钮88×88px图，独立测得可见边界仍58×58px、中心字形偏移最大1.5px、最小离环间隙约3.93px；0/75/100/unknown外环环带与c40逐像素相同。26项与14张证据分别记录，不累加计数；没有复跑旧分支/其他套件。三包身份/严格签名、10+10+1绑定、其他9源不变、AppIcon/host profile通过，最终源与渲染冻结源匹配。用户手动切换后明确反馈“数字和其他显示都正常”，当前真实数字与5h详情一致、字形完整居中清晰、外圈比例、图标大小/间距、详情底边和外点关闭/重开通过，状态`PASS_USER_CONFIRMED_CURRENT_ENVIRONMENT`。其他真实数字格式、0/100边界及跨屏等环境未由该答复证明。

2026-11-06，a1-c40新增完整轨道与5h剩余连续进度弧。实现窗口仅运行既有glyph检查的`--task108`分支，100项通过，覆盖0/25/50/75/100、小数、未知/非法、同tier的80→75、上次记录保留/清空及渲染不新增读取；机器记录的无新增读取字段已修正并重跑同一分支确认。设计窗口另外冻结产品源，用内存transport导出实际生产按钮浅/深色共12张88×88px图，独立测得顺时针方向、比例、未知中性轨道和58×58px可见大小保持，渲染新增读取0。两类证据分别记录，不把位图张数累加成断言数。三包身份/严格签名、10+10+1输入绑定、其他9份源不变、AppIcon与host profile核对通过，最终源与独立渲染输入一致；用户手动切换后明确反馈“圆环比例和交互都正常”，当前真实5h对应圆环、图标大小/间距、详情底边对齐及外点关闭/重开通过，状态`PASS_USER_CONFIRMED_CURRENT_ENVIRONMENT`。本窗口没有自动启动正式候选或访问真实宿主UI；其他真实档位和跨屏不由该答复证明。

2026-11-05，a1-c39详情面板改为外框底边对齐图标可见下沿。设计窗口冻结当前布局源和既有检查，独立编译运行17项通过，覆盖不同自然高度的共同底边、空间缩小限高和增大恢复、250ms回退上限、极小空间安全clamp与无效输入。此为同一既有检查的独立重跑，不与实现窗口的17项累加计数。三包严格签名、10+10+1输入绑定、其他8份产品源与c38一致、AppIcon和host profile均核对通过。用户随后对底边对齐、移动/改变宿主高度后保持、当前内容完整及外点关闭/重开的明确反馈为“全部正常”，这些当前环境场景通过，状态 `PASS_USER_CONFIRMED_CURRENT_ENVIRONMENT`。此次问题未要求实体长内容滚动或跨屏验证，不扩大确认范围。

2026-11-05，a1-c38调整主窗口候选选择，源码及包静态核对通过。本窗口另外直接调用生产选择器做14例无窗口合成检查，全部通过；实现报告记录既有布局检查34项通过，两组不合并计数。用户随后对小型控制预览下按钮可用、切换其他App或最小化后的隐藏及返回/恢复问题，明确反馈“预览时保留，隐藏和恢复也正常”，当前本机场景通过。此反馈不扩展到任意预览尺寸、真实多个主窗口或跨屏环境。

2026-11-05，a1-c37收到用户明确反馈“大小、居中和间距已一致”，本次视觉对齐通过。该确认仅覆盖图标可见大小、水平居中和两段上下间距，不增加窗口跟随、详情点击、刷新或其他行为的验收结论。

同日a1-c36生产QuotaAnchorButtonView独立无窗口2×图为88×88px，可见边界[15,15,72,72]，即居中的58×58px；导图transport调用0次。3包严格签名、输入绑定及当前宿主profile核对通过，后续用户截图证实可见大小。最终小幅位置修正和人工对齐确认由c37承接，不回写为c36完整人工通过。

2026-11-02，a1-c32适配Codex build 24141 / 26.1027.61615，仅更新三个宿主身份常量及相邻注释。其余九份产品输入、AppIcon保持一致；3包严格签名、10/10+10/10+1/1输入绑定和当前宿主profile独立核对通过。用户手动切换后确认“按钮恢复，交互正常”，覆盖当前宿主中的按钮恢复、位置、详情打开、外点关闭和重开；未知未来宿主版本仍隐藏按钮。

截至2026-11-02，a1-c31 已记录用户对当前真实5h对应图标档位、按钮位置、详情打开、外点关闭与重开正常的确认。四档阈值、浅色/深色组件像素及同一按钮后台订阅使用合成数据和无窗口View验证，不代表真实账号四档均已人工测试。此前a1-c28还记录了倒计时、完整日期及详情开关确认，以及格式边界、生产详情无窗口测量和请求计数检查。

以上是已有本机验收记录的摘要，原始本机截图、日志和交付记录未纳入公开仓库。它不代表本次重新构建的新候选已完成交互验收。

真实账号实际到期事件、跨显示器、操作系统睡眠与唤醒、深色模式和实体长内容滚动尚未完成全面验收。宿主更新后应重新核对版本和布局。
