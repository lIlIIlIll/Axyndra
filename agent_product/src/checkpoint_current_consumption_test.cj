package agent_product

import agent_domain.*
import agent_domain.CancellationSource as CheckpointConsumptionCancellation11317
import agent_store.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// Real mounted Native/query and real SQLite rollback controls for the neutral
// data loan. These controls create no canonical Source, Receipt, cut or Item;
// they do not stand in for the installed Core/Direct checkpoint-save gates.
@Test
class CheckpointCurrentConsumption11317Tests {
    @TestCase
    func actualQueryCancellationDuringDataTransactionRollsBack(): Unit {
        checkpointCurrentConsumptionRollback11317(false)
    }
    @TestCase
    func actualConfigurationByteChangeDuringDataTransactionRollsBack(): Unit {
        checkpointCurrentConsumptionRollback11317(true)
    }
}

private func checkpointCurrentConsumptionRollback11317(configuration: Bool): Unit {
    let f = CompactionPolicyFixture(hybrid: false)
    let host = ProductJavaScriptPluginHost(settingsRoot: f.root + "/settings")
    let cancellation = CheckpointConsumptionCancellation11317()
    var owned: ?ProductCompactionReferenceQuery = None<ProductCompactionReferenceQuery>
    let observed = ArrayList<String>()
    let kinds = ArrayList<AgentErrorKind>()
    try {
        lifecycleTestRequire(host.mount(f.record.getOrThrow()))
        let selection = lifecycleTestRequire(loadProductPolicySelection(f.root + "/settings", "compaction"))
        let binding = lifecycleTestRequire(host.policyProviderBinding(selection.namespace, selection.provider))
        let query = ProductCompactionReferenceQuery(host, selection, "current-consumption11317", ThreadId(f.session.value),
            cancellation.token, "current-consumption11317", binding)
        owned = Some(query)
        let actual = query.query("reference_layout", [])
        @Expect(httpIntentExactFields(actual, ["arguments", "state", "event_batch"]))
        query.release(actual)
        let before = f.originalItems()
        f.database.execute("CREATE TABLE checkpoint_data_loan_control11317(value INTEGER NOT NULL)")
        let rejected = try {
            query.consumeCurrentData113({ current: () -> Result<Unit> =>
                f.database.transaction<Result<Unit>>({ tx: SqliteTransaction =>
                    tx.execute("INSERT INTO checkpoint_data_loan_control11317(value) VALUES (1)")
                    if (configuration) {
                        let path = f.root + "/settings/plugins/policies.json"
                        File.writeTo(path, (String.fromUtf8(File.readFrom(path)) + "\n").toArray())
                    } else { cancellation.cancel() }
                    match (current()) {
                        case Result.Err(error) =>
                            observed.add(error.code)
                            kinds.add(error.kind)
                            // Returning Err would commit in the real database.
                            // A failed same-TX proof must throw before COMMIT.
                            throw IllegalStateException("actual data loan current witness rejected")
                        case Result.Ok(_) => Result<Unit>.Ok(())
                    }
                })
            })
            false
        } catch (_: Exception) { true }
        @Expect(rejected)
        @Expect(observed.size, 1)
        if (configuration) { @Expect(observed[0], "policy.configuration_changed") }
        else { @Expect(kinds[0], AgentErrorKind.Cancelled) }
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM checkpoint_data_loan_control11317"), 0)
        @Expect(f.originalItems(), before)
        f.noExecutionOrCheckpoint()
    } finally {
        match (owned) { case Some(value) => value.close(); case None => () }
        cancellation.close(); let _ = host.close(); f.close()
    }
}
