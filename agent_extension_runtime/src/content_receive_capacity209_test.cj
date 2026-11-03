package agent_extension_runtime

import agent_domain.*
import process4cj.*
import process4cj as receiver_process209
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func contentReceiverEnvelope209(kind: String, header: AgentValue): AgentValue {
    objectValue([ValueField("type",textValue(kind)),ValueField("protocol",textValue("axyndra.native/v2")),
        ValueField("extension_id",textValue("actual-content209")),ValueField("extension_version",textValue("1.0.0")),
        ValueField("generation",integerValue(1)),ValueField("id",textValue("host-invocation209")),
        ValueField("tool",textValue("context")),ValueField("kind",textValue("provider")),
        ValueField("command_id",textValue("")),ValueField("thread_id",textValue("actual-thread209")),
        ValueField("run_id",textValue("")),ValueField("epoch",integerValue(0)),
        ValueField("operation_id",textValue("")),ValueField("call_id",textValue("actual-query209")),
        ValueField("payload",header)])
}

private class ContentReceiverCompletion211 {
    public var value: Bool = false
}

private func consumeTinyContentLogicalFrame209(receiver: NativePayloadReceiver): Unit {
    let source="{\"type\":\"result\",\"ok\":true,\"result\":{\"value\":\"actual-tiny-provider\"}}"
    let completed=ContentReceiverCompletion211()
    writeLogicalJsonPayload("actual-content-window209",1,"result",source,CONTENT_PAYLOAD_RESULT_BYTES,
        { => () },{ kind,header =>
            match(receiver.accept(contentReceiverEnvelope209(kind,header))){
                case Some(value)=>
                    @Expect(httpIntentText(value,"type"),"result")
                    @Expect(httpIntentText(value.field("result").getOrThrow(),"value"),"actual-tiny-provider")
                    completed.value=true
                case None=>() }
        })
    @Expect(completed.value,true)
}

private func rejectUnpaidContentDeclarations209(receiver: NativePayloadReceiver): Unit {
    let before=nativePayloadOwnerBudget.usage()
    for(mode in ["actual-full-body","over-limit","foreign-window","invalid-digest"]){
        let header=objectValue([ValueField("schema",textValue("axyndra.logical-json/v1")),
            ValueField("window",textValue(if(mode=="foreign-window"){"foreign-window"}else{"actual-content-window209"})),
            ValueField("transfer_sequence",integerValue(1)),ValueField("message_type",textValue("result")),
            ValueField("bytes",integerValue(if(mode=="over-limit"){CONTENT_PAYLOAD_RESULT_BYTES+65537}else{CONTENT_PAYLOAD_RESULT_BYTES})),
            ValueField("sha256",textValue(if(mode=="invalid-digest"){"invalid"}else{"0000000000000000000000000000000000000000000000000000000000000000"}))])
        var rejected=false
        try { let _=receiver.accept(contentReceiverEnvelope209("payload_begin",header)) }
        catch(error: ProcessError){
            rejected=true
            @Expect(match(error.kind){case ProcessErrorKind.Frame=>true;case _=>false})
            if(mode=="actual-full-body"){
                @Expect(error.message,"logical payload aggregate decoded capacity is exhausted") }
        }
        @Expect(rejected,true)
        @Expect(receiver.pending,false)
        @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),before),true)
    }
}

// The real original process bank is pressured by the observed App footprint,
// plus two actually paid simultaneous owners. No replacement budget/cap/ACK.
// Every payload consumer returns Unit before its receiver may close. The
// outer test observes the bank only after this entire private frame returns.
private func contentReceiverPressureFrame209(rejectLarge: Bool): Unit {
    let pressure=reserveNativeControlMetadata(4096)
    try {
        // Pressure is expressed against the CURRENT aggregate so the refusal
        // this test asserts stays reachable whatever the product quota is.
        // Exactly THREE floor-priced owners of room are left: the `frozen` and
        // `outgoing` reservations (two floors) must succeed, and the eager
        // result-profile reservation below must be the one that is refused.
        // The behaviour under test - refuse before allocating and change no
        // bank state - is unchanged.
        let capacity = nativeControlMetadataCapacity113()
        pressure.ensureRetainedPeak(capacity - 3 * 16777216)
        let frozen=reserveNativeControlMetadata(4096)
        try {
            let budget=NativePayloadProcessBudget()
            let outgoing=budget.acquire(65536)
            try {
                let cancellation=receiver_process209.CancellationSource()
                try {
                    let before=nativePayloadOwnerBudget.usage()
                    var eagerRejected=false
                    try {
                        let original=NativePayloadReceiver(budget,CONTENT_PAYLOAD_RESULT_BYTES+65536,
                            "actual-content-window209",hostNowMillis()+5000,cancellation.token,
                            physicalFrameBytes:JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES)
                        original.close()
                    } catch(error: NativePayloadCapacityError){
                        eagerRejected=true
                        @Expect(error.message,"logical payload aggregate capacity is exhausted") }
                    @Expect(eagerRejected,true)
                    @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),before),true)
                    for(_ in 0..if(rejectLarge){1}else{32}){
                        let receiver=NativePayloadReceiver(budget,CONTENT_PAYLOAD_RESULT_BYTES+65536,
                            "actual-content-window209",hostNowMillis()+5000,cancellation.token,
                            physicalFrameBytes:JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES,reserveMaximum:false)
                        try {
                            let incoming=nativePayloadOwnerBudget.usage()
                            @Expect(incoming[0],before[0]+1)
                            @Expect(incoming[1],before[1]+16777216)
                            // The existing original per-worker two-transfer
                            // gate remains strict while this actual input lives.
                            var thirdRejected=false
                            try { let third=budget.acquire(1);third.close() }
                            catch(error: NativePayloadCapacityError){
                                thirdRejected=true
                                @Expect(error.message,"logical payload worker capacity is exhausted") }
                            @Expect(thirdRejected,true)
                            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),incoming),true)
                            if(rejectLarge){rejectUnpaidContentDeclarations209(receiver)}
                            else{consumeTinyContentLogicalFrame209(receiver)}
                        } finally { receiver.close() }
                        @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),before),true)
                    }
                } finally { cancellation.close() }
            } finally { outgoing.close() }
        } finally { frozen.close() }
    } finally { pressure.close() }
}

@Test
class ContentReceiveActualCapacity209Tests {
    @TestCase
    func originalAppPressureAllowsActualSmallCompleteFramesWithoutUnusedMaximumReservation(): Unit {
        let before=nativePayloadOwnerBudget.usage()
        contentReceiverPressureFrame209(false)
        @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),before),true)
    }
    @TestCase
    func allowedLargeBodyCannotAllocateBeforeItsFullInvoiceAndOriginalMalformedGuardsRemainStrict(): Unit {
        let before=nativePayloadOwnerBudget.usage()
        contentReceiverPressureFrame209(true)
        @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),before),true)
    }
}
