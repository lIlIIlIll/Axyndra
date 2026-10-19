package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

public let ROW_JOURNAL_STRUCTURAL_ACCESS_SCHEMA="axyndra.row-journal-structural-access/v2"

// This is a descriptive operator document. Its parser and boolean decisions
// grant no data access. Actual Host configuration, Source, scope, approval,
// cancellation and Store fence owners must authorize every use separately.
class RowJournalStructuralScopeCase {
    let classification:String
    let keyMatch:String
    init(classification:String,keyMatch:String){this.classification=classification;this.keyMatch=keyMatch}
}
public class RowJournalStructuralAccess {
    private let rules:Array<JsonFieldProjectionRule>
    private let classification:Int64
    private let key:Int64
    private let cases:Array<RowJournalStructuralScopeCase>
    public let digest:String
    private init(rules:Array<JsonFieldProjectionRule>,classification:Int64,key:Int64,
        cases:Array<RowJournalStructuralScopeCase>,digest:String){
        this.rules=rules;this.classification=classification;this.key=key;this.cases=cases;this.digest=digest}
    public static func parse(value:AgentValue):RowJournalStructuralAccess{
        if(!httpIntentExactFields(value,["schema","fields","scope_classification_path","scope_key_path","scopes"]) ||
            httpIntentText(value,"schema")!=ROW_JOURNAL_STRUCTURAL_ACCESS_SCHEMA){
            throw LogicalJsonPayloadError("structural operator policy has an unsupported exact shape")}
        let fields=value.field("fields").getOrThrow();let scopeCases=value.field("scopes").getOrThrow()
        if(fields.unifiedKind!=ValueKind.List || fields.items.isEmpty() || fields.items.size>64 ||
            scopeCases.unifiedKind!=ValueKind.List || scopeCases.items.isEmpty() || scopeCases.items.size>64){
            throw LogicalJsonPayloadError("structural operator policy has an invalid bounded rule count")}
        let classificationPath=structuralAccessPath(value.field("scope_classification_path").getOrThrow())
        let keyPath=structuralAccessPath(value.field("scope_key_path").getOrThrow())
        let rules=ArrayList<JsonFieldProjectionRule>();let unique=HashSet<String>()
        var classification:Int64= -1;var key:Int64= -1
        for(index in 0..fields.items.size){
            let row=fields.items[index]
            if(!httpIntentExactFields(row,["path","prefix_bytes","ascii_trimmed_length"])){
                throw LogicalJsonPayloadError("structural field policy has an unknown field")}
            let path=structuralAccessPath(row.field("path").getOrThrow())
            let canonical=canonicalAgentValue(listValue(path.map{part=>textValue(part)}))
            if(!unique.add(canonical)){throw LogicalJsonPayloadError("structural operator policy repeats a field path")}
            let prefix=structuralAccessInteger(row.field("prefix_bytes").getOrThrow())
            let trim=row.field("ascii_trimmed_length").getOrThrow()
            if(prefix<0 || prefix>64 || trim.unifiedKind!=ValueKind.Boolean){
                throw LogicalJsonPayloadError("structural field policy has an invalid disclosure bound")}
            let isClassification=structuralAccessSamePath(path,classificationPath)
            let isKey=structuralAccessSamePath(path,keyPath)
            if(isClassification){classification=index;if(prefix!=64 || trim.asBool()){
                throw LogicalJsonPayloadError("scope classification must have only its bounded classifier disclosure")}}
            if(isKey){key=index;if(prefix!=0 || !trim.asBool()){
                throw LogicalJsonPayloadError("scope key may disclose only its explicitly approved trimmed length")}}
            if(trim.asBool() && !isKey){throw LogicalJsonPayloadError("trim metadata is only approved for the frozen scope key path")}
            rules.add(JsonFieldProjectionRule(path,prefixBytes:prefix,includePrefix:prefix>0,asciiTrimmedLength:trim.asBool()))
        }
        if(classification<0 || key<0 || classification==key){
            throw LogicalJsonPayloadError("scope paths must select two distinct frozen fields")}
        let parsedCases=ArrayList<RowJournalStructuralScopeCase>();let labels=HashSet<String>()
        for(row in scopeCases.items){
            if(!httpIntentExactFields(row,["classification","key_match"])){throw LogicalJsonPayloadError("scope policy has an unknown field")}
            let label=httpIntentText(row,"classification");let matchKey=httpIntentText(row,"key_match")
            if(label=="" || label.size>64 || !labels.add(label) ||
                !["text_fallback_empty","ascii_nonempty","current_thread","current_workspace"].contains(matchKey)){
                throw LogicalJsonPayloadError("scope policy has a repeated classifier or an unknown mechanical comparison")}
            parsedCases.add(RowJournalStructuralScopeCase(label,matchKey))
        }
        RowJournalStructuralAccess(rules.toArray(),classification,key,parsedCases.toArray(),
            modelPolicySha256Text(canonicalAgentValue(value)))
    }
    // Thread/workspace strings must come from the actual authorized Root,
    // never Native parameters. They stay private and are compared over every
    // decoded UTF8 byte after the same ASCII-only normalization as std trim.
    public func projector(bytes:Int64,digest:String,owner:LogicalJsonOwnerReservation,
        actualThread:String,actualWorkspace:String):JsonFieldStreamProjector{
        let path=rules[key].path
        JsonFieldStreamProjector(bytes,digest,rules,owner,projectedSchema:"axyndra.json-field-projection/v2",
            comparisons:[JsonFieldProjectionComparison(path,actualThread,asciiTrim:true),
                JsonFieldProjectionComparison(path,actualWorkspace,asciiTrim:true)])
    }
    // Separate opt-in private data-owner observation. The original projector
    // and all public disclosure rules remain byte identical by default.
    public func projectorWithPrivateText(bytes:Int64,digest:String,owner:LogicalJsonOwnerReservation,
        actualThread:String,actualWorkspace:String,sink:JsonFieldStreamPrivateTextSink):JsonFieldStreamProjector{
        let path=rules[key].path
        JsonFieldStreamProjector(bytes,digest,rules,owner,projectedSchema:"axyndra.json-field-projection/v2",
            comparisons:[JsonFieldProjectionComparison(path,actualThread,asciiTrim:true),
                JsonFieldProjectionComparison(path,actualWorkspace,asciiTrim:true)],privateText:Some(sink))
    }
    public func describesReadable(projection:JsonFieldStreamProjection,actualThread:String,actualWorkspace:String):Bool{
        let value=projection.value
        if(!httpIntentExactFields(value,["schema","fields"]) || httpIntentText(value,"schema")!="axyndra.json-field-projection/v2"){
            throw LogicalJsonPayloadError("observed structural result has another dialect")}
        let fields=value.field("fields").getOrThrow()
        if(fields.unifiedKind!=ValueKind.List || fields.items.size!=rules.size || projection.comparisonMatches.size!=2){
            throw LogicalJsonPayloadError("observed structural result has another field or comparison set")}
        for(index in 0..rules.size){structuralAccessField(fields.items[index],rules[index])}
        let classifier=fields.items[classification];let keyField=fields.items[key]
        // Non-text scope labels have the original text fallback empty and
        // cannot match a nonempty operator classifier.
        if(httpIntentText(classifier,"type")!="string" ||
            structuralAccessInteger(classifier.field("bytes").getOrThrow())>64){return false}
        let label=httpIntentText(classifier,"prefix");let keyType=httpIntentText(keyField,"type")
        let raw=structuralAccessInteger(keyField.field("bytes").getOrThrow())
        let trimmed=structuralAccessInteger(keyField.field("ascii_trimmed_bytes").getOrThrow())
        for(row in cases where row.classification==label){
            match(row.keyMatch){
                case "text_fallback_empty"=>return keyType!="string" || raw==0
                case "ascii_nonempty"=>return keyType=="string" && trimmed>0
                case "current_thread"=>return keyType=="string" && actualThread!="" && projection.comparisonMatches[0]
                case "current_workspace"=>return keyType=="string" && actualWorkspace!="" && projection.comparisonMatches[1]
                case _=>throw LogicalJsonPayloadError("frozen mechanical scope comparison changed")}
        };false
    }
}
func structuralAccessInteger(value:AgentValue):Int64{
    if(value.unifiedKind!=ValueKind.Number){throw LogicalJsonPayloadError("structural integer is not numeric")}
    let text=value.asNumberText();let result=Int64.parse(text)
    if(result.toString()!=text){throw LogicalJsonPayloadError("structural integer is not canonical Int64")};result
}
func structuralAccessPath(value:AgentValue):Array<String>{
    if(value.unifiedKind!=ValueKind.List || value.items.isEmpty() || value.items.size>32){
        throw LogicalJsonPayloadError("structural policy path has an invalid extent")}
    let path=ArrayList<String>()
    for(part in value.items){if(part.unifiedKind!=ValueKind.Text || part.text=="" || part.text.size>256){
        throw LogicalJsonPayloadError("structural policy path has an invalid component")};path.add(part.text)}
    path.toArray()
}
func structuralAccessSamePath(left:Array<String>,right:Array<String>):Bool{
    if(left.size!=right.size){return false}
    for(index in 0..left.size){if(left[index]!=right[index]){return false}};true
}
func structuralAccessField(value:AgentValue,rule:JsonFieldProjectionRule):Unit{
    let fields=ArrayList<String>();fields.add(all:["path","type","bytes"])
    if(rule.includePrefix){fields.add("prefix")};if(rule.asciiTrimmedLength){fields.add("ascii_trimmed_bytes")}
    if(!httpIntentExactFields(value,fields.toArray()) ||
        !structuralAccessSamePath(structuralAccessPath(value.field("path").getOrThrow()),rule.path)){
        throw LogicalJsonPayloadError("observed structural field differs from its frozen disclosure policy")}
    let kind=httpIntentText(value,"type");let bytes=structuralAccessInteger(value.field("bytes").getOrThrow())
    if(!["missing","null","boolean","number","string","array","object"].contains(kind) || bytes<0 || bytes>67108864 ||
        (!["string","number"].contains(kind) && bytes!=0)){
        throw LogicalJsonPayloadError("observed structural field has an invalid type or extent")}
    if(rule.includePrefix){let prefix=httpIntentText(value,"prefix")
        if(prefix.size>rule.prefixBytes || prefix.size>bytes ||
            (bytes<=rule.prefixBytes && prefix.size!=bytes) || (!["string","number"].contains(kind) && prefix!="")){
            throw LogicalJsonPayloadError("observed classification differs from its bounded complete prefix")}}
    if(rule.asciiTrimmedLength){let trimmed=structuralAccessInteger(value.field("ascii_trimmed_bytes").getOrThrow())
        if(trimmed<0 || trimmed>bytes || (kind!="string" && trimmed!=0)){
            throw LogicalJsonPayloadError("observed scope trim length differs from its mechanical field type")}}
}
