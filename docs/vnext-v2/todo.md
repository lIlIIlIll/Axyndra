# Axyndra Next：Durable Composition Runtime

以下方案基于当前 Axyndra `main@9bd9f71c`、Pi `main@a470b121` 的新 `AgentHarness` 设计，以及 DeepSeek Harness `master@b150a551` 的 Cordis/插件架构。它是一份**目标架构与实施蓝图**，不代表当前仓库已经实现。

一句话定义：

> **Axyndra Next 是一个以不可变语义事实为核心、以完整持久化程序计数器驱动恢复、以作用域化组件图组织扩展、以 Capability 和 Operation/Receipt 管理一切副作用的 Agent Runtime。**

它应当融合三者最强的部分：

| 来源               | 吸收的核心设计                                                                       |
| ---------------- | ----------------------------------------------------------------------------- |
| 当前 Axyndra       | Thread/Turn/Item、Attempt/Decision、Operation/Receipt、RunScope、Approval、Sandbox |
| Pi AgentHarness  | Lane、完整 `op.state`、Effect Sandwich、恢复解释器、Hook replay contract                 |
| DeepSeek Harness | Service Seam、Profile、Realm、可逆 EffectScope、按 Agent 组合、Code Mode                |

Pi 的新设计把 Session 建模为不可变 Entry Tree、可变寄存器、Lane 和 Usage Ledger，并通过一个完整 `op.state` 作为 durable program counter；Provider 和 Tool 都采用 intent → uncertain effect → settlement。

DeepSeek Harness 则把服务、事件和注册项放进可卸载的插件作用域，通过 Profile 和 Realm 为不同 Agent 组装不同能力，同时保证注册副作用在卸载时被撤销。

Axyndra 已经拥有更细粒度的 Attempt、Decision、DecisionBlock、Operation、Receipt、Approval 和 Replay Barrier，也有能够把未收敛异步工作升级为 `RecoveryRequired` 的 RunScope，因此不应退化成通用事件日志或任意插件内核。

---

# 一、最高层架构决策

Axyndra Next 分为四个平面。

```text
┌──────────────────────────────────────────────────────────┐
│ Client / Experience Plane                                │
│ TUI · CLI · SDK · ACP · RPC · Web · Eval · Inspector     │
└───────────────────────────┬──────────────────────────────┘
                            │ typed App Protocol
┌───────────────────────────▼──────────────────────────────┐
│ Control / Composition Plane                              │
│ Profiles · Realms · Service Registry · EffectScope       │
│ Extension Runtime · Component Graph · Configuration      │
└───────────────────────────┬──────────────────────────────┘
                            │ resolved composition snapshot
┌───────────────────────────▼──────────────────────────────┐
│ Durable Semantic Kernel                                  │
│ Thread · Item Tree · Lane · Turn · Run · Step             │
│ Attempt · Decision · Operation · Receipt · Approval       │
│ RunContinuation · WorkDebt · Transaction Coordinator     │
└───────────────────────────┬──────────────────────────────┘
                            │ capability-governed effects
┌───────────────────────────▼──────────────────────────────┐
│ Execution Fabric                                         │
│ Model Providers · Tools · Sandbox · Process · FS · MCP    │
│ WASM · Remote Worker · Terminal · LSP · DAP · Verifier    │
└──────────────────────────────────────────────────────────┘
```

## 不可替换的内核

以下部分不能由插件替换：

```text
Identity 生成与归属
Thread/Lane revision ownership
合法 Run 状态转换
RunContinuation 解释器
Model terminal evidence 验证
Decision canonical commit
Operation intent 与 settlement
Approval ceiling
Receipt 唯一性
RecoveryRequired 判定
事务原子性
```

## 可插拔的能力

以下部分可以通过 Service Seam 和 Profile 组合：

```text
Model Provider
Context Compiler 策略
Prompt Contributor
Tool Provider
Skill Provider
Compaction 策略
Verifier
Filesystem / Process / Terminal 后端
Sandbox 后端
Storage 后端
Telemetry / Eval Sink
UI Renderer
MCP / WASM / Process Extension
```

原则是：

> **能力可替换，语义不变量不可替换。**

---

# 二、12 条核心不变量

## 1. 语义事实不可变

一旦提交的 Item、Decision、Receipt、ApprovalDecision、UsageRecord 不允许原地修改。修正通过新事实或明确的行政 rewrite 完成。

## 2. Provider 流不是事实

Streaming delta 只能形成草稿和实时事件。只有完整 terminal evidence、结构验证和策略验证都通过的 Decision，才能形成 canonical Item。

## 3. 所有外部效果必须有 Intent

任何 Provider 请求、Tool、远程作业、插件 Hook 副作用之前，都必须先提交准确的执行意图、参数和预留结果 ID。

## 4. 恢复不靠猜测

恢复只读取完整 `RunContinuation`，根据 phase 分派处理器；禁止通过“哪个表缺了某条记录”推断当前执行位置。

## 5. 一个 Lane 同时最多一个 Run

Thread 内可以有多个 Lane 并行运行，但单个 Lane 内保持顺序执行。

## 6. Run 只有在 WorkDebt 收敛后才能结束

未结算模型请求、工具、审批、外部等待、子 Run、后台任务或 deferred context 任一存在，Run 都不能发布 `Completed`。

## 7. 服务存在不代表拥有权限

能够解析 `FileSystemService`、`NetworkService` 或 `ProcessService`，不等于当前 Run 获得了对应 Capability。

## 8. 插件贡献必须有 Owner 和 Scope

每个 Tool、Hook、Service、后台任务、进程、定时器和资源必须归属于一个 EffectScope，并能够撤销或进入 Quarantine。

## 9. 模型可见内容必须可重建

每个模型请求都必须能回答：哪些 Item、Fact、Skill、Prompt Contribution 和 Tool Schema 构成了本次请求。

## 10. 不安全副作用绝不自动重放

无法确认是否已执行的 `NeverReplay`、`AtMostOnce` 操作不得因本地缺少 Receipt 而重新执行。

## 11. Projection 不是 Authority

UI Snapshot、搜索索引、统计、摘要缓存、TUI 状态均可重建，不能反向决定语义事实。

## 12. 终态之后禁止晚到语义事件

Run terminal、Operation terminal 或 Item committed 之后，相关 late delta、progress 和 draft 必须被拒绝或标为 stale。当前 AppMailbox 已经有相近的 sealing 与 coalescing 语义，应继续保留。

---

# 三、完整领域模型

## 1. Thread

Thread 是共享的持久化语义空间，包含：

```text
Item Tree
Lanes
Thread-scoped facts
Artifacts
Usage/Audit ledgers
```

Thread 不再等于一个线性 `messages[]`。

## 2. Item

Item 是不可变、单父节点的语义条目：

```cangjie
class Item {
    let id: ItemId
    let threadId: ThreadId
    let parentItemId: ?ItemId
    let turnId: ?TurnId
    let laneId: LaneId
    let globalSequence: Int64
    let kind: ItemKind
    let payload: AgentValue
    let provenance: Provenance
    let createdCommitSequence: Int64
}
```

建议使用**单父树 + 独立引用边**，而不是直接引入任意 DAG：

```text
parentItemId
    定义会话分支

item_references
    表达摘要来源、Artifact 来源、跨分支引用和合并证据
```

这样 Context 路径仍然确定，同时支持跨分支证据。

## 3. Lane

Lane 是指向 Item Tree 某个叶子的具名执行游标：

```cangjie
class LaneState {
    let laneId: LaneId
    let threadId: ThreadId
    let leafItemId: ?ItemId
    let activeRunId: ?RunId
    let revision: Int64
    let fenceToken: Int64
    let modelLaneSnapshotId: SnapshotId
    let profileSnapshotId: SnapshotId
}
```

每个 Thread 默认有：

```text
main
```

其他 Lane 可用于：

```text
并行研究
共享历史 Child Run
Slack/聊天线程
Reviewer
Planner
Agent Team 成员
后台任务
```

## 4. Turn

Turn 是一次外部意图的语义封闭区间：

```text
用户输入被接受
→ 零个或多个 Step
→ 不再欠下工作
→ Turn 关闭
```

即使输入被 pre-step policy 拒绝，也应形成一个零 Step Turn，留下明确事实。

## 5. Run

Run 是执行一个 Turn 的持久化解释器实例。

```text
崩溃后恢复
    使用同一个 RunId

终态失败后重新尝试整个 Turn
    创建新 Run，parentRunId 指向旧 Run
```

## 6. Step

Step 是：

```text
一次模型请求
+ 该 Decision 产生的一批工具调用
```

一个 Turn 可以包含多个 Step。

```cangjie
class StepRecord {
    let id: StepId
    let runId: RunId
    let ordinal: Int64
    let semanticRequestId: SemanticRequestId
    let decisionId: ?DecisionId
    let state: StepState
}
```

## 7. ModelAttempt

保留当前 Axyndra 的 Attempt 模型，并进一步冻结：

```text
ContextManifestId
CompositionSnapshotId
ModelCapabilitySnapshotId
ResolvedModelRequestPolicy
Provider adapter fingerprint
Wire request digest
Reserved DecisionId
Reserved UsageId
```

Retry 是同一个 `semanticRequestId` 下的新 Attempt，不修改原始请求意图。

## 8. ModelDecision

Decision 保持以下约束：

```text
一个 Attempt 最多一个 Decision
Decision 必须通过 terminal validation
DecisionBlock 必须完整
canonical projection 必须原子覆盖全部 block
```

## 9. Operation

Axyndra 中的 Operation 继续表示一个实际或潜在副作用，而不是 Pi 所说的整个 Run。

建议把当前可变 Operation 拆成：

```text
OperationRecord      不可变执行意图
OperationState       可变当前状态
OperationReceipt     不可变结算事实
```

## 10. Receipt

Receipt 必须记录：

```text
执行结果
是否确认产生副作用
外部句柄
输出与 Artifact
验证证据
错误分类
重放证据
开始/结束时间
实现 fingerprint
```

## 11. ContextManifest

每个模型请求拥有一个精确的 ContextManifest：

```cangjie
class ModelContextManifest {
    let id: ContextManifestId
    let laneId: LaneId
    let leafItemId: ?ItemId
    let sourceItemIds: Array<ItemId>
    let checkpointId: ?CheckpointId
    let factVersions: Array<FactVersionRef>
    let activeSkills: Array<SkillSnapshotRef>
    let promptContributions: Array<ContentArtifactRef>
    let toolCatalogSnapshotId: SnapshotId
    let transformations: Array<ContextTransformation>
    let tokenBreakdown: ContextTokenBreakdown
    let renderedInputArtifact: ContentHash
    let compilerVersion: UInt32
    let digest: String
}
```

## 12. CompositionSnapshot

每个 Run 冻结完整组件组合：

```cangjie
class ResolvedAgentCompositionSnapshot {
    let id: CompositionSnapshotId
    let profileId: String
    let profileVersion: String
    let componentInstances: Array<ComponentInstanceRef>
    let serviceBindings: Array<ResolvedServiceBinding>
    let capabilityCeiling: CapabilitySet
    let toolVisibilityDigest: String
    let promptGraphDigest: String
    let resolverVersion: UInt32
    let digest: String
}
```

配置或插件更新只影响新 Run；旧 Run Resume 使用原 Snapshot。

---

# 四、三层持久化模型

Pi 的 “entries / registers / usage ledger” 边界很清晰，但 Axyndra 不应退化为通用 KV。应保留正规化表，同时明确三种语义层。

## 第一层：Immutable Semantic Facts

```text
items
item_references
turn_records
run_records
run_outcomes
step_records

model_context_manifests
model_attempts
model_decisions
model_decision_blocks
canonical_decision_items

operation_records
operation_receipts
approval_decisions

composition_snapshots
artifacts
checkpoints
```

## 第二层：Mutable Registers

```text
thread_state
lane_state
run_continuations
operation_states
inbox_entries
pending_entries
active_grants
component_instance_states
extension_scopes
leases
```

Register 只表示“现在是什么”，不承担审计历史。

## 第三层：Append-only Ledgers

```text
usage_ledger
audit_ledger
telemetry_outbox
memory_events
migration_events
```

## Derived Projections

以下都不是权威：

```text
Branch index
Full-text search
Thread summaries
UI snapshot cache
Statistics
Trajectory materialized view
Token projection cache
```

损坏后必须可以从前三层重建。

---

# 五、统一事务模型

新增唯一写入口：

```cangjie
interface SemanticStore {
    func transact(
        expected: TransactionPreconditions,
        writes: DurableWriteSet
    ): Result<CommitReceipt>
}
```

一个事务可同时包含：

```text
插入 immutable fact
更新或删除 register
追加 ledger row
追加 app outbox event
CAS lane/thread revision
```

每个 commit 获得严格递增的：

```text
commitSequence
```

建议按 Thread 分配序列；跨 Thread 全局审计另用 Store sequence。

所有语义 AppEvent 必须进入事务内 outbox，事务成功后再发布，避免：

```text
数据库已提交
但事件尚未发送时进程崩溃
```

---

# 六、完整 Durable RunContinuation

这是下一代最优先的设计。

```cangjie
class RunContinuationV1 {
    let schemaVersion: UInt32
    let runId: RunId
    let laneId: LaneId
    let turnId: TurnId
    let stepOrdinal: Int64

    let phase: RunExecutionPhase

    let compositionSnapshotId: CompositionSnapshotId
    let modelLaneSnapshotId: SnapshotId
    let contextManifestId: ?ContextManifestId

    let semanticRequestId: ?SemanticRequestId
    let attemptId: ?AttemptId
    let reservedDecisionId: ?DecisionId
    let reservedUsageId: ?UsageId
    let reservedItemIds: Array<ItemId>

    let toolBatch: ?ToolBatchContinuation
    let pendingOperationId: ?OperationId
    let pendingApprovalId: ?ApprovalId
    let waitingExternal: ?ExternalWaitState

    let workDebt: WorkDebtSnapshot
    let recoveryPolicyVersion: UInt32
    let digest: String
}
```

`RunExecutionPhase` 必须是带完整 payload 的代数类型：

```cangjie
enum RunExecutionPhase {
    Accepted(AcceptedState)
    ContextCompiling(ContextCompilingState)
    ContextReady(ContextReadyState)

    ModelReady(ModelReadyState)
    ModelEffectPending(ModelEffectPendingState)
    ModelSettling(ModelSettlingState)
    DecisionReady(DecisionReadyState)

    ToolBatchReady(ToolBatchReadyState)
    WaitingApproval(WaitingApprovalState)
    ToolEffectPending(ToolEffectPendingState)
    ToolSettling(ToolSettlingState)

    WaitingExternal(WaitingExternalState)
    Checkpoint(CheckpointState)
    Terminalizing(TerminalizingState)
}
```

每个 phase 都必须包含恢复所需的完整状态，禁止依赖上一个 phase。

---

# 七、Effect Sandwich

所有不确定外部效果都使用：

```text
Intent Transaction
→ Uncertain External Effect
→ Settlement Transaction
```

## 1. 模型请求

```text
TX1
  create ModelAttempt
  persist exact ContextManifest
  persist effective provider request
  reserve DecisionId / UsageId / ItemIds
  continuation = ModelEffectPending

Provider request / stream

TX2
  persist terminal evidence
  persist validated Decision and Blocks
  persist usage
  continuation = DecisionReady
```

崩溃在中间时：

```text
Provider 支持 request status / idempotency
    → 查询或恢复

Provider 无法查询，但策略允许重试
    → 关闭旧 Attempt 为 Interrupted
    → 新 Attempt

可能已计费且重试不安全
    → RecoveryRequired
```

## 2. Tool

```text
TX1
  create immutable OperationRecord
  reserve ReceiptId / ToolResultItemId
  persist normalized effective arguments
  persist replay policy
  continuation = ToolEffectPending

Execute

TX2
  persist Receipt
  persist ToolResult Item
  advance batch
```

## 3. 外部异步任务

```text
TX1
  reserve ExternalHandleId
  persist submit intent

Submit external job

TX2
  persist remote job handle
  continuation = WaitingExternal
```

后续恢复通过 remote handle poll/attach，而不是重新 submit。

---

# 八、ReplayDisposition

替换简单的 `safe/never` 二元模型：

```cangjie
enum ReplayDisposition {
    Pure
    SafeReplay
    Idempotent(String)
    RecoverByProbe(RecoveryProbeId)
    Compensatable(CompensationPlanId)
    AtMostOnce
    NeverReplay
}
```

含义：

| 类型               | 恢复行为                          |
| ---------------- | ----------------------------- |
| `Pure`           | 可直接重算                         |
| `SafeReplay`     | 同实现 fingerprint 下可重放          |
| `Idempotent`     | 使用冻结的 idempotency key 重试      |
| `RecoverByProbe` | 先查询外部系统是否已完成                  |
| `Compensatable`  | 可执行明确补偿流程                     |
| `AtMostOnce`     | 不确定时不重放，生成 interrupted result |
| `NeverReplay`    | 进入人工恢复或 `RecoveryRequired`    |

每个 Operation 必须冻结：

```text
toolId
toolVersion
implementationFingerprint
schemaDigest
effectiveArgumentsDigest
replayContractVersion
```

当前扩展版本改变时，不允许使用新实现盲目恢复旧 Operation。

---

# 九、WorkDebt：Run 是否可以结束的唯一依据

```cangjie
class WorkDebtSnapshot {
    let unclaimedInputs: Array<InboxEntryId>
    let activeAttempts: Array<AttemptId>
    let uncommittedDecisions: Array<DecisionId>
    let unsettledOperations: Array<OperationId>
    let pendingApprovals: Array<ApprovalId>
    let waitingExternal: Array<ExternalHandleId>
    let activeChildRuns: Array<RunId>
    let ownedTasks: Array<OwnedTaskId>
    let deferredContexts: Array<DeferredContextId>
}
```

Run terminal 条件：

```text
所有列表为空
```

或每项已被明确归类为：

```text
Completed
Cancelled
Failed
Quarantined
Interrupted
```

主循环“暂时没有下一条消息”不再等价于 Run 可以结束。

---

# 十、Inbox 与 Steering

Lane 拥有持久 Inbox：

```cangjie
enum InboxEntryKind {
    UserPrompt
    Steering
    ContextInjection
    ApprovalDecision
    ExternalCompletion
    ChildRunMessage
    Cancel
    Close
}
```

Inbox Entry 状态：

```text
Queued
Claimed
Applied
Rejected
Superseded
```

Claim 必须在事务中完成：

```text
mark claimed
+ open Turn/Step
+ place accepted Item
+ update RunContinuation
```

避免崩溃后同一输入被重复消费。

---

# 十一、Context Compiler

Context 不再是简单“历史截断器”，而是一个确定性编译器。

```text
Lane leaf
+ current Turn intent
+ prior branch Items
+ checkpoint
+ named fact versions
+ active Skills
+ memory retrieval
+ prompt contributions
+ tool catalog
+ token budget
→ ModelContextManifest
→ rendered provider-neutral request
```

DeepSeek Harness 强调模型可见内容必须可以从持久会话日志重建，Pi 则从 Lane 当前分支投影上下文；Axyndra 应在此基础上进一步持久化精确 ContextManifest。

## 编译阶段

```text
1. Branch selection
2. Checkpoint application
3. Current intent placement
4. Fact and memory retrieval
5. Active Skill assembly
6. Prompt contribution resolution
7. Tool catalog projection
8. Tool-result pruning
9. Compaction / summary selection
10. Token measurement
11. Manifest commit
```

## Prompt Contribution

所有 Prompt Section 都以 content-addressed Artifact 存储：

```cangjie
class PromptContribution {
    let ownerComponentId: ComponentInstanceId
    let scope: ComponentScope
    let orderBand: String
    let artifactHash: ContentHash
    let visibility: PromptVisibility
}
```

这样某个插件更新后，旧 Attempt 仍能重建原提示词。

## Compaction

Compaction 是一等 Durable RunKind：

```text
RunKind.Chat
RunKind.Compaction
RunKind.NavigationSummary
RunKind.Verification
```

Compaction 不能直接覆盖旧 Item，只能生成：

```text
Checkpoint
Summary Item
Surface replacement metadata
```

---

# 十二、模型执行平面

保留 Axyndra 当前思路：

```text
RequestedModelPolicy
→ frozen ModelCapabilitySnapshot
→ AttemptPolicyInput
→ ResolvedModelRequestPolicy
→ provider lowering
```

每个 Attempt 额外绑定：

```text
CompositionSnapshot
ContextManifest
ProviderAdapterFingerprint
ToolPresentationMode
```

## Attempt 生命周期

```text
Prepared
DispatchClaimed
InFlight
TerminalObserved
Validated
Settled

或

Interrupted
Failed
RecoveryRequired
```

## Streaming

实时层：

```text
DraftText
DraftReasoning
DraftToolCall
UsageEstimate
```

语义层：

```text
Validated DecisionBlock
```

UI 可显示实时草稿，但任何 Tool Operation 必须来自已 canonical commit 的 ToolCall block。

---

# 十三、Operation Pipeline

完整流程：

```text
Decision ToolCallBlock
→ Resolve Tool Identity
→ Validate Schema
→ Normalize Arguments
→ Build OperationPlan
→ Capability Check
→ Policy Decision
→ Approval
→ Intent Commit
→ Sandbox / Service Execution
→ Verification
→ Receipt Commit
→ Canonical ToolResult Item
```

## OperationPlan

```cangjie
class OperationPlan {
    let toolId: String
    let toolVersion: String
    let implementationFingerprint: String
    let arguments: AgentValue
    let argumentsDigest: String

    let capabilityRequirement: CapabilityRequirement
    let resourceScope: ResourceScope
    let effectClass: EffectClass
    let replayDisposition: ReplayDisposition
    let concurrencyMode: ToolConcurrencyMode

    let timeoutPolicy: TimeoutPolicy
    let budget: ExecutionBudget
    let sandboxProfile: SandboxProfileId
}
```

## ConcurrencyMode

```cangjie
enum ToolConcurrencyMode {
    ParallelSafe
    Exclusive
    Barrier
    Unknown
}
```

`Unknown` 必须按 `Exclusive` 处理。

## Verifier

Verification 应成为独立 Seam：

```cangjie
interface OperationVerifier {
    func verify(
        plan: OperationPlan,
        rawOutcome: RawOperationOutcome
    ): Result<VerificationReceipt>
}
```

验证失败不应抹去已经发生的副作用，而应得到：

```text
SucceededVerified
SucceededUnverified
SucceededVerificationFailed
Failed
Unknown
```

---

# 十四、Tool Program Mode

DeepSeek Harness 的 Code Mode 允许模型针对工具生成 TypeScript 程序，减少多轮 Tool Call 和中间结果进入上下文的成本，但其内部子调用仍经过完整 Tool Pipeline。

Axyndra 应实现更严格的：

```text
Tool Program Mode
```

## 模式

```cangjie
enum ToolPresentationMode {
    Native
    Programmatic
    Auto
}
```

不建议默认 `Both`，因为同时携带 schema 和 SDK 会增加大量 token。

## 模型输入形式

模型可写 TypeScript 风格子集：

```typescript
const files = await tools.glob({ pattern: "**/*.cj" })
const matches = await parallel(
  files.map(file => tools.grep({ path: file, pattern: "RunState" }))
)
return matches.filter(x => x.count > 0)
```

但宿主不直接执行任意 JavaScript。

```text
parse
→ validate restricted subset
→ type-check tool bindings
→ compile ToolProgramIR
→ interpret in sandboxed runtime
```

## 第一版 IR 只支持

```text
let
if
bounded for-each
map/filter/reduce
bounded parallel
try/catch
return
```

禁止：

```text
import
eval
ambient filesystem
ambient network
arbitrary process
unbounded loop
reflection
dynamic code generation
```

## 每个子调用仍然是 Operation

```text
ProgramOperation
├── SubOperation 0
├── SubOperation 1
└── SubOperation 2
```

每个子调用拥有独立：

```text
OperationId
Receipt
Capability check
Approval
ReplayDisposition
Implementation fingerprint
```

模型默认只看到聚合的 ProgramResult；完整子调用轨迹仍然持久化。

## Program Runtime 限制

```text
maxInstructions
maxSubCalls
maxParallelCalls
maxDepth
maxWallTime
maxComputeTime
maxResultBytes
maxLogBytes
```

存在副作用的 Program 部分成功时，不允许整体盲目重试：

```text
Completed
Partial
Failed
RecoveryRequired
```

---

# 十五、Service Seam

引入运行时类型化服务注册表：

```cangjie
class ServiceKey<T> {
    let name: String
    let contractVersion: UInt32
    let expectedScope: ServiceScope
}

interface ServiceProvider<T> {
    func acquire(scope: ComponentScope): Result<ServiceLease<T>>
}
```

首批 Service：

```text
ModelProviderRegistry
FileSystemService
ProcessService
TerminalService
LanguageServerService
DebugAdapterService
WebAccessService
SandboxService
ApprovalService
ArtifactStore
MemoryStore
SessionStore
VerifierRegistry
TelemetryService
CodeRuntimeService
```

Consumer 只能依赖 Service Definition，不依赖具体实现。

例如：

```text
FileSystemService
├── LocalFS
├── BubblewrapFS
├── ContainerFS
├── RemoteWorkerFS
└── SSHFS
```

将 FS 和 Process 指向同一个 Remote Execution Realm，即可把 Shell、LSP、Terminal 一并搬到远端，而不是为每个 Tool 写远程特化版本。

---

# 十六、Realm 与作用域

定义固定作用域层级：

```text
HostRealm
  全局注册表、Store、Sandbox Authority

ThreadRealm
  Thread 级 Facts、Artifacts、共享 Skills

LaneRealm
  Agent Profile、Model Lane、Tool Visibility

RunRealm
  Cancellation、Budget、Context、WorkDebt

ExtensionRealm
  单个扩展 generation 的资源

InvocationRealm
  单次 Tool / Hook 执行
```

Service 必须声明其合法 Scope。

例如：

```text
SQLite Store
    HostRealm

Lane-specific Context Compiler
    LaneRealm

CancellationToken
    RunRealm

Tool temporary process
    InvocationRealm
```

---

# 十七、EffectScope 与安全卸载

当前 Axyndra ExtensionRuntime 已经支持 Manifest、SDK 范围、依赖检查、启用和停用，但使用 `CompiledExtensionProvider`，并明确不拥有正在执行的 ToolPipeline 工作，因此停用不是完整安全卸载。

下一代扩展 API：

```cangjie
interface EffectScope {
    func provideService<T>(key: ServiceKey<T>, provider: ServiceProvider<T>)
    func registerTool(tool: ToolContribution)
    func registerPrompt(contribution: PromptContribution)
    func registerHook(hook: HookContribution)
    func registerSkill(provider: SkillProvider)

    func ownTask(task: OwnedTask)
    func ownProcess(process: OwnedProcess)
    func ownResource(resource: DisposableResource)

    func deferDispose(action: () -> Unit)
}
```

扩展生命周期：

```text
Discovered
→ Validated
→ Mounted
→ Active
→ StopAdmitting
→ Draining
→ Disposing
→ Inactive
```

失败路径：

```text
Draining timeout
→ Quarantined
→ RecoveryRequired
```

## Generation-based Reload

热更新不在原实例上修改：

```text
extension@v1 generation 12
extension@v2 generation 13
```

流程：

```text
挂载 generation 13
→ 新 Run 使用 13
→ generation 12 停止接受新调用
→ 旧调用 drain
→ refcount = 0
→ 卸载 12
```

---

# 十八、扩展类型

| 类型             | 执行位置         | 信任级别  | 用途       |
| -------------- | ------------ | ----- | -------- |
| Built-in       | 进程内          | 最高    | 核心官方能力   |
| Trusted Native | 进程内          | 高     | 受控部署扩展   |
| Process Plugin | 沙箱子进程        | 中/低   | 第三方代码    |
| WASM Component | WASM Runtime | 中/低   | 可移植第三方插件 |
| MCP            | 外部进程/服务      | 低     | 远程工具     |
| Skill          | 内容层          | 不授予权限 | 指令与知识    |

第三方插件不应通过通用 `dlopen()` 进入宿主地址空间。

## 插件包格式

建议：

```text
extension.axp
├── manifest.json
├── module.wasm
│   或 executable/
├── schemas/
├── prompts/
├── resources/
└── signature.json
```

Manifest：

```text
id
version
sdkRange
protocolRange
entrypoint
contributions
requiredServices
requestedCapabilities
stateSchemaVersion
recoveryCompatibility
signature
```

插件只能“申请” Capability，不能自行授予。

---

# 十九、Agent Profile

Profile 决定一个 Lane 的能力组合：

```cangjie
class AgentProfile {
    let id: String
    let version: String
    let baseProfile: ?String

    let mounts: Array<ComponentMount>
    let serviceBindings: Array<ServiceBinding>
    let modelRoles: Array<ModelRoleBinding>

    let toolVisibility: ToolVisibilityPolicy
    let toolPresentation: ToolPresentationMode
    let capabilityCeiling: CapabilitySet

    let contextPolicy: ContextCompilerPolicy
    let compactionPolicy: CompactionPolicy
    let skillSources: Array<SkillSource>
}
```

配置层级：

```text
Built-in defaults
< Profile
< Workspace
< User
< Session/Lane
< Run override
```

最终结果在 Run 开始时解析并冻结。

推荐内置 Profile：

```text
standard
minimal
plan
reviewer
child-readonly
child-workspace-write
eval-replay
programmatic-readonly
```

Plan Profile 可以保持 Tool Catalog 稳定，但通过 Capability Ceiling 和 Policy 禁止 mutation，而不是靠提示词声称“不要写文件”。

---

# 二十、Hook 模型

DeepSeek Harness 的 typed events 和 waterfall 适合扩展执行路径，但 Axyndra 必须明确 Hook 的权限和重放语义。

```cangjie
enum HookKind {
    Observer
    Transformer
    Decider
    Around
}
```

## Observer

只能观察：

```text
AttemptStarted
DecisionCommitted
OperationSettled
RunFinished
```

## Transformer

返回受限 patch，由内核校验：

```text
ContextSelectionPatch
PromptAssemblyPatch
ToolResultPresentationPatch
```

## Decider

只能：

```text
Allow
Deny
Ask
Abstain
```

后续 Hook 不得把 Deny 重新扩大为 Allow。

## Around

只用于：

```text
timeout
retry transport
metrics
tracing
```

不能修改 Operation identity、Capability requirement 或 Receipt authority。

## Replay Contract

```cangjie
enum HookReplayContract {
    OnceAndPersist
    PerAttempt
    OnSafeReplay
    ResumeOnly
    IdempotentMayRepeat
    ObserveOnly
}
```

每个 Hook 必须声明：

```text
owner
scope
priority
replay contract
timeout
failure policy
output schema
```

---

# 二十一、Child Run 与 Agent Team

## Shared-history Child

```text
在同一个 Thread 创建新 Lane
anchor = 当前 Item
```

适用于：

```text
并行搜索
Reviewer
Planner
共享上下文的研究任务
```

## Isolated Child

```text
Fork 新 Thread
```

适用于：

```text
权限隔离
隐私隔离
不同工作区
长期独立任务
```

## Capability 继承

子 Run 的能力：

```text
Parent capability ceiling
∩ Child profile ceiling
∩ Delegation grant
```

子 Run 永远不能扩大父 Run 权限。

## Agent Team

Agent Team 不应作为独立 AgentCore，而应建立在 Lane 之上：

```text
Team
├── Durable roster
├── Task board
├── Mailbox
├── Member lanes
└── Coordinator lane
```

成员之间通过持久消息和 Item Reference 通信，不能直接修改彼此 RunContinuation。

---

# 二十二、所有权与并发模型

## Thread Supervisor

一个 Thread 同一时刻只有一个 fenced owner process：

```text
ThreadLease {
    ownerId
    fenceToken
    expiresAt
}
```

## Lane Actor

每个 Lane 内串行处理：

```text
Inbox claim
Run transition
Context compile
Semantic commit
```

不同 Lane 可以并行。

## Tool Scheduler

Tool batch 使用有界 rolling pool：

```text
ParallelSafe
    最多 N 个并行

Exclusive
    等待当前 pool drain 后单独执行

Barrier
    前后都形成顺序屏障
```

## 后台作业

后台 Tool 不允许成为无法追踪的 fire-and-forget：

```text
JobOperation
→ durable remote/local handle
→ WaitingExternal
→ collect / cancel / settle
```

---

# 二十三、安全模型

权限计算：

```text
Tool requested capability
∩ Extension declared capability
∩ Profile capability ceiling
∩ Run capability ceiling
∩ Current grant
∩ Resource policy
∩ Approval decision
```

任意一项不满足都拒绝。

## Secret

插件和 Tool 不直接获得宿主环境变量。

```text
CredentialRef
→ CredentialService
→ operation-scoped resolution
→ filtered invocation environment
```

Receipt、日志、错误和 AppEvent 均经过统一 redaction。

## Approval

Approval 绑定：

```text
Operation digest
Capability ceiling
Resource scope
Implementation fingerprint
Expiry
Decision source
```

参数、Tool 版本或 Scope 任一变化，旧 Approval 失效。

## Sandbox

Sandbox 不可用时：

```text
fail closed
```

不能静默回退为宿主直接执行。

## 第三方扩展

```text
进程外或 WASM
无原始 DB 句柄
无宿主对象引用
无隐式环境
无未经授权的网络
```

---

# 二十四、App Protocol

Client 只通过 typed protocol 与 Runtime 交互。

## Commands

```text
CreateThread
CreateLane
ForkThread
Prompt
Steer
InjectContext
RespondApproval
CancelRun
CloseLane
ActivateProfile
InspectTrajectory
```

## Queries

```text
ThreadSnapshot
ItemBranch
LaneSnapshot
RunSnapshot
OperationSnapshot
CompositionSnapshot
ContextManifest
Trajectory
UsageSummary
```

## Events

分为两类：

### Durable semantic events

```text
ItemCommitted
DecisionCommitted
OperationSettled
ApprovalRequested
RunFinished
LaneMoved
```

绝不丢弃。

### Ephemeral projection events

```text
DraftChanged
StreamingDelta
Progress
TokenEstimate
```

可以 coalesce。

每个 Event 带：

```text
threadId
laneId
runId
epoch
commitSequence
eventSequence
```

---

# 二十五、Trajectory、Eval 与可解释性

新增统一的因果投影：

```text
External Input
→ Turn
→ ContextManifest
→ SemanticRequest
→ ModelAttempt
→ ModelDecision
→ DecisionBlock
→ Operation
→ Receipt
→ Canonical Item
```

CLI：

```text
axyndra inspect profile
axyndra inspect services
axyndra inspect tools
axyndra inspect context <attempt>
axyndra inspect trajectory <run>
axyndra explain tool <name>
axyndra explain approval <operation>
axyndra diff-profile <left> <right>
```

## 自动 Eval 闭环

任意生产失败可提取：

```text
Frozen Thread slice
Composition Snapshot
Context Manifest
Model Capability Snapshot
Provider transcript
Operation plans
Receipts
Expected invariant
```

形成 deterministic replay fixture。

## Replay Provider

Provider Adapter 增加：

```text
ReplayModelProvider
```

它根据 semantic request digest 返回冻结 Decision，不调用真实模型。

---

# 二十六、统一 RuntimeEffects 与故障注入

```cangjie
interface RuntimeEffects {
    func commit(tx: DurableTransaction): Result<CommitReceipt>
    func requestModel(request: FrozenModelRequest): Result<ModelEffectResult>
    func executeOperation(plan: OperationPlan): Result<RawOperationOutcome>
    func invokeHook(call: HookCall): Result<HookOutcome>
    func sleep(deadline: Deadline): Result<Unit>
}
```

两套实现：

```text
ProductionRuntimeEffects
DeterministicRuntimeEffects
```

测试驱动：

```text
driveUntil(ModelEffectPending)
crash()
reopen()
resume()
assertNoDuplicateEffect()
```

必须覆盖：

```text
每个事务之前
每个事务之后
Provider 已收到请求但未 settlement
Tool 已产生副作用但未 Receipt
Approval 与 Cancel 竞争
Extension deactivate 与 Tool start 竞争
Run terminal 与 late event 竞争
```

---

# 二十七、建议包结构

尽量在现有包上增量演进，而不是一次性重命名所有包。

```text
agent_domain
    IDs、Thread、Item、Lane、Turn、Run、Step、
    Attempt、Decision、Operation、Receipt

agent_store
    SemanticStore、SQLite、事务、迁移、outbox、lease

agent_runtime
    ThreadSupervisor、LaneActor、RunInterpreter、
    RunContinuation、WorkDebt、恢复

agent_context
    ContextCompiler、ContextManifest、Compaction、TokenMeter

agent_model_runtime
    Attempt policy、Provider seam、terminal validator

tool_runtime
    Operation pipeline、scheduler、verification、Tool Program IR

agent_composition
    ServiceKey、ServiceRegistry、Realm、Profile、
    CompositionSnapshot、EffectScope

agent_extension_runtime
    Manifest、安装、generation、drain、process/WASM/MCP adapters

agent_skills
    Skill registry、content loader、snapshot

agent_app_protocol
    Command、Query、Event、cursor、mailbox

agent_client
    typed client

agent_sdk
    embed API、Builder、testkit integration

agent_product
    composition root 与产品配置，不拥有重复语义
```

---

# 二十八、数据库核心表

```text
threads
thread_states

items
item_references

lanes
lane_states
lane_inbox

turn_records
run_records
run_continuations
run_outcomes
step_records

model_context_manifests
model_attempts
model_decisions
model_decision_blocks
model_decision_usage
canonical_decision_items

operation_records
operation_states
operation_receipts
decision_operations

approval_requests
approval_decisions
capability_grants

composition_snapshots
component_instances
extension_scopes
extension_states

checkpoints
artifacts
fact_registers

usage_ledger
audit_ledger
app_event_outbox

thread_leases
schema_migrations
```

所有 JSON payload 必须：

```text
schemaVersion
canonical encoding
digest
```

数据库 API 改为 prepared statement + typed binding，业务代码禁止自行拼接 SQL。

---

# 二十九、迁移路线

## Phase 0：可信仓库基线

在引入新架构之前先完成：

```text
clean-clone build
CI required checks
修复 architecture gate 过期路径
清除 DB/WAL/dist/log/PID
闭合 cj_tui 依赖
文档与实际包同步
```

这是所有后续工作的前置条件。

## Phase 1：Total RunContinuation

交付：

```text
RunContinuationV1
phase interpreter
continuation digest
完整恢复 switch
旧 continuation 双写兼容
deterministic crash driver
```

暂不引入 Lane Tree。

## Phase 2：统一 Effect Sandwich

交付：

```text
Model intent/settlement
Tool intent/settlement
预留结果 ID
ReplayDisposition
implementation fingerprint
OperationRecord / State / Receipt 拆分
```

## Phase 3：Step、WorkDebt、Inbox Claim

交付：

```text
StepRecord
Turn enclosure
WorkDebt
持久 Inbox
Steering
WaitingExternal
严格 terminal rule
```

## Phase 4：ContextManifest

交付：

```text
ContextCompiler
Content-addressed prompt contributions
Tool catalog snapshot
模型请求精确重建
Compaction as durable RunKind
```

## Phase 5：Lane 与 Item Tree

先迁移为：

```text
main Lane
线性 Items 自动形成 parent chain
```

再增加：

```text
CreateLane
Shared-history child
ForkThread
Lane-local queues/config
```

## Phase 6：Composition Graph

交付：

```text
ServiceKey
ServiceRegistry
Realm
AgentProfile
CompositionSnapshot
EffectScope
```

现有 Extension 通过适配层接入。

## Phase 7：安全扩展生命周期

交付：

```text
generation reload
stop admission
drain
quarantine
process plugin
WASM plugin
signed manifest
```

## Phase 8：Tool Program Mode

先交付只读模式：

```text
TS-like subset
ToolProgramIR
bounded scheduler
每子调用 Operation/Receipt
```

有副作用模式必须在只读 Eval 稳定后再加入。

## Phase 9：Agent Team 与远程执行

交付：

```text
Team roster
task board
mailbox
remote execution realm
distributed routing
```

---

# 三十、推荐提交拆分

```text
A. clean repository and CI closure
B. semantic transaction + outbox
C. RunContinuationV1
D. deterministic effect driver
E. provider effect sandwich
F. operation record/state/receipt split
G. hook replay contracts
H. Step + WorkDebt + durable inbox
I. ContextManifest + compiler
J. Item tree + main Lane migration
K. multi-Lane runtime
L. Service Registry + Realm
M. Profile + Composition Snapshot
N. EffectScope + generation drain
O. process/WASM plugin host
P. Tool Program read-only mode
Q. programmatic side-effect recovery
R. legacy compatibility removal
```

每个提交都必须是独立可构建、可测试的状态。

---

# 三十一、发布门禁

## Clean Build Gate

```text
全新 clone
固定 SDK
固定依赖
check/build/test
```

## Semantic Invariant Gate

至少检查：

```text
未验证 Decision 不得 canonical commit
每个 terminal Operation 恰有一个 Receipt
Run terminal 时 WorkDebt 必须为空或已分类
NeverReplay 不得自动重放
ContextManifest 可重建精确请求
```

## Crash Matrix Gate

对每个 phase 进行：

```text
before intent
after intent
during effect
before settlement
after settlement
during terminal
```

## Extension Lifecycle Gate

```text
激活 1000 次
停用 1000 次
无 Tool/Hook/Task/Process 泄漏
旧 generation 不接受新调用
drain timeout 进入 Quarantine
```

## Security Gate

```text
Capability 不能被 Hook 扩大
Approval digest mismatch 必须拒绝
Sandbox 缺失 fail closed
Secret 不进入日志与 Receipt
第三方插件无 ambient authority
```

## Performance Gate

建议目标：

```text
100k Items 的 branch/context 查询稳定
256 Lanes 可持久化
64 个活动 Lane 不破坏公平性
AppEvent cursor 无 gap
Draft coalescing 不丢 semantic event
```

## PTC Eval Gate

Programmatic Mode 只有在以下至少一项显著改善且安全指标不退化时才能默认启用：

```text
成功率
模型往返次数
输入 token
挂钟延迟
中间结果大小
```

同时要求：

```text
重复副作用 = 0
恢复错误率 = 0
Capability 绕过 = 0
```

---

# 三十二、明确不做的事情

第一版 Axyndra Next 不应追求：

```text
Exactly-once 外部副作用
任意第三方进程内插件
Provider stream 跨进程续传
无边界多写者
把 Run Interpreter 本身插件化
让 UI 或 Hook 修改 canonical facts
默认启用任意代码执行式 PTC
```

外部世界无法普遍提供 exactly-once，因此正确目标是：

```text
显式不确定窗口
+ 稳定 idempotency
+ 可探测恢复
+ 禁止危险重放
+ 明确 RecoveryRequired
```

---

# 最终形态

Axyndra Next 的固定数据流应当是：

```text
Durable Inbox
→ Acceptance Transaction
→ Turn + Run + total RunContinuation
→ Context Compiler + ContextManifest
→ Model Intent Transaction
→ Provider Effect
→ Validated Decision Settlement
→ Atomic Canonical Projection
→ Operation Intent Transaction
→ Capability / Policy / Approval
→ Sandboxed Effect
→ Verification + Receipt Settlement
→ WorkDebt Convergence
→ Terminal Transaction
→ Typed App Projection
→ Trajectory / Eval
```

最终架构定位不是：

```text
一个带很多工具的聊天程序
```

也不是：

```text
一个所有东西都能随意替换的插件容器
```

而是：

> **一个拥有强语义内核、完整崩溃恢复、严格副作用边界、可组合能力图和可验证执行轨迹的 Agent 操作系统。**

实施优先级应固定为：

```text
仓库可信基线
→ RunContinuation
→ Effect Sandwich
→ WorkDebt
→ ContextManifest
→ Lane
→ Composition / EffectScope
→ 安全插件
→ Tool Program Mode
→ Agent Team
```

