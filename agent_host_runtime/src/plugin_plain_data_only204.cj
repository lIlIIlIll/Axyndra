package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// Independent DATA only, funded by the actual installed Registry descriptor.
// These values cannot admit a Source, worker, tool or canonical projection.
class HostPlainDataOnlyInput204 {
    let payment: HostPaidValueProjection151
    let identity: String
    init(payment: HostPaidValueProjection151, identity: String) { this.payment = payment; this.identity = identity }
}
class HostPlainDataOnlyFrame204 {
    var input: ?HostPlainDataOnlyInput204 = None<HostPlainDataOnlyInput204>
    var nativeAttempted = false
    var nativeReturned = false
    var nativeSucceeded = false
    var observerReturned = false
    var awaitReturned = false
    func detachReturnedInput204(): ?HostPaidValueProjection151 {
        // Return only the DATA owner after clearing the actual input holder
        // and its independently copied identity; the whole helper must return
        // before that owner is closed by the outer executor.
        let value = input.map({ actual => actual.payment })
        input = None<HostPlainDataOnlyInput204>; value
    }
}
private func hostPlainDataOnlyPayment204(host: HostJavaScriptPluginHost, namespace: String,
    generation: UInt64): Result<LogicalJsonOwnerReservation> {
    let descriptor = match (host.servicePackage(namespace, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try { Result.Ok(descriptor.deriveCopiedDataPayment(1048576)) }
    finally { descriptor.close() }
}
func hostCopyPlainDataOnlyInput204(host: HostJavaScriptPluginHost, namespace: String, generation: UInt64,
    identity: String, value: AgentValue): Result<HostPlainDataOnlyInput204> {
    let payment = match (hostPlainDataOnlyPayment204(host, namespace, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let copy = try { HostPaidValueProjection151(payment) } catch (error: Exception) { payment.close(); throw error }
    try { Result.Ok(hostPlainDataOnlyInputCopyFrame204(copy, identity, value)) }
    catch (error: Exception) { copy.closeUnpublished151(); throw error }
}
private func hostPlainDataOnlyInputCopyFrame204(copy: HostPaidValueProjection151, identity: String,
    value: AgentValue): HostPlainDataOnlyInput204 {
    copy.fundAdditional151(identity.size * 6 + 8192, 8)
    let copied = String.fromUtf8(identity.toArray())
    copy.retainValue151(1, value); copy.projectValue151(1)
    HostPlainDataOnlyInput204(copy, copied)
}
func hostCopyPlainDataOnlyResult204(host: HostJavaScriptPluginHost, namespace: String, generation: UInt64,
    identity: String, value: AgentValue, isError: Bool): Result<ToolResult> {
    let payment = match (hostPlainDataOnlyPayment204(host, namespace, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let copy = try { HostPaidValueProjection151(payment) } catch (error: Exception) { payment.close(); throw error }
    var publicationAttempted = false
    try {
        copy.fundAdditional151(identity.size * 6 + 8192, 8)
        let copiedIdentity = String.fromUtf8(identity.toArray())
        copy.retainValue151(1, value); copy.projectValue151(1)
        let cell = [None<AgentValue>]
        copy.withValue151({ actual => cell[0] = Some(actual) })
        publicationAttempted = true
        let lease = copy.publicationLease151()
        let result = ToolResult(copiedIdentity, cell[0].getOrThrow(), isError: isError, payloadLease: Some(lease))
        cell[0] = None<AgentValue>
        Result.Ok(result)
    } finally { if (!publicationAttempted) { copy.closeUnpublished151() } }
}
