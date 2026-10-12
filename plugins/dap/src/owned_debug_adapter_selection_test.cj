package dap_plugin

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func dapOwnedSelectionControlConfiguration():JsonNode{
    parseUnifiedJson("{\"adapter\":\"legacy\",\"launch\":{},\"attach\":{},\"workspace_mode\":\"workspace_readonly\",\"network\":{\"mode\":\"deny\"},\"adapters\":{\"first\":{\"service_id\":\"stdio\",\"fileTypes\":[\".c\"],\"launchDefaults\":{\"stopOnEntry\":true},\"attachDefaults\":{}},\"second\":{\"service_id\":\"secondary\",\"fileTypes\":[\".py\"],\"launchDefaults\":{},\"attachDefaults\":{\"host\":\"localhost\"}}},\"configured_processes\":[{\"service_id\":\"stdio\",\"executable\":\"/usr/bin/first\",\"args\":[\"--first\"],\"environment\":{\"FIXED\":\"first\"},\"compatible_scope\":true},{\"service_id\":\"secondary\",\"executable\":\"/usr/bin/second\",\"args\":[\"--second\"],\"environment\":{\"FIXED\":\"second\"},\"compatible_scope\":true}]}")
}

@Test
class DapOwnedAdapterSelectionTests{
    @TestCase
    func explicitIdentityFileTypeAndOrderedFallbackUseDifferentFixedPrograms():Unit{
        let configuration=dapOwnedSelectionControlConfiguration()
        let bySuffix=dapOwnedSelectAdapter(parseUnifiedJson("{\"program\":\"main.py\"}"),configuration)
        @Expect(text(bySuffix,"adapter"),"second");@Expect(text(bySuffix,"configured_process"),"secondary")
        @Expect(text(bySuffix,"executable"),"/usr/bin/second")
        @Expect(text(field(bySuffix,"environment"),"FIXED"),"second")
        let explicit=dapOwnedSelectAdapter(parseUnifiedJson("{\"program\":\"main.py\",\"adapter\":\"first\"}"),configuration)
        @Expect(text(explicit,"adapter"),"first");@Expect(text(explicit,"configured_process"),"stdio")
        @Expect(boolean(field(explicit,"launch"),"stopOnEntry"),true)
        let fallback=dapOwnedSelectAdapter(parseUnifiedJson("{\"program\":\"unknown.extension\"}"),configuration)
        @Expect(text(fallback,"adapter"),"first")
    }
    @TestCase
    func unknownExplicitMissingActualCeilingAndIncompatibleScopeNeverFallBack():Unit{
        for(mode in ["identity","ceiling","scope"]){
            let configuration=dapOwnedSelectionControlConfiguration()
            let input=parseUnifiedJson("{\"adapter\":\"second\"}")
            if(mode=="identity"){input.put("adapter",jsonString("absent"))}
            else if(mode=="ceiling"){configuration.put("configured_processes",jsonArray([]))}
            else{field(configuration,"configured_processes").items[1].put("compatible_scope",jsonBool(false))}
            var rejected=false
            try{let _=dapOwnedSelectAdapter(input,configuration)}catch(_:Exception){rejected=true}
            @Expect(rejected,true)
        }
    }
}
