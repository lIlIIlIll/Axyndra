package agent_product

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func initialWindowTestSelection(version!:Int64=7):AgentValue{
    let value=objectValue([ValueField("version",integerValue(version)),ValueField("namespace",textValue("memory")),
        ValueField("package_digest",textValue("sha256:"+modelPolicySha256Text("actual-package"))),ValueField("provider",textValue("memory_context")),
        ValueField("resources",listValue([textValue("journal")])),ValueField("query",objectValue([
            ValueField("schema",textValue("axyndra.memory-context-query/v1")),ValueField("query",textValue("")),
            ValueField("max_bytes",integerValue(4096))])),ValueField("prompt_field",textValue(""))])
    if(version==7){value.put("preparation_provider",textValue("prepare_window_context"))};value
}

@Test
class PluginInitialContextWindowConfigurationTests {
    @TestCase
    func explicitSeparateTypedProviderKeepsLogicalKeysAndFullConfigurationIdentity():Unit{
        let value=initialWindowTestSelection();let raw=stringifyUnifiedJson(value)+"\n "
        let selection=lifecycleTestRequire(parseInitialContextSelection("/tmp",raw,None))
        @Expect(selection.windowProtocol);@Expect(!selection.documentProtocol);@Expect(!selection.preparationProtocol)
        @Expect(selection.preparationProvider,"prepare_window_context");@Expect(selection.provider,"memory_context")
        @Expect(selection.resources().items[0].text,"journal")
        @Expect(selection.digest,modelPolicySha256Text(raw));@Expect(initialContextSelectionMaximumReads(selection),8)
        @Expect(selection.query("prompt").field("query").getOrThrow().text,"")
    }
    @TestCase
    func displayAuthorityAndFilesystemLocatorsCannotEnterWindowConfiguration():Unit{
        for(field in ["source","capabilities","approval","operation_id","generation","lane_id","binding"]){
            let value=initialWindowTestSelection();value.put(field,textValue("display-copy"))
            @Expect(parseInitialContextSelection("/tmp",stringifyUnifiedJson(value),None).isError())}
        for(key in ["../journal","/tmp/journal","blob:sha256:body",""]){
            let value=initialWindowTestSelection();value.put("resources",listValue([textValue(key)]))
            @Expect(parseInitialContextSelection("/tmp",stringifyUnifiedJson(value),None).isError())}
        let duplicate=initialWindowTestSelection();duplicate.put("resources",listValue([textValue("journal"),textValue("journal")]))
        @Expect(parseInitialContextSelection("/tmp",stringifyUnifiedJson(duplicate),None).isError())
    }
    @TestCase
    func ordinaryDocumentSelectionRemainsSeparateAndMalformedPreparationCannotSelectWindows():Unit{
        let old=lifecycleTestRequire(parseInitialContextSelection("/tmp",stringifyUnifiedJson(initialWindowTestSelection(version:5)),None))
        @Expect(old.documentProtocol);@Expect(!old.windowProtocol);@Expect(old.preparationProvider,"")
        @Expect(initialContextSelectionMaximumReads(old),1)
        for(provider in ["","memory_context"," "]){
            let value=initialWindowTestSelection();value.put("preparation_provider",textValue(provider))
            @Expect(parseInitialContextSelection("/tmp",stringifyUnifiedJson(value),None).isError())}
        let typed=initialWindowTestSelection();typed.put("preparation_provider",integerValue(1))
        @Expect(parseInitialContextSelection("/tmp",stringifyUnifiedJson(typed),None).isError())
    }
    @TestCase
    func compositionPaysWholeEightReadCeilingAndKeepsOuterBytesFrozen():Unit{
        let value=objectValue([ValueField("version",integerValue(6)),ValueField("selections",listValue([initialWindowTestSelection()]))])
        let raw=stringifyUnifiedJson(value)+"\n"
        let one=lifecycleTestRequire(parseInitialContextSelections("/tmp",raw,None))
        @Expect(one.size,1);@Expect(one[0].digest,modelPolicySha256Text(raw));@Expect(one[0].windowProtocol)
        let other=initialWindowTestSelection(version:5);other.put("provider",textValue("second_context"))
        value.put("selections",listValue([initialWindowTestSelection(),other]))
        @Expect(parseInitialContextSelections("/tmp",stringifyUnifiedJson(value),None).isError())
    }
}
