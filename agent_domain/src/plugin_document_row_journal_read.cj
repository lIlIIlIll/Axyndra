package agent_domain

import std.collection.*
import yjson.*
import yjson_support.*

public let PLUGIN_DOCUMENT_ROW_JOURNAL_READ_SCHEMA="axyndra.plugin-document-row-journal-read/v1"
public let PLUGIN_DOCUMENT_ROW_JOURNAL_READ_RESULT_SCHEMA="axyndra.plugin-document-row-journal-read-result/v1"
public let OPAQUE_ROW_JOURNAL_MANIFEST_SCHEMA="axyndra.opaque-row-journal-manifest/v1"
public let OPAQUE_ROW_JOURNAL_ROWS_SCHEMA="axyndra.opaque-row-journal-rows/v1"

// This opt-in dialect describes one original canonical read. Its index may
// select only the completed manifest in the same actual prior fact chain.
// No shape, ordinal, hash or successful parser conveys read authority.
public func pluginDocumentRowJournalReadRequestValid(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["schema","binding","projection_digest","key","window","prior_facts"]) ||
            httpIntentText(value,"schema")!=PLUGIN_DOCUMENT_ROW_JOURNAL_READ_SCHEMA ||
            validatePluginDocumentBinding(value.field("binding").getOrThrow()).isError() ||
            !httpIntentDigest(httpIntentText(value,"projection_digest")) || !documentContractIdentifier(httpIntentText(value,"key"))){return false}
        let binding=value.field("binding").getOrThrow()
        let prior=contextReadFactLinksFromValue(value.field("prior_facts").getOrThrow())
        if(prior.size>7){return false}
        for(link in prior){
            if(link.runId.value!=httpIntentText(binding,"run_id") || link.origin.ownerNamespace!=httpIntentText(binding,"namespace") ||
                link.origin.packageDigest!=httpIntentText(binding,"package_digest") ||
                link.origin.configurationDigest!=httpIntentText(binding,"configuration_digest") ||
                link.origin.projectionDigest!=httpIntentText(value,"projection_digest") || link.origin.parentCallItemId==""){return false}
            if(link.origin.parentCallItemId!=prior[0].origin.parentCallItemId ||
                link.origin.parentKind!=prior[0].origin.parentKind || link.origin.parentOperationId!=prior[0].origin.parentOperationId ||
                link.origin.parentDecisionId!=prior[0].origin.parentDecisionId || link.origin.parentScopedCallId!=prior[0].origin.parentScopedCallId){return false}}
        let window=value.field("window").getOrThrow()
        match(httpIntentText(window,"kind")){
            case "manifest"=>if(!httpIntentExactFields(window,["kind"]) || !prior.isEmpty()){return false}
            case "rows"=>
                if(!httpIntentExactFields(window,["kind","manifest_fact","offset","count"]) || prior.isEmpty() ||
                    documentContractInteger(window.field("manifest_fact").getOrThrow())!=0 ||
                    documentContractInteger(window.field("offset").getOrThrow())<0 ||
                    documentContractInteger(window.field("count").getOrThrow())<1){return false}
            case _=>return false}
        // The full bounded references remain present; nothing is replaced by
        // a plugin hash or a shortened reference merely to fit this dialect.
        stringifyUnifiedJson(value).size<=65536
    }catch(_:Exception){false}
}

public func pluginDocumentRowJournalReadAuthority(plan:NormalizedOperationPlan):Bool{
    if(!pluginDocumentRowJournalReadRequestValid(plan.canonicalArguments) || plan.requiredCapabilities.size!=1 ||
        !plan.resolvedPaths.isEmpty() || !plan.resolvedHosts.isEmpty()){return false}
    let binding=plan.canonicalArguments.field("binding").getOrThrow()
    plan.requiredCapabilities[0].kind==CapabilityKind.ExtensionInvoke &&
        plan.requiredCapabilities[0].resource==httpIntentText(binding,"namespace")
}

public func pluginDocumentRowJournalReadResultValid(value:AgentValue,request:AgentValue):Bool{
    try{
        pluginDocumentRowJournalReadRequestValid(request) && pluginDocumentRowJournalReadResultDataValid(value,
            modelPolicySha256Text(canonicalAgentValue(request)),httpIntentText(request,"key"))
    }catch(_:Exception){false}
}

// Shared descriptive result shape for the independently validated Tool12 or
// Context9 requests. This helper does not validate either source or binding.
public func pluginDocumentRowJournalReadResultDataValid(value:AgentValue,requestDigest:String,key:String):Bool{
    try{
        if(!httpIntentDigest(requestDigest) || !documentContractIdentifier(key) ||
            !httpIntentExactFields(value,["schema","request_digest","documents"]) ||
            httpIntentText(value,"schema")!=PLUGIN_DOCUMENT_ROW_JOURNAL_READ_RESULT_SCHEMA ||
            httpIntentText(value,"request_digest")!=requestDigest){return false}
        let documents=value.field("documents").getOrThrow()
        if(documents.unifiedKind!=ValueKind.List || documents.items.size!=1){return false}
        let snapshot=documents.items[0]
        if(!httpIntentExactFields(snapshot,["key","revision","payload"]) || httpIntentText(snapshot,"key")!=key ||
            documentContractInteger(snapshot.field("revision").getOrThrow())<1){return false}
        // A fresh journal already has a real manifest and logical revision1.
        // Do not borrow the old null-document/tombstone rule or event count.
        parsePluginDocumentPayloadReference(snapshot.field("payload").getOrThrow()).value().getOrThrow().bytes>0
    }catch(_:Exception){false}
}

// Generic opaque metadata only. There is no business-kind filter, corpus
// history decode or authority selection in this parser. The actual read
// materializer and its prepaid shared-pool owner supply these bytes.
public func opaqueRowJournalManifestValid(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["schema","layout","state","rows","annotations"]) ||
            httpIntentText(value,"schema")!=OPAQUE_ROW_JOURNAL_MANIFEST_SCHEMA || httpIntentText(value,"layout")!="opaque-fact-events-v3"){return false}
        let state=value.field("state").getOrThrow()
        if(!httpIntentExactFields(state,["sha256","chain_sha256","next_event_id","rows","events"]) ||
            !httpIntentDigest(httpIntentText(state,"sha256")) || !httpIntentDigest(httpIntentText(state,"chain_sha256")) ||
            documentContractInteger(state.field("next_event_id").getOrThrow())<1 ||
            documentContractInteger(state.field("rows").getOrThrow())<0 || documentContractInteger(state.field("events").getOrThrow())<0){return false}
        let annotations=value.field("annotations").getOrThrow()
        if(!httpIntentExactFields(annotations,["workspace_root","settings_root","thread_id","lane_id"])){return false}
        for(field in annotations.fields){if(field.value.unifiedKind!=ValueKind.Text || field.value.text.size>65536 || field.value.text.contains("\u{0000}")){return false}}
        let headers=value.field("rows").getOrThrow()
        if(headers.unifiedKind!=ValueKind.List || headers.items.size>documentContractInteger(state.field("rows").getOrThrow())){return false}
        let seen=HashSet<String>();var event:Int64=0
        for(header in headers.items){
            if(!httpIntentExactFields(header,["key","kind","revision","payload_sha256","payload_bytes","payload_json_bytes","first_event_id"]) ||
                !httpIntentDigest(httpIntentText(header,"payload_sha256"))){return false}
            let key=httpIntentText(header,"key");let kind=httpIntentText(header,"kind")
            if(key=="" || key.size>65536 || key.contains("\u{0000}") || kind=="" || kind.size>65536 || kind.contains("\u{0000}") || seen.contains(key)){return false}
            let bytes=documentContractInteger(header.field("payload_bytes").getOrThrow())
            let quoted=documentContractInteger(header.field("payload_json_bytes").getOrThrow())
            let first=documentContractInteger(header.field("first_event_id").getOrThrow())
            if(documentContractInteger(header.field("revision").getOrThrow())<1 || bytes<1 || bytes>PLUGIN_DOCUMENT_MAX_BYTES ||
                quoted<bytes+2 || quoted>bytes*6+2 || first<=event || first>=documentContractInteger(state.field("next_event_id").getOrThrow())){return false}
            seen.add(key);event=first}
        true
    }catch(_:Exception){false}
}

public func opaqueRowJournalRowsValid(value:AgentValue,manifest:AgentValue,manifestDigest:String,offset:Int64,count:Int64):Bool{
    try{
        if(!opaqueRowJournalManifestValid(manifest) || !httpIntentDigest(manifestDigest) ||
            !httpIntentExactFields(value,["schema","manifest_sha256","offset","rows"]) ||
            httpIntentText(value,"schema")!=OPAQUE_ROW_JOURNAL_ROWS_SCHEMA || httpIntentText(value,"manifest_sha256")!=manifestDigest ||
            documentContractInteger(value.field("offset").getOrThrow())!=offset || offset<0 || count<1){return false}
        let headers=manifest.field("rows").getOrThrow().items;let rows=value.field("rows").getOrThrow()
        if(offset>headers.size || count>headers.size-offset || rows.unifiedKind!=ValueKind.List || rows.items.size!=count){return false}
        for(index in 0..count){
            let row=rows.items[index];let header=headers[offset+index]
            if(!httpIntentExactFields(row,["key","revision","payload_sha256","payload"]) ||
                httpIntentText(row,"key")!=httpIntentText(header,"key") ||
                documentContractInteger(row.field("revision").getOrThrow())!=documentContractInteger(header.field("revision").getOrThrow()) ||
                httpIntentText(row,"payload_sha256")!=httpIntentText(header,"payload_sha256") || row.field("payload").getOrThrow().unifiedKind!=ValueKind.Text){return false}
            let raw=row.field("payload").getOrThrow().text
            if(raw.size!=documentContractInteger(header.field("payload_bytes").getOrThrow()) ||
                modelPolicySha256Text(raw)!=httpIntentText(header,"payload_sha256") ||
                stringifyUnifiedJson(textValue(raw)).size!=documentContractInteger(header.field("payload_json_bytes").getOrThrow())){return false}}
        true
    }catch(_:Exception){false}
}
