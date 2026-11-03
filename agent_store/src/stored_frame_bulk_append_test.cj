package agent_store

import agent_domain.*
import std.collection.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Private test oracle is the exact original framing algorithm, never an executor.
private func originalFrameEncode(value: AgentValue): String {
    let output=ArrayList<Byte>()
    originalFrameAppendValue(output,value)
    String.fromUtf8(output.toArray())
}

func originalFrameAppendValue(output: ArrayList<Byte>, value: AgentValue): Unit {
    match (value.unifiedKind) {
        case ValueKind.Null => output.add(b'n')
        case ValueKind.Boolean => output.add(if (value.asBool()) { b't' } else { b'f' })
        case ValueKind.Number =>
            output.add(b'd')
            originalFrameAppendFrame(output, value.asNumberText())
        case ValueKind.Text =>
            output.add(b's')
            originalFrameAppendFrame(output, value.text)
        case ValueKind.List =>
            output.add(b'l')
            originalFrameAppendFrame(output, value.items.size.toString())
            for (item in value.items) { originalFrameAppendValue(output, item) }
        case ValueKind.Object =>
            output.add(b'o')
            originalFrameAppendFrame(output, value.fields.size.toString())
            for (field in value.fields) {
                originalFrameAppendFrame(output, field.name)
                originalFrameAppendValue(output, field.value)
            }
    }
}

func originalFrameAppendFrame(output: ArrayList<Byte>, value: String): Unit {
    let bytes = unsafe { value.rawData() }
    for (byte in bytes.size.toString().toArray()) { output.add(byte) }
    output.add(b':')
    for (byte in bytes) { output.add(byte) }
}


@Test
class StoredFrameBulkAppendTests {
    @TestCase
    func everyValueKindAndObjectOrderKeepOriginalCanonicalBytes(): Unit {
        let tail="A"+String.fromUtf8([UInt8(0)])+"雪🙂"
        let value=objectValue([ValueField("z",listValue([
            nullValue(),boolValue(true),boolValue(false),numberValue("1.00"),textValue(""),listValue([])])),
            ValueField("雪",textValue(tail))])
        let expected="o1:21:zl1:6ntfd4:1.00s0:l1:03:雪s9:"+tail
        let actual=encodeStoredValue(value)
        @Expect(actual,expected);@Expect(actual,originalFrameEncode(value))
        @Expect(encodeStoredValue(decodeStoredValue(actual)),expected)
        let reversed=objectValue([ValueField("雪",textValue(tail)),ValueField("z",value.field("z").getOrThrow())])
        @Expect(encodeStoredValue(reversed),originalFrameEncode(reversed))
        @Expect(encodeStoredValue(reversed)!=actual)
    }

    @TestCase
    func byteLengthFramesKeepZerosUnicodeAndDecimalWidthBoundaries(): Unit {
        for(size in [0,1,9,10,99,100,999,1000]){
            let text=String.fromUtf8(Array<Byte>(size,repeat:b'x'))+
                String.fromUtf8([UInt8(0)])+"雪🙂"
            let value=textValue(text)
            let expected="s"+(size+8).toString()+":"+text
            let actual=encodeStoredValue(value)
            @Expect(actual,expected);@Expect(actual,originalFrameEncode(value))
            @Expect(decodeStoredValue(actual).text.toArray(),text.toArray())
        }
    }

    @TestCase
    func actualThreeMibSqlRowsRetainWholeCanonicalFrameAfterMutation(): Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db=SqliteDatabase(root+"/framed.sqlite")
        let text=String.fromUtf8(Array<Byte>(3145728,repeat:b'x'))+
            String.fromUtf8([UInt8(0)])+"雪"
        let value=objectValue([ValueField("body",textValue(text)),ValueField("mode",textValue("readonly"))])
        let before=encodeStoredValue(value)
        @Expect(before,originalFrameEncode(value))
        try {
            db.execute("CREATE TABLE framed_history(value TEXT)")
            db.execute("INSERT INTO framed_history VALUES(?)",[SqlParameter.Text(before)])
            value.put("body",textValue(text+"changed"))
            let after=encodeStoredValue(value)
            @Expect(after,originalFrameEncode(value));@Expect(after!=before)
            let rows=db.query("SELECT value, length(CAST(value AS BLOB)) FROM framed_history")
            @Expect(rows[0].required(0),before)
            @Expect(rows[0].required(1),before.size.toString())
            let restored=decodeStoredValue(rows[0].required(0))
            @Expect(restored.field("body").getOrThrow().text.toArray(),text.toArray())
            @Expect(restored.field("mode").getOrThrow().text,"readonly")
            @Expect(encodeStoredValue(restored),before)
        } finally {db.close();remove(root,recursive:true)}
    }
}
