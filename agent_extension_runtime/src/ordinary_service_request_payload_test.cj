package agent_extension_runtime

import agent_domain.*
import agent_sdk.*
import std.env.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*
import yjson.JsonNode

class RequestPayloadObserver <: JavaScriptHostObserver {
    let calls=AtomicInt64(0)
    let peakOwners=AtomicInt64(0)
    public func onProgress(invocation:String,value:String):JavaScriptHostResult<Unit>{JavaScriptHostResult.Ok(())}
    public func onServiceRequest(invocation:String,request:String,service:String,arguments:String):JavaScriptHostResult<String>{
        let n=calls.fetchAdd(1)
        if(n==0){peakOwners.store(nativePayloadOwnerBudget.usage()[0])}
        else{@Expect(nativePayloadOwnerBudget.usage()[0],peakOwners.load())}
        @Expect(service,"fixture.echo");@Expect(parseUnifiedJson(arguments,maxBytes:1048576).field("text").isSome())
        JavaScriptHostResult.Ok("{}")
    }
}
func requestPayloadFixtureRoot():String{
    let source=getVariable("AXYNDRA_REPO_ROOT").getOrThrow()+"/support_tests/ordinary_request_payload_host_fixture/peer.py"
    let root=Directory.createTemp(getVariable("TMPDIR").getOrDefault({ => "/tmp" })).toString()
    File.writeTo(root+"/worker",File.readFrom(source));let _=FileInfo(root+"/worker").setExecutable(true);root
}
@Test
class OrdinaryServiceRequestPayloadTests {
    @TestCase
    func sameTwoSlotsAcceptMixedRawAndLogicalRequestsThenReleaseOnlyAtResultConsumer():Unit{
        for(mode in ["mixed","many"]){
            let before=nativePayloadOwnerBudget.usage();let root=requestPayloadFixtureRoot();let host=ordinaryPayloadHost(root)
            let baseline=nativePayloadOwnerBudget.usage();let observer=RequestPayloadObserver()
            try{
                let output=match(host.invoke("run",stringifyUnifiedJson(objectValue([ValueField("mode",textValue(mode))])),
                    identity:quotaIdentity("tool"),timeoutMillis:10000,toolPayloadLimits:Some(OrdinaryToolPayloadLimits("run")),observer:Some(observer))){
                    case JavaScriptHostResult.Ok(value)=>value;case JavaScriptHostResult.Err(error)=>throw IllegalStateException(error.code)}
                try{
                    let expected=if(mode=="many"){32}else{2}
                    @Expect(observer.calls.load(),expected);@Expect(nativePayloadOwnerBudget.usage()[0],baseline[0]+2)
                    @Expect(parseUnifiedJson(output.resultJson).field("calls").getOrThrow().asNumberText(),expected.toString())
                }finally{output.releasePayload()}
                @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),baseline))
            }finally{@Expect(host.awaitCleanup(timeoutMillis:2000).isOk());remove(root,recursive:true)}
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),before))
        }
    }
    @TestCase
    func wrongWindowSequenceHashOverlapAndIncompleteRequestNeverDispatchObserver():Unit{
        for(mode in ["window","sequence","hash","overlap","incomplete","bad_eof","bad_utf8","identity"]){
            let before=nativePayloadOwnerBudget.usage();let root=requestPayloadFixtureRoot();let host=ordinaryPayloadHost(root);let observer=RequestPayloadObserver()
            try{
                let output=host.invoke("run",stringifyUnifiedJson(objectValue([ValueField("mode",textValue(mode))])),
                    identity:quotaIdentity("tool"),timeoutMillis:1000,toolPayloadLimits:Some(OrdinaryToolPayloadLimits("run")),observer:Some(observer))
                @Expect(!output.isOk());@Expect(observer.calls.load(),0)
            }finally{@Expect(host.awaitCleanup(timeoutMillis:2000).isOk());remove(root,recursive:true)}
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),before))
        }
    }
    @TestCase
    func defaultTerminalOnlyReceiverCannotAcceptLogicalServiceRequest():Unit{
        let root=requestPayloadFixtureRoot();let host=ordinaryPayloadHost(root);let observer=RequestPayloadObserver()
        try{
            let output=host.invoke("run","{\"mode\":\"many\"}",identity:quotaIdentity("tool"),timeoutMillis:1000,observer:Some(observer))
            @Expect(!output.isOk());@Expect(observer.calls.load(),0)
        }finally{@Expect(host.awaitCleanup(timeoutMillis:2000).isOk());remove(root,recursive:true)}
    }
}

// Deliberately retain the old byte-wise algorithm as an independent oracle.
// This is test-only: production must not select a fallback implementation.
func referenceLogicalJsonNodeCount(source: String): Int64 {
    var quoted = false; var escaped = false; var scalar = false; var nodes: Int64 = 0
    for (byte in source.toArray()) {
        if (quoted) {
            if (escaped) { escaped = false }
            else if (byte == b'\\') { escaped = true }
            else if (byte == b'"') { quoted = false }
        } else if (byte == b'"') { quoted = true; scalar = false; nodes += 1 }
        else if (byte == b'{' || byte == b'[') { scalar = false; nodes += 1 }
        else if (byte == b',' || byte == b':' || byte == b'}' || byte == b']' ||
            byte == b' ' || byte == b'\t' || byte == b'\r' || byte == b'\n') { scalar = false }
        else if (!scalar) { scalar = true; nodes += 1 }
        if (nodes > 65536) { throw LogicalJsonPayloadError("logical JSON has too many lexical nodes") }
    }
    nodes
}

func nodeCountScalarArray(count: Int64): String {
    let bytes = Array<Byte>(count * 2 + 1, repeat: b',')
    bytes[0] = b'['; bytes[bytes.size - 1] = b']'
    for (index in 0..count) { bytes[index * 2 + 1] = b'0' }
    String.fromUtf8(bytes)
}

func nodeCountRejects(source: String, counter: (String) -> Int64): Bool {
    try { let _ = counter(source); false }
    catch (error: LogicalJsonPayloadError) { true }
}

@Test
class OrdinaryServiceRequestLexicalPreflightTests {
    @TestCase
    func preservesEveryLexicalClassIncludingMalformedInput(): Unit {
        for (source in ["", " \t\r\n", "null", "-12.34e+5", "[true,false,null]",
            "{\"name\":\"value\"}", "{\"汉字\":\"🙂\",\"items\":[0,true,null]}",
            "\"", "\"unfinished\\", "\"\\\"", "\\\"[]", "[,,]", "{{", "0 1:2,3",
            "\u{0}", "\"\u{0}\"", "\"line\nbreak\"", "\"bad\\qescape\"", "\"\\u12\""]) {
            @Expect(logicalJsonNodeCount(source), referenceLogicalJsonNodeCount(source))
        }
        @Expect(logicalJsonNodeCount("{\"name\":\"value\"}"), 3)
        @Expect(logicalJsonNodeCount("[true,false,null]"), 4)
    }

    @TestCase
    func exhaustiveShortInputsMatchOriginalStateMachine(): Unit {
        let alphabet: Array<Byte> = [b'"', b'\\', b'[', b']', b':', b' ', b'0']
        var combinations: Int64 = 1
        var checked: Int64 = 0
        // All 137257 strings of length 0 through 6 over the state-transition
        // alphabet, not just valid JSON or randomly chosen escape examples.
        for (width in 0..7) {
            for (encoded in 0..combinations) {
                var value = encoded
                let bytes = Array<Byte>(width, repeat: b' ')
                for (index in 0..width) {
                    bytes[index] = alphabet[value % alphabet.size]
                    value /= alphabet.size
                }
                let source = String.fromUtf8(bytes)
                @Expect(logicalJsonNodeCount(source), referenceLogicalJsonNodeCount(source))
                checked += 1
            }
            combinations *= alphabet.size
        }
        @Expect(checked, 137257)
    }

    @TestCase
    func quoteTerminationUsesCompleteBackslashRunParity(): Unit {
        for (count in 0..130) {
            let slashes = String.fromUtf8(Array<Byte>(count, repeat: b'\\'))
            for (prefix in ["", "汉字🙂", "{\"key\":"]) {
                for (tail in ["", "[0,1]", "\\\" [2]", "\" : false}"]) {
                    let source = prefix + "\"body" + slashes + "\"" + tail
                    @Expect(logicalJsonNodeCount(source), referenceLogicalJsonNodeCount(source))
                }
            }
        }
    }

    @TestCase
    func longQuotedBodiesPreserveCountsAtChunkBoundaries(): Unit {
        for (size in [16383, 16384, 16385, 1048576]) {
            let body = String.fromUtf8(Array<Byte>(size, repeat: b'x'))
            let source = "{\"text\":\"" + body + "\",\"end\":[0]}"
            @Expect(logicalJsonNodeCount(source), 6)
            @Expect(logicalJsonNodeCount(source), referenceLogicalJsonNodeCount(source))
            @Expect(logicalJsonNodeCount("\"" + body), 1)
        }
    }

    @TestCase
    func escapeHeavyAndUnterminatedBodiesKeepAdvancing(): Unit {
        let bytes = Array<Byte>(65536, repeat: b'\\')
        for (index in 0..bytes.size / 2) { bytes[index * 2 + 1] = b'"' }
        let body = String.fromUtf8(bytes)
        for (suffix in ["", "\"", "\\", "[0,1]"]) {
            let source = "\"" + body + suffix
            @Expect(logicalJsonNodeCount(source), referenceLogicalJsonNodeCount(source))
        }
    }

    @TestCase
    func originalNodeCeilingStillRejectsBeforeDecoding(): Unit {
        let atLimit = nodeCountScalarArray(65535)
        @Expect(logicalJsonNodeCount(atLimit), 65536)
        @Expect(logicalJsonNodeCount(atLimit), referenceLogicalJsonNodeCount(atLimit))
        for (source in [nodeCountScalarArray(65536), atLimit + "\"unterminated", atLimit + "{"]) {
            @Expect(nodeCountRejects(source, logicalJsonNodeCount))
            @Expect(nodeCountRejects(source, referenceLogicalJsonNodeCount))
        }
    }

    @TestCase
    func lexicalPreflightDoesNotReplaceStrictJsonParsing(): Unit {
        for (source in ["\"unterminated", "\"bad\\qescape\"", "\"line\nbreak\"", "[,,]", "{\"key\":}"]) {
            let _ = logicalJsonNodeCount(source)
            var rejected = false
            try { let _ = parseUnifiedJson(source) }
            catch (error: Exception) { rejected = true }
            @Expect(rejected)
        }
    }
}
