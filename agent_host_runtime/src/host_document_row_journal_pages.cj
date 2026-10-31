package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// This pure selector sees only prepaid actual manifest headers. The Store
// still validates the original manifest fact/payload/current state and each
// contiguous interval in its actual transaction before reading any row.
func hostRowJournalPages(manifest:AgentValue,manifestDigest:String):Result<AgentValue>{
    try{
        if(!opaqueRowJournalManifestValid(manifest) || !httpIntentDigest(manifestDigest)){
            return hostPluginResourceError("plugin.document_window_manifest_invalid","actual row manifest metadata is invalid")}
        let headers=manifest.field("rows").getOrThrow().items
        let pages=ArrayList<AgentValue>();var offset:Int64=0
        while(offset<headers.size){
            // Exact bytes from SQLite json_quote(payload), plus the actual
            // bounded metadata shell. Do not reject a real 6MiB ASCII row by
            // replacing this observed encoding size with a blanket 6x bound.
            let empty=objectValue([ValueField("schema",textValue(OPAQUE_ROW_JOURNAL_ROWS_SCHEMA)),
                ValueField("manifest_sha256",textValue(manifestDigest)),ValueField("offset",integerValue(offset)),ValueField("rows",listValue([]))])
            var bytes=stringifyUnifiedJson(empty).size;var count:Int64=0
            while(offset+count<headers.size){
                let header=headers[offset+count]
                let shell=objectValue([ValueField("key",header.field("key").getOrThrow()),ValueField("revision",header.field("revision").getOrThrow()),
                    ValueField("payload_sha256",header.field("payload_sha256").getOrThrow()),ValueField("payload",nullValue())])
                let quoted=Int64.parse(header.field("payload_json_bytes").getOrThrow().asNumberText())
                let rowBytes=stringifyUnifiedJson(shell).size-4+quoted
                let addition=rowBytes+(if(count==0){0}else{1})
                if(addition>PLUGIN_DOCUMENT_MAX_BYTES-bytes){break}
                bytes+=addition;count++}
            if(count==0){return hostPluginResourceError("plugin.document_window_row_oversized","an actual opaque row exceeds the original document payload boundary")}
            pages.add(objectValue([ValueField("offset",integerValue(offset)),ValueField("count",integerValue(count)),ValueField("bytes",integerValue(bytes))]))
            offset+=count
            if(pages.size>7){return hostPluginResourceError("plugin.document_window_read_limit","the full corpus requires more than the original eight-read sequence")}}
        Result.Ok(listValue(pages.toArray()))
    }catch(_:Exception){hostPluginResourceError("plugin.document_window_manifest_invalid","actual manifest cannot select its bounded complete row pages")}
}
