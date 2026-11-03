package memory_plugin

import agent_domain.*

// Exactly the existing KMP transitions; the admitted content-message maximum
// is far below UInt32.Max and all prefix values are nonnegative <pattern.size.
// One cached table is live. Replacing it drops the old array before allocating
// the next one; private slots only deduplicate equal authorized query patterns.
class MemoryStreamCompactKmp {
    private var slot:Int64= -1
    private var prefix:Array<UInt32>=[]
    func close():Unit{prefix=[];slot= -1}
    func advance(identity:Int64,pattern:String,text:String,matched:Int64,found:Bool):(Int64,Bool){
        let needle=unsafe{pattern.rawData()};let bytes=unsafe{text.rawData()}
        if(identity<0 || needle.isEmpty() || needle.size>CONTENT_PAYLOAD_MESSAGE_BYTES ||
            needle.size>4294967295 || matched<0 || matched>=needle.size){memoryFragmentError()}
        if(found){return (matched,true)}
        if(slot!=identity){
            close();prefix=Array<UInt32>(needle.size,repeat:0);var previous:Int64=0
            for(index in 1..needle.size){
                while(previous>0 && needle[index]!=needle[previous]){previous=Int64(prefix[previous-1])}
                if(needle[index]==needle[previous]){previous++};prefix[index]=UInt32(previous)
            }
            slot=identity
        }
        if(prefix.size!=needle.size){memoryFragmentError()}
        var current=matched
        for(raw in bytes){
            let byte=if(raw>=b'A' && raw<=b'Z'){raw+32}else{raw}
            while(current>0 && byte!=needle[current]){current=Int64(prefix[current-1])}
            if(byte==needle[current]){current++}
            if(current==needle.size){return (Int64(prefix[current-1]),true)}
        }
        (current,false)
    }
}
