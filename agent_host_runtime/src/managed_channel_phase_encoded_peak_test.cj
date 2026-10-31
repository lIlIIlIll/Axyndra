package agent_host_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Exercise the pinned production encoder's escaping and the existing whole
// structural bound. These are memory primitives, not fabricated Host custody,
// Store Source, permission, process or physical lifecycle acknowledgements.
@Test
class ManagedChannelPhaseEncodedPeakControls {
    @TestCase
    func nulScalarAndFieldNameKeepTheirWholeSixByteEscapesPaid():Unit {
        let raw=String.fromUtf8(Array<Byte>(131073,repeat:0))
        let value=objectValue([ValueField("\u{0}",textValue(raw)),
            ValueField("surviving",listValue([textValue("old progress"),boolValue(true),nullValue()]))])
        let measure=HostManagedGrantRetainedMeasure();measure.add(value)
        let wholeUpper=measure.encodedUpperBound()
        let encoded=stringifyUnifiedJson(value)
        @Expect(encoded.size>=raw.size*6,true)
        @Expect(encoded.size>raw.size*4,true)
        @Expect(encoded.size<=wholeUpper,true)
        @Expect(parseUnifiedJson(encoded,maxBytes:1048576).field("\u{0}").getOrThrow().text,raw)
    }
    @TestCase
    func fullEscapedGraphIsNeverClippedToAnEightMiBDescriptorLimit():Unit {
        let raw=String.fromUtf8(Array<Byte>(1572865,repeat:0))
        let value=objectValue([ValueField("action",textValue("channel_begin")),ValueField("input",textValue(raw))])
        let measure=HostManagedGrantRetainedMeasure();measure.add(value)
        let wholeUpper=measure.encodedUpperBound()
        @Expect(wholeUpper>8388608,true)
        let encoded=stringifyUnifiedJson(value)
        @Expect(encoded.size>8388608,true)
        @Expect(encoded.size<=wholeUpper,true)
    }
}
