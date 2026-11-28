# DSH × NodeMobile × iSH ARM64 implementation

## Current implementation status

The repository now builds source-pinned iSH ARM64 libraries and converts a SHA-256-pinned Alpine 3.23.8 aarch64 minirootfs into iSH fakefs (`data/` plus `meta.db`). CI builds the host-native `fakefsify` converter from the same locked iSH source revision, packages the rootfs in the existing `alpine-rootfs.zip` layout, and records installed packages, license fields, source commit links, SQLite integrity, archive size, and hashes. It also checks the OpenMinis revision, the iSH ARM64 revision, all three iSH submodule revisions, and the upstream build script digest, then packages device and Simulator static libraries, headers, resources, source archives, licenses, and SHA-256 sums. The iSH license bundle records GPLv3, GPLv2 for later contributions, and the iOS addendum.

This artifact is a build foundation. It is not yet linked into `DSBotStandalone`; the application still uses its existing QEMU-backed guest route. The CI artifact's Alpine files are a rootfs candidate, not an app install or an on-demand package installer. Do not describe the iSH runtime as active until the native engine bridge and the acceptance gates below pass. The existing release gate remains in force during this migration.

The first verified library build reports 1,094,488 bytes of device static libraries and 1,097,848 bytes for Simulator. These are archive sizes before app linking and dead stripping. The AOT archive is an empty 720-byte placeholder because the pinned build has no AOT images configured. A new CI build will report the fakefs ZIP and expanded rootfs sizes; neither the final IPA delta nor the on-device persistent copy size has been measured.

## Current user-visible capability

| Surface | Current backend and behavior |
|---|---|
| Bot `terminal_exec` | QEMU ARM64 Alpine PTY; shell text runs in a fresh owner-scoped session with timeout and output limits. |
| Web terminal | QEMU ARM64 Alpine `ash` PTY; interactive input, resize, exit status, session cleanup, and bounded output. |
| DSH subprocess `spawnTerminal` | Only `/bin/sh` or `/bin/ash` is accepted, with the bundled Alpine shell profile. |
| DSH subprocess `spawn(argv)` | Deliberately rejected with `SUBPROCESS_PTY_UNAVAILABLE`; ordinary pipe-backed child processes are not implemented on iOS yet. |
| iSH ARM64 | Source-pinned device/Simulator libraries build and verify in CI; no iSH code is linked or selected at runtime. |

At the pinned OpenMinis revision, the app-level integration lives in `src/ios/iSH/ISHKernel` and `ISHShellExecutor`, alongside the iSH kernel libraries. It includes fakefs boot and bind-mount hooks, a PTY path, and argv-based execution with pipe output and exit notifications. Those Objective-C sources and their app dependencies are not part of the current DSH target or the static-library artifact. Port the minimum required host glue behind DSH's runtime contract; do not import OpenMinis UI or native offload handlers as a bundle.

Run the build on macOS with Xcode and the iOS SDKs. It builds the iOS libraries and host `fakefsify`, fetches the pinned minirootfs, converts and packages the fakefs image, then verifies the combined artifact:

```sh
bash scripts/build-ish-arm64-ios.sh
```

The output is written to `dist/ish-arm64-ios/` by default. CI builds the same artifact on `macos-26` and retains it for 30 days.

## Target runtime

```text
DSH 0.2.2-rc.5 control core
       │ existing SubprocessRuntime / RPC compatibility adapters
NodeMobile 24.22.3 host process
       │ authenticated host-issued execution lease
       ├── iSH ARM64 engine, one per App process, started lazily
       │     ├── persistent fakefs metadata and Alpine rootfs in Application Support
       │     ├── project directories bind-routed to the same APFS project folders
       │     └── independent Linux tasks, pipes, PTYs, signals, and cancellation
       └── shared APFS project folders for bot tools, Web terminal, and native UI
```

Node and DSH remain in the host process. The iSH guest supplies Linux syscall and process behavior; it is not a second DSH/Node runtime. Guest UID 0 means root inside the fake Linux filesystem only. It does not grant iOS root, jailbreak, Keychain access, or access to files outside the app sandbox.

Existing projects must map to stable project IDs. The current `files/` directory becomes the default project without moving its contents. Bot terminal, Web terminal, workspace tools, and native file UI resolve paths through one host-controlled project resolver. A client-provided `DSH_SESSION_ID` or Linux `fs_context` value is routing metadata, not authorization.

The iSH process shares the app's address space. It does not sandbox malicious JavaScript plugins. DSH plugin permissions and host RPC checks remain the security boundary for plugins; project path checks protect file routing across the host and guest.

## Migration steps and gates

### 1. Engine build, rootfs candidate, and source provenance — implemented; app packaging pending

- Locked OpenMinis and iSH revisions are in `scripts/ish-arm64-sources.lock.json`.
- `scripts/build-ish-arm64-ios.sh` creates device and Simulator libraries from source.
- `scripts/prepare-arm64-guest.py --minirootfs-only` downloads only the hash-pinned Alpine minirootfs, avoiding a QEMU kernel download for the iSH build.
- `scripts/build-ish-arm64-ios.sh` builds host-native `fakefsify` from the locked iSH revision and converts the pinned source to the `alpine-rootfs.zip` layout consumed by the existing rootfs installer.
- `scripts/package-ish-arm64-ios.py` emits the rootfs package inventory and notices, iSH source archives, hashes, component sizes, and a report that explicitly says the artifact is not linked into the app.
- `scripts/verify-ish-arm64-artifact.py` gates publication on locked commits, source archives, notices, checksums, library byte totals and ARM64 slices, rootfs ZIP paths/CRC, SQLite integrity, package inventory, and component sizes.
- `.github/workflows/ish-arm64-ios-runtime.yml` performs the macOS build on relevant pushes and pull requests.

### 2. Native engine lifecycle — next

Port the pinned OpenMinis kernel boot and fakefs setup behind a small Objective-C/C bridge and Swift `LinuxRuntime` actor. Boot one engine lazily per App process and keep it mounted until process exit. Persist fakefs metadata and the Alpine filesystem under Application Support; never replace or unmount the rootfs while the engine is live. Startup must be idempotent, serialized, cancellable for the waiter, and recoverable on the next cold launch after an interrupted upgrade.

The bridge must install signal handling that preserves Node/V8 handlers, stop sharing iSH's process-global current working directory with Node, and expose memory/FD/thread diagnostics. Do not enable native offload until its global `chdir`/abort behavior is removed or serialized with explicit invocation context.

**Gate:** cold boot, warm command, shutdown/relaunch recovery, and signal tests pass in an ARM64 Simulator build; no `XCTSkip` path can turn a required iSH runtime test into a pass.

### 3. Authenticated process and PTY sessions

Port the upstream process and PTY primitives separately. Preserve DSH's `SubprocessRuntime` contract: synchronous `spawn(argv)` returns a pipe-backed process handle; `spawnTerminal` creates a real PTY; both preserve argv boundaries, cwd, env, exit status, signals, and cancellation. Keep the existing RPC names as compatibility adapters while moving their implementation behind `LinuxRuntime`.

Each execution receives a host-issued lease bound to project, owner session, tool call, worker generation, and permissions. Interactive sessions and one-shot commands have separate IDs and cleanup. Maintain the four-PTY cap, bound output buffers, and make concurrent Web reads independent so a later read cannot replace an earlier waiter.

**Gate:** shell metacharacters in argv stay literal; PTY echo, resize, foreground signals, exit codes, timeout and close are checked in Simulator; cancellation cannot leave a live process or lease.

### 4. Persistent fakefs and project routing

Use iSH `fs_context` only as an opaque project route. The host resolver maps it to an already authorized project root and rejects unknown contexts. Implement both forward and reverse path hooks. Denied paths must fail closed rather than fall through to a global bind mount. Prevent `..`, symlink, hard-link, descriptor, and cross-project escapes. Bind project directories from the app sandbox; do not expose Keychain, databases, or the DSH plugin directory.

Host workspace writes and edits use atomic replacement and a revision/CAS check. Shell writes keep normal Linux semantics. Both paths emit file-change events for UI refresh and persistence.

**Gate:** the same file written from DSH tool, bot shell, Web terminal, and native UI is visible to each; two projects cannot read or modify each other's files; restart preserves both projects and fakefs metadata.

### 5. Offline rootfs and on-demand tools — base image candidate exists; install flow pending

Keep the CI-generated Alpine fakefs as an immutable base candidate. The current app does not install it and has no package selector yet. When runtime wiring is implemented, start with the base BusyBox tools and show install suggestions for missing commands. Optional packages such as `bash`, `jq`, `ripgrep`, and `git` must be user-selected or explicitly requested. A host-side installer should fetch APKs, verify Alpine signatures and hashes, resolve dependency closure, then commit the package transaction into fakefs. Guest network remains disabled by default. Never automatically rerun a command after a failed package install because it may have partially executed.

Keep the model API online requirement separate from local guest/tool availability. The shell, rootfs, and previously installed tools continue to work offline.

### 6. Performance and release promotion

Use one shared `MemoryGovernor` for Node, WebAssembly, and iSH. Initial caps: four PTYs, two heavy tasks, eight Linux processes per task tree, 32 global Linux processes. Tune from device measurements. Keep AOT off until the image ABI and engine build ID match exactly; initially evaluate musl, BusyBox, and zlib with a 30 MiB uncompressed budget. Measure actual app bundle growth, AOT hit rate, boot latency, command latency, memory peak, and process/thread/FD cleanup.

Targets for the first device baseline: engine ready p95 ≤3 s after rootfs install; warm `/bin/true` p95 ≤200 ms; PTY echo p95 ≤100 ms; selected AOT suite ≥15% overall improvement. These are targets, not measured results.

Only switch the release gate from QEMU to iSH after device and Simulator integration pass, exact IPA component sizes and SBOM are emitted, the source/license bundle is attached, and 4 GB-class iPhone memory testing is complete. Keep the previous release path available until an iSH candidate passes those gates.
