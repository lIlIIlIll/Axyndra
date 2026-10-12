package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import std.convert.*

foreign func axyndra_document_input_open(source:CString,witness:CString,bytes:Int64):Int32
foreign func axyndra_journal_stream_input_open(source:CString,witness:CString,bytes:Int64):Int32
foreign func axyndra_document_input_read(fd:Int32,witness:CString,buffer:CPointer<UInt8>,capacity:Int64):Int64
foreign func axyndra_document_input_rewind(fd:Int32,witness:CString):Int32
foreign func axyndra_document_input_close(fd:Int32):Int32

// Adopt this object into the bounded session before open(). Its only content
// source is a no-follow verified fd, never a pathname reopened by std.fs.File.
// The original identity includes inode, mode, size, mtime and ctime. Each read
// checks that same fd before and after filling the private bounded buffer.
public class HostVerifiedArtifactInput {
    private let witness:String
    private let bytes:Int64
    private var fd:Int32 = -1
    public init(witness:String,bytes:Int64){this.witness=witness;this.bytes=bytes}
    public func open(path:String):Result<Unit>{
        if(fd>=0){return hostPluginResourceError("plugin.document_payload_file_changed","document input handle is already owned")}
        let actual=unsafe{
            let source=LibC.mallocCString(path);let expected=LibC.mallocCString(witness)
            try{axyndra_document_input_open(source,expected,bytes)}
            finally{LibC.free(expected);LibC.free(source)}}
        if(actual<0){return hostPluginResourceError("plugin.document_payload_file_changed","document input cannot open its frozen link-free identity")}
        fd=actual;Result.Ok(())
    }
    // Package-local completed-content verification only. Ordinary document
    // open retains its original limit and implementation.
    func openJournalStream(path:String):Result<Unit>{
        if(fd>=0){return hostPluginResourceError("plugin.document_payload_file_changed","journal stream handle is already owned")}
        let actual=unsafe{
            let source=LibC.mallocCString(path);let expected=LibC.mallocCString(witness)
            try{axyndra_journal_stream_input_open(source,expected,bytes)}
            finally{LibC.free(expected);LibC.free(source)}}
        if(actual<0){return hostPluginResourceError("plugin.document_payload_file_changed","journal stream cannot open its frozen link-free identity")}
        fd=actual;Result.Ok(())
    }
    public func read(buffer:Array<Byte>):Result<Int64>{
        if(fd<0 || buffer.size<1 || buffer.size>65536){
            return hostPluginResourceError("plugin.document_payload_file_changed","document input has no bounded owned handle")}
        let count=unsafe{
            let expected=LibC.mallocCString(witness);let raw=acquireArrayRawData(buffer)
            try{axyndra_document_input_read(fd,expected,raw.pointer,buffer.size)}
            finally{releaseArrayRawData(raw);LibC.free(expected)}}
        if(count<0 || count>buffer.size){return hostPluginResourceError("plugin.document_payload_file_changed","document input changed before bytes could be consumed")}
        Result.Ok(count)
    }
    public func rewind():Result<Unit>{
        if(fd<0){return hostPluginResourceError("plugin.document_payload_file_changed","document input handle is closed")}
        let result=unsafe{
            let expected=LibC.mallocCString(witness)
            try{axyndra_document_input_rewind(fd,expected)}finally{LibC.free(expected)}}
        if(result!=0){return hostPluginResourceError("plugin.document_payload_file_changed","document input changed before its verified replay")}
        Result.Ok(())
    }
    public func close():Result<Unit>{
        if(fd<0){return Result.Ok(())}
        let result=unsafe{axyndra_document_input_close(fd)}
        if(result!=0){return hostPluginResourceError("plugin.document_query_cleanup_pending","document input descriptor remains owned")}
        fd = -1;Result.Ok(())
    }
}
