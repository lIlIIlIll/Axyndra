package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_plugin_registry.*
import agent_sdk.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

let HOST_CANONICAL_FAILURE_HELD173 = AgentError(AgentErrorKind.RecoveryRequired,
    "tool.owned_execution_failure_held", "actual execution failure awaits its paid loan and caller")

// Only the local operator file creates this selection. It never grants an
// OperationRootSource, ContextRead, canonical ordinal or completed Receipt.
// The actual mounted descriptor and original Pipeline still grant invocation.
public class HostCanonicalProjectionSelection173 {
    public let namespace: String
    public let packageDigest: String
    public let generation: UInt64
    public let localTool: String
    public let provider: String
    public let action: String
    public let capability: String
    public let effect: String
    public let configurationDigest: String
    private let path: String
    private let encoded: String
    private let witness: String
    private let payment: LogicalJsonOwnerReservation
    private let lock = Mutex()
    // The old raw catalog/plan API has no reference-retirement witness. Keep
    // each independent prepared graph funded until its real owner is retired.
    private let preparedCopies = ArrayList<HostCanonicalProjectionCopy173>()
    private let mountedMetadata = ArrayList<LogicalJsonOwnerReservation>()
    private let heldExecutionFailures173 = ArrayList<HostCanonicalExecutionFailure173>()

    init(path: String, encoded: String, witness: String, namespace: String,
        packageDigest: String, generation: UInt64, tool: AgentValue,
        payment: LogicalJsonOwnerReservation) {
        this.path = path; this.encoded = encoded; this.witness = witness
        // These are independent UTF8 copies in this selection's existing
        // Registry child. The caller's Catalog identity is never retained.
        this.namespace = String.fromUtf8(namespace.toArray())
        this.packageDigest = String.fromUtf8(packageDigest.toArray())
        this.generation = generation; this.payment = payment
        localTool = httpIntentText(tool, "name"); provider = httpIntentText(tool, "provider")
        action = httpIntentText(tool, "action"); capability = httpIntentText(tool, "capability")
        effect = httpIntentText(tool, "effect")
        configurationDigest = modelPolicySha256Text(encoded + "\n" + witness)
    }
    public func validateCurrent173(): Result<Unit> {
        lock.lock()
        try {
            // This temporary UTF8/native comparison backing is paid by the
            // installed snapshot for the entire captured alias lifetime.
            let bytes = encoded.toArray()
            let code = unsafe {
                let source = LibC.mallocCString(path)
                try {
                    let expected = LibC.mallocCString(witness)
                    try {
                        let raw = acquireArrayRawData(bytes)
                        try { axyndra_read_view_equal(source, expected, raw.pointer, bytes.size) }
                        finally { releaseArrayRawData(raw) }
                    } finally { LibC.free(expected) }
                } finally { LibC.free(source) }
            }
            if (code != 0) { return hostPluginResourceError("plugin.canonical_projection_selection_changed",
                "the complete operator canonical-data selection changed") }
            Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }
    public func deriveDataPayment173(invoice: Int64): LogicalJsonOwnerReservation {
        if (invoice < 1) { throw IllegalArgumentException("canonical data payment must be positive") }
        let actual = payment.deriveRetainedLease()
        try { actual.ensureRetainedPeak(invoice); actual }
        catch (error: Exception) { actual.close(); throw error }
    }
    public func requires173(context: ToolInvocationContext): Result<Unit> {
        match (context.cancellation.check()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
        if (action != "canonical.context.project" || capability != "workspace.read" || effect != "read_only" ||
            !context.capabilities.allows(CapabilityKind.WorkspaceRead)) {
            return hostPluginResourceError("plugin.canonical_projection_permission_denied",
                "the actual invocation must hold the exact operator-selected canonical-data action") }
        validateCurrent173()
    }
    func retainMountMetadata173(): Unit {
        let actual = deriveDataPayment173(16384)
        lock.lock()
        try { mountedMetadata.add(actual) }
        catch (error: Exception) { actual.close(); throw error }
        finally { lock.unlock() }
    }
    public func reserveExecutionFailure173(): HostCanonicalExecutionFailure173 {
        // This executes BEFORE the first Native/query/SQL producer. A refused
        // original-bank invoice therefore precedes every paid error transfer.
        let metadata = deriveDataPayment173(16384)
        var registered = false
        try {
            let held = HostCanonicalExecutionFailure173(this, metadata)
            lock.lock()
            try { heldExecutionFailures173.add(held); registered = true; held }
            finally { lock.unlock() }
        } finally { if (!registered) { metadata.close() } }
    }
    func reservePreparedExecutionFailure173(prepared: PreparedToolInvocation): HostCanonicalExecutionFailure173 {
        let held = reserveExecutionFailure173()
        // The existing16KiB cell invoice includes this single borrowed pointer;
        // the actual prepared graph still has its own independent151 payment.
        // Assignment is before any Native/query/SQL execution producer.
        held.transferLock.lock()
        try { held.prepared173 = Some(prepared); held.requiresPipelineReturn173 = true }
        finally { held.transferLock.unlock() }
        held
    }
    func returnedExecutionFrame173(prepared: PreparedToolInvocation): Unit {
        // Called ONLY by actual Pipeline after executeObserved returned. A
        // throw/unknown frame has no call here and keeps its complete paid cell.
        lock.lock()
        try {
            for (index in 0..heldExecutionFailures173.size) {
                let held = heldExecutionFailures173[index]
                held.transferLock.lock()
                try {
                    match (held.prepared173) {
                        case Some(actual) => if (refEq(actual, prepared)) {
                            held.prepared173 = None<PreparedToolInvocation>
                            held.pipelineReturned173 = true
                            // The trusted typed sink accepted this SAME share.
                            // All original dispatch/borrow/execute helpers have
                            // now returned. Clear only our pointer, never ACK it.
                            if (held.sinkAccepted173) { held.consumer = None<OwnedFailureDataConsumer113> }
                        }
                        case None => () }
                } finally { held.transferLock.unlock() }
            }
        } finally { lock.unlock() }
        retireAcknowledgedExecutionFailures173()
    }
    public func consumeExecutionFailure173(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        held: HostCanonicalExecutionFailure173): Result<ToolResult> {
        if (!held.belongsTo173(this)) { throw IllegalArgumentException("execution failure holder belongs to another selection") }
        // The original consumer is ALREADY linked in the paid selection. No
        // reserve, clone or holder construction occurs while accepting it.
        // Every later pressure/None/throw leaves that same reference reachable.
        let consumer = held.consumer.getOrThrow()
        match (classifyExecutionFailure173(held)) {
            case Result.Err(_) => return Result<ToolResult>.Err(HOST_CANONICAL_FAILURE_HELD173)
            case Result.Ok(_) => () }
        if (held.recoverable) {
            // Original model-facing recoverable output and error ordering
            // remain exact. The independent output copy is paid separately
            // while the complete original eight-field error loan remains live.
            let copied = HostPaidValueProjection151(deriveDataPayment173(4096))
            var published = false
            try {
                match (consumer.withError({ error, fund =>
                    var bytes = prepared.call.callId.size + prepared.operationId.value.size
                    for (size in [error.code.size, error.message.size]) {
                        if (bytes > Int64.Max - size) { throw LogicalJsonPayloadError("recoverable error bytes overflow") }
                        bytes += size }
                    for (field in error.fields) {
                        if (bytes > Int64.Max - field.name.size || bytes + field.name.size > Int64.Max - field.value.size) {
                            throw LogicalJsonPayloadError("recoverable error field bytes overflow") }
                        bytes += field.name.size + field.value.size }
                    if (error.fields.size > (Int64.Max - 32) / 8) { throw LogicalJsonPayloadError("recoverable error nodes overflow") }
                    let nodes = error.fields.size * 8 + 32
                    if (bytes > (Int64.Max - 65536) / 16 || nodes > (Int64.Max - 65536 - bytes * 16) / 512) {
                        throw LogicalJsonPayloadError("recoverable error construction invoice overflow") }
                    match (fund(65536 + bytes * 16 + nodes * 512)) {
                        case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () }
                    let original = recoverableToolResult(prepared.call, error, receiptId: prepared.operationId.value)
                    copied.retainValue151(1, original.output)
                    copied.projectValue151(1)
                })) {
                    case Result.Err(_) => return Result<ToolResult>.Err(HOST_CANONICAL_FAILURE_HELD173)
                    case Result.Ok(_) => () }
                // This short loan transfers no raw error alias. The output's
                // own canonical payload share is independent of this consumer.
                copied.withValue151({ value => held.output = Some(value) })
                let output = held.output.getOrThrow(); held.output = None<AgentValue>
                dispatchExecutionFailure173(context, prepared.call.callId, held, true)
                let lease = copied.publicationLease151(); published = true
                Result<ToolResult>.Ok(ToolResult(prepared.call.callId, output, isError: true,
                    receiptId: prepared.operationId.value, payloadLease: Some(lease)))
            } finally { if (!published) { copied.closeUnpublished151() } }
        } else {
            // Fixed scalar metadata retains the real original kind. The
            // complete code/message/fields/attachments stay in paid custody.
            Result<ToolResult>.Err(dispatchExecutionFailure173(context, prepared.call.callId, held, false))
        }
    }
    func classifyExecutionFailure173(held: HostCanonicalExecutionFailure173): Result<Unit> {
        if (!held.belongsTo173(this)) { throw IllegalArgumentException("execution failure holder belongs to another selection") }
        held.withError173({ error, _ =>
            held.kind = error.kind; held.recoverable = isRecoverableExecutionFailure173(error) })
    }
    func dispatchExecutionFailure173(context: ToolInvocationContext, callId: String,
        held: HostCanonicalExecutionFailure173, dataOnly: Bool): AgentError {
        let pending = AgentError(held.kind, "tool.owned_execution_failure_pending",
            "actual execution failure awaits its paid consumer")
        match (context.paidExecutionFailureConsumer173()) {
            case None => pending
            case Some(actual) =>
                try {
                    match (actual.captureExecutionFailure173(context, callId, held.consumer.getOrThrow(), dataOnly)) {
                        case Result.Err(_) => pending
                        case Result.Ok(marker) =>
                            // The real Core/Direct queue now holds this exact
                            // consumer. Only this producer-side reference dies;
                            // neither it nor the conservative holder is ACKed.
                            // Keep our exact pointer until actual Pipeline
                            // observes the ENTIRE executeObserved frame return.
                            held.sinkAccepted173 = true; marker }
                } catch (_: Exception) { pending }
        }
    }
    // Only this cell's metadata can retire here. Normal mounted execution
    // additionally requires actual Pipeline return; its complete error/output
    // and independent payment are NEVER ACKed by execution return. DATA-only
    // custody controls have no Native producer and use their actual consumer
    // ACK after the enclosing synchronous loan helper has returned.
    private func detachOneReturnedExecutionFailure173(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            for (index in 0..heldExecutionFailures173.size) {
                let held = heldExecutionFailures173[index]
                held.transferLock.lock()
                let detached = try {
                    let returned = !held.requiresPipelineReturn173 || held.pipelineReturned173
                    let empty = held.consumer.isNone() && held.output.isNone()
                    let acknowledged = held.consumer.isSome() && held.consumer.getOrThrow().isAcknowledged()
                    if (returned && (empty || acknowledged) && held.metadata.isSome()) {
                        // Clear every cell reference, including its borrowed
                        // selection/metadata pointers, before unlinking it.
                        // Never ACK its independent consumer or result share.
                        held.consumer = None<OwnedFailureDataConsumer113>
                        held.output = None<AgentValue>; held.prepared173 = None<PreparedToolInvocation>
                        held.selected173 = None<HostCanonicalProjectionSelection173>
                        let actual = held.metadata; held.metadata = None<LogicalJsonOwnerReservation>
                        actual
                    } else { None<LogicalJsonOwnerReservation> }
                } finally { held.transferLock.unlock() }
                if (detached.isSome()) {
                    heldExecutionFailures173.remove(at: index)
                    return detached
                }
            }
            None<LogicalJsonOwnerReservation>
        } finally { lock.unlock() }
    }
    func retireAcknowledgedExecutionFailures173(): Unit {
        while (true) {
            // The entire detach/unlink/held helper has now returned, so no
            // local cell/selection borrow in that helper survives this close.
            match (detachOneReturnedExecutionFailure173()) {
                case Some(actual) => actual.close(); case None => return }
        }
    }
    func retainedExecutionCellCount173(): Int64 {
        lock.lock(); try { heldExecutionFailures173.size } finally { lock.unlock() }
    }
    private func frozenData173(): AgentValue {
        // The enclosing installed snapshot already pays these fixed atoms.
        objectValue([ValueField("schema", textValue("axyndra.canonical-data-binding/v1")),
            ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(packageDigest)),
            ValueField("generation", textValue(generation.toString())), ValueField("tool", textValue(localTool)),
            ValueField("provider", textValue(provider)), ValueField("action", textValue(action)),
            ValueField("capability", textValue(capability)), ValueField("effect", textValue(effect)),
            ValueField("configuration_digest", textValue(configurationDigest))])
    }
    public func canonicalArguments173(host: HostJavaScriptPluginHost,
        context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
        match (requires173(context)) { case Result.Err(error) => return Result<AgentValue>.Err(error); case Result.Ok(_) => () }
        if (call.name != "plugin." + namespace + "." + localTool ||
            call.arguments.field("projection_binding").isSome() || call.arguments.field("projection_arguments").isSome() ||
            call.arguments.field("projection_recipe").isSome() ||
            call.arguments.field("host_plan").isSome() || call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome()) {
            return hostPluginResourceError("plugin.canonical_projection_caller_binding",
                "only the actual mounted canonicalizer may capture canonical-data binding") }
        let owner = deriveDataPayment173(4096)
        let copy = HostPaidValueProjection151(owner)
        var retained = false
        try {
            // The indexed meter funds its own metadata/scalar writer before
            // measuring; structural copies and field arrays are paid first.
            copy.retainValue151(1, call.arguments)
            copy.fundAdditional151(16384, 64)
            let binding = frozenData173()
            copy.retainValue151(2, binding)
            // Native preparation receives only bounded operator-description
            // metadata. Large original arguments stay in the paid raw plan;
            // they are visited later through the original bounded references.
            let encodedExtent = copy.measureBorrowedValue151(binding)
            copy.fundAdditional151(encodedExtent.bytes * 8, encodedExtent.nodes)
            let encoded = encodeAgentValue(binding)
            let version = match (host.instanceExecutorVersion(namespace, generation)) {
                case Result.Err(error) => return Result<AgentValue>.Err(error); case Result.Ok(value) => value }
            let prepared = match (host.invoke(namespace, localTool, encoded,
                identity: JavaScriptHostInvocationIdentity(threadId: context.sessionId.value,
                    runId: context.runId.value, epoch: context.epoch, operationId: "", callId: call.callId, kind: "prepare"),
                cancellation: context.cancellation, cwd: context.cwd,
                processLimits: context.budget.processLimits, expectedInstanceGeneration: generation,
                authorityScope: "data-only:" + namespace + ":" + version + ":" + namespace + ":" + packageDigest)) {
                case Result.Err(error) => return Result<AgentValue>.Err(error); case Result.Ok(value) => value }
            try {
                if (prepared.isError || !httpIntentExactFields(prepared.value,
                    ["schema", "action", "role", "provider", "execution", "post_canonical"]) ||
                    httpIntentText(prepared.value, "schema") != "axyndra.canonical-data-recipe/v1" ||
                    httpIntentText(prepared.value, "action") != action || httpIntentText(prepared.value, "provider") != provider) {
                    return hostPluginResourceError("plugin.canonical_projection_recipe_invalid",
                        "the selected Native preparation did not return its exact data recipe") }
                copy.retainValue151(3, prepared.value)
            } finally { prepared.releasePayload() }
            copy.retainField151(1, "projection_arguments", 1)
            copy.retainField151(1, "projection_binding", 2)
            copy.retainField151(1, "projection_recipe", 3)
            copy.projectFields151(1)
            let cell = HostCanonicalProjectionCopy173(copy)
            copy.withValue151({ value => cell.value = Some(value) })
            match (validateCurrent173()) { case Result.Err(error) => return Result<AgentValue>.Err(error); case Result.Ok(_) => () }
            lock.lock()
            try { preparedCopies.add(cell); retained = true } finally { lock.unlock() }
            Result<AgentValue>.Ok(cell.value.getOrThrow())
        } finally { if (!retained) { copy.closeUnpublished151() } }
    }
    func canonicalArgumentsOwned186(host: HostJavaScriptPluginHost,
        context: ToolInvocationContext, call: ToolCall, cache186: HostCanonicalProjectionConfigurationCache173): Result<AgentValue> {
        match (requires173(context)) { case Result.Err(error) => return Result<AgentValue>.Err(error); case Result.Ok(_) => () }
        if (call.name != "plugin." + namespace + "." + localTool ||
            call.arguments.field("projection_binding").isSome() || call.arguments.field("projection_arguments").isSome() ||
            call.arguments.field("projection_recipe").isSome() ||
            call.arguments.field("host_plan").isSome() || call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome()) {
            return hostPluginResourceError("plugin.canonical_projection_caller_binding",
                "only the actual mounted canonicalizer may capture canonical-data binding") }
        let owner = deriveDataPayment173(4096)
        let copy = HostPaidValueProjection151(owner)
        var retained = false
        try {
            // The indexed meter funds its own metadata/scalar writer before
            // measuring; structural copies and field arrays are paid first.
            copy.retainValue151(1, call.arguments)
            copy.fundAdditional151(16384, 64)
            let binding = frozenData173()
            copy.retainValue151(2, binding)
            // Native preparation receives only bounded operator-description
            // metadata. Large original arguments stay in the paid raw plan;
            // they are visited later through the original bounded references.
            let encodedExtent = copy.measureBorrowedValue151(binding)
            copy.fundAdditional151(encodedExtent.bytes * 8, encodedExtent.nodes)
            let encoded = encodeAgentValue(binding)
            let version = match (host.instanceExecutorVersion(namespace, generation)) {
                case Result.Err(error) => return Result<AgentValue>.Err(error); case Result.Ok(value) => value }
            let prepared = match (host.invoke(namespace, localTool, encoded,
                identity: JavaScriptHostInvocationIdentity(threadId: context.sessionId.value,
                    runId: context.runId.value, epoch: context.epoch, operationId: "", callId: call.callId, kind: "prepare"),
                cancellation: context.cancellation, cwd: context.cwd,
                processLimits: context.budget.processLimits, expectedInstanceGeneration: generation,
                authorityScope: "data-only:" + namespace + ":" + version + ":" + namespace + ":" + packageDigest)) {
                case Result.Err(error) => return Result<AgentValue>.Err(error); case Result.Ok(value) => value }
            try {
                if (prepared.isError || !httpIntentExactFields(prepared.value,
                    ["schema", "action", "role", "provider", "execution", "post_canonical"]) ||
                    httpIntentText(prepared.value, "schema") != "axyndra.canonical-data-recipe/v1" ||
                    httpIntentText(prepared.value, "action") != action || httpIntentText(prepared.value, "provider") != provider) {
                    return hostPluginResourceError("plugin.canonical_projection_recipe_invalid",
                        "the selected Native preparation did not return its exact data recipe") }
                copy.retainValue151(3, prepared.value)
            } finally { prepared.releasePayload() }
            copy.retainField151(1, "projection_arguments", 1)
            copy.retainField151(1, "projection_binding", 2)
            copy.retainField151(1, "projection_recipe", 3)
            copy.projectFields151(1)
            let cell = HostCanonicalProjectionCopy173(copy)
            copy.withValue151({ value => cell.value = Some(value) })
            match (validateCurrent173()) { case Result.Err(error) => return Result<AgentValue>.Err(error); case Result.Ok(_) => () }
            lock.lock()
            try { cache186.holdPreparedCopy186(cell); retained = true } finally { lock.unlock() }
            Result<AgentValue>.Ok(cell.value.getOrThrow())
        } finally { if (!retained) { copy.closeUnpublished151() } }
    }
    func canRetireOwnedConfiguration186(): Bool {
        lock.lock()
        try { preparedCopies.isEmpty() && mountedMetadata.isEmpty() && heldExecutionFailures173.isEmpty() }
        finally { lock.unlock() }
    }
    public func requirePlan173(context: ToolInvocationContext, plan: NormalizedOperationPlan): Result<Unit> {
        match (requires173(context)) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
        if (plan.toolName != "plugin." + namespace + "." + localTool ||
            plan.implementation.implementationFingerprint != namespace + ":" + packageDigest ||
            !httpIntentExactFields(plan.canonicalArguments, ["projection_arguments", "projection_binding", "projection_recipe"])) {
            return hostPluginResourceError("plugin.canonical_projection_frozen_plan_changed",
                "the actual prepared plan does not bind its mounted contribution") }
        // Comparison creates two actual codec strings under this SAME paid
        // installed root. Both remain live until the helper returns.
        let phase = deriveDataPayment173(1048576)
        let meter = HostPaidValueProjection151(phase)
        try {
            meter.fundAdditional151(16384, 64)
            let expected = frozenData173()
            let actual = plan.canonicalArguments.field("projection_binding").getOrThrow()
            let left = meter.measureBorrowedValue151(expected)
            let right = meter.measureBorrowedValue151(actual)
            meter.fundAdditional151(left.bytes + right.bytes, left.nodes + right.nodes)
            if (encodeAgentValue(actual) != encodeAgentValue(expected)) {
                return hostPluginResourceError("plugin.canonical_projection_frozen_plan_changed",
                    "the whole operator action/capability/effect binding changed after preparation") }
            validateCurrent173()
        } finally { meter.closeUnpublished151() }
    }
}

// Opaque paid DATA cell. Only the actual selection can construct/register it;
// Native IPC cannot mint it, an operation Source, Receipt or legal cut.
public class HostCanonicalExecutionFailure173 {
    var selected173: ?HostCanonicalProjectionSelection173
    let transferLock = Mutex()
    var prepared173: ?PreparedToolInvocation = None<PreparedToolInvocation>
    var requiresPipelineReturn173 = false
    var pipelineReturned173 = false
    var sinkAccepted173 = false
    var consumer: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    var metadata: ?LogicalJsonOwnerReservation
    var kind = AgentErrorKind.RecoveryRequired
    var recoverable = false
    var output: ?AgentValue = None<AgentValue>
    init(selected: HostCanonicalProjectionSelection173, metadata: LogicalJsonOwnerReservation) {
        this.selected173 = Some(selected); this.metadata = Some(metadata)
    }
    public func belongsTo173(actual: HostCanonicalProjectionSelection173): Bool {
        transferLock.lock(); try {
            selected173.isSome() && refEq(selected173.getOrThrow(), actual)
        } finally { transferLock.unlock() }
    }
    public func hasConsumer173(): Bool {
        transferLock.lock(); try { consumer.isSome() } finally { transferLock.unlock() }
    }
    public func adoptConsumer173(actual: OwnedFailureDataConsumer113): Unit {
        transferLock.lock()
        try {
            if (metadata.isNone()) { throw IllegalStateException("execution failure holder has retired") }
            if (consumer.isSome()) { throw IllegalStateException("execution failure holder is occupied") }
            // Fixed metadata and the registry link were paid before execution.
            // Assignment precedes classification, new invoice and all callbacks.
            consumer = Some(actual)
        } finally { transferLock.unlock() }
    }
    public func adoptPaidFailure173(actual: OwnedCanonicalPaidFailure113): Unit {
        transferLock.lock()
        try {
            if (metadata.isNone()) { throw IllegalStateException("execution failure holder has retired") }
            if (consumer.isSome()) { throw IllegalStateException("execution failure holder is occupied") }
            // All checks/lock acquisition precede takeConsumer. Its exact result
            // moves straight into this already-reachable cell, without a fund
            // call, clone, callback or new holder between take and assignment.
            consumer = Some(actual.takeConsumer())
        } finally { transferLock.unlock() }
    }
    public func withError173(consume: (AgentError, (Int64) -> Result<Unit>) -> Unit): Result<Unit> {
        let actual = consumer.getOrThrow()
        actual.withError(consume)
    }
}

class HostCanonicalProjectionCopy173 {
    let owner: HostPaidValueProjection151
    var value: ?AgentValue = Option<AgentValue>.None
    var next186: ?HostCanonicalProjectionCopy173 = None<HostCanonicalProjectionCopy173>
    init(owner: HostPaidValueProjection151) { this.owner = owner }
}

class HostCanonicalProjectionConfigurationCache173 {
    private let nativeTextDebtLock186 = Mutex()
    private var nativeTextDebt186: ?HostCanonicalNativeTextDebt186 = None<HostCanonicalNativeTextDebt186>
    private var pendingNativeText186: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    func copiedNativeProviderFrame186(selected: HostCanonicalProjectionSelection173): String {
        nativeTextDebtLock186.lock(); try {
            if (pendingNativeText186.isSome()) { throw LogicalJsonPayloadError("unknown Native provider text construction remains paid") }
            let size = selected.provider.size
            if (size > (Int64.Max - 16384) / 8) { throw LogicalJsonPayloadError("Native provider text invoice overflow") }
            // The complete callback borrows this private selection under its
            // real view frame. Check pending before any next invoice is paid.
            let payment = selected.deriveDataPayment173(16384 + size * 8)
            pendingNativeText186 = Some(payment)
            let carrier = HostCanonicalNativeTextDebt186(payment, nativeTextDebt186)
            nativeTextDebt186 = Some(carrier); pendingNativeText186 = None<LogicalJsonOwnerReservation>
            // No original configuration/View/Policy object enters this
            // carrier. SDK timer functions may retain this independent copy
            // after get; its exact original-bank payment therefore stays Held.
            carrier.value186 = String.fromUtf8(selected.provider.toArray())
            carrier.value186
        } finally { nativeTextDebtLock186.unlock() }
    }
    // Every publicly exported text has its own original-bank copy and
    // intrusive payment carrier. No exported String shares the view's private
    // metadata allocation, and unknown consumers never authorize its refund.
    private let publicTextDebtLock186 = Mutex()
    private var publicTextDebt186: ?HostCanonicalPublicTextDebt186 = None<HostCanonicalPublicTextDebt186>
    private var pendingPublicText186: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    func copiedPublicTextFrame186(selected: HostCanonicalProjectionSelection173, index: Int64): String {
        publicTextDebtLock186.lock(); try {
            if (pendingPublicText186.isSome()) { throw LogicalJsonPayloadError("unknown public configuration text construction remains paid") }
            let source = match (index) {
                case 0 => selected.namespace; case 1 => selected.packageDigest; case 2 => selected.localTool; case 3 => selected.provider
                case 4 => selected.action; case 5 => selected.capability; case 6 => selected.effect; case 7 => selected.configurationDigest
                case _ => throw IllegalArgumentException("configuration text index is outside its fixed fields") }
            if (source.size > (Int64.Max - 16384) / 8) { throw LogicalJsonPayloadError("public configuration text invoice overflow") }
            let payment = selected.deriveDataPayment173(16384 + source.size * 8)
            pendingPublicText186 = Some(payment)
            let carrier = HostCanonicalPublicTextDebt186(payment, publicTextDebt186)
            publicTextDebt186 = Some(carrier); pendingPublicText186 = None<LogicalJsonOwnerReservation>
            carrier.value186 = String.fromUtf8(source.toArray())
            carrier.value186
        } finally { publicTextDebtLock186.unlock() }
    }
    func publicTextDebtCount186(): Int64 {
        publicTextDebtLock186.lock(); try {
            var result: Int64 = 0; var current = publicTextDebt186
            while (current.isSome()) { result++; current = current.getOrThrow().next186 }
            result
        } finally { publicTextDebtLock186.unlock() }
    }
    private let copyDebtLock186 = Mutex()
    private var copyDebt186: ?HostCanonicalProjectionCopy173 = None<HostCanonicalProjectionCopy173>
    func holdPreparedCopy186(value: HostCanonicalProjectionCopy173): Unit {
        // A separate lock prevents the original selection lock -> debt-link
        // path from reversing the cache -> selection retirement lock order.
        copyDebtLock186.lock()
        try { value.next186 = copyDebt186; copyDebt186 = Some(value) }
        finally { copyDebtLock186.unlock() }
    }
    private var owned186: ?HostCanonicalConfigurationOwner186 = None<HostCanonicalConfigurationOwner186>
    private var pendingOwnedPayment186: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private let lock = Mutex()
    private let snapshots = ArrayList<HostCanonicalProjectionSelection173>()
    func retainedExecutionCellCount173(): Int64 {
        lock.lock()
        try {
            var count: Int64 = 0
            for (index in 0..snapshots.size) { count += snapshots[index].retainedExecutionCellCount173() }
            count
        } finally { lock.unlock() }
    }
    func registerOwnedData186(payment: LogicalJsonOwnerReservation): HostCanonicalConfigurationOwner186 {
        lock.lock(); try { registerOwnedDataFrame186(payment) } finally { lock.unlock() }
    }
    private func registerOwnedDataFrame186(payment: LogicalJsonOwnerReservation): HostCanonicalConfigurationOwner186 {
        if (pendingOwnedPayment186.isSome()) { throw LogicalJsonPayloadError("unknown canonical owner construction remains paid") }
        pendingOwnedPayment186 = Some(payment)
        let owner = HostCanonicalConfigurationOwner186(this, payment, owned186)
        owned186 = Some(owner)
        pendingOwnedPayment186 = None<LogicalJsonOwnerReservation>
        owner
    }
    func ownedDataCount186(): Int64 {
        lock.lock(); try {
            var count: Int64 = 0; var current = owned186
            while (current.isSome()) { count++; current = current.getOrThrow().next186 }
            count
        } finally { lock.unlock() }
    }
    func loadOwned186(host: HostJavaScriptPluginHost, settingsRoot: String, namespace: String,
        packageDigest: String, localTool: String, generation: UInt64): Result<?HostOwnedCanonicalProjectionSelection186> {
        lock.lock()
        try {
            if (pendingOwnedPayment186.isSome()) { throw LogicalJsonPayloadError("unknown canonical owner construction remains paid") }
            let descriptor = match (host.servicePackage(namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let payment = try { descriptor.deriveCopiedDataPayment(1048576) } finally { descriptor.close() }
            let owner = registerOwnedDataFrame186(payment)
            try { loadOwnedFrame186(host, settingsRoot, namespace, packageDigest, localTool, generation, payment, owner) }
            catch (error: Exception) { owner.holdUnknown186(); throw error }
            finally {
                // Only the enclosing complete load frame may detach unused
                // parser/FD/constructor data; a published owner stays indexed.
                let returned = takeUnusedOwnedLoad186(owner)
                match (returned) { case Some(value) => value.close(); case None => () }
            }
        } catch (_: Exception) { hostPluginResourceError("plugin.canonical_projection_selection_invalid",
            "operator canonical-data selection could not be captured in its original installed bank") }
        finally { lock.unlock() }
    }
    private func loadOwnedFrame186(host: HostJavaScriptPluginHost, settingsRoot: String, namespace: String,
        packageDigest: String, localTool: String, generation: UInt64, payment: LogicalJsonOwnerReservation,
        owner: HostCanonicalConfigurationOwner186): Result<?HostOwnedCanonicalProjectionSelection186> {
                var names = settingsRoot.size
                for (size in [namespace.size, packageDigest.size, localTool.size]) {
                    if (names > Int64.Max - size) { throw LogicalJsonPayloadError("canonical selection metadata overflow") }
                    names += size }
                if (names > (Int64.Max - 1048576) / 8) { throw LogicalJsonPayloadError("canonical selection metadata overflow") }
                payment.ensureRetainedPeak(1048576 + names * 8)
                if (settingsRoot == "") { return Result<?HostOwnedCanonicalProjectionSelection186>.Ok(None<HostOwnedCanonicalProjectionSelection186>) }
                let root = canonicalize(Path(settingsRoot))
                let directory = root.join("plugins")
                let file = directory.join("canonical-data.json")
                if (!exists(directory) || !exists(file)) {
                    return Result<?HostOwnedCanonicalProjectionSelection186>.Ok(None<HostOwnedCanonicalProjectionSelection186>) }
                if (FileInfo(directory).isSymbolicLink() || !FileInfo(directory).isDirectory() ||
                    FileInfo(file).isSymbolicLink() || !FileInfo(file).isRegular()) {
                    return hostPluginResourceError("plugin.canonical_projection_selection_invalid", "operator selection must not follow a directory or file symlink") }
                let path = file.toString()
                var current186 = owned186
                while (current186.isSome()) {
                    let candidate186 = current186.getOrThrow()
                    if (candidate186.matches186(namespace, packageDigest, localTool, generation)) {
                        return Result.Ok(Some(candidate186.retain186())) }
                    current186 = candidate186.next186
                }
                let witness = match (hostReadResourceWitness(path)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                let bytes = Int64.parse(witness.split(":")[4])
                if (!witness.startsWith("f:") || bytes < 1 || bytes > 65536) {
                    return hostPluginResourceError("plugin.canonical_projection_selection_invalid",
                        "canonical-data selection must be an exact bounded regular file") }
                payment.ensureRetainedPeak(1048576 + names * 8 + bytes * 16)
                let temporary = Directory.createTemp("/tmp")
                let encoded: String
                try {
                    let target = temporary.join("canonical-data-selection")
                    let copied = match (hostReadResourceCopy(path, witness, target.toString(), bytes)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                    if (copied != bytes) { return hostPluginResourceError("plugin.canonical_projection_selection_changed",
                        "the operator file changed while its exact FD witness was captured") }
                    encoded = String.fromUtf8(File.readFrom(target))
                } finally { remove(temporary, recursive: true) }
                let nodes = logicalJsonNodeCount(encoded)
                payment.ensureRetainedPeak(1048576 + names * 8 + bytes * 16 + nodes * 512)
                let document = match (hostParseCanonicalConfigurationData186(encoded)) {
                    case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                let selected = match (hostCanonicalProjectionSelection173(document, namespace, packageDigest, localTool)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                if (selected.isNone()) { return Result<?HostOwnedCanonicalProjectionSelection186>.Ok(Option<HostOwnedCanonicalProjectionSelection186>.None) }
                // Copy only after extending this exact existing child. The
                // original snapshot/DOM/FD invoice remains fully paid; the
                // extra bytes cover both UTF8 arrays and independent Strings.
                var identityCopyInvoice159: Int64 = 0
                for (_ in 0..namespace.size) { identityCopyInvoice159 = hostRegistryAdd81(identityCopyInvoice159, 8) }
                for (_ in 0..packageDigest.size) { identityCopyInvoice159 = hostRegistryAdd81(identityCopyInvoice159, 8) }
                payment.ensureRetainedPeak(hostRegistryAdd81(
                    1048576 + names * 8 + bytes * 16 + nodes * 512, identityCopyInvoice159))
                let snapshot = HostCanonicalProjectionSelection173(path, encoded, witness, namespace,
                    packageDigest, generation, selected.getOrThrow(), payment)
                match (snapshot.validateCurrent173()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                owner.publish186(snapshot)
                return Result.Ok(Some(owner.retain186()))
    }
    private func takeUnusedOwnedLoad186(owner: HostCanonicalConfigurationOwner186): ?LogicalJsonOwnerReservation {
        if (!owner.unusedReturned186()) { return None<LogicalJsonOwnerReservation> }
        unlinkOwned186(owner)
        owner.takePayment186()
    }
    private func unlinkOwned186(owner: HostCanonicalConfigurationOwner186): Unit {
        var previous: ?HostCanonicalConfigurationOwner186 = None<HostCanonicalConfigurationOwner186>
        var current = owned186
        while (current.isSome()) {
            let actual = current.getOrThrow()
            if (refEq(actual, owner)) {
                match (previous) { case Some(value) => value.next186 = actual.next186; case None => owned186 = actual.next186 }
                actual.next186 = None<HostCanonicalConfigurationOwner186>
                return
            }
            previous = current; current = actual.next186
        }
        throw IllegalStateException("canonical private DATA owner was not indexed")
    }
    func returnOwnedView186(owner: HostCanonicalConfigurationOwner186,
        returned: HostOwnedCanonicalProjectionSelection186): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            owner.returnView186(returned)
            if (!owner.canRetire186()) { return None<LogicalJsonOwnerReservation> }
            unlinkOwned186(owner)
            owner.takePayment186()
        } finally { lock.unlock() }
    }
    func load(host: HostJavaScriptPluginHost, settingsRoot: String, namespace: String,
        packageDigest: String, localTool: String, generation: UInt64): Result<?HostCanonicalProjectionSelection173> {
        lock.lock()
        try {
            let descriptor = match (host.servicePackage(namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let payment = try { descriptor.deriveCopiedDataPayment(1048576) } finally { descriptor.close() }
            var retained = false
            try {
                var names = settingsRoot.size
                for (size in [namespace.size, packageDigest.size, localTool.size]) {
                    if (names > Int64.Max - size) { throw LogicalJsonPayloadError("canonical selection metadata overflow") }
                    names += size }
                if (names > (Int64.Max - 1048576) / 8) { throw LogicalJsonPayloadError("canonical selection metadata overflow") }
                payment.ensureRetainedPeak(1048576 + names * 8)
                if (settingsRoot == "") { return Result<?HostCanonicalProjectionSelection173>.Ok(None<HostCanonicalProjectionSelection173>) }
                let root = canonicalize(Path(settingsRoot))
                let directory = root.join("plugins")
                let file = directory.join("canonical-data.json")
                if (!exists(directory) || !exists(file)) {
                    return Result<?HostCanonicalProjectionSelection173>.Ok(None<HostCanonicalProjectionSelection173>) }
                if (FileInfo(directory).isSymbolicLink() || !FileInfo(directory).isDirectory() ||
                    FileInfo(file).isSymbolicLink() || !FileInfo(file).isRegular()) {
                    return hostPluginResourceError("plugin.canonical_projection_selection_invalid", "operator selection must not follow a directory or file symlink") }
                let path = file.toString()
                for (snapshot in snapshots where snapshot.namespace == namespace && snapshot.packageDigest == packageDigest &&
                    snapshot.localTool == localTool && snapshot.generation == generation) {
                    if (snapshot.validateCurrent173().isOk()) { return Result.Ok(Some(snapshot)) } }
                let witness = match (hostReadResourceWitness(path)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                let bytes = Int64.parse(witness.split(":")[4])
                if (!witness.startsWith("f:") || bytes < 1 || bytes > 65536) {
                    return hostPluginResourceError("plugin.canonical_projection_selection_invalid",
                        "canonical-data selection must be an exact bounded regular file") }
                payment.ensureRetainedPeak(1048576 + names * 8 + bytes * 16)
                let temporary = Directory.createTemp("/tmp")
                let encoded: String
                try {
                    let target = temporary.join("canonical-data-selection")
                    let copied = match (hostReadResourceCopy(path, witness, target.toString(), bytes)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                    if (copied != bytes) { return hostPluginResourceError("plugin.canonical_projection_selection_changed",
                        "the operator file changed while its exact FD witness was captured") }
                    encoded = String.fromUtf8(File.readFrom(target))
                } finally { remove(temporary, recursive: true) }
                let nodes = logicalJsonNodeCount(encoded)
                payment.ensureRetainedPeak(1048576 + names * 8 + bytes * 16 + nodes * 512)
                let document = parseUnifiedJson(encoded, maxBytes: 65536, maxDepth: 10)
                let selected = match (hostCanonicalProjectionSelection173(document, namespace, packageDigest, localTool)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                if (selected.isNone()) { return Result<?HostCanonicalProjectionSelection173>.Ok(Option<HostCanonicalProjectionSelection173>.None) }
                // Copy only after extending this exact existing child. The
                // original snapshot/DOM/FD invoice remains fully paid; the
                // extra bytes cover both UTF8 arrays and independent Strings.
                var identityCopyInvoice159: Int64 = 0
                for (_ in 0..namespace.size) { identityCopyInvoice159 = hostRegistryAdd81(identityCopyInvoice159, 8) }
                for (_ in 0..packageDigest.size) { identityCopyInvoice159 = hostRegistryAdd81(identityCopyInvoice159, 8) }
                payment.ensureRetainedPeak(hostRegistryAdd81(
                    1048576 + names * 8 + bytes * 16 + nodes * 512, identityCopyInvoice159))
                let snapshot = HostCanonicalProjectionSelection173(path, encoded, witness, namespace,
                    packageDigest, generation, selected.getOrThrow(), payment)
                match (snapshot.validateCurrent173()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                snapshots.add(snapshot); retained = true
                Result.Ok(Some(snapshot))
            } finally { if (!retained) { payment.close() } }
        } catch (_: Exception) { hostPluginResourceError("plugin.canonical_projection_selection_invalid",
            "operator canonical-data selection could not be captured in its original installed bank") }
        finally { lock.unlock() }
    }
}

// Strict parsing is only local operator configuration validation. Native
// request/output data never enters this function to acquire permission.
func hostCanonicalProjectionSelection173(document: AgentValue, namespace: String,
    packageDigest: String, localTool: String): Result<?AgentValue> {
    if (!httpIntentExactFields(document, ["version", "plugins"]) ||
        document.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
        document.field("version").getOrThrow().asNumberText() != "1" ||
        document.field("plugins").getOrThrow().unifiedKind != ValueKind.List ||
        document.field("plugins").getOrThrow().items.size > 64) {
        return hostPluginResourceError("plugin.canonical_projection_selection_invalid", "unsupported exact operator schema") }
    let namespaces = HashSet<String>(); var selected: ?AgentValue = Option<AgentValue>.None
    for (plugin in document.field("plugins").getOrThrow().items) {
        let name = httpIntentText(plugin, "namespace"); let digest = httpIntentText(plugin, "package_digest")
        if (!httpIntentExactFields(plugin, ["namespace", "package_digest", "tools"]) ||
            !httpServicePluginNamespace(name) || !httpServicePackageDigest(digest) || namespaces.contains(name) ||
            plugin.field("tools").getOrThrow().unifiedKind != ValueKind.List ||
            plugin.field("tools").getOrThrow().items.size > 128) {
            return hostPluginResourceError("plugin.canonical_projection_selection_invalid", "ambiguous actual installed package selection") }
        namespaces.add(name); let tools = HashSet<String>()
        for (tool in plugin.field("tools").getOrThrow().items) {
            let local = httpIntentText(tool, "name")
            if (!httpIntentExactFields(tool, ["name", "provider", "action", "capability", "effect"]) ||
                !hostDocumentLogicalName(local) || tools.contains(local) ||
                !hostDocumentLogicalName(httpIntentText(tool, "provider")) ||
                httpIntentText(tool, "action") != "canonical.context.project" ||
                httpIntentText(tool, "capability") != "workspace.read" || httpIntentText(tool, "effect") != "read_only") {
                return hostPluginResourceError("plugin.canonical_projection_selection_invalid", "unknown or duplicate exact operator action/capability/effect") }
            tools.add(local)
            if (name == namespace && digest == packageDigest && local == localTool) { selected = Some(tool) }
        }
    }
    Result.Ok(selected)
}


// Only a known parser exception is converted to the original closed error.
// The complete parser/exception helper returns before an unused original-bank
// configuration owner can clear its DATA and refund. Unexpected FD/native or
// construction failures still retain the exact actual pending owner.
func hostParseCanonicalConfigurationData186(encoded: String): Result<AgentValue> {
    try { Result<AgentValue>.Ok(parseUnifiedJson(encoded, maxBytes: 65536, maxDepth: 10)) }
    catch (_: JsonException) { hostPluginResourceError("plugin.canonical_projection_selection_invalid",
        "operator canonical-data selection could not be captured in its original installed bank") }
}

class HostCanonicalNativeTextDebt186 {
    let payment186: LogicalJsonOwnerReservation
    var value186: String = ""
    let next186: ?HostCanonicalNativeTextDebt186
    init(payment: LogicalJsonOwnerReservation, next: ?HostCanonicalNativeTextDebt186) {
        this.payment186 = payment; this.next186 = next
    }
}

// Only independent copy/payment/link remain reachable. In particular no
// private configuration, owned view, authority or callback is retained here.
class HostCanonicalPublicTextDebt186 {
    let payment186: LogicalJsonOwnerReservation
    var value186: String = ""
    let next186: ?HostCanonicalPublicTextDebt186
    init(payment: LogicalJsonOwnerReservation, next: ?HostCanonicalPublicTextDebt186) {
        this.payment186 = payment; this.next186 = next
    }
}
