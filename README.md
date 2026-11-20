# DS Bot iOS

DS Bot keeps the SwiftUI iPhone/iPad interface and runs the real DeepSeek Harness 0.2.2-rc.5 agent in an embedded Node.js runtime. Swift talks to Node through a private Unix socket pair; the app does not open a local network listener. The DSH event log is stored in SQLite with WAL and full synchronous writes. The app's `dsh-home` directory is also passed as `DSH_HOME`, keeping DSH identity and cache files in the app container. Existing iOS Keychain credentials and native capabilities are exposed through a narrow, first-party bridge.

The runtime starts through the official DSH 0.2.2-rc.5 `profile-boot` `runProfile()` lifecycle. It uses a dedicated `dsbot-ios` profile whose explicit Cordis rows mount the agent, agent loop, LLM, DeepSeek API-key provider, sessions, projections, tools and the iOS host adapters. The exact official `@deepseek-ai/dsh/profile-boot` subpath is vendored with its MIT license; the `@deepseek-ai/dsh` umbrella package and its desktop dependency graph are excluded. The app also excludes `dsh-base`, `dsh-web-app`, shell, terminal and desktop automation bundles.

The **探索 → 插件** screen has the DSH format 1 indexes from dsh-market and dshfind, plus custom HTTPS indexes and local-folder import. Sources are off by default, and only one can be enabled at a time. Installing an indexed NPM bundle pins the exact listed version, verifies the registry tarball's SHA-512 digest, and never runs package scripts. The iOS installer rejects desktop bundles, native/WebAssembly files, symlinks, process/worker/VM imports, incompatible DSH bundle platform declarations, and packages whose runtime or peer dependencies are not already available in the embedded iOS dependency graph. App-embedded DSH profile plugins are protected from third-party enable/remove actions. Plugin changes stage an atomic profile revision and restart the DSH worker over the existing Swift socket. Failed revisions roll back to the previous manifest. If recovery also fails, the supervisor starts only the iOS core and lets the user disable or remove offending plugins. Removed packages remain on disk until the new profile starts successfully. Third-party plugin code still runs inside the app's Node process, so the screen asks users to trust the source and author.

The supplied Fish Pocket 1.2.0 IPA was inspected as a read-only reference. It demonstrates a working NodeMobile/DSH iOS host and useful platform adapters, while carrying a 90-dependency DSH rc.1 umbrella graph, pnpm, Python, FFmpeg, web UI and terminal components. The reference findings and Fish Pocket adoption decisions are recorded in [the IPA audit](docs/ios-reference-ipa-audit.zh.md).

## Runtime status

The only verified NodeMobile iOS binary currently available in this workspace is Node 24.22.1. Upstream Node 24.22.3 was published on 2026-11-10, so the build marks this as a preview probe and the release workflow refuses to promote it. A public release needs a NodeMobile framework rebuilt from the mobile source patches at a current security release, followed by locally re-signed device acceptance. The generated IPA report records these blockers.

The existing app accepted Chat Completions endpoints. The upstream DSH DeepSeek adapter uses the Anthropic Messages protocol. The official DeepSeek endpoint is translated to its `/anthropic` route; a custom endpoint must support that protocol. API keys remain in Keychain and are resolved when DSH makes a request. Existing Swift chat archives remain in `chats.json`; the most recent archived messages are imported as bounded context into a new DSH session.

## Use

1. Install a preview IPA only for runtime/device evaluation. Do not use a preview candidate for public distribution while its report says `releaseEligible: false`.
2. In Settings, enter the HTTPS service address and save its API key. Choose a model supported by the service.
3. DSH tools run through the iOS bridge. Memory writes, group tasks, device status, web fetch and Remote MCP request approval. JavaScript evaluation runs in the existing bounded QuickJS sandbox. DSH owns new chat turns and durable event history.
4. Open **探索 → 插件** to manage the dedicated iOS DSH profile. A catalog entry is not automatically considered iOS-compatible: its package is checked again at install time, and missing dependencies or desktop-only capabilities are rejected.

## Build

On macOS, install Xcode 26.6, XcodeGen 2.46.0, Python 3.12, Node 24.22.1/npm 11.9.0, then run:

```bash
bash scripts/build-unsigned-ipa.sh
```

The build uses Node.js 24.22.1/npm 11.9.0 and `npm ci` against `kernel/runtime/package-lock.json`, stages the pinned upstream JS packages, downloads the SHA-256-pinned NodeMobile XCFramework, removes upstream code signatures, and archives the arm64 iPhoneOS app. The verifier inspects the embedded framework Mach-O, DSH package versions and lock digest, the app's NodeMobile load command, privacy metadata and unsigned status. Outputs include the IPA, `ipa-report.json`, `source.json` and `SHA256SUMS.txt` under `dist/` (or `DSBOT_OUT_DIR`). The IPA is expected to be much larger than the previous Swift-only 900 KB package because it contains Node and the upstream JavaScript runtime.

After staging the runtime, run `python3 scripts/smoke-dsh-runtime.py` to exercise the app's socket protocol, native credential bridge, provider endpoint update, DSH turn lifecycle and SQLite recovery across a Node restart without contacting a model service.

The generated IPA report also breaks out compressed and uncompressed sizes for the app executable, NodeMobile framework, DSH runtime and assets.

## Candidate and release gates

- The **iOS Native IPA** workflow builds the candidate and runs simulator validation. It uploads the unsigned IPA and its report for review.
- The **iOS Native Release** `stage` operation may publish a preview candidate after checking its exact IPA hash and source commit.
- `promote` is blocked unless the archived report says the embedded Node runtime is current and release-eligible. It also requires recorded re-signed device acceptance, including install, cold launch, upgrade, chat, cancellation, approval and rejection flows.

Runtime dependencies and licenses are recorded in `DSHRuntime/THIRD-PARTY-NOTICES.txt`; NodeMobile, QuickJS and upstream package notices ship with the app.

## Re-signing and device evidence

For LCSign, import the unsigned IPA from the build artifact. For an upgrade test, keep the original bundle ID `io.github.dsbot.ios.standalone` and the same signing identity as the installed copy. Use the separate signed IPA's SHA-256 in the device evidence.

Use a macOS keychain identity and a device provisioning profile that authorizes the original bundle ID. The helper validates the unsigned archive, signs the nested NodeMobile framework before the app, checks that both signatures use a certificate listed in the provisioning profile, and prints both checksums.

```bash
bash scripts/resign-ios-ipa.sh unsigned.ipa device.mobileprovision 'Apple Development: Name (TEAM)' signed.ipa
```

Promotion accepts a JSON record with `commit`, `unsignedSha256`, `signedSha256`, `signingToolVersion` and `devices`. Each device has `model`, `ios` and a `results` object. The required scenario keys are listed in `scripts/verify-ios-device-evidence.py`; report `pass` only for an observed result. Use the same app identity for upgrade and Keychain retention checks.

The iOS profile exposes the upstream `dsh-web` service through the existing Swift approval flow. DeepSeek web search is off by default and is available with an official API address and a Keychain API key. The app asks for approval before sending each exact query and leaves the original user prompt out of the search request. The in-process subagent tool is opt-in with one child at a time and one level of delegation.

The **iOS Native IPA** workflow accepts `build_security_runtime` to build the full NodeMobile 24.22.3 framework from the pinned mobile snapshot and verified upstream security diff before archiving the app. This pipeline records the framework and archive digests. Use the same macOS toolchain for local reproduction.
