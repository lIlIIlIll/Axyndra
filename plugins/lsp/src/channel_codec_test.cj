package lsp_plugin

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func compactReadValue(name: String, encoded: String): JsonNode {
    jsonObject([JsonObjectEntry(name, jsonString(encoded)), JsonObjectEntry("eof", jsonBool(false))])
}
@Test
class CompactChannelReadTests {
    @TestCase
    func originalDefaultHexShapeAndSixteenKibBoundaryRemainStrict(): Unit {
        @Expect(lspChannelReadBytes(compactReadValue("bytes_hex", "00ff")).size, 2)
        @Expect(lspChannelReadBytes(compactReadValue("bytes_hex", "00ff"))[1], 255u8)
        @Expect(lspChannelReadBytes(compactReadValue("bytes_hex", "")).size, 0)
        let maximum=String.fromUtf8(Array<Byte>(32768,repeat:b'0'))
        @Expect(lspChannelReadBytes(compactReadValue("bytes_hex", maximum)).size,16384)
        for(value in ["0","AA",maximum+"00"]){
            @Expect(editTestRejected({=>let _=lspChannelReadBytes(compactReadValue("bytes_hex",value))}))}
        @Expect(editTestRejected({=>let _=lspChannelReadBytes(compactReadValue("bytes_base64","AA=="))}))
        @Expect(editTestRejected({=>let _=lspChannelReadBytes(compactReadValue("bytes_hex","00"),encoding:"base64")}))
        let both=compactReadValue("bytes_base64","AA==");both.put("bytes_hex",jsonString("00"))
        @Expect(editTestRejected({=>let _=lspChannelReadBytes(both,encoding:"base64")}))
    }
    @TestCase
    func canonicalBase64RetainsBinaryAndSplitUtf8BeforeFraming(): Unit {
        @Expect(lspChannelReadBytes(compactReadValue("bytes_base64",""),encoding:"base64").size,0)
        let controls=lspChannelReadBytes(compactReadValue("bytes_base64","AAH/"),encoding:"base64")
        @Expect(controls.size,3);@Expect(controls[0],0u8);@Expect(controls[1],1u8);@Expect(controls[2],255u8)
        let first=lspChannelReadBytes(compactReadValue("bytes_base64","6Q=="),encoding:"base64")
        let rest=lspChannelReadBytes(compactReadValue("bytes_base64","m6o="),encoding:"base64")
        @Expect(String.fromUtf8([first[0],rest[0],rest[1]]),"雪")
        @Expect(lspChannelReadBytes(compactReadValue("bytes_base64","/w=="),encoding:"base64")[0],255u8)
    }
    @TestCase
    func canonicalPaddingDecodedBoundAndExactResultShapeRejectMalformedReads(): Unit {
        let maximum=String.fromUtf8(Array<Byte>(43691,repeat:b'A'))+"="
        @Expect(lspChannelReadBytes(compactReadValue("bytes_base64",maximum),encoding:"base64").size,32768)
        for(value in ["A","AA=","AA===","AB==","AAF=","=AAA","A=AA","AA=A","AA==AAAA","AA\n=","__8=",
            String.fromUtf8(Array<Byte>(43692,repeat:b'A'))]){
            @Expect(editTestRejected({=>let _=lspChannelReadBytes(compactReadValue("bytes_base64",value),encoding:"base64")}))}
        let wrong=compactReadValue("bytes_base64","AA==");wrong.put("eof",jsonString("false"))
        @Expect(editTestRejected({=>let _=lspChannelReadBytes(wrong,encoding:"base64")}))
    }
}
