package agent_app

import agent_domain.*
import agent_product.*
import logical_json_payload.LogicalJsonOwnerReservation as RegistryCliReservation158
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os == "Linux"]
private func registryCliPrintRepeatedActual158(installed: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let product = openProduct(config: ProductConfig(workspaceRoot: root,
        settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
        asyncEnabled: false)).value().getOrThrow()
    var probe: ?RegistryCliReservation158 = None
    try {
        let session = product.applicationSession()
        if (installed) {
            let source = root + "/source-雪"
            Directory.create(source + "/extensions", recursive: true)
            File.writeTo(source + "/package.json", "{\"name\":\"print-retirement-fixture\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
            File.writeTo(source + "/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE_WHILE_PRINTING');".toArray())
            let record = match (session.importLocalPlugin(source)) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => error.close(); throw IllegalStateException("actual maintenance import failed")
            }
            @Expect(appRegistryCliPrintRecord83r(record, "import"), 0)
        }
        let seed = session.plugins()
        let actual = seed.deriveCopiedDataPayment(65536); probe = Some(actual)
        seed.close()
        let original = actual.retainedCustodyUsage113()
        for (index in 0..32) {
            // Real Registry snapshots, real 8-field DOM/plain renderer and
            // actual SDK stdout write+flush. The original bank is observed;
            // no injected allocator or guessed private reference count exists.
            @Expect(runPluginCli(session, if (index % 2 == 0) { ["list", "--json"] } else { ["list"] }), 0)
            expectActualUsageFields163_3(actual.retainedCustodyUsage113(), original)
        }
    } finally {
        match (probe) { case Some(value) => value.close(); case None => () }
        try { product.close().value().getOrThrow() }
        finally { remove(root, recursive: true) }
    }
    // This checks actual per-consumer return to a live Registry baseline.
    // It does not claim that unrelated mounted Product generations or an
    // incomplete-output path have acknowledged Root retirement.
}

@When[os == "Linux"]
@Test
class RegistryCliPrintRetirement158Tests {
    @TestCase
    func emptyListRepeatedRealWriteFlushReturnsAllConsumerLoansToOriginalBank(): Unit {
        registryCliPrintRepeatedActual158(false)
    }
    @TestCase
    func installedUnicodeLocatorRepeatedPlainAndJsonPrintingReturnsAllConsumerLoans(): Unit {
        registryCliPrintRepeatedActual158(true)
    }
}

private func expectActualUsageFields163_3(actual: (Int64, Int64, Int64), expected: (Int64, Int64, Int64)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
    @Expect(actual[2], expected[2])
}
