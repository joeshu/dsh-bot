# DS Bot iOS

DS Bot 是 SwiftUI 原生 iPhone 和 iPad 应用。它直连 DeepSeek 或其他 HTTPS Chat Completions 兼容服务。聊天历史保存在本机，模型响应由所选服务提供。应用包含 Bot、群目标和待办、侧边问答、记忆、JS 计算与 Remote MCP。

## 使用

1. 通过 SideStore 或 AltStore Classic 重签并侧载 Releases 中的 IPA。订阅地址为 `https://github.com/joeshu/dsh-bot/releases/latest/download/source.json`。原生候选版的侧载测试可使用对应预发布版本的 `source.json`。
2. 在设置中填写 HTTPS 服务地址并为这个地址保存 API Key。官方默认模型是 DeepSeek Flash。自定义服务可先读取模型列表，也可在 Bot 设置中手填模型 ID。v1.8.2 上使用自定义端点的用户需要重新保存密钥。
3. 聊天中，写入本机数据、读取设备信息、网页访问和 Remote MCP 工具需要确认。工具结果会送给当前模型服务。私密会话使用系统设备身份验证解锁。Remote MCP 支持 HTTPS 上的 2025-03-26 Streamable HTTP。

`kernel/` 仍供 DSH 移植实验使用，原生版的运行和构建均由 iOS 工程负责。原生发布资源包含 Swift App、应用图标与 QuickJS 许可。

## 构建

在 macOS 安装 Xcode 26.6、XcodeGen 2.46.0 和 Python 3.11 或更新版本，再运行：

```bash
bash scripts/build-unsigned-ipa.sh
```

脚本下载并校验固定版本的 QuickJS 源码，通过 Xcode 归档 arm64 iPhoneOS App。输出位于 `dist/`，包括无签名 IPA、`ipa-report.json`、`SHA256SUMS.txt` 和 `source.json`。可用 `DSBOT_OUT_DIR` 指定输出目录。手动运行 XcodeGen 前先运行 `python3 scripts/prepare-quickjs.py`。

## 候选包验收

- 在 Actions 的 **iOS Native IPA** 获取通过模拟器测试的候选包和 SHA-256。
- **iOS Native Release** 的 `stage` 接收已纳入主分支的提交对应的 run ID 和 IPA SHA-256，将同一产物提供为预发布。保留候选提交的合并历史，可直接使用已经验证的分支产物。
- 从预发布验证 SideStore 和 AltStore Classic 的源导入、重签、安装及冷启动。以相同签名身份从 v1.8.2 升级，检查历史记录与配置，再测试官方 API 流式回复、取消、一次批准的 MCP 调用和一次拒绝的工具调用。记录设备、系统、客户端版本与 IPA 哈希。
- 验证通过后执行 `promote`，提供相同的 run ID、哈希和真机记录。发布任务核对预发布资产字节后将其设为最新正式版。候选包有缺陷时修复并提高版本号。

QuickJS‑NG 许可随 App 一起分发，见 `ios/Resources/QuickJS-LICENSE.txt`。
