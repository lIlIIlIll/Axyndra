package agent_store_contract

import agent_domain.*
import agent_store.*
import yjson.*
import yjson_support.*

// Corrupt an already-persisted real fixture plan, never synthesize authority.
// The public loader proves the original operations/effect record agreement
// before tampering. Some callers deliberately leave those records different;
// this helper neither writes them nor loads/repairs the corrupted result.
func documentTamperStoredPlan(database: SqliteDatabase, store: DurableOperationStore,
    operation: OperationId, run: RunId, replacement: NormalizedOperationPlan): String {
    let label = "actual document plan tamper fixture " + operation.value
    let rows = database.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",
        [SqlParameter.Text(operation.value), SqlParameter.Text(run.value)])
    expect(rows.size == 1, label + " starts from one actual persisted plan")
    let encoded = rows[0].required(0)
    let effects = database.query("SELECT normalized_plan FROM operation_effect_records WHERE operation_id=?",
        [SqlParameter.Text(operation.value)])
    expect(effects.size == 1 && effects[0].required(0) == encoded,
        label + " original operation and effect record contain the same real plan")
    let current = httpContractRequire(store.loadPlan(operation, run), label + " real original plan loads")
    let original = decodeStoredValue(encoded)
    let changed = decodeStoredValue(encoded)
    expect(encodeStoredValue(original) == encoded &&
        encodeStoredValue(original.field("arguments").getOrThrow()) == encodeStoredValue(current.canonicalArguments) &&
        original.field("digest").getOrThrow().text == current.bindingDigest &&
        original.field("effective_arguments_digest").getOrThrow().text == current.implementation.effectiveArgumentsDigest,
        label + " public loader and durable value describe the same original plan")
    // documentServicePlan's factory changes only arguments/binding-derived
    // implementation digest, plus effect when CAS is deliberately made read.
    expect(current.toolName == replacement.toolName && current.cwd == replacement.cwd &&
        current.retryDisposition == replacement.retryDisposition && current.idempotencyKey == replacement.idempotencyKey &&
        current.implementation.toolId == replacement.implementation.toolId &&
        current.implementation.toolVersion == replacement.implementation.toolVersion &&
        current.implementation.implementationFingerprint == replacement.implementation.implementationFingerprint &&
        current.implementation.schemaDigest == replacement.implementation.schemaDigest &&
        current.implementation.replayContractVersion == replacement.implementation.replayContractVersion &&
        current.resolvedPaths.isEmpty() && replacement.resolvedPaths.isEmpty() &&
        current.resolvedHosts.isEmpty() && replacement.resolvedHosts.isEmpty() &&
        current.relevantEnvironment.isEmpty() && replacement.relevantEnvironment.isEmpty() &&
        current.contextReadFacts.isEmpty() && replacement.contextReadFacts.isEmpty() &&
        canonicalAgentValue(networkPolicyCanonicalValue(current.networkPolicy)) ==
            canonicalAgentValue(networkPolicyCanonicalValue(replacement.networkPolicy)),
        label + " original factory keeps other plan properties unchanged")
    expect(current.requiredCapabilities.size == replacement.requiredCapabilities.size,
        label + " factory keeps capability count")
    for (index in 0..current.requiredCapabilities.size) {
        expect(current.requiredCapabilities[index].kind == replacement.requiredCapabilities[index].kind &&
            current.requiredCapabilities[index].resource == replacement.requiredCapabilities[index].resource,
            label + " factory keeps each capability")
    }
    let currentNever = match (current.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }
    let replacementNever = match (replacement.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }
    expect(currentNever && replacementNever, label + " original factory keeps NeverReplay")
    let effect = match (replacement.effectClass) {
        case OperationEffectClass.ReadOnly => "read_only"
        case OperationEffectClass.ExternalMutation => "external_mutation"
        case OperationEffectClass.WorkspaceMutation => throw IllegalStateException("document fixture factory cannot select workspace mutation")
    }
    changed.put("arguments", replacement.canonicalArguments)
    changed.put("digest", textValue(replacement.bindingDigest))
    changed.put("effective_arguments_digest", textValue(replacement.implementation.effectiveArgumentsDigest))
    changed.put("effect", textValue(effect))
    expect(changed.fields.size == original.fields.size, label + " corruption adds no plan fields")
    for (field in original.fields) {
        if (!["arguments", "digest", "effective_arguments_digest", "effect"].contains(field.name)) {
            expect(encodeStoredValue(changed.field(field.name).getOrThrow()) == encodeStoredValue(field.value),
                label + " preserves original durable field " + field.name)
        }
    }
    let result = encodeStoredValue(changed)
    expect(result != encoded, label + " deliberate plan corruption changes actual bytes")
    result
}
