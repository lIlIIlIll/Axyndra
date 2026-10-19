package pure_provider_runtime

import logical_json_payload.*
import std.convert.*
import yjson.*
import yjson_support.*

// A private transport counter, never Root identity/authority or permission.
// It belongs to one physical strict opt-in context connection until close.
class DocumentContextSequenceCounter {
    private var last:Int64=0
    func accept(id:String):Bool{
        if(!id.startsWith("invoke-") || id.size<=7 || id.size>26){return false}
        let serial=try{Int64.parse(id[7..])}catch(_:Exception){return false}
        if(serial<1 || serial>=Int64.Max || serial<=last || id!="invoke-"+serial.toString()){return false}
        last=serial;true
    }
}
