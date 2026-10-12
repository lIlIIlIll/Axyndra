package shell_readonly_plugin

import agent_domain.*
import process4cj.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*


@Test
class ReadonlyShellPrivateOutputCodecTests {
    @TestCase
    func wholeRawControlsAndInvalidUtf8UseOriginalCombinedCaptureWithExactHashes():Unit {
        let charge=srPayloadProcess.acquire(2097152)
        try{charge.ensureDecoded(4194304,8192)
            for(byte in [1u8,255u8]){
                let raw=Array<Byte>(131072,repeat:byte);let encoded=srEncodeCaptured(raw)
                @Expect(srDecodeCaptured(encoded),raw)
                let body=jsonObject([JsonObjectEntry("exit_code",jsonNumber("0")),JsonObjectEntry("stdout",encoded),
                    JsonObjectEntry("stderr",srEncodeCaptured([])),JsonObjectEntry("timed_out",jsonBool(false)),JsonObjectEntry("truncated",jsonBool(false))])
                @Expect(stringifyUnifiedJson(body).size<229376)
                let output=srDecodeWorkerResult(body)
                @Expect(output.field("stdout").getOrThrow().text,decodeProcessOutput(raw))
                @Expect(stringifyUnifiedJson(output).size<=1048576)
                @Expect(output.fields.size,5)}
        }finally{charge.close()}
    }
    @TestCase
    func noncanonicalPaddingWrongLengthHashAndExtraFieldsAreNeverAccepted():Unit {
        let charge=srPayloadProcess.acquire(2097152)
        try{charge.ensureDecoded(4194304,8192)
            for(kind in ["padding","length","hash","extra"]){
                let value=srEncodeCaptured([65u8])
                if(kind=="padding"){value.put("data",jsonString("QR=="))}
                else if(kind=="length"){value.put("bytes",jsonNumber("2"))}
                else if(kind=="hash"){value.put("sha256",jsonString(modelPolicySha256([66u8])))}
                else{value.put("forged",jsonBool(true))}
                var denied=false;try{let _=srDecodeCaptured(value)}catch(_:ReadonlyShellFailure){denied=true}
                @Expect(denied)}
        }finally{charge.close()}
    }
    @TestCase
    func streamsCannotEachBorrowTheFullCombinedCaptureAndFailedDecodeReleasesReservation():Unit {
        let before=srPayloadOwner.usage();let charge=srPayloadProcess.acquire(2097152)
        try{charge.ensureDecoded(4194304,8192)
            let raw=Array<Byte>(65537,repeat:65u8)
            let body=jsonObject([JsonObjectEntry("exit_code",jsonNumber("0")),JsonObjectEntry("stdout",srEncodeCaptured(raw)),
                JsonObjectEntry("stderr",srEncodeCaptured(raw)),JsonObjectEntry("timed_out",jsonBool(false)),JsonObjectEntry("truncated",jsonBool(false))])
            var denied=false;try{let _=srDecodeWorkerResult(body)}catch(_:ReadonlyShellFailure){denied=true}
            @Expect(denied)
        }finally{charge.close()}
        let after=srPayloadOwner.usage();@Expect(after[0],before[0]);@Expect(after[1],before[1])
    }

    @TestCase
    func pressureFailureClosesOnlyItsOwnFixedBufferAndPreservesExistingPaidOwners():Unit {
        let initial=srPayloadOwner.usage();let first=srPayloadProcess.acquire(1048576)
        try{let input=ReadonlyShellPayloadInput()
            try{let before=srPayloadOwner.usage();var denied=false
                try{let unexpected=ReadonlyShellPayloadInput();unexpected.close()}catch(_:LogicalJsonPayloadError){denied=true}
                @Expect(denied);let after=srPayloadOwner.usage()
                @Expect(after[0],before[0]);@Expect(after[1],before[1])
            }finally{input.close()}
        }finally{first.close()}
        let finalUsage=srPayloadOwner.usage();@Expect(finalUsage[0],initial[0]);@Expect(finalUsage[1],initial[1])
    }
}
