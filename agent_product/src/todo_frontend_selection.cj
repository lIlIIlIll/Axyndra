package agent_product

import agent_domain.*
import agent_extension_runtime.{PluginEntryKind}
import agent_plugin_registry.*
import agent_sdk.*
import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

// Describes one operator-selected installed command. No Source, document
// permission, Runtime, database or write callback is exposed to a plugin.
class ProductTodoSelection {
    let runtime: ProductRuntime
    let session: SessionId
    let configurationDigest: String
    let namespace: String
    let packageDigest: String
    let generation: UInt64
    let tool: String
    let route: String
    let implementationVersion: String
    let implementationFingerprint: String
    init(runtime: ProductRuntime, session: SessionId, config: String, namespace: String,
        digest: String, generation: UInt64, tool: String, route: String, version: String, fingerprint: String) {
        this.runtime=runtime;this.session=session;configurationDigest=modelPolicySha256Text(config)
        this.namespace=namespace;packageDigest=digest;this.generation=generation;this.tool=tool;this.route=route
        implementationVersion=version;implementationFingerprint=fingerprint
    }
    func current(): Result<Unit> {
        let encoded=match(productTodoSelectionText(runtime.settingsRoot)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(modelPolicySha256Text(encoded)!=configurationDigest){return productTodoFrontendError("todo.selection_changed")}
        let descriptor=match(runtime.vnext.javascriptPlugins.servicePackage(namespace,generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try{
        let published=match(runtime.vnext.publishedToolIdentity(tool,threadId:Some(ThreadId(session.value)))){
            case None=>return productTodoFrontendError("todo.component_unprovided");case Some(value)=>value}
        let actualVersion=match(runtime.vnext.javascriptPlugins.instanceExecutorVersion(namespace,generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(descriptor.entryKind!=PluginEntryKind.NativeExecutable || !descriptor.textEquals(PluginDescriptorText.ContentDigest,packageDigest) ||
            actualVersion!=implementationVersion ||
            published.implementationVersion!=implementationVersion || published.implementationFingerprint!=implementationFingerprint){
            return productTodoFrontendError("todo.selection_changed")}
        var commandCurrent=false
        for(command in runtime.javascriptPluginCommands() where command.routeName==route && command.instanceGeneration==generation){commandCurrent=true}
        if(!commandCurrent){return productTodoFrontendError("todo.component_unprovided")}
        let configuration=match(runtime.vnext.javascriptPlugins.documentConfiguration(namespace,packageDigest)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(!configuration.permits("todo","todo",false)){
            return productTodoFrontendError("todo.document_read_unprovided")}
        Result.Ok(())
        }finally{descriptor.close()}
    }
}

func productTodoSelectionText(settingsRoot: String): Result<String> {
    try{
        let root=canonicalize(Path(settingsRoot));let directory=root.join("plugins");let path=directory.join("todo-tools.json")
        if(!exists(directory) || !exists(path)){return productTodoFrontendError("todo.selection_unprovided")}
        let info=FileInfo(path)
        if(FileInfo(directory).isSymbolicLink() || info.isSymbolicLink() || !info.isRegular() || info.size>16384 ||
            canonicalize(path).toString()!=root.join("plugins/todo-tools.json").toString()){
            return productTodoFrontendError("todo.selection_invalid")}
        let file=File(path,OpenMode.Read);let bytes=ArrayList<UInt8>();let buffer=Array<UInt8>(4096,repeat:0)
        try{while(true){let count=file.read(buffer);if(count==0){break}
            if(count<0 || count>buffer.size || bytes.size+count>16384){return productTodoFrontendError("todo.selection_invalid")}
            bytes.add(all:buffer[..count])}}
        finally{file.close()}
        Result.Ok(String.fromUtf8(bytes.toArray()))
    }catch(_:Exception){productTodoFrontendError("todo.selection_unprovided")}
}

func selectProductTodo(runtime: ProductRuntime, session: SessionId): Result<ProductTodoSelection> {
    let encoded=match(productTodoSelectionText(runtime.settingsRoot)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    try{
        let config=parseUnifiedJson(encoded,maxBytes:16384,maxDepth:8)
        if(!httpIntentExactFields(config,["schema","namespace","package_digest","tool","command"]) ||
            httpIntentText(config,"schema")!="axyndra.todo-tools/v1" ||
            !httpServicePluginNamespace(httpIntentText(config,"namespace")) ||
            !httpServicePackageDigest(httpIntentText(config,"package_digest")) ||
            httpIntentText(config,"tool")!="todo" || httpIntentText(config,"command")!="todo"){
            return productTodoFrontendError("todo.selection_invalid")}
        let namespace=httpIntentText(config,"namespace");let digest=httpIntentText(config,"package_digest")
        let enabled=productRegistryHasEnabledRecord139(runtime.pluginSnapshots(),namespace,digest)
        if(!enabled){return productTodoFrontendError("todo.component_unprovided")}
        let generation=runtime.vnext.javascriptPlugins.instanceGeneration(namespace)
        let descriptor=match(runtime.vnext.javascriptPlugins.servicePackage(namespace,generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try{
        if(descriptor.entryKind!=PluginEntryKind.NativeExecutable || !descriptor.textEquals(PluginDescriptorText.ContentDigest,digest) ||
            !descriptor.hasCapability("document.store")){return productTodoFrontendError("todo.selection_invalid")}
        let foundTool=descriptor.hasContribution(PluginContributionKind.Tool,httpIntentText(config,"tool"))
        let foundCommand=descriptor.hasContribution(PluginContributionKind.Command,httpIntentText(config,"command"))
        let name="plugin."+namespace+"."+httpIntentText(config,"tool")
        let published=match(runtime.vnext.publishedToolIdentity(name,threadId:Some(ThreadId(session.value)))){
            case None=>return productTodoFrontendError("todo.component_unprovided");case Some(value)=>value}
        let actualVersion=match(runtime.vnext.javascriptPlugins.instanceExecutorVersion(namespace,generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(!foundTool || !foundCommand || published.implementationVersion!=actualVersion ||
            published.implementationFingerprint!=namespace+":"+digest){
            return productTodoFrontendError("todo.selection_invalid")}
        let selection=ProductTodoSelection(runtime,session,encoded,namespace,digest,generation,name,
            "plugin."+namespace+"."+httpIntentText(config,"command"),published.implementationVersion,published.implementationFingerprint)
        match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(selection)
        }finally{descriptor.close()}
    }catch(_:Exception){productTodoFrontendError("todo.selection_invalid")}
}

func productTodoFrontendError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Configuration,code,
        "Todo requires its current explicitly selected native contribution and actual user-owned document operation"))
}
