package agent_core_contract

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_ports.*
import tool_runtime.*
import yjson.*
import yjson_support.*

class HookContextCapture240 {
    var beforeContext: ?ToolInvocationContext = None<ToolInvocationContext>
    var afterContext: ?ToolInvocationContext = None<ToolInvocationContext>
    var retained: ?ToolInvocationContext = None<ToolInvocationContext>
    let retainChild: Bool
    let throwBefore: Bool
    init(retainChild: Bool, throwBefore: Bool) { this.retainChild = retainChild; this.throwBefore = throwBefore }
    func before(context: ToolInvocationContext): CoreToolHookDecision {
        beforeContext = Some(context)
        if (retainChild) { retained = Some(context.retainInvocationContext159()) }
        if (throwBefore) { throw IllegalStateException("scoped hook fixture") }
        CoreToolHookDecision.Continue
    }
    func after(context: ToolInvocationContext): Unit { afterContext = Some(context) }
}
class ScopedCaptureHooks240 <: ScopedCoreToolHookRuntime240 {
    let capture: HookContextCapture240
    init(capture: HookContextCapture240) { this.capture = capture }
    public func beforeTool(context: ToolInvocationContext, _: CommittedToolCallRef,
        _: AgentValue): CoreToolHookDecision { capture.before(context) }
    public func afterTool(context: ToolInvocationContext, _: CommittedToolCallRef,
        _: CoreToolHookPostEvent): Unit { capture.after(context) }
}
class LegacyCaptureHooks240 <: CoreToolHookRuntime {
    let capture: HookContextCapture240
    init(capture: HookContextCapture240) { this.capture = capture }
    public func beforeTool(context: ToolInvocationContext, _: CommittedToolCallRef,
        _: AgentValue): CoreToolHookDecision { capture.before(context) }
    public func afterTool(context: ToolInvocationContext, _: CommittedToolCallRef,
        _: CoreToolHookPostEvent): Unit { capture.after(context) }
}
func hookContextClosed240(context: ToolInvocationContext): Bool {
    try { context.requireLiveInvocationView159(); false }
    catch (_: IllegalStateException) { true }
}
func retainedHookCallerFrame240(context: ToolInvocationContext): Bool {
    context.requireLiveInvocationView159()
    context.runId.value == "scoped-hook-retained" && context.epoch > 0 && context.hasOwnedToolSetSnapshot159()
}
func runHookContextCase240(scoped: Bool, retainChild: Bool, throwBefore: Bool, id: String): Unit {
    let capture = HookContextCapture240(retainChild, throwBefore)
    let hooks: CoreToolHookRuntime = if (scoped) { ScopedCaptureHooks240(capture) } else { LegacyCaptureHooks240(capture) }
    // This catalog's real private bank pays snapshot DATA. The existing model
    // fixture retains its requests, so this case makes no whole-frame refund
    // claim. No Native/SQLite/Source or fabricated return witness is supplied.
    let catalog = planBatchReadCatalog204()
    let echo = EchoTool()
    expect(catalog.register(ToolDescriptor(ModelToolDefinition("echo", "echo", objectValue([])),
        Capability(CapabilityKind.WorkspaceRead)), echo).isOk(), "hook context fixture registers its actual Tool")
    let runs = MemoryRuns()
    let core = AgentCore(TwoStepModel(), runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()), catalog, toolHooks: hooks)
    let result = core.start(AgentRunRequest(RunId(id), SessionId(id), "fixture", "exercise actual Core hooks",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])))
    expect(result.isOk(), "ordinary Core loop still completes after scoped hook handling")
    expect(echo.executions == (if (throwBefore) { 0 } else { 1 }), "throwing hook still denies Tool execution")
    expect(capture.beforeContext.isSome(), "actual Core before-hook callback ran")
    expect(hookContextClosed240(capture.beforeContext.getOrThrow()) == scoped,
        "only opt-in Core before-hook Context is revoked after its complete callback")
    if (!throwBefore) {
        expect(capture.afterContext.isSome(), "actual Core after-hook callback ran")
        expect(hookContextClosed240(capture.afterContext.getOrThrow()) == scoped,
            "only opt-in Core after-hook Context is revoked after its complete callback")
    }
    match (capture.retained) {
        case Some(value) =>
            let live = retainedHookCallerFrame240(value)
            value.returnOwnedToolSetFrame159()
            expect(live, "actual retained hook Context remains independently paid and usable after Core callback return")
        case None => ()
    }
}
func scopedCoreHookContextContract240(): Unit {
    runHookContextCase240(false, false, false, "legacy-hook-context")
    runHookContextCase240(true, true, false, "scoped-hook-retained")
    runHookContextCase240(true, false, true, "scoped-hook-throw")
    let legacyInvoice = runTypedHookFailureCase240(false)
    let scopedInvoice = runTypedHookFailureCase240(true)
    // Numeric evidence only, not a retirement assertion: a scoped hook cannot
    // certify the other open Pipeline consumers of the private Context.
    println("typed failure retained-custody invoice legacy=" + legacyInvoice.toString() + " scoped=" + scopedInvoice.toString())
    opaquePolicyContextFailureContract240()
    println("actual Core scoped hook Context contract passed; legacy inputs remain open")
}

// A real finite synchronous provider. Its private consumer returns before the
// framework records input return; the original Run/Future witness remains Core's.
// This fixture stores no request or event callback and invents no task witness.
class TypedHookFailureModel240 <: ModelPort & ReturningModelInputPort159 & ReturningModelTranscriptPort159 {
    var calls: Int64 = 0
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        executeFrame240(request, events)
    }
    public func executeReturningInput159(request: ModelRequest, events: ModelEventSink,
        _: ModelInputDataBudget159): ModelInputReturn159 {
        let result = executeFrame240(request, events)
        ModelInputReturn159.Returned(result)
    }
    public func transcriptSnapshotReturning159(request: ModelRequest, loan: ModelInputToolsBorrow159): ?String {
        let result = noTranscriptFrame240(request)
        loan.returnModelToolsFrame159()
        result
    }
    private func noTranscriptFrame240(_: ModelRequest): ?String { None }
    private func executeFrame240(_: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls++
        if (calls == 1) {
            events(ModelEvent.Completed)
            return Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.ToolCall, callId: "typed-hook-call",
                name: "echo", arguments: objectValue([ValueField("text", textValue("hello"))]))]))
        }
        Result.Err(AgentError(AgentErrorKind.Protocol, "fixture.typed_hook_failure", "finite typed model failure"))
    }
}
func runTypedHookFailureCase240(scoped: Bool): Int64 {
    let capture = HookContextCapture240(false, false)
    let hooks: CoreToolHookRuntime = if (scoped) { ScopedCaptureHooks240(capture) } else { LegacyCaptureHooks240(capture) }
    let paid = PlanBatchReadPayment204()
    let catalog = ToolCatalog()
    catalog.registerBatch([ToolCatalogRegistration(ToolDescriptor(ModelToolDefinition("echo", "echo", objectValue([])),
        Capability(CapabilityKind.WorkspaceRead)), EchoTool())], dataPayment: Some(paid)).value().getOrThrow()
    let model = TypedHookFailureModel240()
    let core = AgentCore(model, MemoryRuns(),
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()), catalog, toolHooks: hooks)
    let result = core.start(AgentRunRequest(RunId("typed-hook-failure"), SessionId("typed-hook-failure"),
        "fixture", "fail after the real Tool hook", capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])))
    expect(model.calls == 2 && result.isError() && result.error().getOrThrow().code == "fixture.typed_hook_failure",
        "both Core variants reach the same actual typed failure after their Tool hook")
    core.collectReturnedModelInputs159()
    expect(capture.beforeContext.isSome() && hookContextClosed240(capture.beforeContext.getOrThrow()) == scoped,
        "failure preserves the same legacy versus scoped callback lifetime")
    // Exact original-custody numeric DATA only. Prepared/raw copies stay paid
    // in both variants; the assertion never expects an empty bank or Source ACK.
    paid.currentInvoice240()
}

// This legacy public policy has not opted into scoped inputs. It delegates
// every decision to the same real default policy and retains only its actual
// Context input. It grants no capability or execution authority of its own.
class CapturingCapabilityPolicy240 <: CapabilityPolicy {
    private let actual = DefaultCapabilityPolicy()
    var captured: ?ToolInvocationContext = None<ToolInvocationContext>
    public func evaluate(context: ToolInvocationContext, plan: NormalizedOperationPlan): PolicyDecision {
        if (captured.isNone()) { captured = Some(context) }
        actual.evaluate(context, plan)
    }
}
func opaquePolicyContextFailureContract240(): Unit {
    let paid = PlanBatchReadPayment204(); let catalog = ToolCatalog()
    catalog.registerBatch([ToolCatalogRegistration(ToolDescriptor(ModelToolDefinition("echo", "echo", objectValue([])),
        Capability(CapabilityKind.WorkspaceRead)), EchoTool())], dataPayment: Some(paid)).value().getOrThrow()
    let policy = CapturingCapabilityPolicy240()
    let capture = HookContextCapture240(false, false)
    let core = AgentCore(TypedHookFailureModel240(), MemoryRuns(),
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds(), policy: policy),
        catalog, toolHooks: ScopedCaptureHooks240(capture))
    let result = core.start(AgentRunRequest(RunId("opaque-policy-failure"), SessionId("opaque-policy-failure"),
        "fixture", "preserve the actual legacy policy consumer", capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])))
    expect(result.isError() && result.error().getOrThrow().code == "fixture.typed_hook_failure",
        "opaque policy control reaches the original typed failure")
    core.collectReturnedModelInputs159()
    expect(policy.captured.isSome() && !hookContextClosed240(policy.captured.getOrThrow()),
        "scoped hooks cannot acknowledge or revoke an unknown legacy policy Context consumer")
    expect(policy.captured.getOrThrow().hasOwnedToolSetSnapshot159(),
        "the real legacy policy consumer still retains its independently paid snapshot data")
}
