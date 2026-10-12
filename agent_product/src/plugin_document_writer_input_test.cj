package agent_product

import agent_domain.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

@Test
class PluginDocumentWriterInputTests{
    @TestCase
    func canonicalVerifierRejectsLinkSwapAfterWitnessBeforeItsFirstRead():Unit{
        documentWriterInputLinkScenario(true)
    }
    @TestCase
    func publishedVerifierRejectsLinkSwapAfterWitnessBeforeItsFirstRead():Unit{
        documentWriterInputLinkScenario(false)
    }
    @TestCase
    func emptyObservationKeepsItsOriginalPublishContractWithVerifiedFd():Unit{
        let f=PluginDocumentResetFixture();let writers=ArrayList<ProductServiceArtifactWriter>()
        try{
            let artifacts=ProductArtifactStore(f.root+"/state",database:Some(f.database))
            let writer=lifecycleTestRequire(artifacts.openServiceArtifactWriter());writers.add(writer)
            lifecycleTestRequire(writer.open());lifecycleTestRequire(writer.finish(0,modelPolicySha256Text("")))
            let path=f.root+"/state/blobs/"+modelPolicySha256Text("")+".txt"
            lifecycleTestRequire(writer.publish(path));lifecycleTestRequire(writer.verifyPublished(path))
            @Expect(File.readFrom(path).size,0);lifecycleTestRequire(writer.close())
        }finally{for(writer in writers){let _=writer.close()};f.close()}
    }
}

func documentWriterInputLinkScenario(canonical:Bool):Unit{
    let f=PluginDocumentResetFixture();let writers=ArrayList<ProductServiceArtifactWriter>();let linked=AtomicBool(false)
    let digest=modelPolicySha256Text("null");let path=f.root+"/state/blobs/"+digest+".txt"
    try{
        let artifacts=ProductArtifactStore(f.root+"/state",database:Some(f.database))
        let writer=lifecycleTestRequire(artifacts.openServiceArtifactWriter());writers.add(writer)
        lifecycleTestRequire(writer.open());lifecycleTestRequire(writer.append(0,"null",4));lifecycleTestRequire(writer.finish(4,digest))
        lifecycleTestRequire(writer.publish(path))
        let external=f.root+"/external-secret";File.writeTo(external,"FAIL".toArray())
        let calls=AtomicInt64(0)
        let guard={=>
            // #1 precedes probe; #2 follows the frozen no-follow witness and
            // adoption but precedes fd open. The first-read guard is #3.
            if(calls.fetchAdd(1)==1){rename(path,to:path+".original");SymbolicLink.create(path,to:external);linked.store(true)}
            Result<Unit>.Ok(())}
        let result=if(canonical){writer.verifyCanonicalDocument(path,guard,receiptValue:true)}else{writer.verifyPublished(path,guard:guard)}
        @Expect(result.isError());@Expect(result.error().getOrThrow().code,"plugin.document_payload_file_changed")
        @Expect(calls.load(),2) // No first-read checkpoint, hence zero content bytes.
        @Expect(String.fromUtf8(File.readFrom(external)),"FAIL")
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
        lifecycleTestRequire(writer.close());remove(path);rename(path+".original",to:path);linked.store(false)
    }finally{
        for(writer in writers){let _=writer.close()}
        if(linked.load()){remove(path);rename(path+".original",to:path)}
        f.close()
    }
}
