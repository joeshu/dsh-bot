# DSH × NodeMobile × iSH ARM64 implementation

## Current implementation status

The repository now builds source-pinned iSH ARM64 libraries and converts a SHA-256-pinned Alpine 3.23.8 aarch64 minirootfs into iSH fakefs (`data/` plus `meta.db`). CI builds the host-native `fakefsify` converter from the same locked iSH source revision, packages the rootfs in the existing `alpine-rootfs.zip` layout, and records installed packages, license fields, source commit links, SQLite integrity, archive size, and hashes. It also checks the OpenMinis revision, the iSH ARM64 revision, all three iSH submodule revisions, and the upstream build script digest, then packages device and Simulator static libraries, headers, resources, source archives, licenses, and SHA-256 sums. The iSH license bundle records GPLv3, GPLv2 for later contributions, and the iOS addendum.

The app has an opt-in iSH ARM64 Objective-C engine bridge, a Swift PTY adapter, a persistent fakefs installer, and a build path that embeds the pinned rootfs and iSH libraries. iSH remains behind `DSBOT_ISH_RUNTIME_ENABLED`; release/default builds still select QEMU. CI has linked Simulator and physical-device ARM64 targets. Earlier Simulator runs found and fixed ZIP path normalization, long Unix-socket paths, QoS inversion, and an overflowing host `uname` hostname copy. The source-locked iSH patch now reports a fixed `dsbot` hostname and uses a bounded write.

The iSH ARM64 engine build and both Simulator/device link gates passed in [run 46181680624](https://github.com/joeshu/dsh-bot/actions/runs/46181680624). The Simulator test validated the private rootfs/workspace boundary, executed its shell script with exit status 0, and completed the background shell with exit status 0. It failed while extracting the background PID marker from the PTY output (`NativeRuntimeTests.swift:422`); the test now emits the marker with one `printf` call and parses it without requiring a line boundary. Node/V8 coexistence, a clean PTY rerun, and physical-device acceptance remain release gates.

QEMU's ARM64 guest passed the host TCG PING/PONG probe and the full host PTY smoke in [run 46179010914](https://github.com/joeshu/dsh-bot/actions/runs/46179010914). The same run's iOS Simulator test received `READY`, sent its challenge, and timed out after 120 seconds without a PONG. The pre-fix retest in [run 46180894658](https://github.com/joeshu/dsh-bot/actions/runs/46180894658) hit the same timeout. Commit `9b06932` removes binary PING before READY and preserves an early READY until the waiter is installed; its latest validation is active in [run 46181680747](https://github.com/joeshu/dsh-bot/actions/runs/46181680747). Keep QEMU as the default until this Simulator test passes. The signed APK catalog and tool-selection UI are not implemented yet.

The latest iSH build reports a 4,129,738-byte fakefs ZIP that expands to 8,747,296 bytes, plus 16 base packages. Device static-library archives total 1,094,488 bytes and Simulator archives total 1,097,848 bytes; these are archive sizes before app linking and dead stripping. The AOT archive is an empty 720-byte placeholder because the pinned build has no AOT images configured. The complete iSH CI artifact is 214,194,599 bytes because it also carries source archives, headers, licenses, and build provenance; that is not an app bundle estimate. The iSH-linked device `.app` measured 256,529,679 expanded bytes, including existing DSH, NodeMobile, Python, and QuickJS resources. The rootfs ZIP adds 4,129,738 bytes to app resources and expands to 8,747,296 bytes in Application Support. The final IPA delta against the QEMU build remains unmeasured.

## Current user-visible capability

| Surface | Current backend and behavior |
|---|---|
| Bot `terminal_exec` | QEMU ARM64 Alpine PTY; shell text runs in a fresh owner-scoped session with timeout and output limits. |
| Web terminal | QEMU ARM64 Alpine `ash` PTY rendered by pinned SwiftTerm; raw VT output, interactive input, resize, exit status, session cleanup, and bounded buffers. |
| DSH subprocess `spawnTerminal` | Only `/bin/sh` or `/bin/ash` is accepted, with the bundled Alpine shell profile. |
| DSH subprocess `spawn(argv)` | Deliberately rejected with `SUBPROCESS_PTY_UNAVAILABLE`; ordinary pipe-backed child processes are not implemented on iOS yet. |
| iSH ARM64 | Optional build embeds pinned rootfs and links the engine; Simulator boot is not yet accepted, and QEMU remains default. |

The app bridge currently ports fakefs boot and a `/workspace` bind mount of only the user project directory `dsh-home/files`; the DSH session database and app metadata stay outside the guest mount. Startup rejects a project tree containing symlinks, and the pinned iSH integration patch rejects guest-created symlinks under host bind mounts. Guest `uname` reports the fixed name `dsbot` with a bounded write rather than exposing or overflowing on the host's nodename. Alpine PID 1/reaping and bounded shell PTYs are implemented. The OpenMinis UI, native offload handlers, and argv-based pipe process API are not imported. DSH `spawn(argv)` still reports `SUBPROCESS_PTY_UNAVAILABLE`; its pipe-backed process contract remains a separate implementation step.

The native Web terminal view uses SwiftTerm v1.18.0 at a fixed source revision. It passes PTY output bytes directly to the VT parser, uses a bounded 1,200-line scrollback and 512 KiB render queue, and batches keyboard input into ordered RPC writes with a 64 KiB cap. The Alpine shell exports `TERM=xterm-256color` to match the emulator. Before opening a session, the serial broker waits for the guest agent's READY frame, then requires a random challenge PONG; it keeps an early READY so fast guest startup cannot race the waiter. The soft-key row exposes common control, cursor, paging, and F1–F4 keys. OSC 52 clipboard reads and writes and terminal-originated link opens are denied; ordinary user keyboard input and the system keyboard remain available. This changes the terminal renderer and input path only; it does not change the runtime backend selection or make iSH the default.

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

### 1. Engine build, rootfs candidate, provenance, and opt-in app link — implemented; Simulator runtime acceptance pending

- Locked OpenMinis and iSH revisions are in `scripts/ish-arm64-sources.lock.json`.
- `scripts/build-ish-arm64-ios.sh` creates device and Simulator libraries from source.
- `scripts/prepare-arm64-guest.py --minirootfs-only` downloads only the hash-pinned Alpine minirootfs, avoiding a QEMU kernel download for the iSH build.
- `scripts/build-ish-arm64-ios.sh` builds host-native `fakefsify` from the locked iSH revision and converts the pinned source to the `alpine-rootfs.zip` layout consumed by the existing rootfs installer.
- `scripts/package-ish-arm64-ios.py` emits the rootfs package inventory and notices, iSH source archives, hashes, component sizes, and a report that explicitly says the artifact is not linked into the app.
- `scripts/verify-ish-arm64-artifact.py` gates publication on locked commits, source archives, notices, checksums, library byte totals and ARM64 slices, rootfs ZIP paths/CRC, SQLite integrity, package inventory, and component sizes.
- `.github/workflows/ish-arm64-ios-runtime.yml` performs the macOS build on relevant pushes and pull requests.
- The source/library/rootfs, Simulator link, and physical-device link checks passed in [GitHub Actions run 46150361982](https://github.com/joeshu/dsh-bot/actions/runs/46150361982). Its runtime test found the ZIP directory-path bug, fixed in `a70c216`. The rerun [46151826737](https://github.com/joeshu/dsh-bot/actions/runs/46151826737) installed fakefs and created the workspace bind mount, but stopped before kernel boot because the Simulator temp path was too long for a Unix-domain socket. Run [46153193817](https://github.com/joeshu/dsh-bot/actions/runs/46153193817) passed the short-path probe and reached workspace mounting. Run [46155631897](https://github.com/joeshu/dsh-bot/actions/runs/46155631897) passed Simulator/device linking and reached Alpine init, then failed its PTY test with a signal trap and `closeSessionID` QoS warning. Run [46159246655](https://github.com/joeshu/dsh-bot/actions/runs/46159246655) included host wake-signal isolation and user-initiated PTY worker QoS, passed both link targets, then trapped during PTY use. Run [46170548304](https://github.com/joeshu/dsh-bot/actions/runs/46170548304) isolated an overflowing `sys_uname` host-name copy, fixed by a bounded guest-only hostname patch. Run [46179010934](https://github.com/joeshu/dsh-bot/actions/runs/46179010934) passed source, fakefs, Simulator/device link, workspace boundary, and background-process checks; its two marker failures came from PTY command echo. In [run 46181680624](https://github.com/joeshu/dsh-bot/actions/runs/46181680624), the workspace and background commands both exited 0, but the test could not extract the PID marker; the marker is now emitted by one `printf` call. The latest measured iSH-linked device `.app` is 256,529,679 expanded bytes. Ordinary QEMU IPA and iOS Simulator checks passed in [GitHub Actions run 46147702305](https://github.com/joeshu/dsh-bot/actions/runs/46147702305).

### 2. Native engine lifecycle — bridge and durable rootfs install implemented; acceptance pending

`ISHRootfsStore` now provides the persistent install half: it verifies the bundled ZIP hash, ZIP paths and CRCs, Alpine layout, SQLite integrity and path count, extracts to a same-volume staging directory, then atomically moves it into Application Support. It refuses to replace an existing rootfs when the bundled image changes, so package/user state cannot be silently erased. `ios/project.yml` can embed the CI rootfs by setting `DSBOT_ISH_ROOTFS_DIR` to the artifact's `rootfs/` directory. The opt-in iSH runtime uses this store; the release/default QEMU path does not.

`ISHLinuxPTYRuntime` boots the bridge lazily, serializes/coalesces concurrent startup, and uses `ISHRootfsStore` to install and validate the pinned image. The Objective-C bridge mounts fakefs, binds the app-owned DSH workspace, sets a fixed guest anonymous-page cap, starts Alpine init as PID 1, and creates owner-issued PTYs. The runtime and bridge are compiled only when explicitly enabled. Run `46181680624` rejected a host symlink and executed the workspace script with exit status 0; its background shell also exited 0. The test then failed to parse the background PID marker, so `/proc` cleanup verification did not run. The marker now uses one `printf` call and the parser searches the full output stream. Node coexistence remains untested before rollout. The installer refuses rootfs replacement on version changes; a separately designed, recoverable migration/reset flow is still needed.

The bridge calls `become_first_process()`. The pinned host integration patch moves iSH's internal wakeup handler to `SIGUSR2`, leaving Node's common `SIGUSR1` inspector hook available, sets Apple guest task threads to user-initiated QoS so PTY teardown does not wait on default-QoS workers, and gives the guest a bounded non-host `uname` hostname. Run `46176536897` confirms the `uname` overflow is fixed, reaches the workspace command, and no longer overflows the output event buffer. Node/V8 coexistence still needs runtime acceptance. iSH still ignores `SIGPIPE` process-wide and keeps process-global guest cwd, so concurrent native execution remains a release blocker. Add memory/FD/thread diagnostics and verify no host callback or plugin code runs under iSH locks. Do not enable native offload until its global `chdir`/abort behavior is removed or serialized with explicit invocation context.

**Gate:** cold boot, warm command, shutdown/relaunch recovery, and signal tests pass in an ARM64 Simulator build; no `XCTSkip` path can turn a required iSH runtime test into a pass.

### 3. Authenticated process and PTY sessions — Bot/Web PTY route implemented; generic spawn pending

Bot `terminal_exec` and the Web terminal now use the backend-neutral `LinuxPTYRuntime` contract, with QEMU as default and opt-in iSH behind the same lease API. The iSH bridge caps sessions at four, bounds input/output, and schedules TERM/KILL cleanup for same-session background processes after the shell exits. Its Simulator shell and workspace checks exit 0; the background PID parser fix is awaiting a rerun before `/proc` cleanup is verified. QEMU host TCG PING/PONG and PTY smoke passed in run `46179010914`, but the pre-fix Simulator run `46180894658` timed out before PTY creation. Commit `9b06932` waits for READY before the challenge and covers early-READY ordering; Simulator validation is running in `46181680747`. Preserve DSH's full `SubprocessRuntime` contract in the next step: synchronous `spawn(argv)` must return a pipe-backed process handle, while `spawnTerminal` creates a real PTY; both preserve argv boundaries, cwd, env, exit status, signals, and cancellation. Keep the existing RPC names as compatibility adapters while moving their implementation behind `LinuxRuntime`.

Each execution receives a host-issued lease bound to project, owner session, tool call, worker generation, and permissions. Interactive sessions and one-shot commands have separate IDs and cleanup. Maintain the four-PTY cap, bound output buffers, and make concurrent Web reads independent so a later read cannot replace an earlier waiter.

**Gate:** shell metacharacters in argv stay literal; PTY echo, resize, foreground signals, exit codes, timeout and close are checked in Simulator; cancellation cannot leave a live process or lease.

### 4. Persistent fakefs and project routing — durable base and default project mounted; multi-project isolation pending

The bridge bind-mounts only the app-owned `dsh-home/files` directory at guest `/workspace`. DSH session SQLite files, plugin imports, and other app metadata stay outside that mount. Startup scans the project tree for symlinks, and a pinned iSH source patch rejects creating symlinks beneath a host bind mount; these guards still need Simulator acceptance. Introduce a host-owned project resolver and stable project IDs before exposing multiple project roots. Use iSH `fs_context` only as opaque routing metadata. Denied paths must fail closed rather than fall through to a global bind mount. Test `..`, symlink, hard-link, descriptor, and cross-project escapes before adding multi-project routing.

Host workspace writes and edits use atomic replacement and a revision/CAS check. Shell writes keep normal Linux semantics. Both paths emit file-change events for UI refresh and persistence.

**Gate:** the same file written from DSH tool, bot shell, Web terminal, and native UI is visible to each; two projects cannot read or modify each other's files; restart preserves both projects and fakefs metadata.

### 5. Offline rootfs and on-demand tools — minimal Alpine base is bundled by opt-in build; installer/UI pending

Keep the CI-generated Alpine fakefs as the immutable base candidate. The opt-in app build embeds it and `ISHRootfsStore` installs it; there is no package selector yet. Start with the base BusyBox tools and show install suggestions for missing commands. Optional packages such as `bash`, `jq`, `ripgrep`, and `git` must be user-selected or explicitly requested. A host-side installer should fetch APKs, verify Alpine signatures and hashes, resolve dependency closure, then commit the package transaction into fakefs. Guest network remains disabled by default. Never automatically rerun a command after a failed package install because it may have partially executed.

Keep the model API online requirement separate from local guest/tool availability. The shell, rootfs, and previously installed tools continue to work offline.

### 6. Performance and release promotion

Use one shared `MemoryGovernor` for Node, WebAssembly, and iSH. Current iSH limits are four PTYs and a fixed 256 MiB anonymous-page cap; they are not coordinated with `MemoryGovernor` and are not device-tuned. Start with eight Linux processes per task tree and 32 global Linux processes after process execution exists. Keep AOT off until the image ABI and engine build ID match exactly; the current archive is a placeholder. Initially evaluate musl, BusyBox, and zlib with a 30 MiB uncompressed budget. Measure actual app bundle growth, AOT hit rate, boot latency, command latency, memory peak, and process/thread/FD cleanup.

Targets for the first device baseline: engine ready p95 ≤3 s after rootfs install; warm `/bin/true` p95 ≤200 ms; PTY echo p95 ≤100 ms; selected AOT suite ≥15% overall improvement. These are targets, not measured results.

Only switch the release gate from QEMU to iSH after device and Simulator integration pass, exact IPA component sizes and SBOM are emitted, the source/license bundle is attached, and 4 GB-class iPhone memory testing is complete. Keep the previous release path available until an iSH candidate passes those gates.
