# Fish Pocket 1.2.0 IPA 参考审计

本审计只读取用户提供的 Fish Pocket_1.2.0.ipa，没有运行其中的程序。样本 SHA-256：

2ae832d3a6b2fe0226b5baf2e087b21ded982517a35e275f7dc0982473827c53

## 样本构成

- IPA 压缩包约 141 MB；ZIP 项目解压总计 423,551,277 字节。
- nodejs-project/node_modules 有 15,417 个文件，未压缩 241,778,034 字节，ZIP 中占 66,891,836 字节。
- 样本使用 @deepseek-ai/dsh 0.2.2-rc.1，该包声明 90 个直接依赖；另内嵌 pnpm 11.28.5、ds-bot 0.3.1、just-bash 和 TypeScript。
- IPA 还包括 Python 3.15 与 FFmpeg 框架。Node 依赖树中可见 dsh-base、dsh-web-app、终端、实验性 Inspector、Web 前端及大量客户端 UI 插件。
- boot.mjs 通过 runCli() 启动 dsh web 并附加 ios.patch.yml。该 overlay 禁用部分桌面进程/沙箱实现，插入 iOS subprocess、sandbox、host、native 插件；相关替代实现把 shell 命令转交 just-bash，把部分 Node 子进程转为 worker。
- IPA 的最低系统版本为 iOS 17.0。

## Fish Pocket 的采用与取舍

这份样本证明了 NodeMobile、iOS 原生宿主和 DSH 插件组合可以落地，也给出了有价值的边界适配方式：原生桥接插件、插件版本 pin、变更后的重启提示，以及在 iOS 上替换桌面专属服务。

Fish Pocket 的目标是 SwiftUI 原生客户端，不需要启动 DSH Web Server 或把桌面终端搬到手机。因此当前实现使用 DSH 0.2.2-rc.5 的官方 profile-boot 生命周期和独立 dsbot-ios profile，逐项挂载 session、agent、LLM、tools 与原生适配器。它不把 @deepseek-ai/dsh 总包、dsh-base、dsh-web-app、pnpm、Python、FFmpeg 或终端 bundle 当作运行基础。

插件安装保留市场目录发现能力，但采用适合 iOS 的精确版本、SHA-512 tarball 校验和、不运行安装脚本、依赖必须已随 App 内嵌、拒绝本机二进制/链接的策略。内嵌的 DSH profile 插件受保护，不会显示成可卸载的第三方插件。profile 变更前先结束当前 Agent 轮次并释放空闲 Agent；如果官方重组流程报告需要重启，原生界面会明确提示用户重新打开 App。需要重启的卸载会暂存待清理记录，等下次启动后再删除包文件，避免当前 Node 进程继续引用时丢失文件。

截至审计时，当前工作区的锁定 runtime node_modules 约 27 MB（此数值不是 IPA 最终大小）。具体 IPA 大小仍需在 macOS 上完成 NodeMobile 资源暂存和 Xcode archive 后测量。
