package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// These exercise the private transport state and actual allocation owners.
// They neither manufacture a Source nor claim read/write Root authority.
func pureLoanTestReply():JavaScriptHostResult<JavaScriptHostInvocationResult>{
    JavaScriptHostResult<JavaScriptHostInvocationResult>.Ok(JavaScriptHostInvocationResult("loan-test", "{\"ok\":true}"))}
func pureLoanTestRequest():AgentValue{objectValue([ValueField("action",textValue("ping"))])}

@Test
class HostPluginPureWorkerLoanTests {
    @TestCase
    func escapedLoanAfterCloseCannotInvokeOrAcquireAnotherOwner():Unit{
        let calls=AtomicInt64(0);let budget=LogicalJsonOwnerBudget()
        let loan=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1);pureLoanTestReply()},
            {bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,4096)
        loan.close();loan.close()
        @Expect(loan.exchange(pureLoanTestRequest()).error().getOrThrow().code,"plugin.pure_loan_closed")
        @Expect(calls.load(),0);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func pendingReplyKeepsItsPaidOwnerAndBlocksNextExchangeUntilAcknowledged():Unit{
        let calls=AtomicInt64(0);let budget=LogicalJsonOwnerBudget()
        let loan=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1);pureLoanTestReply()},
            {bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,4096)
        try{
            let reply=loan.exchange(pureLoanTestRequest()).value().getOrThrow()
            @Expect(reply.value.field("ok").getOrThrow().boolValue,true)
            @Expect(budget.usage()[0],1);@Expect(budget.usage()[1]>=16777216,true)
            @Expect(loan.exchange(pureLoanTestRequest()).error().getOrThrow().code,"plugin.pure_loan_reply_pending")
            @Expect(calls.load(),1);reply.close();reply.close();@Expect(budget.usage()[0],0)
            let next=loan.exchange(pureLoanTestRequest()).value().getOrThrow();@Expect(calls.load(),2)
            next.close();@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{loan.close()}
    }
    @TestCase
    func cancelledCurrentBeforeInvokeCannotSpendOrDispatch():Unit{
        let calls=AtomicInt64(0);let budget=LogicalJsonOwnerBudget()
        let loan=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1);pureLoanTestReply()},
            {bytes=>budget.acquire(bytes)},{=>hostPluginResourceError<Unit>("test.cancelled","cancelled")},MonoTime.now()+Duration.second*5,4096)
        try{
            @Expect(loan.exchange(pureLoanTestRequest()).error().getOrThrow().code,"test.cancelled")
            @Expect(calls.load(),0);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{loan.close()}
    }
    @TestCase
    func cancellationAfterNativeReturnDropsReplyAndClosesBothPayloadOwners():Unit{
        let calls=AtomicInt64(0);let cancelled=AtomicBool(false);let budget=LogicalJsonOwnerBudget()
        let loan=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1);cancelled.store(true);pureLoanTestReply()},
            {bytes=>budget.acquire(bytes)},{=>if(cancelled.load()){hostPluginResourceError<Unit>("test.cancelled","cancelled")}else{Result<Unit>.Ok(())}},
            MonoTime.now()+Duration.second*5,4096)
        try{
            @Expect(loan.exchange(pureLoanTestRequest()).error().getOrThrow().code,"test.cancelled")
            @Expect(calls.load(),1);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{loan.close()}
    }
    @TestCase
    func expiredDeadlineAndOriginalExchangeQuotaCannotResetTheConnection():Unit{
        let calls=AtomicInt64(0);let budget=LogicalJsonOwnerBudget()
        let expired=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1);pureLoanTestReply()},
            {bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()-Duration.second,4096)
        try{@Expect(expired.exchange(pureLoanTestRequest()).error().getOrThrow().code,"plugin.pure_loan_deadline");@Expect(calls.load(),0)}
        finally{expired.close()}
        let bounded=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1);pureLoanTestReply()},
            {bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,2)
        try{
            bounded.exchange(pureLoanTestRequest()).value().getOrThrow().close()
            bounded.exchange(pureLoanTestRequest()).value().getOrThrow().close()
            @Expect(bounded.exchange(pureLoanTestRequest()).error().getOrThrow().code,"plugin.pure_loan_closed")
            @Expect(calls.load(),2);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{bounded.close()}
    }
    @TestCase
    func malformedAndRejectedNativeRepliesNeverRetainAPaidDom():Unit{
        let budget=LogicalJsonOwnerBudget();let calls=AtomicInt64(0)
        let loan=HostPluginPureDataLoan({_,_=>let ordinal=calls.fetchAdd(1)
            JavaScriptHostResult<JavaScriptHostInvocationResult>.Ok(JavaScriptHostInvocationResult("invalid",if(ordinal==0){"{}"}else{"{"},isError:ordinal==0))},
            {bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,4096)
        try{
            @Expect(loan.exchange(pureLoanTestRequest()).error().getOrThrow().code,"plugin.pure_loan_reply")
            @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
            @Expect(loan.exchange(pureLoanTestRequest()).isError(),true)
            @Expect(calls.load(),2);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{loan.close()}
    }
    @TestCase
    func aggregateAllocationFailurePrecedesNativeDispatchAndDoesNotLeak():Unit{
        let budget=LogicalJsonOwnerBudget(maximumCharged:16777216);let occupied=budget.acquire(1);let calls=AtomicInt64(0)
        let loan=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1);pureLoanTestReply()},
            {bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,4096)
        try{
            @Expect(loan.exchange(pureLoanTestRequest()).isError(),true);@Expect(calls.load(),0)
            @Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)
        }finally{loan.close();occupied.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func closingTheLoanAcknowledgesPendingReplyExactlyOnceAndRevokesFurtherCalls():Unit{
        let budget=LogicalJsonOwnerBudget();let calls=AtomicInt64(0)
        let loan=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1);pureLoanTestReply()},
            {bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,4096)
        let reply=loan.exchange(pureLoanTestRequest()).value().getOrThrow();@Expect(budget.usage()[0],1)
        loan.close();reply.close();loan.close()
        @Expect(reply.isClosed(),true);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        @Expect(loan.exchange(pureLoanTestRequest()).error().getOrThrow().code,"plugin.pure_loan_closed");@Expect(calls.load(),1)
    }

    @TestCase
    func failedAdoptionCannotClearAPreexistingUncollectedSessionWorkerDebt():Unit{
        let attempts=AtomicInt64(0);let collected=AtomicBool(false)
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-loan-debt"))
        try{
            let result=session.run({owner=>
                @Expect(owner.retainWorkerCleanup({=>let _=attempts.fetchAdd(1);collected.load()}).isOk(),true)
                let debt=HostPluginPureWorkerDebt(owner)
                @Expect(debt.adopt({=>true}).error().getOrThrow().code,"plugin.document_query_closed")
                // Both normal and finally-style ACK attempts remain inert:
                // physical collection of an unadopted worker is insufficient.
                debt.acknowledgeIfCollected(true);debt.acknowledgeIfCollected(true)
                Result<AgentValue>.Ok(nullValue())})
            @Expect(result.error().getOrThrow().code,"plugin.document_query_cleanup_pending")
            @Expect(attempts.load(),1);@Expect(session.collect(),false);@Expect(attempts.load(),2)
            collected.store(true);@Expect(session.collect(),true);@Expect(attempts.load(),3)
        }finally{collected.store(true);@Expect(session.close().isOk(),true)}
    }
    @TestCase
    func successfulAdoptionWithoutPhysicalCollectionRetainsItsOriginalCleanup():Unit{
        let attempts=AtomicInt64(0);let collected=AtomicBool(false)
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-loan-owned-debt"))
        try{
            let result=session.run({owner=>
                let debt=HostPluginPureWorkerDebt(owner)
                @Expect(debt.adopt({=>let _=attempts.fetchAdd(1);collected.load()}).isOk(),true)
                debt.acknowledgeIfCollected(false)
                Result<AgentValue>.Ok(nullValue())})
            @Expect(result.error().getOrThrow().code,"plugin.document_query_cleanup_pending")
            @Expect(attempts.load(),1);collected.store(true);@Expect(session.collect(),true);@Expect(attempts.load(),2)
        }finally{collected.store(true);@Expect(session.close().isOk(),true)}
    }
    @TestCase
    func successfulAdoptionAndCollectionAcknowledgeOnlyThatSameSessionDebtOnce():Unit{
        let attempts=AtomicInt64(0)
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-loan-collected"))
        try{
            let result=session.run({owner=>
                let debt=HostPluginPureWorkerDebt(owner)
                @Expect(debt.adopt({=>let _=attempts.fetchAdd(1);false}).isOk(),true)
                debt.acknowledgeIfCollected(true);debt.acknowledgeIfCollected(true)
                Result<AgentValue>.Ok(nullValue())})
            @Expect(result.isOk(),true);@Expect(session.collect(),true);@Expect(attempts.load(),0)
        }finally{@Expect(session.close().isOk(),true)}
    }
}
