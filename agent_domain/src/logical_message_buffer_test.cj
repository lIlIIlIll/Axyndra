package agent_domain

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func messageBufferHeader(window: String, sequence: Int64, bytes: Int64, digest: String): AgentValue {
    objectValue([ValueField("schema",textValue(LOGICAL_JSON_PAYLOAD_SCHEMA)),ValueField("window",textValue(window)),
        ValueField("transfer_sequence",integerValue(sequence)),ValueField("message_type",textValue("service_request")),
        ValueField("bytes",integerValue(bytes)),ValueField("sha256",textValue(digest))])
}
func messageBufferFinish(process: LogicalJsonProcessBudget, charge: LogicalJsonReservation, sequence: Int64): LogicalJsonReceiver {
    let source="{\"text\":\"paid\"}"
    let receiver=LogicalJsonReceiver(process,1048576,"window",sequence,"service_request",{ => () },
        reservation:Some(charge),reserveMaximum:false)
    @Expect(receiver.accept("payload_begin",messageBufferHeader("window",sequence,source.size,modelPolicySha256Text(source))).isNone())
    let common=[ValueField("schema",textValue(LOGICAL_JSON_PAYLOAD_SCHEMA)),ValueField("window",textValue("window")),ValueField("transfer_sequence",integerValue(sequence))]
    let chunk=ArrayList<ValueField>(common);chunk.add(ValueField("offset",integerValue(0)));chunk.add(ValueField("bytes_hex",textValue(logicalJsonEncodeHex(source.toArray()))))
    @Expect(receiver.accept("payload_chunk",objectValue(chunk.toArray())).isNone())
    @Expect(receiver.accept("payload_end",objectValue(common)).isSome())
    receiver
}
@Test
class LogicalMessageBufferTests {
    @TestCase
    func thirtyTwoCompletedMessagesKeepBothSlotsAndPaidOwnerUntilTrueClose(): Unit {
        let owner=LogicalJsonOwnerBudget();let process=LogicalJsonProcessBudget(owner)
        let invocation=process.acquire(1);let incoming=process.acquire(1);let initial=owner.usage()
        try {
            for(index in 0..32){
                let receiver=messageBufferFinish(process,incoming,index+2);receiver.clearRetainedMessageBuffer()
                @Expect(owner.usage()[0],initial[0]);@Expect(owner.usage()[1],initial[1])
                var thirdRejected=false
                try{let extra=process.acquire(1);extra.close()}catch(_:LogicalJsonPayloadError){thirdRejected=true}
                @Expect(thirdRejected)
            }
            incoming.ensureDecoded(2097152,30000);let retained=owner.usage()
            let last=messageBufferFinish(process,incoming,34);last.clearRetainedMessageBuffer()
            @Expect(owner.usage()[0],retained[0]);@Expect(owner.usage()[1],retained[1])
        }finally{incoming.close();invocation.close()}
        @Expect(owner.usage()[0],0);@Expect(owner.usage()[1],0)
    }
    @TestCase
    func incompleteClearFailsWithoutRefundAndCompletedClearDoesNotPermitReplay(): Unit {
        let owner=LogicalJsonOwnerBudget();let process=LogicalJsonProcessBudget(owner);let charge=process.acquire(1)
        let unfinished=LogicalJsonReceiver(process,1048576,"window",2,"service_request",{ => () },reservation:Some(charge),reserveMaximum:false)
        let paid=owner.usage();var rejected=false
        try{unfinished.clearRetainedMessageBuffer()}catch(_:LogicalJsonPayloadError){rejected=true}
        @Expect(rejected);@Expect(owner.usage()[0],paid[0]);@Expect(owner.usage()[1],paid[1])
        let complete=messageBufferFinish(process,charge,2);complete.clearRetainedMessageBuffer();rejected=false
        try{let _=complete.accept("payload_begin",messageBufferHeader("window",2,2,modelPolicySha256Text("{}")))}catch(_:LogicalJsonPayloadError){rejected=true}
        @Expect(rejected);complete.close();unfinished.close();@Expect(owner.usage()[0],0)
    }
}
