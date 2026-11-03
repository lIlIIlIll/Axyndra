package agent_app

import agent_domain.*
import agent_product.*
import logical_json_payload.LogicalJsonOwnerReservation as RegistrySessionReservation161
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os == "Linux"]
private func registrySessionRepeatedActualCli161(installed: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let product = openProduct(config: ProductConfig(workspaceRoot: root,
        settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
        asyncEnabled: false)).value().getOrThrow()
    var probe: ?RegistrySessionReservation161 = None
    var plain: ?RegistrySessionCliConsumer161 = None
    var json: ?RegistrySessionCliConsumer161 = None
    try {
        let session = product.applicationSession()
        let source = root + "/source-雪"
        if (installed) {
            Directory.create(source + "/extensions", recursive: true)
            File.writeTo(source + "/package.json", "{\"name\":\"session-retirement-fixture\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
            File.writeTo(source + "/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE_WHILE_PRINTING');".toArray())
            let record = match (session.importLocalPlugin(source)) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => error.close(); throw IllegalStateException("actual maintenance import failed")
            }
            @Expect(appRegistryCliPrintRecord83r(record, "import"), 0)
        }
        let seed = session.plugins()
        let actual = seed.deriveCopiedDataPayment(65536); probe = Some(actual)
        let plainPayment = seed.deriveCopiedDataPayment(65536)
        let jsonPayment = seed.deriveCopiedDataPayment(65536)
        seed.close()
        let actualPlain = RegistrySessionCliConsumer161(session, plainPayment, false); plain = Some(actualPlain)
        let actualJson = RegistrySessionCliConsumer161(session, jsonPayment, true); json = Some(actualJson)
        let original = actual.retainedCustodyUsage113()
        for (index in 0..32) {
            // Real same-Session parsing, original maintenance business, Main
            // formatter and physical SDK stdout write+flush. The quoted token
            // and leading/trailing ASCII whitespace exercise actual route parity.
            @Expect(actualPlain.print(" \t/plu\"gins\" list\r\n"), 0)
            expectActualUsageFields163_3(actual.retainedCustodyUsage113(), original)
            @Expect(actualJson.print("\t/extensions doctor \n"), 0)
            expectActualUsageFields163_3(actual.retainedCustodyUsage113(), original)
            @Expect(actualPlain.print("  /plugins unknown-operation\t"), 1)
            expectActualUsageFields163_3(actual.retainedCustodyUsage113(), original)
            if (installed) {
                @Expect(actualPlain.print(" /plugins inspect \"" + source + "\" --json \t"), 0)
                expectActualUsageFields163_3(actual.retainedCustodyUsage113(), original)
            }
        }
        @Expect(actualPlain.closeAfterConsumersReturned161(), true)
        @Expect(actualJson.closeAfterConsumersReturned161(), true)
        expectActualUsageFields163_3(actual.retainedCustodyUsage113(), (original[0] - 133120, original[1], original[2] - 2))
    } finally {
        match (plain) { case Some(value) => let _ = value.closeAfterConsumersReturned161(); case None => () }
        match (json) { case Some(value) => let _ = value.closeAfterConsumersReturned161(); case None => () }
        match (probe) { case Some(value) => value.close(); case None => () }
        try { product.close().value().getOrThrow() }
        finally { remove(root, recursive: true) }
    }
    // This observes the actual live Registry bank, not an injected allocator.
    // Mounted generations and incomplete output still require their separate
    // real owners to retire; per-command return is not whole-Root evidence.
}

@When[os == "Linux"]
@Test
class RegistrySessionCliRetirement161Tests {
    @TestCase
    func emptySameSessionRepeatedPlainJsonAndOriginalErrorsRetireActualConsumerLoans(): Unit {
        registrySessionRepeatedActualCli161(false)
    }
    @TestCase
    func installedUnicodeInspectionAndDoctorRetireActualMainCopiesWithoutExecutingPlugin(): Unit {
        registrySessionRepeatedActualCli161(true)
    }
}

private func expectActualUsageFields163_3(actual: (Int64, Int64, Int64), expected: (Int64, Int64, Int64)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
    @Expect(actual[2], expected[2])
}
