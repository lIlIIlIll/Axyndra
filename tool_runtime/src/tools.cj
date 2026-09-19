package tool_runtime

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import std.collection.*
import std.deriving.*
import std.overflow.*
import std.sync.*
import std.process.*

public interface ToolExecutor {
    // Executors receive only the immutable prepared invocation. The original
    // call is retained for identity/display; all authority-relevant values
    // come from operationPlan.
    func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult>
    func cancel(runId: RunId): Result<Unit> {
        let _ = runId
        Result.Ok(())
    }

    // Called only after a successful tool result has been appended to the
    // durable conversation. Executors that rewrite session history use this
    // boundary so the tool loop never observes a half-persisted transition.
    func afterResultPersisted(
        context: ToolInvocationContext,
        result: ToolResult
    ): Result<Unit> {
        let _ = context
        let _ = result
        Result.Ok(())
    }
}

public interface ToolArgumentValidator {
    func validate(call: ToolCall, definition: ModelToolDefinition): Result<Unit>
}

public type ToolCapabilityResolver = (ToolCall) -> Capability
public type ToolAdditionalCapabilityResolver = (ToolCall) -> Array<Capability>
public type ToolNetworkPolicyResolver = (ToolCall) -> Result<NetworkPolicy>

public type ToolSideEffectResolver = (ToolCall) -> Bool

public type ToolApprovalMetadataResolver = (ToolCall) -> ToolApprovalMetadata

public class ObjectArgumentValidator <: ToolArgumentValidator {
    public func validate(
        call: ToolCall,
        definition: ModelToolDefinition
    ): Result<Unit> {
        if (call.name != definition.name) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Internal,
                    "tool.definition_mismatch",
                    "resolved tool definition does not match the call"
                )
            )
        }
        if (call.arguments.unifiedKind != ValueKind.Object) {
            return invalidToolArguments(
                call,
                UnifiedJsonSchemaViolation(
                    "$",
                    "type",
                    "tool arguments must be an object"
                )
            )
        }
        match (validateAgentValueSchema(
            definition.inputSchema,
            call.arguments
        )) {
            case Some(violation) => invalidToolArguments(call, violation)
            case None => Result.Ok(())
        }
    }
}

func invalidToolArguments(
    call: ToolCall,
    violation: UnifiedJsonSchemaViolation
): Result<Unit> {
    Result.Err(
        AgentError(
            AgentErrorKind.InvalidInput,
            "tool.invalid_arguments",
            violation.message + " at " + violation.path,
            fields: [
                ErrorField("tool", call.name),
                ErrorField("call_id", call.callId),
                ErrorField("path", violation.path),
                ErrorField("keyword", violation.keyword)
            ]
        )
    )
}

public class ToolDescriptor {
    public let definition: ModelToolDefinition
    public let capability: Capability
    public let sideEffecting: Bool
    public let concurrency: ToolConcurrencyProfile
    public let additionalCapabilities: Array<Capability>
    private let capabilityResolver: ?ToolCapabilityResolver
    private let networkPolicyResolver: ?ToolNetworkPolicyResolver
    private let additionalCapabilityResolver: ?ToolAdditionalCapabilityResolver
    private let sideEffectResolver: ?ToolSideEffectResolver
    private let approvalMetadataResolver: ?ToolApprovalMetadataResolver
    private let approvalMetadataValue: ?ToolApprovalMetadata

    public init(
        definition: ModelToolDefinition,
        capability: Capability,
        sideEffecting!: Bool = false,
        concurrency!: ToolConcurrencyProfile = ToolConcurrencyProfile(),
        additionalCapabilities!: Array<Capability> = [],
        capabilityResolver!: ?ToolCapabilityResolver = None,
        additionalCapabilityResolver!: ?ToolAdditionalCapabilityResolver = None,
        sideEffectResolver!: ?ToolSideEffectResolver = None,
        approvalMetadataResolver!: ?ToolApprovalMetadataResolver = None,
        networkPolicyResolver!: ?ToolNetworkPolicyResolver = None,
        approvalMetadataValue!: ?ToolApprovalMetadata = None
    ) {
        this.definition = definition
        this.capability = capability
        this.sideEffecting = sideEffecting
        this.concurrency = concurrency
        this.additionalCapabilities = additionalCapabilities
        this.capabilityResolver = capabilityResolver
        this.additionalCapabilityResolver = additionalCapabilityResolver
        this.sideEffectResolver = sideEffectResolver
        this.approvalMetadataResolver = approvalMetadataResolver
        this.approvalMetadataValue = approvalMetadataValue
        this.networkPolicyResolver = networkPolicyResolver
    }

    public func resolved(call: ToolCall): ToolDescriptor {
        let requirements = requiredCapabilities(call)
        let resolvedCapability = requirements[0]
        let resolvedAdditional = ArrayList<Capability>()
        for (index in 1..requirements.size) {
            resolvedAdditional.add(requirements[index])
        }
        ToolDescriptor(
            definition,
            resolvedCapability,
            sideEffecting: match (sideEffectResolver) {
                case Some(resolve) => resolve(call)
                case None => sideEffecting
            },
            concurrency: concurrency,
            additionalCapabilities: resolvedAdditional.toArray(),
            networkPolicyResolver: networkPolicyResolver,
            approvalMetadataResolver: approvalMetadataResolver,
            approvalMetadataValue: Some(match (approvalMetadataResolver) {
                case Some(resolve) => resolve(call)
                case None => defaultToolApprovalMetadata(resolvedCapability)
            })
        )
    }

    // The first element is the primary capability used by the existing
    // approval UI; every element is an independently enforced requirement.
    public func requiredCapabilities(call: ToolCall): Array<Capability> {
        let values = ArrayList<Capability>()
        addRequiredCapability(values, match (capabilityResolver) {
            case Some(resolve) => resolve(call)
            case None => capability
        })
        for (value in additionalCapabilities) {
            addRequiredCapability(values, value)
        }
        match (additionalCapabilityResolver) {
            case Some(resolve) => for (value in resolve(call)) {
                addRequiredCapability(values, value)
            }
            case None => ()
        }
        let networkPolicy = match (networkPolicy(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalArgumentException(error.message)
        }
        for (resource in networkPolicyCapabilityResources(networkPolicy)) {
            addRequiredCapability(
                values,
                Capability(CapabilityKind.NetworkAccess, resource: resource)
            )
        }
        values.toArray()
    }

    public func networkPolicy(call: ToolCall): Result<NetworkPolicy> {
        match (networkPolicyResolver) {
            case Some(resolve) => resolve(call)
            case None => networkPolicyForToolCall(call)
        }
    }

    public func requiredCapabilities(): Array<Capability> {
        let values = ArrayList<Capability>()
        addRequiredCapability(values, capability)
        for (value in additionalCapabilities) {
            addRequiredCapability(values, value)
        }
        values.toArray()
    }

    public func approvalMetadata(call: ToolCall): ToolApprovalMetadata {
        match (approvalMetadataValue) {
            case Some(value) => value
            case None => match (approvalMetadataResolver) {
                case Some(resolve) => resolve(call)
                case None => defaultToolApprovalMetadata(capability)
            }
        }
    }
}

func addRequiredCapability(
    values: ArrayList<Capability>,
    candidate: Capability
): Unit {
    for (value in values where value.kind == candidate.kind &&
        value.resource == candidate.resource) {
        return
    }
    values.add(candidate)
}

func missingRequiredCapability(
    context: ToolInvocationContext,
    required: Array<Capability>
): ?Capability {
    for (capability in required) {
        if (!context.capabilities.allows(
            capability.kind,
            resource: capability.resource
        )) {
            return Some(capability)
        }
    }
    None
}

func missingCapabilityError(
    call: ToolCall,
    missing: Capability,
    boundary: String
): AgentError {
    AgentError(
        AgentErrorKind.PermissionDenied,
        "tool.capability_denied",
        "required capability is not granted at " + boundary,
        fields: [
            ErrorField("tool", call.name),
            ErrorField("capability", capabilityName(missing.kind)),
            ErrorField("resource", missing.resource)
        ]
    )
}

class PlanWriteTool <: ToolExecutor {
    public func execute(
        _: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let call = ToolCall(
            prepared.call.callId,
            prepared.call.name,
            prepared.operationPlan.canonicalArguments
        )
        let content = match (call.arguments.field("content")) {
            case Some(value) => value.text.trimAscii()
            case None => ""
        }
        if (content == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "plan_write.empty",
                    "plan_write requires a non-empty content field"
                )
            )
        }
        Result.Ok(
            ToolResult(
                call.callId,
                textValue("Plan recorded for review. The user reviews it via /plan-review before execution.")
            )
        )
    }
}

class ToolRegistration {
    let descriptor: ToolDescriptor
    let executor: ToolExecutor
    var active: Bool

    init(descriptor: ToolDescriptor, executor: ToolExecutor) {
        this.descriptor = descriptor
        this.executor = executor
        this.active = true
    }
}

public class ToolCatalog {
    private let registrations = ArrayList<ToolRegistration>()
    private let lock = Mutex()

    public init() {}

    public func register(
        descriptor: ToolDescriptor,
        executor: ToolExecutor
    ): Result<Unit> {
        if (descriptor.sideEffecting && !sharedSideEffectHasWrite(descriptor.concurrency)) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "tool.shared_side_effect_without_write",
                    "a side-effecting shared tool must declare at least one write resource",
                    fields: [ErrorField("tool", descriptor.definition.name)]
                )
            )
        }
        lock.lock()
        try {
            for (item in registrations where item.descriptor.definition.name == descriptor.definition.name) {
                return Result.Err(
                    AgentError(
                        AgentErrorKind.Configuration,
                        "tool.duplicate",
                        "tool is already registered",
                        fields: [ErrorField("tool", descriptor.definition.name)]
                    )
                )
            }
            registrations.add(ToolRegistration(descriptor, executor))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    func find(name: String): ?ToolRegistration {
        lock.lock()
        try {
            for (item in registrations where item.active && item.descriptor.definition.name == name) {
                return Some(item)
            }
            None
        } finally {
            lock.unlock()
        }
    }

    // Durable prepared/recovery paths retain access to an installed executor
    // after lifecycle deactivation. New preparation uses find() and therefore
    // cannot see inactive registrations.
    func findRegistered(name: String): ?ToolRegistration {
        lock.lock()
        try {
            for (item in registrations where item.descriptor.definition.name == name) {
                return Some(item)
            }
            None
        } finally {
            lock.unlock()
        }
    }

    public func resolvedDescriptor(call: ToolCall): ?ToolDescriptor {
        match (find(call.name)) {
            case Some(value) => Some(value.descriptor.resolved(call))
            case None => None
        }
    }

    public func isReadOnly(call: ToolCall): Bool {
        match (resolvedDescriptor(call)) {
            case Some(value) => !value.sideEffecting
            case None => false
        }
    }

    public func definitions(): Array<ModelToolDefinition> {
        lock.lock()
        try {
            let values = ArrayList<ModelToolDefinition>()
            for (item in registrations where item.active) {
                values.add(item.descriptor.definition)
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }

    public func definitionsFor(capabilities: CapabilitySet): Array<ModelToolDefinition> {
        lock.lock()
        try {
            let values = ArrayList<ModelToolDefinition>()
            for (item in registrations where item.active) {
                var allowed = true
                for (required in item.descriptor.requiredCapabilities()) {
                    if (!capabilities.allows(
                        required.kind,
                        resource: required.resource
                    )) {
                        allowed = false
                        break
                    }
                }
                if (allowed) {
                    values.add(item.descriptor.definition)
                }
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }

    public func unregister(name: String): Bool {
        lock.lock()
        try {
            for (index in 0..registrations.size) {
                if (registrations[index].descriptor.definition.name == name) {
                    registrations.remove(at: index)
                    return true
                }
            }
            false
        } finally {
            lock.unlock()
        }
    }


    public func setActive(name: String, active: Bool): Bool {
        lock.lock()
        try {
            for (item in registrations where item.descriptor.definition.name == name) {
                item.active = active
                return true
            }
            false
        } finally {
            lock.unlock()
        }
    }

    func cancel(runId: RunId): Result<Unit> {
        let snapshot = lockAndSnapshot()
        for (registration in snapshot) {
            match (registration.executor.cancel(runId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(())
    }

    private func lockAndSnapshot(): Array<ToolRegistration> {
        lock.lock()
        try {
            registrations.toArray()
        } finally {
            lock.unlock()
        }
    }
}

@Derive[Equatable]
public enum PermissionRequirement {
    Safe | Confirm | Deny
}

@Derive[Equatable]
public enum ApprovalMode {
    AlwaysAsk | Write | Yolo
}

public class PolicyDecision {
    public let requirement: PermissionRequirement
    public let reason: String

    public init(
        requirement: PermissionRequirement,
        reason!: String = ""
    ) {
        this.requirement = requirement
        this.reason = reason
    }
}

public interface CapabilityPolicy {
    func evaluate(
        context: ToolInvocationContext,
        plan: NormalizedOperationPlan
    ): PolicyDecision
}

public class DefaultCapabilityPolicy <: CapabilityPolicy {
    private let mode: ApprovalMode
    private let allowWorkspaceWrites: Bool
    private let askOnNetwork: Bool

    public init(
        mode!: ApprovalMode = ApprovalMode.AlwaysAsk,
        allowWorkspaceWrites!: Bool = false,
        askOnNetwork!: Bool = true
    ) {
        this.mode = mode
        this.allowWorkspaceWrites = allowWorkspaceWrites
        this.askOnNetwork = askOnNetwork
    }

    public func evaluate(
        context: ToolInvocationContext,
        plan: NormalizedOperationPlan
    ): PolicyDecision {
        for (capability in plan.requiredCapabilities) {
            if (!context.capabilities.allows(
                capability.kind,
                resource: capability.resource
            )) {
                return PolicyDecision(
                    PermissionRequirement.Deny,
                    reason: "required capability " + capabilityName(capability.kind) +
                        " is not granted for this run; ask responses and retries cannot add it"
                )
            }
        }
        let metadata = plan.approvalMetadata
        if (allowWorkspaceWrites && plan.effectClass != OperationEffectClass.ReadOnly &&
            metadata.capabilityLabel == "workspace.write" &&
            metadata.assessment.level == ApprovalRiskLevel.Low) {
            return PolicyDecision(
                PermissionRequirement.Safe,
                reason: "low-risk workspace write allowed by static policy"
            )
        }
        if (requiresPrompt(
            plan,
            context.approvalModeOverride
        )) {
            PolicyDecision(
                PermissionRequirement.Confirm,
                reason: "side effect requires one-time approval"
            )
        } else {
            PolicyDecision(PermissionRequirement.Safe)
        }
    }

    private func requiresPrompt(
        plan: NormalizedOperationPlan,
        override: ?ApprovalMode
    ): Bool {
        let effective = match (override) {
            case Some(value) => value
            case None => mode
        }
        match (effective) {
            case ApprovalMode.Yolo => false
            case _ =>
                if (askOnNetwork && requiresCapability(
                    plan.requiredCapabilities,
                    CapabilityKind.NetworkAccess
                )) {
                    return true
                }
                match (effective) {
                    case ApprovalMode.AlwaysAsk =>
                        plan.effectClass != OperationEffectClass.ReadOnly
                    case ApprovalMode.Write => requiresPromptingCapability(
                        plan.requiredCapabilities
                    )
                    case ApprovalMode.Yolo => false
                }
        }
    }
}

func requiresPromptingCapability(capabilities: Array<Capability>): Bool {
    for (capability in capabilities) {
        match (capability.kind) {
            case CapabilityKind.ProcessSpawn | CapabilityKind.NetworkAccess |
                CapabilityKind.Delegate | CapabilityKind.ExtensionInvoke =>
                return true
            case _ => ()
        }
    }
    false
}

func requiresCapability(
    capabilities: Array<Capability>,
    kind: CapabilityKind
): Bool {
    for (capability in capabilities where capability.kind == kind) {
        return true
    }
    false
}

public class ToolPipeline {
    private let catalog: ToolCatalog
    private let validator: ToolArgumentValidator
    private let policy: CapabilityPolicy
    private let operations: OperationRuntimePort
    private let audit: AuditPort
    private let ids: IdGenerator
    private let permissions: PermissionRepository

    public init(
        catalog: ToolCatalog,
        operations: OperationRuntimePort,
        audit: AuditPort,
        ids: IdGenerator,
        validator!: ToolArgumentValidator = ObjectArgumentValidator(),
        policy!: CapabilityPolicy = DefaultCapabilityPolicy(),
        permissions!: PermissionRepository = MemoryPermissionRepository()
    ) {
        this.catalog = catalog
        this.validator = validator
        this.policy = policy
        this.operations = operations
        this.audit = audit
        this.ids = ids
        this.permissions = permissions
    }
    public func operationRuntime(): OperationRuntimePort {
        operations
    }


    // Sole production AgentCore entry. A CommittedToolCallRef can only be
    // minted after a validated durable Decision has been atomically projected
    // into the canonical Thread.
    public func prepareCommitted(
        context: ToolInvocationContext,
        committed: CommittedToolCallRef
    ): Result<ToolPreparation> {
        prepareResolved(context, ToolCall(
            committed.block.callId,
            committed.block.name,
            committed.block.arguments
        ), Some(OperationId(
            "operation-" + committed.decisionId.value + "-" +
                committed.scopedToolCallId.value
        )))
    }

    // Direct SDK preparation surface. Production AgentCore must use
    // prepareCommitted; this raw API is plan-only and cannot enter
    // OperationRuntimePort without a canonical ToolCall Item.
    // Preparation resolves the catalog entry, validates arguments, applies
    // permanent safety rules and policy, and deliberately never calls the
    // executor. Batch coordinators therefore have a real all-approval barrier
    // instead of a UI convention.
    public func prepare(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolPreparation> {
        prepareResolved(context, call, None)
    }

    private func prepareResolved(
        context: ToolInvocationContext,
        call: ToolCall,
        committedOperationId: ?OperationId
    ): Result<ToolPreparation> {
        let registration = match (catalog.find(call.name)) {
            case Some(value) => value
            case None =>
                let error = AgentError(
                    AgentErrorKind.InvalidInput,
                    "tool.not_found",
                    "tool is not registered",
                    fields: [ErrorField("tool", call.name)]
                )
                return Result.Ok(ToolPreparation.Completed(recoverableToolResult(call, error)))
        }
        // Freeze and validate network authorization before schema-dependent
        // resolution or any executor can observe the call. A gateway error
        // must never become a permission request or a retry trigger.
        match (registration.descriptor.networkPolicy(call)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                return Result.Ok(ToolPreparation.Denied(
                    ToolDenial(call.callId, call.name, error)
                ))
        }
        match (validator.validate(call, registration.descriptor.definition)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                return Result.Ok(ToolPreparation.Completed(recoverableToolResult(call, error)))
        }
        let effective = registration.descriptor.resolved(call)
        let requirements = effective.requiredCapabilities()
        match (missingRequiredCapability(context, requirements)) {
            case Some(missing) =>
                let error = AgentError(
                    AgentErrorKind.PermissionDenied,
                    "tool.capability_denied",
                    "required capability is not granted for this run",
                    fields: [
                        ErrorField("tool", call.name),
                        ErrorField("capability", capabilityName(missing.kind)),
                        ErrorField("resource", missing.resource)
                    ]
                )
                let _ = appendAudit(
                    context,
                    "tool.denied",
                    call,
                    missing,
                    decisionSource: ApprovalDecisionSource.HardDeny
                )
                return Result.Ok(ToolPreparation.Denied(
                    ToolDenial(call.callId, call.name, error)
                ))
            case None => ()
        }
        if (effective.sideEffecting && !sharedSideEffectHasWrite(effective.concurrency)) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "tool.shared_side_effect_without_write",
                    "resolved side-effecting shared tool must declare at least one write resource",
                    fields: [ErrorField("tool", call.name)]
                )
            )
        }
        let plan = normalizedToolOperationPlan(context, call, effective)
        let metadata = plan.approvalMetadata
        let riskFlags = mergedApprovalFlags(
            approvalRiskFlags(call, effective.capability),
            metadata.assessment.flags
        )
        let safetyRequest = ApprovalRequest(
            OperationId("safety-" + call.callId),
            call.callId,
            call.name,
            effective.capability,
            preview: call.arguments,
            sessionId: context.sessionId.value,
            argumentHash: requiredCapabilitiesArgumentHash(call, requirements),
            riskFlags: riskFlags,
            metadata: metadata,
            decisionSource: ApprovalDecisionSource.HardDeny
        )
        match (approvalPermanentDenialReason(safetyRequest)) {
            case Some(reason) =>
                let _ = appendAudit(
                    context,
                    "tool.denied",
                    call,
                    effective.capability,
                    decisionSource: ApprovalDecisionSource.HardDeny,
                    metadata: Some(metadata)
                )
                return Result.Ok(
                    ToolPreparation.Denied(
                        ToolDenial(
                            call.callId,
                            call.name,
                            AgentError(
                                AgentErrorKind.PermissionDenied,
                                "tool.hard_denied",
                                reason,
                                fields: [ErrorField("tool", call.name)]
                            )
                        )
                    )
                )
            case None => ()
        }
        let evaluated = policy.evaluate(
            context,
            plan
        )
        let networkSessionEligible = networkPolicyModeIsDenied(plan.networkPolicy.mode)
        let granted = networkSessionEligible &&
            evaluated.requirement == PermissionRequirement.Confirm &&
            persistedGrantAllows(context.sessionId, metadata.grantScope)
        let policyDecision = if (granted) {
            PolicyDecision(
                PermissionRequirement.Safe,
                reason: "approved for this session"
            )
        } else {
            evaluated
        }
        match (policyDecision.requirement) {
            case PermissionRequirement.Deny =>
                let error = AgentError(
                    AgentErrorKind.PermissionDenied,
                    "tool.capability_denied",
                    policyDecision.reason,
                    fields: [
                        ErrorField("tool", call.name),
                        ErrorField(
                            "capability",
                            capabilityName(effective.capability.kind)
                        )
                    ]
                )
                let _ = appendAudit(
                    context,
                    "tool.denied",
                    call,
                    effective.capability,
                    decisionSource: ApprovalDecisionSource.HardDeny,
                    metadata: Some(metadata)
                )
                Result.Ok(ToolPreparation.Denied(ToolDenial(call.callId, call.name, error)))
            case PermissionRequirement.Safe => prepareReady(
                context,
                call,
                effective,
                effective.capability,
                decisionSource: if (granted) {
                    ApprovalDecisionSource.SessionGrant
                } else {
                    ApprovalDecisionSource.StaticPolicy
                },
                metadata: Some(metadata),
                requestedOperationId: committedOperationId
            )
            case PermissionRequirement.Confirm => prepareForApproval(
                context,
                call,
                effective,
                metadata,
                requestedOperationId: committedOperationId
            )
        }
    }

    public func afterResultPersisted(
        context: ToolInvocationContext,
        toolName: String,
        outcome: ToolInvocationResult
    ): Result<Unit> {
        let result = match (outcome) {
            case ToolInvocationResult.Completed(value) =>
                if (value.isError) {
                    return Result.Ok(())
                }
                value
            case _ => return Result.Ok(())
        }
        let registration = match (catalog.findRegistered(toolName)) {
            case Some(value) => value
            case None => return Result.Err(
                AgentError(
                    AgentErrorKind.Internal,
                    "tool.persisted_hook_missing",
                    "persisted tool result has no registered executor",
                    fields: [ErrorField("tool", toolName)]
                )
            )
        }
        registration.executor.afterResultPersisted(context, result)
    }

    public func cancel(runId: RunId): Result<Unit> {
        catalog.cancel(runId)
    }

    public func authorize(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        decision: ApprovalDecision,
        decisionSource!: ApprovalDecisionSource = ApprovalDecisionSource.User
    ): Result<ToolAuthorization> {
        if (prepared.authorization != PreparedAuthorization.ApprovalRequired) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.approval_not_required",
                "the prepared tool invocation is not awaiting approval"
            ))
        }
        let plan = match (operations.loadPlan(prepared.operationId, context.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!sameNormalizedOperationPlan(plan, prepared.operationPlan)) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.approval_context_changed",
                "the canonical Operation plan changed while approval was pending"
            ))
        }
        let registration = match (catalog.findRegistered(prepared.call.name)) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "tool.pending_registration_missing",
                "pending tool is no longer registered",
                fields: [ErrorField("tool", prepared.call.name)]
            ))
        }
        let currentPlan = normalizedToolOperationPlan(
            context,
            prepared.call,
            registration.descriptor.resolved(prepared.call)
        )
        if (!sameNormalizedOperationPlan(plan, currentPlan)) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.approval_context_changed",
                "normalized Operation changed while approval was pending"
            ))
        }
        let approved = match (decision) {
            case ApprovalDecision.Reject | ApprovalDecision.RejectWithReason(_) => false
            case ApprovalDecision.Approve | ApprovalDecision.ApproveSession => true
        }
        if (approved && match (decision) {
            case ApprovalDecision.ApproveSession => !networkPolicyModeIsDenied(plan.networkPolicy.mode)
            case _ => false
        }) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "approval.session_scope_forbidden",
                "network-enabled operations require one-time approval"
            ))
        }
        match (missingRequiredCapability(context, plan.requiredCapabilities)) {
            case Some(missing) => return Result.Err(
                missingCapabilityError(prepared.call, missing, "approval")
            )
            case None => ()
        }
        if (approved && match (decision) {
            case ApprovalDecision.ApproveSession => match (
                permissions.grant(context.sessionId, plan.approvalMetadata.grantScope)
            ) {
                case Result.Ok(_) => false
                case Result.Err(error) => return Result.Err(error)
            }
            case _ => false
        }) {
            return Result.Err(AgentError(
                AgentErrorKind.Internal,
                "tool.approval_grant_unreachable",
                "session approval grant did not complete"
            ))
        }
        let source = approvalDecisionSourceName(decisionSource)
        match (operations.recordApproval(
            "approval-" + prepared.operationId.value,
            prepared.operationId,
            context.runId,
            plan,
            CapabilitySet(values: plan.requiredCapabilities),
            approved,
            source,
            None
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        if (!approved) {
            let reason = match (decision) {
                case ApprovalDecision.Reject => ""
                case ApprovalDecision.RejectWithReason(value) => value
                case _ => ""
            }
            let error = AgentError(
                AgentErrorKind.PermissionDenied,
                "tool.approval_rejected",
                if (reason.trimAscii() == "") {
                    "user rejected the pending tool operation"
                } else {
                    "user rejected the pending tool operation: " + reason
                },
                fields: rejectionFields(prepared.call.name, reason)
            )
            let result = recoverableToolResult(
                prepared.call,
                error,
                receiptId: prepared.operationId.value
            )
            let _ = appendAudit(
                context,
                "tool.approval_rejected",
                prepared.call,
                primaryPlanCapability(plan)
            )
            return Result.Ok(ToolAuthorization.Completed(result))
        }
        Result.Ok(ToolAuthorization.Ready(
            preparedWithAuthorization(prepared, PreparedAuthorization.Approved)
        ))
    }

    public func decide(
        context: ToolInvocationContext,
        operationId: OperationId,
        decision: ApprovalDecision,
        afterHandoff: (PreparedToolInvocation) -> Result<Unit>,
        decisionSource!: ApprovalDecisionSource = ApprovalDecisionSource.User
    ): Result<ToolInvocationResult> {
        let prepared = match (loadPreparedForApproval(context, operationId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (authorize(context, prepared, decision, decisionSource: decisionSource)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(ToolAuthorization.Ready(value)) =>
                executePrepared(context, value, afterHandoff)
            case Result.Ok(ToolAuthorization.Completed(result)) =>
                Result.Ok(ToolInvocationResult.Completed(result))
            case Result.Ok(ToolAuthorization.Denied(denial)) =>
                Result.Ok(ToolInvocationResult.Denied(denial))
        }
    }

    public func decide(
        context: ToolInvocationContext,
        operationId: OperationId,
        decision: ApprovalDecision
    ): Result<ToolInvocationResult> {
        decide(context, operationId, decision, {_ => Result.Ok(())})
    }

    public func approvalPlan(
        context: ToolInvocationContext,
        operationId: OperationId
    ): Result<NormalizedOperationPlan> {
        operations.loadPlan(operationId, context.runId)
    }

    private func preparedWithAuthorization(
        prepared: PreparedToolInvocation,
        authorization: PreparedAuthorization
    ): PreparedToolInvocation {
        PreparedToolInvocation(
            prepared.operationId,
            prepared.call,
            prepared.concurrency,
            authorization,
            prepared.operationPlan,
            approval: prepared.approval
        )
    }

    private func loadPreparedForApproval(
        context: ToolInvocationContext,
        operationId: OperationId
    ): Result<PreparedToolInvocation> {
        let plan = match (operations.loadPlan(operationId, context.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let call = match (operations.loadCall(operationId, context.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let registration = match (catalog.findRegistered(call.name)) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "tool.pending_registration_missing",
                "pending tool is no longer registered",
                fields: [ErrorField("tool", call.name)]
            ))
        }
        let currentPlan = normalizedToolOperationPlan(
            context,
            call,
            registration.descriptor.resolved(call)
        )
        if (!sameNormalizedOperationPlan(plan, currentPlan)) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.approval_context_changed",
                "normalized Operation changed while approval was pending"
            ))
        }
        let capability = primaryPlanCapability(plan)
        let request = ApprovalRequest(
            operationId,
            call.callId,
            call.name,
            capability,
            preview: plan.canonicalArguments,
            sessionId: context.sessionId.value,
            argumentHash: requiredCapabilitiesArgumentHash(call, plan.requiredCapabilities),
            riskFlags: mergedApprovalFlags(
                approvalRiskFlags(call, capability),
                plan.approvalMetadata.assessment.flags
            ),
            metadata: plan.approvalMetadata
        )
        Result.Ok(PreparedToolInvocation(
            operationId,
            call,
            registration.descriptor.concurrency,
            PreparedAuthorization.ApprovalRequired,
            plan,
            approval: Some(request)
        ))
    }

    private func persistedGrantAllows(
        sessionId: SessionId,
        scope: ApprovalGrantScope
    ): Bool {
        match (permissions.allows(sessionId, scope)) {
            case Result.Ok(value) => value
            case Result.Err(_) => false
        }
    }

    private func prepareForApproval(
        context: ToolInvocationContext,
        call: ToolCall,
        descriptor: ToolDescriptor,
        metadata: ToolApprovalMetadata,
        requestedOperationId!: ?OperationId = None
    ): Result<ToolPreparation> {
        let operationId = match (requestedOperationId) {
            case Some(value) => value
            case None => ids.nextOperationId()
        }
        let plan = normalizedToolOperationPlan(context, call, descriptor)
        let capability = primaryPlanCapability(plan)
        let required = plan.requiredCapabilities
        let _ = appendAudit(
            context,
            "tool.approval_requested",
            call,
            capability
        )
        let request = ApprovalRequest(
            operationId,
            call.callId,
            call.name,
            capability,
            preview: plan.canonicalArguments,
            sessionId: context.sessionId.value,
            argumentHash: requiredCapabilitiesArgumentHash(call, required),
            riskFlags: mergedApprovalFlags(
                approvalRiskFlags(call, capability),
                metadata.assessment.flags
            ),
            metadata: metadata
        )
        let prepared = PreparedToolInvocation(
            operationId,
            call,
            descriptor.concurrency,
            PreparedAuthorization.ApprovalRequired,
            plan,
            approval: Some(request)
        )
        Result.Ok(ToolPreparation.NeedsApproval(prepared, request))
    }

    private func prepareReady(
        context: ToolInvocationContext,
        call: ToolCall,
        descriptor: ToolDescriptor,
        capability: Capability,
        decisionSource!: ApprovalDecisionSource = ApprovalDecisionSource.StaticPolicy,
        metadata!: ?ToolApprovalMetadata = None,
        requestedOperationId!: ?OperationId = None
    ): Result<ToolPreparation> {
        let operationId = match (requestedOperationId) {
            case Some(value) => value
            case None => ids.nextOperationId()
        }
        let plan = normalizedToolOperationPlan(context, call, descriptor)
        let _ = appendAudit(
            context,
            "tool.approval_bypassed",
            call,
            primaryPlanCapability(plan),
            decisionSource: decisionSource,
            metadata: metadata
        )
        Result.Ok(
            ToolPreparation.Ready(
                PreparedToolInvocation(
                    operationId,
                    call,
                    descriptor.concurrency,
                    if (decisionSource == ApprovalDecisionSource.SessionGrant) {
                        PreparedAuthorization.SessionGrant
                    } else {
                        PreparedAuthorization.StaticPolicy
                    },
                    plan
                )
                )
            )
    }

    public func executePrepared(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolInvocationResult> {
        executePrepared(context, prepared, {_ => Result.Ok(())})
    }

    public func executePrepared(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        afterHandoff: (PreparedToolInvocation) -> Result<Unit>
    ): Result<ToolInvocationResult> {
        if (prepared.authorization == PreparedAuthorization.ApprovalRequired) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "tool.prepared_not_authorized",
                "prepared tool invocation has not passed its approval barrier",
                fields: [ErrorField("operation_id", prepared.operationId.value)]
            ))
        }
        let storedPlan = match (operations.loadPlan(
            prepared.operationId,
            context.runId
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!sameNormalizedOperationPlan(storedPlan, prepared.operationPlan)) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.prepared_plan_changed",
                "the canonical Operation plan changed before execution",
                fields: [ErrorField("operation_id", prepared.operationId.value)]
            ))
        }
        match (operations.loadCommittedToolResult(prepared.operationId, context.runId)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(Some(result)) =>
                if (result.callId != prepared.call.callId) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "operation.semantic_replay_drift",
                        "Operation already committed a different canonical ToolResult",
                        fields: [ErrorField("operation_id", prepared.operationId.value)]
                    ))
                }
                return Result.Ok(ToolInvocationResult.Completed(result))
            case Result.Ok(None) => ()
        }
        let registration = match (catalog.findRegistered(prepared.call.name)) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "tool.prepared_registration_missing",
                "prepared tool is no longer registered",
                fields: [ErrorField("tool", prepared.call.name)]
            ))
        }
        let current = registration.descriptor.resolved(prepared.call)
        let currentPlan = normalizedToolOperationPlan(context, prepared.call, current)
        if (!sameNormalizedOperationPlan(currentPlan, storedPlan)) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.prepared_plan_changed",
                "the resolved tool plan changed before execution",
                fields: [ErrorField("operation_id", prepared.operationId.value)]
            ))
        }
        match (missingRequiredCapability(context, storedPlan.requiredCapabilities)) {
            case Some(missing) => return Result.Ok(ToolInvocationResult.Denied(
                ToolDenial(
                    prepared.call.callId,
                    prepared.call.name,
                    AgentError(
                        AgentErrorKind.PermissionDenied,
                        "tool.capability_denied",
                        "required capability is no longer granted at execution",
                        fields: [
                            ErrorField("tool", prepared.call.name),
                            ErrorField("capability", capabilityName(missing.kind)),
                            ErrorField("resource", missing.resource)
                        ]
                    )
                )
            ))
            case None => ()
        }
        match (operations.markExecuting(
            prepared.operationId,
            context.runId,
            storedPlan,
            agentUtcMillis(),
            prepared.authorization == PreparedAuthorization.Approved
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (operations.markExecutionHandoff(
            prepared.operationId,
            context.runId,
            ThreadId(context.sessionId.value),
            agentUtcMillis()
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (afterHandoff(prepared)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let execution = match (registration.executor.execute(context, prepared)) {
            case Result.Ok(value) =>
                if (value.callId != prepared.call.callId) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Internal,
                        "tool.result_call_mismatch",
                        "tool executor returned a result for a different call id"
                    ))
                }
                value
            case Result.Err(error) =>
                if (recoverableExecutorError(error)) {
                    return Result.Ok(ToolInvocationResult.Completed(
                        recoverableToolResult(
                            prepared.call,
                            error,
                            receiptId: prepared.operationId.value
                        )
                    ))
                }
                return Result.Err(error)
        }
        Result.Ok(ToolInvocationResult.Completed(
            ToolResult(
                prepared.call.callId,
                execution.output,
                isError: execution.isError,
                receiptId: if (execution.receiptId == "") {
                    prepared.operationId.value
                } else {
                    execution.receiptId
                }
            )
        ))
    }


    private func appendAudit(
        context: ToolInvocationContext,
        action: String,
        call: ToolCall,
        capability: Capability,
        decisionSource!: ?ApprovalDecisionSource = None,
        metadata!: ?ToolApprovalMetadata = None
    ): Result<Unit> {
        let fields = ArrayList<ValueField>()
        fields.add(ValueField("action", textValue(action)))
        fields.add(ValueField("tool", textValue(call.name)))
        fields.add(ValueField("call_id", textValue(call.callId)))
        fields.add(ValueField("argument_hash", textValue(approvalArgumentHash(call, capability))))
        fields.add(ValueField("capability", textValue(capabilityName(capability.kind))))
        fields.add(ValueField("resource", textValue(capability.resource)))
        match (decisionSource) {
            case Some(source) => fields.add(ValueField("decision_source", textValue(approvalDecisionSourceName(source))))
            case None => ()
        }
        match (metadata) {
            case Some(value) =>
                fields.add(ValueField("permission_class", textValue(value.capabilityLabel)))
                fields.add(ValueField("risk_level", textValue(approvalRiskLevelName(value.assessment.level))))
                fields.add(ValueField("risk_flags", approvalStringValues(value.assessment.flags)))
                fields.add(ValueField("risk_reasons", approvalStringValues(value.assessment.reasons)))
            case None => ()
        }
        audit.append(
            AgentEvent(
                EventMeta(
                    context.nextAuditSequence(),
                    TraceId("tool-audit-" + context.runId.value),
                    context.runId,
                    toolCallId: Some(ToolCallId(call.callId))
                ),
                AgentEventPayload.Extension(
                    AgentEventKind.Audit,
                    objectValue(fields.toArray())
                )
            )
        )
    }
}

public class MemoryPermissionRepository <: PermissionRepository {
    private let lock = Mutex()
    private let grants = ArrayList<MemoryApprovalGrant>()

    public init() {}

    public func allows(
        sessionId: SessionId,
        scope: ApprovalGrantScope
    ): Result<Bool> {
        lock.lock()
        try {
            for (candidate in grants) {
                if (candidate.sessionId == sessionId.value && approvalGrantAllows(candidate.scope, scope)) {
                    return Result.Ok(true)
                }
            }
            Result.Ok(false)
        } finally {
            lock.unlock()
        }
    }

    public func grant(
        sessionId: SessionId,
        scope: ApprovalGrantScope
    ): Result<Unit> {
        lock.lock()
        try {
            for (candidate in grants) {
                if (candidate.sessionId == sessionId.value && approvalGrantSame(candidate.scope, scope)) {
                    return Result.Ok(())
                }
            }
            grants.add(MemoryApprovalGrant(sessionId.value, scope))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }
}

class MemoryApprovalGrant {
    let sessionId: String
    let scope: ApprovalGrantScope

    init(sessionId: String, scope: ApprovalGrantScope) {
        this.sessionId = sessionId
        this.scope = scope
    }
}

public func networkPolicyForToolCall(call: ToolCall): Result<NetworkPolicy> {
    if (call.arguments.unifiedKind != ValueKind.Object) {
        return Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
    }
    match (call.arguments.field("network")) {
        case Some(value) => parseNetworkPolicy(value)
        case None => Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
    }
}

func networkPolicyForNormalizedCall(
    call: ToolCall,
    descriptor: ToolDescriptor
): NetworkPolicy {
    match (descriptor.networkPolicy(call)) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalArgumentException(error.message)
    }
}

public func normalizedToolOperationPlan(
    context: ToolInvocationContext,
    call: ToolCall,
    descriptor: ToolDescriptor
): NormalizedOperationPlan {
    let networkPolicy = networkPolicyForNormalizedCall(call, descriptor)
    let canonicalArguments = canonicalToolArguments(call.arguments)
    let required = descriptor.requiredCapabilities(call)
    let paths = ArrayList<String>()
    let hosts = ArrayList<String>()
    let capabilities = ArrayList<AgentValue>()
    for (capability in required) {
        capabilities.add(textValue(
            capabilityName(capability.kind) + ":" + capability.resource
        ))
        if (capability.resource != "") {
            match (capability.kind) {
                case CapabilityKind.WorkspaceRead | CapabilityKind.WorkspaceWrite =>
                    addUniqueOperationResource(paths, capability.resource)
                case CapabilityKind.NetworkAccess =>
                    addUniqueOperationResource(hosts, capability.resource)
                case _ => ()
            }
        }
    }
    let environment = ArrayList<ValueField>()
    for (entry in context.environment.entries()) {
        environment.add(ValueField(entry.name, textValue(entry.value)))
    }
    let effect = if (!descriptor.sideEffecting) {
        OperationEffectClass.ReadOnly
    } else if (operationCapabilitiesStayInWorkspace(required)) {
        OperationEffectClass.WorkspaceMutation
    } else {
        OperationEffectClass.ExternalMutation
    }
    let retry = if (effect == OperationEffectClass.ReadOnly) {
        OperationRetryDisposition.Safe
    } else {
        OperationRetryDisposition.Never
    }
    let cwd = if (context.cwd.trimAscii() == "") {
        context.workspaceRoot
    } else {
        context.cwd
    }
    let metadata = descriptor.approvalMetadata(call)
    let writeBinding = match (metadata.writeSummary) {
        case Some(summary) => objectValue([
            ValueField("action", textValue(summary.action)),
            ValueField("exists", boolValue(summary.exists)),
            ValueField("content_hash", textValue(summary.contentHash)),
            ValueField("path", textValue(summary.path))
        ])
        case None => objectValue([])
    }
    let bindingValue = objectValue([
        ValueField("tool", textValue(call.name)),
        ValueField("arguments", canonicalArguments),
        ValueField("capabilities", listValue(capabilities.toArray())),
        ValueField("paths", operationStringList(paths.toArray())),
        ValueField("hosts", operationStringList(hosts.toArray())),
        ValueField("network", networkPolicyCanonicalValue(networkPolicy)),
        ValueField("cwd", textValue(cwd)),
        ValueField("environment", objectValue(environment.toArray())),
        ValueField("approval", objectValue([
            ValueField("capability_label", textValue(metadata.capabilityLabel)),
            ValueField("risk", textValue(approvalRiskLevelName(metadata.assessment.level))),
            ValueField("grant_capability", textValue(metadata.grantScope.capability)),
            ValueField("grant_path", textValue(metadata.grantScope.pathPrefix)),
            ValueField("grant_tool", textValue(metadata.grantScope.toolName)),
            ValueField("grant_host", textValue(metadata.grantScope.host)),
            ValueField("write", writeBinding)
        ])),
        ValueField("effect", textValue(match (effect) {
            case OperationEffectClass.ReadOnly => "read_only"
            case OperationEffectClass.WorkspaceMutation => "workspace_mutation"
            case OperationEffectClass.ExternalMutation => "external_mutation"
        })),
        ValueField("retry", textValue(match (retry) {
            case OperationRetryDisposition.Safe => "safe"
            case OperationRetryDisposition.ByIdempotencyKey => "idempotency_key"
            case OperationRetryDisposition.VerifyThenRetry => "verify_then_retry"
            case OperationRetryDisposition.Never => "never"
        }))
    ])
    NormalizedOperationPlan(
        call.name,
        canonicalArguments,
        required,
        effect,
        retry,
        approvalHash(canonicalApprovalValue(bindingValue)),
        resolvedPaths: paths.toArray(),
        networkPolicy: Some(networkPolicy),
        resolvedHosts: hosts.toArray(),
        cwd: cwd,
        relevantEnvironment: environment.toArray(),
        approvalMetadata: Some(metadata)
    )
}
func primaryPlanCapability(plan: NormalizedOperationPlan): Capability {
    if (plan.requiredCapabilities.isEmpty()) {
        Capability(CapabilityKind.WorkspaceRead)
    } else {
        plan.requiredCapabilities[0]
    }
}

func sameNormalizedOperationPlan(
    left: NormalizedOperationPlan,
    right: NormalizedOperationPlan
): Bool {
    left.toolName == right.toolName &&
        canonicalApprovalValue(left.canonicalArguments) == canonicalApprovalValue(right.canonicalArguments) &&
        sameStringArray(left.resolvedPaths, right.resolvedPaths) &&
        sameStringArray(left.resolvedHosts, right.resolvedHosts) &&
        canonicalApprovalValue(networkPolicyCanonicalValue(left.networkPolicy)) ==
            canonicalApprovalValue(networkPolicyCanonicalValue(right.networkPolicy)) &&
        left.cwd == right.cwd &&
        canonicalApprovalValue(objectValue(left.relevantEnvironment)) ==
            canonicalApprovalValue(objectValue(right.relevantEnvironment)) &&
        sameCapabilities(left.requiredCapabilities, right.requiredCapabilities) &&
        sameApprovalMetadata(left.approvalMetadata, right.approvalMetadata) &&
        left.effectClass == right.effectClass &&
        left.retryDisposition == right.retryDisposition &&
        left.idempotencyKey == right.idempotencyKey &&
        left.bindingDigest == right.bindingDigest &&
        sameReplayDisposition(left.replayDisposition, right.replayDisposition) &&
        left.implementation.toolId == right.implementation.toolId &&
        left.implementation.toolVersion == right.implementation.toolVersion &&
        left.implementation.implementationFingerprint ==
            right.implementation.implementationFingerprint &&
        left.implementation.schemaDigest == right.implementation.schemaDigest &&
        left.implementation.effectiveArgumentsDigest ==
            right.implementation.effectiveArgumentsDigest &&
        left.implementation.replayContractVersion ==
            right.implementation.replayContractVersion
}

func sameStringArray(left: Array<String>, right: Array<String>): Bool {
    if (left.size != right.size) { return false }
    for (index in 0..left.size where left[index] != right[index]) {
        return false
    }
    true
}

func sameCapabilities(left: Array<Capability>, right: Array<Capability>): Bool {
    if (left.size != right.size) { return false }
    for (index in 0..left.size) {
        if (left[index].kind != right[index].kind ||
            left[index].resource != right[index].resource) {
            return false
        }
    }
    true
}

func sameApprovalMetadata(
    left: ToolApprovalMetadata,
    right: ToolApprovalMetadata
): Bool {
    left.capabilityLabel == right.capabilityLabel &&
        left.assessment.level == right.assessment.level &&
        sameStringArray(left.assessment.flags, right.assessment.flags) &&
        sameStringArray(left.assessment.reasons, right.assessment.reasons) &&
        left.grantScope.capability == right.grantScope.capability &&
        left.grantScope.pathPrefix == right.grantScope.pathPrefix &&
        left.grantScope.toolName == right.grantScope.toolName &&
        left.grantScope.host == right.grantScope.host &&
        left.grantScope.sessionOnly == right.grantScope.sessionOnly
}

func sameReplayDisposition(
    left: ReplayDisposition,
    right: ReplayDisposition
): Bool {
    match ((left, right)) {
        case (ReplayDisposition.Pure, ReplayDisposition.Pure) => true
        case (ReplayDisposition.SafeReplay, ReplayDisposition.SafeReplay) => true
        case (ReplayDisposition.Idempotent(a), ReplayDisposition.Idempotent(b)) => a == b
        case (ReplayDisposition.RecoverByProbe(a), ReplayDisposition.RecoverByProbe(b)) =>
            a.value == b.value
        case (ReplayDisposition.Compensatable(a), ReplayDisposition.Compensatable(b)) =>
            a.value == b.value
        case (ReplayDisposition.AtMostOnce, ReplayDisposition.AtMostOnce) => true
        case (ReplayDisposition.NeverReplay, ReplayDisposition.NeverReplay) => true
        case _ => false
    }
}

func canonicalToolArguments(arguments: AgentValue): AgentValue {
    let fields = ArrayList<ValueField>()
    if (arguments.unifiedKind == ValueKind.Object) {
        for (field in arguments.fields) {
            fields.add(field)
        }
    }
    objectValue(fields.toArray())
}

func addUniqueOperationResource(values: ArrayList<String>, candidate: String): Unit {
    for (value in values where value == candidate) { return }
    values.add(candidate)
}

func operationCapabilitiesStayInWorkspace(values: Array<Capability>): Bool {
    for (value in values) {
        match (value.kind) {
            case CapabilityKind.WorkspaceRead | CapabilityKind.WorkspaceWrite => ()
            case _ => return false
        }
    }
    true
}

func operationStringList(values: Array<String>): AgentValue {
    let items = ArrayList<AgentValue>()
    for (value in values) { items.add(textValue(value)) }
    listValue(items.toArray())
}

public func approvalArgumentHash(
    call: ToolCall,
    capability: Capability
): String {
    requiredCapabilitiesArgumentHash(call, [capability])
}

public func requiredCapabilitiesArgumentHash(
    call: ToolCall,
    capabilities: Array<Capability>
): String {
    var source = call.name + "\u{001f}" +
        canonicalApprovalValue(call.arguments)
    for (capability in capabilities) {
        source += "\u{001f}" + capabilityName(capability.kind) +
            "\u{001f}" + capability.resource
    }
    approvalHash(source)
}

public func approvalRiskFlags(
    call: ToolCall,
    capability: Capability
): Array<String> {
    let flags = ArrayList<String>()
    let source = canonicalApprovalValue(call.arguments).toAsciiLower()
    let command = approvalTextField(call.arguments, "command").toAsciiLower()
    if (containsAny(
        command,
        [
            "rm -rf",
            "rm -fr",
            "find ",
            " -delete",
            "truncate ",
            "shred ",
            "mkfs",
            "dd if=",
            "dd of="
        ]
    ) && (command.contains("rm ") || command.contains("-delete") || command.contains("truncate ") || command.contains(
        "shred ") || command.contains("mkfs") || command.contains("dd "))) {
        addApprovalFlag(flags, "destructive")
    }
    if (containsAny(
        command,
        [
            "git reset --hard",
            "git clean -fd",
            "git clean -df",
            "git push --force",
            "git push -f",
            "git branch -d"
        ]
    )) {
        addApprovalFlag(flags, "git_destructive")
    }
    if (containsAny(
        command,
        [
            "curl ",
            "wget ",
            "ssh ",
            "scp ",
            "rsync ",
            " nc ",
            "ncat ",
            "socat ",
            "git clone",
            "git fetch",
            "git push",
            "npm ",
            "pnpm ",
            "cargo install",
            "pip install"
        ]
    ) || capability.kind == CapabilityKind.NetworkAccess) {
        addApprovalFlag(flags, "network")
    }
    if (call.name != "write" && containsAny(
        source,
        [
            "/.ssh",
            "~/.ssh",
            "/.aws",
            "~/.aws",
            "/.gnupg",
            "~/.gnupg",
            ".env",
            "credentials",
            "cookie",
            "keychain",
            "id_ed25519",
            "id_rsa"
        ]
    )) {
        addApprovalFlag(flags, "sensitive_data")
    }
    if (containsAny(
        command,
        [
            "sudo ",
            "su -",
            "systemctl ",
            "mount ",
            "umount ",
            "iptables ",
            "nft ",
            "sysctl ",
            "useradd ",
            "userdel ",
            "apt install",
            "apt remove",
            "dnf install",
            "pacman -s"
        ]
    )) {
        addApprovalFlag(flags, "system_change")
    }
    if (containsAny(
        command,
        [
            "kill ",
            "pkill ",
            "killall ",
            "systemctl stop",
            "docker rm",
            "docker system prune"
        ]
    )) {
        addApprovalFlag(flags, "process_control")
    }
    if (containsAny(
        command,
        [
            "bash -c",
            "sh -c",
            "eval ",
            "xargs ",
            "python -c",
            "python3 -c",
            "node -e",
            "perl -e",
            "$(",
            "`",
            "<<"
        ]
    )) {
        addApprovalFlag(flags, "dynamic_execution")
    }
    if (call.name != "write" && containsAny(
        source,
        [
            "../",
            "~/",
            "/tmp/",
            "/etc/",
            "/usr/",
            "/var/",
            "/home/",
            "~/.config",
            "~/.local"
        ]
    )) {
        addApprovalFlag(flags, "outside_workspace")
    }
    flags.toArray()
}

public func approvalPermanentDenialReason(request: ApprovalRequest): ?String {
    let command = approvalTextField(request.preview, "command").trimAscii().toAsciiLower()
    if (containsAny(
        command,
        [
            "rm -rf /",
            "rm -fr /",
            "mkfs",
            "dd of=/dev/"
        ]
    )) {
        return Some("permanent safety rule blocks destructive system-wide file operations")
    }
    if (hasApprovalFlag(request.riskFlags, "network") && hasApprovalFlag(request.riskFlags, "sensitive_data")) {
        return Some("permanent safety rule blocks credential or sensitive-data exfiltration")
    }
    if (request.metadata.capabilityLabel == "sensitive-path.read") {
        return Some("permanent safety rule blocks reads from credential or protected system paths")
    }
    if (request.metadata.capabilityLabel == "sensitive-path.write" || hasApprovalFlag(request.metadata.assessment.flags,
        "sensitive_path")) {
        return Some("permanent safety rule blocks writes to credential or protected system paths")
    }
    if (hasApprovalFlag(request.riskFlags, "system_change") && containsAny(command,
        ["/etc/sudoers", "disable security", "bypass permission"])) {
        return Some("permanent safety rule blocks security-policy modification or bypass")
    }
    None
}

func approvalTextField(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Text) {
                item.text
            } else {
                ""
            }
        case None => ""
    }
}

func hasApprovalFlag(values: Array<String>, expected: String): Bool {
    for (value in values where value == expected) {
        return true
    }
    false
}

func addApprovalFlag(values: ArrayList<String>, value: String): Unit {
    for (existing in values where existing == value) {
        return
    }
    values.add(value)
}

func containsAny(source: String, values: Array<String>): Bool {
    for (value in values where source.contains(value)) {
        return true
    }
    false
}

func approvalHash(source: String): String {
    var hash: UInt64 = 1469598103934665603
    for (byte in source.toArray()) {
        hash = (hash ^ UInt64(byte)).wrappingMul(1099511628211)
    }
    hash.toString()
}

func canonicalApprovalValue(value: AgentValue): String {
    match (value.unifiedKind) {
        case ValueKind.Null => "null"
        case ValueKind.Boolean =>
            if (value.asBool()) {
                "true"
            } else {
                "false"
            }
        case ValueKind.Number => value.asNumberText()
        case ValueKind.Text => "t:" + value.text
        case ValueKind.List =>
            var text = "["
            for (item in value.items) {
                text += canonicalApprovalValue(item) + ";"
            }
            text + "]"
        case ValueKind.Object =>
            var text = "{"
            for (field in value.fields) {
                text += field.name + "=" + canonicalApprovalValue(field.value) + ";"
            }
            text + "}"
    }
}

public func approvalGrantAllows(
    granted: ApprovalGrantScope,
    requested: ApprovalGrantScope
): Bool {
    if (!granted.sessionOnly || !requested.sessionOnly || granted.capability != requested.capability) {
        return false
    }
    if (granted.toolName != "" && granted.toolName != requested.toolName) {
        return false
    }
    if (granted.host != "" && granted.host != requested.host) {
        return false
    }
    if (granted.pathPrefix != "") {
        return safePathContains(granted.pathPrefix, requested.pathPrefix)
    }
    requested.pathPrefix == ""
}

func approvalGrantSame(left: ApprovalGrantScope, right: ApprovalGrantScope): Bool {
    left.capability == right.capability && left.pathPrefix == right.pathPrefix && left.toolName == right.toolName &&
        left.host == right.host && left.sessionOnly == right.sessionOnly
}

func safePathContains(parent: String, child: String): Bool {
    let left = normalizedPathParts(parent)
    let right = normalizedPathParts(child)
    if (left.size == 0 || right.size < left.size) {
        return false
    }
    let caseInsensitive = left[0].endsWith(":") || right[0].endsWith(":")
    for (index in 0..left.size) {
        if (caseInsensitive) {
            if (left[index].toAsciiLower() != right[index].toAsciiLower()) {
                return false
            }
        } else if (left[index] != right[index]) {
            return false
        }
    }
    true
}

func normalizedPathParts(value: String): Array<String> {
    let source = value.replace("\\", "/")
    let parts = ArrayList<String>()
    for (part in source.split("/") where part != "" && part != ".") {
        if (part == "..") {
            if (!parts.isEmpty()) {
                parts.remove(at: parts.size - 1)
            }
        } else if (parts.isEmpty() && part.size == 2 && part[1] == b':') {
            parts.add(part.toAsciiLower())
        } else {
            parts.add(part)
        }
    }
    parts.toArray()
}

func mergedApprovalFlags(left: Array<String>, right: Array<String>): Array<String> {
    let values = ArrayList<String>()
    for (value in left) {
        addApprovalFlag(values, value)
    }
    for (value in right) {
        addApprovalFlag(values, value)
    }
    values.toArray()
}

func approvalStringValues(values: Array<String>): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in values) {
        result.add(textValue(value))
    }
    listValue(result.toArray())
}

func rejectionFields(toolName: String, reason: String): Array<ErrorField> {
    if (reason.trimAscii() == "") {
        [ErrorField("tool", toolName)]
    } else {
        [
            ErrorField("tool", toolName),
            ErrorField("reason", reason)
        ]
    }
}

func capabilityName(kind: CapabilityKind): String {
    match (kind) {
        case CapabilityKind.WorkspaceRead => "workspace.read"
        case CapabilityKind.WorkspaceWrite => "workspace.write"
        case CapabilityKind.ProcessSpawn => "process.spawn"
        case CapabilityKind.NetworkAccess => "network.access"
        case CapabilityKind.PeerMessage => "peer.message"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension.invoke"
    }
}
