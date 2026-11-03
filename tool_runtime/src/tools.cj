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

// Extra execution-current restriction, never source, approval or effect authority.
// A lease spans only one durable admission transition; callbacks run afterward.
public interface ToolExecutionHandoffLease { func close(): Unit }
class NoopToolExecutionHandoffLease <: ToolExecutionHandoffLease { public func close(): Unit {} }

public interface ToolExecutor {
    func acquireHandoffLease(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolExecutionHandoffLease> {
        Result<ToolExecutionHandoffLease>.Ok(NoopToolExecutionHandoffLease())
    }

    // Executors receive only the immutable prepared invocation. The original
    // call is retained for identity/display; all authority-relevant values
    // come from operationPlan.
    func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult>
    // Legacy executors provide no cancellation evidence. The execution
    // result remains exactly the result of the one original executor call.
    func executeObserved(context: ToolInvocationContext,
        prepared: PreparedToolInvocation): ToolExecutionOutcome {
        ToolExecutionOutcome(execute(context, prepared))
    }

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
public type ToolCanonicalArgumentsResolver = (
    ToolInvocationContext,
    ToolCall
) -> Result<AgentValue>


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
    private let definitionValue: ModelToolDefinition
    private let concurrencyValue: ToolConcurrencyProfile
    private let additionalCapabilitiesValue: Array<Capability>
    private var ownedSnapshot = false
    public prop definition: ModelToolDefinition {
        get() { if (ownedSnapshot) { toolOwnedDefinitionCopy(definitionValue) } else { definitionValue } }
    }
    public prop concurrency: ToolConcurrencyProfile {
        get() { if (ownedSnapshot) { toolOwnedConcurrencyCopy(concurrencyValue) } else { concurrencyValue } }
    }
    public prop additionalCapabilities: Array<Capability> {
        get() { if (ownedSnapshot) { additionalCapabilitiesValue.clone() } else { additionalCapabilitiesValue } }
    }
    public let capability: Capability
    public let sideEffecting: Bool
    public let controlOnly: Bool
    public let hostServiceOnly: Bool
    public let neverReplay: Bool
    public let implementationVersion: String
    public let implementationFingerprint: String
    public let schemaDigest: String
    private let capabilityResolver: ?ToolCapabilityResolver
    private let networkPolicyResolver: ?ToolNetworkPolicyResolver
    private let additionalCapabilityResolver: ?ToolAdditionalCapabilityResolver
    private let sideEffectResolver: ?ToolSideEffectResolver
    private let approvalMetadataResolver: ?ToolApprovalMetadataResolver
    // Trusted descriptor metadata only: a real resolver may return None.
    // This does not authorize a read or reuse one decision for two plans.
    public let preparationReadMayBeAbsent: Bool
    private let preparationReadResolver: ?ToolPreparationReadResolver
    public prop hasPreparationRead: Bool { get() { preparationReadResolver.isSome() } }
    private let canonicalArgumentsResolver: ?ToolCanonicalArgumentsResolver
    private let approvalMetadataValue: ?ToolApprovalMetadata

    public init(
        definition: ModelToolDefinition,
        capability: Capability,
        sideEffecting!: Bool = false,
        concurrency!: ToolConcurrencyProfile = ToolConcurrencyProfile(),
        controlOnly!: Bool = false,
        hostServiceOnly!: Bool = false,
        neverReplay!: Bool = false,
        additionalCapabilities!: Array<Capability> = [],
        implementationVersion!: String = "agent-core-v1",
        implementationFingerprint!: String = "",
        capabilityResolver!: ?ToolCapabilityResolver = None,
        additionalCapabilityResolver!: ?ToolAdditionalCapabilityResolver = None,
        sideEffectResolver!: ?ToolSideEffectResolver = None,
        approvalMetadataResolver!: ?ToolApprovalMetadataResolver = None,
        networkPolicyResolver!: ?ToolNetworkPolicyResolver = None,
        approvalMetadataValue!: ?ToolApprovalMetadata = None,
        canonicalArgumentsResolver!: ?ToolCanonicalArgumentsResolver = None,
        preparationReadResolver!: ?ToolPreparationReadResolver = None,
        preparationReadMayBeAbsent!: Bool = false
    ) {
        let version = implementationVersion.trimAscii()
        if (version == "") {
            throw IllegalArgumentException("tool implementation version must not be empty")
        }
        this.definitionValue = definition
        this.capability = capability
        this.sideEffecting = sideEffecting
        this.concurrencyValue = concurrency
        this.controlOnly = controlOnly
        this.hostServiceOnly = hostServiceOnly
        this.neverReplay = neverReplay
        this.additionalCapabilitiesValue = additionalCapabilities
        this.implementationVersion = version
        this.schemaDigest = modelPolicySha256Text(
            canonicalAgentValue(definition.inputSchema)
        )
        this.implementationFingerprint = if (implementationFingerprint.trimAscii() == "") {
            modelPolicySha256Text(
                definition.name + "\n" + version + "\n" + definition.description + "\n" +
                    canonicalAgentValue(definition.inputSchema)
            )
        } else {
            implementationFingerprint.trimAscii()
        }
        this.capabilityResolver = capabilityResolver
        this.additionalCapabilityResolver = additionalCapabilityResolver
        this.sideEffectResolver = sideEffectResolver
        this.approvalMetadataResolver = approvalMetadataResolver
        this.canonicalArgumentsResolver = canonicalArgumentsResolver
        this.preparationReadResolver = preparationReadResolver
        this.preparationReadMayBeAbsent = preparationReadMayBeAbsent && preparationReadResolver.isSome()
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
            controlOnly: controlOnly,
            hostServiceOnly: hostServiceOnly,
            neverReplay: neverReplay,
            concurrency: concurrency,
            additionalCapabilities: resolvedAdditional.toArray(),
            implementationVersion: implementationVersion,
            implementationFingerprint: implementationFingerprint,
            networkPolicyResolver: networkPolicyResolver,
            approvalMetadataResolver: approvalMetadataResolver,
            approvalMetadataValue: Some(match (approvalMetadataValue) {
                case Some(value) => if (ownedSnapshot) { toolOwnedApprovalCopy(value) } else { value }
                case None => match (approvalMetadataResolver) {
                    case Some(resolve) => resolve(call)
                    case None => defaultToolApprovalMetadata(resolvedCapability)
                }
            }),
            canonicalArgumentsResolver: canonicalArgumentsResolver, preparationReadResolver: preparationReadResolver,
            preparationReadMayBeAbsent: preparationReadMayBeAbsent
        )
    }


    // Host-only identity binding preserves every resolver and policy field.
    // Dynamic closures are part of the verified host adapter/package binding;
    // the directory does not execute them or accept them from plugin payloads.
    func withOwnedFingerprint(fingerprint: String): ToolDescriptor {
        copyImplementationBinding(implementationVersion, fingerprint)
    }

    // Trusted composition only. An external contribution cannot mint an
    // instance or derive authority by supplying this public identity string.
    // The caller binds a verified live host instance; its disappearance must
    // leave historical pending calls missing, never redirect them by name.
    public func withExecutorInstance(instanceIdentity: String): Result<ToolDescriptor> {
        if (!toolCatalogIdentifier(instanceIdentity, 512)) {
            return toolCatalogError("tool.instance_invalid", "executor instance identity must be a bounded host identifier")
        }
        try {
            Result.Ok(copyImplementationBinding(implementationVersion + ":instance:" + modelPolicySha256Text(instanceIdentity),
                implementationFingerprint))
        } catch (_: Exception) {
            toolCatalogError("tool.instance_definition_invalid", "instance-bound definition cannot be frozen within JSON limits")
        }
    }

    private func copyImplementationBinding(version: String, fingerprint: String): ToolDescriptor {
        let frozen = ToolDescriptor(toolOwnedDefinitionCopy(definition), capability,
            sideEffecting: sideEffecting, concurrency: toolOwnedConcurrencyCopy(concurrency),
            controlOnly: controlOnly, hostServiceOnly: hostServiceOnly,
            neverReplay: neverReplay, additionalCapabilities: additionalCapabilities.clone(),
            implementationVersion: version, implementationFingerprint: fingerprint,
            capabilityResolver: capabilityResolver, additionalCapabilityResolver: additionalCapabilityResolver,
            sideEffectResolver: sideEffectResolver, approvalMetadataResolver: approvalMetadataResolver,
            networkPolicyResolver: networkPolicyResolver, approvalMetadataValue: match (approvalMetadataValue) {
                case Some(value) => Some(toolOwnedApprovalCopy(value))
                case None => None
            },
            canonicalArgumentsResolver: canonicalArgumentsResolver, preparationReadResolver: preparationReadResolver,
            preparationReadMayBeAbsent: preparationReadMayBeAbsent)
        if (frozen.schemaDigest != schemaDigest) {
            throw IllegalArgumentException("tool schema changed after descriptor construction")
        }
        frozen.ownedSnapshot = true
        frozen
    }

    func ownedPolicyIdentity(): AgentValue {
        let identity = objectValue([
            ValueField("capability_resolver", boolValue(capabilityResolver.isSome())),
            ValueField("additional_capability_resolver", boolValue(additionalCapabilityResolver.isSome())),
            ValueField("side_effect_resolver", boolValue(sideEffectResolver.isSome())),
            ValueField("approval_resolver", boolValue(approvalMetadataResolver.isSome())),
            ValueField("network_resolver", boolValue(networkPolicyResolver.isSome())),
            ValueField("canonical_arguments_resolver", boolValue(canonicalArgumentsResolver.isSome())),
            ValueField("static_approval", match (approvalMetadataValue) {
                case Some(value) => toolOwnedApprovalMetadata(value)
                case None => nullValue()
            })
        ])
        if (preparationReadResolver.isSome()) { identity.put("preparation_read_resolver", boolValue(true)) }
        if (preparationReadMayBeAbsent) { identity.put("preparation_read_may_be_absent", boolValue(true)) }
        identity
    }

    func hasRawPreparedCallResolver204(): Bool {
        canonicalArgumentsResolver.isSome() || preparationReadResolver.isSome()
    }
    public func preparationRead(context: ToolInvocationContext, call: ToolCall): Result<?ToolPreparationRead> {
        let view = context.beginInvocationView159()
        try { preparationReadFrame159(view, call) } finally { view.endInvocationView159() }
    }

    private func preparationReadFrame159(context: ToolInvocationContext, call: ToolCall): Result<?ToolPreparationRead> {
        match (preparationReadResolver) {
            case Some(resolve) => try { resolve(context, call) } catch (_: Exception) {
                Result.Err(AgentError(AgentErrorKind.InvalidInput, "context.read_request_invalid", "preparation read request could not be frozen")) }
            case None => Result.Ok(None)
        }
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

    // Read the private backing without the public getters' schema/array copies.
    // The original getter behavior below is still used after this invoice.
    func measureSnapshotData159(meter: ToolSnapshotMeasure159): Unit {
        meter.addText159(definitionValue.name); meter.addText159(definitionValue.description)
        meter.addValue159(definitionValue.inputSchema)
        meter.addText159(implementationVersion); meter.addText159(implementationFingerprint)
        meter.addText159(schemaDigest); meter.addCapability159(capability)
        meter.addSlots159(additionalCapabilitiesValue.size + 1)
        for (value in additionalCapabilitiesValue) { meter.addCapability159(value) }
    }

    // Same predicate as requiredCapabilities()+allows, without allocating
    // or returning a copied capability array. Duplicate requirements do not
    // change conjunction, and no invocation/approval authority is minted.
    func capabilitiesAllow159(capabilities: CapabilitySet): Bool {
        if (!capabilities.allows(capability.kind, resource: capability.resource)) { return false }
        for (value in additionalCapabilitiesValue) {
            if (!capabilities.allows(value.kind, resource: value.resource)) { return false }
        }
        true
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
            case Some(value) => if (ownedSnapshot) { toolOwnedApprovalCopy(value) } else { value }
            case None => match (approvalMetadataResolver) {
                case Some(resolve) => resolve(call)
                case None => defaultToolApprovalMetadata(capability)
            }
        }
    }

    public func canonicalizedCall(context: ToolInvocationContext, call: ToolCall): Result<ToolCall> {
        let view = context.beginInvocationView159()
        try { canonicalizedCallFrame159(view, call) } finally { view.endInvocationView159() }
    }

    private func canonicalizedCallFrame159(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolCall> {
        match (canonicalArgumentsResolver) {
            case None => Result.Ok(call)
            case Some(resolve) => match (resolve(context, call)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(arguments) => if (arguments.unifiedKind == ValueKind.Object) {
                    Result.Ok(ToolCall(call.callId, call.name, arguments))
                } else {
                    Result.Err(AgentError(
                        AgentErrorKind.InvalidInput,
                        "tool.normalized_arguments_invalid",
                        "normalized tool arguments must be an object",
                        fields: [ErrorField("tool", call.name)]
                    ))
                }
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

class ActiveToolExecution {
    let operationId: OperationId
    let runId: RunId

    init(operationId: OperationId, runId: RunId) {
        this.operationId = operationId
        this.runId = runId
    }
}

class ToolRevocationTarget {
    let executor: ToolExecutor
    let runIds: Array<RunId>

    init(executor: ToolExecutor, runIds: Array<RunId>) {
        this.executor = executor
        this.runIds = runIds
    }
}
public class ToolCatalogRegistration {
    public let descriptor: ToolDescriptor
    public let executor: ToolExecutor

    public init(descriptor: ToolDescriptor, executor: ToolExecutor) {
        this.descriptor = descriptor
        this.executor = executor
    }
}

class ToolRegistration {
    let descriptor: ToolDescriptor
    let executor: ToolExecutor
    let owner: ?ToolCatalogOwner
    var active: Bool
    var revoked: Bool = false
    let activeExecutions = ArrayList<ActiveToolExecution>()

    init(descriptor: ToolDescriptor, executor: ToolExecutor, owner!: ?ToolCatalogOwner = None) {
        this.descriptor = descriptor
        this.executor = executor
        this.owner = owner
        this.active = true
    }
}

func toolHookAvailableAtSnapshot(
    handler: ToolHookHandlerSnapshot,
    capabilities: CapabilitySet
): Bool {
    if (!handler.command.startsWith("pi.event:")) { return true }
    if (!capabilities.allows(
        CapabilityKind.ExtensionInvoke, resource: handler.pluginId
    )) { return false }
    if (handler.event == "PreToolUse") {
        return capabilities.allows(CapabilityKind.WorkspaceWrite)
    }
    capabilities.allows(CapabilityKind.WorkspaceRead) ||
        capabilities.allows(CapabilityKind.WorkspaceWrite)
}

// Optional caller-owned DATA invoice only. This interface cannot register,
// invoke, revoke, mint a Source, or change a Tool's capabilities. Raw catalog
// aliases keep the caller's allocation retained until separately retired.
public interface ToolCatalogDataPayment159 {
    func reserveCatalogData159(bytes: Int64): Unit
    func reserveTemporaryCatalogData159(bytes: Int64): ToolCatalogTemporaryData159
}
// A return marker, not an ACK or allocator. The Host retains the actual
// original-bank child until its enclosing private construction frame returns.
// DATA-only snapshot child from the already retained actual Registry bank.
public interface ToolCatalogSnapshotPayment159 {
    func reserveSnapshotCatalogData159(bytes: Int64): LogicalJsonOwnerReservation
    // The exact child invoice for `reserveSnapshotCatalogData159`, so a caller
    // that owns a declared pool of its own can serve the same amount from it.
    func snapshotCatalogDataInvoice159(): Int64
}

public interface ToolCatalogTemporaryData159 {
    func returnedTemporaryHelper159(): Unit
    func newBacking159(bytes: Int64): ToolCatalogBackingData159
    func prepareBackingPublication159(previous: ?ToolCatalogBackingData159): Unit
}
public interface ToolCatalogBackingData159 {
    func growBacking159(bytes: Int64): Unit
    func retainUnknownBacking159(): Unit
}
private func toolCatalogDataInvoice159(count: Int64, perEntry: Int64): Int64 {
    if (count < 0 || perEntry < 1 || count > (Int64.Max - 8192) / perEntry) {
        throw IllegalStateException("catalog data invoice overflow")
    }
    8192 + count * perEntry
}

// This is DATA custody only. Neither interface grants a Tool/Source operation.
public interface ToolCatalogRetirableData159 {
    func retainCatalogData159(): ToolCatalogDataLease159
}
public interface ToolCatalogDataLease159 {
    func catalogProducerReturned159(): Bool
    func catalogReferencesReturned159(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation)
}
public interface ToolCatalogRetirableBacking159 {
    func backingProducerReturned159(): Bool
    func backingReferencesReturned159(): ?LogicalJsonOwnerReservation
}
private class ToolCatalogDataLink159 {
    var value: ?ToolCatalogDataLease159
    var next: ?ToolCatalogDataLink159
    init(value: ToolCatalogDataLease159, next: ?ToolCatalogDataLink159) {
        this.value = Some(value); this.next = next
    }
}
public class ToolCatalog {
    private var registrationsData159: ?ArrayList<ToolRegistration> = Some(ArrayList<ToolRegistration>())
    private prop registrations: ArrayList<ToolRegistration> {
        get() { registrationsData159.getOrThrow() }
    }
    private var backing159: ?ToolCatalogBackingData159 = Option<ToolCatalogBackingData159>.None
    private var snapshotPayment159: ?ToolCatalogSnapshotPayment159 = Option<ToolCatalogSnapshotPayment159>.None
    private var hookHandlersData159: ?ArrayList<ToolHookHandlerSnapshot> = Some(ArrayList<ToolHookHandlerSnapshot>())
    private prop hookHandlers: ArrayList<ToolHookHandlerSnapshot> {
        get() { hookHandlersData159.getOrThrow() }
    }
    private let lock = Mutex()
    private let dataRetirementLock159 = Mutex()
    private var dataClosed159 = false
    private var rawAliases159 = false
    private var publicationFrames159: Int64 = 0
    private var hostConsumerFrames204: Int64 = 0
    private var pendingConsumerPayment204: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var dataOwners159: ?ToolCatalogDataLink159 = None<ToolCatalogDataLink159>
    private let ownerSeal = ToolCatalogSeal()
    private var ownersData159: ?ArrayList<ToolCatalogOwnerState> = Some(ArrayList<ToolCatalogOwnerState>())
    private prop owners: ArrayList<ToolCatalogOwnerState> {
        get() { ownersData159.getOrThrow() }
    }

    public init() {}

    // Closed scalar consumer: no definition, schema, callback or String alias
    // leaves this helper. The caller owns the expected identity strings.
    public func definitionNamesEqual159(expected: Array<String>, threadId!: ?ThreadId = None): Bool {
        lock.lock()
        try {
            if (dataClosed159) { return false }
            var index: Int64 = 0
            for (item in registrations where item.active && !item.revoked && toolRegistrationVisible(item, threadId) &&
                !item.descriptor.controlOnly && !item.descriptor.hostServiceOnly) {
                if (index >= expected.size || item.descriptor.definition.name != expected[index]) { return false }
                index++
            }
            index == expected.size
        } finally { lock.unlock() }
    }
    // Called only after the caller's own producer/worker helpers return.
    // Public raw exports and private pipeline lookups stay explicitly Held
    // until those callers migrate to counted typed consumers.
    public func retireCatalogData159(): Bool {
        dataRetirementLock159.lock()
        try { retireCatalogDataFrame159() } finally { dataRetirementLock159.unlock() }
    }
    private func retireCatalogDataFrame159(): Bool {
        if (!clearCatalogFrame159()) { return false }
        let backing = takeReturnedCatalogBacking159()
        match (backing) {
            case Some(value) => match (value) {
                case actual: ToolCatalogRetirableBacking159 =>
                    let returned = actual.backingReferencesReturned159()
                    match (returned) { case Some(payment) => payment.close(); case None => return false }
                case _ => return false
            }
            case None => ()
        }
        while (true) {
            match (takeReturnedCatalogOwner159()) {
                case Some(owner) =>
                    let returned = owner.catalogReferencesReturned159()
                    match (returned[0]) { case Some(value) => value.close(); case None => () }
                    match (returned[1]) { case Some(value) => value.close(); case None => () }
                case None => break
            }
        }
        true
    }
    private func clearCatalogFrame159(): Bool {
        lock.lock()
        try {
            if (dataClosed159) { return true }
            if (rawAliases159 || publicationFrames159 != 0 || hostConsumerFrames204 != 0 || pendingConsumerPayment204.isSome()) { return false }
            for (entry in registrations where !entry.activeExecutions.isEmpty()) { return false }
            var link = dataOwners159
            while (link.isSome()) {
                let current = link.getOrThrow()
                if (!current.value.getOrThrow().catalogProducerReturned159()) { return false }
                link = current.next
            }
            match (backing159) {
                case Some(value) => match (value) {
                    case actual: ToolCatalogRetirableBacking159 => if (!actual.backingProducerReturned159()) { return false }
                    case _ => return false
                }
                case None => ()
            }
            // Publication has stopped under the same lock. Drop the actual
            // list objects and their backing, not merely their logical sizes.
            // Private getters reject use after this terminal DATA retirement.
            dataClosed159 = true
            registrationsData159 = None<ArrayList<ToolRegistration>>
            hookHandlersData159 = None<ArrayList<ToolHookHandlerSnapshot>>
            ownersData159 = None<ArrayList<ToolCatalogOwnerState>>
            snapshotPayment159 = None<ToolCatalogSnapshotPayment159>
            true
        } finally { lock.unlock() }
    }
    private func takeReturnedCatalogOwner159(): ?ToolCatalogDataLease159 {
        lock.lock()
        try {
            if (!dataClosed159 || rawAliases159 || publicationFrames159 != 0) { return None<ToolCatalogDataLease159> }
            match (dataOwners159) {
                case None => None<ToolCatalogDataLease159>
                case Some(node) =>
                    dataOwners159 = node.next
                    node.next = None<ToolCatalogDataLink159>
                    let value = node.value
                    node.value = None<ToolCatalogDataLease159>
                    value
            }
        } finally { lock.unlock() }
    }
    private func takeReturnedCatalogBacking159(): ?ToolCatalogBackingData159 {
        lock.lock()
        try {
            if (!dataClosed159 || rawAliases159 || publicationFrames159 != 0) { return None<ToolCatalogBackingData159> }
            let value = backing159
            backing159 = None<ToolCatalogBackingData159>
            value
        } finally { lock.unlock() }
    }
    func prepareHostConsumer204(pipeline: ToolPipeline, context: ToolInvocationContext): ?ToolCatalogHostConsumer204 {
        lock.lock()
        try {
            if (dataClosed159 || pendingConsumerPayment204.isSome() || hostConsumerFrames204 == Int64.Max) {
                throw IllegalStateException("Catalog has no live scoped consumer")
            }
            match (snapshotPayment159) {
                case None => None<ToolCatalogHostConsumer204>
                case Some(original) =>
                    // Drawn from the audit-frame pool rather than the shared
                    // host bank; the invoice is the amount the shared bank
                    // would have charged, so this call's own accounting is
                    // unchanged while the bank keeps its exact totals.
                    let paid = acquireAuditFramePayment204(original.snapshotCatalogDataInvoice159())
                    pendingConsumerPayment204 = Some(paid)
                    let consumer = ToolCatalogHostConsumer204(this, pipeline, context, paid)
                    hostConsumerFrames204++
                    pendingConsumerPayment204 = None<LogicalJsonOwnerReservation>
                    Some(consumer)
            }
        } finally { lock.unlock() }
    }
    func hostConsumerReturned204(): Unit {
        lock.lock()
        try {
            if (hostConsumerFrames204 < 1) { throw IllegalStateException("Catalog consumer count underflow") }
            hostConsumerFrames204--
        } finally { lock.unlock() }
    }
    func recordUnknownConsumer204(): Unit { recordRawCatalogAlias159() }

    private func recordRawCatalogAlias159(): Unit {
        lock.lock()
        try { if (!dataClosed159) { rawAliases159 = true } }
        finally { lock.unlock() }
    }
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
            if (dataClosed159) { return toolCatalogError("tool.catalog_closed", "catalog data was retired") }
            for (item in registrations where item.active && !item.revoked && item.descriptor.definition.name == descriptor.definition.name) {
                return Result.Err(
                    AgentError(
                        AgentErrorKind.Configuration,
                        "tool.duplicate",
                        "tool is already registered",
                        fields: [ErrorField("tool", descriptor.definition.name)]
                    )
                )
            }
            for (item in registrations where toolCatalogSameIdentity(item.descriptor, descriptor)) {
                return toolCatalogError("tool.registration_identity_reused",
                    "a retained or revoked executor already owns this immutable identity")
            }
            if (registrations.size >= 8192) {
                return toolCatalogError("tool.catalog_capacity_exceeded", "retained tool registration limit reached")
            }
            match (backing159) {
                case Some(value) => value.growBacking159(toolCatalogDataInvoice159(registrations.size + 1, 128))
                case None => ()
            }
            registrations.add(ToolRegistration(descriptor, executor))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    // Candidates are staged before mutation, then published by one locked list replacement.
    // An empty batch is a no-op.
    public func registerBatch(entries: Array<ToolCatalogRegistration>,
        dataPayment!: ?ToolCatalogDataPayment159 = None): Result<Unit> {
        lock.lock()
        try {
            if (dataClosed159 || publicationFrames159 == Int64.Max) {
                return toolCatalogError("tool.catalog_closed", "catalog has no live publication owner")
            }
            publicationFrames159++
        } finally { lock.unlock() }
        try { registerBatchBorrowed159(entries, dataPayment: dataPayment) }
        catch (error: Exception) { recordRawCatalogAlias159(); throw error }
        finally { lock.lock(); try { publicationFrames159-- } finally { lock.unlock() } }
    }

    private func registerBatchBorrowed159(entries: Array<ToolCatalogRegistration>,
        dataPayment!: ?ToolCatalogDataPayment159 = None): Result<Unit> {
        let temporary = match (dataPayment) {
            case Some(value) =>
                // Registrations and their published backing list survive the
                // staging frame. Keep their invoice in the original identity.
                value.reserveCatalogData159(toolCatalogDataInvoice159(entries.size, 4096))
                Some(value.reserveTemporaryCatalogData159(toolCatalogDataInvoice159(entries.size, 128)))
            case None => Option<ToolCatalogTemporaryData159>.None
        }
        // No finally marker: an opaque exception retains the phase. A normal
        // Result has no staging-list alias; the helper has physically returned.
        let result = registerBatchFrame159(entries, dataPayment, temporary)
        match (temporary) { case Some(value) => value.returnedTemporaryHelper159(); case None => () }
        result
    }
    private func registerBatchFrame159(entries: Array<ToolCatalogRegistration>,
        dataPayment: ?ToolCatalogDataPayment159, temporary: ?ToolCatalogTemporaryData159): Result<Unit> {
        let staged = ArrayList<ToolRegistration>()
        for (entry in entries) {
            let descriptor = entry.descriptor
            if (descriptor.sideEffecting && !sharedSideEffectHasWrite(descriptor.concurrency)) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "tool.shared_side_effect_without_write",
                    "a side-effecting shared tool must declare at least one write resource",
                    fields: [ErrorField("tool", descriptor.definition.name)]
                ))
            }
            for (existing in staged where
                existing.descriptor.definition.name == descriptor.definition.name) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "tool.duplicate",
                    "tool name is duplicated in the registration batch",
                    fields: [ErrorField("tool", descriptor.definition.name)]
                ))
            }
            staged.add(ToolRegistration(descriptor, entry.executor))
        }
        if (staged.size == 0) { return Result.Ok(()) }

        lock.lock()
        try {
            if (dataClosed159) { return toolCatalogError("tool.catalog_closed", "catalog data was retired") }
            if (registrations.size + staged.size > 8192) {
                return toolCatalogError("tool.catalog_capacity_exceeded", "retained tool registration limit reached")
            }
            for (candidate in staged) {
                let name = candidate.descriptor.definition.name
                for (item in registrations where
                    item.active && !item.revoked && item.descriptor.definition.name == name) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Configuration,
                        "tool.duplicate",
                        "tool is already registered",
                        fields: [ErrorField("tool", name)]
                    ))
                }
                for (item in registrations where toolCatalogSameIdentity(item.descriptor, candidate.descriptor)) {
                    return toolCatalogError("tool.registration_identity_reused",
                        "a retained or revoked executor already owns this immutable identity")
                }
            }
            // Count and fund the exact private backing under this catalog
            // lock. The new child survives staging; it owns no descriptor.
            let replacementBacking159 = match (temporary) {
                case Some(value) => Some(value.newBacking159(toolCatalogDataInvoice159(registrations.size + staged.size, 128)))
                case None => Option<ToolCatalogBackingData159>.None
            }
            let committed = ArrayList<ToolRegistration>()
            for (item in registrations) { committed.add(item) }
            for (item in staged) { committed.add(item) }
            let priorBacking159 = backing159
            match (temporary) {
                case Some(value) => value.prepareBackingPublication159(priorBacking159)
                case None => match (priorBacking159) {
                    case Some(value) => value.retainUnknownBacking159()
                    case None => ()
                }
            }
            // All potentially failing DATA preparation precedes the original
            // publication. Only non-allocating field assignments remain.
            let nextDataOwner159 = match (dataPayment) {
                case Some(value) => match (value) {
                    case actual: ToolCatalogRetirableData159 =>
                        // The original retained parent pays this link before
                        // either the lease carrier or private node is created.
                        value.reserveCatalogData159(4096)
                        Some(ToolCatalogDataLink159(actual.retainCatalogData159(), dataOwners159))
                    case _ => None<ToolCatalogDataLink159>
                }
                case None => None<ToolCatalogDataLink159>
            }
            registrationsData159 = Some(committed)
            backing159 = replacementBacking159
            match (nextDataOwner159) { case Some(value) => dataOwners159 = Some(value); case None => () }
            match (dataPayment) {
                case Some(value) => match (value) {
                    case original: ToolCatalogSnapshotPayment159 => snapshotPayment159 = Some(original)
                    case _ => ()
                }
                case None => ()
            }
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func createContributionOwner(id: String, namespacePrefix: String, threadId!: ?ThreadId = None, maximumEntries!: Int64 = 256, maximumDirectoryBytes!: Int64 = 1048576): Result<ToolCatalogOwner> {
        recordRawCatalogAlias159()
        if (maximumEntries < 1 || maximumEntries > 8192 || maximumDirectoryBytes < 1 || maximumDirectoryBytes > 8388608) {
            return toolCatalogError("tool.owner_limit_invalid", "host catalog owner limits exceed retained bounds")
        }
        if (!toolCatalogIdentifier(id, 256) || !toolCatalogIdentifier(namespacePrefix, 256) ||
            namespacePrefix.size < 2 || !namespacePrefix.endsWith(".")) {
            return toolCatalogError("tool.owner_invalid", "owner and namespace must be bounded host identifiers")
        }
        lock.lock()
        try {
            if (dataClosed159) { return toolCatalogError("tool.catalog_closed", "catalog data was retired") }
            for (state in owners where state.owner.id == id && toolCatalogSameThread(state.owner.threadId, threadId)) {
                return toolCatalogError("tool.owner_already_bound", "a catalog owner cannot be minted twice")
            }
            if (owners.size >= 1024) {
                return toolCatalogError("tool.owner_limit", "catalog owner limit reached")
            }
            let owner = ToolCatalogOwner(id, namespacePrefix, ownerSeal, threadId, maximumEntries, maximumDirectoryBytes)
            owners.add(ToolCatalogOwnerState(owner))
            Result.Ok(owner)
        } finally { lock.unlock() }
    }

    public func contributionRevision(owner: ToolCatalogOwner): Result<Int64> {
        lock.lock()
        try {
            match (ownedState(owner)) {
                case Some(state) => if (state.revoked) {
                    toolCatalogError("tool.owner_revoked", "contribution owner has been revoked")
                } else { Result.Ok(state.revision) }
                case None => toolCatalogError("tool.owner_invalid", "owner belongs to another catalog")
            }
        } finally { lock.unlock() }
    }

    public func replaceOwnedBatch(owner: ToolCatalogOwner, expectedRevision: Int64,
        binding: ToolContributionBinding, entries: Array<ToolCatalogRegistration>): Result<ToolCatalogPublication> {
        recordRawCatalogAlias159()
        publishOwnedBatch(owner, expectedRevision, binding, entries, false)
    }

    // Bootstrap only. The caller must reconstruct the exact verified durable
    // binding; this method does not infer a prior instance from its counter.
    public func restoreOwnedBatch(owner: ToolCatalogOwner, binding: ToolContributionBinding,
        entries: Array<ToolCatalogRegistration>): Result<ToolCatalogPublication> {
        recordRawCatalogAlias159()
        publishOwnedBatch(owner, 0, binding, entries, true)
    }

    private func ownedState(owner: ToolCatalogOwner): ?ToolCatalogOwnerState {
        if (!refEq(owner.seal, ownerSeal)) { return None }
        for (state in owners where refEq(state.owner, owner)) { return Some(state) }
        None
    }

    private func publishOwnedBatch(owner: ToolCatalogOwner, expectedRevision: Int64,
        binding: ToolContributionBinding, entries: Array<ToolCatalogRegistration>, restoring: Bool
    ): Result<ToolCatalogPublication> {
        if (expectedRevision < 0 || expectedRevision == Int64.Max ||
            (!restoring && binding.revision != expectedRevision + 1)) {
            return toolCatalogError("tool.owner_revision_invalid", "publication must advance the exact owner revision")
        }
        if (entries.size > owner.maximumEntries) {
            return toolCatalogError("tool.owner_directory_limit", "owned directory exceeds its sealed host entry limit")
        }
        // Copy the caller's array and mutable descriptor values once. Validation,
        // digesting and publication operate only on this frozen host snapshot.
        let immutableEntries = ArrayList<ToolCatalogRegistration>()
        try {
            for (entry in entries.clone()) {
                immutableEntries.add(ToolCatalogRegistration(entry.descriptor.withOwnedFingerprint(
                    entry.descriptor.implementationFingerprint), entry.executor))
            }
        } catch (_: Exception) {
            return toolCatalogError("tool.owner_definition_invalid", "owned definition cannot be frozen within JSON limits")
        }
        let candidates = immutableEntries.toArray()
        match (validateOwnedToolEntries(owner, candidates)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let digest = toolOwnedDirectoryDigest(candidates)
        let staged = ArrayList<ToolRegistration>()
        let descriptors = ArrayList<ToolDescriptor>()
        try {
            for (entry in candidates) {
                let descriptor = entry.descriptor.withOwnedFingerprint(
                    toolOwnedFingerprint(owner, binding, digest, entry.descriptor))
                staged.add(ToolRegistration(descriptor, entry.executor, owner: Some(owner)))
                descriptors.add(descriptor)
            }
        } catch (_: Exception) {
            return toolCatalogError("tool.owner_definition_invalid", "owned definition cannot be frozen within JSON limits")
        }
        lock.lock()
        try {
            if (dataClosed159) { return toolCatalogError("tool.catalog_closed", "catalog data was retired") }
            let state = match (ownedState(owner)) {
                case Some(value) => value
                case None => return toolCatalogError("tool.owner_invalid", "owner belongs to another catalog")
            }
            if (state.revoked) {
                return toolCatalogError("tool.owner_revoked", "contribution owner has been revoked")
            }
            if (state.revision != expectedRevision) {
                return toolCatalogError("tool.owner_revision_conflict", "contribution directory changed before publication")
            }
            if (registrations.size + staged.size > 8192) {
                return toolCatalogError("tool.catalog_capacity_exceeded", "retained tool registration limit reached")
            }
            for (candidate in staged) {
                for (old in registrations) {
                    if (toolCatalogSameIdentity(old.descriptor, candidate.descriptor)) {
                        return toolCatalogError("tool.registration_identity_reused", "immutable executor identity is already retained")
                    }
                    let sameOwner = match (old.owner) {
                        case Some(value) => refEq(value, owner)
                        case None => false
                    }
                    if (old.active && !old.revoked && !sameOwner &&
                        toolCatalogScopesOverlap(toolRegistrationThread(old), owner.threadId) &&
                        old.descriptor.definition.name == candidate.descriptor.definition.name) {
                        return toolCatalogError("tool.owner_name_conflict", "another owner already publishes this tool name")
                    }
                }
            }
            let published = ArrayList<ToolRegistration>()
            for (old in registrations) { published.add(old) }
            for (candidate in staged) { published.add(candidate) }
            match (backing159) {
                case Some(value) => value.retainUnknownBacking159()
                case None => ()
            }
            // No prior state is changed until every candidate and CAS passed.
            for (old in registrations) {
                match (old.owner) {
                    case Some(value) => if (refEq(value, owner)) { old.active = false }
                    case None => ()
                }
            }
            backing159 = Option<ToolCatalogBackingData159>.None
            registrationsData159 = Some(published)
            state.revision = binding.revision
            Result.Ok(ToolCatalogPublication(owner, binding, digest, descriptors.toArray()))
        } finally { lock.unlock() }
    }

    public func revokeOwned(owner: ToolCatalogOwner): Result<Unit> {
        recordRawCatalogAlias159()
        let targets = ArrayList<ToolRevocationTarget>()
        lock.lock()
        try {
            let state = match (ownedState(owner)) {
                case Some(value) => value
                case None => return toolCatalogError("tool.owner_invalid", "owner belongs to another catalog")
            }
            state.revoked = true
            for (item in registrations) {
                let owned = match (item.owner) {
                    case Some(value) => refEq(value, owner)
                    case None => false
                }
                if (!owned) { continue }
                item.active = false
                item.revoked = true
                let runIds = ArrayList<RunId>()
                for (execution in item.activeExecutions) {
                    var present = false
                    for (runId in runIds where runId.value == execution.runId.value) { present = true; break }
                    if (!present) { runIds.add(execution.runId) }
                }
                if (!runIds.isEmpty()) { targets.add(ToolRevocationTarget(item.executor, runIds.toArray())) }
            }
        } finally { lock.unlock() }
        var failed = false
        for (target in targets) {
            for (runId in target.runIds) {
                try {
                    if (target.executor.cancel(runId).isError()) { failed = true }
                } catch (_: Exception) { failed = true }
            }
        }
        if (failed) {
            toolCatalogError("tool.owner_cancellation_failed", "owner was revoked; one or more cancellation callbacks failed")
        } else { Result.Ok(()) }
    }

    public func registerHookHandlers(
        pluginId: String,
        handlers: Array<ToolHookHandlerSnapshot>,
        dataPayment!: ?ToolCatalogDataPayment159 = None
    ): Result<Unit> {
        if (pluginId.trimAscii() == "") {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "tool.hook_plugin_id_invalid",
                "hook registration requires a plugin identity"
            ))
        }
        lock.lock()
        try {
            if (dataClosed159) { return toolCatalogError("tool.catalog_closed", "catalog data was retired") }
            match (dataPayment) {
                case Some(value) =>
                    value.reserveCatalogData159(toolCatalogDataInvoice159(hookHandlers.size, 128))
                    value.reserveCatalogData159(toolCatalogDataInvoice159(handlers.size, 128))
                case None => ()
            }
            let staged = ArrayList<ToolHookHandlerSnapshot>()
            for (handler in hookHandlers where handler.pluginId != pluginId) {
                staged.add(handler)
            }
            for (handler in handlers) {
                if (handler.pluginId != pluginId) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Configuration,
                        "tool.hook_plugin_identity_mismatch",
                        "hook handler identity does not match its registration owner"
                    ))
                }
                staged.add(handler)
            }
            var preCount: Int64 = 0
            var postCount: Int64 = 0
            for (handler in staged) {
                if (handler.event == "PreToolUse") { preCount += 1 }
                if (handler.event == "PostToolUse") { postCount += 1 }
            }
            if (preCount > 32 || postCount > 32) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "tool.hook_handler_limit",
                    "hook event exceeds the 32-handler product limit"
                ))
            }
            let nextDataOwner159 = match (dataPayment) {
                case Some(value) => match (value) {
                    case actual: ToolCatalogRetirableData159 =>
                        // The original retained parent pays this link before
                        // either the lease carrier or private node is created.
                        value.reserveCatalogData159(4096)
                        Some(ToolCatalogDataLink159(actual.retainCatalogData159(), dataOwners159))
                    case _ => None<ToolCatalogDataLink159>
                }
                case None => None<ToolCatalogDataLink159>
            }
            hookHandlersData159 = Some(staged)
            match (nextDataOwner159) { case Some(value) => dataOwners159 = Some(value); case None => () }
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func unregisterHookHandlers(pluginId: String): Bool {
        lock.lock()
        try {
            let retained = ArrayList<ToolHookHandlerSnapshot>()
            var removed = false
            for (handler in hookHandlers) {
                if (handler.pluginId == pluginId) { removed = true }
                else { retained.add(handler) }
            }
            hookHandlersData159 = Some(retained)
            removed
        } finally {
            lock.unlock()
        }
    }

    func find(name: String, threadId!: ?ThreadId = None): ?ToolRegistration {
        recordRawCatalogAlias159()
        lock.lock()
        try {
            for (item in registrations where item.active && !item.revoked && item.descriptor.definition.name == name && toolRegistrationVisible(item, threadId)) {
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
    func findRegistered(name: String, threadId!: ?ThreadId = None): ?ToolRegistration {
        recordRawCatalogAlias159()
        lock.lock()
        try {
            var selected: ?ToolRegistration = None
            var selectedIsActive = false
            for (item in registrations where item.descriptor.definition.name == name && !item.revoked && toolRegistrationVisible(item, threadId)) {
                if (item.active) {
                    selected = Some(item)
                    selectedIsActive = true
                } else if (!selectedIsActive) {
                    selected = Some(item)
                }
            }
            selected
        } finally {
            lock.unlock()
        }
    }

    func findForSnapshot(
        snapshot: ToolSetSnapshot,
        name: String,
        threadId!: ?ThreadId = None
    ): ?ToolRegistration {
        recordRawCatalogAlias159()
        if (!toolSnapshotThreadAllowed(snapshot, threadId)) { return None }
        var expected: ?ToolSnapshotEntry = None
        for (entry in snapshot.entries where entry.name == name) {
            expected = Some(entry)
            break
        }
        match (expected) {
            case None => return None
            case Some(_) => ()
        }
        let identity = match (expected) {
            case Some(value) => value
            case None => return None
        }
        lock.lock()
        try {
            for (item in registrations where item.descriptor.definition.name == name && !item.revoked && toolRegistrationVisible(item, snapshot.threadId)) {
                if (item.descriptor.implementationVersion == identity.executorVersion &&
                    item.descriptor.implementationFingerprint == identity.implementationFingerprint &&
                    item.descriptor.schemaDigest == identity.schemaDigest) {
                    return Some(item)
                }
            }
            None
        } finally {
            lock.unlock()
        }
    }

    // The snapshot itself never escapes. Registration/executor aliases still
    // retain catalog custody until the separate invocation-owner migration.
    func findForSharedSnapshot159(snapshot: SharedToolSetSnapshot159, name: String,
        threadId: ThreadId): ?ToolRegistration {
        recordRawCatalogAlias159()
        if (!snapshot.permitsThread159(threadId)) { return None<ToolRegistration> }
        lock.lock()
        try {
            for (item in registrations where item.descriptor.definition.name == name && !item.revoked) {
                if (snapshot.matchesRegistration159(name, item.descriptor.implementationVersion,
                    item.descriptor.implementationFingerprint, item.descriptor.schemaDigest, toolRegistrationThread(item))) {
                    return Some(item)
                }
            }
            None<ToolRegistration>
        } finally { lock.unlock() }
    }

    func findBorrowed204(scope: ToolCatalogHostConsumer204, name: String, threadId: ?ThreadId): ?ToolRegistration {
        if (!scope.belongsToCatalog204(this)) { throw IllegalStateException("Catalog registration has no active private consumer") }
        lock.lock()
        try {
            for (item in registrations where item.active && !item.revoked && item.descriptor.definition.name == name && toolRegistrationVisible(item, threadId)) {
                return Some(item)
            }
            None
        } finally {
            lock.unlock()
        }
    }

    func findRegisteredBorrowed204(scope: ToolCatalogHostConsumer204, name: String, threadId: ?ThreadId): ?ToolRegistration {
        if (!scope.belongsToCatalog204(this)) { throw IllegalStateException("Catalog registration has no active private consumer") }
        lock.lock()
        try {
            var selected: ?ToolRegistration = None
            var selectedIsActive = false
            for (item in registrations where item.descriptor.definition.name == name && !item.revoked && toolRegistrationVisible(item, threadId)) {
                if (item.active) {
                    selected = Some(item)
                    selectedIsActive = true
                } else if (!selectedIsActive) {
                    selected = Some(item)
                }
            }
            selected
        } finally {
            lock.unlock()
        }
    }

    func findForSharedSnapshotBorrowed204(scope: ToolCatalogHostConsumer204, snapshot: SharedToolSetSnapshot159, name: String, threadId: ThreadId): ?ToolRegistration {
        if (!scope.belongsToCatalog204(this)) { throw IllegalStateException("Catalog registration has no active private consumer") }
        if (!snapshot.permitsThread159(threadId)) { return None<ToolRegistration> }
        lock.lock()
        try {
            for (item in registrations where item.descriptor.definition.name == name && !item.revoked) {
                if (snapshot.matchesRegistration159(name, item.descriptor.implementationVersion,
                    item.descriptor.implementationFingerprint, item.descriptor.schemaDigest, toolRegistrationThread(item))) {
                    return Some(item)
                }
            }
            None<ToolRegistration>
        } finally { lock.unlock() }
    }

    // Pure publication classification for trusted host composition. This borrows
    // the same active registration lookup and never resolves call-dependent policy.
    // Data observation only: no executor, registration, Source or invocation
    // capability escapes. The existing finder applies active/revoked/scope.
    public func publicationRetainsExecutor(name: String, expected: ToolExecutor,
        threadId!: ?ThreadId = Option<ThreadId>.None): Bool {
        lock.lock()
        try {
            for (actual in registrations where actual.active && !actual.revoked &&
                actual.descriptor.definition.name == name && toolRegistrationVisible(actual, threadId)) {
                return match (actual.executor as Object) {
                    case None => false
                    case Some(left) => match (expected as Object) {
                        case None => false
                        case Some(right) => refEq(left, right)
                    }
                }
            }
            false
        } finally { lock.unlock() }
    }

    // Closed DATA predicate with the same active/revoked/thread selection as
    // the public finder. No descriptor/schema/executor alias is exported.
    public func isPublishedOrdinaryTool159e(name: String, threadId!: ?ThreadId = None): Bool {
        lock.lock()
        try {
            for (actual in registrations where actual.active && !actual.revoked &&
                actual.descriptor.definition.name == name && toolRegistrationVisible(actual, threadId)) {
                return !actual.descriptor.controlOnly && !actual.descriptor.hostServiceOnly
            }
            false
        } finally { lock.unlock() }
    }

    // Same active/revoked/thread lookup and exact original Host service/
    // fingerprint conjunction, without exporting the descriptor or callbacks.
    // The full selector executes under the original Catalog lock.
    public func publishedHostServiceMatches191(name: String, fingerprint: String,
        threadId!: ?ThreadId = None): Bool {
        lock.lock(); try {
            if (dataClosed159) { return false }
            for (actual in registrations where actual.active && !actual.revoked &&
                actual.descriptor.definition.name == name && toolRegistrationVisible(actual, threadId)) {
                return actual.descriptor.hostServiceOnly && actual.descriptor.implementationFingerprint == fingerprint
            }
            false
        } finally { lock.unlock() }
    }

    public func publishedDescriptor(name: String, threadId!: ?ThreadId = None): ?ToolDescriptor {
        recordRawCatalogAlias159()
        match (find(name, threadId: threadId)) {
            case Some(value) => Some(value.descriptor)
            case None => None
        }
    }

    public func resolvedDescriptor(call: ToolCall, threadId!: ?ThreadId = None): ?ToolDescriptor {
        recordRawCatalogAlias159()
        match (find(call.name, threadId: threadId)) {
            case Some(value) => Some(value.descriptor.resolved(call))
            case None => None
        }
    }

    public func isReadOnly(call: ToolCall, threadId!: ?ThreadId = None): Bool {
        match (resolvedDescriptor(call, threadId: threadId)) {
            case Some(value) => !value.sideEffecting
            case None => false
        }
    }

    public func definitions(threadId!: ?ThreadId = None): Array<ModelToolDefinition> {
        recordRawCatalogAlias159()
        lock.lock()
        try {
            let values = ArrayList<ModelToolDefinition>()
            for (item in registrations where item.active && !item.revoked && toolRegistrationVisible(item, threadId) &&
                !item.descriptor.controlOnly && !item.descriptor.hostServiceOnly) {
                values.add(item.descriptor.definition)
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }

    // SDK configuration checks only whether any permitted definition exists.
    // This closed read uses the original exact visibility/filter predicate;
    // no descriptor, schema, executor, String or array leaves the lock.
    public func hasDefinitionsFor159(capabilities: CapabilitySet, threadId!: ?ThreadId = None): Bool {
        lock.lock()
        try {
            if (dataClosed159) { return false }
            for (item in registrations where item.active && !item.revoked && toolRegistrationVisible(item, threadId) &&
                !item.descriptor.controlOnly && !item.descriptor.hostServiceOnly) {
                if (item.descriptor.capabilitiesAllow159(capabilities)) { return true }
            }
            false
        } finally { lock.unlock() }
    }

    public func definitionsFor(capabilities: CapabilitySet, threadId!: ?ThreadId = None): Array<ModelToolDefinition> {
        recordRawCatalogAlias159()
        lock.lock()
        try {
            let values = ArrayList<ModelToolDefinition>()
            for (item in registrations where item.active && !item.revoked && toolRegistrationVisible(item, threadId) &&
                !item.descriptor.controlOnly && !item.descriptor.hostServiceOnly) {
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

    public func reserveModelInputData159(request: ModelRequest,
        settings180!: ?ToolContextDescriptor = None<ToolContextDescriptor>): ?LogicalJsonOwnerReservation {
        // The actual mounted Registry supplies the original bank. Fixture-only
        // catalogs without that owner neither create nor borrow a new bank.
        let original = try { lock.lock(); snapshotPayment159 } finally { lock.unlock() }
        match (original) {
            case None => None<LogicalJsonOwnerReservation>
            case Some(owner) =>
                let payment = owner.reserveSnapshotCatalogData159(131072)
                try {
                    let meter = ToolSnapshotMeasure159(payment)
                    meter.addModelRequest159(request)
                    match (settings180) { case Some(value) => value.measureExecutionSettings180(meter); case None => () }
                    meter.fund159()
                    Some(payment)
                } catch (error: Exception) { payment.close(); throw error }
        }
    }
    public func reserveRegistryData180(invoice: Int64): ?LogicalJsonOwnerReservation {
        if (invoice < 1) { throw IllegalArgumentException("Registry DATA invoice must be positive") }
        let original = try { lock.lock(); snapshotPayment159 } finally { lock.unlock() }
        match (original) { case Some(owner) => Some(owner.reserveSnapshotCatalogData159(invoice))
            case None => None<LogicalJsonOwnerReservation> }
    }


    public func changedSharedToolSetSnapshot159(expected: SharedToolSetSnapshot159,
        run: RunId, capabilities: CapabilitySet, threadId!: ?ThreadId = None): ?SharedToolSetSnapshot159 {
        let producer = ownedToolSetSnapshot159("catalog-observed", capabilities, threadId: threadId).getOrThrow()
        if (producer.matchesSharedContent159(expected)) {
            match (producer.detachReturnedSnapshot159()) { case Some(value) => value.close(); case None => () }
            return None<SharedToolSetSnapshot159>
        }
        producer.identifyCatalogCut159(run)
        Some(producer.transferSharedSnapshot159())
    }
    public func sharedDirectToolSetSnapshot159e(run: RunId, capabilities: CapabilitySet,
        threadId!: ?ThreadId = None): ?SharedToolSetSnapshot159 {
        let producer = produceDirectToolSetSnapshot159e(run, capabilities, threadId)
        match (producer) {
            case Some(value) =>
                value.returnedSnapshotProducer159()
                Some(value.transferSharedSnapshot159())
            case None => None<SharedToolSetSnapshot159>
        }
    }
    private func produceDirectToolSetSnapshot159e(run: RunId, capabilities: CapabilitySet,
        threadId: ?ThreadId): ?OwnedToolSetSnapshot159 {
        lock.lock()
        try {
            if (dataClosed159) { throw IllegalStateException("catalog data was retired") }
            match (snapshotPayment159) {
                case Some(original) => Some(produceLockedToolSetSnapshot159(original,
                    "direct-delegation-", capabilities, threadId, directRun159e: Some(run)))
                case None => None<OwnedToolSetSnapshot159>
            }
        } finally { lock.unlock() }
    }

    public func sharedToolSetSnapshot159(id: String, capabilities: CapabilitySet,
        threadId!: ?ThreadId = None): ?SharedToolSetSnapshot159 {
        var producer = ownedToolSetSnapshot159(id, capabilities, threadId: threadId)
        let result = match (producer) {
            case Some(value) => Some(value.transferSharedSnapshot159())
            case None => Option<SharedToolSetSnapshot159>.None
        }
        producer = Option<OwnedToolSetSnapshot159>.None
        result
    }
    public func ownedToolSetSnapshot159(id: String, capabilities: CapabilitySet,
        threadId!: ?ThreadId = None): ?OwnedToolSetSnapshot159 {
        let value = produceOwnedToolSetSnapshot159(id, capabilities, threadId)
        match (value) { case Some(owned) => owned.returnedSnapshotProducer159(); case None => () }
        value
    }
    private func produceOwnedToolSetSnapshot159(id: String, capabilities: CapabilitySet,
        threadId: ?ThreadId): ?OwnedToolSetSnapshot159 {
        lock.lock()
        try {
            match (snapshotPayment159) {
                case Some(original) => Some(produceLockedToolSetSnapshot159(original, id, capabilities, threadId))
                case None => Option<OwnedToolSetSnapshot159>.None
            }
        } finally { lock.unlock() }
    }
    private func produceLockedToolSetSnapshot159(original: ToolCatalogSnapshotPayment159,
        id: String, capabilities: CapabilitySet, threadId: ?ThreadId,
        directRun159e!: ?RunId = None<RunId>): OwnedToolSetSnapshot159 {
        // Original shared bank BEFORE holder, meter, array, schema getter or
        // producer capture. Unknown producer failure keeps the registered debt.
        let payment = original.reserveSnapshotCatalogData159(131072)
        let owned = OwnedToolSetSnapshot159(payment)
        let meter = ToolSnapshotMeasure159(payment)
        meter.addText159(id)
        match (directRun159e) { case Some(run) => meter.addText159(run.value); case None => () }
        match (threadId) { case Some(thread) => meter.addText159(thread.value); case None => () }
        meter.addSlots159(registrations.size); meter.addSlots159(hookHandlers.size)
        for (item in registrations where item.active && !item.revoked && toolRegistrationVisible(item, threadId) &&
            !item.descriptor.controlOnly && !item.descriptor.hostServiceOnly) {
            item.descriptor.measureSnapshotData159(meter)
        }
        for (handler in hookHandlers) { meter.addHook159(handler) }
        meter.fund159()
        let actualId159e = match (directRun159e) { case Some(run) => id + run.value; case None => id }
        owned.installSnapshot159(toolSetSnapshotLocked159(actualId159e, capabilities, threadId))
        owned
    }

    // Public legacy export is explicitly Held. No raw snapshot, model lane,
    // SDK or TUI alias is retired merely by unmount or end-Run.
    public func toolSetSnapshot(id: String, capabilities: CapabilitySet,
        threadId!: ?ThreadId = None): ToolSetSnapshot {
        var owned: ?OwnedToolSetSnapshot159 = Option<OwnedToolSetSnapshot159>.None
        lock.lock()
        try {
            match (snapshotPayment159) {
                case Some(original) => owned = Some(produceLockedToolSetSnapshot159(original, id, capabilities, threadId))
                // Historical catalogs that never acquired Registry data have
                // no Registry share to derive. Their original route is intact.
                case None => return toolSetSnapshotLocked159(id, capabilities, threadId)
            }
        } finally { lock.unlock() }
        owned.getOrThrow().returnedSnapshotProducer159()
        owned.getOrThrow().exportHistoricalSnapshot159()
    }

    public func sharedToolSetSnapshotMatches159(expected: SharedToolSetSnapshot159, id: String,
        capabilities: CapabilitySet, threadId!: ?ThreadId = None): Bool {
        let observed = sharedToolSetSnapshot159(id, capabilities, threadId: threadId)
        try { compareSharedToolSetFrame159(expected, observed, id, capabilities, threadId) }
        finally { match (observed) { case Some(value) => value.close159(); case None => () } }
    }
    private func compareSharedToolSetFrame159(expected: SharedToolSetSnapshot159,
        observed: ?SharedToolSetSnapshot159, id: String, capabilities: CapabilitySet, threadId: ?ThreadId): Bool {
        match (observed) {
            case Some(value) => expected.contentEqualsShared159(value)
            // Only the historical catalog with no Registry allocation reaches
            // this branch; the paid expected snapshot is still not exported.
            case None => expected.contentEquals159(toolSetSnapshot(id, capabilities, threadId: threadId))
        }
    }

    public func toolSetSnapshotMatches159(expected: ToolSetSnapshot, id: String,
        capabilities: CapabilitySet, threadId!: ?ThreadId = None): Bool {
        let returned = toolSetSnapshotCompareReturned159(expected, id, capabilities, threadId)
        // Entire producer/compare/carrier helper returned; no snapshot owner,
        // schema, meter, callback or carrier reference exists in this frame.
        match (returned[1]) { case Some(value) => value.close(); case None => () }
        returned[0]
    }
    private func toolSetSnapshotCompareReturned159(expected: ToolSetSnapshot, id: String,
        capabilities: CapabilitySet, threadId: ?ThreadId): (Bool, ?LogicalJsonOwnerReservation) {
        var owned = ownedToolSetSnapshot159(id, capabilities, threadId: threadId)
        if (owned.isNone()) {
            return (toolSetSnapshotContentDigest(toolSetSnapshot(id, capabilities, threadId: threadId)) ==
                toolSetSnapshotContentDigest(expected), Option<LogicalJsonOwnerReservation>.None)
        }
        let equal = owned.getOrThrow().matchesContent159(expected)
        owned.getOrThrow().returnedComparisonHelper159()
        let payment = owned.getOrThrow().detachReturnedSnapshot159()
        owned = Option<OwnedToolSetSnapshot159>.None
        (equal, payment)
    }
    public func changedToolSetSnapshot159(expected: ToolSetSnapshot, id: String,
        capabilities: CapabilitySet, threadId!: ?ThreadId = None): ?ToolSetSnapshot {
        let returned = changedToolSetSnapshotReturned159(expected, id, capabilities, threadId)
        match (returned[1]) { case Some(value) => value.close(); case None => () }
        returned[0]
    }
    private func changedToolSetSnapshotReturned159(expected: ToolSetSnapshot, id: String,
        capabilities: CapabilitySet, threadId: ?ThreadId): (?ToolSetSnapshot, ?LogicalJsonOwnerReservation) {
        var owned = ownedToolSetSnapshot159(id, capabilities, threadId: threadId)
        if (owned.isNone()) {
            let observed = toolSetSnapshot(id, capabilities, threadId: threadId)
            if (toolSetSnapshotContentDigest(observed) == toolSetSnapshotContentDigest(expected)) {
                return (Option<ToolSetSnapshot>.None, Option<LogicalJsonOwnerReservation>.None)
            }
            return (Some(observed), Option<LogicalJsonOwnerReservation>.None)
        }
        let equal = owned.getOrThrow().matchesContent159(expected)
        owned.getOrThrow().returnedComparisonHelper159()
        if (!equal) {
            return (Some(owned.getOrThrow().exportHistoricalSnapshot159()), Option<LogicalJsonOwnerReservation>.None)
        }
        let payment = owned.getOrThrow().detachReturnedSnapshot159()
        owned = Option<OwnedToolSetSnapshot159>.None
        (Option<ToolSetSnapshot>.None, payment)
    }
    private func toolSetSnapshotLocked159(id: String, capabilities: CapabilitySet,
        threadId: ?ThreadId): ToolSetSnapshot {
        let entries = ArrayList<ToolSnapshotEntry>()
        for (item in registrations where item.active && !item.revoked && toolRegistrationVisible(item, threadId) &&
            !item.descriptor.controlOnly && !item.descriptor.hostServiceOnly) {
            let required = item.descriptor.requiredCapabilities()
            var allowed = true
            for (capability in required) {
                if (!capabilities.allows(
                    capability.kind,
                    resource: capability.resource
                )) {
                    allowed = false
                    break
                }
            }
            entries.add(ToolSnapshotEntry(
                item.descriptor.definition.name,
                item.descriptor.definition.description,
                item.descriptor.definition.inputSchema,
                item.descriptor.implementationVersion,
                required,
                implementationFingerprint: item.descriptor.implementationFingerprint,
                schemaDigest: item.descriptor.schemaDigest,
                availableAtSnapshot: allowed
            ))
        }
        let snapshotHooks = ArrayList<ToolHookHandlerSnapshot>()
        for (handler in hookHandlers where
            toolHookAvailableAtSnapshot(handler, capabilities)) {
            snapshotHooks.add(handler)
        }
        ToolSetSnapshot(
            id, entries.toArray(), hookHandlers: snapshotHooks.toArray(), threadId: threadId
        )
    }

    public func unregister(name: String, threadId!: ?ThreadId = None): Bool {
        lock.lock()
        try {
            for (item in registrations where item.owner.isSome() && item.active &&
                item.descriptor.definition.name == name && toolCatalogSameThread(toolRegistrationThread(item), threadId)) { return false }
            var changed = false
            for (item in registrations where item.descriptor.definition.name == name && toolCatalogSameThread(toolRegistrationThread(item), threadId) && item.active) {
                item.active = false
                changed = true
            }
            changed
        } finally {
            lock.unlock()
        }
    }

    // Revocation is an immediate security boundary, unlike ordinary retirement.
    public func revoke(name: String, threadId!: ?ThreadId = None): Bool {
        recordRawCatalogAlias159()
        let targets = ArrayList<ToolRevocationTarget>()
        let owned = ArrayList<ToolCatalogOwner>()
        var found = false
        lock.lock()
        try {
            for (item in registrations where item.descriptor.definition.name == name && toolCatalogSameThread(toolRegistrationThread(item), threadId)) {
                match (item.owner) {
                    case Some(value) => owned.add(value); found = true; continue
                    case None => ()
                }
                item.active = false
                item.revoked = true
                found = true
                let runIds = ArrayList<RunId>()
                for (execution in item.activeExecutions) {
                    var present = false
                    for (runId in runIds where runId.value == execution.runId.value) {
                        present = true
                        break
                    }
                    if (!present) { runIds.add(execution.runId) }
                }
                if (!runIds.isEmpty()) {
                    targets.add(ToolRevocationTarget(item.executor, runIds.toArray()))
                }
            }
        } finally {
            lock.unlock()
        }
        // Security revocation of any owned contribution invalidates that
        // owner's whole publication, preventing a partially live directory.
        for (owner in owned) { let _ = revokeOwned(owner) }
        for (target in targets) {
            for (runId in target.runIds) {
                let _ = target.executor.cancel(runId)
            }
        }
        found
    }
    func beginExecution(
        registration: ToolRegistration,
        operationId: OperationId,
        runId: RunId,
        threadId: ThreadId,
        delegatedSource!: ?DirectToolCallRef = None
    ): Bool {
        let scope = match (delegatedSource) {
            case Some(value) =>
                if (value.managedJob.isNone() || value.threadId.value != threadId.value || value.runId.value != runId.value ||
                    value.operationId.value != operationId.value || value.validateLiveSource().isError()) { return false }
                value.managedJob.getOrThrow().binding.parentThreadId
            case None => threadId
        }
        lock.lock()
        try {
            if (registration.revoked || !toolRegistrationVisible(registration, Some(scope))) { return false }
            registration.activeExecutions.add(ActiveToolExecution(operationId, runId))
            true
        } finally {
            lock.unlock()
        }
    }

    func finishExecution(
        registration: ToolRegistration,
        operationId: OperationId
    ): Unit {
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < registration.activeExecutions.size) {
                if (registration.activeExecutions[index].operationId.value == operationId.value) {
                    registration.activeExecutions.remove(at: index)
                    break
                }
                index += 1
            }
        } finally {
            lock.unlock()
        }
    }

    func executionWasRevoked(registration: ToolRegistration): Bool {
        lock.lock()
        try { registration.revoked } finally { lock.unlock() }
    }

    public func setActive(name: String, active: Bool, threadId!: ?ThreadId = None): Bool {
        lock.lock()
        try {
            for (item in registrations where item.owner.isSome() &&
                item.descriptor.definition.name == name && toolCatalogSameThread(toolRegistrationThread(item), threadId)) { return false }
            var selected: ?ToolRegistration = None
            var found = false
            for (item in registrations where item.descriptor.definition.name == name && toolCatalogSameThread(toolRegistrationThread(item), threadId) && !item.revoked) {
                found = true
                if (active) { selected = Some(item) }
                item.active = false
            }
            if (active) {
                match (selected) {
                    case Some(item) => item.active = true
                    case None => ()
                }
            }
            found
        } finally {
            lock.unlock()
        }
    }

    func cancel(runId: RunId, threadId!: ?ThreadId = None): Result<Unit> {
        recordRawCatalogAlias159()
        let snapshot = lockAndSnapshot(threadId)
        for (registration in snapshot) {
            match (registration.executor.cancel(runId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(())
    }

    private func lockAndSnapshot(threadId: ?ThreadId): Array<ToolRegistration> {
        lock.lock()
        try {
            let selected = ArrayList<ToolRegistration>()
            for (item in registrations where toolRegistrationVisible(item, threadId)) { selected.add(item) }
            selected.toArray()
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
        let effectiveMode = match (context.approvalModeOverride) { case Some(value) => value; case None => mode }
        // Extension-backed ContextRead keeps its own review even though its
        // effect is ReadOnly. Reviewing it cannot approve the later mutation.
        if (effectiveMode != ApprovalMode.Yolo && isContextReadPlan(plan) &&
            (contextReadResourceRequiresApproval(plan.canonicalArguments) ||
                requiresCapability(plan.requiredCapabilities, CapabilityKind.ExtensionInvoke))) {
            return PolicyDecision(PermissionRequirement.Confirm,
                reason: "host classified resource read requires exact one-time approval")
        }
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
    private let hostConsumerLock204 = Mutex()
    private var hostConsumers204: ?ToolCatalogHostConsumer204 = None<ToolCatalogHostConsumer204>

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
    private func copyPlanValueFrame204(context: ToolInvocationContext,
        plan: NormalizedOperationPlan): ?OwnedPreparedPlanUtf8204 {
        let action = beginRegistrationConsumer204(context)
        match (action) {
            case None => None<OwnedPreparedPlanUtf8204>
            case Some(value) =>
                var returned = false
                try {
                    let owner = value.copyPlanValueUtf8204(plan)
                    returned = true; Some(owner)
                } catch (error: Exception) { value.holdUnknown204(); throw error }
                finally { if (returned) { value.returnedWholeAction204() } }
        }
    }
    private func prepareDirectPlanDataFrame204(context: ToolInvocationContext,
        source: DirectToolCallRef, plan: NormalizedOperationPlan): Result<Unit> {
        match (operations as PreparedOperationPlanDataPort204) {
            case Some(receiver) => match (copyPlanValueFrame204(context, plan)) {
                case Some(bytes) =>
                    let result = receiver.prepareDirectOperationOwnedUtf8204(source, bytes)
                    // Only this sender's numeric buffer is cleared. The receiver
                    // paid its independent copies before their construction.
                    bytes.closeAfterWholeCaller204(); result
                case None => operations.prepareDirectOperation(source, plan)
            }
            case None =>
                match (hostConsumerForContext204(context)) { case Some(value) => value.holdUnknown204(); case None => () }
                operations.prepareDirectOperation(source, plan)
        }
    }

    // This produces only independent owned numeric bytes. It never exports
    // the original Prepared/Plan/Catalog graph to a callback or a Port.
    public func copyPreparedPlanUtf8204(context: ToolInvocationContext,
        prepared: PreparedToolInvocation): ?OwnedPreparedPlanUtf8204 {
        let action = beginRegistrationConsumer204(context)
        match (action) {
            case None => return None<OwnedPreparedPlanUtf8204>
            case Some(value) =>
                var returned = false
                try {
                    let copied = value.copyPreparedPlanUtf8204(prepared)
                    returned = true; Some(copied)
                } catch (error: Exception) { value.holdUnknown204(); throw error }
                finally { if (returned) { value.returnedWholeAction204() } }
        }
    }
    public func prepareDirectPreparedData204(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, source: DirectToolCallRef,
        receiver: OperationRuntimePort): Result<Unit> {
        let action = beginRegistrationConsumer204(context)
        var returned = false
        try {
            let answer = prepareDirectPreparedFrame204(context, prepared, source, receiver)
            returned = true; answer
        } catch (error: Exception) {
            match (action) { case Some(value) => value.holdUnknown204(); case None => () }; throw error
        } finally { if (returned) { match (action) { case Some(value) => value.returnedWholeAction204(); case None => () } } }
    }
    private func prepareDirectPreparedFrame204(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, source: DirectToolCallRef,
        receiver: OperationRuntimePort): Result<Unit> {
        match (receiver as PreparedOperationPlanDataPort204) {
            case Some(actual) => match (copyPreparedPlanUtf8204(context, prepared)) {
                case Some(bytes) =>
                    let answer = actual.prepareDirectOperationOwnedUtf8204(source, bytes)
                    bytes.closeAfterWholeCaller204(); answer
                case None => receiver.prepareDirectOperation(source, prepared.operationPlan)
            }
            case None => receiver.prepareDirectOperation(source, prepared.operationPlan)
        }
    }

    public func preparedIsContextRead204(context: ToolInvocationContext, prepared: PreparedToolInvocation): Bool {
        let action = beginRegistrationConsumer204(context)
        var returned = false
        try {
            let answer = preparedPredicateFrame204(prepared, false)
            returned = true; answer
        } catch (error: Exception) {
            match (action) { case Some(value) => value.holdUnknown204(); case None => () }; throw error
        } finally { if (returned) { match (action) { case Some(value) => value.returnedWholeAction204(); case None => () } } }
    }
    public func preparedIsFrozenPluginChild204(context: ToolInvocationContext, prepared: PreparedToolInvocation): Bool {
        let action = beginRegistrationConsumer204(context)
        var returned = false
        try {
            let answer = preparedPredicateFrame204(prepared, true)
            returned = true; answer
        } catch (error: Exception) {
            match (action) { case Some(value) => value.holdUnknown204(); case None => () }; throw error
        } finally { if (returned) { match (action) { case Some(value) => value.returnedWholeAction204(); case None => () } } }
    }
    private func preparedPredicateFrame204(prepared: PreparedToolInvocation, frozen: Bool): Bool {
        if (frozen) { isFrozenPluginChildParent111(prepared.borrowOperationPlanFrame204()) }
        else { isContextReadPlan(prepared.borrowOperationPlanFrame204()) }
    }

    // An opaque original-bank DATA frame, not a Source/Tool admission.
    public func beginHostCatalogConsumer204(context: ToolInvocationContext): ?ToolCatalogHostConsumer204 {
        let answer = catalog.prepareHostConsumer204(this, context)
        match (answer) { case Some(value) =>
            hostConsumerLock204.lock()
            try { value.nextPipeline204 = hostConsumers204; hostConsumers204 = Some(value) }
            finally { hostConsumerLock204.unlock() }
            case None => () }
        answer
    }
    func removeHostConsumer204(value: ToolCatalogHostConsumer204): Unit {
        hostConsumerLock204.lock()
        try {
            var previous: ?ToolCatalogHostConsumer204 = None<ToolCatalogHostConsumer204>
            var cursor = hostConsumers204
            while (cursor.isSome()) {
                let actual = cursor.getOrThrow()
                if (refEq(actual, value)) {
                    match (previous) { case Some(owner) => owner.nextPipeline204 = actual.nextPipeline204
                        case None => hostConsumers204 = actual.nextPipeline204 }
                    actual.nextPipeline204 = None<ToolCatalogHostConsumer204>; return
                }
                previous = cursor; cursor = actual.nextPipeline204
            }
            throw IllegalStateException("actual Host Catalog consumer is missing")
        } finally { hostConsumerLock204.unlock() }
    }
    private func hostConsumerForContext204(context: ToolInvocationContext): ?ToolCatalogHostConsumer204 {
        hostConsumerLock204.lock()
        try {
            var cursor = hostConsumers204
            while (cursor.isSome()) {
                let value = cursor.getOrThrow()
                if (value.matchesContext204(context)) { return Some(value) }
                cursor = value.nextPipeline204
            }
            None<ToolCatalogHostConsumer204>
        } finally { hostConsumerLock204.unlock() }
    }
    private func beginRegistrationConsumer204(context: ToolInvocationContext): ?ToolCatalogHostConsumerAction204 {
        match (hostConsumerForContext204(context)) {
            case None => None<ToolCatalogHostConsumerAction204>
            case Some(value) =>
                // Unknown validators receive a ModelToolDefinition and may
                // keep it. They retain the real backing, before that export.
                if ((validator as ObjectArgumentValidator).isNone() || (policy as DefaultCapabilityPolicy).isNone() || ((permissions as MemoryPermissionRepository).isNone() && (permissions as CatalogPermissionGrantDataPort204).isNone())) {
                    value.holdUnknown204()
                }
                Some(value.beginFrame204())
        }
    }

    public func operationRuntime(): OperationRuntimePort {
        operations
    }


    private func registrationConsumerBody204<T>(action: () -> T): T { action() }

    private func hostServiceSourceAllowed(source: PreparedInvocationSource, name: String): Bool {
        if([HOST_MANAGED_CHANNEL_WRITE_TOOL,HOST_MANAGED_CHANNEL_SPAWN_TOOL,HOST_MANAGED_CHANNEL_CLOSE_TOOL].contains(name)){
            if(source.kind!=PreparedInvocationSourceKind.Derived || source.parentOperationId.isNone() || source.parentCallId==""){return false}
            return match(source.operationRoot){case Some(root)=>root.toolName().startsWith("plugin.") && root.callId()==source.parentCallId &&
                source.requestKey.startsWith("managed-channel:"+source.parentCallId+":");case None=>false}}

        if (name == HOST_PLUGIN_CHILD_TOOL111) {
            if (source.kind != PreparedInvocationSourceKind.Derived || source.parentOperationId.isNone() || source.parentCallId == "") { return false }
            return match (source.operationRoot) {
                case Some(root) => root.toolName().startsWith("plugin.") && root.callId() == source.parentCallId &&
                    source.requestKey.startsWith("child-service:" + source.parentCallId + ":")
                case None => false
            }
        }
        if(name==HOST_PLUGIN_LIVE_EFFECT_TOOL){
            if(source.kind!=PreparedInvocationSourceKind.Derived || source.parentOperationId.isNone() || source.parentCallId==""){return false}
            return match(source.operationRoot){case Some(root)=>root.toolName().startsWith("plugin.") &&
                root.callId()==source.parentCallId && source.requestKey.startsWith("live-policy:"+source.parentCallId+":")
                case None=>false}}
        if (name == HOST_CONTEXT_READ_TOOL && source.kind == PreparedInvocationSourceKind.Direct) {
            match (source.operationRoot) {
                case Some(OperationRootSource.Direct(root)) => match (root.origin) {
                    case DirectCallOrigin.ContextRead(_) => return root.validateLiveSource().isOk()
                    case _ => return false }
                case _ => ()
            }
            return match (source.contextReadAdmission) { case Some(value) => value.validateLive().isOk(); case None => false }
        }
        if (source.kind != PreparedInvocationSourceKind.Derived) { return false }
        let prefix = if (name == HOST_CHANNEL_WRITE_TOOL) { "channel-service:" }
            else if (name == HOST_HTTP_STREAM_TOOL) { "http-stream-service:" }
            else if (name == HOST_PLUGIN_DOCUMENT_TOOL) { "document-service:" } else { "javascript-service:" }
        match (source.operationRoot) {
            case Some(root) => root.toolName().startsWith("plugin.") &&
                source.requestKey.startsWith(prefix + (if (name == HOST_READ_VIEW_TOOL && source.parentCallId != "") { source.parentCallId } else { root.callId() }) + ":")
            case None => false
        }
    }

    private func hostServiceNameAllowed(name: String): Bool {
        if([HOST_MANAGED_CHANNEL_WRITE_TOOL,HOST_MANAGED_CHANNEL_SPAWN_TOOL,HOST_MANAGED_CHANNEL_CLOSE_TOOL].contains(name)){return true}
        if(name==HOST_PLUGIN_LIVE_EFFECT_TOOL){return true}
        if (name == HOST_PLUGIN_CHILD_TOOL111) { return true }
        name == HOST_CONTEXT_READ_TOOL || name == "host.process.readonly" || name == "host.file.plan.propose" || name == HOST_HTTP_SERVICE_TOOL ||
            name == HOST_CHANNEL_WRITE_TOOL || name == HOST_HTTP_STREAM_TOOL || name == HOST_READ_VIEW_TOOL || name == HOST_PLUGIN_DOCUMENT_TOOL
    }

    private func noteRegistrationMetadataEscapers204(context: ToolInvocationContext,
        descriptor: ToolDescriptor): Unit {
        // Arbitrary resolvers may return a graph from their captured catalog.
        // Public Prepared.call and deferred reads remain compatibility Raw.
        if (descriptor.hasRawPreparedCallResolver204()) {
            match (hostConsumerForContext204(context)) { case Some(value) => value.holdUnknown204(); case None => () }
        }
    }
    private func registrationForRun(
        context: ToolInvocationContext,
        name: String,
        newPreparation!: Bool = false,
        allowHostService!: Bool = false
    ): ?ToolRegistration {
        if (validateToolSnapshotThread(context).isError()) { return None }
        let consumer204 = hostConsumerForContext204(context)
        let ownedSnapshot = context.forkOwnedToolSetSnapshot159()
        let selected = try { selectRegistrationSnapshotFrame159(context, ownedSnapshot, name, newPreparation, consumer204) }
        finally { match (ownedSnapshot) { case Some(value) => value.close159(); case None => () } }
        match (selected) {
            case Some(value) =>
                noteRegistrationMetadataEscapers204(context, value.descriptor)
                if (!value.descriptor.hostServiceOnly) { return Some(value) }
                if (allowHostService && hostServiceNameAllowed(name)) { return Some(value) }
                return None
            case None => ()
        }
        // These fixed host ports are intentionally absent from model snapshots.
        // Only a sealed Derived invocation can resolve its live registration.
        if (allowHostService && hostServiceNameAllowed(name)) {
            let fallback204 = match (consumer204) {
                case Some(scope) => catalog.findBorrowed204(scope, name, Some(ThreadId(context.sessionId.value)))
                case None => catalog.find(name, threadId: Some(ThreadId(context.sessionId.value))) }
            match (fallback204) {
                case Some(value) =>
                    noteRegistrationMetadataEscapers204(context, value.descriptor)
                    if (value.descriptor.hostServiceOnly) { return Some(value) }
                case None => ()
            }
        }
        None
    }

    private func selectRegistrationSnapshotFrame159(context: ToolInvocationContext,
        ownedSnapshot: ?SharedToolSetSnapshot159, name: String, newPreparation: Bool,
        consumer204: ?ToolCatalogHostConsumer204): ?ToolRegistration {
        match (ownedSnapshot) {
            case Some(snapshot) => return match (consumer204) {
                case Some(scope) => catalog.findForSharedSnapshotBorrowed204(scope, snapshot, name, ThreadId(context.sessionId.value))
                case None => catalog.findForSharedSnapshot159(snapshot, name, ThreadId(context.sessionId.value)) }
            case None => ()
        }
        match (context.legacyToolSetSnapshot159) {
            case Some(snapshot) => catalog.findForSnapshot(snapshot, name, threadId: Some(ThreadId(context.sessionId.value)))
            case None => if (newPreparation) { catalog.find(name, threadId: Some(ThreadId(context.sessionId.value))) } else {
                catalog.findRegistered(name, threadId: Some(ThreadId(context.sessionId.value)))
            }
        }
    }

    public func hasPreparationRead(context: ToolInvocationContext, call: ToolCall): Bool {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Bool = registrationConsumerBody204<Bool>({ =>

        match (registrationForRun(context, call.name, newPreparation: true)) {
            case Some(value) => !value.descriptor.hostServiceOnly && !value.descriptor.controlOnly && value.descriptor.hasPreparationRead
            case None => false
        }
    
            })
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    // Lookup uses the actual Run's immutable registration, never a caller bit.
    public func requiresSeparatePreparationDecision(context: ToolInvocationContext, call: ToolCall): Bool {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Bool = registrationConsumerBody204<Bool>({ =>

        match (registrationForRun(context, call.name, newPreparation: true)) {
            case Some(value) => !value.descriptor.hostServiceOnly && !value.descriptor.controlOnly &&
                value.descriptor.hasPreparationRead && !value.descriptor.preparationReadMayBeAbsent
            case None => false
        }
    
            })
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    // Pure data admission into the installed trusted executor's SAME bank.
    // Real Root/current/policy/Store gates are preserved by their original paths.
    public func retainPreparationInput340(context: ToolInvocationContext, root: ?OperationRootSource,
        call: ToolCall, facts: Array<ContextReadFactLink>): Result<Unit> {
        let view = context.beginInvocationView159()
        try { retainPreparationInput340Scope159(view, root, call, facts) } finally { view.endInvocationView159() }
    }

    private func retainPreparationInput340Scope159(context:ToolInvocationContext,root:?OperationRootSource,
        call:ToolCall,facts:Array<ContextReadFactLink>):Result<Unit>{
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        match(validateToolSnapshotThread(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let selected=match(registrationForRun(context,call.name,newPreparation:true)){
            case Some(value)=>value;case None=>return Result<Unit>.Ok(())}
        match(selected.executor as OwnedPreparationInputExecutor340){case Some(actual)=>
            actual.retainPreparationInput340(context,root,call,facts)
            case None=>Result<Unit>.Ok(())}
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }
    public func preparationReadCommitted340(context:ToolInvocationContext,source:CommittedToolCallRef,
        call:ToolCall):Result<?ToolPreparationRead>{
        match(retainPreparationInput340(context,Some(OperationRootSource.Committed(source)),call,[])){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        preparationReadFunded340(context,call)
    }
    public func preparationReadDirect340(context:ToolInvocationContext,source:DirectToolCallRef,
        call:ToolCall):Result<?ToolPreparationRead>{
        match(retainPreparationInput340(context,Some(OperationRootSource.Direct(source)),call,[])){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        preparationReadFunded340(context,call)
    }
    public func preparationRead(context: ToolInvocationContext, call: ToolCall): Result<?ToolPreparationRead> {
        match(retainPreparationInput340(context,None<OperationRootSource>,call,[])){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        preparationReadFunded340(context,call)
    }
    private func preparationReadFunded340(context: ToolInvocationContext, call: ToolCall): Result<?ToolPreparationRead> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<?ToolPreparationRead> = registrationConsumerBody204<Result<?ToolPreparationRead>>({ =>

        match (validateToolSnapshotThread(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let registration = match (registrationForRun(context, call.name, newPreparation: true)) {
            case Some(value) => value; case None => return Result.Ok(None) }
        if (registration.descriptor.hostServiceOnly || registration.descriptor.controlOnly) { return Result.Ok(None) }
        match (validator.validate(call, registration.descriptor.definition)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        registration.descriptor.preparationRead(context, call)
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    // Sole production AgentCore entry. A CommittedToolCallRef can only be
    // minted after a validated durable Decision has been atomically projected
    // into the canonical Thread.
    public func prepareCommitted(
        context: ToolInvocationContext,
        committed: CommittedToolCallRef,
        effectiveArguments!: ?AgentValue = None,
        contextReadFacts!: Array<ContextReadFactLink> = []
    ): Result<ToolPreparation> {
        let arguments = match (effectiveArguments) {
            case Some(value) => value
            case None => committed.block.arguments
        }
        let retainedCall=ToolCall(committed.block.callId,committed.block.name,arguments)
        match(retainPreparationInput340(context,Some(OperationRootSource.Committed(committed)),retainedCall,contextReadFacts)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        prepareResolved(context, ToolCall(
            committed.block.callId,
            committed.block.name,
            arguments
        ), Some(OperationId(
            "operation-" + committed.decisionId.value + "-" +
                committed.scopedToolCallId.value
        )), PreparedInvocationSource(
            PreparedInvocationSourceKind.Committed, context,
            rootToolCall: Some(committed), contextReadFacts: contextReadFacts
        ))
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
        match(retainPreparationInput340(context,None<OperationRootSource>,call,[])){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        prepareResolved(context, call, None, PreparedInvocationSource(
            PreparedInvocationSourceKind.Direct, context
        ))
    }

    // Continue only the original live UserDirect parent after its optional
    // pure resolver reported no read. This adds no facts, grants or new root.
    public func prepareAttestedDirect(context: ToolInvocationContext, source: DirectToolCallRef): Result<ToolPreparation> {
        match (source.origin) { case DirectCallOrigin.UserDirect => ()
            case _ => return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "tool.direct_source_required", "preparation requires an actual UserDirect parent")) }
        match (source.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (context.trustedControl || context.runId.value != source.runId.value || context.epoch != source.epoch ||
            context.sessionId.value != source.threadId.value || source.call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome()) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "tool.direct_source_changed",
                "preparation must keep the actual parent and cannot attach unobserved read facts")) }
        match(retainPreparationInput340(context,Some(OperationRootSource.Direct(source)),source.call,[])){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        return prepareResolved(context, source.call, Some(source.operationId), PreparedInvocationSource(
            PreparedInvocationSourceKind.Direct, context, operationRoot: Some(OperationRootSource.Direct(source))))
    }

    // A real pending UserDirect Item is required before attaching facts. The
    // DTO list grants nothing: Store checks every Receipt against this parent.
    public func prepareDirectWithContextReads(context: ToolInvocationContext, source: DirectToolCallRef,
        effectiveArguments: AgentValue, facts: Array<ContextReadFactLink>): Result<ToolPreparation> {
        match (source.origin) { case DirectCallOrigin.UserDirect => ()
            case _ => return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "context.read_direct_source_required", "only an actual UserDirect parent can continue this preparation")) }
        match (source.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if(context.trustedControl || context.runId.value!=source.runId.value || context.epoch!=source.epoch ||
            context.sessionId.value!=source.threadId.value){
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"context.read_direct_input_changed",
                "Direct continuation must keep its actual live parent scope"))}
        match(retainPreparationInput340(context,Some(OperationRootSource.Direct(source)),
            ToolCall(source.call.callId,source.call.name,effectiveArguments),facts)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if (context.trustedControl || context.runId.value != source.runId.value || context.epoch != source.epoch ||
            context.sessionId.value != source.threadId.value || facts.isEmpty() ||
            canonicalAgentValue(contextReadBusinessInput(effectiveArguments)) != canonicalAgentValue(source.call.arguments)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "context.read_direct_input_changed",
                "Direct continuation must preserve its actual parent identity and business arguments")) }
        return prepareResolved(context, ToolCall(source.call.callId, source.call.name, effectiveArguments),
            Some(source.operationId), PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context,
                operationRoot: Some(OperationRootSource.Direct(source)), contextReadFacts: facts))
    }

    // Preparation may select only the fixed resource-read port. The seal does
    // not skip capabilities or approval and never enters the executor itself.
    public func prepareContextRead(context: ToolInvocationContext, call: ToolCall,
        admission: ContextReadAdmission, read!: ?ToolPreparationRead = None): Result<ToolPreparation> {
        match (admission.validateLive()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (context.trustedControl || context.runId.value != admission.run.runId.value ||
            context.sessionId.value != admission.run.threadId.value || context.epoch != admission.run.epoch ||
            !admission.matchesInput(call) || contextReadProjectionDigest(context.contextProjection) !=
                contextReadProjectionDigest(admission.run.contextSnapshot)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "context.read_preparation_mismatch",
                "read preparation requires its exact current unprivileged invocation view"))
        }
        match (read) { case Some(value) =>
            if (value.ownerNamespace != admission.ownerNamespace || value.packageDigest != admission.packageDigest ||
                value.configurationDigest != admission.configurationDigest ||
                canonicalAgentValue(value.request()) != canonicalAgentValue(call.arguments)) {
                return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "context.read_request_changed",
                    "resource preparation differs from its retained host request")) }
            if (httpIntentText(call.arguments, "schema") == CONTEXT_READ_RESOURCE_SCHEMA) {
                match (value.validateBoundary(context, call.arguments)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            }
            case None => () }
        let result = match (prepareResolved(context, call, None, PreparedInvocationSource(
            PreparedInvocationSourceKind.Direct, context, contextReadAdmission: Some(admission), contextReadPreparation: read))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let plan: ?NormalizedOperationPlan = match (result) {
            case ToolPreparation.Ready(value) => Some(value.operationPlan)
            case ToolPreparation.NeedsApproval(value, _) => Some(value.operationPlan)
            case _ => None }
        match (plan) { case Some(value) => if (!isContextReadPlan(value)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "context.read_plan_invalid",
                "context preparation cannot request a write, network, process or replayable effect")) }
            case None => () }
        Result.Ok(result)
    }

    // The real ingress admission is checked before even a powerless tool
    // canonicalizer runs. Origin DTOs do not enter this API.
    public func prepareExternal(context: ToolInvocationContext, call: ToolCall,
        admission: ExternalCallAdmission): Result<ToolPreparation> {
        match (admission.validateLive()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (admission.run.runId.value != context.runId.value || admission.run.epoch != context.epoch || !admission.matchesInput(call)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "external.admission_stale", "external preparation does not own this input and Run"))
        }
        match (validateExternalInvocationContext(context, admission.binding, admission.cancellationToken, false)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        let prepared = match (prepare(context, call)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        let plan: ?NormalizedOperationPlan = match (prepared) {
            case ToolPreparation.Ready(value) => Some(value.operationPlan)
            case ToolPreparation.NeedsApproval(value, _) => Some(value.operationPlan)
            case _ => None
        }
        match (plan) {
            case Some(value) => match (admission.validatePlan(value)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            case None => ()
        }
        Result.Ok(prepared)
    }

    public func prepareManagedJob(context: ToolInvocationContext, root: DirectToolCallRef): Result<PreparedToolInvocation> {
        if (root.managedJob.isNone() || context.hasToolSetSnapshot159()) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "task.managed_job_source_required",
                "Task preparation requires its live sealed child source and no borrowed Thread snapshot"))
        }
        let ceiling = CapabilitySet(values: context.capabilities.values.clone())
        match (validateManagedJobContext(context, root, ceiling)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let plan = match (root.managedJob.getOrThrow().frozenPlan()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let source = PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context,
            operationRoot: Some(OperationRootSource.Direct(root)), managedJobCeiling: Some(ceiling))
        let registration = match (managedJobRegistration(source, plan.toolName)) {
            case Some(value) => value; case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "task.managed_job_registration_missing", "original managed contribution is no longer installed")) }
        let canonical = ToolCall(root.call.callId, plan.toolName, plan.canonicalArguments)
        let descriptor = registration.descriptor.resolved(canonical)
        if (descriptor.controlOnly || descriptor.hostServiceOnly ||
            !sameNormalizedOperationPlan(normalizedToolOperationPlan(context, canonical, descriptor, contextReadFacts: plan.contextReadFacts), plan)) {
            return Result.Err(AgentError(AgentErrorKind.Conflict, "task.managed_job_plan_changed", "Task execution changed its approved immutable plan"))
        }
        match (missingRequiredCapability(context, plan.requiredCapabilities)) {
            case Some(_) => return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "task.managed_job_capability_missing", "Task execution lacks an originally required capability"))
            case None => ()
        }
        match (prepareDirectPlanDataFrame204(context, root, plan)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(PreparedToolInvocation(root.operationId, root.call, descriptor.concurrency,
            PreparedAuthorization.ManagedJob, plan, source))
    }

    private func managedJobRegistration(source: PreparedInvocationSource, name: String): ?ToolRegistration {
        match (managedJobRoot(source)) {
            case Some(root) =>
                if (source.kind != PreparedInvocationSourceKind.Direct || root.validateLiveSource().isError()) { return None }
                let selected = catalog.find(name, threadId: Some(root.managedJob.getOrThrow().binding.parentThreadId))
                match (selected) { case Some(value) => if (value.descriptor.hostServiceOnly || value.descriptor.controlOnly) { None } else { selected }
                    case None => None }
            case None => None
        }
    }

    public func bindDirectRoot(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        source: DirectToolCallRef
    ): Result<PreparedToolInvocation> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<PreparedToolInvocation> = registrationConsumerBody204<Result<PreparedToolInvocation>>({ =>

        if(context.runId.value!=source.runId.value || context.epoch!=source.epoch ||
            context.sessionId.value!=source.threadId.value){
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"tool.direct_source_invalid",
                "direct source does not attest this prepared invocation"))}
        match(retainPreparationInput340(context,Some(OperationRootSource.Direct(source)),prepared.call,prepared.borrowOperationPlanFrame204().contextReadFacts)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if (prepared.source.kind != PreparedInvocationSourceKind.Direct ||
            prepared.source.operationRoot.isSome() ||
            source.runId.value != context.runId.value || source.epoch != context.epoch ||
            source.threadId.value != context.sessionId.value ||
            source.operationId.value != prepared.operationId.value ||
            source.call.callId != prepared.call.callId || source.call.name != prepared.call.name ||
            canonicalAgentValue(source.call.arguments) != canonicalAgentValue(match (source.origin) {
                case DirectCallOrigin.ContextRead(_) => prepared.borrowOperationPlanFrame204().canonicalArguments
                case _ => prepared.call.arguments })) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "tool.direct_source_invalid", "direct source does not attest this prepared invocation"))
        }
        match (source.origin) {
            case DirectCallOrigin.ManagedJob(_) => return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "task.managed_job_prepare_required", "Task source can only bind its retained immutable preparation"))
            case DirectCallOrigin.ContextRead(_) => match (prepared.source.contextReadAdmission) {
                case Some(value) => if (!value.matchesCanonicalOrigin(source.origin, prepared.borrowOperationPlanFrame204())) {
                    return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "context.read_source_changed", "read source differs from its prepared plan")) }
                case None => return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                    "context.read_admission_missing", "raw preparation cannot acquire a context read source")) }
            case _ => if (prepared.source.contextReadAdmission.isSome()) {
                return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "context.read_origin_downgraded", "read preparation cannot change its origin")) }
        }
        match (validatePreparedSourceContext(context, prepared.source)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        match (source.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (source.validateExternalPlan(prepared.borrowOperationPlanFrame204())) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (source.externalBinding) {
            case Some(binding) => match (validateExternalInvocationContext(context, binding, source.externalCancellationToken.getOrThrow(), false)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            case None => ()
        }
        Result.Ok(PreparedToolInvocation(
            prepared.operationId, prepared.call, prepared.borrowConcurrencyFrame204(), prepared.authorization,
            prepared.borrowOperationPlanFrame204(), PreparedInvocationSource(
                PreparedInvocationSourceKind.Direct, context,
                operationRoot: Some(OperationRootSource.Direct(source)), contextReadFacts: prepared.borrowOperationPlanFrame204().contextReadFacts,
                contextReadAdmission: prepared.source.contextReadAdmission,
                contextReadPreparation: prepared.source.contextReadPreparation
            ), approval: prepared.borrowApprovalFrame204()
        ))
    
            })
            let outward204 = match (consumerFrame204) { case Some(value) => value.retainPreparedValueResult204(result204); case None => result204 }
            returnedConsumer204 = true
            outward204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    // Opt-in preparation for the new independent effect family. This does
    // not admit, execute, suspend, settle or approve a child. The existing
    // Store is closed to this new family until its separate actual Source /
    // full receipt-prefix / current-fence admission is implemented.
    public func prepareLivePolicyChild(
        parentContext:ToolInvocationContext,context:ToolInvocationContext,
        call:ToolCall,parent:PreparedToolInvocation,requestKey:String
    ):Result<ToolPreparation>{
        if(parent.source.kind==PreparedInvocationSourceKind.Derived || parent.source.operationRoot.isNone() ||
            parent.authorization==PreparedAuthorization.ApprovalRequired || context.trustedControl ||
            !isPluginLivePolicyParentPlan(parent.operationPlan) || call.name!=HOST_PLUGIN_LIVE_EFFECT_TOOL ||
            !pluginLivePolicyChildValueValid(call.arguments)){
            return livePolicyPreparationError<ToolPreparation>("tool.live_policy_parent_invalid")}
        let sequence=call.arguments.field("sequence").getOrThrow().asNumberText()
        if(call.callId!=parent.call.callId+":live:"+sequence || requestKey!="live-policy:"+parent.call.callId+":"+sequence ||
            context.runId.value!=parent.source.runId.value || context.sessionId.value!=parent.source.sessionId.value ||
            context.epoch!=parent.source.epoch){return livePolicyPreparationError<ToolPreparation>("tool.live_policy_child_identity_invalid")}
        match(validatePreparedSourceContext(parentContext,parent.source)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let actual=match(operations.loadPlan(parent.operationId,parentContext.runId)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(!sameNormalizedOperationPlan(actual,parent.operationPlan)){
            return livePolicyPreparationError<ToolPreparation>("tool.live_policy_parent_changed")}
        let source=PreparedInvocationSource(PreparedInvocationSourceKind.Derived,context,
            operationRoot:parent.source.operationRoot,parentOperationId:Some(parent.operationId),
            requestKey:requestKey,parentCallId:parent.call.callId,managedJobCeiling:parent.source.managedJobCeiling)
        match(validatePreparedSourceContext(context,source)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        // No parent plan is supplied. The concrete child goes through the
        // complete ordinary capability / permanent-denial / policy / approval
        // evaluation. A parent ceiling cannot become ParentIntent approval.
        let preparation=match(prepareResolved(context,call,None,source,parentIntentPlan:None)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let prepared:?PreparedToolInvocation=match(preparation){
            case ToolPreparation.Ready(value)=>Some(value)
            case ToolPreparation.NeedsApproval(value,_)=>Some(value)
            case _=>None}
        match(prepared){case Some(value)=>
            if(value.authorization==PreparedAuthorization.ParentIntent ||
                !pluginLivePolicyChildWithinCeiling(parent.operationPlan,value.operationPlan) ||
                requestKey!=pluginLivePolicyRequestKey(parent.call.callId,value.operationPlan)){
                return livePolicyPreparationError<ToolPreparation>("tool.live_policy_child_scope_changed")}
            case None=>()}
        match(validatePreparedSourceContext(parentContext,parent.source)){
            case Result.Err(error)=>
                match(preparation){case ToolPreparation.Completed(value)=>value.releasePayload();case _=>()}
                return Result.Err(error)
            case Result.Ok(_)=>()}
        Result.Ok(preparation)
    }

    // Strict opt-in typed dispatch. Registration downcasts preserve the actual
    // trusted executor object; no Native DTO, legacy lambda or error can mint
    // an owned executor, private pending continuation or terminal witness.
    private func verifyOwnedRuntimeOwnedParentTerminal(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,
        epoch:Int64,plan:NormalizedOperationPlan,expected:?ApprovalRequest,result:ToolResult,
        dataOwner:OperationTerminalDataOwner,guard:()->Result<Unit>):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(plan)){
            operations.verifyManagedChannelOwnedActualParentTerminal(root,parent,run,thread,epoch,plan,expected,result,dataOwner,guard)
        }else{operations.verifyPluginLivePolicyOwnedParentTerminal(root,parent,run,thread,epoch,plan,expected,result,dataOwner,guard)}
    }

    private func prepareOwnedRuntimeParent(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,approval:?ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(plan)){operations.prepareManagedChannelOwnedParent(root,parent,run,thread,epoch,plan,approval,guard)}
        else{operations.preparePluginLivePolicyParent(root,parent,run,thread,epoch,plan,approval,guard)}
    }

    private func recordOwnedRuntimeParentApproval(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(plan)){operations.recordManagedChannelOwnedParentApproval(root,parent,run,thread,epoch,plan,expected,approvalId,ceiling,approved,source,expires,guard)}
        else{operations.recordPluginLivePolicyParentApproval(root,parent,run,thread,epoch,plan,expected,approvalId,ceiling,approved,source,expires,guard)}
    }

    private func markOwnedRuntimeParentExecuting(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,nowMillis:Int64,approvalRequired:Bool,guard:()->Result<Unit>):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(plan)){operations.markManagedChannelOwnedParentExecuting(root,parent,run,thread,epoch,plan,nowMillis,approvalRequired,guard)}
        else{operations.markPluginLivePolicyParentExecuting(root,parent,run,thread,epoch,plan,nowMillis,approvalRequired,guard)}
    }

    private func markOwnedRuntimeParentHandoff(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,nowMillis:Int64,guard:()->Result<Unit>):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(plan)){operations.markManagedChannelOwnedParentHandoff(root,parent,run,thread,epoch,plan,nowMillis,guard)}
        else{operations.markPluginLivePolicyParentHandoff(root,parent,run,thread,epoch,plan,nowMillis,guard)}
    }

    private func recordOwnedRuntimeChildApproval(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(parentPlan)){operations.recordManagedChannelOwnedChildApproval(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,approvalId,ceiling,approved,source,expires,guard)}
        else{operations.recordPluginLivePolicyChildApproval(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,approvalId,ceiling,approved,source,expires,guard)}
    }

    private func recordOwnedRuntimeChildApprovalWithRejectionError(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>,rejectionError:?AgentError):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(parentPlan)){operations.recordManagedChannelOwnedChildApprovalWithRejectionError(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,approvalId,ceiling,approved,source,expires,guard,rejectionError)}
        else{operations.recordPluginLivePolicyChildApprovalWithRejectionError(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,approvalId,ceiling,approved,source,expires,guard,rejectionError)}
    }

    private func markOwnedRuntimeChildExecuting(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,nowMillis:Int64,approvalRequired:Bool,guard:()->Result<Unit>):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(parentPlan)){operations.markManagedChannelOwnedChildExecuting(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,nowMillis,approvalRequired,guard)}
        else{operations.markPluginLivePolicyChildExecuting(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,nowMillis,approvalRequired,guard)}
    }

    private func markOwnedRuntimeChildHandoff(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,nowMillis:Int64,guard:()->Result<Unit>):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(parentPlan)){operations.markManagedChannelOwnedChildHandoff(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,nowMillis,guard)}
        else{operations.markPluginLivePolicyChildHandoff(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,nowMillis,guard)}
    }

    private func prepareOwnedRuntimeInvocation(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,call:ToolCall,approval:?ApprovalRequest,guard:()->Result<Unit>):Result<OperationId>{
        if(isManagedChannelOwnedParentPlan(parentPlan)){operations.prepareManagedChannelOwnedInvocation(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,call,approval,guard)}
        else{operations.preparePluginLivePolicyInvocation(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,call,approval,guard)}
    }

    private func verifyOwnedRuntimePending(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,childCallId:String,approval:ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(parentPlan)){operations.verifyManagedChannelOwnedPending(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,childCallId,approval,guard)}
        else{operations.verifyPluginLivePolicyPending(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,childCallId,approval,guard)}
    }

    private func verifyOwnedRuntimeChildTerminal(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,result:ToolResult,guard:()->Result<Unit>,
        actualExecutor:ToolExecutor):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(parentPlan)){operations.verifyManagedChannelOwnedChildTerminal(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,result,guard)}
        else if((actualExecutor as NativeAbortOwnedToolEffectExecutor340).isSome()){
            operations.verifyPluginLivePolicyChildTerminalNativeAbort340(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,result,guard)}
        else{operations.verifyPluginLivePolicyChildTerminal(root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,result,guard)}
    }

    private func verifyOwnedRuntimeParentTerminal(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,
        epoch:Int64,plan:NormalizedOperationPlan,result:ToolResult,guard:()->Result<Unit>):Result<Unit>{
        if(isManagedChannelOwnedParentPlan(plan)){operations.verifyManagedChannelOwnedParentTerminal(root,parent,run,thread,epoch,plan,result,guard)}
        else{operations.verifyPluginLivePolicyParentTerminal(root,parent,run,thread,epoch,plan,result,guard)}
    }

    private func validateManagedChannelOwnedCurrent(context:ToolInvocationContext,prepared:PreparedToolInvocation):Result<Unit>{
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        match(validateToolSnapshotThread(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(livePolicyPendingGuard(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let source=prepared.source
        if(context.trustedControl || source.runId.value!=context.runId.value || source.sessionId.value!=context.sessionId.value ||
            source.epoch!=context.epoch || source.operationRoot.isNone() ||
            (!isManagedChannelOwnedParentPlan(prepared.borrowOperationPlanFrame204()) && !isManagedChannelOwnedChildPlan(prepared.borrowOperationPlanFrame204()))){
            return livePolicyPreparationError("tool.live_prepared_context_changed")}
        let binding=prepared.borrowOperationPlanFrame204().canonicalArguments.field(if(isManagedChannelOwnedParentPlan(prepared.borrowOperationPlanFrame204())){"host_plan"}else{"binding"}).getOrThrow()
        let actual=if(isManagedChannelOwnedParentPlan(prepared.borrowOperationPlanFrame204())){binding.field("binding").getOrThrow()}else{binding}
        if(httpIntentText(actual,"run_id")!=context.runId.value || httpIntentText(actual,"target_thread_id")!=context.sessionId.value ||
            actual.field("epoch").getOrThrow().asNumberText()!=context.epoch.toString()){
            return livePolicyPreparationError("tool.live_prepared_enclosure_changed")}
        let registration=match(registrationForRun(context,prepared.call.name,allowHostService:hostServiceSourceAllowed(source,prepared.call.name))){
            case Some(value)=>value;case None=>return livePolicyPreparationError("tool.live_prepared_registration_missing")}
        if(isManagedChannelOwnedParentPlan(prepared.borrowOperationPlanFrame204())){
            if((registration.executor as ManagedChannelOwnedExecutor).isNone()){return livePolicyPreparationError("managed_channel.parent_executor_missing")}
        }else if((registration.executor as ManagedChannelOwnedEffectExecutor).isNone()){
            return livePolicyPreparationError("managed_channel.child_executor_missing")}
        let call=ToolCall(prepared.call.callId,prepared.call.name,prepared.borrowOperationPlanFrame204().canonicalArguments)
        let current=normalizedToolOperationPlan(context,call,registration.descriptor.resolved(call),contextReadFacts:prepared.borrowOperationPlanFrame204().contextReadFacts)
        if(!sameNormalizedOperationPlan(current,prepared.borrowOperationPlanFrame204())){return livePolicyPreparationError("tool.live_prepared_descriptor_changed")}
        match(missingRequiredCapability(context,prepared.borrowOperationPlanFrame204().requiredCapabilities)){
            case Some(_)=>return livePolicyPreparationError("tool.live_prepared_capability_revoked");case None=>()}
        Result.Ok(())
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func prepareManagedChannelOwnedChild(parentContext:ToolInvocationContext,context:ToolInvocationContext,
        call:ToolCall,parent:PreparedToolInvocation,requestKey:String):Result<ToolPreparation>{
        if(context.trustedControl || parent.source.kind==PreparedInvocationSourceKind.Derived ||
            parent.source.operationRoot.isNone() || parent.authorization==PreparedAuthorization.ApprovalRequired ||
            !isManagedChannelOwnedParentPlan(parent.operationPlan) || ![HOST_MANAGED_CHANNEL_WRITE_TOOL,HOST_MANAGED_CHANNEL_SPAWN_TOOL,HOST_MANAGED_CHANNEL_CLOSE_TOOL].contains(call.name) ||
            !managedChannelRuntimeChildValueValid(call.arguments) || context.runId.value!=parent.source.runId.value ||
            context.sessionId.value!=parent.source.sessionId.value || context.epoch!=parent.source.epoch){
            return livePolicyPreparationError<ToolPreparation>("tool.live_policy_parent_invalid")}
        if(!refEq(parentContext.budget,context.budget)){return livePolicyPreparationError<ToolPreparation>("managed_channel.single_budget_changed")}
        let sequence=call.arguments.field("sequence").getOrThrow().asNumberText()
        if(call.callId!=parent.call.callId+":managed:"+sequence || requestKey!="managed-channel:"+parent.call.callId+":"+sequence){
            return livePolicyPreparationError<ToolPreparation>("tool.live_policy_child_identity_invalid")}
        match(validatePreparedSourceContext(parentContext,parent.source)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(livePolicyPendingGuard(parentContext)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let source=PreparedInvocationSource(PreparedInvocationSourceKind.Derived,context,
            operationRoot:parent.source.operationRoot,parentOperationId:Some(parent.operationId),requestKey:requestKey,
            parentCallId:parent.call.callId,managedJobCeiling:parent.source.managedJobCeiling)
        match(validatePreparedSourceContext(context,source)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let preparation=match(prepareResolved(context,call,None,source,parentIntentPlan:None)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(preparation){
            case ToolPreparation.Denied(_) | ToolPreparation.Completed(_)=>
                match(operations.recordManagedChannelOwnedStop(parent.source.operationRoot.getOrThrow(),parent.operationId,
                    context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,call,requestKey,
                    "ordinary_policy_preparation_stopped",{=>livePolicyPendingGuard(context)})){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            case _=>()}
        let selected:?PreparedToolInvocation=match(preparation){case ToolPreparation.Ready(value)=>Some(value)
            case ToolPreparation.NeedsApproval(value,_)=>Some(value);case _=>None}
        match(selected){case Some(value)=>
            if(value.authorization==PreparedAuthorization.ParentIntent ||
                !managedChannelOwnedChildAllowed(parent.operationPlan,value.operationPlan) ||
                requestKey!=managedChannelOwnedRequestKey(parent.call.callId,value.operationPlan)){
                return livePolicyPreparationError<ToolPreparation>("tool.live_policy_child_scope_changed")}
            match(validatePreparedSourceContext(parentContext,parent.source)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(validatePreparedSourceContext(context,value.source)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let pending:?ApprovalRequest=match(preparation){case ToolPreparation.NeedsApproval(_,approval)=>Some(approval);case _=>None}
            // The exact waiting state and approval tuple are written with its
            // whole Source/current/read-input/receipt-prefix proof in one TX.
            match(operations.prepareManagedChannelOwnedInvocation(parent.source.operationRoot.getOrThrow(),parent.operationId,
                value.operationId,context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,
                value.operationPlan,requestKey,ToolCall(value.call.callId,value.call.name,value.operationPlan.canonicalArguments),
                pending,{=>livePolicyPendingGuard(context)})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>
                    if(actual.value!=value.operationId.value){return livePolicyPreparationError<ToolPreparation>("tool.live_policy_child_identity_changed")}}
            // Source and current contribution checks occur OUTSIDE the SQL
            // lock, again before the Host can release or publish its custody.
            match(validatePreparedSourceContext(parentContext,parent.source)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(livePolicyPendingGuard(context)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            case None=>()}
        match(validatePreparedSourceContext(parentContext,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validateLivePreparedCurrent(parentContext,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(preparation)
    }

    private func withExecutionHandoff(registration: ToolRegistration, context: ToolInvocationContext,
        prepared: PreparedToolInvocation, action: () -> Result<Unit>): Result<Unit> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        let leases = ArrayList<ToolExecutionHandoffLease>()
        try {
            match (registration.executor.acquireHandoffLease(context, prepared)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => leases.add(value)
            }
            // Derived children retain the actual canonical root attestation.
            // Its installed executor also restricts handoff. It cannot grant
            // permission: every original Store/source/capability check remains.
            match (prepared.source.operationRoot) {
                case Some(root) => if (root.toolName() != prepared.call.name) {
                    let actual = match (registrationForRun(context, root.toolName(), allowHostService: true)) {
                        case Some(value) => value; case None => return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                            "tool.root_registration_revoked", "canonical root executor is unavailable before handoff"))
                    }
                    match (actual.executor.acquireHandoffLease(context, prepared)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => leases.add(value)
                    }
                }
                case None => ()
            }
            action()
        } finally { for (index in 0..leases.size) { leases[leases.size - index - 1].close() } }
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func executeOwnedPrepared(context:ToolInvocationContext,parent:PreparedToolInvocation,
        afterHandoff!:(PreparedToolInvocation)->Result<Unit>={_=>Result.Ok(())},
        afterExecutionAdmission!:()->Unit={=>()}):Result<OwnedToolPipelineProgress>{
        let view=context.beginInvocationView159()
        try{executeOwnedPreparedScope159(view,parent,afterHandoff:afterHandoff,afterExecutionAdmission:afterExecutionAdmission)}finally{view.endInvocationView159()}
    }

    private func executeOwnedPreparedScope159(context:ToolInvocationContext,parent:PreparedToolInvocation,
        afterHandoff!:(PreparedToolInvocation)->Result<Unit>={_=>Result.Ok(())},
        afterExecutionAdmission!:()->Unit={=>()}):Result<OwnedToolPipelineProgress>{
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<OwnedToolPipelineProgress> = registrationConsumerBody204<Result<OwnedToolPipelineProgress>>({ =>

        if(parent.authorization==PreparedAuthorization.ApprovalRequired ||
            parent.authorization==PreparedAuthorization.ParentIntent ||
            !ownedRuntimeParentPlan(parent.operationPlan) || parent.source.kind==PreparedInvocationSourceKind.Derived ||
            parent.source.operationRoot.isNone()){
            return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_parent_not_authorized")}
        match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let registration=match(registrationForRun(context,parent.call.name)){
            case Some(value)=>value;case None=>return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_registration_missing")}
        let executor=match(registration.executor as OwnedToolExecutor){case Some(value)=>value
            case None=>return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_executor_missing")}
        if(!catalog.beginExecution(registration,parent.operationId,context.runId,ThreadId(context.sessionId.value))){
            return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_registration_revoked")}
        try{
            match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let root=parent.source.operationRoot.getOrThrow()
            match(withExecutionHandoff(registration, context, parent, { => markOwnedRuntimeParentExecuting(root,parent.operationId,context.runId,
                ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,agentUtcMillis(),
                parent.authorization==PreparedAuthorization.Approved,{=>livePolicyPendingGuard(context)}) })){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            afterExecutionAdmission()
            match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(withExecutionHandoff(registration, context, parent, { => markOwnedRuntimeParentHandoff(root,parent.operationId,context.runId,
                ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,agentUtcMillis(),{=>livePolicyPendingGuard(context)}) })){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(afterHandoff(parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(catalog.executionWasRevoked(registration)){
                return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_registration_revoked")}
            let control=match(ownedExecutionControlForExecutor(context,parent,None,executor)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            match(executor as OwnedPreparedPhaseExecutor){case Some(actual)=>
                let returned=try{actual.executePreparedPhase(context,parent,control)}finally{control.close()}
                return acceptPreparedPhaseProgress(context,parent,returned,control)
                case None=>()}
            let returned=try{executor.executeOwned(context,parent,control)}finally{control.close()}
            acceptOwnedExecutionProgress(context,parent,returned,terminalControl:Some(control))
        }finally{catalog.finishExecution(registration,parent.operationId)}
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func decideOwnedPrepared(context:ToolInvocationContext,parent:PreparedToolInvocation,decision:ApprovalDecision,
        decisionSource!:ApprovalDecisionSource=ApprovalDecisionSource.User,
        afterHandoff!:(PreparedToolInvocation)->Result<Unit>={_=>Result.Ok(())},
        afterExecutionAdmission!:()->Unit={=>()}):Result<OwnedToolPipelineProgress>{
        let view=context.beginInvocationView159()
        try{decideOwnedPreparedScope159(view,parent,decision,decisionSource:decisionSource,afterHandoff:afterHandoff,afterExecutionAdmission:afterExecutionAdmission)}finally{view.endInvocationView159()}
    }

    private func decideOwnedPreparedScope159(context:ToolInvocationContext,parent:PreparedToolInvocation,decision:ApprovalDecision,
        decisionSource!:ApprovalDecisionSource=ApprovalDecisionSource.User,
        afterHandoff!:(PreparedToolInvocation)->Result<Unit>={_=>Result.Ok(())},
        afterExecutionAdmission!:()->Unit={=>()}):Result<OwnedToolPipelineProgress>{
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<OwnedToolPipelineProgress> = registrationConsumerBody204<Result<OwnedToolPipelineProgress>>({ =>

        if(parent.approval.isNone()){return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_parent_approval_missing")}
        match(validateRetainedOwnedParentDecision(context,parent,parent.approval.getOrThrow(),decision)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let approved=match(decision){case ApprovalDecision.Approve | ApprovalDecision.ApproveSession=>true;case _=>false}
        match(recordOwnedRuntimeParentApproval(parent.source.operationRoot.getOrThrow(),parent.operationId,
            context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,parent.approval.getOrThrow(),
            "approval-"+parent.operationId.value,CapabilitySet(values:parent.operationPlan.requiredCapabilities),approved,
            approvalDecisionSourceName(decisionSource),None,{=>livePolicyPendingGuard(context)})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(decision){case ApprovalDecision.ApproveSession=>
            match(copiedPermissionGrant204(context,context.sessionId,parent.operationPlan.approvalMetadata.grantScope)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};case _=>()}
        if(approved){return executeOwnedPrepared(context,preparedWithAuthorization(parent,PreparedAuthorization.Approved),
            afterHandoff:afterHandoff,afterExecutionAdmission:afterExecutionAdmission)}
        // Rejection has no execution handoff. Its real executor must freeze a
        // paid denial and dedicated no-handoff final witness; the old generic
        // rejected resolver is deliberately not used for this family.
        let registration=match(registrationForRun(context,parent.call.name)){
            case Some(value)=>value;case None=>return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_registration_missing")}
        let executor=match(registration.executor as OwnedToolExecutor){case Some(value)=>value
            case None=>return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_executor_missing")}
        if(!catalog.beginExecution(registration,parent.operationId,context.runId,ThreadId(context.sessionId.value))){
            return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_registration_revoked")}
        try{
            let control=match(ownedExecutionControlForExecutor(context,parent,None,executor)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            match(executor as OwnedPreparedPhaseExecutor){case Some(actual)=>
                let returned=try{actual.rejectPreparedPhase(context,parent,decision,control)}finally{control.close()}
                match(returned){case Result.Ok(OwnedPreparedPhaseProgress.Waiting(_))=>
                    return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_rejected_parent_cannot_wait");case _=>()}
                return acceptPreparedPhaseProgress(context,parent,returned,control)
                case None=>()}
            let returned=try{executor.rejectOwned(context,parent,decision,control)}finally{control.close()}
            match(returned){case Result.Ok(OwnedToolExecutionProgress.Waiting(_))=>
                return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_rejected_parent_cannot_wait");case _=>()}
            acceptOwnedExecutionProgress(context,parent,returned,terminalControl:Some(control))
        }finally{catalog.finishExecution(registration,parent.operationId)}
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func resumeOwnedPrepared(context:ToolInvocationContext,publication:OwnedToolExecutionPublication,decision:ApprovalDecision,
        decisionSource!:ApprovalDecisionSource=ApprovalDecisionSource.User,
        afterHandoff!:(PreparedToolInvocation)->Result<Unit>={_=>Result.Ok(())},
        afterExecutionAdmission!:()->Unit={=>()}):Result<OwnedToolPipelineProgress>{
        let view=context.beginInvocationView159()
        try{resumeOwnedPreparedScope159(view,publication,decision,decisionSource:decisionSource,afterHandoff:afterHandoff,afterExecutionAdmission:afterExecutionAdmission)}finally{view.endInvocationView159()}
    }

    private func resumeOwnedPreparedScope159(context:ToolInvocationContext,publication:OwnedToolExecutionPublication,decision:ApprovalDecision,
        decisionSource!:ApprovalDecisionSource=ApprovalDecisionSource.User,
        afterHandoff!:(PreparedToolInvocation)->Result<Unit>={_=>Result.Ok(())},
        afterExecutionAdmission!:()->Unit={=>()}):Result<OwnedToolPipelineProgress>{
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<OwnedToolPipelineProgress> = registrationConsumerBody204<Result<OwnedToolPipelineProgress>>({ =>

        if(publication.isPreparedPhase()){
            return resumePreparedPhasePublication(context,publication,decision,decisionSource)}
        let value=publication.continuation;let parent=value.parent;let child=value.child
        match(validateRetainedOwnedExecutionDecision(context,publication,value.approval,decision)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        // The caller restored THIS Run to running. Full actual SQL Source,
        // immutable child/prefix/approval and current configuration are proved
        // before acquiring the one private claim or recording any decision.
        match(validateOwnedExecutionPublication(context,publication)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let registration=match(registrationForRun(context,parent.call.name)){
            case Some(actual)=>actual;case None=>return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_registration_missing")}
        let executor=match(registration.executor as OwnedToolExecutor){case Some(actual)=>actual
            case None=>return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_executor_missing")}
        if(!catalog.beginExecution(registration,parent.operationId,context.runId,ThreadId(context.sessionId.value))){
            return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_registration_revoked")}
        try{
            if(!value.claim()){return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_claim_changed")}
            // Any uncertain decision/driver failure keeps this same claimed
            // physical custody in its Host collector. No implicit retry or
            // releaseUnstartedClaim occurs after a possibly durable mutation.
            let approved=match(decision){case ApprovalDecision.Approve | ApprovalDecision.ApproveSession=>true;case _=>false}
            // This exact current User decision creates the same actual Error
            // as the original tool approval path. It is data retained by the
            // dedicated same-TX no-effect writer, never a Source or retry grant.
            let rejected:?AgentError=if(approved){None<AgentError>}else{Some(livePolicyChildRejectionError(child.call,decision))}
            match(recordOwnedRuntimeChildApprovalWithRejectionError(parent.source.operationRoot.getOrThrow(),parent.operationId,
                child.operationId,context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,child.operationPlan,
                child.source.requestKey,child.call.callId,value.approval,"approval-"+child.operationId.value,
                CapabilitySet(values:child.operationPlan.requiredCapabilities),approved,approvalDecisionSourceName(decisionSource),None,
                {=>livePolicyPendingGuard(context)},rejected)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(validatePreparedSourceContext(context,child.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(decision){case ApprovalDecision.ApproveSession=>
                match(copiedPermissionGrant204(context,context.sessionId,child.operationPlan.approvalMetadata.grantScope)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};case _=>()}
            match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(catalog.executionWasRevoked(registration)){
                return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_registration_revoked")}
            let approvedPending:?PreparedToolInvocation=if(approved){Some(preparedWithAuthorization(child,PreparedAuthorization.Approved))}else{None}
            let control=match(ownedExecutionControlForExecutor(context,parent,Some(value),executor,resumed:approvedPending)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
            let returned=try{executor.resumeOwned(context,value,decision,control)}finally{control.close()}
            let accepted=acceptOwnedExecutionProgress(context,parent,returned,terminalControl:Some(control))
            match(accepted){
                case Result.Err(error)=>Result.Err(error)
                case Result.Ok(OwnedToolPipelineProgress.Waiting(next))=>
                    match(value.finishClaimWithSuccessor(next.continuation)){
                        case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>Result.Ok(OwnedToolPipelineProgress.Waiting(next))}
                case Result.Ok(OwnedToolPipelineProgress.FailedRetained(result,error))=>
                    result.appendActualCustodyClose({=>value.close()})
                    let cause=match(value.finishClaim()){case Result.Err(failure)=>AgentError(AgentErrorKind.RecoveryRequired,
                        "tool.retained_failure_claim_pending","same failed resources retain physical cleanup debt",
                        fields:[ErrorField("cause",error.code),ErrorField("settlement",failure.code)])
                        case Result.Ok(_)=>error}
                    Result.Ok(OwnedToolPipelineProgress.FailedRetained(result,cause))
                case Result.Ok(OwnedToolPipelineProgress.Retained(result))=>
                    match(result.appendActualCustodyClose({=>value.close()})){
                        case Result.Err(error)=>return Result.Ok(OwnedToolPipelineProgress.RetainedWithDebt(result,error));case Result.Ok(_)=>()}
                    match(value.finishClaim()){
                        case Result.Err(error)=>Result.Ok(OwnedToolPipelineProgress.RetainedWithDebt(result,error))
                        case Result.Ok(_)=>Result.Ok(OwnedToolPipelineProgress.Retained(result))}
                case Result.Ok(OwnedToolPipelineProgress.RetainedWithDebt(result,error))=>
                    Result.Ok(OwnedToolPipelineProgress.RetainedWithDebt(result,error))
                case Result.Ok(OwnedToolPipelineProgress.Completed(result))=>
                    match(value.finishClaim()){case Result.Err(error)=>return Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,error));case Result.Ok(_)=>()}
                    // Final result was independently frozen and paid before
                    // closing the old physical custody. Failure remains debt.
                    match(value.close()){case Result.Err(error)=>Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,error))
                        case Result.Ok(_)=>Result.Ok(OwnedToolPipelineProgress.Completed(result))}
                case Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,error))=>
                    // No synthetic ACK and no conversion of its known result.
                    Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,error))
            }
        }finally{catalog.finishExecution(registration,parent.operationId)}
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    private func acceptPreparedPhaseProgress(context:ToolInvocationContext,parent:PreparedToolInvocation,
        returned:Result<OwnedPreparedPhaseProgress>,control:OwnedToolExecutionControl):Result<OwnedToolPipelineProgress>{
        match(returned){
            case Result.Err(error)=>acceptOwnedExecutionProgress(context,parent,Result.Err(error),terminalControl:Some(control))
            case Result.Ok(OwnedPreparedPhaseProgress.Legacy(value))=>
                // Typed phase executors cannot publish an immutable raw child.
                match(value){case OwnedToolExecutionProgress.Waiting(_)=>return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.prepared_raw_waiting_forbidden");case _=>()}
                acceptOwnedExecutionProgress(context,parent,Result.Ok(value),terminalControl:Some(control))
            case Result.Ok(OwnedPreparedPhaseProgress.Waiting(phase))=>
                let value=match(phase.pendingProof()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
                if(!refEq(value.parent,parent)){return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_pending_parent_changed")}
                match(validateOwnedExecutionPending(context,value)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(value.releaseForPublication()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(validateOwnedExecutionPending(context,value)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                Result.Ok(OwnedToolPipelineProgress.Waiting(OwnedToolExecutionPublication(context,phase,value)))
        }
    }
    private func preparedPhaseControl(context:ToolInvocationContext,parent:PreparedToolInvocation,
        previous:?OwnedToolExecutionContinuation,executor:OwnedPreparedPhaseExecutor,
        custody:OwnedKernelPreparedReferenceCustody,resumed:?PreparedToolInvocation):Result<OwnedToolExecutionControl>{
        let actual=match(executor.preparedReferenceCustody(context,parent)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(!sameLiveToolExecutionCustody(actual,custody)){
            return livePolicyPreparationError<OwnedToolExecutionControl>("tool.prepared_reference_custody_changed")}
        let debt=match(retainOwnedKernelPreparedReferenceDebt(actual,parent,resumed)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        Result.Ok(ownedExecutionControl(context,parent,previous,resumed:resumed,referenceDebt:Some(debt)))
    }
    private func resumePreparedPhasePublication(context:ToolInvocationContext,publication:OwnedToolExecutionPublication,
        decision:ApprovalDecision,decisionSource:ApprovalDecisionSource):Result<OwnedToolPipelineProgress>{
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<OwnedToolPipelineProgress> = registrationConsumerBody204<Result<OwnedToolPipelineProgress>>({ =>

        // Read-only rejection is retryable: no Captured -> Acting, claim,
        // durable decision, execution registration or resource action yet.
        // The original full decision/context/shape policy is still required.
        match(preflightOwnedPreparedPhaseDecision(context,publication,decision,{approval=>
            validateRetainedOwnedExecutionDecision(context,publication,approval,decision)})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let phase=publication.preparedPhase.getOrThrow()
        let parent=match(phase.pendingParent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let registration=match(registrationForRun(context,parent.call.name)){
            case Some(value)=>value;case None=>return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_registration_missing")}
        let executor=match(registration.executor as OwnedPreparedPhaseExecutor){case Some(value)=>value
            case None=>return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.prepared_phase_executor_missing")}
        if(!catalog.beginExecution(registration,parent.operationId,context.runId,ThreadId(context.sessionId.value))){
            return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_registration_revoked")}
        try{
            let settlement=OwnedPreparedInputActionSettlement()
            let witness=match(phase.consumeInputPhase({_,_=>
                preparedInputActionFrame(context,publication,phase,parent,executor,decision,decisionSource,settlement)})){
                case Result.Err(error)=>match(settlement.failed){
                    case Some(actual)=>return Result.Ok(OwnedToolPipelineProgress.FailedRetained(actual,error))
                    case None=>return Result.Err(error)}
                case Result.Ok(value)=>value}
            // The complete old child/proof/approved/control helper is gone.
            // Parent/public approval/Host/Source escapers still retain original
            // funding; this witness is ONLY Kernel fields, never Host unlock.
            match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(catalog.executionWasRevoked(registration)){
                return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_owned_registration_revoked")}
            let control=match(preparedPhaseControl(context,parent,None<OwnedToolExecutionContinuation>,executor,
                phase.inputCustody(),None<PreparedToolInvocation>)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let returned=try{executor.continuePreparedInput(context,parent,witness,control,phase.inputCustody())}finally{control.close()}
            acceptPreparedPhaseProgress(context,parent,returned,control)
        }finally{catalog.finishExecution(registration,parent.operationId)}
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }
    // All full child/proof/approved/action references are restricted to this
    // lexical helper. Returning does not prove unrelated Host/UI aliases died.
    private func preparedInputActionFrame(context:ToolInvocationContext,publication:OwnedToolExecutionPublication,
        phase:OwnedPreparedWaitingPhase,parent:PreparedToolInvocation,executor:OwnedPreparedPhaseExecutor,
        decision:ApprovalDecision,decisionSource:ApprovalDecisionSource,
        settlement:OwnedPreparedInputActionSettlement):Result<Unit>{
        let value=match(phase.actingProof()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
        let child=value.child
        if(!refEq(value.parent,parent) || !value.sameCustody(phase.inputCustody()) ||
            publication.runId.value!=context.runId.value || publication.threadId.value!=context.sessionId.value ||
            publication.epoch!=context.epoch || publication.projectionDigest!=contextReadProjectionDigest(context.contextProjection) ||
            value.parent.operationId.value!=publication.parentOperationId.value || value.child.operationId.value!=publication.childOperationId.value ||
            value.parent.call.callId!=publication.parentCallId || value.child.call.callId!=publication.childCallId ||
            value.parent.operationPlan.bindingDigest!=publication.parentPlanDigest || value.child.operationPlan.bindingDigest!=publication.childPlanDigest ||
            value.approval.argumentHash!=publication.approvalArgumentHash){
            return livePolicyPreparationError("tool.live_publication_context_changed")}
        match(validateOwnedExecutionPendingShape(context,value)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validateDecisionPolicy(context,child.call,child.operationPlan,decision)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validateOwnedExecutionPending(context,value)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(!value.claim()){return livePolicyPreparationError("tool.live_owned_claim_changed")}
        let approved=match(decision){case ApprovalDecision.Approve | ApprovalDecision.ApproveSession=>true;case _=>false}
        let rejected:?AgentError=if(approved){None<AgentError>}else{Some(livePolicyChildRejectionError(child.call,decision))}
        match(recordOwnedRuntimeChildApprovalWithRejectionError(parent.source.operationRoot.getOrThrow(),parent.operationId,
            child.operationId,context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,child.operationPlan,
            child.source.requestKey,child.call.callId,value.approval,"approval-"+child.operationId.value,
            CapabilitySet(values:child.operationPlan.requiredCapabilities),approved,approvalDecisionSourceName(decisionSource),None,
            {=>livePolicyPendingGuard(context)},rejected)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validatePreparedSourceContext(context,child.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(decision){case ApprovalDecision.ApproveSession=>
            match(copiedPermissionGrant204(context,context.sessionId,child.operationPlan.approvalMetadata.grantScope)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};case _=>()}
        match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let selected:?PreparedToolInvocation=if(approved){Some(preparedWithAuthorization(child,PreparedAuthorization.Approved))}else{None<PreparedToolInvocation>}
        let control=match(preparedPhaseControl(context,parent,Some(value),executor,phase.inputCustody(),selected)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
        let returned:Result<Unit>=try{
            match(control.enterPreparedInputMode(selected)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(executor.resumePreparedInput(context,parent,if(approved){selected.getOrThrow()}else{child},decision,control,phase.inputCustody())){
                case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>control.preparedInputActionAcknowledged()}
        }finally{control.close()}
        match(returned){case Result.Err(error)=>return settlement.retainFailure(control,error);case Result.Ok(_)=>()}
        match(control.preparedControlFieldsWitness()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        // This raw proof will be removed by the private holder after THIS
        // entire helper returns. No physical close/refund is performed here.
        value.finishClaim()
    }

    private func ownedExecutionControlForExecutor(context:ToolInvocationContext,parent:PreparedToolInvocation,
        previous:?OwnedToolExecutionContinuation,executor:OwnedToolExecutor,
        resumed!:?PreparedToolInvocation=None):Result<OwnedToolExecutionControl>{
        match(executor as OwnedPreparedReferenceExecutor){case None=>
            return Result.Ok(ownedExecutionControl(context,parent,previous,resumed:resumed))
            case Some(actual)=>
                let custody=match(actual.preparedReferenceCustody(context,parent)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                match(previous){case Some(value)=>if(!value.sameCustody(custody)){
                    return livePolicyPreparationError<OwnedToolExecutionControl>("tool.prepared_reference_custody_changed")};case None=>()}
                let debt=match(retainOwnedKernelPreparedReferenceDebt(custody,parent,resumed)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                Result.Ok(ownedExecutionControl(context,parent,previous,resumed:resumed,referenceDebt:Some(debt)))
        }
    }

    private func ownedExecutionControl(context:ToolInvocationContext,parent:PreparedToolInvocation,
        previous:?OwnedToolExecutionContinuation,resumed!:?PreparedToolInvocation=None,
        referenceDebt!:?OwnedKernelPreparedReferenceDebt=None<OwnedKernelPreparedReferenceDebt>):OwnedToolExecutionControl{
        let resources=OwnedRetainedInvocationResources()
        OwnedToolExecutionControl(resumed,{=>
            match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>Result.Err(error)
                case Result.Ok(_)=>validateLivePreparedCurrent(context,parent)}},
            {childContext,call,key=>if(isManagedChannelOwnedParentPlan(parent.operationPlan)){prepareManagedChannelOwnedChild(context,childContext,call,parent,key)}else{prepareLivePolicyStreamingChild(context,childContext,call,parent,key)}},
            {child,custody=>
                match(previous){case Some(value)=>if(!value.sameCustody(custody)){
                    return livePolicyPreparationError<OwnedToolExecutionContinuation>("tool.live_continuation_custody_changed")};case None=>()}
                if(child.approval.isNone()){return livePolicyPreparationError<OwnedToolExecutionContinuation>("tool.live_pending_approval_missing")}
                let pending=OwnedToolExecutionContinuation(parent,child,child.approval.getOrThrow(),custody)
                match(validateOwnedExecutionPending(context,pending)){
                    case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>Result.Ok(pending)}},
            {childContext,child=>executeOwnedChildPrepared(context,childContext,parent,child)},terminalParent:Some(parent),retainedResources:Some(resources),
            executeRetained:Some({childContext,child,custody=>
                match(previous){case Some(value)=>if(!value.sameCustody(custody)){
                    return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"tool.retained_custody_changed",
                        "retained child must borrow the same actual claimed Session"))};case None=>()}
                let request=OwnedRetainedChildRequest(parent,custody);resources.admit(request)
                var returned:?Result<ToolInvocationResult>=Some(executeOwnedChildPrepared(context,childContext,parent,child,retainedRequest:Some(request)))
                match(returned.getOrThrow()){case Result.Err(error)=>return Result.Err(error);case _=>()}
                // No second Kernel ToolResult handle escapes this adapter.
                returned=None<Result<ToolInvocationResult>>;request.take()}),referenceDebt:referenceDebt)
    }

    private func acceptOwnedExecutionProgress(context:ToolInvocationContext,parent:PreparedToolInvocation,
        returned:Result<OwnedToolExecutionProgress>,terminalControl!:?OwnedToolExecutionControl=None<OwnedToolExecutionControl>):Result<OwnedToolPipelineProgress>{
        match(returned){
            case Result.Err(error)=>
                match(terminalControl){case Some(control)=>match(control.retainedFailure()){
                    case Some(resources)=>return Result.Ok(OwnedToolPipelineProgress.FailedRetained(resources,error));case None=>()}
                    case None=>()}
                Result.Err(error)
            case Result.Ok(OwnedToolExecutionProgress.Waiting(value))=>
                if(!refEq(value.parent,parent)){return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_pending_parent_changed")}
                match(captureOwnedExecutionPublication(context,value)){
                    case Result.Err(error)=>Result.Err(error);case Result.Ok(actual)=>Result.Ok(OwnedToolPipelineProgress.Waiting(actual))}
            case Result.Ok(OwnedToolExecutionProgress.Terminal(value))=>
                match(value.dataOwner as AcknowledgedOperationTerminalDataOwner){case Some(actual)=>
                    return acceptAcknowledgedOwnedTerminal(context,parent,value,actual,terminalControl)
                    case None=>()}
                let output=value.result
                var transferred=false
                try{
                    let control=match(terminalControl){case Some(actual)=>actual
                        case None=>return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_terminal_capture_missing")}
                    if(!control.ownsTerminal(value,parent)){
                        return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_terminal_capture_changed")}
                    match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(verifyOwnedRuntimeOwnedParentTerminal(parent.source.operationRoot.getOrThrow(),parent.operationId,
                        context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,parent.approval,output,
                        value.dataOwner,{=>livePolicyPendingGuard(context)})){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    transferred=true
                    Result.Ok(OwnedToolPipelineProgress.Completed(Result.Ok(ToolInvocationResult.Completed(output))))
                }finally{if(!transferred){output.releasePayload()}}
            case Result.Ok(OwnedToolExecutionProgress.Completed(result))=>
                if(isManagedChannelOwnedParentPlan(parent.operationPlan)){
                    match(result){case Result.Ok(ToolInvocationResult.Completed(value))=>value.releasePayload();case _=>()}
                    return livePolicyPreparationError<OwnedToolPipelineProgress>("managed_channel.actual_terminal_capture_required")}
                let output=match(result){case Result.Ok(ToolInvocationResult.Completed(value))=>value
                    case Result.Err(error)=>return Result.Err(error)
                    case _=>return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_terminal_shape_invalid")}
                var transferred=false
                try{
                    if(output.callId!=parent.call.callId || output.receiptId!=parent.operationId.value || output.payloadLease.isNone()){
                        return livePolicyPreparationError<OwnedToolPipelineProgress>("tool.live_terminal_output_owner_missing")}
                    match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(verifyOwnedRuntimeParentTerminal(parent.source.operationRoot.getOrThrow(),parent.operationId,
                        context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,output,{=>livePolicyPendingGuard(context)})){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    transferred=true;Result.Ok(OwnedToolPipelineProgress.Completed(result))
                }finally{if(!transferred){output.releasePayload()}}
        }
    }

    private func acceptAcknowledgedOwnedTerminal(context:ToolInvocationContext,parent:PreparedToolInvocation,
        value:OwnedToolTerminalCompletion,owner:AcknowledgedOperationTerminalDataOwner,
        terminalControl:?OwnedToolExecutionControl):Result<OwnedToolPipelineProgress>{
        let verified:Result<Unit>=try{
            let control=match(terminalControl){case Some(actual)=>actual
                case None=>return failedAcknowledgedOwnedTerminal(value,owner,AgentError(AgentErrorKind.RecoveryRequired,
                    "tool.live_terminal_capture_missing","actual terminal capture is missing"))}
            if(!control.ownsTerminal(value,parent)){
                return failedAcknowledgedOwnedTerminal(value,owner,AgentError(AgentErrorKind.RecoveryRequired,
                    "tool.live_terminal_capture_changed","actual terminal capture changed"))}
            match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>Result<Unit>.Err(error)
                case Result.Ok(_)=>match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>Result<Unit>.Err(error)
                    case Result.Ok(_)=>match(verifyOwnedRuntimeOwnedParentTerminal(parent.source.operationRoot.getOrThrow(),parent.operationId,
                        context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,parent.approval,value.result,
                        value.dataOwner,{=>livePolicyPendingGuard(context)})){
                        case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>
                            match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>Result<Unit>.Err(error)
                                case Result.Ok(_)=>validateLivePreparedCurrent(context,parent)}}}}
        }catch(_:Exception){retainedOutputError("tool.retained_terminal_verification_failed")}
        match(verified){case Result.Err(error)=>failedAcknowledgedOwnedTerminal(value,owner,error)
            case Result.Ok(_)=>Result.Ok(OwnedToolPipelineProgress.Retained(OwnedToolRetainedParentExecution(value.result,owner)))}
    }
    private func failedAcknowledgedOwnedTerminal(value:OwnedToolTerminalCompletion,
        owner:AcknowledgedOperationTerminalDataOwner,error:AgentError):Result<OwnedToolPipelineProgress>{
        let resource=OwnedRetainedOutputState(value.result,owner)
        Result.Ok(OwnedToolPipelineProgress.FailedRetained(OwnedToolRetainedFailureExecution([resource]),error))
    }

    private func executeOwnedChildPrepared(parentContext:ToolInvocationContext,context:ToolInvocationContext,
        parent:PreparedToolInvocation,child:PreparedToolInvocation,
        retainedRequest!:?OwnedRetainedChildRequest=None<OwnedRetainedChildRequest>):Result<ToolInvocationResult>{
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<ToolInvocationResult> = registrationConsumerBody204<Result<ToolInvocationResult>>({ =>

        if(child.authorization==PreparedAuthorization.ApprovalRequired || child.authorization==PreparedAuthorization.ParentIntent ||
            child.source.kind!=PreparedInvocationSourceKind.Derived || child.source.parentOperationId.isNone() ||
            child.source.parentOperationId.getOrThrow().value!=parent.operationId.value || child.source.operationRoot.isNone() ||
            !ownedRuntimeChildAllowed(parent.operationPlan,child.operationPlan) ||
            child.source.requestKey!=ownedRuntimeRequestKey(parent.call.callId,child.operationPlan)){
            return livePolicyPreparationError<ToolInvocationResult>("tool.live_child_not_authorized")}
        let sameRoot=match((parent.source.operationRoot.getOrThrow(),child.source.operationRoot.getOrThrow())){
            case (OperationRootSource.Committed(left),OperationRootSource.Committed(right))=>refEq(left,right)
            case (OperationRootSource.Direct(left),OperationRootSource.Direct(right))=>refEq(left,right)
            case _=>false}
        if(!sameRoot || child.source.parentCallId!=parent.call.callId){
            return livePolicyPreparationError<ToolInvocationResult>("tool.live_child_actual_root_changed")}
        match(validatePreparedSourceContext(parentContext,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validatePreparedSourceContext(context,child.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validateLivePreparedCurrent(context,child)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let registration=match(registrationForRun(context,child.call.name,allowHostService:true)){
            case Some(value)=>value;case None=>return livePolicyPreparationError<ToolInvocationResult>("tool.live_child_registration_missing")}
        let effect:()->ToolExecutionOutcome=if(retainedRequest.isSome()){
            let request=retainedRequest.getOrThrow()
            if(!refEq(request.parent,parent)){return livePolicyPreparationError<ToolInvocationResult>("tool.retained_parent_changed")}
            if(isManagedChannelOwnedParentPlan(parent.operationPlan)){
                if((registration.executor as ManagedChannelOwnedEffectExecutor).isNone()){
                    return livePolicyPreparationError<ToolInvocationResult>("managed_channel.child_executor_missing")}
            }else if((registration.executor as OwnedToolEffectExecutor).isNone()){
                return livePolicyPreparationError<ToolInvocationResult>("tool.live_child_executor_missing")}
            let actual=match(registration.executor as RetainedOwnedToolEffectExecutor){case Some(value)=>value
                case None=>return livePolicyPreparationError<ToolInvocationResult>("tool.retained_child_executor_missing")}
            {=>request.execute(actual,context,parent,child)}
        }else if(isManagedChannelOwnedParentPlan(parent.operationPlan)){
            let actual=match(registration.executor as ManagedChannelOwnedEffectExecutor){case Some(value)=>value
                case None=>return livePolicyPreparationError<ToolInvocationResult>("managed_channel.child_executor_missing")}
            {=>actual.executeManagedChannelEffect(context,child)}
        }else{
            let actual=match(registration.executor as OwnedToolEffectExecutor){case Some(value)=>value
                case None=>return livePolicyPreparationError<ToolInvocationResult>("tool.live_child_executor_missing")}
            {=>actual.executeLiveEffect(context,child)}
        }
        if(!catalog.beginExecution(registration,child.operationId,context.runId,ThreadId(context.sessionId.value))){
            return livePolicyPreparationError<ToolInvocationResult>("tool.live_child_registration_revoked")}
        try{
            let root=parent.source.operationRoot.getOrThrow()
            match(withExecutionHandoff(registration, context, child, { => markOwnedRuntimeChildExecuting(root,parent.operationId,child.operationId,context.runId,
                ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,child.operationPlan,child.source.requestKey,
                child.call.callId,child.approval,agentUtcMillis(),child.authorization==PreparedAuthorization.Approved,{=>livePolicyPendingGuard(context)}) })){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(validatePreparedSourceContext(context,child.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(withExecutionHandoff(registration, context, child, { => markOwnedRuntimeChildHandoff(root,parent.operationId,child.operationId,context.runId,
                ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,child.operationPlan,child.source.requestKey,
                child.call.callId,child.approval,agentUtcMillis(),{=>livePolicyPendingGuard(context)}) })){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(validateLivePreparedCurrent(context,child)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(catalog.executionWasRevoked(registration)){
                return livePolicyPreparationError<ToolInvocationResult>("tool.live_child_registration_revoked")}
            let returned=context.executeDerivedFrame(child,{=>effect().result})
            match(returned){case Result.Err(error)=>Result.Err(error);case Result.Ok(output)=>
                var transferred=false
                match(retainedRequest){case Some(request)=>request.retainUnverified(output);case None=>()}
                try{
                    if(output.callId!=child.call.callId || output.receiptId!=child.operationId.value || output.payloadLease.isNone()){
                        return livePolicyPreparationError<ToolInvocationResult>("tool.live_child_output_owner_missing")}
                    match(validatePreparedSourceContext(context,child.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(verifyOwnedRuntimeChildTerminal(root,parent.operationId,child.operationId,context.runId,
                        ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,child.operationPlan,child.source.requestKey,
                        child.call.callId,child.approval,output,{=>livePolicyPendingGuard(context)},registration.executor)){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(validatePreparedSourceContext(context,child.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(retainedRequest){case Some(request)=>
                        match(request.capture(output)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        case None=>()}
                    transferred=true;Result.Ok(ToolInvocationResult.Completed(output))
                }finally{if(!transferred && retainedRequest.isNone()){output.releasePayload()}}}
        }finally{catalog.finishExecution(registration,child.operationId)}
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }
    // Independent v2 path. Policy preparation is ordinary and the precise
    // child is durably admitted only by the NEW actual-source Store method.
    // No old ParentIntent, executePrepared or admitDerived branch is widened.
    public func requiresOwnedApprovalOwner(context:ToolInvocationContext,operationId:OperationId):Result<Bool>{
        match(validateToolSnapshotThread(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(livePolicyPendingGuard(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(operations.requiresOwnedPluginLivePolicyApprovalOwner(operationId,context.runId)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(true)=>return Result.Ok(true);case Result.Ok(false)=>()}
        operations.requiresOwnedManagedChannelApprovalOwner(operationId,context.runId)
    }
    public func persistOwnedPrepared(context:ToolInvocationContext,parent:PreparedToolInvocation):Result<Unit>{
        if(context.trustedControl || !ownedRuntimeParentPlan(parent.operationPlan) ||
            parent.source.kind==PreparedInvocationSourceKind.Derived || parent.source.operationRoot.isNone() ||
            (parent.authorization!=PreparedAuthorization.ApprovalRequired && parent.authorization!=PreparedAuthorization.StaticPolicy && parent.authorization!=PreparedAuthorization.SessionGrant)){
            return livePolicyPreparationError("tool.live_parent_preparation_source_invalid")}
        match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let pending:?ApprovalRequest=if(parent.authorization==PreparedAuthorization.ApprovalRequired){parent.approval}else{None}
        if(parent.authorization==PreparedAuthorization.ApprovalRequired && pending.isNone()){
            return livePolicyPreparationError("tool.live_parent_approval_missing")}
        let persisted=prepareOwnedRuntimeParent(parent.source.operationRoot.getOrThrow(),parent.operationId,
            context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,pending,{=>livePolicyPendingGuard(context)})
        match(persisted){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        validatePreparedSourceContext(context,parent.source)
    }
    // Waiting-Run preflight is routing/current policy only. It deliberately
    // does NOT claim the running-only SQL Source or paid input proof. Actual
    // resume repeats those facts before recording any decision/effect.
    public func validateRetainedOwnedParentDecision(context:ToolInvocationContext,parent:PreparedToolInvocation,
        approval:ApprovalRequest,decision:ApprovalDecision):Result<Unit>{
        if(!ownedRuntimeParentPlan(parent.operationPlan) || parent.source.kind==PreparedInvocationSourceKind.Derived ||
            parent.authorization!=PreparedAuthorization.ApprovalRequired || parent.approval.isNone() ||
            !sameRetainedOwnedApproval(parent.approval.getOrThrow(),approval) || approval.operationId.value!=parent.operationId.value ||
            approval.callId!=parent.call.callId || approval.toolName!=parent.call.name || approval.sessionId!=context.sessionId.value ||
            approval.argumentHash!=requiredCapabilitiesArgumentHash(parent.call,parent.operationPlan.requiredCapabilities)){
            return livePolicyPreparationError("tool.live_parent_retained_approval_changed")}
        match(validateLivePreparedCurrent(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        validateDecisionPolicy(context,parent.call,parent.operationPlan,decision)
    }
    public func validateRetainedOwnedExecutionDecision(context:ToolInvocationContext,publication:OwnedToolExecutionPublication,
        approval:ApprovalRequest,decision:ApprovalDecision):Result<Unit>{
        match(publication.preparedPhase){case Some(phase)=>
            let proof=match(phase.pendingProof()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(!publication.matchesContext(context) || !proof.awaitingDecision() || !sameRetainedOwnedApproval(proof.approval,approval)){
                return livePolicyPreparationError("tool.live_retained_approval_changed")}
            match(validateOwnedExecutionPendingShape(context,proof)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            return validateDecisionPolicy(context,proof.child.call,proof.child.operationPlan,decision)
            case None=>()}
        if(!publication.matchesContext(context) || !publication.continuation.awaitingDecision() || !sameRetainedOwnedApproval(publication.continuation.approval,approval)){
            return livePolicyPreparationError("tool.live_retained_approval_changed")}
        match(validateOwnedExecutionPendingShape(context,publication.continuation)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        validateDecisionPolicy(context,publication.continuation.child.call,publication.continuation.child.operationPlan,decision)
    }
    private func validateLivePreparedCurrent(context:ToolInvocationContext,prepared:PreparedToolInvocation):Result<Unit>{
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        if(isManagedChannelOwnedParentPlan(prepared.borrowOperationPlanFrame204()) || isManagedChannelOwnedChildPlan(prepared.borrowOperationPlanFrame204())){
            return validateManagedChannelOwnedCurrent(context,prepared)}
        match(validateToolSnapshotThread(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(livePolicyPendingGuard(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let source=prepared.source
        if(context.trustedControl || source.runId.value!=context.runId.value || source.sessionId.value!=context.sessionId.value ||
            source.epoch!=context.epoch || source.operationRoot.isNone() ||
            (!isPluginLivePolicyParentPlan(prepared.borrowOperationPlanFrame204()) && !isPluginLivePolicyStreamingChildPlan(prepared.borrowOperationPlanFrame204()))){
            return livePolicyPreparationError("tool.live_prepared_context_changed")}
        let binding=prepared.borrowOperationPlanFrame204().canonicalArguments.field(if(isPluginLivePolicyParentPlan(prepared.borrowOperationPlanFrame204())){"host_plan"}else{"binding"}).getOrThrow()
        let actual=if(isPluginLivePolicyParentPlan(prepared.borrowOperationPlanFrame204())){binding.field("binding").getOrThrow()}else{binding}
        if(httpIntentText(actual,"run_id")!=context.runId.value || httpIntentText(actual,"thread_id")!=context.sessionId.value ||
            actual.field("epoch").getOrThrow().asNumberText()!=context.epoch.toString()){
            return livePolicyPreparationError("tool.live_prepared_enclosure_changed")}
        let registration=match(registrationForRun(context,prepared.call.name,allowHostService:hostServiceSourceAllowed(source,prepared.call.name))){
            case Some(value)=>value;case None=>return livePolicyPreparationError("tool.live_prepared_registration_missing")}
        // Approval preflight revalidates the frozen invocation, never Native preparation.
        // A waiting Run cannot stage a fresh payload or adapt its approved plan.
        let call=ToolCall(prepared.call.callId,prepared.call.name,prepared.borrowOperationPlanFrame204().canonicalArguments)
        let current=normalizedToolOperationPlan(context,call,registration.descriptor.resolved(call),contextReadFacts:prepared.borrowOperationPlanFrame204().contextReadFacts)
        if(!sameNormalizedOperationPlan(current,prepared.borrowOperationPlanFrame204())){return livePolicyPreparationError("tool.live_prepared_descriptor_changed")}
        match(missingRequiredCapability(context,prepared.borrowOperationPlanFrame204().requiredCapabilities)){
            case Some(_)=>return livePolicyPreparationError("tool.live_prepared_capability_revoked");case None=>()}
        Result.Ok(())
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func prepareLivePolicyStreamingChild(parentContext:ToolInvocationContext,context:ToolInvocationContext,
        call:ToolCall,parent:PreparedToolInvocation,requestKey:String):Result<ToolPreparation>{
        if(context.trustedControl || parent.source.kind==PreparedInvocationSourceKind.Derived ||
            parent.source.operationRoot.isNone() || parent.authorization==PreparedAuthorization.ApprovalRequired ||
            !isPluginLivePolicyParentPlan(parent.operationPlan) || call.name!=HOST_PLUGIN_LIVE_EFFECT_TOOL ||
            !pluginLivePolicyStreamingChildValueValid(call.arguments) || context.runId.value!=parent.source.runId.value ||
            context.sessionId.value!=parent.source.sessionId.value || context.epoch!=parent.source.epoch){
            return livePolicyPreparationError<ToolPreparation>("tool.live_policy_parent_invalid")}
        let sequence=call.arguments.field("sequence").getOrThrow().asNumberText()
        if(call.callId!=parent.call.callId+":live:"+sequence || requestKey!="live-policy:"+parent.call.callId+":"+sequence){
            return livePolicyPreparationError<ToolPreparation>("tool.live_policy_child_identity_invalid")}
        match(validatePreparedSourceContext(parentContext,parent.source)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(livePolicyPendingGuard(parentContext)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let source=PreparedInvocationSource(PreparedInvocationSourceKind.Derived,context,
            operationRoot:parent.source.operationRoot,parentOperationId:Some(parent.operationId),requestKey:requestKey,
            parentCallId:parent.call.callId,managedJobCeiling:parent.source.managedJobCeiling)
        match(validatePreparedSourceContext(context,source)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let preparation=match(prepareResolved(context,call,None,source,parentIntentPlan:None)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let selected:?PreparedToolInvocation=match(preparation){case ToolPreparation.Ready(value)=>Some(value)
            case ToolPreparation.NeedsApproval(value,_)=>Some(value);case _=>None}
        match(selected){case Some(value)=>
            if(value.authorization==PreparedAuthorization.ParentIntent ||
                !pluginLivePolicyStreamingChildWithinCeiling(parent.operationPlan,value.operationPlan) ||
                requestKey!=pluginLivePolicyStreamingRequestKey(parent.call.callId,value.operationPlan)){
                return livePolicyPreparationError<ToolPreparation>("tool.live_policy_child_scope_changed")}
            match(validatePreparedSourceContext(parentContext,parent.source)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(validatePreparedSourceContext(context,value.source)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let pending:?ApprovalRequest=match(preparation){case ToolPreparation.NeedsApproval(_,approval)=>Some(approval);case _=>None}
            // The exact waiting state and approval tuple are written with its
            // whole Source/current/read-input/receipt-prefix proof in one TX.
            match(operations.preparePluginLivePolicyInvocation(parent.source.operationRoot.getOrThrow(),parent.operationId,
                value.operationId,context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,
                value.operationPlan,requestKey,ToolCall(value.call.callId,value.call.name,value.operationPlan.canonicalArguments),
                pending,{=>livePolicyPendingGuard(context)})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>
                    if(actual.value!=value.operationId.value){return livePolicyPreparationError<ToolPreparation>("tool.live_policy_child_identity_changed")}}
            // Source and current contribution checks occur OUTSIDE the SQL
            // lock, again before the Host can release or publish its custody.
            match(validatePreparedSourceContext(parentContext,parent.source)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(livePolicyPendingGuard(context)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            case None=>()}
        Result.Ok(preparation)
    }

    // No Host/registry locks are acquired inside a SQL guard. Actual current
    // descriptors/configuration and sealed Source are checked outside it.
    private func livePolicyPendingGuard(context:ToolInvocationContext):Result<Unit>{
        if(context.cancellation.isCancelled()){
            return Result.Err(AgentError(AgentErrorKind.Cancelled,"tool.live_policy_cancelled","live operation was cancelled"))}
        if(context.budget.deadlineMillis>0 && agentUtcMillis()>=context.budget.deadlineMillis){
            return Result.Err(AgentError(AgentErrorKind.Timeout,"tool.live_policy_deadline","live operation deadline expired"))}
        Result.Ok(())
    }

    private func livePolicyPreparationError<T>(code:String):Result<T>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,code,
            "independent live effect preparation lost its exact actual parent or child scope"))}

    // Host bridges select the parent and request key after validating their
    // bounded wire request. Neither field is accepted as plugin authority.
    // This prepares a plan only; OperationRuntime remains the admission owner.
    public func prepareDerived(
        context: ToolInvocationContext,
        call: ToolCall,
        parent: PreparedToolInvocation,
        requestKey: String
    ): Result<ToolPreparation> {
        if ((parent.source.kind == PreparedInvocationSourceKind.Derived &&
                (!isReadonlyDelegatedChildPlan(parent.operationPlan) || call.name != HOST_READ_VIEW_TOOL)) ||
            parent.source.operationRoot.isNone() || requestKey.trimAscii() == "" ||
            context.trustedControl) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "tool.derived_source_invalid",
                "derived preparation requires a sealed canonical root and an unprivileged child context"
            ))
        }
        match (validatePreparedSourceContext(context, parent.source)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        prepareResolved(context, call, None, PreparedInvocationSource(
            PreparedInvocationSourceKind.Derived, context,
            operationRoot: parent.source.operationRoot,
            parentOperationId: Some(parent.operationId),
            requestKey: requestKey, parentCallId: parent.call.callId,
            managedJobCeiling: parent.source.managedJobCeiling
        ), parentIntentPlan: if (parent.authorization == PreparedAuthorization.ApprovalRequired) {
            None
        } else { Some(parent.operationPlan) })
    }

    // A trusted host broker retains the actual root context while its child
    // narrows capabilities. Validate the Direct parent in that full scope;
    // the new Derived source still passes its own unchanged child validator.
    public func prepareDerived(
        parentContext: ToolInvocationContext,
        context: ToolInvocationContext,
        call: ToolCall,
        parent: PreparedToolInvocation,
        requestKey: String
    ): Result<ToolPreparation> {
        if ((parent.source.kind == PreparedInvocationSourceKind.Derived &&
                (!isReadonlyDelegatedChildPlan(parent.operationPlan) || call.name != HOST_READ_VIEW_TOOL)) ||
            parent.source.operationRoot.isNone() || requestKey.trimAscii() == "" ||
            context.trustedControl) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "tool.derived_source_invalid",
                "derived preparation requires a sealed canonical root and an unprivileged child context"
            ))
        }
        match (validatePreparedSourceContext(parentContext, parent.source)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        if (context.runId.value != parent.source.runId.value ||
            context.sessionId.value != parent.source.sessionId.value ||
            context.epoch != parent.source.epoch) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.prepared_source_context_changed",
                "prepared invocation source belongs to another run, session, or epoch"
            ))
        }
        let source = PreparedInvocationSource(
            PreparedInvocationSourceKind.Derived, context,
            operationRoot: parent.source.operationRoot,
            parentOperationId: Some(parent.operationId),
            requestKey: requestKey, parentCallId: parent.call.callId,
            managedJobCeiling: parent.source.managedJobCeiling
        )
        match (validatePreparedSourceContext(context, source)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        prepareResolved(context, call, None, source,
            parentIntentPlan: if (parent.authorization == PreparedAuthorization.ApprovalRequired) {
                None
            } else { Some(parent.operationPlan) })
    }

    // The sealed source supplies every origin argument to the existing
    // durable admission authority. Its return value preserves request replay.
    public func admitDerived(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<OperationId> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<OperationId> = registrationConsumerBody204<Result<OperationId>>({ =>

        let source = prepared.source
        if (source.kind != PreparedInvocationSourceKind.Derived ||
            source.operationRoot.isNone() || source.parentOperationId.isNone() ||
            (prepared.borrowOperationPlanFrame204().effectClass != OperationEffectClass.ReadOnly &&
                !isExactServiceChildPlan(prepared.borrowOperationPlanFrame204())) ||
            context.trustedControl) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "tool.derived_source_invalid",
                "derived admission requires a host-prepared read-only or exactly frozen service child source"
            ))
        }
        match (validatePreparedSourceContext(context, source)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        operations.prepareDerivedInvocation(
            prepared.operationId, source.parentOperationId.getOrThrow(),
            source.runId, source.operationRoot.getOrThrow(), source.requestKey,
            ToolCall(prepared.call.callId, prepared.call.name, prepared.borrowOperationPlanFrame204().canonicalArguments),
            prepared.borrowOperationPlanFrame204()
        )
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    // Not called from a Native DTO decoder. The eventual actual registered
    // live executor calls this private method after retaining its real Host
    // Session in the existing collector. No ordinary executePrepared branch
    // or error-as-Waiting translation is introduced here.
    private func captureOwnedExecutionPublication(context:ToolInvocationContext,
        value:OwnedToolExecutionContinuation):Result<OwnedToolExecutionPublication>{
        match(validateOwnedExecutionPending(context,value)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(value.releaseForPublication()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        // Revalidate AFTER actual FD/worker/loan cleanup and before publishing.
        // Failure retains value in the original Host collector; no ACK or
        // destructor is fabricated and no effect or child is rerun here.
        match(validateOwnedExecutionPending(context,value)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(OwnedToolExecutionPublication(context,value))
    }

    public func validateOwnedExecutionPublication(context:ToolInvocationContext,
        value:OwnedToolExecutionPublication):Result<Unit>{
        match(value.preparedPhase){case Some(phase)=>
            if(!value.matchesContext(context)){return livePolicyPreparationError("tool.live_publication_context_changed")}
            match(phase.pendingProof()){case Result.Err(error)=>return Result.Err(error)
                case Result.Ok(proof)=>return validateOwnedExecutionPending(context,proof)}
            case None=>()}
        if(!value.matchesContext(context)){
            return Result.Err(AgentError(AgentErrorKind.Conflict,"tool.live_publication_context_changed",
                "pending execution does not match its same original context"))}
        validateOwnedExecutionPending(context,value.continuation)
    }

    private func validateOwnedExecutionPendingShape(context:ToolInvocationContext,
        value:OwnedToolExecutionContinuation):Result<Unit>{
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        let parent=value.parent;let child=value.child;let approval=value.approval
        if(context.trustedControl || context.cancellation.isCancelled() ||
            (context.budget.deadlineMillis>0 && agentUtcMillis()>=context.budget.deadlineMillis) ||
            parent.source.kind==PreparedInvocationSourceKind.Derived || child.source.kind!=PreparedInvocationSourceKind.Derived ||
            parent.source.operationRoot.isNone() || child.source.operationRoot.isNone() || child.source.parentOperationId.isNone() ||
            child.source.parentOperationId.getOrThrow().value!=parent.operationId.value || child.source.parentCallId!=parent.call.callId ||
            child.authorization!=PreparedAuthorization.ApprovalRequired || child.approval.isNone() ||
            !refEq(child.approval.getOrThrow(),approval) || approval.operationId.value!=child.operationId.value ||
            approval.callId!=child.call.callId || approval.toolName!=child.call.name || approval.sessionId!=context.sessionId.value ||
            approval.argumentHash!=requiredCapabilitiesArgumentHash(ToolCall(child.call.callId,child.call.name,
                child.operationPlan.canonicalArguments),child.operationPlan.requiredCapabilities)){
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"tool.live_pending_source_invalid",
                "pending child requires the actual prepared parent and exact approval tuple"))}
        let sameRoot=match((parent.source.operationRoot.getOrThrow(),child.source.operationRoot.getOrThrow())){
            case (OperationRootSource.Committed(left),OperationRootSource.Committed(right))=>refEq(left,right)
            case (OperationRootSource.Direct(left),OperationRootSource.Direct(right))=>refEq(left,right)
            case _=>false}
        if(!sameRoot){return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"tool.live_pending_root_changed",
            "pending child lost its same original sealed root source"))}
        match(validateLivePreparedCurrent(context,parent)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validateLivePreparedCurrent(context,child)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(!ownedRuntimeChildAllowed(parent.operationPlan,child.operationPlan) ||
            child.source.requestKey!=ownedRuntimeRequestKey(parent.call.callId,child.operationPlan) ||
            child.call.callId!=ownedRuntimeChildCallId(parent.call.callId,child.operationPlan)){
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"tool.live_pending_ceiling_changed",
                "pending child lost its exact new-family ceiling and contiguous own identity"))}
        let binding=parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        if(httpIntentText(binding,"run_id")!=context.runId.value || httpIntentText(binding,if(isManagedChannelOwnedParentPlan(parent.operationPlan)){"target_thread_id"}else{"thread_id"})!=context.sessionId.value ||
            binding.field("epoch").getOrThrow().asNumberText()!=context.epoch.toString()){
            return Result.Err(AgentError(AgentErrorKind.Conflict,"tool.live_pending_enclosure_changed",
                "pending execution belongs to another actual run, thread or epoch"))}
        for(prepared in [parent,child]){
            let registration=match(registrationForRun(context,prepared.call.name,
                allowHostService:prepared.source.kind==PreparedInvocationSourceKind.Derived)){
                case Some(actual)=>actual
                case None=>return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"tool.live_pending_registration_missing",
                    "pending execution lost its current registered contribution"))}
            let canonicalCall=ToolCall(prepared.call.callId,prepared.call.name,prepared.borrowOperationPlanFrame204().canonicalArguments)
            let resolved=registration.descriptor.resolved(canonicalCall)
            let current=normalizedToolOperationPlan(context,canonicalCall,resolved,contextReadFacts:prepared.borrowOperationPlanFrame204().contextReadFacts)
            if(!sameNormalizedOperationPlan(current,prepared.borrowOperationPlanFrame204())){
                return Result.Err(AgentError(AgentErrorKind.Conflict,"tool.live_pending_descriptor_changed",
                    "pending execution changed its current frozen implementation or scope"))}
            match(missingRequiredCapability(context,prepared.borrowOperationPlanFrame204().requiredCapabilities)){
                case Some(_)=>return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"tool.live_pending_capability_revoked",
                    "pending execution no longer has its actual current capability ceiling"))
                case None=>()}
        }
        // These shape/current registration comparisons grant nothing. The
        // new Store port remains default-closed until its full paid canonical
        // Source/current lane/handoff/approval/ledger proof is implemented.
        Result.Ok(())
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }
    private func validateOwnedExecutionPending(context:ToolInvocationContext,
        value:OwnedToolExecutionContinuation):Result<Unit>{
        match(validateOwnedExecutionPendingShape(context,value)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let parent=value.parent;let child=value.child
        match(validatePreparedSourceContext(context,parent.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(validatePreparedSourceContext(context,child.source)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        verifyOwnedRuntimePending(parent.source.operationRoot.getOrThrow(),parent.operationId,child.operationId,
            context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,child.operationPlan,
            child.source.requestKey,child.call.callId,value.approval,{=>livePolicyPendingGuard(context)})
    }

    private func validatePreparedSourceContext(
        context: ToolInvocationContext,
        source: PreparedInvocationSource
    ): Result<Unit> {
        match (validateToolSnapshotThread(context)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        if (source.runId.value != context.runId.value ||
            source.sessionId.value != context.sessionId.value ||
            source.epoch != context.epoch) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.prepared_source_context_changed",
                "prepared invocation source belongs to another run, session, or epoch"
            ))
        }
        match (source.operationRoot) {
            case Some(OperationRootSource.Direct(root)) =>
                match (root.origin) {
                    case DirectCallOrigin.ContextRead(origin) => if (context.trustedControl ||
                        contextReadProjectionDigest(context.contextProjection) != origin.projectionDigest) {
                        return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                            "context.read_view_changed", "read source cannot move to another invocation projection")) }
                    case _ => ()
                }
                match (root.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                if (root.managedJob.isSome()) {
                    let ceiling = match (source.managedJobCeiling) { case Some(value) => value
                        case None => return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "task.managed_job_ceiling_missing", "Task source lost its frozen capability ceiling")) }
                    match (validateManagedJobContext(context, root, ceiling)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                }
                match (root.externalBinding) {
                    case Some(binding) => match (validateExternalInvocationContext(context, binding,
                        root.externalCancellationToken.getOrThrow(), source.kind == PreparedInvocationSourceKind.Derived)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
                    }
                    case None => ()
                }
            case _ => ()
        }
        Result.Ok(())
    }

    private func prepareResolved(
        context: ToolInvocationContext,
        call: ToolCall,
        committedOperationId: ?OperationId,
        source: PreparedInvocationSource,
        parentIntentPlan!: ?NormalizedOperationPlan = None
    ): Result<ToolPreparation> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<ToolPreparation> = registrationConsumerBody204<Result<ToolPreparation>>({ =>

        match (validateToolSnapshotThread(context)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let registration = match (registrationForRun(context, call.name, newPreparation: true,
            allowHostService: hostServiceSourceAllowed(source, call.name))) {
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
        if (registration.descriptor.controlOnly && !context.trustedControl) {
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
        match (validateContextReadInputProjection(call.arguments, source.contextReadFacts)) {
            case Result.Err(error) => return Result.Ok(ToolPreparation.Denied(ToolDenial(call.callId, call.name, error)))
            case Result.Ok(_) => ()
        }
        // The private host fact projection is not part of the plugin's public
        // input schema. It was checked against the actual retained source above.
        let schemaCall = ToolCall(call.callId, call.name, contextReadBusinessInput(call.arguments))
        match (validator.validate(schemaCall, registration.descriptor.definition)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                return Result.Ok(ToolPreparation.Completed(recoverableToolResult(call, error)))
        }
        let canonicalCall = match (registration.descriptor.canonicalizedCall(context, call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Ok(
                ToolPreparation.Completed(recoverableToolResult(call, error))
            )
        }
        let effective = registration.descriptor.resolved(canonicalCall)
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
        let plan = normalizedToolOperationPlan(context, canonicalCall, effective, contextReadFacts: source.contextReadFacts)
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
            preview: plan.canonicalArguments,
            sessionId: context.sessionId.value,
            argumentHash: requiredCapabilitiesArgumentHash(call, requirements),
            riskFlags: riskFlags,
            metadata: metadata,
            decisionSource: ApprovalDecisionSource.HardDeny,
            sessionApprovalAllowed: networkPolicyModeIsDenied(plan.networkPolicy.mode) &&
                metadata.sessionApprovalAllowed
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
            metadata.sessionApprovalAllowed &&
            evaluated.requirement == PermissionRequirement.Confirm &&
            persistedGrantAllows(context, context.sessionId, metadata.grantScope)
        let policyDecision = if (granted) {
            PolicyDecision(
                PermissionRequirement.Safe,
                reason: "approved for this session"
            )
        } else {
            evaluated
        }
        // Narrow an already authorized exact parent intent. Store proves its
        // actual canonical parent, active epoch and durable handoff before any
        // HTTP exchange or channel write. No user approval is fabricated.
        if (policyDecision.requirement != PermissionRequirement.Deny &&
            source.kind == PreparedInvocationSourceKind.Derived && parentIntentPlan.isSome() &&
            source.operationRoot.isSome() && source.parentCallId != "" &&
            ((exactServiceChildAllowed(parentIntentPlan.getOrThrow(), plan) &&
                source.requestKey == exactServiceRequestKey(source.parentCallId, plan)) ||
             (readonlyDelegationChildAllowed(parentIntentPlan.getOrThrow(), plan) &&
                source.requestKey == readonlyDelegationRequestKey(source.parentCallId, call.callId))) &&
            exactServiceChildTargetAllowed(context, source, plan)) {
            return Result.Ok(ToolPreparation.Ready(PreparedToolInvocation(
                ids.nextOperationId(), call, effective.concurrency,
                PreparedAuthorization.ParentIntent, plan, source
            )))
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
                plan,
                decisionSource: if (granted) {
                    ApprovalDecisionSource.SessionGrant
                } else {
                    ApprovalDecisionSource.StaticPolicy
                },
                metadata: Some(metadata),
                requestedOperationId: committedOperationId,
                source: source
            )
            case PermissionRequirement.Confirm => prepareForApproval(
                context,
                call,
                effective,
                metadata,
                plan,
                requestedOperationId: committedOperationId,
                source: source
            )
        }
    
            })
            let outward204 = match (consumerFrame204) { case Some(value) => value.retainPreparedResult204(result204); case None => result204 }
            returnedConsumer204 = true
            outward204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func afterOwnedResultPersisted(context: ToolInvocationContext, toolName: String,
        held: OwnedCanonicalThreadItemAliasCustody): Result<Unit> {
        let view = context.beginInvocationView159()
        try { afterOwnedResultPersistedScope159(view, toolName, held) } finally { view.endInvocationView159() }
    }

    private func afterOwnedResultPersistedScope159(context: ToolInvocationContext, toolName: String,
        held: OwnedCanonicalThreadItemAliasCustody): Result<Unit> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        match (validateToolSnapshotThread(context)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let shape = OwnedPersistedCanonicalResultShape()
        match (held.withItem({ item => shape.read(item) })) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        // Preserve the ordinary hook's existing error-result behavior.
        if (shape.isError) { return Result.Ok(()) }
        let registration = match (registrationForRun(context, toolName)) {
            case Some(value) => value
            case None => return Result.Err(AgentError(AgentErrorKind.Internal,
                "tool.persisted_hook_missing", "persisted tool result has no registered executor",
                fields: [ErrorField("tool", toolName)])) }
        let actual = match (registration.executor as OwnedPersistedToolResultObserver) {
            case Some(value) => value
            case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.persisted_hook_owned_contract_missing", "actual executor has no complete-result alias custody contract")) }
        // The shape borrow ended. Only the concrete typed observer can now
        // borrow or retain fanout custody; ordinary callbacks are not NOPs.
        actual.afterOwnedResultPersisted(context, held)
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func captureDirectPostCanonicalObserver(context: ToolInvocationContext,
        prepared: PreparedToolInvocation): Result<?DirectPostCanonicalObserverCapture> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<?DirectPostCanonicalObserverCapture> = registrationConsumerBody204<Result<?DirectPostCanonicalObserverCapture>>({ =>

        let registration = match (registrationForRun(context, prepared.call.name)) {
            case Some(value) => value; case None => return Result.Ok(None<DirectPostCanonicalObserverCapture>) }
        let observer = match (registration.executor as DirectPostCanonicalToolObserver) {
            case Some(value) => value; case None => return Result.Ok(None<DirectPostCanonicalObserverCapture>) }
        match (validatePreparedSourceContext(context, prepared.source)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (prepared.source.kind != PreparedInvocationSourceKind.Direct || prepared.source.operationRoot.isNone()) {
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.direct_projection_source_missing", "Direct projection requires its actual prepared root")) }
        match (prepared.source.operationRoot) { case Some(OperationRootSource.Direct(source)) =>
            match (source.origin) { case DirectCallOrigin.UserDirect => ()
                case _ => return Result.Ok(None<DirectPostCanonicalObserverCapture>) }
            case _ => return Result.Ok(None<DirectPostCanonicalObserverCapture>) }
        let executor = match (registration.executor as Object) { case Some(value) => value
            case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.direct_projection_executor_not_reference", "Direct observer requires its actual reference executor")) }
        let canonical=ToolCall(prepared.call.callId,prepared.call.name,prepared.borrowOperationPlanFrame204().canonicalArguments)
        let plan = normalizedToolOperationPlan(context, canonical, registration.descriptor.resolved(canonical),
            contextReadFacts: prepared.borrowOperationPlanFrame204().contextReadFacts)
        if (!sameNormalizedOperationPlan(plan, prepared.borrowOperationPlanFrame204())) {
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.direct_projection_plan_changed", "Direct observer differs from the frozen operation plan")) }
        // This public capture exposes real executor/observer references.
        // Its compatibility contract supplies no private alias-return receipt.
        match (hostConsumerForContext204(context)) { case Some(value) => value.holdUnknown204(); case None => () }
        Result.Ok(Some(DirectPostCanonicalObserverCapture(context, prepared, executor, observer)))
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func afterDirectResultPersisted(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        result: ToolResult, captured: DirectPostCanonicalObserverCapture,
        boundary: DirectPostCanonicalProjectionBoundary): Result<Unit> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        captured.consume({ =>
            if (!refEq(context, captured.context) || !refEq(prepared, captured.prepared) ||
                !refEq(context.budget, boundary.budget) || result.isError || result.payloadLease.isNone() ||
                result.callId != prepared.call.callId || result.receiptId != "receipt-" + prepared.operationId.value) {
                return directPostCanonicalObserverFailure("tool.direct_projection_invocation_changed") }
            match (prepared.source.operationRoot) { case Some(OperationRootSource.Direct(source)) =>
                if (!refEq(source, boundary.source)) { return directPostCanonicalObserverFailure("tool.direct_projection_root_changed") }
                case _ => return directPostCanonicalObserverFailure("tool.direct_projection_source_missing") }
            match (validatePreparedSourceContext(context, prepared.source)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let registration = match (registrationForRun(context, prepared.call.name)) {
                case Some(value) => value; case None => return directPostCanonicalObserverFailure("tool.direct_projection_registration_missing") }
            let executor = match (registration.executor as Object) { case Some(value) => value
                case None => return directPostCanonicalObserverFailure("tool.direct_projection_executor_changed") }
            if (!refEq(executor, captured.executor)) { return directPostCanonicalObserverFailure("tool.direct_projection_executor_changed") }
            let call=ToolCall(prepared.call.callId,prepared.call.name,prepared.borrowOperationPlanFrame204().canonicalArguments)
            let plan = normalizedToolOperationPlan(context, call, registration.descriptor.resolved(call),
                contextReadFacts: prepared.borrowOperationPlanFrame204().contextReadFacts)
            if (!sameNormalizedOperationPlan(plan, prepared.borrowOperationPlanFrame204())) {
                return directPostCanonicalObserverFailure("tool.direct_projection_plan_changed") }
            directObserverScope159(captured.observer, context, prepared, result, boundary)
        })
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    // This dispatcher keeps the old callback/result path explicit. A paid
    // observer supplies one owned outcome; None invokes the original path
    // once. Neither path reruns execution or resolves another operation.
    public func afterResultPersistedWithPlanOwned113(context: ToolInvocationContext,
        toolName: String, outcome: ToolInvocationResult,
        originalPlan: ?NormalizedOperationPlan): OwnedPostCanonicalObserverDispatch113 {
        let view = context.beginInvocationView159()
        try { afterResultPersistedWithPlanOwned113Scope159(view, toolName, outcome, originalPlan) } finally { view.endInvocationView159() }
    }

    private func afterResultPersistedWithPlanOwned113Scope159(context: ToolInvocationContext,
        toolName: String, outcome: ToolInvocationResult,
        originalPlan: ?NormalizedOperationPlan): OwnedPostCanonicalObserverDispatch113 {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: OwnedPostCanonicalObserverDispatch113 = registrationConsumerBody204<OwnedPostCanonicalObserverDispatch113>({ =>

        let registration = match (registrationForRun(context, toolName)) {
            case Some(value) => value
            case None => return OwnedPostCanonicalObserverDispatch113.Existing(
                afterResultPersistedWithPlan(context, toolName, outcome, originalPlan)) }
        let observer = match (registration.executor as PaidPreparedPostCanonicalToolObserver113) {
            case Some(value) => value
            case None => return OwnedPostCanonicalObserverDispatch113.Existing(
                afterResultPersistedWithPlan(context, toolName, outcome, originalPlan)) }
        match (validateToolSnapshotThread(context)) {
            case Result.Err(error) => return OwnedPostCanonicalObserverDispatch113.Existing(Result<Unit>.Err(error))
            case Result.Ok(_) => () }
        let result = match (outcome) {
            case ToolInvocationResult.Completed(value) =>
                if (value.isError) { return OwnedPostCanonicalObserverDispatch113.Existing(Result<Unit>.Ok(())) }; value
            case _ => return OwnedPostCanonicalObserverDispatch113.Existing(Result<Unit>.Ok(())) }
        let plan = match (originalPlan) {
            case Some(value) => value
            case None => return OwnedPostCanonicalObserverDispatch113.Existing(
                directPostCanonicalObserverFailure("tool.original_frozen_plan_missing")) }
        if (plan.toolName != toolName || result.receiptId == "" || result.payloadLease.isNone()) {
            return OwnedPostCanonicalObserverDispatch113.Existing(
                directPostCanonicalObserverFailure("tool.original_frozen_plan_mismatch")) }
        match (observer.afterPreparedResultPersistedOwned113(context, plan, result)) {
            case Some(value) => OwnedPostCanonicalObserverDispatch113.Owned(value)
            case None => OwnedPostCanonicalObserverDispatch113.Existing(
                afterResultPersistedWithPlan(context, toolName, outcome, originalPlan)) }
    
            })
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func afterDirectResultPersistedOwned113(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        captured: DirectPostCanonicalObserverCapture,
        boundary: DirectPostCanonicalProjectionBoundary): OwnedPostCanonicalObserverDispatch113 {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: OwnedPostCanonicalObserverDispatch113 = registrationConsumerBody204<OwnedPostCanonicalObserverDispatch113>({ =>

        let observer = match (captured.observer as PaidDirectPostCanonicalToolObserver113) {
            case Some(value) => value
            case None => return OwnedPostCanonicalObserverDispatch113.Existing(
                afterDirectResultPersisted(context, prepared, result, captured, boundary)) }
        captured.consumeOwned113({ =>
            if (!refEq(context, captured.context) || !refEq(prepared, captured.prepared) ||
                !refEq(context.budget, boundary.budget) || result.isError || result.payloadLease.isNone() ||
                result.callId != prepared.call.callId || result.receiptId != "receipt-" + prepared.operationId.value) {
                return OwnedPostCanonicalObserverDispatch113.Existing(
                    directPostCanonicalObserverFailure("tool.direct_projection_invocation_changed")) }
            match (prepared.source.operationRoot) {
                case Some(OperationRootSource.Direct(source)) =>
                    if (!refEq(source, boundary.source)) {
                        return OwnedPostCanonicalObserverDispatch113.Existing(
                            directPostCanonicalObserverFailure("tool.direct_projection_root_changed")) }
                case _ => return OwnedPostCanonicalObserverDispatch113.Existing(
                    directPostCanonicalObserverFailure("tool.direct_projection_source_missing")) }
            match (validatePreparedSourceContext(context, prepared.source)) {
                case Result.Err(error) => return OwnedPostCanonicalObserverDispatch113.Existing(Result<Unit>.Err(error))
                case Result.Ok(_) => () }
            let registration = match (registrationForRun(context, prepared.call.name)) {
                case Some(value) => value
                case None => return OwnedPostCanonicalObserverDispatch113.Existing(
                    directPostCanonicalObserverFailure("tool.direct_projection_registration_missing")) }
            let executor = match (registration.executor as Object) {
                case Some(value) => value
                case None => return OwnedPostCanonicalObserverDispatch113.Existing(
                    directPostCanonicalObserverFailure("tool.direct_projection_executor_changed")) }
            if (!refEq(executor, captured.executor)) {
                return OwnedPostCanonicalObserverDispatch113.Existing(
                    directPostCanonicalObserverFailure("tool.direct_projection_executor_changed")) }
            let call=ToolCall(prepared.call.callId,prepared.call.name,prepared.borrowOperationPlanFrame204().canonicalArguments)
            let plan = normalizedToolOperationPlan(context, call, registration.descriptor.resolved(call),
                contextReadFacts: prepared.borrowOperationPlanFrame204().contextReadFacts)
            if (!sameNormalizedOperationPlan(plan, prepared.borrowOperationPlanFrame204())) {
                return OwnedPostCanonicalObserverDispatch113.Existing(
                    directPostCanonicalObserverFailure("tool.direct_projection_plan_changed")) }
            directOwnedObserverScope159(observer, captured.observer, context, prepared, result, boundary)
        })
    
            })
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    private func directObserverScope159(observer: DirectPostCanonicalToolObserver,
        context: ToolInvocationContext, prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): Result<Unit> {
        let view = context.beginInvocationView159()
        try { observer.afterDirectResultPersisted(view, prepared, result, boundary) }
        finally { view.endInvocationView159() }
    }
    private func directOwnedObserverScope159(observer: PaidDirectPostCanonicalToolObserver113,
        original: DirectPostCanonicalToolObserver, context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): OwnedPostCanonicalObserverDispatch113 {
        let view = context.beginInvocationView159()
        try { directOwnedObserverFrame159(observer, original, view, prepared, result, boundary) }
        finally { view.endInvocationView159() }
    }
    private func directOwnedObserverFrame159(observer: PaidDirectPostCanonicalToolObserver113,
        original: DirectPostCanonicalToolObserver, context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): OwnedPostCanonicalObserverDispatch113 {
        match (observer.afterDirectResultPersistedOwned113(context, prepared, result, boundary)) {
            case Some(value) => OwnedPostCanonicalObserverDispatch113.Owned(value)
            case None => OwnedPostCanonicalObserverDispatch113.Existing(
                original.afterDirectResultPersisted(context, prepared, result, boundary)) }
    }

    // A neutral data projection receives the original plan retained by Core.
    // Ordinary executors still enter their exact original callback once.
    // This hook neither resolves an Operation nor grants execution authority.
    public func afterResultPersistedWithPlan(context: ToolInvocationContext,
        toolName: String, outcome: ToolInvocationResult,
        originalPlan: ?NormalizedOperationPlan): Result<Unit> {
        let view = context.beginInvocationView159()
        try { afterResultPersistedWithPlanScope159(view, toolName, outcome, originalPlan) } finally { view.endInvocationView159() }
    }

    private func afterResultPersistedWithPlanScope159(context: ToolInvocationContext,
        toolName: String, outcome: ToolInvocationResult,
        originalPlan: ?NormalizedOperationPlan): Result<Unit> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        match (validateToolSnapshotThread(context)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let result = match (outcome) {
            case ToolInvocationResult.Completed(value) =>
                if (value.isError) { return Result.Ok(()) }; value
            case _ => return Result.Ok(()) }
        let registration = match (registrationForRun(context, toolName)) {
            case Some(value) => value
            case None => return afterResultPersisted(context, toolName, outcome) }
        match (registration.executor as PreparedPostCanonicalToolObserver) {
            case None => afterResultPersisted(context, toolName, outcome)
            case Some(observer) =>
                let plan = match (originalPlan) { case Some(value) => value
                    case None => return directPostCanonicalObserverFailure("tool.original_frozen_plan_missing") }
                if (plan.toolName != toolName || result.receiptId == "" || result.payloadLease.isNone()) {
                    return directPostCanonicalObserverFailure("tool.original_frozen_plan_mismatch") }
                observer.afterPreparedResultPersisted(context, plan, result)
        }
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func afterResultPersisted(context: ToolInvocationContext,
        toolName: String, outcome: ToolInvocationResult): Result<Unit> {
        let view = context.beginInvocationView159()
        try { afterResultPersistedScope159(view, toolName, outcome) } finally { view.endInvocationView159() }
    }

    private func afterResultPersistedScope159(
        context: ToolInvocationContext,
        toolName: String,
        outcome: ToolInvocationResult
    ): Result<Unit> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        match (validateToolSnapshotThread(context)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let result = match (outcome) {
            case ToolInvocationResult.Completed(value) =>
                if (value.isError) {
                    return Result.Ok(())
                }
                value
            case _ => return Result.Ok(())
        }
        let registration = match (registrationForRun(context, toolName)) {
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
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func cancel(runId: RunId, threadId!: ?ThreadId = None): Result<Unit> {
        catalog.cancel(runId, threadId: threadId)
    }

    public func authorize(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        decision: ApprovalDecision,
        decisionSource!: ApprovalDecisionSource = ApprovalDecisionSource.User
    ): Result<ToolAuthorization> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<ToolAuthorization> = registrationConsumerBody204<Result<ToolAuthorization>>({ =>

        match (validatePreparedSourceContext(context, prepared.source)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
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
        if (!sameNormalizedOperationPlan(plan, prepared.borrowOperationPlanFrame204())) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.approval_context_changed",
                "the canonical Operation plan changed while approval was pending"
            ))
        }
        let registration = match (registrationForRun(context, prepared.call.name,
            allowHostService: hostServiceSourceAllowed(prepared.source, prepared.call.name))) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "tool.pending_registration_missing",
                "pending tool is no longer registered",
                fields: [ErrorField("tool", prepared.call.name)]
            ))
        }
        let canonicalCall=ToolCall(prepared.call.callId,prepared.call.name,plan.canonicalArguments)
        let current = registration.descriptor.resolved(canonicalCall)
        let currentPlan = normalizedToolOperationPlan(context, canonicalCall, current, contextReadFacts: plan.contextReadFacts)
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
        match (validateDecisionPolicy(
            context, prepared.call, plan, decision
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        if (approved && match (decision) {
            case ApprovalDecision.ApproveSession => match (
                copiedPermissionGrant204(context, context.sessionId, plan.approvalMetadata.grantScope)
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
    
            })
            let outward204 = match (consumerFrame204) { case Some(value) => value.retainAuthorizedResult204(result204); case None => result204 }
            returnedConsumer204 = true
            outward204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
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
        decidePrepared(context, prepared, decision, afterHandoff, decisionSource)
    }

    // Approval continuation must receive a freshly attested canonical source
    // from the Thread owner. Persisted request JSON cannot mint this authority.
    public func decideCommitted(
        context: ToolInvocationContext,
        operationId: OperationId,
        committed: CommittedToolCallRef,
        decision: ApprovalDecision,
        afterHandoff: (PreparedToolInvocation) -> Result<Unit>,
        decisionSource!: ApprovalDecisionSource = ApprovalDecisionSource.User
    ): Result<ToolInvocationResult> {
        let prepared = match (loadPreparedForApproval(context, operationId, committed: Some(committed))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        decidePrepared(context, prepared, decision, afterHandoff, decisionSource)
    }

    public func decideContextRead(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        decision: ApprovalDecision, afterHandoff: (PreparedToolInvocation) -> Result<Unit>,
        decisionSource!: ApprovalDecisionSource = ApprovalDecisionSource.User): Result<ToolInvocationResult> {
        match (validateRetainedContextReadDecision(context, prepared, decision)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        // A valid user choice can outlive its file/component preparation. The
        // original waiting read is rejected, never approved or handed off.
        match (validateContextReadApprovalTarget(context, prepared)) {
            case Result.Err(error) =>
                // Recheck the non-execution proof after potentially slow target
                // validation. A concurrent transition must not become Rejected.
                match (validateRetainedContextReadDecision(context, prepared, decision)) {
                    case Result.Err(changed) => return Result.Err(changed); case Result.Ok(_) => () }
                return Result.Ok(ToolInvocationResult.Denied(ToolDenial(prepared.call.callId, prepared.call.name, error)))
            case Result.Ok(_) => ()
        }
        decidePrepared(context, prepared, decision, afterHandoff, decisionSource)
    }

    private func decidePrepared(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        decision: ApprovalDecision,
        afterHandoff: (PreparedToolInvocation) -> Result<Unit>,
        decisionSource: ApprovalDecisionSource
    ): Result<ToolInvocationResult> {
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
        match (validateToolSnapshotThread(context)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        operations.loadPlan(operationId, context.runId)
    }

    // Non-mutating check before AgentCore persists an approval decision.
    // authorize repeats the checks immediately before executor handoff.
    // Pure validation of the choice against the already frozen review. This
    // does not inspect freshness, consume approval, mint a grant or execute.
    public func validateRetainedApprovalChoice(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, decision: ApprovalDecision): Result<Unit> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        if (prepared.authorization != PreparedAuthorization.ApprovalRequired || prepared.borrowApprovalFrame204().isNone()) {
            return Result.Err(AgentError(AgentErrorKind.Conflict, "approval.review_missing", "retained review is missing")) }
        validateDecisionPolicy(context, prepared.call, prepared.borrowOperationPlanFrame204(), decision)
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func validateApprovalDecision(
        context: ToolInvocationContext,
        operationId: OperationId,
        decision: ApprovalDecision
    ): Result<Unit> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        let prepared = match (loadPreparedForApproval(context, operationId)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                // An unavailable frozen implementation cannot become current.
                // Only this exact missing-registration result may pass the
                // retained choice to decide/authorize for rejected settlement.
                // Available targets still complete the original preflight;
                // configuration and canonical-plan errors leave review pending.
                if (error.code == "tool.pending_registration_missing") {
                    let plan = match (operations.loadPlan(operationId, context.runId)) {
                        case Result.Ok(value) => value
                        case Result.Err(planError) => return Result.Err(planError)
                    }
                    if (!plan.contextReadFacts.isEmpty()) {
                        let call = match (operations.loadCall(operationId, context.runId)) {
                            case Result.Ok(value) => value
                            case Result.Err(callError) => return Result.Err(callError)
                        }
                        return validateDecisionPolicy(context, call, plan, decision)
                    }
                }
                return Result.Err(error)
        }
        validateDecisionPolicy(
            context, prepared.call, prepared.borrowOperationPlanFrame204(), decision
        )
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    // Validate a read-backed parent while its Run is still awaiting approval.
    // The original Core owner supplies its sealed committed source and captured
    // read boundary. This reads facts only; authorize/execute still repeat full
    // canonicalization after the original owner resumes the Run.
    public func validateReadBackedApprovalDecision(context: ToolInvocationContext,
        operationId: OperationId, committed: CommittedToolCallRef,
        read: ToolPreparationRead, decision: ApprovalDecision): Result<Unit> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        match (validateToolSnapshotThread(context)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let plan = match (operations.loadPlan(operationId, context.runId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let call = match (operations.loadCall(operationId, context.runId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (plan.contextReadFacts.isEmpty() || context.trustedControl ||
            operationId.value != "operation-" + committed.decisionId.value + "-" + committed.scopedToolCallId.value ||
            call.callId != committed.block.callId || call.name != committed.block.name || plan.toolName != call.name) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "tool.approval_read_source_mismatch", "read-backed review requires its original canonical parent")) }
        match (validateContextReadInputProjection(call.arguments, plan.contextReadFacts)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let request = read.request()
        for (link in plan.contextReadFacts) {
            let fact = match (operations.loadContextReadFact(link.operationId, context.runId)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let readPlan = match (operations.loadPlan(link.operationId, context.runId)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (link.runId.value != context.runId.value ||
                canonicalAgentValue(fact.reference()) != canonicalAgentValue(link.toValue()) ||
                fact.origin.parentKind != "committed" || fact.origin.parentCallItemId != committed.canonicalItemId.value ||
                fact.origin.parentDecisionId != committed.decisionId.value || fact.origin.parentScopedCallId != committed.scopedToolCallId.value ||
                fact.origin.ownerNamespace != read.ownerNamespace || fact.origin.packageDigest != read.packageDigest ||
                fact.origin.configurationDigest != read.configurationDigest ||
                fact.origin.projectionDigest != contextReadProjectionDigest(context.contextProjection) ||
                !isContextReadPlan(readPlan) || canonicalAgentValue(readPlan.canonicalArguments) != canonicalAgentValue(request)) {
                return Result.Err(AgentError(AgentErrorKind.Conflict,
                    "tool.approval_read_changed", "review read differs from the retained original source and completed fact")) }
        }
        let registration = match (registrationForRun(context, call.name)) {
            // The frozen choice may be recorded for rejected settlement only.
            // Missing implementations still fail in unchanged decide/authorize.
            case None => return validateDecisionPolicy(context, call, plan, decision)
            case Some(value) => value }
        match (read.validateBoundary(context, request)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let frozenCall = ToolCall(call.callId, call.name, plan.canonicalArguments)
        let current = registration.descriptor.resolved(frozenCall)
        if (!sameNormalizedOperationPlan(plan, normalizedToolOperationPlan(context,
            frozenCall, current, contextReadFacts: plan.contextReadFacts))) {
            return Result.Err(AgentError(AgentErrorKind.Conflict,
                "tool.approval_context_changed", "normalized Operation policy changed while approval was pending")) }
        validateDecisionPolicy(context, call, plan, decision)
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func validateRetainedContextReadDecision(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, decision: ApprovalDecision): Result<Unit> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        let root = match (prepared.source.operationRoot) {
            case Some(OperationRootSource.Direct(value)) => value
            case _ => return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "context.read_source_missing", "read approval requires its retained live source")) }
        match (root.origin) { case DirectCallOrigin.ContextRead(_) => (); case _ => return Result.Err(AgentError(
            AgentErrorKind.PermissionDenied, "context.read_source_missing", "read approval cannot use a different source")) }
        match (validatePreparedSourceContext(context, prepared.source)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let plan = match (operations.loadPlan(prepared.operationId, context.runId)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (prepared.authorization != PreparedAuthorization.ApprovalRequired || !sameNormalizedOperationPlan(plan, prepared.borrowOperationPlanFrame204())) {
            return Result.Err(AgentError(AgentErrorKind.Conflict, "context.read_approval_changed", "read approval plan changed")) }
        if (root.operationId.value != prepared.operationId.value || root.call.callId != prepared.call.callId ||
            root.call.name != prepared.call.name || root.runId.value != context.runId.value ||
            root.threadId.value != context.sessionId.value || root.epoch != context.epoch ||
            !isContextReadPlan(plan) || canonicalAgentValue(root.call.arguments) != canonicalAgentValue(plan.canonicalArguments)) {
            return Result.Err(AgentError(AgentErrorKind.Conflict, "context.read_approval_changed", "read approval identity changed")) }
        match (operations.verifyContextReadApprovalPending(root, plan)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        validateDecisionPolicy(context, prepared.call, plan, decision)
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    public func validateRetainedContextReadApproval(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, decision: ApprovalDecision): Result<Unit> {
        match (validateRetainedContextReadDecision(context, prepared, decision)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        validateContextReadApprovalTarget(context, prepared)
    }

    private func validateContextReadApprovalTarget(context: ToolInvocationContext,
        prepared: PreparedToolInvocation): Result<Unit> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<Unit> = registrationConsumerBody204<Result<Unit>>({ =>

        let plan = prepared.borrowOperationPlanFrame204()
        // Retain the original host closure: it binds configuration, prior
        // canonical facts and the frozen request. Rebuilding a canonical plan
        // alone does not revalidate these preparation dependencies. This must
        // run before authorization/handoff; the executor repeats it later.
        match (prepared.source.contextReadPreparation) {
            case Some(read) => match (read.validateBoundary(context, plan.canonicalArguments)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => ()
        }
        let registration = match (registrationForRun(context, prepared.call.name, allowHostService: true)) {
            case Some(value) => value; case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "context.read_registration_missing", "read implementation is no longer registered")) }
        let canonical=ToolCall(prepared.call.callId,prepared.call.name,plan.canonicalArguments)
        if (!sameNormalizedOperationPlan(plan, normalizedToolOperationPlan(context, canonical, registration.descriptor.resolved(canonical)))) {
            return Result.Err(AgentError(AgentErrorKind.Conflict, "context.read_approval_changed", "read target or authority changed while approval was pending")) }
        Result.Ok(())
    
            })
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    private func validateDecisionPolicy(
        context: ToolInvocationContext,
        call: ToolCall,
        plan: NormalizedOperationPlan,
        decision: ApprovalDecision
    ): Result<Unit> {
        let approved = match (decision) {
            case ApprovalDecision.Reject | ApprovalDecision.RejectWithReason(_) => false
            case ApprovalDecision.Approve | ApprovalDecision.ApproveSession => true
        }
        if (approved && match (decision) {
            case ApprovalDecision.ApproveSession =>
                !networkPolicyModeIsDenied(plan.networkPolicy.mode) ||
                    !plan.approvalMetadata.sessionApprovalAllowed
            case _ => false
        }) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "approval.session_scope_forbidden",
                "this operation requires one-time approval"
            ))
        }
        match (missingRequiredCapability(context, plan.requiredCapabilities)) {
            case Some(missing) => return Result.Err(
                missingCapabilityError(call, missing, "approval")
            )
            case None => Result.Ok(())
        }
    }
    private func preparedWithAuthorization(
        prepared: PreparedToolInvocation,
        authorization: PreparedAuthorization
    ): PreparedToolInvocation {
        PreparedToolInvocation(
            prepared.operationId,
            prepared.call,
            prepared.borrowConcurrencyFrame204(),
            authorization,
            prepared.borrowOperationPlanFrame204(),
            prepared.source,
            approval: prepared.borrowApprovalFrame204()
        )
    }

    private func loadPreparedForApproval(
        context: ToolInvocationContext,
        operationId: OperationId,
        committed!: ?CommittedToolCallRef = None
    ): Result<PreparedToolInvocation> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<PreparedToolInvocation> = registrationConsumerBody204<Result<PreparedToolInvocation>>({ =>

        match (validateToolSnapshotThread(context)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let plan = match (operations.loadPlan(operationId, context.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let call = match (operations.loadCall(operationId, context.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (committed) {
            case Some(source) =>
                if (operationId.value != "operation-" + source.decisionId.value + "-" + source.scopedToolCallId.value ||
                    call.callId != source.block.callId || call.name != source.block.name || plan.toolName != call.name) {
                    return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                        "tool.approval_source_mismatch", "canonical approval source does not identify this Operation and ToolCall"))
                }
                // Verify the exact canonical Item/Decision/Run relation using
                // the existing idempotent admission boundary. For an already
                // loaded Operation this cannot replace its plan or reset state.
                match (operations.prepare(operationId, context.runId, source, plan)) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => ()
                }
            case None => ()
        }
        let registration = match (registrationForRun(context, call.name)) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "tool.pending_registration_missing",
                "pending tool is no longer registered",
                fields: [ErrorField("tool", call.name)]
            ))
        }
        // Reload approval from its persisted plan, without staging a new payload.
        let canonicalCall=ToolCall(call.callId,call.name,plan.canonicalArguments)
        let current = registration.descriptor.resolved(canonicalCall)
        let currentPlan = normalizedToolOperationPlan(context, canonicalCall, current, contextReadFacts: plan.contextReadFacts)
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
            metadata: plan.approvalMetadata,
            sessionApprovalAllowed: networkPolicyModeIsDenied(plan.networkPolicy.mode) &&
                plan.approvalMetadata.sessionApprovalAllowed
        )
        Result.Ok(PreparedToolInvocation(
            operationId,
            call,
            registration.descriptor.concurrency,
            PreparedAuthorization.ApprovalRequired,
            plan,
            match (committed) {
                case Some(source) => PreparedInvocationSource(PreparedInvocationSourceKind.Committed,
                    context, rootToolCall: Some(source), contextReadFacts: plan.contextReadFacts)
                // Raw approval callers retain their existing plan-only origin.
                // Loading a plan never invents a canonical source attestation.
                case None => PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context, contextReadFacts: plan.contextReadFacts)
            },
            approval: Some(request)
        ))
    
            })
            let outward204 = match (consumerFrame204) { case Some(value) => value.retainPreparedValueResult204(result204); case None => result204 }
            returnedConsumer204 = true
            outward204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }

    private func copiedPermissionAllows204(context: ToolInvocationContext,
        sessionId: SessionId, scope: ApprovalGrantScope): Result<Bool> {
        let action = beginRegistrationConsumer204(context)
        var returned = false
        try {
            let result = copiedPermissionAllowsFrame204(action, sessionId, scope)
            returned = true; result
        } catch (error: Exception) {
            match (action) { case Some(value) => value.holdUnknown204(); case None => () }; throw error
        } finally { if (returned) { match (action) { case Some(value) => value.returnedWholeAction204(); case None => () } } }
    }
    private func copiedPermissionAllowsFrame204(action: ?ToolCatalogHostConsumerAction204,
        sessionId: SessionId, scope: ApprovalGrantScope): Result<Bool> {
        match (action) { case Some(frame) => match (permissions as CatalogPermissionGrantDataPort204) {
                case Some(receiver) =>
                    let bytes = frame.copyPermissionGrantUtf8204(scope)
                    if (bytes.byteCount > 8388608) {
                        // Preserve the existing large-input Raw contract;
                        // it is paid, but has no private alias-return receipt.
                        frame.holdUnknown204()
                        let original = permissions.allows(sessionId, scope)
                        bytes.closeAfterWholeCaller204(); return original
                    }
                    let answer = receiver.allowsCatalogGrantOwnedUtf8204(sessionId, bytes)
                    bytes.closeAfterWholeCaller204(); answer
                case None => permissions.allows(sessionId, scope) }
            case None => permissions.allows(sessionId, scope) }
    }
    private func copiedPermissionGrant204(context: ToolInvocationContext,
        sessionId: SessionId, scope: ApprovalGrantScope): Result<Unit> {
        let action = beginRegistrationConsumer204(context)
        var returned = false
        try {
            let result = copiedPermissionGrantFrame204(action, sessionId, scope)
            returned = true; result
        } catch (error: Exception) {
            match (action) { case Some(value) => value.holdUnknown204(); case None => () }; throw error
        } finally { if (returned) { match (action) { case Some(value) => value.returnedWholeAction204(); case None => () } } }
    }
    private func copiedPermissionGrantFrame204(action: ?ToolCatalogHostConsumerAction204,
        sessionId: SessionId, scope: ApprovalGrantScope): Result<Unit> {
        match (action) { case Some(frame) => match (permissions as CatalogPermissionGrantDataPort204) {
                case Some(receiver) =>
                    let bytes = frame.copyPermissionGrantUtf8204(scope)
                    if (bytes.byteCount > 8388608) {
                        // Preserve the existing large-input Raw contract;
                        // it is paid, but has no private alias-return receipt.
                        frame.holdUnknown204()
                        let original = permissions.grant(sessionId, scope)
                        bytes.closeAfterWholeCaller204(); return original
                    }
                    let answer = receiver.grantCatalogGrantOwnedUtf8204(sessionId, bytes)
                    bytes.closeAfterWholeCaller204(); answer
                case None => permissions.grant(sessionId, scope) }
            case None => permissions.grant(sessionId, scope) }
    }
    private func persistedGrantAllows(
        context: ToolInvocationContext,
        sessionId: SessionId,
        scope: ApprovalGrantScope
    ): Bool {
        match (copiedPermissionAllows204(context, sessionId, scope)) {
            case Result.Ok(value) => value
            case Result.Err(_) => false
        }
    }

    private func prepareForApproval(
        context: ToolInvocationContext,
        call: ToolCall,
        descriptor: ToolDescriptor,
        metadata: ToolApprovalMetadata,
        plan: NormalizedOperationPlan,
        requestedOperationId!: ?OperationId = None,
        source!: PreparedInvocationSource
    ): Result<ToolPreparation> {
        let operationId = match (requestedOperationId) {
            case Some(value) => value
            case None => ids.nextOperationId()
        }
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
            metadata: metadata,
            sessionApprovalAllowed: networkPolicyModeIsDenied(plan.networkPolicy.mode) &&
                metadata.sessionApprovalAllowed
        )
        let prepared = PreparedToolInvocation(
            operationId,
            call,
            descriptor.concurrency,
            PreparedAuthorization.ApprovalRequired,
            plan,
            source,
            approval: Some(request)
        )
        Result.Ok(ToolPreparation.NeedsApproval(prepared, request))
    }

    private func prepareReady(
        context: ToolInvocationContext,
        call: ToolCall,
        descriptor: ToolDescriptor,
        capability: Capability,
        plan: NormalizedOperationPlan,
        decisionSource!: ApprovalDecisionSource = ApprovalDecisionSource.StaticPolicy,
        metadata!: ?ToolApprovalMetadata = None,
        requestedOperationId!: ?OperationId = None,
        source!: PreparedInvocationSource
    ): Result<ToolPreparation> {
        let operationId = match (requestedOperationId) {
            case Some(value) => value
            case None => ids.nextOperationId()
        }
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
                    plan,
                    source
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
        afterHandoff: (PreparedToolInvocation) -> Result<Unit>,
        afterExecutionAdmission!: () -> Unit = { => () },
        executionObservation!: ?(ReturnedToolExecutionObservation) -> Unit = None
    ): Result<ToolInvocationResult> {
        let view = context.beginInvocationView159()
        try { executePreparedScope159(view, prepared, afterHandoff,
            afterExecutionAdmission: afterExecutionAdmission, executionObservation: executionObservation) }
        finally { view.endInvocationView159() }
    }

    private func executePreparedScope159(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        afterHandoff: (PreparedToolInvocation) -> Result<Unit>,
        afterExecutionAdmission!: () -> Unit = { => () },
        executionObservation!: ?(ReturnedToolExecutionObservation) -> Unit = None
    ): Result<ToolInvocationResult> {
        let consumerFrame204 = beginRegistrationConsumer204(context)
        var returnedConsumer204 = false
        try {
            let result204: Result<ToolInvocationResult> = registrationConsumerBody204<Result<ToolInvocationResult>>({ =>

        if(isPluginLivePolicyParentPlan(prepared.borrowOperationPlanFrame204()) || isPluginLivePolicyStreamingChildPlan(prepared.borrowOperationPlanFrame204()) ||
            isManagedChannelOwnedParentPlan(prepared.borrowOperationPlanFrame204()) || isManagedChannelOwnedChildPlan(prepared.borrowOperationPlanFrame204())){
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"tool.live_owned_entry_required",
                "live family requires its retained typed execution owner"))}
        if (prepared.authorization == PreparedAuthorization.ApprovalRequired) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "tool.prepared_not_authorized",
                "prepared tool invocation has not passed its approval barrier",
                fields: [ErrorField("operation_id", prepared.operationId.value)]
            ))
        }
        match (validatePreparedSourceContext(context, prepared.source)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let storedPlan = match (operations.loadPlan(
            prepared.operationId,
            context.runId
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!sameNormalizedOperationPlan(storedPlan, prepared.borrowOperationPlanFrame204())) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.prepared_plan_changed",
                "the canonical Operation plan changed before execution",
                fields: [ErrorField("operation_id", prepared.operationId.value)]
            ))
        }
        if (prepared.source.kind == PreparedInvocationSourceKind.Derived) {
            match (admitDerived(context, prepared)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(admitted) => if (admitted.value != prepared.operationId.value) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "tool.derived_admission_changed",
                        "derived invocation must replay its admitted operation receipt"
                    ))
                }
            }
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
        let retainedJob: ?DirectToolCallRef = if (prepared.source.kind == PreparedInvocationSourceKind.Direct) { managedJobRoot(prepared.source) } else { None }
        let selected = if (retainedJob.isSome()) { managedJobRegistration(prepared.source, prepared.call.name) } else {
            registrationForRun(context, prepared.call.name, allowHostService: hostServiceSourceAllowed(prepared.source, prepared.call.name)) }
        let registration = match (selected) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "tool.prepared_registration_missing",
                "prepared tool is no longer registered",
                fields: [ErrorField("tool", prepared.call.name)]
            ))
        }
        // Preparation is frozen. Recheck the current descriptor against that
        // exact plan without running its input resolver or staging payloads again.
        let canonicalCall = ToolCall(prepared.call.callId, prepared.call.name, storedPlan.canonicalArguments)
        let current = registration.descriptor.resolved(canonicalCall)
        let currentPlan = normalizedToolOperationPlan(context, canonicalCall, current, contextReadFacts: storedPlan.contextReadFacts)
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
        if (!catalog.beginExecution(
            registration, prepared.operationId, context.runId, ThreadId(context.sessionId.value), delegatedSource: retainedJob
        )) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "tool.prepared_registration_missing",
                "prepared tool was revoked before execution",
                fields: [ErrorField("tool", prepared.call.name)]
            ))
        }
        try {
        match (validatePreparedSourceContext(context, prepared.source)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        match (prepared.source.operationRoot) {
            case Some(OperationRootSource.Direct(root)) => if (prepared.source.kind != PreparedInvocationSourceKind.Derived) {
                match (root.validateExternalPlan(storedPlan)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            }
            case _ => ()
        }
        match(withExecutionHandoff(registration, context, prepared, { => operations.markExecutingWithSource(
            prepared.source.operationRoot, prepared.operationId,
            context.runId,
            storedPlan,
            agentUtcMillis(),
            prepared.authorization == PreparedAuthorization.Approved
        ) })) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        // Executing is already durable. Any subsequent failure is possibly
        // side-effecting, even if the separate handoff marker is not written.
        afterExecutionAdmission()
        match (validatePreparedSourceContext(context, prepared.source)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        match(withExecutionHandoff(registration, context, prepared, { => operations.markExecutionHandoffWithSource(
            prepared.source.operationRoot, prepared.operationId,
            context.runId,
            ThreadId(context.sessionId.value),
            agentUtcMillis()
        ) })) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (afterHandoff(prepared)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (validatePreparedSourceContext(context, prepared.source)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        if (catalog.executionWasRevoked(registration)) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "tool.revoked_during_execution",
                "tool was revoked before executor admission",
                fields: [ErrorField("tool", prepared.call.name)]
            ))
        }
        // Only this synchronous executor call can return local execution
        // evidence. A scheduler/frame error cannot reuse a different Err.
        let observations = ArrayList<ToolExecutionOutcome>()
        let execute = { =>
            let observed = registration.executor.executeObserved(context, prepared)
            // This is the real synchronous producer boundary, not handoff or
            // an exception/future inference. Only an installed typed executor
            // may retire its own now-empty temporary cell; no result/error,
            // canonical Source or other consumer payment is ACKed here.
            match (registration.executor as ReturnedToolExecutionFrameObserver173) {
                case Some(actual) => actual.afterToolExecutionFrameReturned173(context, prepared)
                case None => () }
            observations.add(observed)
            // A terminal consumer receives only the exact synchronous returned
            // observation. Validation/scheduler errors cannot manufacture it.
            match (executionObservation) {
                case Some(consume) => try { consume(observed.returnedObservation(context, prepared)) }
                    catch (_: Exception) {
                        match (observed.result) { case Result.Ok(value) => value.releasePayload(); case Result.Err(_) => () }
                        return Result<ToolResult>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                            "tool.execution_observation_failed", "the original returned execution observation was not consumed"))
                    }
                case None => ()
            }
            observed.result
        }
        let executionResult = if (prepared.source.kind == PreparedInvocationSourceKind.Derived &&
            isFrozenReadViewParentPlan(storedPlan)) {
            context.executeDerivedFrame(prepared, execute)
        } else { execute() }
        var payloadTransferred = false
        try {
        match (validatePreparedSourceContext(context, prepared.source)) {
            case Result.Err(sourceError) =>
                // Source loss cannot erase already uncertain execution either.
                match (executionResult) {
                    case Result.Err(error) => if (error.kind == AgentErrorKind.RecoveryRequired ||
                        (error.kind == AgentErrorKind.Cancelled && (context.cancellation.isCancelled() ||
                            (observations.size == 1 && observations[0].provesCancellation(context, prepared, error)) ||
                            (context.budget.deadlineMillis > 0 && agentUtcMillis() >= context.budget.deadlineMillis)))) {
                        return Result.Err(error)
                    }
                    case Result.Ok(_) => ()
                }
                return Result.Err(sourceError)
            case Result.Ok(_) => ()
        }
        if (catalog.executionWasRevoked(registration)) {
            // Revocation still rejects every late successful value. It cannot
            // erase an executor's conservative unknown outcome or a cancelled
            // effect proved by this actual invocation's token/deadline or
            // exact typed observation from its trusted local executor.
            match (executionResult) {
                case Result.Err(error) =>
                    if (error.kind == AgentErrorKind.RecoveryRequired ||
                        (error.kind == AgentErrorKind.Cancelled &&
                            (context.cancellation.isCancelled() ||
                                (observations.size == 1 && observations[0].provesCancellation(context, prepared, error)) ||
                                (context.budget.deadlineMillis > 0 &&
                                    agentUtcMillis() >= context.budget.deadlineMillis)))) {
                        return Result.Err(error)
                    }
                case Result.Ok(_) => ()
            }
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "tool.revoked_during_execution",
                "tool was revoked while execution was in flight",
                fields: [ErrorField("tool", prepared.call.name)]
            ))
        }
        let execution = match (executionResult) {
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
        let completed = ToolResult(
                prepared.call.callId,
                execution.output,
                isError: execution.isError,
                receiptId: if (execution.receiptId == "") {
                    prepared.operationId.value
                } else {
                    execution.receiptId
                }, payloadLease: execution.payloadLease
            )
        payloadTransferred = true
        Result.Ok(ToolInvocationResult.Completed(completed))
        } finally {
            if (!payloadTransferred) { match (executionResult) { case Result.Ok(value) => value.releasePayload(); case _ => () } }
        }
        } finally {
            catalog.finishExecution(registration, prepared.operationId)
        }
    
            })
            match (consumerFrame204) { case Some(value) => value.observeActualExecution204(result204); case None => () }
            match (consumerFrame204) { case Some(value) => value.holdReturnedResultData204(result204); case None => () }
            returnedConsumer204 = true
            result204
        } catch (error: Exception) {
            match (consumerFrame204) { case Some(value) => value.holdUnknown204(); case None => () }
            throw error
        } finally {
            if (returnedConsumer204) { match (consumerFrame204) { case Some(value) => value.returnedWholeAction204(); case None => () } }
        }
    }


    private func appendAudit(
        context: ToolInvocationContext,
        action: String,
        call: ToolCall,
        capability: Capability,
        decisionSource!: ?ApprovalDecisionSource = None,
        metadata!: ?ToolApprovalMetadata = None
    ): Result<Unit> {
        let pin = beginRegistrationConsumer204(context)
        var returned = false
        try {
            let answer = appendAuditDataFrame204(context, action, call, capability, decisionSource, metadata, pin)
            returned = true; answer
        } catch (error: Exception) {
            match (pin) { case Some(value) => value.holdUnknown204(); case None => () }; throw error
        } finally { if (returned) { match (pin) { case Some(value) => value.returnedWholeAction204(); case None => () } } }
    }
    private func appendAuditEventFrame204(
        context: ToolInvocationContext, action: String, call: ToolCall, capability: Capability,
        decisionSource: ?ApprovalDecisionSource, metadata: ?ToolApprovalMetadata
    ): AgentEvent {
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
    }
    private func appendAuditDataFrame204(context: ToolInvocationContext, action: String,
        call: ToolCall, capability: Capability, decisionSource: ?ApprovalDecisionSource,
        metadata: ?ToolApprovalMetadata, pin: ?ToolCatalogHostConsumerAction204): Result<Unit> {
        match (pin) {
            case Some(frame) => match (audit as CatalogAuditEventDataPort204) {
                case Some(receiver) =>
                    let owner = frame.constructAuditWire204()
                    owner.fundAuditInputFrame204(context, action, call, capability, metadata)
                    // This complete private builder returns before the writer
                    // captures the event. Its original sequence/order is exact.
                    owner.installAuditEventFrame204(appendAuditEventFrame204(context, action, call,
                        capability, decisionSource, metadata))
                    if (owner.requiresRawAuditCompatibility204()) {
                        frame.holdUnknown204()
                        return owner.appendRawAuditCompatibility204(audit)
                    }
                    owner.producerFrameReturned204()
                    let answer = receiver.appendCatalogAuditOwnedUtf8204(owner)
                    owner.closeAfterWholeCaller204(); answer
                case None =>
                    frame.holdUnknown204()
                    audit.append(appendAuditEventFrame204(context, action, call, capability, decisionSource, metadata))
            }
            case None => audit.append(appendAuditEventFrame204(context, action, call, capability, decisionSource, metadata))
        }
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

// Presentation hints for terminal-aware consumers. They are recorded in the
// live ordinary Tool context but never in a frozen durable plan environment,
// whose emptiness the frozen plugin families require. Plugin workers still
// receive them through the sandbox environment allowlist.
func isPresentationEnvironmentHint180(name: String): Bool {
    name == "TERM" || name == "COLORTERM" || name == "NO_COLOR"
}

public func normalizedToolOperationPlan(
    context: ToolInvocationContext,
    call: ToolCall,
    descriptor: ToolDescriptor,
    contextReadFacts!: Array<ContextReadFactLink> = []
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
    // A plan's environment is part of the frozen binding that gets hashed and
    // persisted, so it must not carry per-invocation terminal state. The
    // product seeds TERM/COLORTERM/NO_COLOR into the ordinary Tool context as
    // presentation hints; those stay in the live context (managed jobs and
    // external authority scopes still bind them) and reach plugin workers
    // through the sandbox environment allowlist. Frozen plugin families
    // require an empty plan environment, and a terminal-dependent plan would
    // change its binding digest between a terminal and a non-terminal caller.
    let environment = ArrayList<ValueField>()
    for (entry in context.environment.entries() where !isPresentationEnvironmentHint180(entry.name)) {
        environment.add(ValueField(entry.name, textValue(entry.value)))
    }
    let effect = if (!descriptor.sideEffecting) {
        OperationEffectClass.ReadOnly
    } else if (operationCapabilitiesStayInWorkspace(required)) {
        OperationEffectClass.WorkspaceMutation
    } else {
        OperationEffectClass.ExternalMutation
    }
    let retry = if (!descriptor.neverReplay && effect == OperationEffectClass.ReadOnly) {
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
        ValueField("implementation", objectValue([
            ValueField("tool_version", textValue(descriptor.implementationVersion)),
            ValueField("fingerprint", textValue(descriptor.implementationFingerprint)),
            ValueField("schema_digest", textValue(descriptor.schemaDigest)),
            ValueField("effective_arguments_digest", textValue(modelPolicySha256Text(
                canonicalApprovalValue(canonicalArguments)
            )))
        ])),
        ValueField("approval", approvalBindingValue(metadata, writeBinding)),
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
    if (!contextReadFacts.isEmpty()) { bindingValue.put("context_reads", contextReadFactLinksValue(contextReadFacts)) }
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
        approvalMetadata: Some(metadata),
        toolVersion: descriptor.implementationVersion,
        implementationFingerprint: descriptor.implementationFingerprint,
        schemaDigest: descriptor.schemaDigest,
        effectiveArgumentsDigest: modelPolicySha256Text(
            canonicalApprovalValue(canonicalArguments)
        ), contextReadFacts: contextReadFacts
    )
}
func primaryPlanCapability(plan: NormalizedOperationPlan): Capability {
    if (plan.requiredCapabilities.isEmpty()) {
        Capability(CapabilityKind.WorkspaceRead)
    } else {
        plan.requiredCapabilities[0]
    }
}

public func sameNormalizedOperationPlan(
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
        canonicalAgentValue(contextReadFactLinksValue(left.contextReadFacts)) == canonicalAgentValue(contextReadFactLinksValue(right.contextReadFacts)) &&
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
func approvalBindingValue(
    metadata: ToolApprovalMetadata,
    writeBinding: AgentValue
): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("capability_label", textValue(metadata.capabilityLabel)))
    fields.add(ValueField("risk", textValue(approvalRiskLevelName(metadata.assessment.level))))
    fields.add(ValueField("grant_capability", textValue(metadata.grantScope.capability)))
    fields.add(ValueField("grant_path", textValue(metadata.grantScope.pathPrefix)))
    fields.add(ValueField("grant_tool", textValue(metadata.grantScope.toolName)))
    fields.add(ValueField("grant_host", textValue(metadata.grantScope.host)))
    fields.add(ValueField("write", writeBinding))
    if (!metadata.sessionApprovalAllowed) {
        fields.add(ValueField("session_approval_allowed", boolValue(false)))
    }
    objectValue(fields.toArray())
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
        left.grantScope.sessionOnly == right.grantScope.sessionOnly &&
        left.sessionApprovalAllowed == right.sessionApprovalAllowed
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
    let bytes = unsafe { source.rawData() }
    var index: Int64 = 0
    while (index < bytes.size) {
        hash = (hash ^ UInt64(bytes[index])).wrappingMul(1099511628211)
        index += 1
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

func livePolicyChildRejectionError(call:ToolCall,decision:ApprovalDecision):AgentError{
    let reason=match(decision){case ApprovalDecision.Reject=>"";case ApprovalDecision.RejectWithReason(value)=>value
        case _=>throw IllegalArgumentException("only the actual rejected decision creates a no-effect error")}
    AgentError(AgentErrorKind.PermissionDenied,"tool.approval_rejected",
        if(reason.trimAscii()==""){"user rejected the pending tool operation"}
        else{"user rejected the pending tool operation: "+reason},fields:rejectionFields(call.name,reason))
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
