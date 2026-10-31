package agent_store

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*

// Grammar/equality transport fixture only: it does not create an actual FD,
// Root, grant, Prepared, Receipt or known effect acknowledgement.
private class LiveMemoryCursorFixture300 <: PluginLivePolicyProposalCursor {
    let raw:Array<Byte>
    let width:Int64
    var offset:Int64=0
    var closed=false
    init(raw:String,width:Int64){this.raw=raw.toArray();this.width=width}
    public func next():Result<Array<Byte>>{
        if(closed){return Result.Err(AgentError(AgentErrorKind.Conflict,"fixture.closed","fixture is closed"))}
        let end=min(raw.size,offset+width);let value=raw[offset..end];offset=end;Result.Ok(value)
    }
    public func finish():Result<Unit>{
        if(offset!=raw.size || closed){return Result.Err(AgentError(AgentErrorKind.Conflict,"fixture.incomplete","fixture is incomplete"))}
        Result.Ok(())
    }
    public func close():Result<Unit>{closed=true;Result.Ok(())}
}
@Test
class LiveMemoryFullDecodedEqualityTests300 {
    @TestCase
    func EveryDecodedByteAndFilteredStringBoundaryIsComparedAtArbitraryWidths():Unit{
        for(width in [1,2,7,65536]){
            for(pair in [
                ("{\"content\":\"雪\\u0000\\uD834\\uDD1E\"}","{\"content\":\"雪\\u0000𝄞\"}","content",true),
                ("{\"content\":\"a\\u0000b\"}","{\"content\":\"ab\"}","content",false),
                ("{}","{\"content\":false}","content",true),
                ("{\"conflictIds\":[\"ab\",\"c\"]}","{\"conflictIds\":[\"a\",\"bc\"]}","conflictIds",false),
                ("{\"conflictIds\":[\"\",\"\"]}","{\"conflictIds\":[]}","conflictIds",false),
                ("{\"conflictIds\":[false,\"a\",[\"ignore\"],\"b\"]}","{\"conflictIds\":[\"a\",\"b\"]}","conflictIds",true)]){
                let a="{\"expected_record\":"+pair[0]+"}";let b="{\"record\":"+pair[1]+"}"
                let left=LiveMemoryCursorFixture300(a,width);let right=LiveMemoryCursorFixture300(b,width)
                let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
                try{
                    let equal=liveMemoryExactFieldEqual300(left,a.size,modelPolicySha256Text(a),["expected_record"],
                        right,b.size,modelPolicySha256Text(b),["record"],pair[2],owner,{=>Result<Unit>.Ok(())})
                    @Expect(equal,pair[3]);@Expect(left.closed,true);@Expect(right.closed,true)
                }finally{owner.close()}
                @Expect(budget.usage()[0],0)
            }
        }
    }
    @TestCase
    func EarlyFieldMismatchStillRequiresBothWholeGrammarAndCheckedCleanup():Unit{
        let a="{\"expected_record\":{\"content\":\"different\"},\"ignored\":{\"x\":1,\"\\u0078\":2}}"
        let b="{\"record\":{\"content\":\"other\"},\"ignored\":true}"
        let left=LiveMemoryCursorFixture300(a,1);let right=LiveMemoryCursorFixture300(b,1)
        let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536);var refused=false
        try{let _=liveMemoryExactFieldEqual300(left,a.size,modelPolicySha256Text(a),["expected_record"],
            right,b.size,modelPolicySha256Text(b),["record"],"content",owner,{=>Result<Unit>.Ok(())})}
        catch(_:Exception){refused=true}finally{owner.close()}
        @Expect(refused,true);@Expect(left.closed,true);@Expect(right.closed,true);@Expect(budget.usage()[0],0)
    }
}
