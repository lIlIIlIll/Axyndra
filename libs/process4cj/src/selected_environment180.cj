package process4cj

foreign func process4cj_environment_size180(name:CString,length:CPointer<Int64>):Int32
foreign func process4cj_environment_copy180(name:CString,bytes:CPointer<UInt8>,capacity:Int64,copied:CPointer<Int64>):Int32

public func selectedProcessEnvironment180(name:String,fund:(Int64)->Unit):?String {
    if(name.size>(Int64.Max-65536)/4){throw ProcessError(ProcessErrorKind.Io,"selected environment name invoice overflow")}
    fund(65536+name.size*4)
    unsafe {
        let key=LibC.mallocCString(name)
        try{
            let length=LibC.malloc<Int64>()
            try{
                let measured=process4cj_environment_size180(key,length)
                if(measured<0){throw ProcessError(ProcessErrorKind.Io,"selected environment observation failed errno="+(-measured).toString())}
                if(measured==0){return None<String>}
                let size=length.read()
                if(size<0 || size>(Int64.Max-65536)/16){throw ProcessError(ProcessErrorKind.Io,"selected environment value invoice overflow")}
                // Array, bounded copy, UTF8 String and redactor/entry copies
                // stay covered by the actual original Native bank.
                fund(65536+size*16)
                let bytes=Array<Byte>(size,repeat:0)
                let raw=acquireArrayRawData(bytes)
                let copied=try{process4cj_environment_copy180(key,raw.pointer,size,length)}
                    finally{releaseArrayRawData(raw)}
                if(copied<0){throw ProcessError(ProcessErrorKind.Io,"selected environment bounded copy failed errno="+(-copied).toString())}
                if(copied==0){return None<String>}
                let actual=length.read()
                if(actual<0 || actual>size){throw ProcessError(ProcessErrorKind.Io,"selected environment copy extent is invalid")}
                Some(String.fromUtf8(bytes[..actual]))
            }finally{LibC.free(length)}
        }finally{LibC.free(key)}
    }
}
