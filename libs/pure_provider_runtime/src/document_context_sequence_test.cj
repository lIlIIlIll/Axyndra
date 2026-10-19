package pure_provider_runtime

import std.unittest.*
import std.unittest.testmacro.*

@Test
class PureDocumentContextSequenceTests {
    @TestCase
    func oneActualContextConnectionDoesNotResetItsCounterAt4096():Unit{
        let counter=DocumentContextSequenceCounter()
        for(serial in 1..8200){@Expect(counter.accept("invoke-"+serial.toString()),true)}
        @Expect(counter.accept("invoke-4096"),false);@Expect(counter.accept("invoke-8200"),true)
    }
    @TestCase
    func malformedDuplicateOrReorderedIdsDoNotAdvanceTheLastWholeCounter():Unit{
        let counter=DocumentContextSequenceCounter();@Expect(counter.accept("invoke-8"),true)
        for(id in ["invoke-8","invoke-7","invoke-09","invoke-+9","invoke--9","invoke-0","other-9"]){@Expect(counter.accept(id),false)}
        @Expect(counter.accept("invoke-9"),true)
    }
    @TestCase
    func integerOverflowAndMaximumNeverWrapOnePhysicalConnection():Unit{
        let counter=DocumentContextSequenceCounter();@Expect(counter.accept("invoke-9223372036854775806"),true)
        @Expect(counter.accept("invoke-9223372036854775807"),false)
        @Expect(counter.accept("invoke-9223372036854775808"),false);@Expect(counter.accept("invoke-1"),false)
    }
}
