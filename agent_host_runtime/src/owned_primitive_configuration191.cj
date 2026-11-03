package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import std.sync.*

// Private DATA only. The original installed descriptor pays this backing,
// and every real consumer derives a separate share in that exact same bank.
class HostPrimitiveConfigurationOwner191 {
    let cache191: HostPrimitiveConfigurationCache111
    var next191: ?HostPrimitiveConfigurationOwner191
    private let lock = Mutex()
    private var data: ?HostPrimitiveConfiguration111 = None<HostPrimitiveConfiguration111>
    private var payment: ?LogicalJsonOwnerReservation
    private var pending191: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var views191: ?HostOwnedPrimitiveConfiguration191 = None<HostOwnedPrimitiveConfiguration191>
    private var count191: Int64 = 0
    private var unknown191 = false
    init(cache: HostPrimitiveConfigurationCache111, payment: LogicalJsonOwnerReservation,
        next: ?HostPrimitiveConfigurationOwner191) {
        this.cache191 = cache; this.payment = Some(payment); this.next191 = next
    }
    func publish191(value: HostPrimitiveConfiguration111): Unit {
        lock.lock(); try {
            if (data.isSome() || payment.isNone()) { throw IllegalStateException("primitive configuration publication repeated") }
            value.linkIndependentDebtCache191(cache191)
            data = Some(value)
        } finally { lock.unlock() }
    }
    func matches191(namespace: String, digest: String): Bool {
        lock.lock(); try {
            match (data) { case Some(value) => value.namespace == namespace && value.packageDigest == digest && value.validateCurrent().isOk()
                case None => false }
        } finally { lock.unlock() }
    }
    func retain191(): HostOwnedPrimitiveConfiguration191 {
        lock.lock(); try {
            if (data.isNone() || payment.isNone() || pending191.isSome() || count191 == Int64.Max) {
                throw LogicalJsonPayloadError("primitive configuration has no returned construction frame") }
            let paid = data.getOrThrow().deriveDataPayment191(16384)
            pending191 = Some(paid)
            let view = HostOwnedPrimitiveConfiguration191(this, paid)
            view.next191 = views191; views191 = Some(view); count191++
            pending191 = None<LogicalJsonOwnerReservation>
            view
        } finally { lock.unlock() }
    }
    func borrow191(): HostPrimitiveConfiguration111 {
        lock.lock(); try {
            if (count191 <= 0 || payment.isNone()) { throw IllegalStateException("primitive configuration DATA returned") }
            data.getOrThrow()
        } finally { lock.unlock() }
    }
    func holdUnknown191(): Unit { lock.lock(); try { unknown191 = true } finally { lock.unlock() } }
    func returnView191(view: HostOwnedPrimitiveConfiguration191): Unit {
        lock.lock(); try {
            var previous: ?HostOwnedPrimitiveConfiguration191 = None<HostOwnedPrimitiveConfiguration191>
            var current = views191
            while (current.isSome()) {
                let actual = current.getOrThrow()
                if (refEq(actual, view)) {
                    match (previous) { case Some(value) => value.next191 = actual.next191; case None => views191 = actual.next191 }
                    actual.next191 = None<HostOwnedPrimitiveConfiguration191>; count191--; return
                }
                previous = current; current = actual.next191
            }
            throw IllegalStateException("returned primitive share was not privately registered")
        } finally { lock.unlock() }
    }
    func canRetire191(): Bool {
        lock.lock(); try {
            !unknown191 && count191 == 0 && views191.isNone() && pending191.isNone() && payment.isSome() &&
                (data.isNone() || data.getOrThrow().canRetireOwnedData191())
        } finally { lock.unlock() }
    }
    func takePayment191(): ?LogicalJsonOwnerReservation {
        lock.lock(); try {
            if (unknown191 || count191 != 0 || views191.isSome() || pending191.isSome()) { return None<LogicalJsonOwnerReservation> }
            match (data) { case Some(value) => if (!value.canRetireOwnedData191()) { return None<LogicalJsonOwnerReservation> }; case None => () }
            match (data) { case Some(value) => value.clearReturnedIndependentDebtCache191(); case None => () }
            data = None<HostPrimitiveConfiguration111>
            let paid = payment; payment = None<LogicalJsonOwnerReservation>
            paid
        } finally { lock.unlock() }
    }
}

// This public shell exposes only closed DATA predicates and independent
// retained shares. It cannot export the private operator snapshot accidentally.
public class HostOwnedPrimitiveConfiguration191 {
    var next191: ?HostOwnedPrimitiveConfiguration191 = None<HostOwnedPrimitiveConfiguration191>
    var nextCatalog191: ?HostOwnedPrimitiveConfiguration191 = None<HostOwnedPrimitiveConfiguration191>
    private let lock = Mutex()
    private var owner: ?HostPrimitiveConfigurationOwner191
    private var payment: ?LogicalJsonOwnerReservation
    private var active191: Int64 = 0
    private var closing191 = false
    private var unknown191 = false
    init(owner: HostPrimitiveConfigurationOwner191, payment: LogicalJsonOwnerReservation) {
        this.owner = Some(owner); this.payment = Some(payment)
    }
    private func begin191(): Unit {
        lock.lock(); try {
            if (closing191 || owner.isNone() || active191 == Int64.Max) { throw IllegalStateException("primitive DATA share returned") }
            active191++
        } finally { lock.unlock() }
    }
    private func dataFrame191<T>(action: (HostPrimitiveConfiguration111) -> T): T {
        let actual = owner.getOrThrow().borrow191()
        action(actual)
    }
    private func withData191<T>(action: (HostPrimitiveConfiguration111) -> T): T {
        begin191()
        try { dataFrame191(action) }
        catch (error: Exception) { holdUnknown191(); throw error }
        finally { completeReturn191(finish191()) }
    }
    private func finish191(): (?HostPrimitiveConfigurationOwner191, ?LogicalJsonOwnerReservation) {
        lock.lock(); try {
            if (active191 <= 0) { throw IllegalStateException("primitive DATA frame underflow") }
            active191--; takeReturned191()
        } finally { lock.unlock() }
    }
    private func takeReturned191(): (?HostPrimitiveConfigurationOwner191, ?LogicalJsonOwnerReservation) {
        if (!closing191 || unknown191 || active191 != 0 || owner.isNone()) {
            return (None<HostPrimitiveConfigurationOwner191>, None<LogicalJsonOwnerReservation>) }
        let actual = owner; owner = None<HostPrimitiveConfigurationOwner191>
        let paid = payment; payment = None<LogicalJsonOwnerReservation>
        (actual, paid)
    }
    private func completeReturn191(returned: (?HostPrimitiveConfigurationOwner191, ?LogicalJsonOwnerReservation)): Unit {
        match (returned[0]) { case Some(value) =>
            let paid = value.cache191.returnOwnedView191(value, this)
            // Both complete private action and cache unlink/clear helpers
            // returned before any original allocation custody is refunded.
            match (paid) { case Some(actual) => actual.close(); case None => () }
            case None => () }
        match (returned[1]) { case Some(actual) => actual.close(); case None => () }
    }
    public func withOwnedPrimitiveFrame191<T>(action: () -> T): T {
        begin191()
        try { primitiveActionFrame191(action) }
        catch (error: Exception) { holdUnknown191(); throw error }
        finally { completeReturn191(finish191()) }
    }
    private func primitiveActionFrame191<T>(action: () -> T): T { action() }
    public func holdUnknown191(): Unit {
        lock.lock(); try { unknown191 = true
            match (owner) { case Some(value) => value.holdUnknown191(); case None => () }
        } finally { lock.unlock() }
    }
    public func returnOwnedPrimitive191(): Unit { completeReturn191(requestReturn191()) }
    private func requestReturn191(): (?HostPrimitiveConfigurationOwner191, ?LogicalJsonOwnerReservation) {
        lock.lock(); try { closing191 = true; takeReturned191() } finally { lock.unlock() }
    }
    func canReturnOwnedPrimitive191(): Bool {
        lock.lock(); try { !closing191 && !unknown191 && active191 == 0 && owner.isSome() && payment.isSome() }
        finally { lock.unlock() }
    }
    // Trusted private Catalog construction first attaches this exact view.
    // Its whole private backing/producer return precedes removal of the share;
    // public Raw catalog exports preserve their original alias gates.
    func additionalCapabilities(localTool: String): Array<Capability> {
        withData191({ value => value.additionalCapabilities(localTool) })
    }
    func invocationCapability(localTool: String): Capability {
        withData191({ value => value.invocationCapability(localTool) })
    }
    func resolvedInvocationCapability(localTool: String, arguments: AgentValue): Capability {
        withData191({ value => value.resolvedInvocationCapability(localTool, arguments) })
    }
    func resolvedAdditionalCapabilities(localTool: String, arguments: AgentValue): Array<Capability> {
        withData191({ value => value.resolvedAdditionalCapabilities(localTool, arguments) })
    }
    public func retainOwnedPrimitive191(): HostOwnedPrimitiveConfiguration191 {
        withData191({ _ => owner.getOrThrow().retain191() })
    }
    public func permits(localTool: String): Bool { withData191({ value => value.permits(localTool) }) }
    public func permitsService(localTool: String, service: String): Bool { withData191({ value => value.permitsService(localTool, service) }) }
    public func mappedInvocation(localTool: String): Bool { withData191({ value => value.mappedInvocation(localTool) }) }
    public func callerAllows(localTool: String, capabilities: CapabilitySet, service!: String = ""): Bool {
        withData191({ value => value.callerAllows(localTool, capabilities, service: service) })
    }
    public func validateCurrent(): Result<Unit> { withData191({ value => value.validateCurrent() }) }
    // This complete private export registers the Raw backing PaidHeld before exposure.
    // Whole export-helper return permits only the never-exported view header to retire.
    func exportCompatibilityHeld191(): HostPrimitiveConfiguration111 {
        withData191({ value => owner.getOrThrow().holdUnknown191(); value })
    }
    func retainFailure172(error: AgentError): AgentError {
        withData191({ value => value.retainFailure172(error) })
    }
}

// An independent failure keeps its own payment/complete captured data. Its
// allocator captures only that paid child; never an operator configuration,
// invocation Context, Source, Root, or the primitive DATA view.
class HostPrimitiveIndependentFailure191 {
    let payment191: LogicalJsonOwnerReservation
    var actual191: ?HostPrimitiveFailureData172 = None<HostPrimitiveFailureData172>
    let next191: ?HostPrimitiveIndependentFailure191
    init(payment: LogicalJsonOwnerReservation, next: ?HostPrimitiveIndependentFailure191) {
        this.payment191 = payment; this.next191 = next
    }
}
func hostPrimitiveFailureAllocation191(payment: LogicalJsonOwnerReservation, bytes: Int64): LogicalJsonOwnerReservation {
    if (bytes < 1) { throw IllegalArgumentException("input payment must be positive") }
    let loan = payment.deriveRetainedLease()
    try { loan.ensureRetainedPeak(max(1048576, bytes)); loan }
    catch (error: Exception) { loan.close(); throw error }
}
