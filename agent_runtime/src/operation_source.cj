package agent_runtime

import agent_domain.*

// A live Thread owner attests its own canonical direct ToolCall. This is not a
// model Decision and is deliberately neither deserializable nor public-mintable.
public class DirectToolCallRef {
    public let operationId: OperationId
    public let canonicalItemId: ItemId
    public let threadId: ThreadId
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let epoch: Int64
    public let call: ToolCall
    public let origin: DirectCallOrigin
    private let externalGuard: ?ExternalRequestGuard
    private let contextReadGuard: ?ContextReadGuard
    private let managedJobGuard: ?ManagedJobAdmission

    init(item: ThreadItem, operationId: OperationId, runId: RunId, epoch: Int64, call: ToolCall,
        externalGuard!: ?ExternalRequestGuard = None, contextReadGuard!: ?ContextReadGuard = None,
        managedJobGuard!: ?ManagedJobAdmission = None) {
        this.operationId = operationId
        this.canonicalItemId = item.id
        this.threadId = item.threadId
        this.turnId = item.turnId
        this.runId = runId
        this.epoch = epoch
        this.call = call
        this.origin = effectiveDirectCallOrigin(item.provenance)
        this.externalGuard = externalGuard
        this.contextReadGuard = contextReadGuard; this.managedJobGuard = managedJobGuard
        match (origin) {
            case DirectCallOrigin.ManagedJob(value) =>
                if (managedJobGuard.isNone() || contextReadGuard.isSome() || externalGuard.isSome() ||
                    managedJobLaunchDigest(value) != managedJobLaunchDigest(managedJobGuard.getOrThrow().binding) ||
                    value.declaration.threadId.value != threadId.value || value.declaration.runId.value != runId.value) {
                    throw IllegalArgumentException("Task source requires its live sealed admission and exact child owner")
                }
            case DirectCallOrigin.ContextRead(_) =>
                if (contextReadGuard.isNone() || managedJobGuard.isSome() || externalGuard.isSome() ||
                    !sameDirectCallOrigin(origin, DirectCallOrigin.ContextRead(contextReadGuard.getOrThrow().origin))) {
                    throw IllegalArgumentException("context read source requires its live sealed admission")
                }
            case DirectCallOrigin.External(value) => if (managedJobGuard.isSome() || contextReadGuard.isSome() || externalGuard.isNone() ||
                !sameDirectCallOrigin(origin, DirectCallOrigin.External(externalGuard.getOrThrow().origin)) ||
                value.threadId.value != threadId.value || externalToolCallDigest(call) != value.requestDigest) {
                throw IllegalArgumentException("external source requires its live sealed request guard")
            }
            case _ => if (managedJobGuard.isSome() || contextReadGuard.isSome() || externalGuard.isSome()) { throw IllegalArgumentException("non-external source cannot carry an external guard") }
        }
    }

    public prop externalBinding: ?ExternalIngressBinding {
        get() { match (externalGuard) { case Some(value) => Some(value.connection.binding); case None => None } }
    }
    public prop managedJob: ?ManagedJobAdmission { get() { managedJobGuard } }
    public func validateLiveSource(): Result<Unit> {
        match (managedJobGuard) { case Some(value) => return value.validateInvocation(call); case None => () }
        match (contextReadGuard) { case Some(value) => return value.validate(call); case None => () }
        match (externalGuard) {
            case Some(value) =>
                if (externalToolCallDigest(call) != value.origin.requestDigest) { return externalDenied("external.source_mutated") }
                value.validate()
            case None => Result.Ok(())
        }
    }
    public func validateExternalPlan(plan: NormalizedOperationPlan): Result<Unit> {
        match (managedJobGuard) { case Some(value) => return value.validatePlan(plan); case None => () }
        match (contextReadGuard) { case Some(value) => return value.validatePlan(plan); case None => () }
        match (externalGuard) { case Some(value) => value.validatePlan(plan); case None => Result.Ok(()) }
    }
    public func matchesExternalCancellation(token: CancellationToken): Bool {
        match (managedJobGuard) { case Some(value) => return refEq(value.token(), token); case None => () }
        match (externalGuard) { case Some(value) => refEq(value.token(), token); case None => true }
    }
    public prop externalCancellationToken: ?CancellationToken {
        get() { match (managedJobGuard) { case Some(value) => Some(value.token()); case None =>
            match (externalGuard) { case Some(value) => Some(value.token()); case None => None } } }
    }
}

// Both variants require capabilities minted by the canonical Thread owner.
// Wrapping an existing reference does not change its identity or authority.
public enum OperationRootSource {
    Committed(CommittedToolCallRef) | Direct(DirectToolCallRef)

    public func itemId(): ItemId {
        match (this) {
            case Committed(value) => value.canonicalItemId
            case Direct(value) => value.canonicalItemId
        }
    }

    public func callId(): String {
        match (this) {
            case Committed(value) => value.block.callId
            case Direct(value) => value.call.callId
        }
    }

    public func toolName(): String {
        match (this) {
            case Committed(value) => value.block.name
            case Direct(value) => value.call.name
        }
    }
}

func rejectUnsupportedExternalOperationSource(source: ?OperationRootSource): Result<Unit> {
    match (source) {
        case Some(OperationRootSource.Direct(root)) => match (root.origin) {
            case DirectCallOrigin.ManagedJob(_) => managedJobDenied("operation.managed_job_source_unsupported")
            case DirectCallOrigin.External(_) => externalDenied("operation.external_source_unsupported")
            case DirectCallOrigin.ContextRead(_) => contextReadDenied("operation.context_read_source_unsupported")
            case _ => Result.Ok(())
        }
        case _ => Result.Ok(())
    }
}
