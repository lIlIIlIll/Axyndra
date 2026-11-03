package agent_store

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private class LiveProposalRangesTest296 {
    let paths=ArrayList<String>()
    let extents=ArrayList<(String,Int64,Int64)>()
    let decoded=ArrayList<Byte>()
    init(){}
    func start(path:Array<String>,kind:String,offset:Int64):Unit{
        paths.add(canonicalAgentValue(listValue(path.map{part=>textValue(part)}))+":"+kind+":"+offset.toString())
    }
    func scalar(path:Array<String>,kind:String,raw:Array<Byte>):Unit{
        if(path.size==4 && path[0]=="events" && path[1]=="0" && path[2]=="record" && path[3]=="content" && kind=="string"){decoded.add(all:raw)}
    }
    func end(path:Array<String>,kind:String,start:Int64,end:Int64):Unit{
        if(path.size==2 && path[0]=="events"){extents.add((kind,start,end))}
    }
}
private func liveProposalScanTest296(raw:String,width:Int64,owner:LogicalJsonOwnerReservation,
    actual:LiveProposalRangesTest296):Unit{
    let scan=LiveProposalScanner296(raw.size,modelPolicySha256Text(raw),owner,
        {path,kind,start=>actual.start(path,kind,start)},
        {path,kind,bytes=>actual.scalar(path,kind,bytes)},
        {path,kind,start,end=>actual.end(path,kind,start,end)})
    let bytes=raw.toArray();var at:Int64=0
    while(at<bytes.size){let end=min(bytes.size,at+width);scan.append(at,bytes[at..end]);at=end}
    let _=scan.finish()
}
@Test
class LivePolicyProposalScannerTests296 {
    @TestCase
    func FullGrammarRangesAndDecodedScalarsStayExactAcrossBoundaries():Unit{
        let first="{\"record\":{\"content\":\"雪\\u0000\\uD834\\uDD1E\"}}"
        let second="{\"record\":{\"content\":\"next\"},\"unknown\":[false,null,-1.25e+3]}"
        let raw="{\"events\":["+first+","+second+"],\"expected_record\":null}"
        for(width in [1,2,3,7,65536]){
            let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536);let actual=LiveProposalRangesTest296()
            try{
                liveProposalScanTest296(raw,width,owner,actual)
                @Expect(actual.extents.size,2)
                for(pair in [(0,first),(1,second)]){
                    let range=actual.extents[pair[0]]
                    @Expect(range[0],"object")
                    @Expect(String.fromUtf8(raw.toArray()[range[1]..range[2]]),pair[1])
                }
                @Expect(String.fromUtf8(actual.decoded.toArray()),"雪\u{0000}𝄞")
            }finally{owner.close()}
            @Expect(budget.usage()[0],0)
        }
    }
    @TestCase
    func CompleteHashEOFAndUnknownDuplicateGrammarRemainMandatoryWithoutAggregateCap():Unit{
        for(raw in ["{\"events\":[{\"unknown\":{\"x\":1,\"\\u0078\":2}}]}",
            "{\"events\":[{\"unknown\":\"\\uD800x\"}]}","{\"events\":[1,]}",
            "{\"events\":[]} false","{\"events\":[1e+]}"]){
            let owner=LogicalJsonOwnerBudget().acquire(65536);var refused=false
            try{liveProposalScanTest296(raw,1,owner,LiveProposalRangesTest296())}
            catch(_:Exception){refused=true}finally{owner.close()}
            @Expect(refused,true)
        }
        let raw="{\"events\":[]}"
        let owner=LogicalJsonOwnerBudget().acquire(65536)
        try{
            let large=LiveProposalScanner296(67108865,modelPolicySha256Text(raw),owner,{_,_,_=>()},{_,_,_=>()},{_,_,_,_=>()})
            large.append(0,raw.toArray())
            var unfinished=false;try{let _=large.finish()}catch(_:Exception){unfinished=true};@Expect(unfinished,true)
            let wrong=LiveProposalScanner296(raw.size,modelPolicySha256Text(raw+"changed"),owner,{_,_,_=>()},{_,_,_=>()},{_,_,_,_=>()})
            wrong.append(0,raw.toArray());var hash=false
            try{let _=wrong.finish()}catch(_:Exception){hash=true};@Expect(hash,true)
        }finally{owner.close()}
    }
}
