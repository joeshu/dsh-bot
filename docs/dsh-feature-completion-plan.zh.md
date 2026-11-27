# DSH iOS 功能补齐清单

参考目标：`Fei2411/DS-Bot`、DSH 原版 Web 和 DSH `0.2.2-rc.5` Host 契约。该清单区分已接通的能力、仅适合前台运行的能力，以及需要真正 iOS 执行后端的桌面功能。

## 已落地

| 能力 | 实现 | 状态 |
| --- | --- | --- |
| Web / Bot 模式选择 | 官方 Agent Preset Registry；`standard`、`cordis`、`ptc-python`、`minimal` 四个注册项由 Web 和原生 Bot 共用 | 完成。原生 Bot 在新会话开始前选择，已产生历史的会话固定模式；PTC 模式仅在工具启用时运行。 |
| 文件开发工具 | DSH FS 工具接 iOS 沙盒文件服务；根目录固定为 `$DSH_HOME/files` | `read`、`write`、`edit`、`apply_patch` 在原生 Bot 和 Web 可用；写操作通过对应审批界面。 |
| 文件发现 | iOS 原生 `glob` / `grep` 适配，不启动 ripgrep 子进程 | 有目录、文件大小、访问量、结果数及正则复杂度限制。 |
| 提问、计划、待办、Skills、Web | 使用 DSH 原生工具与 Web UI；原生 Bot 通过 Swift IPC 处理提问和审批 | 完成。 |
| 创造模式运行时查询 | DSH Cordis Inspect Provider 与 Web `ui-cordis` | 只读查询 Host / Client API、schema、插件和工具声明，不能执行任意 Cordis 方法。 |
| Bot 历史工具卡 | 从 DSH 持久事件 `tool/call` / `tool/result` 与 PTC `tool/ptc-dispatch` 恢复，按会话时间和序号与消息合并显示；点按可按调用序号分段读取输入与结果 | 完成。含 PTC 嵌套工具记录；卡片预览有界；完整详情按不超过 64 KiB 的 UTF-8 字节页读取，用户继续加载时再取下一页；没有配对结果的调用标注“结果未知”。 |
| Bot 审批与文件操作历史 | 从 `approval/asked` / `approval/decided` 配对恢复审批结果；从文件工具参数中提取路径摘要 | 完成。审批卡只显示工具名、结果和时间，不重复展示敏感 reason；`write`、`edit`、`apply_patch`、`patch` 与 `delete` 工具卡显示最多 3 个目标路径；历史分页在前后 100 个事件内配对审批记录。 |
| 私密会话 Web API 隔离 | `ios-private-session-access` 注册 DSH Remote Access policy；Swift 启动时传入私密 Bot ID，创建/删除时同步；按 `parentSession` 将私密根的子会话一并封锁 | DSH Remote 与导出/附件路由已有隔离；`dsh-purge-safe` 的独立 `/redteam/api` 也按私密根/后代过滤 team board、agent 状态，并拒绝引用私密 Session 的请求。Web 解锁状态不授权读取私密区。 |
| Schedule 前台服务 | 官方 `dsh-schedule` 使用既有 SQLite storage-domain；`ios-schedule-tools` 在标准/创造 Bot Agent scope 注册任务工具，Bot 会话内提供原生任务页 | 已接通 `schedule_create/list/view/history/edit`，任务目标固定为当前 Bot；原生页可查看、编辑标题/提示/规则、暂停、恢复、删除和分页查看投递回执。工具与 UI 都只对任务的 involved Session 开放，并隐藏其他 Session 的目标 ID；私密 Session 任务对其他 Bot 隐藏。投递回执只代表写入会话收件箱，不代表模型处理完成。iOS 挂起或终止 Host 时不保证投递。 |
| Web 插件目录 | 保留 DSH 官方 inventory/settings 页面 | 只读；Remote Access policy 不授予 `pluginManager/*`、`plugins/*`，也不授予未来可能挂载的 `schedule/*`。原生「探索 → 插件」仍是安装、启停、卸载的管理入口。 |
| 会话首页与历史 | 首页从 SQLite 会话摘要取最近活动时间和有界消息预览；历史正文按需分页，Bot 历史搜索使用 DSH session-query 索引并按公开 Bot ID 限定 | 首页按最近活动排序，不为排序加载完整历史；从旧数据库首次启动时一次性回填摘要。私密会话不向原生公开搜索结果摘要。 |
| 可移植 Web 会话功能 | SQLite 会话查询、Markdown/ZIP 导出、消息反馈、会话反馈 | 已接通。导出精确路由单独校验公开 Session；未知或私密 Session 返回 404。 |

## 会话开发工具

原生 Bot 的标准/创造模式已可使用以下工具：

- **源码工作区**：`read`、`write`、`edit`、`apply_patch`、`glob`、`grep`，范围在 App 文件区 `files/`。
- **本机计算**：`js_eval` 在 QuickJS 中计算或转换 JSON；每次新建上下文，最多 2 秒、16 MiB，不开放文件、网络、系统进程或异步 Host binding。
- **开发上下文**：`cordis_inspect_list`、`cordis_inspect_query` 读取 DSH API、配置 schema、工具和插件信息；`skill` 加载技能；`ask_user_question`、`exit_plan_mode`、`todo_write` 支持协作流程。
- **本机 Python 会话执行**：`python_exec` 使用随 IPA 离线打包的 Pyodide 0.29.5（Python 3.13.2）和 NumPy 2.2.5。每次在新 Worker/新解释器中运行，完整代码经 iOS 审批；45 秒、256 MiB WebAssembly 内存、16,000 字符代码和 32,000 字符输出上限。Worker 不提供应用文件、网络、进程或 MCP 绑定。外部开发服务仍通过 `remote_mcp_list` / `remote_mcp_call` 独立调用。
- **PTC / `run_code`**：新增「PTC 开发模式」，复用 DSH 官方 `dsh-tool-executor-ptc` 和 `ctx.ptcRuntime` 契约；后端以离线 Pyodide Python/NumPy 在独立 Worker 中执行 `function-body`，使用父端结构化 JSON 消息桥调用 Agent 当前可见的工具，并提供官方 Python SDK 所需的 `asyncio`、`ToolCallError` 和 `tools[...]` 访问形式。完整源码先走 DSH/iOS 审批；嵌套工具继续经过官方 guarded pipeline 与各自权限。每次运行 120 秒、256 MiB WebAssembly、16,000 字符源码、32,000 字符输出、最多 60 次嵌套调用、最多 256 KiB 总桥接数据；一次性解释器，取消或退出 preset 会终止并等待 Worker。Python 侧的 JS globals 只含冻结的窄桥，回调和 Promise 原型不可用于遍历 Node Worker 全局；PTC 的 `tool/ptc-dispatch` 子调用输入/结果支持实时卡片和历史分页/详情。它不直接访问 App 文件、网络或进程，也不提供 sandbox escalation；文件能力只能通过已声明且获准的 DSH 工具。
- **前台 Schedule**：`schedule_create`、`schedule_list`、`schedule_view`、`schedule_history`、`schedule_edit` 只挂在原生标准/创造 Bot 的 Agent scope；任务目标固定为当前 Bot，按 `involvedSessionIds` 限定读写，私密任务不会出现在其他 Bot 的列表。创建、编辑、暂停、恢复和删除只按用户明确要求执行。原生任务页支持编辑标题/提醒内容/RRULE，并分页展示 DSH 保存的投递回执。任务持久化在 DSH SQLite storage-domain；Host 前台运行时按 recurrence 投递，重启后使用官方 catch-up。iOS 挂起或终止时不保证准点执行。轻量模式与 Web preset 不挂这些工具。
- **网络资料**：`web_search`、`web_fetch` 按当前设置和审批策略查询资料。

当前命令台是受限的 JavaScript 命令解释器，可执行少量工作区命令及离线 Python/Node 调用；它不是 POSIX shell、Linux 用户空间或 PTY，不能运行任意 ELF 程序。Bot 生成的每条 `terminal_exec` 命令显示完整内容并逐条等待用户批准，即使 Bot 处于 `autoReview` 也不跳过；只读模式禁用 Bot 终端工具。原生 UI 用户手动输入仍视作直接用户操作。Python/NumPy 独立工具和 DSH PTC `run_code` 共用进程级单 Worker 槽，独立工具执行 45 秒，PTC 执行最多 120 秒。取消/挂起/运行时关闭会终止 Worker。工作区读写由独立的沙箱工具承担，Python 本身不直接访问 App 文件和网络。

## dsh-purge-safe iOS 适配与权限

对照源码目标 `joeshu/dsh-purge-safe`。上游当前声明 `dshTarget: 0.2.2-rc.3`，本机 DSH 是 `0.2.2-rc.5`，所以按 iOS 宿主契约选择性适配，不把桌面补丁能力当成已兼容。

| 层级 | iOS 行为 | 权限边界 |
| --- | --- | --- |
| RedTeam SQLite/store、工具、技能 | 保留插件的 `dsh-purge-safe/redteam`、store、技能目录；工具模块由 iOS 宿主按全局开关动态挂载 | 每个 Bot 的授权独立保存，旧 Bot/新 Bot 默认关闭；私密 Bot 在 Swift 与 Node 两侧都不能调用。 |
| Bot 工具 | 标准/创造模式在授权后可读演练台、资产与报告；数据库写入、敏感记录另有独立开关 | “工具”开关授予基础查询；“写入演练台”只授予审核过的写工具；“敏感资料”授予凭据、入口、WebShell、隧道、PoC、攻击文件、探测和清理工具。未列入 iOS 白名单的新工具默认拒绝。 |
| DSH 审批 | `ask` 对写入和敏感工具逐次请求 iOS 审批；`autoReview` 对敏感工具逐次审批；`readOnly` 禁止所有插件写入 | DSH `tools.guard` 在 waterfall 之后再检查授权，并核对审批是否确实通过；插件即使尝试把 ask/deny 改成 allow，也不能越过 guard。 |
| Web 演练台 | 保留 RedTeam Dock、SQLite 管理和技能/报告界面；全局宿主开关之外，另有 Web 普通读取、写入、敏感资料/主动探测三个持久化开关 | Web 的直接操作使用独立 Web 授权，不借用 Bot 授权。敏感写入要求同时打开 Web 写入和敏感资料；未知 API 操作默认拒绝，桌面代理连接与插件自更新接口在 iOS 明确不支持。路由过滤私密根及后代会话，拒绝请求引用私密会话，并过滤全量 sessionBindings 响应中的私密 ID。 |
| `dsh-purge-safe` 根层 | iOS 最终 `runProfile` overlay 固定 `enabled:false`、`toolGateBypass:false`、`subagentControl:false`，自动应用/更新/回退也关闭；保留 sibling RedTeam/store/UI 层 | 不能修改只读 App Bundle；不得关闭 DSH 原生工具审批或子代理授权。 |

安装时，iOS Plugin Manager 会给 `lib/redteam/ui.js` 加宿主适配：Web API 总开关、逐类授权、私密会话闭包过滤、私密 session 参数拒绝及私密绑定结果过滤。若上游改动导致适配锚点不匹配，会拒绝该版本安装；已有旧插件在启动时适配，失败则关闭 RedTeam Web UI 并显示诊断。UI 源文件会在用户 profile 的插件副本内改写，不改源码仓库，也不改 App Bundle。

iOS 没有 shell、PTY、桌面进程或可写 App 安装目录。因此 `/purge apply/revert/uninstall`、对 DSH 程序包打补丁、终端驱动的主动攻击链不能完整移植；插件 `redteam` preset 中依赖 shell/jobs 的部分也不能作为 iOS 本机执行能力。可用能力限于经授权的演练台工具、存储和 Web UI；网络探测、敏感入口和 PoC 工具需要单独敏感授权，并在 `ask` / `autoReview` 下逐次确认。

## PTC、Jobs、Schedule 与插件写入：上游契约和 iOS 方案

| 能力 | DSH 上游实现 | iOS 现状与落地方案 |
| --- | --- | --- |
| PTC / `run_code` | `dsh-ptc-runtime` 是 `ctx.ptcRuntime` 执行后端 seam；官方 executor 生成 Python SDK、限制子调用、用 guarded pipeline 调度 nested tools，并持久写 `tool/ptc-dispatch`。官方 Node provider 在受管 Node 子进程运行 TypeScript；发布版没有适用于 iOS 的受限 Python provider。 | 已挂官方 `dsh-tool-executor-ptc`，新增 `ptc-python` preset 和 Pyodide `PtcRuntime` provider。每次完整源码经审批，异步 binding 以结构化 JSON 穿过 Worker 边界，工具调用使用 DSH 官方权限流水线。Python 看到的 JS globals 只有冻结的宿主调用桥；桥函数和 Promise 包装没有可遍历的 Function/Node 原型链。无直接宿主文件策略，拒绝 sandboxPolicy；不支持有状态 Python。Web/Bot 可选择同一 preset，若审批 answerer 不可用则 fail-closed。 |
| 后台 Jobs | `dsh-jobs` 是注册表契约；`dsh-jobs-local` 保存进程内任务与有界输出，`dsh-tool-jobs` 提供 `job_list`、`job_output`、`job_kill`、owner 隔离和完成通知。生产方通过 `JobSpec.run()` 注册任务；官方 desktop 常见 shell/bun 生产方不适用于 iOS。 | 已挂官方 Jobs registry/control 插件。标准/创造模式只注册 `python_job_start`：完整 Python 源码逐次审批，独立离线 Python/NumPy Worker，最多 120 秒、每 Bot 并发 1、全 App 同时最多运行 1 个 Python Worker、输出 128 KiB；无 App 文件、网络、进程、MCP 或 DSH 工具权限。Bot 菜单提供 owner-scoped 任务列表、输出读取与取消。私密 Bot 不启用，转为私密时终止该会话任务。DSH 注册和完成事件进入会话日志，但 registry 与输出 ring 是进程内状态，Host 退出或 Bot 被释放时取消；原生 Bot 将 Jobs 完成通知留在收件箱并由下一次用户输入带入，避免未关联原生流式 turn 的后台模型请求；嵌入 Web 保留 DSH 默认唤醒行为。App 切后台时保留有 Jobs 记录的 owner，并把原生 DSH followup 转为不唤醒的收件箱注入；iOS 仍可挂起或终止 Host，故执行仅为尽力而为且不跨重启恢复。 |
| Schedule / 定时 Agent 指令 | `dsh-schedule` 将任务保存到 storage domain（可用 SQLite），运行时以 `setTimeout` 驱动；Host 必须运行才能投递，重启后重复任务只投递最近一次错过的发生。官方 `dsh-tool-schedule` 会列出 Host 全部任务，并可按 ID 编辑任意任务。 | 已挂官方持久服务并提供 iOS 专用 Bot 工具适配层，不使用全 Host 的官方工具。自定义工具按任务 involved Session 限权，轻量模式与 Web preset 不挂载；Web Remote API 和自动化页仍封锁，因为 Remote Schedule 没有 task-level resource。只承诺 Host 前台运行及恢复后的官方 catch-up，不承诺 iOS 后台准点执行。 |
| Web 插件写管理 | 官方 `dsh-plugin-manager` 写 profile/lockfile，调用 pnpm 并运行依赖安装脚本；受 Host 平台能力和包管理器约束。 | Web 的插件 inventory 保持只读。将来若做 Web 管理，只能把请求送到 Swift 宿主管理器，复用原生包校验、受保护插件规则、profile 原子改写、运行时重启/回滚及逐项审批；禁止 Web 直接写 profile 或启用桌面 pnpm 管理器。 |
| 终端 / PTY | 独立 shell 进程、PTY 生命周期、工作目录、交互输入输出及取消 | 当前仅有受限虚拟解释器。ARM64 Linux 目标采用 iOS TCI QEMU（不依赖 JIT/HVF），headless 串口终端加 guest PTY agent；Bot 与 Web 共用带 owner/session 认证的流。每条模型命令必须逐次审批；命令文本不能用于静态推断只读。iOS 挂起后记录 guest 状态，恢复时重连，App 终止后恢复磁盘并重建 PTY 会话。 |

### 私密会话隔离实现依据

DSH `dsh-api-remote-access` 只约束 Typert Gateway Remote API。它能在 `session/list`、`session/search` 等返回结果中逐项用 `allows()` 过滤，也能在指定 Session 资源上限制调用；而 `dsh-client-connection` 的认证浏览器 Peer 默认是 `{ kind: 'owner' }`，owner 绕过 Remote Access policy。另有精确 Fetch 路由 `/api/session.export`、`/api/session.markdown` 和 `/api/session/uploadFileBinary`，这些路由不经过 Typert policy。附件 Remote 虽然携带 Session 资源，但上游读取实现不验证附件引用是否属于该 Session。

因此 iOS Host 把浏览器 Peer 作为 `ios-web` 非 owner principal，为公开 Session 建立授权；Session header 的 `parentSession` 链将私密 Bot 根及后代排除。Remote Access policy 从 Typert descriptor 动态取 action，公开 session 查询由 DSH 自身的逐项过滤机制运行；插件管理和全局 Schedule 管理命名空间不授予。上游 `dsh-tool-schedule` 会列出全 Host 任务，并允许按 ID 编辑任务；光有 Session Remote policy 无法保证私密任务不泄露，因此官方全局工具和 Web 自动化页保持关闭。原生 Bot 使用单独的 Agent-scope 工具，按 `involvedSessionIds` 把任务限定到当前会话，并在非私密 Bot 中过滤涉及私密 Session 的记录。三个精确 Session Fetch 路由在进入官方 handler 前都要求 session index 已加载、目标存在且公开，再通过请求局部 AsyncLocalStorage 给该次请求临时 owner 身份；重复 `sessionId` 参数会拒绝，ZIP 的重复 `includeDescendants` 也拒绝，且导出会检查子树内是否包含私密 Session。附件权限按 `sessionId → attachmentId` 归属表校验，避免公开 Session 的权限扩展到私密或其他 Session 的附件。索引载入失败时按 fail-closed 处理导出、上传和 session-scoped Remote。

私密 Bot 在原生 UI 解锁时仍不向 Web 授权。Face ID 状态不进入 Web principal，也不在 Web 解锁时延长；这是因为 DSH Web 目前没有可验证的 iOS 生物认证挑战/令牌协议。

### 后续优先级

1. **P0 复核运行时隔离**：在 iOS 构建和运行环境核对连接器认证、私密根/子会话、并发新建 Session、导出、附件和 `/redteam/api` 边界；对策略失效、索引错误和路由被拒留可见诊断。
2. **P1 历史轨迹体验**：审批事件与文件操作路径摘要已接入 Bot 时间线；会话搜索复用 DSH 索引且可从结果打开原生会话上下文；完整工具输入与输出已改为 UTF-8 分页读取，详情页按需加载。
3. **P1 PTC 执行后端**：已完成 `ptc-python` preset、官方 `run_code` transport、Pyodide `PtcRuntime` provider、父端 binding bridge、完整源码审批、Worker 取消/退出清理、子调用调用上限和 PTC 工具历史卡。当前 provider 只支持无状态 Python function-body；没有直接文件 sandbox / escalation。远端开发服务继续通过通用 MCP 工具单独使用。
4. **P1 Schedule 后台体验**：原生 Bot 前台 Schedule、规则编辑、投递回执和任务级隔离已接通。剩余是可取消且有截止时间的 best-effort `BGTask` 唤醒/通知设计，以及更明确的漏投与恢复诊断。上游 Schedule 是 Host-wide 单计时器；在后台唤醒前还要让它跳过已锁定的私密 Session，避免设备锁定时自动执行私密任务。BGTask 仍不能承诺准点。
5. **P2 Jobs 持久执行**：基础 DSH Jobs 已接入并提供离线 Python 生产方、原生管理页与完整 owner 隔离。若产品需要 Host 重启后恢复或系统挂起时持续运行，需要另行实现 Swift 持久 task broker 与 iOS BackgroundTasks/通知适配，并保留目前无 shell 的生产方边界；iOS 系统调度不承诺准点。
6. **P2 Web 插件写管理**：Web 页面保持只读，直到原生宿主授权/审查/回滚接口闭环。
7. **P1 ARM64 Linux 终端**：已落地可复现的 Alpine ARM64 serial-shell bootstrap 镜像构建，内核与根文件系统按 SHA-256 固定；该产物目前只作为独立 CI artifact。Bot 命令现已要求逐条人工审批，避免 `autoReview` 绕过命令审查。仓库现新增独立手动 **ARM64 iOS TCI Runtime** 构建门：固定 UTM/QEMU 版本，只编译 `aarch64-softmmu`，强制关闭 HVF、图形、USB redirection 与 9P，对源码归档做 SHA-256 校验，并打包 strip 后 Frameworks、源码、patch、许可证和动态依赖报告。首轮 macOS CI 已成功编译 QEMU，但打包审计脚本误把源码目录当成 Meson 构建目录，导致未上传产物、也没有实测体积；现已按真实目录布局修正审计器，并补上 `proxy-libintl` 源码修订和 LGPL 许可证校验，待复跑确认。随后依序完成：启动/串口 guest 验收；构建将 virtio-blk/ext4 等所需驱动内置的 guest kernel（当前 Alpine virt kernel 配置把这些驱动编为模块，而 bootstrap 没有模块目录）；建立原子写入且有空间配额的持久 guest 磁盘；以 guest PTY agent 提供真实 PTY、输出回压、取消和 app 恢复语义；通过受认证的宿主文件代理映射 `files/`（当前 QEMU 的 9P/virtfs 在 iOS host 构建中不可用，不能直接假设桌面共享方案可移植）；给 Bot、Web 和原生 UI 提供同一受 owner/session 限制的实时流；实现签名 APK 的主机侧按需下载与 guest 离线安装、工具选择目录和卸载回滚；最后才纳入 IPA 并做物理设备验收。

### ARM64 终端体积与工具策略估算

- **已测引导产物**：kernel、配置与 rootfs 合计 14,605,280 bytes（13.93 MiB），独立于 IPA。它没有 QEMU，也不是可持久安装工具的系统盘。
- **规划预算**：只保留一个 aarch64 TCI 目标、serial/PTY 和最小 GLib/pixman/ucontext 运行依赖，预计给 IPA 增加约 **35–80 MiB**（含 14 MiB guest payload；构建前估值，必须以首个审计通过的精简 iOS framework 构建的 strip 后大小和 IPA 差值替换）。QEMU 本体已编译，但首轮构建没有通过产物审计，暂时仍无实测 QEMU 体积。对照：UTM SE v5.0.9 的公开 IPA 为 237,418,770 bytes，包含通用虚拟机 UI、多架构及图形相关功能，只作宽配置参考，不能视为本项目大小。
- **设备数据空间**：guest 系统盘默认规划 256 MiB，按需扩至 2 GiB；这部分在 App Documents 中增长，不计入 IPA。工具本身下载至签名 APK 缓存后离线安装，安装占用由目录按 APK 下载大小和包内 `Installed-size` 展示。工具组合和构建器依赖可使占用从数 MiB 增至数百 MiB，因此不预装完整开发套件。
- **首批工具目录**：基础 BusyBox/APK；Shell（Bash、coreutils、findutils、grep、sed）；文件/JSON（jq、tree）；网络诊断（curl、wget、bind-tools，默认 guest 网络仍关闭）；Git/SSH；Python；编译器与 `make`。选择工具前显示依赖闭包、下载总量、磁盘增量、版本和签名状态；“需要时安装”与手动勾选共用同一 package plan。没有用户选择时不下载可选工具。
- **估算不确定项**：精简 QEMU 的真实 IPA 增量、iOS 上 TCI 吞吐/内存，以及 Alpine 内核模块体积都尚未实测。CI 的下一道门应先报告 QEMU framework 的架构、动态依赖、strip 后字节数和许可清单；达不到启动/内存/尺寸目标时不要把后端塞入正式 IPA。

## 代码位置

- DSH Profile、模式和只读插件目录：`kernel/runtime/ios-profile-package/cordis.patch.yml`
- DSH 启动、事件转换和历史工具活动：`kernel/runtime/dsh-ios-entry.mjs`
- dsh-purge-safe iOS overlay、Bot 工具权限、逐次审批与 Web 私密 Session 适配：`kernel/runtime/dsh-ios-entry.mjs`、`kernel/runtime/ios-plugin-manager.mjs`、`ios/Sources/Runtime/LocalAgentHost.swift`、`ios/Sources/UI/PluginManagerView.swift`、`ios/Sources/UI/StandaloneViews.swift`
- 前台 Schedule 服务、Bot Session 级工具、历史 IPC 与原生管理 UI：`kernel/runtime/ios-profile-package/cordis.patch.yml`、`kernel/runtime/ios-host-package/ios-schedule-tools.mjs`、`kernel/runtime/dsh-ios-entry.mjs`、`ios/Sources/UI/ScheduleManagerView.swift`
- 私密 Session Remote policy、精确导出和附件归属校验：`kernel/runtime/ios-host-package/private-session-access.mjs`
- 私密 Bot ID 启动参数、历史恢复和实时工具卡状态：`ios/Sources/Runtime/NodeRuntimeTransport.swift`、`ios/Sources/Runtime/LocalAgentHost.swift`
- DSH Jobs 本地注册表、离线 Python 生产方、owner-scoped IPC 与原生查看/取消页面：`kernel/runtime/ios-profile-package/cordis.patch.yml`、`kernel/runtime/ios-host-package/ios-python-jobs.mjs`、`kernel/runtime/dsh-ios-entry.mjs`、`ios/Sources/UI/JobsManagerView.swift`
- 对话消息与历史工具卡合并显示：`ios/Sources/UI/StandaloneViews.swift`
- 原生工具（QuickJS、工作区、MCP、Web）：`kernel/runtime/ios-host-package/native-tools.mjs`、`ios/Sources/Runtime/LocalAgentEngine.swift`
- 本机 Python 与 PTC Worker、逐次审批和离线资源：`kernel/runtime/ios-host-package/ios-python-tool.mjs`、`python-execution.mjs`、`python-worker.mjs`、`ios-ptc-runtime.mjs`、`ios-ptc-python-worker.mjs`、`ios-ptc-executor.mjs`、`scripts/prepare-python-runtime.py`

## 验收边界

- 私密 Session、其后代、未知 Session 和索引不可用时，不得经 Web Remote、搜索、附件上传/读取或导出接口访问。
- 公开 Session 只能读取自身记录中的附件引用；Web inventory 可读，任何 Web 插件 profile 写入接口都被拒绝。
- Bot 历史中消息和工具卡按持久事件时间/序号排列；未完成调用显示结果未知，卡片预览有界，完整详情按 64 KiB UTF-8 页读取。
- `js_eval` 无文件、网络、进程和异步 Host 权限；`python_exec` 与 PTC `run_code` 使用离线 Pyodide/NumPy 新解释器，每次完整代码逐次批准，并受运行时间、WASM 内存、输出和桥接数据上限约束；PTC 的 Python JS global 仅有冻结且去掉可遍历原型链的窄宿主调用桥，Python 不能直接访问 app 文件、网络、进程或 MCP。
- dsh-purge-safe Bot 工具默认无权限；写入、敏感数据和 Web API 都受各自开关/审批约束；私密会话不显示在插件 Web 面板，且不能调用插件工具。
- Schedule 仅在 Host 可运行时投递，重启后按官方 catch-up；iOS 挂起/终止期间不承诺准点。Jobs 的取消、会话所有权、并发、输出上限和进程退出语义由运行时契约固定；Job 状态和输出不跨 Host 重启恢复。
