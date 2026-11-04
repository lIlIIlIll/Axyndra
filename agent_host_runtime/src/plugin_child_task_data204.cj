package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*
import std.collection.*
import yjson.*
import yjson_support.*

// Descriptive Task history only. This object owns neither Source nor a plan,
// executor, grant or launch callback. Its payment derives from the actual
// installed configuration, before any independent history copy is built.
class HostTaskHistory204 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var data: ?AgentValue
    private var readers: Int64 = 0
    private var exported = false
    init(payment: LogicalJsonOwnerReservation, data: AgentValue) {
        this.payment = Some(payment); this.data = Some(data)
    }
    func withData<T>(body: (AgentValue) -> T): T {
        let actual: AgentValue
        lock.lock()
        try {
            if (payment.isNone() || data.isNone() || readers == Int64.Max) {
                throw IllegalStateException("Task descriptive history has returned")
            }
            readers++; actual = data.getOrThrow()
        } finally { lock.unlock() }
        try { body(actual) } finally { lock.lock(); try { readers-- } finally { lock.unlock() } }
    }
    // Existing raw history exports have no retirement acknowledgement. Keep
    // their real payment rather than treating callback return as consumer ACK.
    func exportDefinition(): AgentValue {
        lock.lock()
        try {
            if (payment.isNone() || data.isNone()) { throw IllegalStateException("Task descriptive history has returned") }
            exported = true
            data.getOrThrow().field("definition").getOrThrow()
        } finally { lock.unlock() }
    }
    private func clearReturnedFrame(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (readers != 0 || exported) { return None<LogicalJsonOwnerReservation> }
            data = None<AgentValue>
            let actual = payment; payment = None<LogicalJsonOwnerReservation>; actual
        } finally { lock.unlock() }
    }
    func readersReturned204(): Bool { lock.lock(); try { readers == 0 } finally { lock.unlock() } }
    func isReturned204(): Bool { lock.lock(); try { payment.isNone() } finally { lock.unlock() } }
    func retireAfterCompleteTaskFrame(): Bool {
        let actual = clearReturnedFrame()
        match (actual) { case Some(value) => value.close(); true
            case None => lock.lock(); try { payment.isNone() } finally { lock.unlock() } }
    }
}

func copyHostTaskHistory204(configuration: HostPrimitiveConfiguration111,
    prepared: PreparedToolInvocation, call: ToolCall, plan: NormalizedOperationPlan): HostTaskHistory204 {
    let payment = configuration.deriveDataPayment191(65536)
    try {
        let producer = configuration.inputTemporaryPayment111(1048576)
        try { copyHostTaskHistoryFrame204(payment, producer, prepared, call, plan) }
        finally { producer.close() }
    } catch (error: Exception) { payment.close(); throw error }
}

private func copyHostTaskHistoryFrame204(payment: LogicalJsonOwnerReservation,
    producer: LogicalJsonOwnerReservation, prepared: PreparedToolInvocation, call: ToolCall,
    plan: NormalizedOperationPlan): HostTaskHistory204 {
    let intent = plan.canonicalArguments.field("intent").getOrThrow()
    let input = intent.field("input").getOrThrow()
    let definition = if (input.field("resume").isSome()) {
        let proposal = input.field("resume").getOrThrow().field("proposal").getOrThrow()
        objectValue([ValueField("request", proposal.field("request").getOrThrow()),
            ValueField("completion", proposal.field("completion").getOrThrow())])
    } else { input }
    let history = objectValue([
        ValueField("call_id", textValue(call.callId)),
        ValueField("operation_id", textValue(prepared.operationId.value)),
        ValueField("parent_call_id", textValue(httpIntentText(plan.canonicalArguments.field("binding").getOrThrow(), "parent_call_id"))),
        ValueField("parent_operation_id", match (prepared.source.parentOperationId) {
            case Some(value) => textValue(value.value); case None => nullValue() }),
        ValueField("service", intent.field("service").getOrThrow()),
        ValueField("intent_id", intent.field("id").getOrThrow()),
        ValueField("binding", textValue(canonicalAgentValue(plan.canonicalArguments.field("binding").getOrThrow()))),
        ValueField("definition", definition)])
    let bytes = logicalJsonWriteReservationBytes(history, 8388608)
    let nodes = logicalJsonValueNodeCount(history)
    if (bytes > (Int64.Max - 1048576) / 16 || nodes > (Int64.Max - 1048576 - bytes * 16) / 512) {
        throw LogicalJsonPayloadError("Task history invoice overflow")
    }
    let invoice = bytes * 16 + nodes * 512
    payment.ensureRetainedPeak(invoice + 65536)
    producer.ensureRetainedPeak(invoice + 1048576)
    let encoded = encodeAgentValue(history)
    HostTaskHistory204(payment, parseUnifiedJson(encoded, maxBytes: 8388608))
}

// Independent prepaid Native input copy. Its real complete invocation reader
// returns before the caller closes this owner; no prepared DOM is exported.
func copyHostTaskInvocationInput204(configuration: HostPrimitiveConfiguration111,
    plan: NormalizedOperationPlan): HostTaskHistory204 {
    let payment = configuration.deriveDataPayment191(65536)
    try {
        let producer = configuration.inputTemporaryPayment111(1048576)
        try { copyHostTaskInvocationFrame204(payment, producer, plan.canonicalArguments) }
        finally { producer.close() }
    } catch (error: Exception) { payment.close(); throw error }
}
private func copyHostTaskInvocationFrame204(payment: LogicalJsonOwnerReservation,
    producer: LogicalJsonOwnerReservation, source: AgentValue): HostTaskHistory204 {
    let bytes = logicalJsonWriteReservationBytes(source, 8388608)
    let nodes = logicalJsonValueNodeCount(source)
    if (bytes > (Int64.Max - 1048576) / 16 || nodes > (Int64.Max - 1048576 - bytes * 16) / 512) {
        throw LogicalJsonPayloadError("Task invocation invoice overflow")
    }
    let invoice = bytes * 16 + nodes * 512
    payment.ensureRetainedPeak(invoice + 65536)
    producer.ensureRetainedPeak(invoice + 1048576)
    let encoded = encodeAgentValue(source)
    HostTaskHistory204(payment, parseUnifiedJson(encoded, maxBytes: 8388608))
}

func hostWorkflowTaskDataSelected204(host: HostJavaScriptPluginHost, namespace: String,
    localTool: String, generation: UInt64): Bool {
    if (namespace != "axyndra:workflow" || localTool != "task") { return false }
    match (host.primitiveConfiguration111(namespace, localTool, generation)) {
        case Result.Ok(Some(value)) => value.supervisedTaskServices191(localTool)
        case _ => false
    }
}

// Separate DATA lifetimes: historical state/header copies remain funded while
// ordinary post-close snapshots can read them; physical-worker-only metadata
// can retire after the actual producer and all its private aliases return.
class HostTaskMetadataLedger204 {
    private let lock = Mutex()
    private var root: ?LogicalJsonOwnerReservation
    private let payments = ArrayList<LogicalJsonOwnerReservation>()
    init(root: LogicalJsonOwnerReservation) { this.root = Some(root) }
    func retain(bytes: Int64): Unit {
        if (bytes < 1 || bytes > Int64.Max - 4096) { throw LogicalJsonPayloadError("Task metadata invoice overflow") }
        lock.lock()
        try {
            let original = root.getOrThrow()
            if (payments.size > (Int64.Max - 65536) / 64) { throw LogicalJsonPayloadError("Task metadata ledger overflow") }
            original.ensureRetainedPeak(65536 + (payments.size + 1) * 64)
            let child = original.deriveRetainedLease()
            var retained = false
            try {
                child.ensureRetainedPeak(bytes + 4096)
                payments.add(child); retained = true
            } finally { if (!retained) { child.close() } }
        } finally { lock.unlock() }
    }
    func copyText(text: String): String {
        if (text.size > (Int64.Max - 8192) / 6) { throw LogicalJsonPayloadError("Task state text invoice overflow") }
        retain(text.size * 6 + 8192)
        String.fromUtf8(text.toArray())
    }
    func isPaid(): Bool { lock.lock(); try { root.isSome() } finally { lock.unlock() } }
    func isReturned(): Bool { lock.lock(); try { root.isNone() } finally { lock.unlock() } }
    private func clearReturnedFrame(): Array<LogicalJsonOwnerReservation> {
        lock.lock()
        try {
            if (root.isNone()) { return [] }
            let count = payments.size
            let original = root.getOrThrow()
            let values = Array<LogicalJsonOwnerReservation>(count + 1, { index =>
                if (index == count) { original } else { payments[index] } })
            payments.clear(); root = None<LogicalJsonOwnerReservation>
            values
        } finally { lock.unlock() }
    }
    func returnAfterPrivateConsumers(): Unit {
        let returned = clearReturnedFrame()
        for (payment in returned) { payment.close() }
    }
}
func createHostTaskMetadataLedger204(configuration: HostPrimitiveConfiguration111): HostTaskMetadataLedger204 {
    let root = configuration.deriveDataPayment191(65536)
    try { HostTaskMetadataLedger204(root) } catch (error: Exception) { root.close(); throw error }
}

// Private DATA readers only. The source is another real projection consumer
// guard, never a Source, launch grant, receipt or Task completion fact.
class HostTaskExecutorDataReaders204 {
    private let lock = Mutex()
    private var readers: Int64 = 0
    private var source: ?HostTaskExecutorDataReaders204 = None<HostTaskExecutorDataReaders204>
    func beginFrame204(): Unit {
        lock.lock(); try {
            if (readers == Int64.Max) { throw LogicalJsonPayloadError("Task executor reader overflow") }
            readers++
        } finally { lock.unlock() }
    }
    func borrowSourceFrame204(actual: HostTaskExecutorDataReaders204): Unit {
        if (refEq(actual, this)) { return }
        lock.lock(); try {
            if (readers <= 0 || source.isSome()) { throw IllegalStateException("Task output source reader is unavailable") }
            actual.beginFrame204()
            source = Some(actual)
        } finally { lock.unlock() }
    }
    private func detachReturnedFrame204(): ?HostTaskExecutorDataReaders204 {
        lock.lock(); try {
            if (readers <= 0) { throw IllegalStateException("Task executor reader was not borrowed") }
            readers--
            let actual = source; source = None<HostTaskExecutorDataReaders204>; actual
        } finally { lock.unlock() }
    }
    func returnCompleteFrame204(): Unit {
        // The complete alias-clearing helper returns before the source loan.
        let actual = detachReturnedFrame204()
        match (actual) { case Some(value) => value.returnCompleteFrame204(); case None => () }
    }
    func readersReturned204(): Bool { lock.lock(); try { readers == 0 } finally { lock.unlock() } }
}
