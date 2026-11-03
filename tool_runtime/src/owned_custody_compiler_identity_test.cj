package tool_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

private class CompilerReferenceCustody <: LiveToolExecutionCustody {
    let label="same fields do not own the same resource"
    public func releaseTransient():Result<Unit>{Result.Ok(())}
    public func close():Result<Unit>{Result.Ok(())}
}
private struct CompilerValueCustody <: LiveToolExecutionCustody {
    public func releaseTransient():Result<Unit>{Result.Ok(())}
    public func close():Result<Unit>{Result.Ok(())}
}

// Real interface/class/value language identity, no Root or resource release
// claim. Existing continuation/custody tests remain byte-for-byte unchanged.
@Test
class OwnedCustodyCompilerIdentityTests {
    @TestCase
    func onlySameActualReferenceObjectMayTransferPhysicalCustody():Unit{
        let original=CompilerReferenceCustody()
        let same:LiveToolExecutionCustody=original
        let other:LiveToolExecutionCustody=CompilerReferenceCustody()
        let value:LiveToolExecutionCustody=CompilerValueCustody()
        @Expect(sameLiveToolExecutionCustody(original,same),true)
        @Expect(sameLiveToolExecutionCustody(original,other),false)
        @Expect(sameLiveToolExecutionCustody(value,value),false)
        @Expect(sameLiveToolExecutionCustody(original,value),false)
    }
}
