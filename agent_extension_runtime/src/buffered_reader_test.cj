package agent_extension_runtime

import process4cj.*
import std.unittest.*
import std.unittest.testmacro.*

func bufferedReaderHost(script: String): JavaScriptExtensionHost {
    hostCleanupOwner(startProcess(ProcessCommand("/usr/bin/python3", arguments: ["-u", "-c", script])))
}

@Test
class NativeBufferedReaderTests {
    @TestCase
    func severalPhysicalFramesKeepUtf8AndCrlfBoundariesAndOneFixedCharge(): Unit {
        let before = nativePayloadOwnerBudget.usage()
        let host = bufferedReaderHost("import os; os.write(1, 'a\\r\\n雪\\nlast\\n'.encode())")
        let source = CancellationSource()
        try {
            @Expect(host.readLine(source.token, hostNowMillis() + 2000, maxFrameBytes: 3), "a")
            @Expect(host.readLine(source.token, hostNowMillis() + 2000, maxFrameBytes: 4), "雪")
            @Expect(host.readLine(source.token, hostNowMillis() + 2000, maxFrameBytes: 5), "last")
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), (before[0] + 1, before[1] + 8192)))
            var ended = false
            try { let _ = host.readLine(source.token, hostNowMillis() + 2000) }
            catch (error: ProcessError) { ended = match (error.kind) { case ProcessErrorKind.Exit => true; case _ => false } }
            @Expect(ended)
        } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); source.close() }
        @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
    }

    @TestCase
    func prefetchedNextFrameStillEnforcesItsOwnPhysicalWireLimit(): Unit {
        let before = nativePayloadOwnerBudget.usage()
        let host = bufferedReaderHost("import os; os.write(1, b'ok\\n12345\\r\\n')")
        let source = CancellationSource()
        try {
            @Expect(host.readLine(source.token, hostNowMillis() + 2000, maxFrameBytes: 3), "ok")
            var rejected = false
            try { let _ = host.readLine(source.token, hostNowMillis() + 2000, maxFrameBytes: 6) }
            catch (error: ProcessError) { rejected = match (error.kind) { case ProcessErrorKind.OutputLimit => true; case _ => false } }
            @Expect(rejected)
        } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); source.close() }
        @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
    }

    @TestCase
    func bufferedInvalidUtf8AndUnterminatedEofNeverBecomeAValidFrame(): Unit {
        for (mode in ["utf8", "eof"]) {
            let before = nativePayloadOwnerBudget.usage()
            let script = if (mode == "utf8") { "import os; os.write(1, b'ok\\n\\xc3\\n')" }
                else { "import os; os.write(1, b'ok\\nunterminated')" }
            let host = bufferedReaderHost(script); let source = CancellationSource()
            try {
                @Expect(host.readLine(source.token, hostNowMillis() + 2000), "ok")
                var rejected = false
                try { let _ = host.readLine(source.token, hostNowMillis() + 2000) }
                catch (error: ProcessError) {
                    rejected = match (error.kind) {
                        case ProcessErrorKind.Frame => mode == "utf8"
                        case ProcessErrorKind.Exit => mode == "eof"
                        case _ => false
                    }
                }
                @Expect(rejected)
            } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); source.close() }
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
        }
    }

    @TestCase
    func bufferedBytesCannotBypassCurrentCancellationOrDeadline(): Unit {
        for (mode in ["cancel", "deadline"]) {
            let before = nativePayloadOwnerBudget.usage()
            let host = bufferedReaderHost("import os; os.write(1, b'first\\nlate\\n')")
            let source = CancellationSource()
            try {
                @Expect(host.readLine(source.token, hostNowMillis() + 2000), "first")
                if (mode == "cancel") { let _ = source.cancel() }
                var rejected = false
                try { let _ = host.readLine(source.token, if (mode == "deadline") { hostNowMillis() - 1 } else { hostNowMillis() + 2000 }) }
                catch (_: Exception) { rejected = true }
                @Expect(rejected)
            } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); source.close() }
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
        }
    }
    @TestCase
    func paidBatchBoundariesKeepUtf8CrlfAndPrefetchedNextFrameExact(): Unit {
        let before=nativePayloadOwnerBudget.usage()
        let host=bufferedReaderHost("import os; os.write(1,b'a'*255+b'\\r'+b'b'*7935+'雪\\r\\nlast\\n'.encode())")
        let source=CancellationSource()
        try{
            let expected=String.fromUtf8(Array<Byte>(255,repeat:b'a'))+String.fromUtf8(Array<Byte>(7935,repeat:b'b'))+"雪"
            @Expect(host.readLine(source.token,hostNowMillis()+2000,maxFrameBytes:8196),expected)
            @Expect(host.readLine(source.token,hostNowMillis()+2000,maxFrameBytes:5),"last")
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),(before[0]+1,before[1]+8192)))
        }finally{@Expect(host.awaitCleanup(timeoutMillis:2000).isOk());source.close()}
        @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),before))
    }

    @TestCase
    func firstViolatingWireOrConfiguredByteKeepsItsOriginalRemainingCursor(): Unit {
        for(mode in ["wire","configured"]){
            let before=nativePayloadOwnerBudget.usage()
            let amount=if(mode=="wire"){256}else{JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES}
            let host=bufferedReaderHost("import os; os.write(1,b'a'*"+amount.toString()+"+b'BC\\nok\\n')")
            let source=CancellationSource()
            try{
                var rejected=false
                try{let _=host.readLine(source.token,hostNowMillis()+2000,maxFrameBytes:if(mode=="wire"){257}else{0})}
                catch(error:ProcessError){rejected=match(error.kind){
                    case ProcessErrorKind.OutputLimit=>mode=="wire"
                    case ProcessErrorKind.Frame=>mode=="configured"
                    case _=>false}}
                @Expect(rejected)
                @Expect(host.readLine(source.token,hostNowMillis()+2000,maxFrameBytes:2),if(mode=="wire"){""}else{"C"})
                @Expect(host.readLine(source.token,hostNowMillis()+2000,maxFrameBytes:3),"ok")
                @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),(before[0]+1,before[1]+8192)))
            }finally{@Expect(host.awaitCleanup(timeoutMillis:2000).isOk());source.close()}
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),before))
        }
    }
}
