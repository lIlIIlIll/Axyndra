package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class MemoryReplayTestProbe {
    var digest=""
    let owner=reservePurePolicyData(1024)
    func remember(value:String):Unit{digest=String.fromUtf8(value.toArray())}
    func close():Unit{digest="";owner.close()}
}
func memoryReplayOriginalRetain(journal:NativeMemoryJournal):Result<ToolResult>{
    let runtime=NativeMemoryTools(journal,NativeManagedSkillProposals([]),"/settings","/workspace",[])
    let args=objectValue([ValueField("items",listValue([
        objectValue([ValueField("content",textValue("first"))]),
        objectValue([ValueField("content",textValue("second"))])]))])
    runtime.retain(NativeMemoryToolContext(SessionId("thread"),"/workspace"),ToolCall("call","retain",args))
}

// Pure business continuation/data oracles only. A test settlement is not an
// actual Source/Receipt/approval, and these tests assert no SQLite success.
@Test
class NativeMemoryLiveReplayTests {
    @TestCase
    func firstUnsettledDraftYieldsAtOriginalAppendBeforeAnyVirtualSuccess():Unit{
        let turn=nativeMemoryReplayTurn([],1000,[],memoryReplayOriginalRetain)
        try{turn.consume({outcome=>match(outcome){
            case NativeMemoryReplayOutcome.Proposal(group,digest)=>
                @Expect(group.ordinal,0);@Expect(group.operation,"retain");@Expect(group.events.size,1)
                @Expect(httpIntentText(group.events[0].field("record").getOrThrow(),"content"),"first")
                @Expect(httpIntentDigest(digest),true)
            case _=>@Expect(false,true)}})}finally{turn.close()}}
    @TestCase
    func knownFirstDraftThenSecondDraftThenOriginalCompleteReport():Unit{
        let first=MemoryReplayTestProbe();let second=MemoryReplayTestProbe()
        try{
            let turn1=nativeMemoryReplayTurn([],1000,[],memoryReplayOriginalRetain)
            try{turn1.consume({outcome=>match(outcome){case NativeMemoryReplayOutcome.Proposal(_,digest)=>first.remember(digest);case _=>@Expect(false,true)}})}finally{turn1.close()}
            let turn2=nativeMemoryReplayTurn([],1000,[NativeMemoryReplaySettlement(first.digest)],memoryReplayOriginalRetain)
            try{turn2.consume({outcome=>match(outcome){case NativeMemoryReplayOutcome.Proposal(group,digest)=>
                @Expect(group.ordinal,1);@Expect(httpIntentText(group.events[0].field("record").getOrThrow(),"content"),"second");second.remember(digest)
                case _=>@Expect(false,true)}})}finally{turn2.close()}
            let turn3=nativeMemoryReplayTurn([],1000,[NativeMemoryReplaySettlement(first.digest),NativeMemoryReplaySettlement(second.digest)],memoryReplayOriginalRetain)
            try{turn3.consume({outcome=>match(outcome){case NativeMemoryReplayOutcome.Completed(result)=>
                let actual=nativeMemoryTestRequire(result)
                let oracle=nativeMemoryTestRequire(memoryReplayOriginalRetain(NativeMemoryJournal([],1000)))
                @Expect(canonicalAgentValue(actual.output),canonicalAgentValue(oracle.output));@Expect(actual.isError,oracle.isError)
                @Expect(actual.output.field("count").getOrThrow().asNumberText(),"2")
                case _=>@Expect(false,true)}})}finally{turn3.close()}
        }finally{second.close();first.close()}}
    @TestCase
    func knownSecondFailureReturnsOriginalErrorWithoutThirdEffect():Unit{
        let first=MemoryReplayTestProbe();let second=MemoryReplayTestProbe()
        try{
            let turn1=nativeMemoryReplayTurn([],1000,[],memoryReplayOriginalRetain)
            try{turn1.consume({outcome=>match(outcome){case NativeMemoryReplayOutcome.Proposal(_,digest)=>first.remember(digest);case _=>@Expect(false,true)}})}finally{turn1.close()}
            let turn2=nativeMemoryReplayTurn([],1000,[NativeMemoryReplaySettlement(first.digest)],memoryReplayOriginalRetain)
            try{turn2.consume({outcome=>match(outcome){case NativeMemoryReplayOutcome.Proposal(_,digest)=>second.remember(digest);case _=>@Expect(false,true)}})}finally{turn2.close()}
            let failure=AgentError(AgentErrorKind.Conflict,"fixture.second_rejected","known second append rejection")
            let turn3=nativeMemoryReplayTurn([],1000,[NativeMemoryReplaySettlement(first.digest),NativeMemoryReplaySettlement(second.digest,error:Some(failure))],memoryReplayOriginalRetain)
            try{turn3.consume({outcome=>match(outcome){case NativeMemoryReplayOutcome.Completed(result)=>match(result){
                case Result.Err(error)=>@Expect(error.code,failure.code);@Expect(error.message,failure.message)
                case _=>@Expect(false,true)};case _=>@Expect(false,true)}})}finally{turn3.close()}
        }finally{second.close();first.close()}}
    @TestCase
    func changedProposalAndExtraKnownPrefixCannotProduceFinalSuccess():Unit{
        var changed=false
        try{let turn=nativeMemoryReplayTurn([],1000,[NativeMemoryReplaySettlement(modelPolicySha256Text("wrong"))],memoryReplayOriginalRetain);turn.close()}
        catch(error:PureProviderError){changed=error.code=="memory.live_proposal_changed"}
        @Expect(changed,true)
        var extra=false
        try{let turn=nativeMemoryReplayTurn([],1000,[NativeMemoryReplaySettlement(modelPolicySha256Text("unused"))],
            {_=>Result<ToolResult>.Ok(ToolResult("call",textValue("read only")))});turn.close()}
        catch(error:PureProviderError){extra=error.code=="memory.live_prefix_extra"}
        @Expect(extra,true)}
    @TestCase
    func correctionRemainsOneOriginalAtomicGroupWithTwoEvents():Unit{
        let seed=NativeMemoryJournal([],1000)
        let original=nativeMemoryTestRequire(seed.retain(nativeMemoryTestDraft("original")))
        let turn=nativeMemoryReplayTurn([original],2000,[],{journal=>
            match(journal.correct(original.id,nativeMemoryTestDraft("replacement"),expectedRevision:1)){
                case Result.Err(error)=>Result<ToolResult>.Err(error)
                case Result.Ok(value)=>Result<ToolResult>.Ok(ToolResult("call",memoryV3RecordValue(value)))}})
        try{turn.consume({outcome=>match(outcome){case NativeMemoryReplayOutcome.Proposal(group,_)=>
            @Expect(group.operation,"correct");@Expect(group.events.size,2);@Expect(group.ordinal,0)
            @Expect(httpIntentText(group.value().field("expected_record").getOrThrow(),"id"),original.id)
            @Expect(httpIntentText(group.events[1].field("record").getOrThrow(),"correctionOf"),original.id)
            case _=>@Expect(false,true)}})}finally{turn.close()}}
    @TestCase
    func completeCanonicalHashMatchesOriginalAcrossScalarAndChunkBoundaries():Unit{
        let raw=String.fromUtf8(Array<Byte>(70000,repeat:b'x'))+"\u{0000}\n中文"
        let values=[nullValue(),boolValue(true),JsonNode.number("-0"),JsonNode.number("1e+9"),textValue(raw),
            objectValue([ValueField("z",textValue(raw)),ValueField("a",listValue([integerValue(3),textValue("quote\\\"")]))])]
        let owner=reservePurePolicyRawData()
        try{for(value in values){
            @Expect(nativeMemoryReplayDigest(value,owner),modelPolicySha256Text(canonicalAgentValue(value)))
            @Expect(nativeMemoryReplayCanonicalBytes(value),canonicalAgentValue(value).size)}}finally{owner.close()}}
}
