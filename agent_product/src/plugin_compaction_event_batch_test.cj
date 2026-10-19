package agent_product

import agent_domain.*
import yjson.*
import yjson_support.*
import agent_domain.CancellationSource as CompactionBatchCancellationSource
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class InstalledCompactionEventBatchTests {
    @TestCase
    func actualInstalledBatchAndLegacyLayoutKeepSameBytesAndFinalRevocationFence(): Unit {
        let f=CompactionPolicyFixture(hybrid:false)
        let host=ProductJavaScriptPluginHost(settingsRoot:f.root+"/settings")
        let cancellation=CompactionBatchCancellationSource()
        let queries=ArrayList<ProductCompactionReferenceQuery>()
        try {
            lifecycleTestRequire(host.mount(f.record.getOrThrow()))
            let selection=lifecycleTestRequire(loadProductPolicySelection(f.root+"/settings","compaction"))
            let binding=lifecycleTestRequire(host.policyProviderBinding(selection.namespace,selection.provider))
            let summaries=ArrayList<String>()
            for(batch in [false,true]){
                let query=ProductCompactionReferenceQuery(host,selection,"batch-source",ThreadId(f.session.value),
                    cancellation.token,if(batch){"actual-batch"}else{"actual-legacy"},binding)
                queries.add(query)
                let layout=query.query("reference_layout",[])
                @Expect(layout.field("event_batch").getOrThrow().asBool())
                query.configureLayout(if(batch){layout}else{objectValue([
                    ValueField("arguments",layout.field("arguments").getOrThrow()),ValueField("state",layout.field("state").getOrThrow())])})
                let before=query.marker()
                let state=query.event(layout.field("state").getOrThrow(),objectValue([
                    ValueField("kind",textValue("message")),ValueField("role",textValue("user"))]))
                @Expect(query.marker()-before,if(batch){1}else{3})
                let next=query.event(state,objectValue([ValueField("kind",textValue("text")),ValueField("role",textValue("user")),
                    ValueField("text",query.references.intern("short 雪\r\n request"))]))
                @Expect(query.marker()-before,if(batch){3}else{7})
                let result=query.query("reference_finish",[ValueField("state",next)])
                summaries.add(query.references.compose(result.field("recipe").getOrThrow(),8388608))
                query.check()
            }
            @Expect(summaries[0],summaries[1])
            @Expect(summaries[1],"[Compacted session history]\nmessages: 1 (user 1, assistant 0)\nkey excerpts:\n- user: short 雪  request")
            lifecycleTestRequire(host.unmount(selection.namespace))
            for(query in queries){let refused=try{query.check();false}catch(_:Exception){true};@Expect(refused)}
            f.noExecutionOrCheckpoint()
        }finally{for(query in queries){query.close()};cancellation.close();let _=host.close();f.close()}
    }
}
