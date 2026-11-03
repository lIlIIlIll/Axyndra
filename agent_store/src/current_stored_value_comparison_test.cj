package agent_store

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class CurrentStoredValueComparisonTests {
    @TestCase
    func exactFramesKindsUnicodeZerosNumbersAndObjectOrder(): Unit {
        let value = objectValue([ValueField("z", listValue([nullValue(), boolValue(true),
            boolValue(false), numberValue("1.00"), numberValue("-0"), textValue("") ])),
            ValueField("雪", textValue("A" + String.fromUtf8([UInt8(0)]) + "雪🙂"))])
        let frozen = encodeStoredValue(value)
        @Expect(currentStoredValueMatches(value, frozen))
        @Expect(currentStoredValueMatches(decodeStoredValue(frozen), frozen))
        @Expect(!currentStoredValueMatches(value, frozen + "n"))
        @Expect(!currentStoredValueMatches(textValue("tail"), "s4:tai"))
        let reversed = objectValue([ValueField("雪", value.field("雪").getOrThrow()),
            ValueField("z", value.field("z").getOrThrow())])
        @Expect(!currentStoredValueMatches(reversed, frozen))
        @Expect(!currentStoredValueMatches(textValue("x"), "s01:x"))
        @Expect(!currentStoredValueMatches(numberValue("1.0"), encodeStoredValue(numberValue("1.00"))))
        @Expect(!currentStoredValueMatches(textValue("true"), encodeStoredValue(boolValue(true))))
    }

    @TestCase
    func nestedMutableValuesCannotReuseFrozenProofBytes(): Unit {
        let nested = objectValue([ValueField("state", textValue("original"))])
        let list = listValue([nested, textValue("tail")])
        let value = objectValue([ValueField("list", list), ValueField("present", nullValue())])
        let frozen = encodeStoredValue(value)
        @Expect(currentStoredValueMatches(value, frozen))
        nested.put("state", textValue("changed"))
        @Expect(!currentStoredValueMatches(value, frozen))
        nested.put("state", textValue("original"))
        @Expect(currentStoredValueMatches(value, frozen))
        list.items[1] = textValue("tails")
        @Expect(!currentStoredValueMatches(value, frozen))
        list.items[1] = textValue("tail")
        @Expect(currentStoredValueMatches(value, frozen))
        value.put("new", nullValue())
        @Expect(!currentStoredValueMatches(value, frozen))
        @Expect(!currentStoredValueMatches(objectValue([]), encodeStoredValue(objectValue([ValueField("present", nullValue())]))))
    }

    @TestCase
    func fullThreeMibLastByteMutationAndFrameWidthBoundaries(): Unit {
        for (size in [0, 1, 9, 10, 99, 100, 999, 1000, 3145728]) {
            let body = String.fromUtf8(Array<Byte>(size, repeat: b'x')) + String.fromUtf8([UInt8(0)]) + "雪🙂"
            let value = objectValue([ValueField("body", textValue(body))])
            let frozen = encodeStoredValue(value)
            @Expect(currentStoredValueMatches(value, frozen))
            value.put("body", textValue(body + "changed"))
            @Expect(!currentStoredValueMatches(value, frozen))
            value.put("body", textValue(body[0..body.size - 4] + "🙃"))
            @Expect(!currentStoredValueMatches(value, frozen))
            value.put("body", textValue(body))
            @Expect(currentStoredValueMatches(value, frozen))
        }
    }

    @TestCase
    func depthAndEightMibCannotReuseOriginallyRejectedSnapshots(): Unit {
        var value = textValue("leaf")
        for (_ in 0..64) { value = listValue([value]) }
        let frozen = encodeStoredValue(value)
        @Expect(currentStoredValueMatches(value, frozen))
        value = listValue([value])
        @Expect(!currentStoredValueMatches(value, encodeStoredValue(value)))
        let large = textValue(String.fromUtf8(Array<Byte>(8388608, repeat: b'x')))
        @Expect(!currentStoredValueMatches(large, encodeStoredValue(large)))
    }
}
