package agent_host_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func downloadSlot287(slot:String,offset:Int64):AgentValue{
    objectValue([ValueField("slot",textValue(slot)),ValueField("offset",integerValue(offset)),
        ValueField("bytes_hex",textValue("61")),ValueField("last",boolValue(true))])
}
// Transport data contract only; no Source, Receipt, file or execution grant.
@Test
class LivePolicyDownloadActualSlotTests {
    @TestCase
    func actualNativeFourFieldReplyIsBoundToTheRequestedSlotAndOffset():Unit{
        @Expect(hostLivePolicyDownloadReplyValid287(downloadSlot287("payload-0",0),"payload-0",0),true)
        @Expect(hostLivePolicyDownloadReplyValid287(downloadSlot287("manifest",65536),"manifest",65536),true)
        @Expect(hostLivePolicyDownloadReplyValid287(downloadSlot287("payload-1",0),"payload-0",0),false)
        @Expect(hostLivePolicyDownloadReplyValid287(downloadSlot287("payload-0",1),"payload-0",0),false)
    }
    @TestCase
    func missingSlotAndAdditionalFieldsNeverPassAsTheActualNativeReply():Unit{
        let missing=objectValue([ValueField("offset",integerValue(0)),ValueField("bytes_hex",textValue("61")),ValueField("last",boolValue(true))])
        @Expect(hostLivePolicyDownloadReplyValid287(missing,"payload-0",0),false)
        let extra=objectValue([ValueField("slot",textValue("payload-0")),ValueField("offset",integerValue(0)),
            ValueField("bytes_hex",textValue("61")),ValueField("last",boolValue(true)),ValueField("accepted",boolValue(true))])
        @Expect(hostLivePolicyDownloadReplyValid287(extra,"payload-0",0),false)
    }
    @TestCase
    func wrongSlotTypeAndNonBooleanEOFRemainRejected():Unit{
        let wrongSlot=objectValue([ValueField("slot",integerValue(0)),ValueField("offset",integerValue(0)),
            ValueField("bytes_hex",textValue("61")),ValueField("last",boolValue(true))])
        @Expect(hostLivePolicyDownloadReplyValid287(wrongSlot,"payload-0",0),false)
        let wrongEOF=objectValue([ValueField("slot",textValue("payload-0")),ValueField("offset",integerValue(0)),
            ValueField("bytes_hex",textValue("61")),ValueField("last",integerValue(1))])
        @Expect(hostLivePolicyDownloadReplyValid287(wrongEOF,"payload-0",0),false)
    }
}
