package process4cj

import std.io.*
import std.unittest.*
import std.unittest.testmacro.*

foreign func pipe(fds:CPointer<Int32>):Int32

// Real descriptor/C-call controls, no mock process, PID, Root or Source.
@Test
class Process4CjReleaseFirstTests{
    @TestCase
    func negativeForeignReadCanAllocateItsOriginalErrorOnlyAfterRelease():Unit{
        let bytes=Array<Byte>(8192,repeat:65)
        for(index in 0..256){
            var rejected=false
            try{let _=nativeProcessReadBytes(-1,bytes)}catch(error:ProcessError){
                rejected=true;@Expect(processErrorKindName(error.kind),"io")
                @Expect(error.message.startsWith("process pipe read failed errno="),true)
                let copied=error.message+"-"+index.toString();@Expect(copied.size>0,true)}
            @Expect(rejected,true);@Expect(bytes[0],65u8);@Expect(bytes[8191],65u8)
        }
    }
    @TestCase
    func negativeForeignWriteCanAllocateItsOriginalErrorOnlyAfterRelease():Unit{
        let bytes="完整 write snow 雪".toArray()
        for(index in 0..256){
            var rejected=false
            try{nativeProcessWriteBytes(-1,bytes)}catch(error:ProcessError){
                rejected=true;@Expect(processErrorKindName(error.kind),"broken_pipe")
                @Expect(error.message.startsWith("process stdin write failed errno="),true)
                let copied=error.message+"-"+index.toString();@Expect(copied.size>0,true)}
            @Expect(rejected,true);@Expect(String.fromUtf8(bytes),"完整 write snow 雪")
        }
    }
    @TestCase
    func actualPipeReadWriteAndEofKeepOriginalBytesAndSingleOwnedClose():Unit{
        let fds=unsafe{LibC.malloc<Int32>(count:2)}
        let (reader,writer)=unsafe{
            try{if(pipe(fds)!=0){throw IllegalStateException("real pipe setup failed")};(fds.read(0),fds.read(1))}
            finally{LibC.free(fds)}}
        let input=NativeProcessInput(reader);var writerClosed=false
        try{
            let original="real pipe 完整雪 EOF".toArray();nativeProcessWriteBytes(writer,original)
            let buffer=Array<Byte>(8192,repeat:0);let count=input.read(buffer)
            @Expect(count,original.size);@Expect(String.fromUtf8(buffer[..count]),"real pipe 完整雪 EOF")
            let result=unsafe{process4cj_close(writer)};writerClosed=true;@Expect(result,0)
            @Expect(input.read(buffer),0);@Expect(input.isClosed(),true)
            input.close();input.close();@Expect(input.read(buffer),0)
        }finally{input.close();if(!writerClosed){let _=unsafe{process4cj_close(writer)}}}
    }
}
