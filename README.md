# DS-Bot iOS Standalone (Embedded DSH 0.2.2-rc.5)

完全独立于桌面端、Android 与 Docker 的 **Apple iOS 无签名 IPA** 工程，采用 **「稳态 SwiftUI 原生壳 + 可热换裁剪版 DSH 内核包」** 双层架构，首版锁定 `@deepseek-ai/dsh@0.2.2-rc.5`。

## 架构特点

1. **零跨平台耦合**：仅包含 `kernel/`（DSH 裁剪编译器与垫片）与 `ios/`（纯 SwiftUI + XcodeGen），不依赖 Electron、Android、Docker 或桌面配对中转。
2. **单一版本真源防漂移（解决 DSH `#13730` / `#13798`）**：`kernel/dsh.lock.json` 锁定主版本 `0.2.2-rc.5`，`scripts/sync-dsh-lock.mjs` 自动对齐全部 21 个 `@deepseek-ai/dsh-*` 子包与 `overrides`，杜绝跨 `rc` 小版本残留导致 `SessionController` 失活。
3. **`0.2.2-rc.5` 旧会话防崩溃守卫（解决 DSH `#13834`）**：`kernel/src/shims/legacy-session-guard.mjs` 在读取历史会话时自动为缺失的 `turn/end.data.reason` 补全默认值 `{ kind: "completed" }`，不 fork DSH 源码即可安全兼容老日志。
4. **免重签热升级 + 5 秒看门狗自动回滚**：IPA 内置 `0.2.2-rc.5` 作为不可变基线内核；后续 DSH 发新版时，通过 `.github/workflows/dsh-kernel-bump.yml` 产出纯 JS 内核包与 SHA-256 `kernel-manifest.json`，`KernelManager.swift` 校验后原子切换；若新内核 5 秒内未发出 `kernel.ready`，`BareWorkletHost.swift` 自动回滚至基线内核。
5. **全侧载生态兼容（零特权 Entitlements）**：无 Push/iCloud/AppGroup/Extensions 权限冲突，四重门禁校验确保 `arm64` 单架构、零 `_CodeSignature` 与 `embedded.mobileprovision` 残留，直接兼容 **SideStore**、**AltStore**、**LiveContainer**、**TrollStore** 与离线 `zsign` 重签。

## 快速开始

### 1. 运行内核对齐检查与四重契约测试
```bash
cd kernel
node scripts/sync-dsh-lock.mjs --check
npm test
node scripts/build-kernel.mjs
```

### 2. 一键升级 DSH 内核版本（例如升至 `0.2.2-rc.6`）
```bash
cd kernel
node scripts/sync-dsh-lock.mjs 0.2.2-rc.6
npm install
node scripts/build-kernel.mjs --mode=bundle
npm test
```

### 3. 在 macOS 本地构建无签名 IPA
```bash
brew install xcodegen
bash scripts/build-unsigned-ipa.sh
# 产物位于 dist/DS-Bot-iOS-Standalone-v0.1.0-dsh0.2.2-rc.5-unsigned.ipa
```

### 4. 生成 SideStore / AltStore 订阅源
```bash
node scripts/generate-sidestore-source.mjs \
  --repo <owner>/<repo> \
  --tag v0.1.0 \
  --ipa dist/DS-Bot-iOS-Standalone-v0.1.0-dsh0.2.2-rc.5-unsigned.ipa \
  --out dist/source.json
```
