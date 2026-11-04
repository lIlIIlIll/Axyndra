package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*

// An actual counted Catalog source loan, DATA only. Registration selection,
// exact source validation and execution still run through their original APIs.
// A Core control retains this scope through its existing caller/task witnesses.
public class ToolCatalogCoreDataScope204 {
    private let lock = Mutex()
    private var catalog: ?ToolCatalog
    private var pipeline: ?ToolPipeline
    private var core: ?PlanCopyDataConsumer204
    private var payment: ?LogicalJsonOwnerReservation
    private let run: RunId
    private var held = false
    private var returned = false
    private var returning = false
    private var firstMetadata204: ?PreparedMetadataOwner204 = None<PreparedMetadataOwner204>
    private var headers: Int64 = 0
    var nextPipeline204: ?ToolCatalogCoreDataScope204 = None<ToolCatalogCoreDataScope204>
    init(catalog: ToolCatalog, pipeline: ToolPipeline, core: PlanCopyDataConsumer204,
        run: RunId, payment: LogicalJsonOwnerReservation) {
        this.catalog = Some(catalog); this.pipeline = Some(pipeline); this.core = Some(core)
        this.run = RunId(copyTextData204(run.value)); this.payment = Some(payment)
    }
    func matches204(actual: ToolCatalog, actualRun: RunId, actualCore: PlanCopyDataConsumer204): Bool {
        lock.lock(); try { !returned && catalog.isSome() && core.isSome() &&
            refEq(catalog.getOrThrow(), actual) && samePlanCopyConsumer204(core.getOrThrow(), actualCore) && run.value == actualRun.value }
        finally { lock.unlock() }
    }
    func belongsToCatalog204(actual: ToolCatalog): Bool {
        lock.lock(); try { !returned && catalog.isSome() && refEq(catalog.getOrThrow(), actual) }
        finally { lock.unlock() }
    }
    func holdUnknown204(): Unit { lock.lock(); try { held = true } finally { lock.unlock() } }
    func retainPrepared204(value: PreparedToolInvocation): Unit {
        if (value.hasDetachedMetadata204()) { return }
        lock.lock(); try {
            if (returned || payment.isNone() || value.source.runId.value != run.value) {
                throw IllegalStateException("prepared DATA has no actual Core source loan") }
            if (headers > (Int64.Max - 16384) / 1024 - 1) { throw LogicalJsonPayloadError("Catalog DATA header invoice overflow") }
            payment.getOrThrow().ensureRetainedPeak(16384 + (headers + 1) * 1024); headers++
            let paid = payment.getOrThrow().deriveRetainedLease()
            try { paid.ensureRetainedPeak(131072) }
            catch (error: Exception) { paid.close(); throw error }
            // Register before constructing any independent metadata graph.
            let owner = PreparedMetadataOwner204(paid, core.getOrThrow())
            owner.next204 = firstMetadata204; firstMetadata204 = Some(owner)
            try { owner.installFrame204(value) }
            catch (error: Exception) { held = true; owner.holdUnknown204(); throw error }
        } finally { lock.unlock() }
    }
    func requireCanonicalOwnerBank204(owner: ToolCanonicalArgumentsOwner204): Unit {
        lock.lock(); try {
            if (returned || payment.isNone()) { throw IllegalStateException("Catalog DATA source has returned") }
            owner.requireSameBank204(payment.getOrThrow())
        } finally { lock.unlock() }
    }
    func copyCanonicalCall204(call: ToolCall, arguments: AgentValue): ToolCall {
        lock.lock(); try {
            let paid = copyPayment204(); let meter = ToolSnapshotMeasure159(paid)
            meter.addText159(call.callId); meter.addText159(call.name); meter.addValue159(arguments); meter.fund159()
            ToolCall(copyTextData204(call.callId), copyTextData204(call.name), copyJsonData204(arguments))
        } catch (error: Exception) { held = true; throw error }
        finally { lock.unlock() }
    }
    func copyPlan204(value: NormalizedOperationPlan): NormalizedOperationPlan {
        lock.lock(); try {
            if (returned || payment.isNone()) { throw IllegalStateException("Catalog DATA source has returned") }
            // The actual Core copied-plan ledger owns this independent graph
            // until the same complete Core task/caller frames have returned.
            let paid = core.getOrThrow().derivePlanWireAllocation204(run, 131072)
            core.getOrThrow().retainPlanReadAllocation204(run, paid)
            let meter = OwnedPreparedReferenceMeasure(paid, 131072)
            meter.planCopy204(value); paid.ensureRetainedPeak(meter.peak())
            copyPlanData204(value)
        } catch (error: Exception) { held = true; throw error }
        finally { lock.unlock() }
    }
    private func copyPayment204(): LogicalJsonOwnerReservation {
        if (returned || core.isNone()) { throw IllegalStateException("Catalog DATA source has returned") }
        let paid = core.getOrThrow().derivePlanWireAllocation204(run, 131072)
        core.getOrThrow().retainPlanReadAllocation204(run, paid); paid
    }
    func copyError204(value: AgentError): AgentError {
        lock.lock(); try {
            let paid = copyPayment204(); let meter = ToolSnapshotMeasure159(paid)
            meter.addText159(value.code); meter.addText159(value.message); meter.addSlots159(value.fields.size)
            for (field in value.fields) { meter.addText159(field.name); meter.addText159(field.value) }
            meter.fund159()
            // Opaque diagnostic owners stay on their existing physical source.
            // This route does not assert that those external graphs returned.
            if (value.attemptFailure.isSome() || value.observation.isSome()) { held = true }
            AgentError(value.kind, copyTextData204(value.code), copyTextData204(value.message), retryable: value.retryable,
                fallbackAllowed: value.fallbackAllowed, fields: value.fields.map { field => ErrorField(copyTextData204(field.name), copyTextData204(field.value)) },
                attemptFailure: value.attemptFailure, observation: value.observation)
        } catch (error: Exception) { held = true; throw error }
        finally { lock.unlock() }
    }
    func copyToolResult204(value: ToolResult): ToolResult {
        lock.lock(); try {
            let paid = copyPayment204(); let meter = ToolSnapshotMeasure159(paid)
            meter.addText159(value.callId); meter.addText159(value.receiptId); meter.addValue159(value.output); meter.fund159()
            if (value.payloadLease.isSome()) { held = true }
            ToolResult(copyTextData204(value.callId), copyJsonData204(value.output), isError: value.isError,
                receiptId: copyTextData204(value.receiptId), payloadLease: value.payloadLease)
        } catch (error: Exception) { held = true; throw error }
        finally { lock.unlock() }
    }
    func copyDenial204(value: ToolDenial): ToolDenial {
        // call identity is caller-owned; the error is the only registration-
        // callback output. Its complete copy helper returns before this DTO.
        ToolDenial(value.callId, value.toolName, copyError204(value.reason))
    }
    // Only Core's actual existing collector calls this after all its real
    // request frames, task witnesses and pending execution/ACK consumers return.
    public func returnWholeCoreFrame204(): Bool {
        lock.lock()
        let links = try {
            if (held || returning) { return false }
            if (returned) { return true }
            returning = true
            (pipeline.getOrThrow(), catalog.getOrThrow())
        } finally { lock.unlock() }
        try {
            links[0].removeCoreCatalogDataScope204(this)
            links[1].coreDataSourceReturned204()
            while (firstMetadata204.isSome()) {
                let value = firstMetadata204.getOrThrow(); firstMetadata204 = value.next204
                value.next204 = None<PreparedMetadataOwner204>; value.producerReturned204()
            }
            payment.getOrThrow().close()
            lock.lock(); try {
                payment = None<LogicalJsonOwnerReservation>; pipeline = None<ToolPipeline>
                catalog = None<ToolCatalog>; core = None<PlanCopyDataConsumer204>
                returned = true; returning = false
            } finally { lock.unlock() }
            true
        } catch (error: Exception) {
            lock.lock(); try { held = true; returning = false } finally { lock.unlock() }
            // Cleanup uncertainty cannot make a subsequent call report a
            // successful return or let the original Catalog backing retire.
            links[1].recordUnknownConsumer204()
            throw error
        }
    }
}
