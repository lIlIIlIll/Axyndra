package legacy_extension_runtime

import agent_extension_runtime.*
import std.collection.*
import std.deriving.*














public interface GenerationLifecycleHost {
    func mount(provider: CompiledExtensionProvider, generation: UInt64): HostLifecycleResult
    func activate(extensionId: String, generation: UInt64): HostLifecycleResult
    func stopAdmitting(extensionId: String, generation: UInt64): HostLifecycleResult
    func dispose(extensionId: String, generation: UInt64): HostLifecycleResult
}

// Compatibility adapter for the original compiled-provider host. It preserves
// generation 1 behavior; overlapping reloads require a generation-aware host.
public class CompiledExtensionLifecycleAdapter <: GenerationLifecycleHost {
    private let host: ExtensionLifecycleHost
    public init(host: ExtensionLifecycleHost) { this.host = host }

    public func mount(provider: CompiledExtensionProvider, generation: UInt64): HostLifecycleResult {
        if (generation != 1u64) {
            return HostLifecycleResult.Err("generation.unsupported", "legacy lifecycle host supports generation 1 only")
        }
        host.activate(provider.create(), provider.source)
    }
    public func activate(_extensionId: String, generation: UInt64): HostLifecycleResult {
        let _ = _extensionId
        if (generation == 1u64) { HostLifecycleResult.Ok }
        else { HostLifecycleResult.Err("generation.unsupported", "legacy lifecycle host supports generation 1 only") }
    }
    public func stopAdmitting(_extensionId: String, _generation: UInt64): HostLifecycleResult {
        let _ = _extensionId; let _ = _generation
        HostLifecycleResult.Ok
    }
    public func dispose(extensionId: String, generation: UInt64): HostLifecycleResult {
        if (generation != 1u64) {
            return HostLifecycleResult.Err("generation.unsupported", "legacy lifecycle host supports generation 1 only")
        }
        host.deactivate(extensionId)
    }
}



class ExtensionGenerationRecord {
    let provider: CompiledExtensionProvider
    let generation: UInt64
    var state: ExtensionLifecycleState
    var inFlight: UInt64 = 0u64
    var accepting: Bool = false
    var error: String = ""

    init(provider: CompiledExtensionProvider, generation: UInt64) {
        this.provider = provider
        this.generation = generation
        this.state = ExtensionLifecycleState.Discovered
    }
}

public class ExtensionInvocationLease {
    public let extensionId: String
    public let generation: UInt64
    private let onRelease: () -> Unit
    private var released: Bool = false

    init(extensionId: String, generation: UInt64, onRelease: () -> Unit) {
        this.extensionId = extensionId
        this.generation = generation
        this.onRelease = onRelease
    }

    public func release(): Unit {
        if (!released) {
            released = true
            onRelease()
        }
    }
}

// Serialized by the owning runtime actor. A lease pins one immutable
// generation until the invocation has settled.
public class SafeExtensionLifecycleRuntime {
    private let host: GenerationLifecycleHost
    private let records = ArrayList<ExtensionGenerationRecord>()

    public init(host: GenerationLifecycleHost) { this.host = host }

    public func mountInitial(provider: CompiledExtensionProvider, generation!: UInt64 = 1u64): SafeLifecycleResult<Unit> {
        if (find(provider.id, generation).isSome() || current(provider.id).isSome()) {
            return SafeLifecycleResult.Err("extension generation is already mounted")
        }
        mountAndActivate(provider, generation)
    }

    public func reload(provider: CompiledExtensionProvider, generation: UInt64): SafeLifecycleResult<Unit> {
        let old = match (current(provider.id)) {
            case Some(value) => value
            case None => return SafeLifecycleResult.Err("extension has no active generation")
        }
        if (generation <= old.generation || find(provider.id, generation).isSome()) {
            return SafeLifecycleResult.Err("reload generation must increase monotonically")
        }
        match (mountAndActivate(provider, generation)) {
            case SafeLifecycleResult.Err(error) => return SafeLifecycleResult.Err(error)
            case SafeLifecycleResult.Ok(_) => ()
        }
        match (host.stopAdmitting(old.provider.id, old.generation)) {
            case HostLifecycleResult.Err(code, message) =>
                let next = match (find(provider.id, generation)) {
                    case Some(value) => value
                    case None => return SafeLifecycleResult.Err("${code}: ${message}")
                }
                match (host.stopAdmitting(next.provider.id, next.generation)) {
                    case HostLifecycleResult.Ok =>
                        next.accepting = false
                        next.state = ExtensionLifecycleState.StopAdmitting
                        let _ = disposeRecord(next)
                    case HostLifecycleResult.Err(_, _) =>
                        next.accepting = false
                        next.state = ExtensionLifecycleState.Quarantined
                }
                return SafeLifecycleResult.Err("${code}: ${message}")
            case HostLifecycleResult.Ok =>
                old.accepting = false
                old.state = ExtensionLifecycleState.StopAdmitting
                old.state = ExtensionLifecycleState.Draining
        }
        if (old.inFlight == 0u64) { disposeRecord(old) } else { SafeLifecycleResult.Ok(()) }
    }

    public func acquire(extensionId: String): SafeLifecycleResult<ExtensionInvocationLease> {
        let record = match (current(extensionId)) {
            case Some(value) => value
            case None => return SafeLifecycleResult.Err("extension has no active generation")
        }
        if (!record.accepting || record.state != ExtensionLifecycleState.Active) {
            return SafeLifecycleResult.Err("extension generation stopped admission")
        }
        record.inFlight += 1u64
        SafeLifecycleResult.Ok(ExtensionInvocationLease(extensionId, record.generation, {
            => releaseRecord(record)
        }))
    }

    // The owner calls this after its bounded drain deadline. Remaining work is
    // never force-unloaded; it is quarantined for explicit recovery.
    public func finishDrain(extensionId: String, generation: UInt64): SafeLifecycleResult<Unit> {
        let record = match (find(extensionId, generation)) {
            case Some(value) => value
            case None => return SafeLifecycleResult.Err("extension generation is not mounted")
        }
        if (record.state != ExtensionLifecycleState.Draining) {
            return SafeLifecycleResult.Err("extension generation is not draining")
        }
        if (record.inFlight > 0u64) {
            record.state = ExtensionLifecycleState.Quarantined
            return SafeLifecycleResult.Err("drain deadline expired with ${record.inFlight} invocation(s)")
        }
        disposeRecord(record)
    }

    public func diagnostics(): Array<ExtensionGenerationDiagnostic> {
        let values = ArrayList<ExtensionGenerationDiagnostic>()
        for (record in records) {
            values.add(ExtensionGenerationDiagnostic(
                record.provider.id, record.generation, record.state, record.inFlight, record.accepting,
                error: record.error
            ))
        }
        values.toArray()
    }

    private func mountAndActivate(provider: CompiledExtensionProvider, generation: UInt64): SafeLifecycleResult<Unit> {
        if (generation == 0u64) { return SafeLifecycleResult.Err("generation must be positive") }
        let record = ExtensionGenerationRecord(provider, generation)
        record.state = ExtensionLifecycleState.Validated
        match (callHost({ => host.mount(provider, generation) })) {
            case HostLifecycleResult.Err(code, message) =>
                record.error = "${code}: ${message}"
                match (callHost({ => host.dispose(provider.id, generation) })) {
                    case HostLifecycleResult.Ok => record.state = ExtensionLifecycleState.Failed
                    case HostLifecycleResult.Err(cleanupCode, cleanupMessage) =>
                        record.state = ExtensionLifecycleState.Quarantined
                        record.error += "; cleanup: ${cleanupCode}: ${cleanupMessage}"
                }
                records.add(record)
                return SafeLifecycleResult.Err(record.error)
            case HostLifecycleResult.Ok => record.state = ExtensionLifecycleState.Mounted
        }
        match (callHost({ => host.activate(provider.id, generation) })) {
            case HostLifecycleResult.Err(code, message) =>
                record.error = "${code}: ${message}"
                // A failed activation may already have published resources.
                // This generation has never admitted a lease, so dispose it.
                var cleanupFailed = false
                match (callHost({ => host.stopAdmitting(provider.id, generation) })) {
                    case HostLifecycleResult.Ok => ()
                    case HostLifecycleResult.Err(cleanupCode, cleanupMessage) =>
                        cleanupFailed = true
                        record.error += "; stop admission: ${cleanupCode}: ${cleanupMessage}"
                }
                match (callHost({ => host.dispose(provider.id, generation) })) {
                    case HostLifecycleResult.Ok => ()
                    case HostLifecycleResult.Err(cleanupCode, cleanupMessage) =>
                        cleanupFailed = true
                        record.error += "; cleanup: ${cleanupCode}: ${cleanupMessage}"
                }
                record.state = if (cleanupFailed) {
                    ExtensionLifecycleState.Quarantined
                } else { ExtensionLifecycleState.Failed }
                records.add(record)
                return SafeLifecycleResult.Err(record.error)
            case HostLifecycleResult.Ok =>
                record.state = ExtensionLifecycleState.Active
                record.accepting = true
                records.add(record)
                SafeLifecycleResult.Ok(())
        }
    }

    private func callHost(action: () -> HostLifecycleResult): HostLifecycleResult {
        try { action() } catch (error: Exception) {
            HostLifecycleResult.Err("host.lifecycle_exception", error.message)
        }
    }

    private func releaseRecord(record: ExtensionGenerationRecord): Unit {
        if (record.inFlight > 0u64) { record.inFlight -= 1u64 }
        if (record.inFlight == 0u64 && record.state == ExtensionLifecycleState.Draining) {
            let _ = disposeRecord(record)
        }
    }

    private func disposeRecord(record: ExtensionGenerationRecord): SafeLifecycleResult<Unit> {
        record.state = ExtensionLifecycleState.Disposing
        match (host.dispose(record.provider.id, record.generation)) {
            case HostLifecycleResult.Ok =>
                record.state = ExtensionLifecycleState.Inactive
                SafeLifecycleResult.Ok(())
            case HostLifecycleResult.Err(code, message) =>
                record.state = ExtensionLifecycleState.Quarantined
                record.error = "${code}: ${message}"
                SafeLifecycleResult.Err("${code}: ${message}")
        }
    }

    private func current(extensionId: String): ?ExtensionGenerationRecord {
        var selected: ?ExtensionGenerationRecord = None
        for (record in records where record.provider.id == extensionId &&
            record.state == ExtensionLifecycleState.Active && record.accepting) {
            match (selected) {
                case None => selected = Some(record)
                case Some(value) => if (record.generation > value.generation) { selected = Some(record) }
            }
        }
        selected
    }

    private func find(extensionId: String, generation: UInt64): ?ExtensionGenerationRecord {
        for (record in records where record.provider.id == extensionId && record.generation == generation) {
            return Some(record)
        }
        None
    }
}
