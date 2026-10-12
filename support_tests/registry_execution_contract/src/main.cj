package registry_execution_contract

import agent_plugin_registry.*
import std.env.*
import std.fs.*
import std.time.*

// The actual installed record/pin exist before READY. The Python process then
// commits a different real registry mutation; no source/grant is simulated.
main():Int64 {
    let args=getCommandLine();if(args.size!=6){return 64}
    let registry=PluginRegistry(args[1],args[2])
    try{
    if(args[4]=="enable"){
        match(registry.setEnabled(args[5],true)){
            case PluginRegistryResult.Ok(value)=>value.close();println("OK");return 0
            case PluginRegistryResult.Err(error)=>try{println(error.code);return 2}finally{error.close()}}}
    let record=match(registry.get(args[5])){case Some(value)=>value;case None=>return 66}
    var pin:?PluginRegistryExecutionPin=None;var fence:?PluginRegistryExecutionFence=None
    try{
        if(args[4]!="capture"){
            let actual=match(registry.captureExecutionPin(record)){
                case PluginRegistryResult.Ok(value)=>value;case PluginRegistryResult.Err(error)=>try{println(error.code);return 2}finally{error.close()}}
            pin=Some(actual)
            if(args[4]=="hold"){fence=match(actual.enter()){
                case PluginImportResult.Ok(value)=>Some(value);case PluginImportResult.Err(error)=>println(error.code);return 2}}
        }
        File.writeTo(args[3]+".ready","ready".toArray())
        let started=MonoTime.now()
        while(!exists(Path(args[3]+".go"))){
            if(MonoTime.now()-started>Duration.second*20){return 65};sleep(Duration.millisecond*5)}
        if(args[4]=="capture"){
            match(registry.captureExecutionPin(record)){
                case PluginRegistryResult.Ok(value)=>value.close();println("OK");0
                case PluginRegistryResult.Err(error)=>try{println(error.code);2}finally{error.close()}}
        }else{match(pin.getOrThrow().current()){
            case PluginImportResult.Ok(_)=>println("OK");0
            case PluginImportResult.Err(error)=>println(error.code);2}}
    }finally{match(fence){case Some(value)=>value.close();case None=>()}
        match(pin){case Some(value)=>value.close();case None=>()};record.close()}
    }finally{registry.close()}
}
