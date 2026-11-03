package agent_host_runtime

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Private bridge contracts only. These real files/witnesses are not Root,
// Source, Receipt, a published artifact or an execution grant.
func transferWitnessTestBytes():String {
    stringifyUnifiedJson(objectValue([ValueField("version",integerValue(1)),ValueField("plugins",listValue([
        objectValue([ValueField("namespace",textValue("axyndra:memory")),
            ValueField("package_digest",textValue("sha256:"+modelPolicySha256Text("witness-test-package"))),
            ValueField("tools",listValue([objectValue([ValueField("name",textValue("journal_tool")),
                ValueField("documents",listValue([objectValue([ValueField("key",textValue("journal")),
                    ValueField("read",boolValue(true)),ValueField("write",boolValue(false))])]))])]))])]))]))
}
func transferWitnessTestEqual(path:String,witness:String,bytes:Array<Byte>,length:Int64):Int32 {
    unsafe {
        let source=LibC.mallocCString(path)
        try {
            let expected=LibC.mallocCString(witness)
            try {
                let raw=acquireArrayRawData(bytes)
                try{axyndra_read_view_equal(source,expected,raw.pointer,length)}
                finally{releaseArrayRawData(raw)}
            }finally{LibC.free(expected)}
        }finally{LibC.free(source)}
    }
}

@Test
class HostDocumentTransferWitnessTests {
    @TestCase
    func maximumWholeConfigurationSurvivesRepeatedActualTransferValidation():Unit {
        let root=Directory.createTemp("/tmp")
        try {
            Directory.create(root.join("plugins"))
            let original=transferWitnessTestBytes()
            let encoded=original+String.fromUtf8(Array<Byte>(65536-original.size,repeat:32))
            @Expect(encoded.size,65536)
            let path=root.join("plugins").join("documents.json")
            File.writeTo(path,encoded.toArray())
            let frozen=loadHostPluginDocumentConfiguration(root.toString(),"axyndra:memory",
                "sha256:"+modelPolicySha256Text("witness-test-package")).value().getOrThrow()
            @Expect(frozen.permits("journal_tool","journal",false));@Expect(!frozen.permits("journal_tool","journal",true))
            for(_ in 0..16){@Expect(frozen.validateTransferWitness().isOk())}
            @Expect(String.fromUtf8(File.readFrom(path)),encoded)
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func currentRealIdentityStillRequiresEveryByteAndOriginalLengthCeiling():Unit {
        let root=Directory.createTemp("/tmp")
        try {
            let path=root.join("complete-bytes")
            let bytes=Array<Byte>(65536,repeat:97)
            bytes[16383]=0;bytes[16384]=255;bytes[65535]=0
            File.writeTo(path,bytes)
            let witness=hostReadResourceWitness(path.toString()).value().getOrThrow()
            @Expect(transferWitnessTestEqual(path.toString(),witness,bytes,65536)==0)
            for(offset in [0,16383,16384,32768,65535]) {
                let original=bytes[offset];bytes[offset]=if(original==0){1}else{0}
                @Expect(transferWitnessTestEqual(path.toString(),witness,bytes,65536)!=0)
                bytes[offset]=original
            }
            @Expect(transferWitnessTestEqual(path.toString(),witness,bytes,0)!=0)
            @Expect(transferWitnessTestEqual(path.toString(),witness,bytes,65537)!=0)
            @Expect(transferWitnessTestEqual(path.toString(),witness,bytes,65536)==0)
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func identicalReplacementMissingAndTruncatedFilesRejectTheFrozenConfiguration():Unit {
        let root=Directory.createTemp("/tmp")
        try {
            Directory.create(root.join("plugins"));let path=root.join("plugins").join("documents.json")
            let encoded=transferWitnessTestBytes();let digest="sha256:"+modelPolicySha256Text("witness-test-package")
            File.writeTo(path,encoded.toArray())
            let frozen=loadHostPluginDocumentConfiguration(root.toString(),"axyndra:memory",digest).value().getOrThrow()
            @Expect(frozen.validateTransferWitness().isOk())
            // Keep the original inode alive at another name: an identical
            // replacement cannot accidentally reuse that original inode.
            rename(path,to:root.join("original-grant"),overwrite:false)
            File.writeTo(path,encoded.toArray())
            @Expect(frozen.validateTransferWitness().isError())
            let replaced=loadHostPluginDocumentConfiguration(root.toString(),"axyndra:memory",digest).value().getOrThrow()
            @Expect(replaced.validateTransferWitness().isOk())
            File.writeTo(path,"{".toArray());@Expect(replaced.validateTransferWitness().isError())
            remove(path);@Expect(replaced.validateTransferWitness().isError())
        }finally{remove(root,recursive:true)}
    }
}
