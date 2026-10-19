package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_plugin_registry.*
import agent_sdk.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

// This selection is operator data, not a Source or a delegation grant. Actual
// ToolPipeline capabilities, canonical ParentIntent and Kernel child admission
// remain independently mandatory. A package's service union is never consulted.
class HostPrimitiveConfiguration111 {
    let namespace: String
    let packageDigest: String
    let digest: String
    private let path: String
    private let encoded: String
    private let witness: String
    private let selections: AgentValue
    // Legacy Tool descriptors can retain closures and raw immutable Strings.
    // The mounted Host retains this actual same-bank child for those aliases;
    // returning a helper or closing a worker does not refund configuration data.
    private let payment: LogicalJsonOwnerReservation
    private let validationLock = Mutex()
    private let planLock = Mutex()
    private let copiedPlans = ArrayList<HostPrimitivePlanData111>()
    private var failures172: ?ArrayList<HostPrimitiveFailureData172> = None<ArrayList<HostPrimitiveFailureData172>>
    private var pendingFailurePayment172: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var pendingFailure172: ?HostPrimitiveFailureData172 = None<HostPrimitiveFailureData172>
    private var independentDebtCache191: ?HostPrimitiveConfigurationCache111 = None<HostPrimitiveConfigurationCache111>
    init(path: String, encoded: String, witness: String, namespace: String,
        packageDigest: String, selections: AgentValue, payment: LogicalJsonOwnerReservation) {
        this.path = path; this.encoded = encoded; this.witness = witness
        this.namespace = namespace; this.packageDigest = packageDigest; this.selections = selections
        this.payment = payment
        digest = modelPolicySha256Text(encoded + "\n" + witness)
    }
    func linkIndependentDebtCache191(cache: HostPrimitiveConfigurationCache111): Unit {
        planLock.lock(); try {
            if (independentDebtCache191.isSome()) { throw IllegalStateException("owned Primitive debt cache publication repeated") }
            independentDebtCache191 = Some(cache)
        } finally { planLock.unlock() }
    }
    func clearReturnedIndependentDebtCache191(): Unit {
        planLock.lock(); try { independentDebtCache191 = None<HostPrimitiveConfigurationCache111> }
        finally { planLock.unlock() }
    }
    func deriveDataPayment191(invoice: Int64): LogicalJsonOwnerReservation {
        if (invoice < 1) { throw IllegalArgumentException("primitive DATA payment must be positive") }
        let actual = payment.deriveRetainedLease()
        try { actual.ensureRetainedPeak(invoice); actual }
        catch (error: Exception) { actual.close(); throw error }
    }
    func canRetireOwnedData191(): Bool {
        planLock.lock(); try {
            copiedPlans.isEmpty() && processProjections180.isEmpty() && pendingProcessProjection180.isNone() &&
                pendingFailurePayment172.isNone() && pendingFailure172.isNone() &&
                (failures172.isNone() || failures172.getOrThrow().isEmpty())
        } finally { planLock.unlock() }
    }
    func same(path: String, encoded: String, witness: String, namespace: String, packageDigest: String): Bool {
        this.path == path && this.encoded == encoded && this.witness == witness &&
            this.namespace == namespace && this.packageDigest == packageDigest
    }
    func permits(localTool: String): Bool {
        for (entry in selections.items where httpIntentText(entry, "name") == localTool) { return true }
        false
    }
    func permitsService(localTool: String, service: String): Bool {
        for (entry in selections.items where httpIntentText(entry, "name") == localTool) {
            for (selected in entry.field("services").getOrThrow().items where selected.text == service) { return true }
        }
        false
    }
    private func selectedEntry(localTool:String):AgentValue {
        for(entry in selections.items where httpIntentText(entry,"name")==localTool){return entry}
        throw IllegalStateException("no actual selected primitive contribution")
    }
    func invocationName(localTool:String,service!:String=""):String {
        let entry=selectedEntry(localTool)
        let selection=entry.field("invocation_capability") ?? textValue("extension.invoke")
        if(selection.unifiedKind==ValueKind.Text){return selection.text}
        if(service==""){return httpIntentText(selection,"catalog")}
        let values=selection.field("services").getOrThrow()
        return httpIntentText(values,service)
    }
    func invocationCapability(localTool:String,service!:String=""):Capability {
        hostPrimitiveCapability111(invocationName(localTool,service:service),namespace)
    }
    func mappedInvocation(localTool:String):Bool {
        (selectedEntry(localTool).field("invocation_capability") ?? nullValue()).unifiedKind==ValueKind.Object
    }
    func additionalCapabilities(localTool:String):Array<Capability> {
        // This is ONLY the static catalog visibility contract. Actual calls
        // resolve their own exact Host-frozen service and its capability.
        if(mappedInvocation(localTool)){return []}
        if(invocationName(localTool)=="extension.invoke"){return requiredCapabilities(localTool)}
        []
    }
    func requiredCapabilities(localTool:String):Array<Capability> {
        let services=selectedEntry(localTool).field("services").getOrThrow()
        [Capability(pluginPrimitiveRequiredCapability111(services.items[0].text))]
    }
    func callerAllows(localTool:String,capabilities:CapabilitySet,service!:String=""):Bool {
        if(service!="") {
            if(!permitsService(localTool,service)){return false}
            let invoked=invocationCapability(localTool,service:service)
            return capabilities.allows(invoked.kind,resource:invoked.resource) &&
                capabilities.allows(pluginPrimitiveRequiredCapability111(service)) }
        // Pure preparation can run only when at least one exact selected
        // service is eligible. Its returned service is checked again before
        // it becomes a canonical plan; this is never effect authorization.
        for(value in selectedEntry(localTool).field("services").getOrThrow().items) {
            if(callerAllows(localTool,capabilities,service:value.text)){return true} }
        false
    }
    func resolvedInvocationCapability(localTool:String,arguments:AgentValue):Capability {
        let service=pluginPrimitiveArgumentsService111(arguments)
        if(!permitsService(localTool,service) || pluginPrimitiveInvocationName111(arguments)!=invocationName(localTool,service:service)) {
            return Capability(CapabilityKind.ExtensionInvoke,resource:namespace) }
        invocationCapability(localTool,service:service)
    }
    func resolvedAdditionalCapabilities(localTool:String,arguments:AgentValue):Array<Capability> {
        let service=pluginPrimitiveArgumentsService111(arguments)
        if(!permitsService(localTool,service) || pluginPrimitiveInvocationName111(arguments)!=invocationName(localTool,service:service)) {
            return [Capability(CapabilityKind.ExtensionInvoke,resource:namespace)] }
        pluginPrimitiveAdditionalCapabilities111(arguments)
    }
    // The installed original map, never Native result data, chooses this
    // permission for a no-effect completion. Caller capability is rechecked.
    func preparedCompletionPermission152(localTool: String): String {
        selectedEntry(localTool).field("services").getOrThrow().items[0].text
    }
    func preparationProvider(localTool: String): String {
        for (entry in selections.items where httpIntentText(entry, "name") == localTool) {
            return httpIntentText(entry, "preparation_provider") }
        ""
    }
    // Lexical encoding/verified-FD work derives from THIS installed snapshot's
    // real allocation. It cannot acquire a second pool or grant an input ref.
    private var pendingProcessProjection180:?LogicalJsonOwnerReservation=None
    private let processProjections180=ArrayList<HostPaidValueProjection151>()
    func retainProcessProjection180():HostPaidValueProjection151{
        planLock.lock()
        try{
            if(pendingProcessProjection180.isSome()){throw IllegalStateException("an original process projection allocation remains held")}
            let child=payment.deriveRetainedLease();pendingProcessProjection180=Some(child)
            if(processProjections180.size>(Int64.Max-1048576)/4096){throw LogicalJsonPayloadError("process projection registry SUM overflow")}
            child.ensureRetainedPeak(processProjections180.size*4096+1048576)
            let meter=HostPaidValueProjection151(child)
            processProjections180.add(meter);pendingProcessProjection180=None<LogicalJsonOwnerReservation>
            meter
        }finally{planLock.unlock()}
    }
    func inputTemporaryPayment111(bytes:Int64):LogicalJsonOwnerReservation {
        if(bytes<1){throw IllegalArgumentException("input payment must be positive")}
        let loan=payment.deriveRetainedLease()
        try{loan.ensureRetainedPeak(max(1048576,bytes));loan}
        catch(error:Exception){loan.close();throw error}
    }

    func copyPreparedPlan(value: AgentValue): AgentValue {
        let bytes = logicalJsonWriteReservationBytes(value, 8388608)
        let nodes = logicalJsonValueNodeCount(value)
        let loan = payment.deriveRetainedLease()
        var retained = false
        try {
            // Encoding, decode input and returned DOM overlap. Count every
            // occurrence before making the independent raw copy.
            loan.ensureRetainedPeak(bytes * 16 + nodes * 512 + 1048576)
            let frozen = parseUnifiedJson(encodeAgentValue(value), maxBytes: 8388608)
            let data = HostPrimitivePlanData111(loan, frozen)
            planLock.lock()
            try { copiedPlans.add(data); retained = true }
            finally { planLock.unlock() }
            frozen
        } finally { if (!retained) { loan.close() } }
    }
    // Same installed allocation only. A completed physical worker does not
    // retire the retained data aliases of its request, future or callback.
    func retainWorkerMetadata111(bytes: Int64): Unit {
        if (bytes < 16384 || bytes > Int64.Max - 4096) {
            throw IllegalArgumentException("invalid actual worker metadata invoice") }
        let loan = payment.deriveRetainedLease()
        var retained = false
        try {
            loan.ensureRetainedPeak(bytes + 4096)
            let hold = HostPrimitivePlanData111(loan, nullValue())
            planLock.lock()
            try { copiedPlans.add(hold); retained = true } finally { planLock.unlock() }
        } finally { if (!retained) { loan.close() } }
    }

    func retainObservation(encodedCeiling: Int64, nodeCeiling: Int64, build: () -> AgentValue): AgentValue {
        if(encodedCeiling<1 || nodeCeiling<1 || encodedCeiling>Int64.Max/64 || nodeCeiling>Int64.Max/2048){
            throw IllegalArgumentException("observation accounting exceeds its representable invoice")}
        let loan=payment.deriveRetainedLease()
        var retained=false
        try {
            // Pay the original snapshot nodes and the independent codec copy
            // before constructing either graph. They share this installed bank.
            loan.ensureRetainedPeak(encodedCeiling*16+nodeCeiling*512+1048576)
            let value=build()
            if(logicalJsonWriteReservationBytes(value,8388608)>encodedCeiling ||
                logicalJsonValueNodeCount(value)>nodeCeiling){
                throw IllegalStateException("actual observation exceeded its prepaid shape")}
            let frozen=parseUnifiedJson(encodeAgentValue(value),maxBytes:8388608)
            let data=HostPrimitivePlanData111(loan,frozen)
            planLock.lock()
            try{copiedPlans.add(data);retained=true}finally{planLock.unlock()}
            frozen
        }finally{if(!retained){loan.close()}}
    }
    func retainFailure172(error: AgentError): AgentError {
        match (independentDebtCache191) {
            case Some(cache) => return cache.captureIndependentFailure191(this, error)
            case None => ()
        }
        // Register this real same-bank holder before any fallible complete
        // error capture. A raw error alias has no retirement receipt here.
        planLock.lock()
        let hold = try {
            if (pendingFailurePayment172.isSome()) { throw IllegalStateException("an unregistered paid failure holder remains pending") }
            let metadata=payment.deriveRetainedLease()
            pendingFailurePayment172=Some(metadata)
            let count=match(failures172){case Some(values)=>values.size;case None=>0}
            if(count>(Int64.Max-65536)/256){throw LogicalJsonPayloadError("retained failure metadata SUM overflow")}
            metadata.ensureRetainedPeak(count*256+65536)
            let actual=HostPrimitiveFailureData172(metadata,{ bytes => inputTemporaryPayment111(bytes) })
            pendingFailure172=Some(actual)
            if (failures172.isNone()) { failures172=Some(ArrayList<HostPrimitiveFailureData172>()) }
            failures172.getOrThrow().add(actual)
            pendingFailure172=None<HostPrimitiveFailureData172>
            pendingFailurePayment172=None<LogicalJsonOwnerReservation>
            actual
        } finally { planLock.unlock() }
        hold.capture(error)
    }
    func rootProcessConfiguration180(meter:HostPaidValueProjection151):AgentValue{
        validationLock.lock()
        try{
            var bytes:Int64=65536
            for(text in [path,encoded,witness,namespace,packageDigest,digest]){
                if(bytes>Int64.Max-text.size){throw LogicalJsonPayloadError("complete process configuration invoice overflow")}
                bytes+=text.size}
            meter.fundAdditional151(bytes,128)
            objectValue([ValueField("path",textValue(path)),ValueField("encoded",textValue(encoded)),
                ValueField("witness",textValue(witness)),ValueField("namespace",textValue(namespace)),
                ValueField("package_digest",textValue(packageDigest)),ValueField("configuration_digest",textValue(digest))])
        }finally{validationLock.unlock()}
    }

    func validateCurrent(): Result<Unit> {
        validationLock.lock()
        try {
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
        if (code != 0) { return hostPluginResourceError("plugin.primitive_selection_changed",
            "complete operator primitive selection changed after preparation") }
        Result.Ok(())
        } finally { validationLock.unlock() }
    }
}

// Raw ToolDescriptor/Prepared APIs have no consumer-retirement contract. This
// opt-in pilot keeps their copied graph funded, rather than using worker ACK or
// callback return as a false data ACK. Reclamation is explicitly not completed.
private class HostPrimitivePlanData111 {
    let payment: LogicalJsonOwnerReservation
    let value: AgentValue
    init(payment: LogicalJsonOwnerReservation, value: AgentValue) { this.payment = payment; this.value = value }
}

// A paid cache of immutable configuration bytes, never a second installed
// registry. It is scoped to the real Host and derives from the real installed
// descriptor's existing allocation custody. No fresh bank or floor is created.
class HostPrimitiveConfigurationCache111 {
    private let lock = Mutex()
    private let snapshots = ArrayList<HostPrimitiveConfiguration111>()
    func load(host: HostJavaScriptPluginHost, settingsRoot: String, namespace: String,
        packageDigest: String, generation: UInt64): Result<?HostPrimitiveConfiguration111> {
        let path = Path(settingsRoot).join("plugins").join("primitives.json").toString()
        // Missing configuration preserves all pre-existing mount behavior.
        // Any existing malformed/link/replaced file is an explicit refusal.
        if (!exists(path)) { return Result<?HostPrimitiveConfiguration111>.Ok(Option<HostPrimitiveConfiguration111>.None) }
        lock.lock()
        try {
            for (snapshot in snapshots where snapshot.namespace == namespace && snapshot.packageDigest == packageDigest) {
                if (snapshot.validateCurrent().isOk()) { return Result.Ok(Some(snapshot)) }
            }
            let descriptor = match (host.servicePackage(namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let payment = try { descriptor.deriveCopiedDataPayment(1048576) }
                finally { descriptor.close() }
            var retained = false
            try {
                let witness = match (hostReadResourceWitness(path)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                let bytes = Int64.parse(witness.split(":")[4])
                if (!witness.startsWith("f:") || bytes < 1 || bytes > 65536) {
                    return hostPluginResourceError("plugin.primitive_selection_invalid", "primitive selection must be a bounded regular file") }
                payment.ensureRetainedPeak(bytes * 16 + 1048576)
                let temporary = Directory.createTemp("/tmp")
                let encoded: String
                try {
                    let target = temporary.join("primitive-selection")
                    let copied = match (hostReadResourceCopy(path, witness, target.toString(), bytes)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                    if (copied != bytes) { return hostPluginResourceError("plugin.primitive_selection_changed", "selection changed during capture") }
                    encoded = String.fromUtf8(File.readFrom(target))
                } finally { remove(temporary, recursive: true) }
                let nodes = logicalJsonNodeCount(encoded)
                payment.ensureRetainedPeak(bytes * 16 + nodes * 512 + 1048576)
                let document = parseUnifiedJson(encoded, maxBytes: 65536, maxDepth: 10)
                let selected = match (hostPrimitiveSelections111(document, namespace, packageDigest)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                if (selected.isNone()) { return Result<?HostPrimitiveConfiguration111>.Ok(Option<HostPrimitiveConfiguration111>.None) }
                let value = HostPrimitiveConfiguration111(path, encoded, witness, namespace, packageDigest,
                    selected.getOrThrow(), payment)
                match (value.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                snapshots.add(value); retained = true
                Result.Ok(Some(value))
            } finally { if (!retained) { payment.close() } }
        } catch (_: Exception) { hostPluginResourceError("plugin.primitive_selection_invalid", "primitive selection could not be captured in its original data budget") }
        finally { lock.unlock() }
    }
    private var owned191: ?HostPrimitiveConfigurationOwner191 = None<HostPrimitiveConfigurationOwner191>
    private var pendingOwned191: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private let independentFailureLock191 = Mutex()
    private var independentFailures191: ?HostPrimitiveIndependentFailure191 = None<HostPrimitiveIndependentFailure191>
    private var independentFailureCount191: Int64 = 0
    private var pendingIndependentFailure191: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    func captureIndependentFailure191(data: HostPrimitiveConfiguration111, error: AgentError): AgentError {
        independentFailureLock191.lock()
        let holder = try {
            if (pendingIndependentFailure191.isSome()) { throw LogicalJsonPayloadError("unknown independent primitive failure construction remains paid") }
            if (independentFailureCount191 > (Int64.Max - 65536) / 256) { throw LogicalJsonPayloadError("retained failure metadata SUM overflow") }
            let metadata = data.deriveDataPayment191(independentFailureCount191 * 256 + 65536)
            pendingIndependentFailure191 = Some(metadata)
            let carrier = HostPrimitiveIndependentFailure191(metadata, independentFailures191)
            independentFailures191 = Some(carrier); independentFailureCount191++
            pendingIndependentFailure191 = None<LogicalJsonOwnerReservation>
            // The complete original failure consumer sees only this independently
            // paid allocator. Capturing it never retains the DATA backing.
            let actual = HostPrimitiveFailureData172(metadata, { bytes => hostPrimitiveFailureAllocation191(metadata, bytes) })
            carrier.actual191 = Some(actual)
            actual
        } finally { independentFailureLock191.unlock() }
        holder.capture(error)
    }
    func registerOwnedData191(payment: LogicalJsonOwnerReservation): HostPrimitiveConfigurationOwner191 {
        lock.lock(); try { registerOwned191(payment) } finally { lock.unlock() }
    }
    func heldIndependentFailureCount191(): Int64 {
        independentFailureLock191.lock(); try { independentFailureCount191 } finally { independentFailureLock191.unlock() }
    }
    private func registerOwned191(payment: LogicalJsonOwnerReservation): HostPrimitiveConfigurationOwner191 {
        if (pendingOwned191.isSome()) { throw LogicalJsonPayloadError("unknown primitive DATA construction remains paid") }
        pendingOwned191 = Some(payment)
        let result = HostPrimitiveConfigurationOwner191(this, payment, owned191)
        owned191 = Some(result); pendingOwned191 = None<LogicalJsonOwnerReservation>
        result
    }
    func loadCompatibility191(host: HostJavaScriptPluginHost, settingsRoot: String, namespace: String,
        packageDigest: String, generation: UInt64): Result<?HostPrimitiveConfiguration111> {
        let selected = match (loadOwned191(host, settingsRoot, namespace, packageDigest, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let result = primitiveCompatibilityWholeFrame191(selected)
        // Only the temporary private view/header is returned. Its opaque shell
        // was never given to the Raw consumer; real backing remains paid Held.
        match (selected) { case Some(value) => value.returnOwnedPrimitive191(); case None => () }
        Result.Ok(result)
    }
    private func primitiveCompatibilityWholeFrame191(selected: ?HostOwnedPrimitiveConfiguration191): ?HostPrimitiveConfiguration111 {
        match (selected) { case Some(value) => Some(value.exportCompatibilityHeld191()); case None => None<HostPrimitiveConfiguration111> }
    }
    func loadOwned191(host: HostJavaScriptPluginHost, settingsRoot: String, namespace: String,
        packageDigest: String, generation: UInt64): Result<?HostOwnedPrimitiveConfiguration191> {
        let path = Path(settingsRoot).join("plugins").join("primitives.json").toString()
        if (!exists(path)) { return Result<?HostOwnedPrimitiveConfiguration191>.Ok(None<HostOwnedPrimitiveConfiguration191>) }
        lock.lock(); try {
            if (pendingOwned191.isSome()) { throw LogicalJsonPayloadError("unknown primitive DATA construction remains paid") }
            var current = owned191
            while (current.isSome()) {
                let actual = current.getOrThrow()
                if (actual.matches191(namespace, packageDigest)) { return Result.Ok(Some(actual.retain191())) }
                current = actual.next191
            }
            let descriptor = match (host.servicePackage(namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let payment = try { descriptor.deriveCopiedDataPayment(1048576) }
                finally { descriptor.close() }
            let actual = registerOwned191(payment)
            try { loadOwnedFrame191(path, namespace, packageDigest, payment, actual) }
            catch (_: Exception) { actual.holdUnknown191(); hostPluginResourceError("plugin.primitive_selection_invalid",
                "primitive selection could not be captured in its original data budget") }
            finally {
                // The complete witness/FD/parser/publication helper returned.
                // Unknown exceptions or still-registered shares keep custody.
                let paid = retireReturnedData191(actual)
                match (paid) { case Some(value) => value.close(); case None => () }
            }
        } finally { lock.unlock() }
    }
    private func loadOwnedFrame191(path: String, namespace: String, packageDigest: String,
        payment: LogicalJsonOwnerReservation, owner: HostPrimitiveConfigurationOwner191): Result<?HostOwnedPrimitiveConfiguration191> {
                let witness = match (hostReadResourceWitness(path)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                let bytes = Int64.parse(witness.split(":")[4])
                if (!witness.startsWith("f:") || bytes < 1 || bytes > 65536) {
                    return hostPluginResourceError("plugin.primitive_selection_invalid", "primitive selection must be a bounded regular file") }
                payment.ensureRetainedPeak(bytes * 16 + 1048576)
                let temporary = Directory.createTemp("/tmp")
                let encoded: String
                try {
                    let target = temporary.join("primitive-selection")
                    let copied = match (hostReadResourceCopy(path, witness, target.toString(), bytes)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                    if (copied != bytes) { return hostPluginResourceError("plugin.primitive_selection_changed", "selection changed during capture") }
                    encoded = String.fromUtf8(File.readFrom(target))
                } finally { remove(temporary, recursive: true) }
                let nodes = logicalJsonNodeCount(encoded)
                payment.ensureRetainedPeak(bytes * 16 + nodes * 512 + 1048576)
                let document = match (hostParsePrimitiveConfiguration191(encoded)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                let selected = match (hostPrimitiveSelections111(document, namespace, packageDigest)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                if (selected.isNone()) { return Result<?HostOwnedPrimitiveConfiguration191>.Ok(Option<HostOwnedPrimitiveConfiguration191>.None) }
                let value = HostPrimitiveConfiguration111(path, encoded, witness, namespace, packageDigest,
                    selected.getOrThrow(), payment)
                match (value.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                owner.publish191(value)
                Result.Ok(Some(owner.retain191()))
    }
    private func retireReturnedData191(owner: HostPrimitiveConfigurationOwner191): ?LogicalJsonOwnerReservation {
        if (!owner.canRetire191()) { return None<LogicalJsonOwnerReservation> }
        var previous: ?HostPrimitiveConfigurationOwner191 = None<HostPrimitiveConfigurationOwner191>
        var current = owned191
        while (current.isSome()) {
            let actual = current.getOrThrow()
            if (refEq(actual, owner)) {
                let paid = actual.takePayment191()
                if (paid.isNone()) { return None<LogicalJsonOwnerReservation> }
                match (previous) { case Some(value) => value.next191 = actual.next191; case None => owned191 = actual.next191 }
                actual.next191 = None<HostPrimitiveConfigurationOwner191>
                return paid
            }
            previous = current; current = actual.next191
        }
        throw IllegalStateException("primitive DATA owner was not privately registered")
    }
    func returnOwnedView191(owner: HostPrimitiveConfigurationOwner191,
        view: HostOwnedPrimitiveConfiguration191): ?LogicalJsonOwnerReservation {
        lock.lock(); try { owner.returnView191(view); retireReturnedData191(owner) } finally { lock.unlock() }
    }
    func ownedDataCount191(): Int64 {
        lock.lock(); try {
            var result: Int64 = 0; var current = owned191
            while (current.isSome()) { result++; current = current.getOrThrow().next191 }
            result
        } finally { lock.unlock() }
    }

}

func hostPrimitiveSelections111(document: AgentValue, namespace: String, packageDigest: String): Result<?AgentValue> {
    if (!httpIntentExactFields(document, ["version", "plugins"]) ||
        document.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
        document.field("version").getOrThrow().asNumberText() != "1" ||
        document.field("plugins").getOrThrow().unifiedKind != ValueKind.List ||
        document.field("plugins").getOrThrow().items.size > 64) {
        return hostPluginResourceError("plugin.primitive_selection_invalid", "unsupported exact primitive selection schema") }
    let namespaces = HashSet<String>()
    var selected: ?AgentValue = None
    for (plugin in document.field("plugins").getOrThrow().items) {
        let name = httpIntentText(plugin, "namespace"); let digest = httpIntentText(plugin, "package_digest")
        if (!httpIntentExactFields(plugin, ["namespace", "package_digest", "tools"]) ||
            !httpServicePluginNamespace(name) || !httpServicePackageDigest(digest) || namespaces.contains(name) ||
            plugin.field("tools").getOrThrow().unifiedKind != ValueKind.List ||
            plugin.field("tools").getOrThrow().items.size > 128) {
            return hostPluginResourceError("plugin.primitive_selection_invalid", "invalid or duplicate exact installed package selection") }
        namespaces.add(name)
        let tools = HashSet<String>()
        for (tool in plugin.field("tools").getOrThrow().items) {
            let localTool = httpIntentText(tool, "name")
            if (!(httpIntentExactFields(tool, ["name", "profile", "services", "preparation_provider"]) ||
                httpIntentExactFields(tool, ["name", "profile", "services", "preparation_provider", "invocation_capability"])) ||
                !hostDocumentLogicalName(localTool) || tools.contains(localTool) ||
                httpIntentText(tool, "profile") != "frozen-primitives-v1" ||
                !hostDocumentLogicalName(httpIntentText(tool, "preparation_provider"))) {
                return hostPluginResourceError("plugin.primitive_selection_invalid", "primitive profile requires an exact local contribution and pure Provider") }
            let services = tool.field("services").getOrThrow()
            if (services.unifiedKind != ValueKind.List || services.items.isEmpty() || services.items.size > 2) {
                return hostPluginResourceError("plugin.primitive_selection_invalid", "invalid exact child service selection") }
            let selectedServices = HashSet<String>()
            for (service in services.items) {
                if (service.unifiedKind != ValueKind.Text ||
                    !pluginPrimitiveService111(service.text) || selectedServices.contains(service.text)) {
                    return hostPluginResourceError("plugin.primitive_selection_invalid", "unknown or duplicate child service") }
                selectedServices.add(service.text)
            }
            if ((selectedServices.contains("child.wait") && !selectedServices.contains("child.start")) ||
                ((selectedServices.contains("peer.list") || selectedServices.contains("peer.receive") || selectedServices.contains("peer.send") || selectedServices.contains("job.list") || selectedServices.contains("job.wait") || selectedServices.contains("peer.wait") || selectedServices.contains("job.cancel")) &&
                    (selectedServices.contains("child.start") || selectedServices.contains("child.wait")))) {
                return hostPluginResourceError("plugin.primitive_selection_invalid", "child wait cannot create a standalone selected owner") }
            if(selectedServices.contains("process.service") && selectedServices.size!=1){
                return hostPluginResourceError("plugin.primitive_selection_invalid","process resources require their own exact selected contribution")}
            if(selectedServices.contains("process.observe") && selectedServices.size!=1){
                return hostPluginResourceError("plugin.primitive_selection_invalid","process observations require their own exact selected contribution")}
            let invocation=tool.field("invocation_capability") ?? textValue("extension.invoke")
            if(invocation.unifiedKind==ValueKind.Object) {
                if(!httpIntentExactFields(invocation,["catalog","services"]) ||
                    invocation.field("catalog").getOrThrow().unifiedKind!=ValueKind.Text) {
                    return hostPluginResourceError("plugin.primitive_invocation_capability_invalid","invalid exact contribution invocation mapping") }
                let mapped=invocation.field("services").getOrThrow()
                let names=ArrayList<String>()
                for(service in services.items){names.add(service.text)}
                if(!httpIntentExactFields(mapped,names.toArray())) {
                    return hostPluginResourceError("plugin.primitive_invocation_capability_invalid","every selected service requires exactly one operator mapping") }
                var catalogSelected=false
                for(service in services.items) {
                    let name=mapped.field(service.text).getOrThrow()
                    if(!pluginPrimitiveInvocationSelection111(objectValue([ValueField("invocation_capability",name)]),service.text)) {
                        return hostPluginResourceError("plugin.primitive_invocation_capability_invalid","mapped capability differs from the actual primitive") }
                    if(name.unifiedKind==ValueKind.Text && name.text==httpIntentText(invocation,"catalog")){catalogSelected=true}
                }
                if(!catalogSelected){return hostPluginResourceError("plugin.primitive_invocation_capability_invalid","catalog visibility must name one explicitly selected invocation capability")}
            }else{
                for(service in services.items) {
                    if(!pluginPrimitiveInvocationSelection111(tool,service.text)) {
                        return hostPluginResourceError("plugin.primitive_invocation_capability_invalid",
                            "invocation capability must match each exact selected primitive") }
                }
            }
            tools.add(localTool)
        }
        if (name == namespace && digest == packageDigest) { selected = Some(plugin.field("tools").getOrThrow()) }
    }
    Result.Ok(selected)
}

// This conversion handles only already-validated operator configuration. It
// does not read business tool names, role names, publisher claims or IPC data.
func hostPrimitiveCapability111(name:String,namespace:String):Capability {
    match(name) {
        case "extension.invoke"=>Capability(CapabilityKind.ExtensionInvoke,resource:namespace)
        case "workspace.read"=>Capability(CapabilityKind.WorkspaceRead)
        case "peer.message"=>Capability(CapabilityKind.PeerMessage)
        case "process.spawn"=>Capability(CapabilityKind.ProcessSpawn)
        case "delegate"=>Capability(CapabilityKind.Delegate)
        case _=>throw IllegalArgumentException("invalid actual operator capability") }
}

// A raw Result<AgentError> remains an explicit legacy data alias. This holder
// is registered in the actual installed configuration before capture starts.
// Unknown allocation/capture failures therefore leave reachable paid custody;
// no callback-return, cancellation or worker completion can refund it.
class HostPrimitiveFailureData172 {
    let metadataPayment: LogicalJsonOwnerReservation
    private let allocate: (Int64) -> LogicalJsonOwnerReservation
    private var consumer: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    var error: ?AgentError = None<AgentError>
    init(payment: LogicalJsonOwnerReservation, allocate: (Int64) -> LogicalJsonOwnerReservation) {
        this.metadataPayment = payment; this.allocate = allocate
    }
    func capture(value: AgentError): AgentError {
        let actual = match (captureOwnedFailureData113<Unit>(value, allocate)) {
            case OwnedFailureDataOutcome113.Failure(found) => found
            case OwnedFailureDataOutcome113.Value(_) => throw IllegalStateException("full failure capture returned a value") }
        consumer = Some(actual)
        match (actual.withError({ borrowed, _ => this.error = Some(borrowed) })) {
            case Result.Err(failure) => throw OwnedCanonicalDataFailure113(failure)
            case Result.Ok(_) => error.getOrThrow() }
    }
}


// The factory calls this with the already-paid exact issued ticket graph.
// This is the original fixed-file byte/witness verifier and closed operator
// selection, not an IPC authorization or a replacement Source validator.
public func hostValidateProcessRootConfiguration180(value:AgentValue,plan:NormalizedOperationPlan):Result<Unit>{
    if(!httpIntentExactFields(value,["path","encoded","witness","namespace","package_digest","configuration_digest"]) ||
        (pluginPrimitivePlanService111(plan)!="process.service" && !isPluginHubProcessObservationPlan197(plan))){
        return hostPluginResourceError("hub.process_root_configuration_invalid","issued Root configuration is incomplete")}
    for(name in ["path","encoded","witness","namespace","package_digest","configuration_digest"]){
        if(value.field(name).getOrThrow().unifiedKind!=ValueKind.Text){
            return hostPluginResourceError("hub.process_root_configuration_invalid","issued configuration changed its actual scalar")}}
    let encoded=httpIntentText(value,"encoded");let witness=httpIntentText(value,"witness")
    let namespace=httpIntentText(value,"namespace");let packageDigest=httpIntentText(value,"package_digest")
    let binding=plan.canonicalArguments.field("binding").getOrThrow()
    if(encoded.size<1 || encoded.size>65536 || httpIntentText(binding,"namespace")!=namespace ||
        httpIntentText(binding,"package_digest")!=packageDigest ||
        httpIntentText(binding,"configuration_digest")!=httpIntentText(value,"configuration_digest") ||
        modelPolicySha256Text(encoded+"\n"+witness)!=httpIntentText(value,"configuration_digest")){
        return hostPluginResourceError("hub.process_root_configuration_changed","whole issued operator selection changed")}
    let bytes=encoded.toArray()
    let code=unsafe{
        let path=LibC.mallocCString(httpIntentText(value,"path"))
        try{let expected=LibC.mallocCString(witness)
            try{let raw=acquireArrayRawData(bytes)
                try{axyndra_read_view_equal(path,expected,raw.pointer,bytes.size)}finally{releaseArrayRawData(raw)}}
            finally{LibC.free(expected)}}finally{LibC.free(path)}}
    if(code!=0){return hostPluginResourceError("plugin.primitive_selection_changed","complete operator primitive selection changed after preparation")}
    let document=parseUnifiedJson(encoded,maxBytes:65536,maxDepth:10)
    let selected=match(hostPrimitiveSelections111(document,namespace,packageDigest)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    if(selected.isNone()){return hostPluginResourceError("hub.process_root_selection_missing","actual installed package lost its process selection")}
    let contribution=httpIntentText(binding,"contribution")
    for(tool in selected.getOrThrow().items where "plugin."+namespace+"."+httpIntentText(tool,"name")==contribution){
        for(service in tool.field("services").getOrThrow().items where service.unifiedKind==ValueKind.Text && service.text==pluginPrimitivePlanService111(plan)){
            return Result<Unit>.Ok(())}}
    hostPluginResourceError("hub.process_root_selection_missing","same actual contribution no longer selects the process service")
}

func hostParsePrimitiveConfiguration191(encoded: String): Result<AgentValue> {
    try { Result<AgentValue>.Ok(parseUnifiedJson(encoded, maxBytes: 65536, maxDepth: 10)) }
    catch (_: JsonException) { hostPluginResourceError("plugin.primitive_selection_invalid", "primitive selection could not be captured in its original data budget") }
}
