# App 图标

CodexGauge 使用「暖白底＋橙金阶梯刻度」图标。

- `AppIcon.png`：图标源图，外部浅灰展示底色一并保留。
- `AppIcon.icns`：由该原图转换的 macOS 图标，含 16、32、64、128、256、512、1024 像素表示。
- 重新生成：在项目根目录运行 `bash scripts/generate-app-icon.sh`。

`scripts/build-anchored-quota-button-a1-c1.sh` 在封装生产 `QuotaButton.app` 时复制 `.icns` 并写入 `CFBundleIconFile`，随后签名；缺少图标时停止构建。模拟按钮、模拟宿主和历史候选不变。
