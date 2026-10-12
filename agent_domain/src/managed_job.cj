package agent_domain

import std.convert.*
import yjson.*
import yjson_support.*

// Descriptive host-frozen launch request. Neither decoding this value nor
// observing a completed parent Receipt creates a Runtime admission seal.
public class ManagedJobDeclaration {
    public let jobId: String
    public let threadId: ThreadId
    public let runId: RunId
    public let deadlineMillis: Int64
    public let maxToolCalls: Int64
    public init(jobId: String, threadId: ThreadId, runId: RunId,
        deadlineMillis: Int64, maxToolCalls: Int64) {
        if (!directOriginIdentifier(jobId, 128) || !directOriginIdentifier(threadId.value, 256) ||
            !directOriginIdentifier(runId.value, 256) || deadlineMillis < 1 || maxToolCalls < 1 || maxToolCalls > 8193) {
            throw IllegalArgumentException("managed job requires fixed bounded identity, deadline and tool budget")
        }
        this.jobId = jobId; this.threadId = threadId; this.runId = runId
        this.deadlineMillis = deadlineMillis; this.maxToolCalls = maxToolCalls
    }
}

public func managedJobDeclarationValue(value: ManagedJobDeclaration): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.managed-job/v1")),
        ValueField("job_id", textValue(value.jobId)), ValueField("thread_id", textValue(value.threadId.value)),
        ValueField("run_id", textValue(value.runId.value)), ValueField("deadline_ms", integerValue(value.deadlineMillis)),
        ValueField("max_tool_calls", integerValue(value.maxToolCalls))])
}

public func managedJobDeclarationFromValue(value: AgentValue): ManagedJobDeclaration {
    if (!httpIntentExactFields(value, ["schema", "job_id", "thread_id", "run_id", "deadline_ms", "max_tool_calls"]) ||
        httpIntentText(value, "schema") != "axyndra.managed-job/v1") {
        throw IllegalArgumentException("unsupported managed job launch declaration")
    }
    ManagedJobDeclaration(httpIntentText(value, "job_id"), ThreadId(httpIntentText(value, "thread_id")),
        RunId(httpIntentText(value, "run_id")), managedJobInteger(value, "deadline_ms"), managedJobInteger(value, "max_tool_calls"))
}

func managedJobInteger(value: AgentValue, field: String): Int64 {
    let raw = value.field(field).getOrThrow()
    if (raw.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("managed job budget must be an integer") }
    let parsed = Int64.parse(raw.asNumberText())
    if (parsed.toString() != raw.asNumberText()) { throw IllegalArgumentException("managed job budget must be canonical") }
    parsed
}

// The complete plan is bound by the Store codec digest, not its caller supplied
// bindingDigest. All fields here are scalar immutable copied data.
public class ManagedJobLaunchBinding {
    public let declaration: ManagedJobDeclaration
    public let parentThreadId: ThreadId
    public let parentRunId: RunId
    public let parentEpoch: Int64
    public let parentOperationId: OperationId
    public let parentItemId: ItemId
    public let parentCallId: String
    public let planDigest: String
    public let permissionDomain: String
    public let serviceBindingDigest: String
    public init(declaration: ManagedJobDeclaration, parentThreadId: ThreadId, parentRunId: RunId,
        parentEpoch: Int64, parentOperationId: OperationId, parentItemId: ItemId, parentCallId: String,
        planDigest: String, permissionDomain: String, serviceBindingDigest: String) {
        if (parentEpoch < 1 || declaration.threadId.value == parentThreadId.value || declaration.runId.value == parentRunId.value ||
            !directOriginIdentifier(parentThreadId.value, 256) || !directOriginIdentifier(parentRunId.value, 256) ||
            !directOriginIdentifier(parentOperationId.value, 512) || !directOriginIdentifier(parentItemId.value, 512) ||
            !directOriginIdentifier(parentCallId, 512) || !directOriginDigest(planDigest) ||
            !directOriginDigest(permissionDomain) || !directOriginDigest(serviceBindingDigest)) {
            throw IllegalArgumentException("managed job launch must bind separate execution identity and the exact parent plan")
        }
        this.declaration = ManagedJobDeclaration(declaration.jobId, declaration.threadId, declaration.runId,
            declaration.deadlineMillis, declaration.maxToolCalls)
        this.parentThreadId = parentThreadId; this.parentRunId = parentRunId; this.parentEpoch = parentEpoch
        this.parentOperationId = parentOperationId; this.parentItemId = parentItemId; this.parentCallId = parentCallId
        this.planDigest = planDigest; this.permissionDomain = permissionDomain; this.serviceBindingDigest = serviceBindingDigest
    }
}

public func managedJobLaunchBindingValue(value: ManagedJobLaunchBinding): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.managed-job-launch/v1")),
        ValueField("job", managedJobDeclarationValue(value.declaration)),
        ValueField("parent_thread_id", textValue(value.parentThreadId.value)), ValueField("parent_run_id", textValue(value.parentRunId.value)),
        ValueField("parent_epoch", integerValue(value.parentEpoch)), ValueField("parent_operation_id", textValue(value.parentOperationId.value)),
        ValueField("parent_item_id", textValue(value.parentItemId.value)), ValueField("parent_call_id", textValue(value.parentCallId)),
        ValueField("plan_digest", textValue(value.planDigest)), ValueField("permission_domain", textValue(value.permissionDomain)),
        ValueField("service_binding_digest", textValue(value.serviceBindingDigest))])
}

public func managedJobLaunchDigest(value: ManagedJobLaunchBinding): String {
    modelPolicySha256Text(canonicalAgentValue(managedJobLaunchBindingValue(value)))
}

// The launch parent reports delegation, never the eventual command outcome.
public func managedJobLaunchOutput(value: ManagedJobLaunchBinding): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.managed-job-started/v1")),
        ValueField("job_id", textValue(value.declaration.jobId)), ValueField("status", textValue("running")),
        ValueField("thread_id", textValue(value.declaration.threadId.value)), ValueField("run_id", textValue(value.declaration.runId.value)),
        ValueField("launch_digest", textValue(managedJobLaunchDigest(value)))])
}

public func isManagedJobLaunchPlan(plan: NormalizedOperationPlan): Bool {
    try {
        if (!isFrozenChannelParentPlan(plan) || plan.retryDisposition != OperationRetryDisposition.Never ||
            !CapabilitySet(values: plan.requiredCapabilities).allows(CapabilityKind.Delegate, resource: "managed-job")) { return false }
        match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => (); case _ => return false }
        let host = plan.canonicalArguments.field("host_plan").getOrThrow()
        let job = managedJobDeclarationFromValue(host.field("managed_job").getOrThrow())
        let binding = host.field("binding").getOrThrow()
        job.threadId.value != httpIntentText(binding, "target_thread_id")
    } catch (_: Exception) { false }
}

// Durable Task origin is evidence only. Runtime admission has no public ctor.
public func managedJobLaunchBindingFromValue(value: AgentValue): ManagedJobLaunchBinding {
    if (!httpIntentExactFields(value, ["schema", "job", "parent_thread_id", "parent_run_id", "parent_epoch",
        "parent_operation_id", "parent_item_id", "parent_call_id", "plan_digest", "permission_domain", "service_binding_digest"]) ||
        httpIntentText(value, "schema") != "axyndra.managed-job-launch/v1") {
        throw IllegalArgumentException("unsupported managed job launch binding")
    }
    ManagedJobLaunchBinding(managedJobDeclarationFromValue(value.field("job").getOrThrow()),
        ThreadId(httpIntentText(value, "parent_thread_id")), RunId(httpIntentText(value, "parent_run_id")),
        managedJobInteger(value, "parent_epoch"), OperationId(httpIntentText(value, "parent_operation_id")),
        ItemId(httpIntentText(value, "parent_item_id")), httpIntentText(value, "parent_call_id"),
        httpIntentText(value, "plan_digest"), httpIntentText(value, "permission_domain"), httpIntentText(value, "service_binding_digest"))
}

public func managedJobOriginValue(value: ManagedJobLaunchBinding): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.direct-origin/v5")), ValueField("kind", textValue("managed_job")),
        ValueField("launch", managedJobLaunchBindingValue(value))])
}
public func managedJobOriginFromValue(value: AgentValue): ManagedJobLaunchBinding {
    if (!httpIntentExactFields(value, ["schema", "kind", "launch"]) || httpIntentText(value, "schema") != "axyndra.direct-origin/v5" ||
        httpIntentText(value, "kind") != "managed_job") { throw IllegalArgumentException("unsupported Task origin") }
    managedJobLaunchBindingFromValue(value.field("launch").getOrThrow())
}
public func isManagedJobInitiator(item: ThreadItem): Bool {
    if (item.kind != ItemKind.SystemNote || item.provenance.source != "managed_job" ||
        item.provenance.runId.isNone() || item.provenance.operationId.isSome()) { return false }
    match (item.provenance.directOrigin) {
        case Some(DirectCallOrigin.ManagedJob(value)) => item.provenance.runId.getOrThrow().value == value.declaration.runId.value &&
            item.threadId.value == value.declaration.threadId.value
        case _ => false
    }
}

public func managedJobPreparationReference(value: ManagedJobLaunchBinding): AgentValue {
    objectValue([ValueField("thread_id", textValue(value.parentThreadId.value)), ValueField("run_id", textValue(value.parentRunId.value)),
        ValueField("epoch", integerValue(value.parentEpoch)), ValueField("call_id", textValue(value.parentCallId))])
}

public func managedJobRunBudget(binding: ManagedJobLaunchBinding): AgentValue {
    objectValue([ValueField("run_kind", textValue("managed_job")),
        ValueField("max_tool_calls", integerValue(binding.declaration.maxToolCalls)), ValueField("max_concurrent_tools", integerValue(1)),
        ValueField("deadline_millis", integerValue(binding.declaration.deadlineMillis)),
        ValueField("launch_digest", textValue(managedJobLaunchDigest(binding)))])
}
