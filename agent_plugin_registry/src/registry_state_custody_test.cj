package agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import std.collection.*
import std.fs.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*

private func custodyAssertAllCapacityAvailable(): Unit {
    let actual = ArrayList<LogicalJsonOwnerReservation>()
    try { for (_ in 0..8) { actual.add(reserveNativeControlMetadata(1)) }; @Expect(actual.size,8) }
    finally { for (value in actual) { value.close() } }
}


// Fill the process-wide bank with 16 MiB-floor owners until it has no room for
// one more, so a test can assert refusal regardless of the configured
// aggregate. Each returned reservation is a real owner and must be closed.


// Fill the process-wide bank until exactly ONE more 16 MiB-floor owner still
// fits, so a test can assert that the next reservation is refused regardless
// of the configured aggregate. Returned reservations must be closed.


// Fill the process-wide bank until it refuses one more 16 MiB-floor owner, so a
// test can assert refusal regardless of the configured aggregate. Every
// returned reservation is a real owner and must be closed by the test.
private func fillRegistryBankToCapacity(): ArrayList<LogicalJsonOwnerReservation> {
    let held = ArrayList<LogicalJsonOwnerReservation>()
    while (true) {
        try { held.add(reserveNativeControlMetadata(1)) }
        catch (_: LogicalJsonPayloadError) { break }
    }
    return held
}

@Test
class RegistryStateCustodyTests {
    @TestCase
    func restoredCallerMetadataMustFitTheRealSharedPoolBeforeRegistryAdoptsItsGraph(): Unit {
        let fixture=RegistryGenerationFixture(1)
        let pins=fixture.capture()
        var pressure=ArrayList<LogicalJsonOwnerReservation>()
        try {
            let original=fixture.records[0]
            // This is an explicit foreign caller INPUT built using the
            // actual original business values. It exposes no Registry getter;
            // the input clears its aliases before the source owner closes.
            let caller=RegistryCallerInputFixture78(original)
            let source=original.descriptor
            try {
            pressure=fillRegistryBankToCapacity()
            @Expect(fixture.registry.restoreRecord(caller.input).isOk(),false)
            @Expect(fixture.registry.list().size,1)
            @Expect(fixture.registry.get("pi:generation-0").getOrThrow().descriptor.capabilityCount,
                source.capabilityCount)
            for(value in pressure){value.close()};pressure.clear()
            @Expect(fixture.registry.restoreRecord(original).isOk(),true)
            let current=fixture.registry.get("pi:generation-0").getOrThrow()
            let captured=match(fixture.registry.captureExecutionPin(current)){
                case PluginRegistryResult.Ok(value)=>value
                case PluginRegistryResult.Err(error)=>throw registryTestOwnedFailure78(error)
            }
            try{@Expect(captured.current().isOk(),true)}finally{captured.close()}
            } finally { caller.close() }
        }finally{for(pin in pins){pin.close()};for(value in pressure){value.close()};fixture.close()}
        custodyAssertAllCapacityAvailable()
    }

    @TestCase
    func publicInspectionAfterCapturePrepaysDenseDomAndKeepsSuccessfulResultPayment(): Unit {
        let fixture=RegistryGenerationFixture(1)
        let pins=fixture.capture()
        var pressure=ArrayList<LogicalJsonOwnerReservation>()
        try {
            @Expect(registryTestInspectInstalled78(fixture.registry, fixture.records[0]).isOk(),true)
            let path=registryFixturePackage(fixture.root,"8.0.0")
            let original=String.fromUtf8(File.readFrom(path+"/package.json")).trimAscii()
            let text=StringBuilder();text.append(original[..original.size-1]);text.append(",\"dense\":[")
            for(index in 0..50000){if(index!=0){text.append(",")};text.append("null")}
            text.append("]}");File.writeTo(path+"/package.json",text.toString().toArray())
            pressure=fillRegistryBankToCapacity()
            @Expect(fixture.registry.inspect(path).isOk(),false)
            @Expect(fixture.registry.list().size,1)
            for(pin in pins){pin.close()}
            fixture.registry.close()
            let available=reserveNativeControlMetadata(1);available.close()
        }finally{for(pin in pins){pin.close()};for(value in pressure){value.close()};fixture.close()}
        custodyAssertAllCapacityAvailable()
    }

    @TestCase
    func actualCurrentRegistryStateRetainsTheSingleOriginalFloorAfterLastPinCloses(): Unit {
        let fixture = RegistryGenerationFixture(9)
        var pressure = ArrayList<LogicalJsonOwnerReservation>()
        let pins = ArrayList<PluginRegistryExecutionPin>()
        try {
            pressure=fillRegistryBankToCapacity()
            pins.add(all:fixture.capture())
            for (pin in pins) { pin.close() }
            // A still-readable actual Registry must retain its decoded state,
            // even though no worker pin or active physical fence remains.
            @Expect(fixture.registry.list().size,9)
            var rejected=false
            try { let impossible=reserveNativeControlMetadata(1);impossible.close() }
            catch (_:LogicalJsonPayloadError) { rejected=true }
            @Expect(rejected,true)
            fixture.registry.close();fixture.registry.close()
            let available=reserveNativeControlMetadata(1);available.close()
        } finally {
            for (pin in pins) { pin.close() }
            for (owner in pressure) { owner.close() };fixture.close()
        }
        custodyAssertAllCapacityAvailable()
    }

    @TestCase
    func genuineConstructorMustReserveBeforeAnyInstalledMetadataCanBeDecoded(): Unit {
        let fixture=RegistryGenerationFixture(1)
        var pressure=ArrayList<LogicalJsonOwnerReservation>()
        var reopened:?PluginRegistry=None
        try {
            fixture.registry.close()
            pressure=fillRegistryBankToCapacity()
            var rejected=false
            try { reopened=Some(PluginRegistry(fixture.root+"/settings",fixture.root)) }
            catch (_:LogicalJsonPayloadError) { rejected=true }
            @Expect(rejected,true);@Expect(reopened.isNone(),true)
            for (value in pressure) { value.close() };pressure.clear()
            let actual=PluginRegistry(fixture.root+"/settings",fixture.root);reopened=Some(actual)
            @Expect(actual.list().size,1)
        } finally {
            match(reopened){case Some(value)=>value.close();case None=>()}
            for(value in pressure){value.close()};fixture.close()
        }
        custodyAssertAllCapacityAvailable()
    }

    @TestCase
    func actualReloadAndCaptureShareOneCustodyButPreserveIndependentGenerationRevocation(): Unit {
        let fixture=RegistryGenerationFixture(17)
        let pins=ArrayList<PluginRegistryExecutionPin>()
        var pressure=ArrayList<LogicalJsonOwnerReservation>()
        try {
            pressure=fillRegistryBankToCapacity()
            pins.add(all:fixture.capture())
            // The real same-object writer reloads old+new under its custody.
            // A newly parsed state never borrows the old pin's authority.
            let target="pi:generation-0"
            @Expect(fixture.registry.setEnabled(target,false).isOk(),true)
            @Expect(!pins[0].current().isOk(),true)
            @Expect(fixture.registry.setEnabled(target,true).isOk(),true)
            let current=fixture.registry.get(target).getOrThrow()
            let next=match(fixture.registry.captureExecutionPin(current)){
                case PluginRegistryResult.Ok(value)=>value
                case PluginRegistryResult.Err(error)=>throw registryTestOwnedFailure78(error)
            }
            try { @Expect(next.current().isOk(),true);@Expect(!pins[0].current().isOk(),true) }
            finally { next.close() }
        } finally {
            for(pin in pins){pin.close()};for(value in pressure){value.close()};fixture.close()
        }
        custodyAssertAllCapacityAvailable()
    }

    @TestCase
    func closedRegistryCannotMintAnotherPinButActualOutstandingFenceKeepsItsPayment(): Unit {
        let fixture=RegistryGenerationFixture(1)
        let pins=fixture.capture()
        var pressure=ArrayList<LogicalJsonOwnerReservation>()
        let held=match(pins[0].enter()){
            case PluginImportResult.Ok(value)=>value
            case PluginImportResult.Err(error)=>throw IllegalStateException(error.code)
        }
        try {
            pressure=fillRegistryBankToCapacity()
            let data=fixture.records[0]
            fixture.registry.close();pins[0].close()
            var rejected=false
            try{let _=fixture.registry.captureExecutionPin(data)}
            catch(error:PluginRegistryWriteError){rejected=error.code=="plugin.registry_closed"}
            @Expect(rejected,true)
            var unavailable=false
            try{let value=reserveNativeControlMetadata(1);value.close()}
            catch(_:LogicalJsonPayloadError){unavailable=true}
            @Expect(unavailable,true)
            held.close();held.close()
            let value=reserveNativeControlMetadata(1);value.close()
        }finally{held.close();for(pin in pins){pin.close()};for(value in pressure){value.close()};fixture.close()}
        custodyAssertAllCapacityAvailable()
    }
}
