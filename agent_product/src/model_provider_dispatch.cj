package agent_product

import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_host_runtime.*
import model_provider_runtime.*

// Compatibility for the existing private actual SQLite test fixture. No
// callback constructor or adapter is exported to plugin/SDK composition.
class ProductModelDispatchCurrentAuthority <: HostModelDispatchCurrentAuthority {
    private let current: () -> Result<Unit>
    private let token: CancellationToken
    init(current: () -> Result<Unit>, token: CancellationToken) { this.current = current; this.token = token }
    public func requireCurrent(): Result<Unit> { current() }
    public func cancellation(): CancellationToken { token }
}
class ProductModelProviderDispatchGate <: HostModelProviderDispatchGate {
    init(reader: SqliteModelProviderDispatchReader, runtimes: ThreadRuntimeRegistry,
        binding: ModelProviderBinding, grantCurrent: () -> Result<Unit>, grantCancellation: CancellationToken) {
        super(reader, runtimes, binding, ProductModelDispatchCurrentAuthority(grantCurrent, grantCancellation))
    }
}
func modelProcessAdmissionDenied<T>(): Result<T> { hostModelProcessAdmissionDenied<T>() }
