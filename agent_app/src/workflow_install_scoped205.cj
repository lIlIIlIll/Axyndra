package agent_app

import agent_domain.*
import agent_product.*
import std.collection.*
import std.fs.*
import std.sync.*
import yjson_support.*

private let appPlanWorkflowInstallationScopes205 = AppPlanWorkflowInstallationScopes205()

// Private synchronous installation only. Every child comes from the actual
// imported Registry record. No global legacy debt, invocation or Source is
// cleared. A failed/unknown installation retains this exact prelinked owner.
class AppPlanWorkflowInstallationFrame205 {
    var next205: ?AppPlanWorkflowInstallationFrame205 = None
    private var header205: ?LogicalJsonOwnerReservation
    private var owners205: ?ArrayList<OwnedRegistryUtf8> = Some(ArrayList<OwnedRegistryUtf8>())
    private var payments205: ?ArrayList<LogicalJsonOwnerReservation> = Some(ArrayList<LogicalJsonOwnerReservation>())
    private var bytes205: ?ArrayList<Array<UInt8>> = Some(ArrayList<Array<UInt8>>())
    private var texts205: ?ArrayList<String> = Some(ArrayList<String>())
    init(header: LogicalJsonOwnerReservation) { header205 = Some(header) }
    func copyText205(result: PluginRegistryResult<OwnedRegistryUtf8>): String {
        let owner = match (result) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                error.close(); throw LogicalJsonPayloadError("workflow installation metadata is unavailable") }
        owners205.getOrThrow().add(owner)
        let paid = owner.deriveCopiedDataPayment(appRegistryCopyInvoice83(owner.byteCount, 0))
        payments205.getOrThrow().add(paid)
        let copied = Array<UInt8>(owner.byteCount, repeat: 0u8)
        bytes205.getOrThrow().add(copied)
        for (index in 0..owner.byteCount) { copied[index] = owner.byteAt(index) }
        let text = String.fromUtf8(copied)
        texts205.getOrThrow().add(text)
        text
    }
    private func closeOwners205(): Unit {
        let actual = owners205; owners205 = None<ArrayList<OwnedRegistryUtf8>>
        match (actual) { case Some(values) => for (value in values) { value.close() }; case None => () }
    }
    private func closePayments205(): Unit {
        let actual = payments205; payments205 = None<ArrayList<LogicalJsonOwnerReservation>>
        match (actual) { case Some(values) => for (value in values) { value.close() }; case None => () }
    }
    func returnAfterWholeInstallationFrame205(): Unit {
        // The entire enable/JSON/UTF8/write/error producer returned Unit.
        // Its returned success exports no copied Registry leaf or callback.
        texts205 = None<ArrayList<String>>; bytes205 = None<ArrayList<Array<UInt8>>>
        closeOwners205(); closePayments205()
        appPlanWorkflowInstallationScopes205.remove205(this)
        let actual = header205; header205 = None<LogicalJsonOwnerReservation>
        match (actual) { case Some(value) => value.close(); case None => () }
    }
}

private class AppPlanWorkflowInstallationScopes205 {
    private let lock = Mutex()
    private var head: ?AppPlanWorkflowInstallationFrame205 = None
    func register205(actual: AppPlanWorkflowInstallationFrame205): Unit {
        lock.lock(); try { actual.next205 = head; head = Some(actual) } finally { lock.unlock() }
    }
    func remove205(actual: AppPlanWorkflowInstallationFrame205): Unit {
        lock.lock()
        try {
            var previous: ?AppPlanWorkflowInstallationFrame205 = None
            var current = head
            while (current.isSome()) {
                let value = current.getOrThrow()
                if (refEq(value, actual)) {
                    match (previous) { case Some(parent) => parent.next205 = value.next205; case None => head = value.next205 }
                    value.next205 = None<AppPlanWorkflowInstallationFrame205>; return
                }
                previous = current; current = value.next205
            }
            throw IllegalStateException("workflow installation owner is not registered")
        } finally { lock.unlock() }
    }
}

private func appInstallPlanWorkflowFrame205(actual: AppPlanWorkflowInstallationFrame205,
    product: ProductRuntime, record: ProductPluginRecord): Unit {
    match (product.setPluginEnabled(actual.copyText205(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
        case PluginRegistryResult.Ok(value) => value.close()
        case PluginRegistryResult.Err(error) =>
            let code = error.code; error.close(); throw IllegalStateException(code) }
    let directory = product.settingsRoot + "/plugins"
    if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
    let path = directory + "/policies.json"
    if (exists(Path(path))) { throw IllegalStateException("app Plan fixture refuses to overwrite operator selection") }
    File.writeTo(path, stringifyUnifiedJson(objectValue([ValueField("version", integerValue(1)),
        ValueField("bindings", objectValue([ValueField("workflow", objectValue([
            ValueField("namespace", textValue(actual.copyText205(record.descriptor.copyText(PluginDescriptorText.Namespace)))),
            ValueField("provider", textValue("propose")),
            ValueField("package_digest", textValue(actual.copyText205(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
            ValueField("plan_tool", textValue("plan_write"))]))]))])).toArray())
}

func appInstallPlanWorkflowScoped205(product: ProductRuntime, record: ProductPluginRecord): Unit {
    if (product.settingsRoot.size > (134217728 - 65536) / 64) {
        throw LogicalJsonPayloadError("workflow installation paths exceed the original aggregate") }
    let header = record.descriptor.deriveCopiedDataPayment(65536 + product.settingsRoot.size * 64)
    let actual = try { AppPlanWorkflowInstallationFrame205(header) }
        catch (error: Exception) { header.close(); throw error }
    // Registration and fixed holder payment precede every copied String/DOM
    // and every backend action. Unknown/throw leaves this exact cell paid.
    appPlanWorkflowInstallationScopes205.register205(actual)
    appInstallPlanWorkflowFrame205(actual, product, record)
    actual.returnAfterWholeInstallationFrame205()
}
