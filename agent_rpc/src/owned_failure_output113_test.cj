package agent_rpc

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// DATA ownership controls. This receiver deliberately is not StdOut and
// makes no claim that a real RPC process wrote/flushed a physical frame.
private class RpcFailureTestOutput113 <: OwnedRpcFailureOutput113 {
    var calls:Int64=0
    var deferAck=false
    var fail=false
    var output:?RpcFailureAlias113=None<RpcFailureAlias113>
    var secondary:?OwnedFailureDataConsumer113=None<OwnedFailureDataConsumer113>
    public func writeFailureFrame113(value:OwnedFailureRunPublication113,
        render:(AgentError,(Int64)->Result<Unit>)->Result<String>):OwnedFailureDataOutcome113<Unit> {
        writeData(RpcFailureAlias113.Publication(value),render)
    }
    public func writeFailureFrame113(value:OwnedFailureDataConsumer113,
        render:(AgentError,(Int64)->Result<Unit>)->Result<String>):OwnedFailureDataOutcome113<Unit> {
        writeData(RpcFailureAlias113.Data(value),render)
    }
    private func writeData(value:RpcFailureAlias113,
        render:(AgentError,(Int64)->Result<Unit>)->Result<String>):OwnedFailureDataOutcome113<Unit> {
        calls++;output=Some(value)
        let answer=value.withError({error,fund=>
            @Expect(value.acknowledge().isError(),true)
            if(fail) {
                // The actual same-bank capture happens while this borrowed
                // producer/error frame still exists, before any input ACK.
                secondary=Some(value.capture(error))
                return Result<Unit>.Ok(())
            }
            let encoded=match(render(error,fund)){case Result.Ok(raw)=>raw
                case Result.Err(failure)=>secondary=Some(value.capture(failure));return Result<Unit>.Ok(())}
            match(fund(ownedOuterErrorAdd333(65536,ownedOuterErrorMultiply333(encoded.size,8)))) {
                case Result.Err(failure)=>secondary=Some(value.capture(failure));return Result<Unit>.Ok(())
                case Result.Ok(_)=>() }
            let decoded=decodeAgentValue(encoded).value().getOrThrow()
            @Expect(decoded.field("type").getOrThrow().text,"response")
            @Expect(decoded.field("id").getOrThrow().text,"request-113")
            @Expect(decoded.field("command").getOrThrow().text,"prompt")
            @Expect(decoded.field("success").getOrThrow().asBool(),false)
            @Expect(decoded.field("error").getOrThrow().text,error.message)
            let detail=decoded.field("error_data").getOrThrow()
            @Expect(detail.field("code").getOrThrow().text,"rpc.original_failure")
            @Expect(detail.field("fields").getOrThrow().items.size,2)
            @Expect(detail.field("attempt_failure").isSome(),true)
            @Expect(detail.field("observation").isSome(),true)
            Result<Unit>.Ok(())
        })
        match(answer){case Result.Err(error)=>secondary=Some(value.capture(error));case Result.Ok(_)=>()}
        match(secondary){case Some(error)=>return OwnedFailureDataOutcome113<Unit>.Failure(error);case None=>()}
        if(!deferAck) {
            // Actual borrowed decode/renderer frame has now ended. Only this
            // output CHILD can ACK; it cannot retire queue-owned metadata.
            @Expect(value.acknowledge().isOk(),true);output=None<RpcFailureAlias113>
        }
        OwnedFailureDataOutcome113<Unit>.Value(())
    }
    func acknowledgeDeferred():Unit {
        @Expect(output.getOrThrow().acknowledge().isOk(),true)
        output=None<RpcFailureAlias113>
    }
}

private func rpcFailureConsumer113(pool:LogicalJsonOwnerBudget):OwnedFailureDataConsumer113 {
    let failure=AgentError(AgentErrorKind.Transport,"rpc.original_failure","雪\u{0}🙂",
        retryable:true,fallbackAllowed:true,fields:[ErrorField("same","first"),ErrorField("same","second")])
    let data=OwnedFailureData113(failure,{size=>pool.acquire(size)})
    let consumer=data.retainConsumer().value().getOrThrow()
    @Expect(data.closeAfterProducerRetirement().isOk(),true)
    consumer
}

@Test
class OwnedRpcFailureDataControls113 {
    @TestCase
    func FullFailureFalseResponseRetiresOnlyAfterSeparateOutputAndQueueConsumers():Unit {
        let pool=LogicalJsonOwnerBudget();let input=rpcFailureConsumer113(pool)
        let queue=RpcOwnedFailureQueue113();let output=RpcFailureTestOutput113()
        queue.append(rpcPrepareFailureData113(input,"request-113","prompt",1).value().getOrThrow())
        queue.offer(Some(output),{=>"chunk-113"})
        @Expect(output.calls,1);@Expect(input.isAcknowledged(),false)
        @Expect(pool.usage()[1]>0,true)
        @Expect(queue.collect(),true);@Expect(input.isAcknowledged(),true)
        @Expect(queue.pending(),false);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func MissingConcreteOutputKeepsCompleteOriginalPaidInputUntilActualReceiver():Unit {
        let pool=LogicalJsonOwnerBudget();let input=rpcFailureConsumer113(pool)
        let queue=RpcOwnedFailureQueue113()
        queue.append(rpcPrepareFailureData113(input,"request-113","prompt",1).value().getOrThrow())
        queue.offer(None<OwnedRpcFailureOutput113>,{=>"chunk-113"})
        @Expect(queue.collect(),false);@Expect(queue.pending(),true)
        @Expect(input.isAcknowledged(),false);@Expect(pool.usage()[1]>0,true)
        let output=RpcFailureTestOutput113();queue.offer(Some(output),{=>"chunk-113"})
        @Expect(output.calls,1);@Expect(queue.collect(),true);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func ValueReturnWithoutOutputAckCannotReplayOrReleaseOriginalQueueData():Unit {
        let pool=LogicalJsonOwnerBudget();let input=rpcFailureConsumer113(pool)
        let queue=RpcOwnedFailureQueue113();let output=RpcFailureTestOutput113();output.deferAck=true
        queue.append(rpcPrepareFailureData113(input,"request-113","prompt",1).value().getOrThrow())
        queue.offer(Some(output),{=>"chunk-113"})
        @Expect(queue.collect(),false);@Expect(input.isAcknowledged(),false)
        queue.offer(Some(output),{=>"chunk-113"});@Expect(output.calls,1)
        output.acknowledgeDeferred();@Expect(queue.collect(),true)
        @Expect(input.isAcknowledged(),true);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func TypedSecondaryRetainsItsSameBankDataAndNeverAcknowledgesOrRetriesFailedInput():Unit {
        let pool=LogicalJsonOwnerBudget();let input=rpcFailureConsumer113(pool)
        let queue=RpcOwnedFailureQueue113();let output=RpcFailureTestOutput113();output.fail=true
        queue.append(rpcPrepareFailureData113(input,"request-113","prompt",1).value().getOrThrow())
        queue.offer(Some(output),{=>"chunk-113"})
        @Expect(output.calls,1);@Expect(queue.collect(),false)
        @Expect(input.isAcknowledged(),false);@Expect(queue.pending(),true)
        @Expect(output.secondary.getOrThrow().withError({error,_=>
            @Expect(error.code,"rpc.original_failure")
            @Expect(error.message,"雪\u{0}🙂")
            @Expect(error.fields.size,2)
            @Expect(error.retryable,true);@Expect(error.fallbackAllowed,true)
        }).isOk(),true)
        queue.offer(Some(output),{=>"chunk-113"});@Expect(output.calls,1)
        @Expect(pool.usage()[1]>0,true)
        // This negative control intentionally remains held. No fake ACK or
        // zero-pool assertion is used for an unfinished output consumer.
    }
}
