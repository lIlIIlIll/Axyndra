# Axyndra TUI UI/UX 规范

**目标规范；不代表当前版本已全部实现。** 本文定义普通工作页的目标布局、交互和验收结果。规范名称是设计术语，不代表已存在的 Cangjie 类型或配置 API。

## 适用范围与规范等级

本规范面向 Axyndra TUI 的产品实现与验收。`MUST` 表示验收必需，`SHOULD` 表示默认要求，`MAY` 表示条件能力。源码现状、截图观察和设计目标分别标明；目标不得写成当前功能。

条款编号是稳定验收标识。实现差距见[现状映射与证据边界](#现状映射与证据边界)。

## 参考特征与设计原则

参考图呈现全宽单列工作流，没有固定左右工具侧栏。其主区层级可作为 transcript 参考，但不限制根布局增加右侧栏。工具卡含标题、调用摘要、Output、有限预览、展开提示和状态。卡片后弱化统计与会话底部统计属于不同信息层。

参考图还呈现分阶段 TODO、当前动作、会话任务名、子代理摘要和旁问面板。旁问提示为 `c to copy · f to follow up · Esc to close`；截图不能证明该能力属于 Axyndra、面板是否固定或如何取得焦点。第二张图的展开提示、内容截断说明和完整结果引用是三个不同事实。图片中的重复 JSON、重复预览、壁纸和本机路径不是规范要求。

设计原则：工具正文只在 transcript 出现；辅助区展示摘要；任务目标、TODO 步骤、后台任务和子代理是不同实体；缺少数据时省略，不造状态、统计或能力；移动视图不移动业务状态。

## 屏幕结构与组件契约

### LAY-01：主区与侧栏各有唯一组件宿主

普通工作页采用以下目标结构。全屏 Plan Review 等模式仍由自身拥有画面。

```text
Screen
├─ WorkArea                         H−1 行
│  ├─ MainPane
│  │  ├─ Transcript                 消费主列剩余高度
│  │  │  ├─ Message / Reasoning
│  │  │  ├─ ToolCard / Ask / Approval
│  │  │  └─ TurnSummary
│  │  ├─ ContextStack               有效位置在主区的辅助组件
│  │  ├─ ActivityLine
│  │  ├─ TaskRail
│  │  └─ Composer
│  ├─ Divider                       侧栏可见时 1 列
│  └─ Sidebar                       标题与独立滚动组件栈
├─ SessionStatus                    全宽 1 行
└─ OverlayHost                      设置、文档、计划等交互模式
```

可停靠组件为 `TaskOverview`、`PromptQueue`、`Todo`、`SubagentStrip`、`Aside`。主区和侧栏都按固定顺序呈现其组件子集：TaskOverview → PromptQueue → Todo → SubagentStrip → Aside。用户选择组件归属；不提供拖拽、多列、排序编辑器或布局脚本。

默认将 TaskOverview、Todo、SubagentStrip 放入侧栏；PromptQueue 和条件性 Aside 留在主区。用户可选择任意可用组合，也可全部取消以恢复单列。取消选择表示组件回到主区，不隐藏能力或数据。

Transcript、ToolCard、Ask/Approval、ActivityLine、TaskRail、Composer 和 SessionStatus 不可停靠或由布局设置隐藏。工具正文只在 transcript；侧栏只承载摘要。授权对象与选项始终由原交互模式呈现。

组件只绘制分配矩形并读取既有数据投影。组件不得自行清屏、执行产品 I/O 或管理第二套 operation/task ledger。调用失败进入产品诊断通道；缺失值不得伪装成成功。

每个组件同一时刻只有一个宿主。迁移时保留身份、展开选择和阅读锚点；不得重新发请求或创建另一份任务状态。窄屏的有效位置可暂时不同于用户偏好，详见 LAY-02、LAY-03。

|组件|数据与条件|焦点和滚动|空态与异常|
|---|---|---|---|
|Transcript|既有消息、工具与交互事件|主滚动；显式选择卡片|空会话显示开始提示；错误是有身份的条目|
|TaskOverview|会话目标、明确状态、已知非子代理后台任务|只读；详情仍在原卡片|无目标和任务时 0 行；未知状态明确未知|
|PromptQueue|尚未投递的 steer/follow-up|不自动聚焦；编辑沿用撤回路径|空队列 0 行；保留真实失败事实|
|Todo|现有 TODO Markdown 任务与阶段信息|摘要不抢焦点；编辑沿用 TodoController|无任务 0 行；失败显示诊断|
|SubagentStrip|会话子代理身份、角色、状态|摘要不抢焦点；详情沿用 Agent Hub|未创建为 0 行；区分失败与等待|
|Aside|仅当产品具备能力且面板打开|显式聚焦后处理本地动作|无能力或未打开为 0 行；错误来自真实结果|
|Sidebar|用户选择的组件宿主|F6/点击显式聚焦；保存阅读锚点|选中组件都无内容时显示一行“暂无侧栏内容”|
|ActivityLine|当前动作、取消或等待事实|无独立滚动；提示按焦点上下文变化|空闲保留 1 空行；等待用户时不显示 Working|
|TaskRail|会话任务锚点及有来源的汇总|无独立交互|缺失元数据省略，不补零|
|Composer|主草稿、光标、补全|默认输入焦点；超限时内部滚动|空稿保留提示符；失败显示产品错误|
|SessionStatus|模型、模式、工作区、当前焦点快捷提示|全宽 1 行|缺失元数据省略；保留适用操作提示|
|OverlayHost|既有设置、文档、计划等交互状态|所属 controller 独占输入与本地滚动|关闭时不绘制；关闭后恢复原状态|

TaskOverview 回答“当前在做什么、哪些已知任务正在运行”；TODO 回答“计划还有哪些步骤”；SubagentStrip 回答“哪些子代理在工作”。`JobStatus` 的 `jobType=task` 表示子代理，不得再次作为后台任务计数。只有产品提供的非子代理任务进入后台任务摘要。

普通背景更新不抢焦点。Ask/审批仍使用原有明确交互模式并保留草稿；侧栏焦点、位置或折叠状态不能替代授权。

### LAY-03：用户可设置组件停靠并保存偏好

`/settings` 的目标子项为 `Layout`，页面标题为 `Sidebar widgets`。按固定顺序列出 `Task`、`Prompt queue`、`TODO`、`Subagents`、`Aside` 复选项。页面说明“勾选：侧栏；未勾选：主区”。产品不支持旁问时，Aside 禁用并说明原因。

无更高优先级交互的主工作页中，目标快捷键 F2 打开同一页面并保存主草稿与返回焦点。运行中的纯布局编辑不得取消任务或发模型请求。现有 `/settings` 运行中受 slash-command 门禁限制；F2 是目标入口，不绕过业务门禁。

|布局页输入|目标行为|
|---|---|
|Up/Down|选择行；初始选中 Task|
|Space|修改暂存勾选|
|Enter|保存并应用|
|Esc 或 Ctrl+C|放弃未保存选择并返回|

不得逐项落盘或后台即时重排。保存期间不重复提交，也不能继续改勾选。Esc/Ctrl+C 只提示正在保存，不声称撤销已提交写入。成功后统一更新宿主并恢复焦点；失败保留原布局、草稿和编辑选择，显示真实错误并允许重试或取消。

偏好属于用户级 UI 设置，在同一应用配置下跨会话和重启保留；不得写入项目文件、对话事件或模型提示，也不影响权限。实现复用产品配置持久化边界，不在本文指定配置键或 JSON schema。上述页面、快捷键和保存能力都是目标。

首次无偏好时使用默认三项侧栏。读取失败时采用默认显示并提示读取失败，不覆盖原配置；只有成功保存才更新偏好。已保存组件暂不可用时保留偏好并暂停挂载；能力恢复后再应用。没有任何可用的选中组件时不占侧栏宽度。

窄屏设置仍可保存，并显示“侧栏组件暂在主区显示”；终端变宽后按偏好停靠。布局改变不得换会话、重启 agent 或重置 TODO/子代理进度。

布局编辑期间若 Ask/审批到达，关闭页面并放弃未提交选择；保留主草稿和已确认偏好，进入原决策模式。若保存已提交，其结果仍更新偏好，但回调不得关闭新决策、切回布局页或抢 Composer 焦点。布局保存不授权业务操作。

**可观察验收：**默认勾选下按 F2、Down、Down、Space、Enter，只将 TODO 移回主区；Task/Subagents 留在侧栏，草稿不变且无 Provider 请求。再次操作恢复 TODO 到侧栏。全不选后显示单列；重启后保留选择。窄屏临时回流不覆盖偏好。取消、保存失败或不可用 Aside 不留下半应用布局。

## 尺寸与空间分配

### LAY-02：响应式布局按单元格尺寸分配空间

尺寸以终端显示单元格计。宽度测量包含边框、边距、标题和提示；不得按 UTF-8 字节测量。先分配宿主和列宽，再按有效宽度计算换行和高度。

侧栏出现条件为 `W≥120`、`H≥18`，且至少一个当前支持的组件被选入侧栏。组件暂时无数据不改变列宽；显示聚合空态。侧栏宽度 `S=min(44,max(32,floor(W/4)))`，分隔线宽 1，主列 `M=W−S−1`，且不少于 80。无侧栏时 `S=0`、无分隔线、`M=W`。不提供拖拽改宽度。

SessionStatus 固定在底部，占全宽 1 行。其上 WorkArea 高 `H−1`；MainPane 和 Sidebar 顶底对齐。Composer、TaskRail 只占主列。Sidebar 标题 1 行，内容视口 `H−2` 行，左右边距各 1 列，不再加完整外框。

标准主区条件为 `M≥80` 且 `H≥24`，水平边距 2 列。其他非极小尺寸使用 1 列边距。Composer 按主列宽换行；标准 1–8 行，紧凑 1–4 行，超出时光标跟随内部滚动。提示符宽 2 列，续行正文对齐。

|区域|期望高度（含 chrome）|空状态|
|---|---|---|
|Transcript|主列剩余高度；H≥24 保底 6 行，否则保底 3 行|开始提示，不画空工具框|
|TaskOverview|0–5 行|无目标、无任务时 0 行|
|PromptQueue|0–2 行|0 行|
|Todo|0–6 行|0 行|
|SubagentStrip|0–4 行|0 行|
|Aside|0–min(8,floor(H/3)) 行|未提供能力或未打开时 0 行|
|ActivityLine / TaskRail|各 1 行|保留行高，不因忙闲挤动输入|
|Composer|标准 1–8 行；紧凑 1–4 行|1 行|
|SessionStatus|全宽固定 1 行|保留适用操作提示|

ContextStack 只包含有效位置在主区的组件，子项直接相接。主列高度不足时，按 TaskOverview、Todo、SubagentStrip、Aside、PromptQueue 的顺序将非空组件压至 1 行；每一步达到 Transcript 下限即停止。仍不足才减少 Composer，最低 1 行。非极小模式满足 `Transcript + 主区辅助组件 + ActivityLine + TaskRail + Composer + SessionStatus = H`。

侧栏组件按上表高度上限排列，非空兄弟间隔 1 行。总高度超过 `H−2` 时只滚动侧栏，不挤压主列。标题固定；滚动范围为 `0..max(0,内容高度−视口高度)`。无内容时聚合空态占 1 行。

`W<120` 或 `H<18` 时，所有侧栏组件暂回 ContextStack，按固定顺序与未选组件合并，不重复挂载。偏好不变；达到阈值后自动迁回。迁移不清草稿、不重置任务、不发请求。

极小模式为 `W<40` 或 `H<12`：不显示侧栏；只保留 1 行 Composer、当 `H≥2` 时 1 行合并状态，其余给 Transcript。辅助组件仅以摘要计数进入合并状态。`H=1` 时只显示输入；边距为 0；`W<3` 时省略提示符。任一维度为 0 时不绘制。无法完整检查授权对象与选项时，不可确认授权。

Resize、配置应用和迁移按组件身份保留阅读锚点、展开选择、草稿和逻辑光标。侧栏消失且焦点在其中时返回 Composer；侧栏出现不自动夺焦点。

以下文字线框是目标示意，不是运行截图。共同输入为默认 Task/Todo/Subagents 侧栏，Composer 1 行；Task/Queue/Todo/Subagents/Aside 期望高度为 5/2/6/3/8。假设 Aside 能力可用，仅为几何说明。固定行数是 Activity、TaskRail、SessionStatus 之和；侧栏与主列平行占用空间，不纵向相加。

```text
宽屏 120×36（示意）
┌──────────────────────── 主列 M=87 ───────────────────────┬─ Sidebar S=32 ─┐
│ Transcript                                               │ TaskOverview  │
│                                                         │ TODO          │
│                                                         │ Subagents     │
│ ActivityLine                                             │               │
│ TaskRail                                                 │               │
│ Composer                                                 │               │
├─────────────────────────────────────────────────────────┴───────────────┤
│ SessionStatus (全宽 1 行)                                               │
└─────────────────────────────────────────────────────────────────────────┘

窄屏 119×24（示意，偏好仍保留）
┌────────────────────────── 主列 M=119 ────────────────────────────────┐
│ Transcript                                                           │
│ ContextStack: Task → Queue → TODO → Subagents → Aside                 │
│ ActivityLine · TaskRail                                                │
│ Composer                                                              │
├───────────────────────────────────────────────────────────────────────┤
│ SessionStatus (全宽 1 行)                                             │
└───────────────────────────────────────────────────────────────────────┘
```

|尺寸|主列|侧栏|Transcript|主区 Task/Q/Todo/Sub/Aside|输入|固定行|侧栏内容/视口|
|---|---:|---:|---:|---|---:|---:|---:|
|160×36|119|40|22|0/2/0/0/8|1|3|16/34|
|120×36|87|32|22|0/2/0/0/8|1|3|16/34|
|120×24|87|32|10|0/2/0/0/8|1|3|16/22|
|119×24|119|0|7|1/2/1/1/8|1|3|0/0|
|80×24|80|0|7|1/2/1/1/8|1|3|0/0|
|120×18|87|32|6|0/2/0/0/6|1|3|16/16|
|120×17|120|0|3|1/2/1/1/5|1|3|0/0|
|60×18|60|0|3|1/2/1/1/6|1|3|0/0|
|40×12|40|0|3|1/1/1/1/1|1|3|0/0|
|20×8|20|0|6|0/0/0/0/0|1|1|0/0|

120×36 全部取消选择时为单列：Transcript 8 行、辅助区 5/2/6/3/8 行、Composer 1 行、固定 3 行。120×18 全部选择且 Subagents 需求 4 行、输入 40 个视觉行时：Transcript 11 行、Composer 4 行、固定 3 行；侧栏内容 27 行、视口 16 行，侧栏独立滚动。它们是同一算法的不同输入。

**可观察验收：**逐项调整终端尺寸至上表及 119↔120 列、17↔18 行边界，确认列宽公式、行高和单宿主约束。将 40 行草稿在边界两侧 resize；窄屏时组件回主区，恢复尺寸后回侧栏，草稿与阅读锚点不变。

## 视觉层级与主题

### VIS-01：视觉使用低噪声层级

普通 assistant 正文不加完整边框。用户消息可用弱背景和文本身份区分。工具卡使用一层细线框，标题嵌入上沿；内部只在真实内容段间分隔，不再给每段套框。

Composer 不画左右边框或底框，只保留上方 TaskRail、提示符和正文。快捷提示放在 SessionStatus 可用空间，不增加永久帮助栏。同级 transcript 条目间隔 1 行；卡片内部不插额外空行。工具框左右各留 1 列。标题和脚注各 1 行，按内容优先级截短。

沿用 `ProductTheme` 的 `text`、`secondary`、`muted`、`accent`、`success`、`warning`、`danger`、`toolBorder` 等语义角色，不要求特定 RGB 或 OMP 原主题。正文、可操作提示和关键错误使用可读正文色。`muted` 只弱化计数、时间、装饰和历史辅助信息。

成功状态用状态词或小标记表达，不将整张卡片刷绿。失败、超时和待用户动作局部显著。焦点只强调所属控件，不与工具状态共用含义。默认背景沿用选定主题；透明背景或壁纸由终端和主题决定，不是验收依赖。等宽字体即可，不依赖 Nerd Font、emoji 或品牌图标。

### META-01：会话目标、当前动作和轮次统计分层

TurnSummary 属于已经结束的一轮。只显示确有来源的时间、token、耗时或速率；下一轮不得改写历史摘要。

TaskRail 显示整个会话任务名和可用汇总。工具调用不得把任务名改成工具名。布局为弹性细线、任务标题和右对齐指标；空间不足时先省可选指标，再截短标题。

ActivityLine 显示当前动作意图和 Esc 取消提示，例如“检查 SDK 约束”。没有明确意图时才显示 Running/Thinking 等阶段。Transcript 中的 Thinking 是 reasoning/执行阶段，不是第二个任务标题。

SessionStatus 显示模型、thinking/work mode、工作区、分支和输入快捷提示。空间不足时依次省 session/hash、分支细节、路径前缀，再缩短模型名；路径保留末段。不要补截图中出现但产品未提供的数据。缺失统计不显示伪造的 `0`；未知、未提供和数值零必须区分。统计带文字或单位，不能只靠图标。

侧栏与主列间只有一条细分隔线；摘要以标题和留白分组，不为每项加完整框。侧栏焦点通过所属标题/焦点标记呈现，不整列刷成执行状态色。ActivityLine 的取消提示带上下文：主输入聚焦时可写 Esc 取消；侧栏或布局页聚焦时写“主输入 Esc 取消”。本地退出提示由 SessionStatus 提供。

## Transcript 与工具卡

### CARD-01：工具卡统一表达动作与结果

工具卡顺序为：工具类别与状态、动作/对象标题、调用摘要、Output、Status/结果元信息。无数据时省略对应段，不显示空 Output 或捏造成功。

保留 `AGENT_CARD_RENDERER_REGISTRY` 的语义 presenter：Read 显示路径和内容，Edit 显示 diff，Shell 显示命令和 stdout/stderr。默认展示用户可理解的结果；仅缺少语义 presenter 时才将有界原始 JSON 作为详情。不得在卡片内外重复输出同一大对象。

### CARD-02：展开只恢复 UI 折叠的内容

紧凑预览最多显示 3 个输入视觉行和 6 个输出视觉行。展开正文视口最多 `max(1,min(20,transcriptHeight−5))` 行。短内容不填空行。卡片可超过 transcript 视口，但不得挤走底部 Composer。

UI 折叠提示中的省略行数，指当前宽度下已保留内容的视觉行数。源内容数量未知时不估算总行数。展开状态由用户控制；流式增量和完成事件不得改写展开/折叠选择。

三种事实必须区分：UI 折叠只隐藏已保留内容；preview truncated 表示 UI 只持有有界预览；source truncated 表示源输出已截断。展开只能恢复第一类，不能恢复后两类。仅在产品提供结果引用时显示入口或可复制标识；只有存在真实打开能力才显示可执行动作。没有引用时明确说明未提供完整结果，不编造路径、URL 或 `artifact://` 协议。

`failed`/`timed_out` 的紧凑视图保留失败类别、已有退出信息和真实可执行下一步。折叠不得把失败伪装成完成。取消、拒绝和超时是不同状态。

**可观察验收：**以 Read、Edit、Shell、未知工具和空输出检查语义结果与状态。用 60 行保留结果、preview 截断和 source 截断分别检查展开能力；没有真实引用时不出现完整结果链接。

## Task、TODO、子代理、队列与旁问

### 组件职责契约

|条款|契约|
|---|---|
|CTX-01|TaskOverview 与 TODO、子代理分离；只投影真实目标和非子代理任务事实。不得从 prompt 或 status 文案推断百分比、依赖图、完整任务数。最多 5 行：标题 1 行；有目标时目标/状态 1 行；其余列任务。超出时末行显示未列出数量。待用户/失败优先，其次运行、终态；同优先级保持首次顺序。子代理不重复计数。全部终态时压成真实状态摘要；未知不当完成；无内容为 0 行。TaskRail 保持会话任务锚点，不复制工具输出或 TurnSummary。|
|CTX-02|Aside 是条件组件，不新增 `/btw` 命令或后端。只有产品提供能力且面板打开时才显示；置于所属宿主栈尾，展示问题标题、有限回答和本地动作。无能力时无入口或空面板。后台结果不抢焦点。显式聚焦后 `c` 复制、`f` 带入后续编辑、Esc 关闭；主输入中的这些字母仍是文本。`f` 不提交；主稿非空时选择“替换草稿 / 取消”，默认取消，确认前不修改原稿。关闭恢复 Composer，不取消主请求。|
|CTX-03|SubagentStrip 独立停靠；同一宿主固定在 TODO 后、Aside 前。无子代理为 0 行；活动时标题 1 行、每个子代理 1 行，最多 4 行。超过 3 名时显示前两名及其余数量。待用户/异常优先，其次活动；同优先级按快照顺序。全部结束压成一行真实完成/失败计数。展示稳定身份、角色、状态和确有来源的短意图；不输出委派全文，也不猜模型或 currentAction。复用同一份 `TuiSubagentInfo`/事件投影。Alt+A/Ctrl+S 仍打开 Agent Hub；编辑器 Ctrl+S 保存优先。TaskRail 数量是同一快照的紧凑提示。|
|CTX-04|TaskOverview 表示当前会话目标/明确状态及已知非子代理后台任务，不新建任务数据库或调度器。只显示真实身份、短标题、状态和耗时。子代理 `jobType=task` 只进 SubagentStrip。失败、完成不污染其他任务；详情留在原卡片。无真实状态时显示未知或省略，不造进度。|

TODO 按现有 Markdown 复选项表达。存在阶段标题时按原顺序分组，展开含进行中项的阶段；无进行中项时展开首个含 blocked 或 pending 项的阶段。无阶段数据时平铺，不编造 phase。当前项亮于待办；已完成弱化但保留标记，删除线 MAY。全部完成压成一行摘要，不显示假动画。空间不足先保留当前阶段/任务，再显示真实计数。无 TODO 不占高度；编辑沿用 TodoController，不另建存储。

PromptQueue 区分 steer 与 follow-up，显示条数、简短文本和既有撤回/编辑提示。空队列为 0 行。停靠不改变请求顺序、类型或投递状态。

## 输入、键盘与焦点

### IN-01：输入保留发送、续写和补全语义

主输入保留现有语义。普通 Enter 先接受可见补全；否则空输入且选中卡片时切换卡片；其他情况下空闲时 send、运行时 steer。Ctrl+Enter 或 Ctrl+Q 在运行时 follow-up、空闲时正常 send；先关闭补全，不作为接受补全。Shift+Enter 或 Alt+Enter 插入换行。Tab 使用现有补全；Up/Down 按补全/Composer 既有编辑与历史逻辑，不导航工具卡。多行粘贴不自动发送。

Esc 先关闭补全；无补全且请求运行时请求取消并保留草稿；空闲时不退出。Ctrl+C 第一次清稿并提示再次退出，第二次退出；不得宣传为运行取消键。主输入为空时 Ctrl+D 退出，非空时不退出。

### IN-02：焦点决定事件归属且事件不穿透

|上下文|按键|目标行为|
|---|---|---|
|所有现有模式|Ctrl+L / Ctrl+Z / Ctrl+O / Ctrl+T|分别重置显示、挂起终端进程、切换工具输出、切换 reasoning 可见性；先于局部模式处理，不改变授权|
|主工作页，无更高模式占用|F2|打开 Layout 设置，保留草稿和返回焦点，不发请求、不取消运行|
|主工作页，无更高模式占用|F6|在主区与可见 Sidebar 间切换；返回时聚焦 Composer；不可见时不聚焦隐藏控件|
|布局设置|Up/Down、Space、Enter、Esc/Ctrl+C|选行、暂存、保存应用、放弃返回；不可用项不切换；保存失败留页且不丢稿|
|Sidebar|Tab/Shift+Tab、Up/Down、PageUp/PageDown、Home/End|按固定顺序聚焦非空组件并显示标题；滚 1 行、视口减 1 行、到顶/底，不滚 transcript|
|Sidebar 只读摘要|Esc/Ctrl+C、普通文字、Enter、粘贴|返回 Composer，不清稿/取消/退出；其他输入不写主稿、不提交，并提示 F6 返回|
|Sidebar 内|鼠标滚轮、点击|每格滚 3 行，边界不穿透主区；点击只聚焦，不执行任务或授权|
|主输入|Alt+Up|撤回最近尚未投递队列项并恢复编辑焦点，不创建重复请求|
|主输入为空|Alt+j/k、Alt+h/l、Alt+Space 或聚焦卡 Enter、Alt+y|导航卡片、收起/展开、切换、复制；普通 j/k/c/f/y 仍是文本|
|主区未聚焦侧栏|PageUp/PageDown|空输入且聚焦展开卡可滚时先滚卡体；卡不能继续滚才滚 transcript；一次按键不滚两处|
|Transcript|鼠标滚轮、点击卡片|滚 3 行；点击聚焦并切换卡片；鼠标悬停不触发隐式局部滚动|
|主区未聚焦侧栏|Ctrl+Home/Ctrl+End；空输入 Home/End|transcript 顶/底；首/末卡导航；空输入 End 同时恢复底部跟随；非空 Home/End 编辑文本|
|主界面|Alt+A 或 Ctrl+S|打开既有 Agent Hub；局部编辑器 Ctrl+S 保存优先|
|Ask 选择态|Up/Down 或 j/k、Space、Enter、Tab/Other、n、c、Esc/Ctrl+C|选择、多选、继续、自定义、备注、转 chat、取消 Ask；此处 c 不是 Aside 复制|
|Ask 编辑态|Esc、Ctrl+S、自定义输入 Enter|返回选择、保存、保存自定义回答；不改主稿|
|审批|方向键、Enter、Esc、Ctrl+C|选择产品实际提供项、提交、取消审批；保留现有第二次 Ctrl+C 退出语义|
|TODO/Plan 编辑态|Ctrl+S、Esc|保存、取消或返回；不触发 Hub 或取消无关请求|
|Plan Review|Tab/BackTab、方向键、Enter、Esc|切换 Actions/Body/TOC，阅读或决策，关闭审阅；提交中不重复提交|
|通用模态|Esc|关闭；Session 搜索有筛选时先清筛选，再关闭|

全局键之后的目标模式优先级为 Plan Review → TODO 编辑器 → Ask 编辑器 → Ask 选择态 → Agent Hub → 通用 modal（含布局设置）→ secret setup → approval。均未消费时，普通工作页依次处理 F2/F6、既有 Hub/撤回入口、显式聚焦 Aside 的 c/f/Esc、只读 Sidebar 输入，最后才是 Composer。消费事件不得穿透；侧栏聚焦时 Ctrl+Enter/Ctrl+Q 不提交隐藏草稿。F6 性能夹具的注入分支不代表产品焦点测试。

Ask 选择态粘贴进入现有 Other/custom 编辑器，不进入后台 Composer。审批只有已选择 Reject 时才把粘贴送入拒绝理由；其他选项下保留原稿并提示先选拒绝。这是目标差距，不是现状声明。

首次聚焦 Sidebar 时选中第一个非空组件；再次进入时恢复仍存在的组件身份。无非空组件时焦点停在容器。只读摘要 Enter 不执行动作。Aside 仅在显式聚焦时消费 c/f/Esc；其他导航由 Sidebar 处理。离开非提交模态时恢复草稿、光标和局部阅读位置。组件已移走或 Sidebar 隐藏时返回 Composer，不跳入其他任务。复制失败显示真实错误。

审批卡保留产品真实提供的权限、作用域和默认选项；不得照搬泛化 Allow session 示例。焦点、边框色、折叠状态和快捷键都不授予权限。侧栏组件变空时焦点留在容器，不转交给其他动作组件；下次 Tab 从首个非空组件开始。布局迁移将原侧栏组件移到主区时返回 Composer，不隐式编辑或提交。

**可观察验收：**分别在布局设置、侧栏、Ask、审批中输入 Esc、Enter、Ctrl+C、F2/F6，确认事件只由正确模式处理。确认侧栏粘贴不进入隐藏草稿，回到主输入不误触取消、授权或退出。布局编辑期间到达 Ask/审批时，未提交选择不应用；已提交保存回调不得覆盖决策界面。

## 滚动、流式更新与状态

### SCROLL-01：滚动锚点按视图隔离

Transcript、Sidebar、工具正文、Composer、文档/编辑器分别维护滚动状态。上滚后按条目身份和条目内偏移保留锚点，并显示新内容计数。新输出、spinner、统计变化和卡片完成不得跳回底部。主区 Ctrl+End 或空输入 End 才恢复 transcript 跟随；Sidebar Home/End 只改侧栏位置。

Resize、停靠迁移和卡片展开重新排版后保留同一内容位置，不以失效整屏行号定位。卡片折叠后再展开从正文起点开始；此动作不清除 transcript 未读计数。

**可观察验收：**主区上滚后到达延迟 chunk，再 F6 切侧栏并 PageDown，返回主区时两处锚点互不污染；侧栏边界不穿透，主区未读数保留，显式回底后才跟随。

### STATE-01：状态变化保留真实终态

|状态|表示与结束行为|
|---|---|
|pending / queued|明确待执行/排队；无执行 spinner，不造耗时|
|running / streaming|当前阶段、已有正文和意图；允许轻量动画；原位更新|
|awaiting user|明确等待内容、选项和范围；由原 Ask/审批控件接收输入|
|completed|真实完成标记；停止动画，保留结果及展开选择|
|failed|显示可读错误类别、已有原因和恢复入口；错误局部突出|
|timed out|明确超时，不混作普通失败；保留此前有效输出|
|cancelled|明确取消，不显示成功；保留部分输出，允许后续请求|
|rejected|明确拒绝，不混作取消；保留决策事实|
|expired|明确过期，不可确认旧决策；新决策只能来自产品新状态|

终态不得被迟到增量改回 running。成功必须有真实结束依据；超时、非法编码和不完整 EOF 不显示完成。取消发出后先显示 cancelling/取消中，收到结束事实才显示 cancelled。多条活动记录只更新各自状态；子代理完成不代表主请求完成。

约 80ms spinner 节奏可复用，但动画不得改变标题宽度、重排卡片或刷新历史。输入和正文无需等待 spinner。空闲时不显示假 Thinking。没有错误详情时只显示产品提供的类别和状态，不造原因、引用或重试按钮。任何展示状态都不改执行授权、网络权限或请求所有权。

### STREAM-01：流式内容按身份原位更新

每个流式回答或工具按既有身份原位更新，不按 chunk 新建卡。Reasoning 只显示产品允许展示的事件，不推导隐藏推理。主任务、子代理和工具更新不互相冒充所有者。

**可观察验收：**使用确定性本地 SSE，发送多个延迟 chunk 并改变字节边界；正文逐步出现，身份稳定。EOF 缺少终止事件时显示不完整错误，不显示完成。检查实际 stream 日志与用户可见增量，不能只检查最终文本。

## 信息安全与终端适配

### SAFE-01：不可信输出不得控制终端或泄露敏感内容

工具结果按不可信内容显示。不得执行结果中的终端控制序列来清屏、改标题或操作剪贴板。预览、展开、复制、错误卡和回放遵守同一产品脱敏规则。

规范示例与验收夹具使用 `<workspace>`、`src/example.cj`、`example.test` 等合成标识；不得复制本机用户名、项目路径、主机信息或会话数据。

**可观察验收：**将敏感标记和恶意终端控制字符经主区及侧栏的预览、展开、复制路径输入；两种宿主均执行相同脱敏，且不产生终端副作用。

### A11Y-01：无颜色和窄屏下仍可操作

支持中文、组合字符、宽字符及跨 SSE chunk 的字符边界。截断、换行和光标按字素/显示列处理，不按字节切出乱码。Provider 流的非法 UTF-8 显示真实解码错误类别，保留此前有效文本，将本轮标为失败；TUI 不崩溃，后续请求可继续。合法 UTF-8 恰好跨 chunk 不算错误。

NO_COLOR、16 色、256 色和纯 ASCII 下，状态仍以文字和结构区分。关键动作不得只靠颜色或图标。不能据截图弱化可操作文字或诊断的对比度。核心发送、取消、展开、阅读和审批流程必须可用键盘。

终端不支持组合键、鼠标或 resize 测试时，记录限制，不声称覆盖。

**可观察验收：**在 NO_COLOR/ASCII 与宽字符场景检查状态及键盘流程；注入非法 UTF-8 后确认有效前缀保留、本轮失败、程序可接收下一请求。授权对象或选项无法完整检查时不能确认。

## 验收矩阵

矩阵定义目标结果，不表示本次已运行产品验收。

|条款|输入和操作|目标可观察结果|
|---|---|---|
|LAY-01|120×36 空会话，再出现 TODO、两个子代理、主任务和工具输出|默认 Task/TODO/Subagents 在侧栏；队列和输入在主列；工具正文只在 transcript；组件各挂载一次，数据变化不反复改列宽|
|LAY-02|尺寸表、119↔120 列、17↔18 行、40 行草稿往返 resize|公式和行高正确；窄屏回流、恢复偏好停靠；草稿与锚点保留，焦点不留在隐藏区|
|LAY-03|草稿“保留草稿”；F2、Down、Down、Space、Enter|仅 TODO 移回主区；无新 Provider 请求；重复序列恢复停靠|
|LAY-03|全不选后重启；窄屏保存组合后扩大终端|单列和用户偏好持久；窄屏有效位置不覆盖偏好|
|LAY-03|勾选后 Esc、保存失败、无偏好、Aside 不可用|取消/失败无半布局，真实错误可见可重试；默认三项；无能力不能启用 Aside|
|VIS-01|普通消息、成功/失败工具和侧栏并列；切单色|Composer 无完整框；工具单层框；侧栏单分隔线；焦点与状态可分，成功不整片着色|
|META-01|连续两次工具调用，同时后台任务更新|TaskRail 保持会话目标；ActivityLine 随当前动作变；TurnSummary 不重写；不造统计|
|CARD-01|Read、Edit、Shell、未知工具、空输出|语义结果可读，空段省略，未知详情有界安全；侧栏不复制输出|
|CARD-02|60 行保留结果、preview 截断、source 截断|展开仅恢复保留数据；分别说明限制；无假完整链接|
|CTX-01|两阶段任务、steer/follow-up、迁移 TODO/队列|阶段与队列含义不变；顺序和状态不变；不重复数据|
|CTX-02|Aside 不可用；有能力时后台结果到达且主稿非空|无能力时无入口；不抢焦点；f 不提交或覆盖草稿；关闭不取消主请求|
|CTX-03|子代理从 2 增至 5，更新后全部结束；只迁移 Subagents|身份更新、溢出计数、终态无动画；其他组件和主稿不变|
|CTX-04|主任务、非 task 后台 JobStatus、task 子代理；后台失败、子代理完成|TaskOverview 只含主任务与非子代理任务；子代理只计 Subagents；状态不污染其他任务|
|IN-01|多行粘贴、中文、组合字符、运行中 Enter/Ctrl+Enter|粘贴不发送；光标正确；steer/follow-up 区分|
|IN-02|布局、侧栏、Ask、审批中 Esc/Enter/Ctrl+C/F2/F6|事件只由正确模式消费；粘贴不入隐藏稿；返回输入不误触取消、授权或退出|
|IN-02|保存中收到 Ask/审批；随后保存回调；聚焦组件变空|未提交选择不应用；回调不盖决策；焦点不转给有副作用组件|
|SCROLL-01|主区上滚后延迟 chunk，F6、侧栏 PageDown，再回主区|两锚点独立；边界不穿透；主区未读保留，显式回底才跟随|
|STATE-01|成功、失败、拒绝、超时、取消、迟到增量；取消后再请求|终态不倒退；不同记录互不污染；后续真实请求可继续|
|STREAM-01|确定性 SSE，多延迟 chunk、边界变化、EOF 缺终止|正文增量可见、身份稳定；不完整结果不显示成功|
|SAFE-01|敏感标记和恶意控制字符经两宿主预览/展开/复制|脱敏一致；无终端副作用|
|A11Y-01|NO_COLOR、ASCII、宽字符、窄屏、非法 UTF-8|状态可辨、无乱码崩溃；键盘可操作；授权对象不完整时不可确认|

## 现状映射与证据边界

下表区分截图观察、源码现状和设计目标。源码路径及符号是定位提示；实现以源码行为为准。目标不得因已有测试通过而视为完成。

|目标|已确认现状|规范处理|
|---|---|---|
|可配置侧栏与用户偏好|普通根布局为固定纵向区；Settings 无 Layout；未核实布局保存 API|Layout、F2/F6、持久化和响应式迁移均为目标|
|TaskOverview|已有 taskLabel、JobStatus/SubagentStatus 与后台卡片；`jobType=task` 指子代理|复用事实投影；会话目标稳定性及独立摘要是目标|
|轻量 Composer、TaskRail、SessionStatus|`agent_tui/src/tui.cj` 约 5735 行及 `tui_chrome.cj` 当前采用完整输入框和混合 header|目标布局，不称为现有外观|
|统一工具卡外框|`productTranscriptCardTheme` 仅 Shell 使用 fullFrame；其他工具主要使用 rail|复用 registry presenter；统一外框是目标|
|TODO 阶段树|`TodoController` 当前扁平提取 Markdown 复选项，并按活跃状态优先选取少量项|阶段分组/展开是目标，不宣称已有 phase 字段|
|SubagentStrip|`TuiSubagentInfo` 和 Agent Hub 已有；普通根布局无独立区|复用身份、角色、状态和子会话；独立摘要是目标，不猜模型/意图字段|
|Aside|本仓库 slash 清单与检索未见 `/btw`|条件表示规范；不新增后端或把 Ask 当旁问|
|焦点隔离|键路由已按模式处理；Ask 选择态粘贴目前落入主输入|将粘贴归属列为目标差距；F2/F6 是新增目标|
|截断层次|`boundedTerminalPreview`、source/preview truncated 和条件 artifact metadata 已有|不承诺展开可找回所有源数据|
|视觉与窄屏验收|真 PTY runner 主要断言可见文本；headless/gallery 不是实际终端视觉基线|目标边框、区域和颜色需后续真实 PTY 证据|

源码定位：`agent_tui/src/tui_contracts.cj` 中 `TuiSubagentInfo` 只有 `id`、`agent`、`status`、`task`；`AgentTuiBackend` 提供 subagents/focusSubagent/subagentTranscript/focusMain。`agent_tui/src/todo_controller.cj` 的 `parseTodoItems` 扁平提取复选项；`todoRowCount` 窄屏最多 2 项、宽屏最多 5 项。`agent_tui/src/tui.cj` 的 `AgentScreen.render` 当前顺序是 transcript、activity、queue、todo、composer，并使用 `VirtualTranscriptView`、局部脏区和底部跟随。`tui_chrome.cj` 的 `composerMaximumHeight` 当前最多 8 行；header 把任务、模型、工作区、分支与 token/status 混在一行。

`productTranscriptStatus` 区分等待、运行、成功、失败、超时、过期、取消和拒绝；`productTranscriptCardTheme` 仅 Shell 使用 fullFrame。`shellToolMetadata` 仅在结果提供 `artifact` 或 `artifact_id` 时显示引用。`AGENT_CARD_RENDERER_REGISTRY` 已区分 Shell、Read、Edit、Search、HTTP、MCP、Permission、Ask。`boundedTerminalPreview` 有界保存有效 UTF-8 前缀；`tuiToolCompletionFooter` 区分 source 与 preview 截断。`ProductTheme` 提供语义角色及 NO_COLOR、16/256/truecolor 适配；内置默认主题使用不透明深色背景，因此本文不把透明背景当现状。

`AgentScreen` 的 Settings 当前有 Model、Theme、Session、Archive/reset、Close；无 Layout 分支。`selectTheme` 通过 backend 和 ThemeSelected 处理配置变更；本文只复用配置职责边界，不声称已有布局偏好 API。F6 在 `tui.cj` 的 `tuiPtyPerformanceFixtureRequested` 模式注入测试文本；这是夹具行为，不是正常焦点键。所查 `agent_tui` 源码没有 F2 分支。JobStatus 的 `task` 类型显示 Subagent，其他类型显示 Background；`taskLabel` 会在 submitPrompt 和 steer InputInjected 时更新，不能据此声称它已是稳定 TaskOverview。

仓库文档 [`tui-card-inventory.md`](tui-card-inventory.md) 说明工具卡职责与验证；[`themes.md`](themes.md) 说明主题。两者不是完整 UI/UX 规范。截图不能证明像素尺寸到终端行列的换算，也不能确定 RGB 或终端宿主。

既有路径矩阵只读校验曾输出 `matrix valid cases=50 paths=43 scenarios=30 tests=30`；该结果仅证明矩阵格式和引用，不证明场景运行成功。当前可以用以下命令复核格式与 case 清单；它们不运行产品：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 support_tests/tui_path_coverage/check.py --validate-matrix
PYTHONDONTWRITEBYTECODE=1 python3 support_tests/tui_path_coverage/check.py --list
```

本规范没有执行真实 UI、Provider、MCP、SDK 或写配置的 gate。产品实现后的真实 PTY 验收应在磁盘支持的任务私有目录运行；先确认 `$HOME/.cache` 有空间且不是 tmpfs，再创建权限为 0700 的独立目录并设置 `TMPDIR`、`TMP`、`TEMP`。候选二进制必须是绝对路径，输出目录必须为空，不能用 fixture、HEADLESS 或 gallery 替代真实 TUI。

```sh
install -d -m 0700 "$HOME/.cache/agent-tmp"
RUN_DIR="$(mktemp -d "$HOME/.cache/agent-tmp/tui-ux.XXXXXX")"
chmod 0700 "$RUN_DIR"
export TMPDIR="$RUN_DIR" TMP="$RUN_DIR" TEMP="$RUN_DIR"
AXYNDRA_SDK_ROOT="$HOME/cangjie_sdk/daily" scripts/pinned_cangjie \
  python3 support_tests/tui_path_coverage/check.py \
  --candidate "$PWD/target/release/bin/agent_app" \
  --output "$RUN_DIR/evidence" \
  --case T003/editor-paste \
  --case T005/overlay-routing \
  --case T006/queue-race \
  --case T008/navigation-resize \
  --case T013/hub-subagents \
  --case T018/chat-rich \
  --case T019/provider-errors \
  --case T021/tool-loop-cancel \
  --case T023/mcp-stdio \
  --case T025/renderer-boundaries
```

该命令仅供 UI 实现后验收，本次不得运行。前提包括仓库根目录、Python 3、tmux、当前源码构建的 `target/release/bin/agent_app`、STS SDK 与原生依赖。`scripts/pinned_cangjie` 会准备原生依赖并复制网络桥；文档只读校验不应执行它。

真实 PTY 证据应保留 `input.jsonl`、原始 `terminal.ansi`、`screens/*.ansi`、`screens/*.txt`、`timeline.jsonl`、Provider 的 `requests.jsonl`/`stream.jsonl`、MCP 的 `mcp.jsonl`、`assertions.json` 和 `exit.json`。必须以退出码 0 正常退出，并验证取消后第二个真实请求收到响应；强制清理进程不是通过证据。只对实际运行的 case 声称 Provider/MCP 行为。分享证据前归一化路径和本地服务地址，原始证据留在任务私有目录。

已有命令只覆盖既有行为，不能代替 LAY-02 双列/回流、LAY-03 偏好保存、CTX-03 子代理和 CTX-04 TaskOverview 验收。新增真实 PTY 场景须保留设置键序列、存储成功/失败、重启、两区滚动与阈值 resize 的证据；不得伪造 case 名。

已知覆盖缺口：

- `T007/esc-cancel-recovery` 检查恢复和迟到文本未出现，但有效 handler 未调用 `normal_exit`，也未断言 `provider_disconnect`。不能据其 PASS 声称远端确认取消且正常退出。命令中的 `T021/tool-loop-cancel` 可证明工具取消后恢复，但不自动证明 Provider 端确认取消。
- 有效 `run_rich_stream` 是后定义函数。T018 fixture 配置分块和延迟，但最终 handler 未断言实际 `wire_chunk_size`；旧同名函数的断言不代表当前覆盖。STREAM-01 需检查真实 stream 日志与可见增量。
- `T008/navigation-resize` 现有 PTY 尺寸为 120×36 和 80×24；60×18、40×12、20×8 尚无已运行证据。
- `scripts/tui_golden_gate.py` 使用 headless；gallery 是静态卡片；showcase 是取证生成器；PTY perf 是性能证据。它们不能代替新布局真实 PTY 的区域、ANSI/属性、焦点和滚动验收。
- 待用户交互、超时、不完整 EOF、非法 UTF-8、窄屏优先级、子代理并发和完整输出可达性需要各自断言。输入处理器模拟或单张最终截图不足以验收过程。

目标验收仍未执行。真实 Provider/MCP 场景需使用确定性本地 SSE fixture，不使用用户账户。鼠标、resize 等终端能力若 PTY harness 不支持，必须记录限制。