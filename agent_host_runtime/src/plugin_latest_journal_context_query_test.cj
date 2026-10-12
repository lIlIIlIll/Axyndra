package agent_host_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class LatestJournalContextTransportContractTest {
    @TestCase
    func finalBoundRemainsOriginalAndRequiresCanonicalCompleteDigest():Unit{
        let exact=objectValue([ValueField("bytes",integerValue(RUN_CONTEXT_SNAPSHOT_MAX_BYTES)),
            ValueField("sha256",textValue(modelPolicySha256Text("result")))])
        @Expect(hostJournalContextOutputValid(exact),true)
        exact.put("bytes",integerValue(RUN_CONTEXT_SNAPSHOT_MAX_BYTES+1))
        @Expect(hostJournalContextOutputValid(exact),false)
        exact.put("bytes",numberValue("1.0"))
        @Expect(hostJournalContextOutputValid(exact),false)
        exact.put("bytes",integerValue(1));exact.put("sha256",textValue("sha256:"+modelPolicySha256Text("result")))
        @Expect(hostJournalContextOutputValid(exact),false)
    }
    @TestCase
    func finalChunkMustMatchActualOffsetExtentEOFAndEveryHexByte():Unit{
        let chunk=objectValue([ValueField("offset",integerValue(7)),ValueField("bytes_hex",textValue("f09f8c8a")),
            ValueField("eof",boolValue(true))])
        @Expect(hostJournalContextChunkValid(chunk,7,11),true)
        @Expect(hostJournalContextChunkValid(chunk,8,11),false)
        @Expect(hostJournalContextChunkValid(chunk,7,12),false)
        chunk.put("bytes_hex",textValue("f09f8c8Z"));@Expect(hostJournalContextChunkValid(chunk,7,11),false)
        chunk.put("bytes_hex",textValue("f09f8c8"));@Expect(hostJournalContextChunkValid(chunk,7,11),false)
        chunk.put("bytes_hex",textValue("f09f8c8a"));chunk.put("extra",nullValue())
        @Expect(hostJournalContextChunkValid(chunk,7,11),false)
    }
    @TestCase
    func outputTransportPreservesSplitUtf8AndStrict16KiBWindow():Unit{
        let bytes=Array<Byte>(16384,repeat:b'a');bytes[16383]=0xf0
        let first=objectValue([ValueField("offset",integerValue(0)),ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes))),
            ValueField("eof",boolValue(false))])
        @Expect(hostJournalContextChunkValid(first,0,16387),true)
        let next=objectValue([ValueField("offset",integerValue(16384)),ValueField("bytes_hex",textValue("9f8c8a")),
            ValueField("eof",boolValue(true))])
        @Expect(hostJournalContextChunkValid(next,16384,16387),true)
        first.put("bytes_hex",textValue(logicalJsonEncodeHex(Array<Byte>(16385,repeat:b'a'))))
        @Expect(hostJournalContextChunkValid(first,0,32768),false)
    }
}
