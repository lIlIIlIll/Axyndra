package registry_process_contract

import agent_plugin_registry.*
import agent_domain.*
import std.collection.*
import std.env.*
import std.fs.*
import std.time.*

// A persistent real registry is constructed before READY. The Python parent
// opens its gate only after another OS process has committed a mutation.
main(): Int64 {
    let args=getCommandLine()
    if (args.size!=7) { return 64 }
    let registry=PluginRegistry(args[1],args[2])
    try {
    File.writeTo(args[3]+".ready","ready".toArray())
    let started=MonoTime.now()
    while (!exists(Path(args[3]+".go"))) {
        if (MonoTime.now()-started>Duration.second*20) { return 65 }
        sleep(Duration.millisecond*5)
    }
    match (args[4]) {
        case "import" => report(registry.importLocal(args[5]))
        case "workspace" => report(registry.importLocal(args[5],PluginInstallScope.Workspace))
        case "update" => report(registry.updateLocal(args[6],args[5]))
        case "disable" => report(registry.setEnabled(args[6],false))
        case "gc" =>
            match (registry.garbageCollect()) {
                case PluginImportResult.Ok(_) => println("OK"); 0
                case PluginImportResult.Err(error) => println(error.code); 2
            }
        case _ => 64
    }
    } finally { registry.close() }
}

func report(value: PluginRegistryResult<ProductPluginRecord>): Int64 {
    match (value) {
        case PluginRegistryResult.Ok(record) => reportOwnedRecord96(record)
        case PluginRegistryResult.Err(error) => try { println(error.code); 2 } finally { error.close() }
    }
}

// This subprocess consumes one exclusive maintenance result. Its fixed
// private slot is empty until the real Registry output arrives. Every raw
// byte/String/output copy is funded by that output's original Native bank.
private class RegistryProcessPrintFrame96 {
    var active=false
    var record:?ProductPluginRecord=None<ProductPluginRecord>
    var namespaceOwner:?OwnedRegistryUtf8=None<OwnedRegistryUtf8>
    var versionOwner:?OwnedRegistryUtf8=None<OwnedRegistryUtf8>
    var namespacePayment:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    var versionPayment:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    var namespaceBytes:?Array<UInt8> =None<Array<UInt8>>
    var versionBytes:?Array<UInt8> =None<Array<UInt8>>
    var namespaceText:?String=None<String>
    var versionText:?String=None<String>
    init(){}
    func prepare(actual:ProductPluginRecord):Unit{
        if(active){throw LogicalJsonPayloadError("the exclusive registry printer retains its failed output")}
        active=true;record=Some(actual)
        namespaceOwner=Some(registryProcessText96(actual.descriptor.copyText(PluginDescriptorText.Namespace)))
        versionOwner=Some(registryProcessText96(actual.descriptor.copyText(PluginDescriptorText.Version)))
        // Both complete invoices precede private Array/String allocation.
        namespacePayment=Some(namespaceOwner.getOrThrow().deriveCopiedDataPayment(
            registryProcessPrintInvoice96(namespaceOwner.getOrThrow().byteCount)))
        versionPayment=Some(versionOwner.getOrThrow().deriveCopiedDataPayment(
            registryProcessPrintInvoice96(versionOwner.getOrThrow().byteCount)))
    }
    func printActual():Int64{
        let namespaceSource=namespaceOwner.getOrThrow()
        let versionSource=versionOwner.getOrThrow()
        namespaceBytes=Some(Array<UInt8>(namespaceSource.byteCount,{index=>namespaceSource.byteAt(index)}))
        versionBytes=Some(Array<UInt8>(versionSource.byteCount,{index=>versionSource.byteAt(index)}))
        namespaceText=Some(String.fromUtf8(namespaceBytes.getOrThrow()))
        versionText=Some(String.fromUtf8(versionBytes.getOrThrow()))
        println("OK:"+namespaceText.getOrThrow()+":"+versionText.getOrThrow());0
    }
    func retireReturnedPrint():Unit{
        // printActual's real concatenation/println frame has returned. Remove
        // every actual copied-data field before closing either data payment.
        namespaceText=None<String>;versionText=None<String>
        namespaceBytes=None<Array<UInt8>>;versionBytes=None<Array<UInt8>>
        match(namespaceOwner){case Some(value)=>namespaceOwner=None<OwnedRegistryUtf8>;value.close();case None=>()}
        match(versionOwner){case Some(value)=>versionOwner=None<OwnedRegistryUtf8>;value.close();case None=>()}
        match(namespacePayment){case Some(value)=>namespacePayment=None<LogicalJsonOwnerReservation>;value.close();case None=>()}
        match(versionPayment){case Some(value)=>versionPayment=None<LogicalJsonOwnerReservation>;value.close();case None=>()}
        match(record){case Some(value)=>record=None<ProductPluginRecord>;value.close();case None=>()}
        active=false
    }
}
private let registryProcessPrintFrame96=RegistryProcessPrintFrame96()
private func registryProcessPrintInvoice96(bytes:Int64):Int64{
    if(bytes<0 || bytes>(134217728-8192)/64){
        throw LogicalJsonPayloadError("registry print copies cannot fit the original shared capacity")}
    bytes*64+8192
}
private func registryProcessText96(result:PluginRegistryResult<OwnedRegistryUtf8>):OwnedRegistryUtf8{
    match(result){case PluginRegistryResult.Ok(value)=>value
        case PluginRegistryResult.Err(error)=>
            try{throw IllegalStateException(error.code)}finally{error.close()}}
}
private func reportOwnedRecord96(record:ProductPluginRecord):Int64{
    registryProcessPrintFrame96.prepare(record)
    let result=registryProcessPrintFrame96.printActual()
    registryProcessPrintFrame96.retireReturnedPrint()
    // An unknown copy/println exception does not reach the retirement above.
    // Its actual private fields/payments remain in this same fixed collector.
    result
}
