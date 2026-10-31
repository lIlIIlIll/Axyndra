package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Pure protocol fixtures, never actual Sources, grants, read facts or Root
// receipts. They show that the new shape supplies no inherited approval.
func livePolicyTestRead():ContextReadFactLink{
    let binding=documentTestBinding();let digest=modelPolicySha256Text("fixture")
    let origin=ContextReadOrigin(httpIntentText(binding,"namespace"),httpIntentText(binding,"package_digest"),
        httpIntentText(binding,"configuration_digest"),digest,digest,"read-1","parent-item",
        parentKind:"direct",parentOperationId:"parent-operation")
    ContextReadFactLink(OperationId("read-operation"),RunId("run"),ItemId("read-source"),ItemId("read-result"),
        "read-receipt",origin,digest,2)
}
func livePolicyTestCeiling():AgentValue{
    objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_CEILING_SCHEMA)),
        ValueField("documents",listValue([objectValue([ValueField("key",textValue("journal")),
            ValueField("operations",listValue([textValue("row_journal.append")]))])])),
        ValueField("filesystem",listValue([objectValue([ValueField("root",textValue("settings")),
            ValueField("canonical_root",textValue("/settings")),ValueField("operations",listValue([
                textValue("directory.create"),textValue("file.atomic_write"),textValue("directory.delete_tree")]))])]))])
}
func livePolicyTestParent():AgentValue{
    objectValue([ValueField("input",objectValue([])),ValueField("configuration",objectValue([])),
        ValueField("host_plan",objectValue([ValueField("version",textValue(PLUGIN_LIVE_POLICY_PARENT_SCHEMA)),
            ValueField("binding",documentTestBinding()),ValueField("input_payload",rowWindowTestReference("{}")),
            ValueField("effect_ceiling",livePolicyTestCeiling()),ValueField("initial_read_facts",contextReadFactLinksValue([livePolicyTestRead()])),
            ValueField("policy_provider",textValue("next_effect")),ValueField("data_schema",textValue("fixture-policy/v1"))]))])
}
func livePolicyTestChild(file!:Bool=false):AgentValue{
    let effect=if(file){objectValue([ValueField("kind",textValue("file.atomic_write")),ValueField("root",textValue("settings")),
        ValueField("relative_path",textValue("managed-skills/example/SKILL.md")),
        ValueField("canonical_path",textValue("/settings/managed-skills/example/SKILL.md"))])}
        else{objectValue([ValueField("kind",textValue("row_journal.append")),ValueField("key",textValue("journal"))])}
    objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_CHILD_SCHEMA)),ValueField("binding",documentTestBinding()),
        ValueField("sequence",integerValue(1)),ValueField("effect",effect),ValueField("proposal_payload",rowWindowTestReference("{}")),
        ValueField("read_facts",contextReadFactLinksValue([livePolicyTestRead()])),ValueField("prior_receipts",listValue([]))])
}
func livePolicyTestParentPlan(args:AgentValue,missingLinks!:Bool=false):NormalizedOperationPlan{
    let binding=args.field("host_plan").getOrThrow().field("binding").getOrThrow()
    NormalizedOperationPlan(httpIntentText(binding,"contribution"),args,
        [Capability(CapabilityKind.ExtensionInvoke,resource:httpIntentText(binding,"namespace"))],
        OperationEffectClass.ExternalMutation,OperationRetryDisposition.Never,"live-parent-plan",
        implementationFingerprint:httpIntentText(binding,"implementation_fingerprint"),schemaDigest:httpIntentText(binding,"schema_digest"),
        contextReadFacts:if(missingLinks){[]}else{[livePolicyTestRead()]})
}
func livePolicyTestChildPlan(args:AgentValue,wrongCapability!:Bool=false):NormalizedOperationPlan{
    let effect=args.field("effect").getOrThrow();let file=httpIntentText(effect,"kind")!="row_journal.append"
    let path=httpIntentText(effect,"canonical_path")
    NormalizedOperationPlan(HOST_PLUGIN_LIVE_EFFECT_TOOL,args,
        [if(file){Capability(CapabilityKind.WorkspaceWrite,resource:if(wrongCapability){"/settings"}else{path})}
            else{Capability(CapabilityKind.ExtensionInvoke,resource:if(wrongCapability){"other"}else{"axyndra:workflow"})}],
        OperationEffectClass.ExternalMutation,OperationRetryDisposition.Never,"live-child-plan",
        resolvedPaths:if(file){[path]}else{[]},toolVersion:HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT,
        implementationFingerprint:HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT)
}
func livePolicyTestReceipt(outcome!:String="completed",sequence!:Int64=1):AgentValue{
    objectValue([ValueField("sequence",integerValue(sequence)),ValueField("operation_id",textValue("child-operation")),
        ValueField("receipt_id",textValue("child-receipt")),ValueField("plan_sha256",textValue(modelPolicySha256Text("exact child plan"))),
        ValueField("outcome",textValue(outcome))])
}

@Test
class PluginLivePolicyFamilyTests{
    @TestCase
    func boundedRelationshipNeverBecomesOldParentIntentApproval():Unit{
        let parent=livePolicyTestParentPlan(livePolicyTestParent());let child=livePolicyTestChildPlan(livePolicyTestChild())
        @Expect(pluginLivePolicyChildWithinCeiling(parent,child),true)
        @Expect(isExactServiceChildPlan(child),false);@Expect(exactServiceChildAllowed(parent,child),false)
        @Expect(isFrozenPluginDocumentParentPlan(parent),false);@Expect(isPluginDocumentChildPlan(child),false)
        @Expect(pluginLivePolicyRequestKey("parent",child),"live-policy:parent:1")
    }
    @TestCase
    func fullBindingReadProjectionAndUnknownAuthorityAreRejected():Unit{
        @Expect(isPluginLivePolicyParentPlan(livePolicyTestParentPlan(livePolicyTestParent(),missingLinks:true)),false)
        for(field in ["grant","Source","owner","sql","table","private_fence","parent_intent"]){
            let child=livePolicyTestChild();child.put(field,boolValue(true));@Expect(pluginLivePolicyChildValueValid(child),false)}
        let different=livePolicyTestChild();different.field("binding").getOrThrow().put("generation",textValue("8"))
        @Expect(pluginLivePolicyChildWithinCeiling(livePolicyTestParentPlan(livePolicyTestParent()),livePolicyTestChildPlan(different)),false)
        let otherRun=livePolicyTestChild();otherRun.field("binding").getOrThrow().put("run_id",textValue("other-run"))
        @Expect(pluginLivePolicyChildValueValid(otherRun),false)
    }
    @TestCase
    func eachChildRequiresItsExactCapabilityAndSelectedDocumentOrFileRoot():Unit{
        let parent=livePolicyTestParentPlan(livePolicyTestParent())
        @Expect(pluginLivePolicyChildWithinCeiling(parent,livePolicyTestChildPlan(livePolicyTestChild(file:true))),true)
        @Expect(isPluginLivePolicyChildPlan(livePolicyTestChildPlan(livePolicyTestChild(file:true),wrongCapability:true)),false)
        @Expect(isPluginLivePolicyChildPlan(livePolicyTestChildPlan(livePolicyTestChild(),wrongCapability:true)),false)
        let other=livePolicyTestChild();other.field("effect").getOrThrow().put("key",textValue("other"))
        @Expect(pluginLivePolicyChildWithinCeiling(parent,livePolicyTestChildPlan(other)),false)
        let path=livePolicyTestChild(file:true);path.field("effect").getOrThrow().put("canonical_path",textValue("/settings-sibling/secret"))
        @Expect(pluginLivePolicyChildWithinCeiling(parent,livePolicyTestChildPlan(path)),false)
    }
    @TestCase
    func pendingUnknownAndIncompleteReceiptPrefixesCannotProposeTheNextChild():Unit{
        for(outcome in ["pending","unknown","failed","timed_out","cancelled"]){
            let child=livePolicyTestChild();child.put("sequence",integerValue(2));child.put("prior_receipts",listValue([livePolicyTestReceipt(outcome:outcome)]))
            @Expect(pluginLivePolicyChildValueValid(child),false)}
        for(outcome in ["completed","rejected"]){
            let child=livePolicyTestChild();child.put("sequence",integerValue(2));child.put("prior_receipts",listValue([livePolicyTestReceipt(outcome:outcome)]))
            @Expect(pluginLivePolicyChildValueValid(child),true)}
        let gap=livePolicyTestChild();gap.put("sequence",integerValue(3));gap.put("prior_receipts",listValue([livePolicyTestReceipt()]))
        @Expect(pluginLivePolicyChildValueValid(gap),false)
        let duplicate=livePolicyTestChild();duplicate.put("sequence",integerValue(3));duplicate.put("prior_receipts",listValue([
            livePolicyTestReceipt(),livePolicyTestReceipt(sequence:2)]));@Expect(pluginLivePolicyChildValueValid(duplicate),false)
    }
    @TestCase
    func sequenceSpellingRelativeTraversalAndMutableProposalPointersFailClosed():Unit{
        for(sequence in [integerValue(0),integerValue(-1),numberValue("1.0"),numberValue("1e0")]){
            let child=livePolicyTestChild();child.put("sequence",sequence);@Expect(pluginLivePolicyChildValueValid(child),false)}
        for(path in ["../secret","/absolute","a/../b","a//b","a\\b","C:/secret"]){
            let child=livePolicyTestChild(file:true);child.field("effect").getOrThrow().put("relative_path",textValue(path))
            @Expect(pluginLivePolicyChildValueValid(child),false)}
        let pointer=livePolicyTestChild();pointer.field("proposal_payload").getOrThrow().put("path",textValue("native path"))
        @Expect(pluginLivePolicyChildValueValid(pointer),false)
    }
    @TestCase
    func duplicateCeilingsAndRootItselfCannotBecomeAnEffect():Unit{
        let value=livePolicyTestCeiling();let rows=value.field("documents").getOrThrow().items.toArray()
        value.put("documents",listValue([rows[0],rows[0]]));@Expect(pluginLivePolicyCeilingValid(value),false)
        let root=livePolicyTestChild(file:true);root.field("effect").getOrThrow().put("canonical_path",textValue("/settings"))
        @Expect(pluginLivePolicyChildWithinCeiling(livePolicyTestParentPlan(livePolicyTestParent()),livePolicyTestChildPlan(root)),false)
        let empty=livePolicyTestCeiling();empty.put("documents",listValue([]));empty.put("filesystem",listValue([]))
        @Expect(pluginLivePolicyCeilingValid(empty),false)
    }
}
