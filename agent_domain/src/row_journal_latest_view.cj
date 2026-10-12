package agent_domain

import yjson.*
import yjson_support.*

public let ROW_JOURNAL_LATEST_VIEW_SCHEMA="axyndra.row-journal-latest-view/v3"

// Descriptive generic operator policy, never a Source, access grant, SQL
// selector or Native-selected JSON pointer. Actual assembly must freeze the
// complete operator file and current purpose before using this parser's value.
public class RowJournalLatestView {
    private let keyPath:Array<String>
    public let digest:String
    private init(keyPath:Array<String>,digest:String){this.keyPath=keyPath;this.digest=digest}
    public static func parse(value:AgentValue):RowJournalLatestView{
        if(!httpIntentExactFields(value,["schema","group_key_path","ordinal","fold"]) ||
            httpIntentText(value,"schema")!=ROW_JOURNAL_LATEST_VIEW_SCHEMA ||
            httpIntentText(value,"ordinal")!="event-primary-key" ||
            httpIntentText(value,"fold")!="last-value-first-position"){
            throw LogicalJsonPayloadError("operator latest view has another exact mechanical purpose")}
        let path=structuralAccessPath(value.field("group_key_path").getOrThrow())
        RowJournalLatestView(path,modelPolicySha256Text(canonicalAgentValue(value)))
    }
    public func privateSink(consume:(Int64,Array<Byte>)->Unit):JsonFieldStreamPrivateTextSink{
        JsonFieldStreamPrivateTextSink(keyPath,consume)
    }
}
