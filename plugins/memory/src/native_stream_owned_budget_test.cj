package memory_plugin

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class NativeMemoryStreamOwnedBudgetTests {
    @TestCase
    func ConcurrentDecoderLexicalAndInlineOwnersAreChargedSeparatelyUntilEachAck():Unit{
        let budget=LogicalJsonOwnerBudget();let decoder=budget.acquire(65536)
        let lexical=MemoryStreamLexicalBatch("needle", -1,allocate:{bytes=>budget.acquire(bytes)})
        let content=MemoryStreamInlineField("content",0,4097,allocate:{bytes=>budget.acquire(bytes)})
        let context=MemoryStreamInlineField("context",0,4097,allocate:{bytes=>budget.acquire(bytes)})
        try{@Expect(budget.usage()[0],4);@Expect(budget.usage()[1],67108864)
            lexical.close();@Expect(budget.usage()[0],3);@Expect(budget.usage()[1],50331648)
            content.close();@Expect(budget.usage()[0],2)
            context.close();@Expect(budget.usage()[0],1)
        }finally{context.close();content.close();lexical.close();decoder.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func InvalidConstructionOrGrowthCannotLeakOrBorrowAnotherLiveOwner():Unit{
        let budget=LogicalJsonOwnerBudget(maximumCharged:16777216);let retained=budget.acquire(1)
        try{
            var refused=false;try{let _=MemoryStreamLexicalBatch("needle", -1,allocate:{bytes=>budget.acquire(bytes)})}
                catch(_:Exception){refused=true};@Expect(refused,true);@Expect(budget.usage()[0],1)
        }finally{retained.close()}
        var refused=false;try{let _=MemoryStreamLexicalBatch(" ", -1,allocate:{bytes=>budget.acquire(bytes)})}
            catch(_:Exception){refused=true};@Expect(refused,true)
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func ClosedInlineOrLexicalOwnerRejectsAnyFurtherCallback():Unit{
        let budget=LogicalJsonOwnerBudget()
        let lexical=MemoryStreamLexicalBatch("needle", -1,allocate:{bytes=>budget.acquire(bytes)})
        let inline=MemoryStreamInlineField("content",1,4097,allocate:{bytes=>budget.acquire(bytes)})
        lexical.close();inline.close()
        var refused=false;try{lexical.consume("content",0,"x")}catch(_:Exception){refused=true};@Expect(refused,true)
        refused=false;try{inline.consume("content",0,"x")}catch(_:Exception){refused=true};@Expect(refused,true)
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
