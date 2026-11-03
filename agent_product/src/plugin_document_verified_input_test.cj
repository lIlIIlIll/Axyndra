package agent_product

import agent_domain.*
import agent_store.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// These tests use the actual canonical ContextRead fixture and actual artifact
// metadata. They cover the resource/input seam; no full public native pipeline
// or completed-history restoration is inferred from this narrower coverage.
@Test
class PluginDocumentVerifiedInputTests{
    @TestCase
    func replacementBetweenWitnessAndOpenCannotConsumeExternalBytes():Unit{
        let f=PluginDocumentResetFixture();let owned=ArrayList<ProductDocumentVerifiedInput>()
        try{
            let original=DocumentPayloadProductRead(f,textValue("authorized original"))
            let artifacts=ProductArtifactStore(f.root+"/state",database:Some(f.database))
            let reader=artifacts.documentPayloadReader(productOperationStore(f.database),original.source,original.plan,{=>Result<Unit>.Ok(())},None)
            let observed=try{lifecycleTestRequire(reader.read())}finally{lifecycleTestRequire(reader.close())}
            original.commit(observed)
            let reference=parsePluginDocumentPayloadReference(observed.field("documents").getOrThrow().items[0].field("payload").getOrThrow()).value().getOrThrow()
            let path=f.root+"/state/blobs/"+reference.digest+".txt";let external=f.root+"/external-secret"
            File.writeTo(external,Array<Byte>(reference.bytes,repeat:b's'))
            // adopt() occurs after the real no-follow witness probe, before
            // the real fd open. This deterministically exercises that window.
            let result=artifacts.openDocumentDataInput(reference,{actual=>
                owned.add(actual);rename(path,to:path+".original");SymbolicLink.create(path,to:external);Result<Unit>.Ok(())})
            @Expect(result.isError());@Expect(result.error().getOrThrow().code,"plugin.document_payload_file_changed")
            let consumed=AtomicInt64(0);let bytes=owned[0].read(Array<Byte>(65536,repeat:0))
            match(bytes){case Result.Ok(count)=>let _=consumed.fetchAdd(count);case Result.Err(_)=>()}
            @Expect(bytes.isError());@Expect(consumed.load(),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),1)
            lifecycleTestRequire(owned[0].close());remove(path);rename(path+".original",to:path)
        }finally{for(value in owned){let _=value.close()};f.close()}
    }
    @TestCase
    func sameSizeWrongContentIsRejectedBeforeTheFirstUploadCallback():Unit{
        documentVerifiedUploadScenario(false)
    }
    @TestCase
    func mutationDuringReplayStopsBeforeAnyChangedChunkIsConsumed():Unit{
        documentVerifiedUploadScenario(true)
    }
}

func documentVerifiedUploadScenario(mutateAfterFirst:Bool):Unit{
    let f=PluginDocumentResetFixture();var retained:?ProductDocumentDataSession=None
    try{
        let original=DocumentPayloadProductRead(f,textValue(String.fromUtf8(Array<Byte>(131070,repeat:b'a'))))
        let store=productOperationStore(f.database);let artifacts=ProductArtifactStore(f.root+"/state",database:Some(f.database))
        let reader=artifacts.documentPayloadReader(store,original.source,original.plan,{=>Result<Unit>.Ok(())},None)
        let observed=try{lifecycleTestRequire(reader.read())}finally{lifecycleTestRequire(reader.close())}
        original.commit(observed);let fact=lifecycleTestRequire(store.loadContextReadFact(original.source.operationId,original.source.runId))
        let reference=parsePluginDocumentPayloadReference(observed.field("documents").getOrThrow().items[0].field("payload").getOrThrow()).value().getOrThrow()
        let binding=original.plan.canonicalArguments.field("binding").getOrThrow();let path=f.root+"/state/blobs/"+reference.digest+".txt"
        let changed=Array<Byte>(reference.bytes,repeat:b's');let consumed=AtomicInt64(0);let callbacks=AtomicInt64(0)
        let session=artifacts.documentDataSession();retained=Some(session)
        let operations=f.database.scalarInt("SELECT COUNT(*) FROM operations");let receipts=f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
        let result=session.run({actual=>
            match(actual.authorize(fact.link(),binding,observed,{=>Result<Unit>.Ok(())})){
                case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            if(!mutateAfterFirst){File.writeTo(path,changed)}
            let uploaded=actual.upload(reference,{=>Result<Unit>.Ok(())},{offset,bytes=>
                @Expect(offset,0);@Expect(bytes,original.original.encoded.toArray()[..bytes.size])
                let _=consumed.fetchAdd(bytes.size);let _=callbacks.fetchAdd(1)
                if(mutateAfterFirst){File.writeTo(path,changed)}
                Result<Unit>.Ok(())})
            match(uploaded){case Result.Err(error)=>Result<AgentValue>.Err(error);case Result.Ok(_)=>Result.Ok(nullValue())}
        })
        @Expect(result.isError());@Expect(result.error().getOrThrow().code,"plugin.document_payload_file_changed")
        @Expect(callbacks.load(),if(mutateAfterFirst){1}else{0});@Expect(consumed.load(),if(mutateAfterFirst){65536}else{0})
        @Expect(session.collect());lifecycleTestRequire(session.close())
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),operations)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),receipts)
        @Expect(lifecycleTestRequire(f.documents.read(original.source.threadId,LaneId("main"),"axyndra:workflow","todo")).encoded,original.original.encoded)
    }finally{match(retained){case Some(value)=>let _=value.close();case None=>()};f.close()}
}
