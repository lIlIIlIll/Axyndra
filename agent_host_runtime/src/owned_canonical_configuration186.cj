package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*

// A private DATA backing in the original installed bank. Cache lookup, view
// counters and metadata can neither create a Source nor authorize an effect.
class HostCanonicalConfigurationOwner186 {
    let cache186: HostCanonicalProjectionConfigurationCache173
    var next186: ?HostCanonicalConfigurationOwner186
    private let lock = Mutex()
    private var data: ?HostCanonicalProjectionSelection173 = None<HostCanonicalProjectionSelection173>
    private var payment: ?LogicalJsonOwnerReservation
    private var pendingHeader: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var views: Int64 = 0
    private var constructions186: ?HostCanonicalConsumerConstruction186 = None<HostCanonicalConsumerConstruction186>
    private var viewHead: ?HostOwnedCanonicalProjectionSelection186 = None<HostOwnedCanonicalProjectionSelection186>
    private var unknown = false
    init(cache: HostCanonicalProjectionConfigurationCache173, payment: LogicalJsonOwnerReservation,
        next: ?HostCanonicalConfigurationOwner186) {
        this.cache186 = cache; this.payment = Some(payment); this.next186 = next
    }
    func publish186(value: HostCanonicalProjectionSelection173): Unit {
        lock.lock(); try {
            if (data.isSome() || payment.isNone()) { throw IllegalStateException("canonical configuration publication repeated") }
            data = Some(value)
        } finally { lock.unlock() }
    }
    func holdUnknown186(): Unit { lock.lock(); try { unknown = true } finally { lock.unlock() } }
    func matches186(namespace: String, digest: String, tool: String, generation: UInt64): Bool {
        lock.lock(); try {
            match (data) {
                case Some(value) => value.namespace == namespace && value.packageDigest == digest &&
                    value.localTool == tool && value.generation == generation && value.validateCurrent173().isOk()
                case None => false }
        } finally { lock.unlock() }
    }
    func retain186(): HostOwnedCanonicalProjectionSelection186 {
        lock.lock(); try {
            if (data.isNone() || payment.isNone() || pendingHeader.isSome() || views == Int64.Max) {
                throw LogicalJsonPayloadError("canonical configuration has no returned private DATA construction frame") }
            let actual = data.getOrThrow()
            var bytes: Int64 = 0
            for (size in [actual.namespace.size, actual.packageDigest.size, actual.localTool.size,
                actual.provider.size, actual.action.size, actual.capability.size, actual.effect.size, actual.configurationDigest.size]) {
                if (bytes > Int64.Max - size) { throw LogicalJsonPayloadError("canonical view metadata overflow") }
                bytes += size }
            if (bytes > (Int64.Max - 16384) / 8) { throw LogicalJsonPayloadError("canonical view metadata overflow") }
            let header = actual.deriveDataPayment173(16384 + bytes * 8)
            // Constructor failure preserves this exact original-bank header.
            // It is never refunded while a partial construction is unknown.
            pendingHeader = Some(header)
            let result = HostOwnedCanonicalProjectionSelection186(this, header, actual)
            result.nextView186 = viewHead; viewHead = Some(result)
            views++; pendingHeader = None<LogicalJsonOwnerReservation>
            result
        } finally { lock.unlock() }
    }
    func prepareCopiedConsumer186(bytes: Int64): HostCanonicalConsumerConstruction186 {
        lock.lock(); try {
            if (pendingHeader.isSome()) { throw LogicalJsonPayloadError("unknown canonical copied consumer construction remains paid") }
            let header = data.getOrThrow().deriveDataPayment173(bytes)
            pendingHeader = Some(header)
            let carrier = HostCanonicalConsumerConstruction186(header, constructions186)
            constructions186 = Some(carrier); pendingHeader = None<LogicalJsonOwnerReservation>
            carrier
        } finally { lock.unlock() }
    }
    func publishedCopiedConsumer186(carrier: HostCanonicalConsumerConstruction186): Unit {
        lock.lock(); try {
            var previous: ?HostCanonicalConsumerConstruction186 = None<HostCanonicalConsumerConstruction186>
            var current = constructions186
            while (current.isSome()) {
                let actual = current.getOrThrow()
                if (refEq(actual, carrier)) {
                    match (previous) { case Some(value) => value.next186 = actual.next186; case None => constructions186 = actual.next186 }
                    actual.next186 = None<HostCanonicalConsumerConstruction186>
                    actual.payment186 = None<LogicalJsonOwnerReservation>
                    actual.view186 = None<HostOwnedCanonicalProjectionSelection186>
                    return
                }
                previous = current; current = actual.next186
            }
            throw IllegalStateException("canonical copied consumer construction was not registered")
        } finally { lock.unlock() }
    }
    func borrow186(): HostCanonicalProjectionSelection173 {
        lock.lock(); try {
            if (views <= 0 || payment.isNone()) { throw IllegalStateException("canonical owned DATA view has returned") }
            data.getOrThrow()
        } finally { lock.unlock() }
    }
    func returnView186(returned: HostOwnedCanonicalProjectionSelection186): Unit {
        lock.lock(); try {
            if (views <= 0) { throw IllegalStateException("canonical configuration view underflow") }
            var previous: ?HostOwnedCanonicalProjectionSelection186 = None<HostOwnedCanonicalProjectionSelection186>
            var current = viewHead
            var removed = false
            while (current.isSome()) {
                let actual = current.getOrThrow()
                if (refEq(actual, returned)) {
                    match (previous) { case Some(value) => value.nextView186 = actual.nextView186
                        case None => viewHead = actual.nextView186 }
                    actual.nextView186 = None<HostOwnedCanonicalProjectionSelection186>
                    removed = true; break
                }
                previous = current; current = actual.nextView186
            }
            if (!removed) { throw IllegalStateException("canonical returned view was not privately registered") }
            views--
        } finally { lock.unlock() }
    }
    func unusedReturned186(): Bool {
        lock.lock(); try { !unknown && views == 0 && data.isNone() && pendingHeader.isNone() && constructions186.isNone() }
        finally { lock.unlock() }
    }
    func canRetire186(): Bool {
        lock.lock(); try {
            !unknown && views == 0 && pendingHeader.isNone() && constructions186.isNone() && payment.isSome() &&
                data.isSome() && data.getOrThrow().canRetireOwnedConfiguration186()
        } finally { lock.unlock() }
    }
    func takePayment186(): ?LogicalJsonOwnerReservation {
        lock.lock(); try {
            if (unknown || views != 0 || pendingHeader.isSome() || constructions186.isSome() || viewHead.isSome()) { return None<LogicalJsonOwnerReservation> }
            match (data) { case Some(value) => if (!value.canRetireOwnedConfiguration186()) {
                return None<LogicalJsonOwnerReservation> }; case None => () }
            data = None<HostCanonicalProjectionSelection173>
            let actual = payment; payment = None<LogicalJsonOwnerReservation>
            actual
        } finally { lock.unlock() }
    }
}

// Each real owner receives an independent prepaid view. The private snapshot
// never leaves this class. A retained view may outlive its producer; terminal
// release revokes new calls, waits for complete method frames, clears every
// private snapshot/metadata reference, then returns its original-bank share.
public class HostOwnedCanonicalProjectionSelection186 {
    var nextCatalog186: ?HostOwnedCanonicalProjectionSelection186 = None<HostOwnedCanonicalProjectionSelection186>
    var nextView186: ?HostOwnedCanonicalProjectionSelection186 = None<HostOwnedCanonicalProjectionSelection186>
    private let lock = Mutex()
    private var owner: ?HostCanonicalConfigurationOwner186
    private var header: ?LogicalJsonOwnerReservation
    private var activeFrames: Int64 = 0
    private var closing = false
    private var unknown = false
    private var namespaceValue: String
    private var digestValue: String
    private var localToolValue: String
    private var providerValue: String
    private var actionValue: String
    private var capabilityValue: String
    private var effectValue: String
    private var configurationDigestValue: String
    private var policyBinding193: ?HostPluginPolicyBinding = None<HostPluginPolicyBinding>
    private var policyBindingOpening193 = false
    private let generationValue: UInt64
    init(owner: HostCanonicalConfigurationOwner186, header: LogicalJsonOwnerReservation,
        value: HostCanonicalProjectionSelection173) {
        this.owner = Some(owner); this.header = Some(header)
        namespaceValue = String.fromUtf8(value.namespace.toArray())
        digestValue = String.fromUtf8(value.packageDigest.toArray())
        localToolValue = String.fromUtf8(value.localTool.toArray())
        providerValue = String.fromUtf8(value.provider.toArray())
        actionValue = String.fromUtf8(value.action.toArray())
        capabilityValue = String.fromUtf8(value.capability.toArray())
        effectValue = String.fromUtf8(value.effect.toArray())
        configurationDigestValue = String.fromUtf8(value.configurationDigest.toArray())
        generationValue = value.generation
    }
    private func privateTextFrame186(index: Int64): String {
        // Package-private callers consume this solely under an already pinned
        // complete action frame and return only Bool or numeric DATA.
        match (index) {
            case 0 => namespaceValue; case 1 => digestValue; case 2 => localToolValue; case 3 => providerValue
            case 4 => actionValue; case 5 => capabilityValue; case 6 => effectValue; case 7 => configurationDigestValue
            case _ => throw IllegalArgumentException("configuration text index is outside its fixed fields") }
    }
    private func text186(index: Int64): String {
        withData186({ value => owner.getOrThrow().cache186.copiedPublicTextFrame186(value, index) })
    }
    func textEquals186(index: Int64, expected: String): Bool {
        withOwnedConfigurationFrame186({ => privateTextFrame186(index) == expected })
    }
    public func textSize186(index: Int64): Int64 {
        withOwnedConfigurationFrame186({ => privateTextFrame186(index).size })
    }
    public prop namespace: String { get() { text186(0) } }
    public prop packageDigest: String { get() { text186(1) } }
    public prop localTool: String { get() { text186(2) } }
    public prop provider: String { get() { text186(3) } }
    public prop action: String { get() { text186(4) } }
    public prop capability: String { get() { text186(5) } }
    public prop effect: String { get() { text186(6) } }
    public prop configurationDigest: String { get() { text186(7) } }
    public prop generation: UInt64 { get() { lock.lock(); try {
        if (closing || owner.isNone()) { throw IllegalStateException("canonical owned metadata has returned") }
        generationValue
    } finally { lock.unlock() } } }
    public func constructCopiedConsumer186<T>(bytes: Int64,
        action: (LogicalJsonOwnerReservation, HostOwnedCanonicalProjectionSelection186) -> T): T {
        withOwnedConfigurationFrame186({ => copiedConsumerFrame186(bytes, action) })
    }
    private func copiedConsumerFrame186<T>(bytes: Int64,
        action: (LogicalJsonOwnerReservation, HostOwnedCanonicalProjectionSelection186) -> T): T {
        let parent = owner.getOrThrow()
        let carrier = parent.prepareCopiedConsumer186(bytes)
        carrier.view186 = Some(retainOwnedConfiguration186())
        let result = action(carrier.payment186.getOrThrow(), carrier.view186.getOrThrow())
        parent.publishedCopiedConsumer186(carrier)
        result
    }
    public func canReturnOwnedConfiguration186(): Bool {
        lock.lock(); try { !unknown && activeFrames == 0 && owner.isSome() && !closing }
        finally { lock.unlock() }
    }
    public func exportCompatibilityHeld186(): HostCanonicalProjectionSelection173 {
        holdUnknown186()
        withData186({ value => value })
    }
    public func retainOwnedConfiguration186(): HostOwnedCanonicalProjectionSelection186 {
        withData186({ _ => owner.getOrThrow().retain186() })
    }
    private func beginFrame186(): Unit {
        lock.lock(); try {
            if (closing || owner.isNone() || activeFrames == Int64.Max) { throw IllegalStateException("canonical owned DATA call has returned") }
            activeFrames++
        } finally { lock.unlock() }
    }
    private func dataFrame186<T>(action: (HostCanonicalProjectionSelection173) -> T): T {
        let actual = owner.getOrThrow().borrow186()
        action(actual)
    }
    private func withData186<T>(action: (HostCanonicalProjectionSelection173) -> T): T {
        beginFrame186()
        try { dataFrame186(action) }
        catch (error: Exception) { holdUnknown186(); throw error }
        finally { completeReturn186(finishFrame186()) }
    }
    public func holdUnknown186(): Unit {
        lock.lock(); try {
            unknown = true
            match (owner) { case Some(value) => value.holdUnknown186(); case None => () }
        } finally { lock.unlock() }
    }
    // A concrete producer may pin the exact view across its entire original
    // callback/helper, including all nested metadata and policy consumers.
    public func withOwnedConfigurationFrame186<T>(action: () -> T): T {
        beginFrame186()
        try { ownedConfigurationActionFrame186(action) }
        catch (error: Exception) { holdUnknown186(); throw error }
        finally { completeReturn186(finishFrame186()) }
    }
    private func ownedConfigurationActionFrame186<T>(action: () -> T): T { action() }
    private func finishFrame186(): (?HostCanonicalConfigurationOwner186, ?LogicalJsonOwnerReservation) {
        lock.lock(); try {
            if (activeFrames <= 0) { throw IllegalStateException("canonical configuration call frame underflow") }
            activeFrames--
            takeReturnedFrame186()
        } finally { lock.unlock() }
    }
    private func takeReturnedFrame186(): (?HostCanonicalConfigurationOwner186, ?LogicalJsonOwnerReservation) {
        if (!closing || unknown || activeFrames != 0 || owner.isNone()) { return (None<HostCanonicalConfigurationOwner186>, None<LogicalJsonOwnerReservation>) }
        policyBinding193 = None<HostPluginPolicyBinding>
        namespaceValue = ""; digestValue = ""; localToolValue = ""; providerValue = ""
        actionValue = ""; capabilityValue = ""; effectValue = ""; configurationDigestValue = ""
        let actual = owner; owner = None<HostCanonicalConfigurationOwner186>
        let paid = header; header = None<LogicalJsonOwnerReservation>
        (actual, paid)
    }
    private func completeReturn186(returned: (?HostCanonicalConfigurationOwner186, ?LogicalJsonOwnerReservation)): Unit {
        match (returned[0]) {
            case Some(actual) =>
                let backing = actual.cache186.returnOwnedView186(actual, this)
                // The whole cache unlink/snapshot-clear helper has returned.
                match (backing) { case Some(value) => value.close(); case None => () }
            case None => () }
        match (returned[1]) { case Some(value) => value.close(); case None => () }
    }
    public func returnOwnedConfiguration186(): Unit {
        let returned = requestReturnFrame186()
        completeReturn186(returned)
    }
    private func requestReturnFrame186(): (?HostCanonicalConfigurationOwner186, ?LogicalJsonOwnerReservation) {
        lock.lock(); try { closing = true; takeReturnedFrame186() } finally { lock.unlock() }
    }
    public func copiedNativeProviderText186(): String {
        // Only the complete package-private copied-text helper sees DATA;
        // the caller receives solely its independent already-paid String.
        withData186({ value => owner.getOrThrow().cache186.copiedNativeProviderFrame186(value) })
    }
    func invokeNativeRecipe193(host: HostJavaScriptPluginHost, context: ToolInvocationContext,
        prepared: PreparedToolInvocation, payment: LogicalJsonOwnerReservation): Result<HostJavaScriptPluginInvocationResult> {
        withData186({ value => hostInvokeCanonicalDataRecipeFrame193(host, value, context, prepared, payment) })
    }
    public func policyGeneration193(host: HostJavaScriptPluginHost): Result<UInt64> {
        withData186({ value => capturePolicyBindingFrame193(host, value) })
    }
    private func capturePolicyBindingFrame193(host: HostJavaScriptPluginHost,
        value: HostCanonicalProjectionSelection173): Result<UInt64> {
        lock.lock()
        try {
            if (policyBindingOpening193 || policyBinding193.isSome()) {
                throw IllegalStateException("canonical policy binding was already captured") }
            policyBindingOpening193 = true
        } finally { lock.unlock() }
        // Exactly the original first Host lookup, before the original selection
        // validation. The private pointer is protected by the whole view frame.
        let selected = host.policyProviderBinding(value.namespace, value.provider)
        lock.lock()
        try {
            policyBindingOpening193 = false
            match (selected) {
                case Result.Err(error) => Result<UInt64>.Err(error)
                case Result.Ok(binding) =>
                    // The exact namespace/provider arguments already belong
                    // to this pinned private selection. The descriptor digest
                    // belongs to another generation: fund and copy it before
                    // retaining it across that generation's unmount.
                    var bytes: Int64 = 0
                    for (size in [namespaceValue.size, digestValue.size, localToolValue.size, providerValue.size,
                        actionValue.size, capabilityValue.size, effectValue.size, configurationDigestValue.size,
                        binding.digest.size]) {
                        if (bytes > Int64.Max - size) { throw LogicalJsonPayloadError("canonical policy binding invoice overflow") }
                        bytes += size
                    }
                    if (bytes > (Int64.Max - 24576) / 8) { throw LogicalJsonPayloadError("canonical policy binding invoice overflow") }
                    header.getOrThrow().ensureRetainedPeak(24576 + bytes * 8)
                    policyBinding193 = Some(HostPluginPolicyBinding(value.namespace, value.provider,
                        String.fromUtf8(binding.digest.toArray()), binding.generation))
                    Result<UInt64>.Ok(binding.generation)
            }
        } finally { lock.unlock() }
    }
    private func pinnedPolicyBindingFrame193(generation: UInt64): HostPluginPolicyBinding {
        lock.lock()
        try {
            let actual = policyBinding193.getOrThrow()
            if (actual.generation != generation) { throw IllegalStateException("canonical policy generation differs from its private binding") }
            actual
        } finally { lock.unlock() }
    }
    public func validatePolicyGeneration193(host: HostJavaScriptPluginHost, generation: UInt64, pinned: Bool): Result<Unit> {
        withData186({ value => hostCanonicalPolicyValidate193(host, value, pinnedPolicyBindingFrame193(generation), pinned) })
    }
    public func consumeCurrentPolicy193(host: HostJavaScriptPluginHost, generation: UInt64,
        action: () -> Result<Unit>): Result<Unit> {
        withData186({ _ => consumePolicyFrame193(host, generation, action) })
    }
    private func consumePolicyFrame193(host: HostJavaScriptPluginHost, generation: UInt64,
        action: () -> Result<Unit>): Result<Unit> {
        let binding = pinnedPolicyBindingFrame193(generation)
        host.withCurrentPolicyData(binding.namespace, binding.contribution, binding.generation, binding.digest, action)
    }
    public func queryPolicy193(host: HostJavaScriptPluginHost, input: AgentValue, thread: ThreadId,
        cancellation: CancellationToken, requestId: String, provenance: ?String): Result<HostPolicyScalarResult193> {
        withData186({ value => hostCanonicalPolicyQuery193(host, value, input, thread, cancellation, requestId, provenance) })
    }
    public func validateCurrent173(): Result<Unit> { withData186({ value => value.validateCurrent173() }) }
    public func deriveDataPayment173(bytes: Int64): LogicalJsonOwnerReservation { withData186({ value => value.deriveDataPayment173(bytes) }) }
    public func requires173(context: ToolInvocationContext): Result<Unit> { withData186({ value => value.requires173(context) }) }
    public func canonicalArguments173(host: HostJavaScriptPluginHost, context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
        withData186({ value => value.canonicalArgumentsOwned186(host, context, call, owner.getOrThrow().cache186) })
    }
    public func requirePlan173(context: ToolInvocationContext, plan: NormalizedOperationPlan): Result<Unit> {
        withData186({ value => value.requirePlan173(context, plan) })
    }
    func reservePreparedExecutionFailure173(prepared: PreparedToolInvocation): HostCanonicalExecutionFailure173 {
        withData186({ value => value.reservePreparedExecutionFailure173(prepared) })
    }
    public func consumeExecutionFailure173(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        held: HostCanonicalExecutionFailure173): Result<ToolResult> {
        withData186({ value => value.consumeExecutionFailure173(context, prepared, held) })
    }
    func returnedExecutionFrame173(prepared: PreparedToolInvocation): Unit {
        withData186({ value => value.returnedExecutionFrame173(prepared) })
    }
    public func ownsExecutionFailure186(held: HostCanonicalExecutionFailure173): Bool {
        withData186({ value => held.belongsTo173(value) })
    }
}

class HostCanonicalConsumerConstruction186 {
    var payment186: ?LogicalJsonOwnerReservation
    var view186: ?HostOwnedCanonicalProjectionSelection186 = None<HostOwnedCanonicalProjectionSelection186>
    var next186: ?HostCanonicalConsumerConstruction186
    init(payment: LogicalJsonOwnerReservation, next: ?HostCanonicalConsumerConstruction186) {
        payment186 = Some(payment); next186 = next
    }
}
