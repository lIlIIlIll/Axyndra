package model_provider_runtime

import agent_domain.*
import std.sync.*

private let providerInputIdentityDebts159 = ProviderInputIdentityDebts159()

// The anti-replay set has a different lifetime from one ModelRequest. Its
// exact UTF8 identity is copied only after this independent original-bank
// reservation exists. No request graph or callback is kept in this record.
class ProviderInputIdentity159 <: ModelInputReturnWitness159 {
    private let lock = Mutex()
    var portNext159: ?ProviderInputIdentity159 = None<ProviderInputIdentity159>
    var debtNext159: ?ProviderInputIdentity159 = None<ProviderInputIdentity159>
    private var payment: ?LogicalJsonOwnerReservation
    private var identity = ""
    private var returned159 = false
    private var successfulFrame159 = false
    private var returnGate159: ?ModelProviderDispatchGate = None<ModelProviderDispatchGate>
    private var returnEndpoint159: ?ModelProviderEndpoint = None<ModelProviderEndpoint>
    private var cancellation159: ?ProviderInputCancellation159 = None<ProviderInputCancellation159>
    private var observation: ?ModelProviderDispatch = None<ModelProviderDispatch>
    init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment)
        providerInputIdentityDebts159.retain159(this)
    }
    func copyIdentity159(value: String): Unit {
        identity = copyProviderIdentityFrame159(value)
    }
    func text159(): String { identity }
    func observe159(value: ModelProviderDispatch): Unit { observation = Some(value) }
    func cancellationBridge159(endpoint: ModelProviderEndpoint): ProviderInputCancellation159 {
        lock.lock(); try {
            let result = ProviderInputCancellation159(endpoint, identity)
            cancellation159 = Some(result); result
        } finally { lock.unlock() }
    }
    func recordSuccessfulFrame159(gate: ModelProviderDispatchGate, endpoint: ModelProviderEndpoint): Unit {
        lock.lock(); try {
            returnGate159 = Some(gate); returnEndpoint159 = Some(endpoint); successfulFrame159 = true
        } finally { lock.unlock() }
    }
    public func inputAliasesReturned159(): Bool {
        lock.lock()
        try {
            if (returned159) { return true }
            if (!successfulFrame159) { return false }
            match (cancellation159) { case Some(value) => if (!value.referencesReturned159()) { return false }; case None => () }
            let dispatch = match (observation) { case Some(value) => value; case None => return false }
            let gateReturned = match (returnGate159) {
                case Some(actual) => match (actual) {
                    case typed: ModelProviderReturningInputGate159 => typed.inputObservationReturned159(dispatch)
                    case _ => false }
                case None => false
            }
            let endpointReturned = match (returnEndpoint159) {
                case Some(actual) => match (actual) {
                    case typed: NativeModelProviderEndpoint => typed.inputReferencesReturned159(dispatch)
                    case _ => false }
                case None => false
            }
            if (!gateReturned || !endpointReturned) { return false }
            observation = None<ModelProviderDispatch>
            returnGate159 = None<ModelProviderDispatchGate>
            returnEndpoint159 = None<ModelProviderEndpoint>
            cancellation159 = None<ProviderInputCancellation159>
            returned159 = true; true
        } finally { lock.unlock() }
    }
    func isReturned159(): Bool { inputAliasesReturned159() }
    func clearCacheReferences159(): ?LogicalJsonOwnerReservation {
        if (!isReturned159()) { return None<LogicalJsonOwnerReservation> }
        lock.lock()
        try {
        // The owning port already dropped its complete anti-replay backing.
        // This helper contains no model input, callback, endpoint or Source.
        let paid = payment
        identity = ""; observation = None<ModelProviderDispatch>
        portNext159 = None<ProviderInputIdentity159>
        providerInputIdentityDebts159.remove159(this)
        payment = None<LogicalJsonOwnerReservation>
        paid
        } finally { lock.unlock() }
    }
}
private func copyProviderIdentityFrame159(value: String): String {
    // The caller already charged the bytes, decoded String and retained node.
    String.fromUtf8(value.toArray())
}
class ProviderInputIdentityDebts159 {
    private let lock = Mutex()
    private var head: ?ProviderInputIdentity159 = None<ProviderInputIdentity159>
    func retain159(value: ProviderInputIdentity159): Unit {
        lock.lock(); try { value.debtNext159 = head; head = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: ProviderInputIdentity159): Unit {
        lock.lock()
        try {
            var previous: ?ProviderInputIdentity159 = None<ProviderInputIdentity159>
            var cursor = head
            while (cursor.isSome()) {
                let item = cursor.getOrThrow()
                if (refEq(item, value)) {
                    match (previous) { case Some(before) => before.debtNext159 = item.debtNext159
                        case None => head = item.debtNext159 }
                    item.debtNext159 = None<ProviderInputIdentity159>; return
                }
                previous = cursor; cursor = item.debtNext159
            }
        } finally { lock.unlock() }
    }
}

// The cancellation registration may have copied its closure before dispose.
// It captures only this already-funded cell. Clearing admission prevents a
// late callback from taking any model identity or endpoint reference.
class ProviderInputCancellation159 {
    private let lock = Mutex()
    private var endpoint: ?ModelProviderEndpoint
    private var requestId: ?String
    private var frames: Int64 = 0
    private var stopped = false
    private var registration: ?CancellationRegistration = None<CancellationRegistration>
    init(endpoint: ModelProviderEndpoint, requestId: String) {
        this.endpoint = Some(endpoint); this.requestId = Some(requestId)
    }
    func registration159(value: CancellationRegistration): Unit {
        lock.lock(); try { registration = Some(value) } finally { lock.unlock() }
    }
    func cancel159(): Unit {
        lock.lock()
        let entered = try { if (stopped) { false } else { frames++; true } }
            finally { lock.unlock() }
        if (!entered) { return }
        try { cancelFrame159() }
        finally {
            lock.lock()
            try {
                frames--
                if (stopped && frames == 0) { clear159() }
            } finally { lock.unlock() }
        }
    }
    private func cancelFrame159(): Unit {
        let values = try { lock.lock(); (endpoint.getOrThrow(), requestId.getOrThrow()) }
            finally { lock.unlock() }
        try { let _ = values[0].cancel(values[1]) } catch (_: Exception) {}
    }
    func stop159(): Unit {
        lock.lock(); try { stopped = true; if (frames == 0) { clear159() } } finally { lock.unlock() }
    }
    private func clear159(): Unit { endpoint = None<ModelProviderEndpoint>; requestId = None<String> }
    func referencesReturned159(): Bool {
        lock.lock()
        try {
            if (!stopped || frames != 0 || endpoint.isSome() || requestId.isSome()) { return false }
            match (registration) {
                case Some(value) =>
                    if (!value.callbacksReturned159()) { return false }
                    registration = None<CancellationRegistration>
                case None => ()
            }
            true
        } finally { lock.unlock() }
    }
}
