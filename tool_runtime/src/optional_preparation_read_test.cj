package tool_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class OptionalPreparationReadIdentityTests111 {
    @TestCase
    func optinIsFrozenInBothDescriptorCopiesAndCannotComeFromCallArguments():Unit {
        let definition=ModelToolDefinition("optional.read","actual optional resolver identity",objectValue([]))
        let resolver:ToolPreparationReadResolver={_,_=>Result<?ToolPreparationRead>.Ok(Option<ToolPreparationRead>.None)}
        let original=ToolDescriptor(definition,Capability(CapabilityKind.WorkspaceRead),preparationReadResolver:Some(resolver))
        let optional=ToolDescriptor(definition,Capability(CapabilityKind.WorkspaceRead),preparationReadResolver:Some(resolver),
            preparationReadMayBeAbsent:true)
        let injected=ToolCall("optional-call","optional.read",objectValue([ValueField("preparation_read_may_be_absent",boolValue(true))]))
        @Expect(!original.preparationReadMayBeAbsent);@Expect(!original.resolved(injected).preparationReadMayBeAbsent)
        @Expect(original.ownedPolicyIdentity().field("preparation_read_may_be_absent").isNone())
        @Expect(optional.ownedPolicyIdentity().field("preparation_read_may_be_absent").getOrThrow().asBool())
        @Expect(optional.resolved(injected).preparationReadMayBeAbsent)
        let rebound=optional.withExecutorInstance("actual-instance").value().getOrThrow()
        @Expect(rebound.preparationReadMayBeAbsent);@Expect(rebound.hasPreparationRead)
        @Expect(canonicalAgentValue(optional.ownedPolicyIdentity()),canonicalAgentValue(rebound.ownedPolicyIdentity()))
        @Expect(canonicalAgentValue(original.ownedPolicyIdentity())!=canonicalAgentValue(optional.ownedPolicyIdentity()))
    }
    @TestCase
    func optinWithoutAnActualResolverCannotPublishAnOptionalReadIdentity():Unit {
        let value=ToolDescriptor(ModelToolDefinition("absent.read","no callback",objectValue([])),
            Capability(CapabilityKind.WorkspaceRead),preparationReadMayBeAbsent:true)
        @Expect(!value.hasPreparationRead);@Expect(!value.preparationReadMayBeAbsent)
        @Expect(value.ownedPolicyIdentity().field("preparation_read_may_be_absent").isNone())
    }
}
