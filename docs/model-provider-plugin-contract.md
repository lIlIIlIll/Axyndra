# Typed ModelProvider boundary and installed adapters

The host boundary behind `ModelPort` now executes installed ModelProvider contributions. The independent `plugins/model_providers` package supplies OpenAI Chat Completions, OpenAI Responses and Anthropic Messages adapters using the existing wire implementations. Production model execution uses `ProductInstalledModelPort`, a wrapper of `HostInstalledModelPort`. Every model requires an explicit installed contribution mapping and current operator grant. Unmapped models are rejected; the normal missing-mapping diagnostic is `model.provider_not_configured`, while existing legacy-configuration diagnostics are preserved; missing, disabled or invalid mapped contributions also fail without a static provider fallback. `FixtureModelPort` is selected only by the explicit test fixture configuration. This source boundary does not establish complete A6 acceptance.

## Authority and persistence

Core still creates, claims, cancels, retries and terminalizes the unique model Attempt, records usage, and commits the validated Decision. Provider execution never creates a ToolCall, Operation, HostService or second Attempt. `modelRequestSnapshotValue` and its decoder move the existing provider-neutral checkpoint codec into Domain without changing its v1 fields or semantic digest. The hard transport deadline remains in the separate wire-policy digest.

`HostModelProviderDispatchGate` implements the generic dispatch boundary used by installed production selection; the package-private `ProductModelProviderDispatchGate` is a composition adapter. It reads the real claimed Attempt, active Thread/Turn/Run and epoch, exact input/policy/transcript, and sealed continuation; it also requires the host's current operator grant callback and grant cancellation token. These are independent checks: durable facts do not authorize network or secrets. Request/Attempt tombstones prevent repeat dispatch in the same instance. The trusted host can implement ports, so public DTO constructors are not a sandbox or proof against arbitrary host code; IPC can neither construct nor replace the actual Product gate.

The gate links the real Run cancellation token and operator revocation to the native process abort path. Checks run before launch, writes and each bounded read/frame. A late success after cancellation/revocation is rejected. Failed cleanup retains the channel owner for explicit `retryCleanup`; it is not a successful release. The factory must retain failed-launch resources and return only bounded actual cleanup acknowledgements, as existing process owners do.

## Protocol

Host sends a pure `hello` containing schema `axyndra.model-provider/v1` and the frozen binding digest. The worker must return exact `ready`. Host then sends `execute` with the neutral request, fixed binding, timeout, and exact Attempt/Run/Thread/epoch/request/binding/input identity. Frames have the same identity, a strictly increasing sequence, kind `event`, `usage`, `reply` or `failure`, and a typed payload. The final transport `done` does not substitute for a valid model reply. The worker may request only the bounded model HTTP open/head/read/close interface bound to this captured actual dispatch. It cannot select another Attempt or obtain a generic Tool/Service callback or retry control.

The binding freezes package/configuration/instance/contribution/provider/model identity, capability snapshot, feature support, nonsecret configuration and opaque credential references. Snapshot construction and validation have zero plugin or grant calls and do not resolve credentials. Capability discovery cannot authorize execution.

Events preserve typed text, reasoning, tool-call progress, block boundaries and provider-terminal evidence. Replies preserve refusal/error/opaque replay blocks and structured output. Final tools must match declared tools and streamed IDs/arguments; parallel-call policy and partial text consistency are checked. Core remains the final Decision validator. EOF, duplicate/out-of-order identity, malformed usage or terminal drift never become a Decision or synthetic Completed event.

Usage includes input/output/reasoning/cache counts, optional cost, source and evidence. Overflow and invalid cache subsets reject. Unknown usage cannot claim known cost. On failure the observed typed counters/evidence enter Core's existing failure accounting; they do not invent a provider final or trigger a second retry policy.

Current explicit bounds: binding 64 KiB; neutral snapshot/execution input 64 MiB; individual returned frame 256 KiB; all process stdout plus stderr 64 MiB; at most 262144 frames, 4096 terminal blocks and 1024 streamed calls. Handshake is five seconds, subsequent work obeys the actual Core owner deadline and cancellation. Eight active/opening/cleanup-pending channels and 4096 consumed requests per port instance are hard bounds with no tombstone eviction. These limits are not claims of full legacy provider payload parity.

## Installed package, HTTP and integrity boundaries

The manifest declares typed ModelProvider contributions independently of tools. Selection freezes the exact namespace, package digest, instance, contribution and configuration. The existing `plugins/services.json` is the operator grant source. Each model mapping specifies its exact contribution, wire model and nonsecret configuration; network requests and credential references also require their existing exact destination/method grants. Installation and capability metadata grant no network or secret access.

The worker runs under Denied network with its installed package. Worker and HTTP resources have distinct typed ModelAttempt owners verified by the actual Product dispatch gate. Credential resolution occurs only after the real Attempt dispatch claim. The private host launcher injects the selected credential, and filters reflected credentials from headers, body and diagnostics. A bounded Retry-After projection does not expose arbitrary response headers. Large request bodies use a host-created immutable Artifact pinned to that actual Attempt, without a fabricated Operation or ToolCall.

Every live poll continues to validate current Run/Attempt ownership, cancellation, operator grant and the mutable request against its frozen policy. Installed package bytes are checked at actual launch, HTTP and terminal boundaries, including after cleanup ACK before successful completion. Store observation compares the complete snapshot and retained continuation payload as SQLite BLOBs, including embedded NUL bytes; changed bytes, digest, phase or owner trigger the existing full decoder and seal validation. The observation is private to a dispatch and is not a cached authorization decision.

An explicit operator payload profile negotiates the existing logical chunk/hash codec across bounded physical frames. The shared allocation budget remains held through consumer callbacks. The newer `reply_stream` terminal references ordered byte ranges and hashes from the same Attempt's observed text/reasoning, and verifies complete coverage before the normal reply and usage checks. This avoids retransmitting large streamed text; it does not create resource or replay authority. Zero or long provider timeouts retain actual Run cancellation, deadline, first-response/idle policies and cleanup ownership.

## Historical validation checkpoint

The recorded Model checkpoint compiled and enumerated **401** Product tests and actually executed **35 selected Model tests**, all passing without extending their original limits. It is not a full 401-test or repository-wide pass. The actual cases cover all three installed adapters through local HTTP and SQLite, a unique claimed Attempt without a Tool Operation, mapping and credential rejection, credential reflection, package changes before launch and during a stream, malformed/partial output, unknown usage, real cancellation, owned cleanup debt and ACK, immutable payload pins, and exact Store byte/phase/ownership checks.

The actual 300 KB request/reply case completed in 23.292 seconds inside its original 60-second test limit. The zero-hard-timeout large-request case retained its original 10-second wait for the HTTP boundary, then cancelled the real owner and required cleanup ACK. Per-case source, binary and package checks remained equal, and owned-process cleanup recorded zero survivors. Earlier failed attempts and diagnostic-only runs remain preserved separately.

Source inventory SHA-256: `3fea97f82980e9ea458aa093f63ac0de6d2064ac57baab527d66b51f42a9c1af`.
Actual Product binary: `816389eefb773cb6e21a6efb366c01abfe3231024ead8dce1ff957d8c238765a`.
Evidence: `model-observation-final-checkpoint-attempt-1/summary.json`, SHA-256 `c032aa76baad00ea99bdc4cd6322aeae7ad49c4e1bd9d859c9e1f82cd7c5ca1a`.
The same aggregate records the separately validated, unchanged dependency graphs for the independent package's **33/33** protocol checks and runtime's **15/15** unit checks. These earlier graphs are not substituted for execution of all later changes.

Subsequent Context, internal-model, compact-terminal and Domain JSON-codec changes have separate source inventories and validation records. In particular, the internal approval/compaction migration now records and claims a real internal Attempt before dispatch, but its new Product cases are outside the 35-case checkpoint above. Do not infer their success from that checkpoint. The official Product gate prepares an independently built package and requires the actual process/HTTP fixtures; absent fixtures fail rather than skip.

## Remaining A6 work

A6-01, A6-02 and A6-03 remain **Partial**. Production selection is installed-only, and static wire adapters belong to the independently packaged `plugins/model_providers` dependency graph. The earlier execution checkpoint above is historical; it is not validation of the current complete source tree. Legacy configuration conversion, independently installed restoration and current full-runtime acceptance still require evidence. The complete old transport capacity, image/opaque-state/structured-output matrix, public-provider behavior, performance and recovery across replaced instances are not established by the local fixtures. Snapshot restoration must preserve its exact frozen binding; a current grant cannot silently replace historical authority.

Model-free Product/Minimal composition, clean build and independently installed provider restoration remain required. Configuration conversion must preserve original files and history, require explicit credential choices where legacy fallback has no equivalent, and separate a proposed mapping from actual operator authorization. Internal approval/compaction paths must pass their own real Attempt, budget, cancellation and recovery cases before their migration is accepted. There is no synthetic Tool or HostService fallback for model execution.

## 通用 JSON 编解码归属

`encodeAgentValue` / `decodeAgentValue` 归 `agent_domain` 所有；持久化、CLI、RPC 和通用宿主服务通过领域层使用这些函数。原 `model_adapters` 导出已删除，使用包别名的调用方需要改成 `agent_domain` 的别名；这属于 issue #45 允许的代码接口切换。

JSON 字节、默认 1 MiB 解码上限、显式 `maxBytes` 参数，以及 `value.invalid_json` / `json_error_kind` 保持原实现。此改动不改写已有存储。`persistence_runtime`、Product、App 与 Minimal 的当前本地依赖图均已移除 `model_adapters` / `llm4cj`；这些专属 wire 依赖归独立的 `plugins/model_providers` 包。正常产品装配仅使用已安装的 Provider，未配置模型不会回退到旧实现。源码依赖分离仍不能代替当前 Minimal 的干净构建、独立安装恢复或完整 A6 验收。
