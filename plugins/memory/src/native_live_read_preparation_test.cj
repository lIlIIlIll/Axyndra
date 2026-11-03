package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class NativeMemoryLiveReadPreparationTests {
    @TestCase
    func PublishedMemoryToolsSelectTheirLogicalReadWithoutBusinessParameters():Unit{
        for(tool in MEMORY_NATIVE_TOOLS){
            let actual=memoryDocumentPolicy("prepare_document",objectValue([
                ValueField("schema",textValue(MEMORY_LIVE_READ_PREPARATION_QUERY)),ValueField("tool",textValue(tool))]))
            @Expect(httpIntentExactFields(actual,["document_read"]),true)
            let read=actual.field("document_read").getOrThrow()
            @Expect(httpIntentExactFields(read,["key","kind"]),true)
            @Expect(httpIntentText(read,"key"),MEMORY_JOURNAL_KEY)
            @Expect(httpIntentText(read,"kind"),"latest")}
    }
    @TestCase
    func PreparationCannotAcceptCallerFactsPathsScopeOrAuthority():Unit{
        for(field in ["input","facts","thread_id","workspace_root","key","binding","source","approval"]){
            let value=objectValue([ValueField("schema",textValue(MEMORY_LIVE_READ_PREPARATION_QUERY)),
                ValueField("tool",textValue("retain")),ValueField(field,textValue("caller supplied"))])
            let failure=@AssertThrows[PureProviderError](memoryDocumentPolicy("prepare_document",value))
            @Expect(failure.code,"memory.document_shape")}
    }
    @TestCase
    func UnknownOrForeignProviderAndNontextToolStayClosed():Unit{
        for(tool in [textValue("plugin.foreign.retain"),textValue("unknown"),integerValue(1)]){
            let value=objectValue([ValueField("schema",textValue(MEMORY_LIVE_READ_PREPARATION_QUERY)),ValueField("tool",tool)])
            let _=@AssertThrows[PureProviderError](memoryDocumentPolicy("prepare_document",value))}
        let value=objectValue([ValueField("schema",textValue(MEMORY_LIVE_READ_PREPARATION_QUERY)),ValueField("tool",textValue("retain"))])
        let _=@AssertThrows[PureProviderError](memoryDocumentPolicy("other_provider",value))
    }
    @TestCase
    func OriginalDefaultPreparationRetainsExactWholeReadSelection():Unit{
        let original=objectValue([ValueField("schema",textValue("axyndra.tool-preparation-query/v1")),
            ValueField("tool",textValue("retain")),ValueField("input",objectValue([]))])
        let actual=memoryDocumentPolicy("prepare_document",original)
        @Expect(httpIntentExactFields(actual,["document_read"]),true)
        @Expect(httpIntentExactFields(actual.field("document_read").getOrThrow(),["keys"]),true)
        let keys=actual.field("document_read").getOrThrow().field("keys").getOrThrow()
        @Expect(keys.items.size,1)
        @Expect(keys.items[0].text,MEMORY_JOURNAL_KEY)
    }
}
