package agent_product

import agent_host_runtime.*

import agent_domain.*
import agent_store.*
import agent_extension_runtime.*

// All executable Product stores use the same Host-wide native allocation pool.
// This callback only accounts memory; actual source/plan/grant validation stays
// in Store. The generic historical inspector remains read-only and needs no
// allocation authority for loading compact plans.
func productOperationStore(database: SqliteDatabase,
    derivedSettlementFailureObserver!: ?(String, String, String, String) -> Unit = None): DurableOperationStore {
    hostOperationStore(database, derivedSettlementFailureObserver: derivedSettlementFailureObserver)
}
