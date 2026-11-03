package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256

private func journalWriterRequire<T>(value:Result<T>):T{
    match(value){case Result.Ok(result)=>result;case Result.Err(error)=>throw IllegalStateException(error.code)}}

// Content/ownership fixtures only. Real files/hash/cleanup are exercised;
// there is no mocked or created Source, grant, Run, operation or Receipt.
@Test
class JournalStreamWriterOwnershipTests {
    @TestCase
    func streamMethodDoesNotWidenTheOriginalWorkerAppendBounds():Unit{
        let root=Directory.createTemp("/tmp").toString()
        let writer=HostServiceArtifactWriter(root,reserveNativeObservationBuffer())
        try{
            journalWriterRequire(writer.open())
            let chunk=Array<Byte>(65536,repeat:UInt8(97))
            @Expect(writer.appendBytes(0,chunk,16777216).isError())
            @Expect(writer.appendBytes(0,[UInt8(97)],16777217).isError())
            @Expect(writer.appendJournalStreamBytes(1,chunk,65536).isError())
            @Expect(writer.appendJournalStreamBytes(0,Array<Byte>(65537,repeat:UInt8(97)),65537).isError())
            journalWriterRequire(writer.appendJournalStreamBytes(0,chunk,65536))
            @Expect(writer.appendJournalStreamBytes(0,chunk,131072).isError())
            journalWriterRequire(writer.finish(65536,hostArtifactSha256(chunk)))
            @Expect(writer.completedArtifact().bytes,65536)
        }finally{journalWriterRequire(writer.close());remove(root,recursive:true)}
    }
    @TestCase
    func completeSixtyThreeMiBRecordAndHistoryRemainBoundedFileCopies():Unit{
        let root=Directory.createTemp("/tmp").toString()
        let writer=HostServiceArtifactWriter(root,reserveNativeObservationBuffer())
        try{
            journalWriterRequire(writer.open())
            // More than two legal 63MiB bodies. No complete body/DOM is built,
            // and no old 16MiB transport cap is raised or silently truncated.
            let total:Int64=2*63*1048576+17
            let chunk=Array<Byte>(65536,repeat:UInt8(97));let hash=SHA256()
            var offset:Int64=0
            while(offset<total){let count=min(chunk.size,total-offset);let selected=chunk[..count]
                journalWriterRequire(writer.appendJournalStreamBytes(offset,selected,total));hash.write(selected);offset+=count}
            journalWriterRequire(writer.finish(total,logicalJsonEncodeHex(hash.finish())))
            let artifact=writer.completedArtifact();@Expect(artifact.bytes,total)
            journalWriterRequire(writer.publish(root+"/"+artifact.sha256+".txt"))
            @Expect(FileInfo(Path(root+"/"+artifact.sha256+".txt")).size,total)
            journalWriterRequire(writer.verifyPublished(root+"/"+artifact.sha256+".txt"))
        }finally{journalWriterRequire(writer.close());remove(root,recursive:true)}
    }
    @TestCase
    func failedHashLeavesNoCompletedArtifactAndCleanupRemainsOwned():Unit{
        let root=Directory.createTemp("/tmp").toString()
        let writer=HostServiceArtifactWriter(root,reserveNativeObservationBuffer())
        try{
            journalWriterRequire(writer.open())
            let chunk=Array<Byte>(65536,repeat:UInt8(97))
            journalWriterRequire(writer.appendJournalStreamBytes(0,chunk,65536))
            @Expect(writer.finish(65536,modelPolicySha256Text("different")).isError())
            @Expect(Directory.readFrom(root).size,1)
            journalWriterRequire(writer.close());@Expect(Directory.readFrom(root).size,0)
            @Expect(writer.appendJournalStreamBytes(65536,[UInt8(97)],65537).isError())
            journalWriterRequire(writer.close())
        }finally{journalWriterRequire(writer.close());remove(root,recursive:true)}
    }
}
