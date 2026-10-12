package agent_domain

import yjson.*
import yjson_support.*

public let PLUGIN_LIVE_POLICY_TERMINAL_DATA_SCHEMA="axyndra.plugin-live-policy-terminal-data/v1"

// A Host-frozen bounded descriptor only. No Native data can turn this into
// a known Receipt, handoff, Source or publication. Store must independently
// inspect the complete actual same-parent prefix, current full Source, pin,
// and the exact Host-owned Blob bytes before a terminal audit is recorded.
public func pluginLivePolicyTerminalDataValid(value:AgentValue,parentOperationId:String,parentBindingDigest:String):Bool{
    try{
        if(!documentContractIdentifier(parentOperationId) || !httpIntentDigest(parentBindingDigest) ||
            !httpIntentExactFields(value,["schema","parent_operation_id","parent_binding_digest","prior_receipts","result_payload","is_error"]) ||
            httpIntentText(value,"schema")!=PLUGIN_LIVE_POLICY_TERMINAL_DATA_SCHEMA ||
            httpIntentText(value,"parent_operation_id")!=parentOperationId ||
            httpIntentText(value,"parent_binding_digest")!=parentBindingDigest ||
            value.field("is_error").getOrThrow().unifiedKind!=ValueKind.Boolean){return false}
        let ledger=value.field("prior_receipts").getOrThrow()
        let through=documentContractInteger(ledger.field("through_sequence").getOrThrow())
        if(!pluginLivePolicyLedgerReferenceValid(ledger,parentOperationId,through)){return false}
        let payload=parsePluginDocumentPayloadReference(value.field("result_payload").getOrThrow()).value().getOrThrow()
        payload.bytes>0
    }catch(_:Exception){false}
}
