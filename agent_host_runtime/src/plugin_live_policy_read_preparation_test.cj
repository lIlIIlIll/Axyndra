package agent_host_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class HostPluginLiveReadSelectionTests {
    @TestCase
    func PureSelectorsCannotChooseAnotherLogicalKeyOrAddSourceAndBinding():Unit{
        let good=objectValue([ValueField("document_read",objectValue([ValueField("key",textValue("journal")),ValueField("kind",textValue("latest"))]))])
        @Expect(hostLivePolicyReadSelectionValid(good,"journal"),true)
        @Expect(hostLivePolicyReadSelectionValid(good,"other"),false)
        for(name in ["source","binding","approval","thread_id","sql","path"]){
            let extra=objectValue([ValueField("document_read",good.field("document_read").getOrThrow()),ValueField(name,textValue("untrusted"))])
            @Expect(hostLivePolicyReadSelectionValid(extra,"journal"),false)}
    }
    @TestCase
    func OldWholeReadAndRowsWindowSelectorsCannotEnterNewLatestFamily():Unit{
        for(selection in [objectValue([ValueField("keys",listValue([textValue("journal")]))]),
            objectValue([ValueField("key",textValue("journal")),ValueField("window",objectValue([ValueField("kind",textValue("manifest"))]))]),
            objectValue([ValueField("key",textValue("journal")),ValueField("kind",textValue("rows"))]),
            objectValue([ValueField("key",integerValue(1)),ValueField("kind",textValue("latest"))])]){
            @Expect(hostLivePolicyReadSelectionValid(objectValue([ValueField("document_read",selection)]),"journal"),false)}
    }
}
