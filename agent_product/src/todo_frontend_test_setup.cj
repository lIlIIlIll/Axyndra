package agent_product

import agent_domain.*
import agent_plugin_registry.*
import std.env.*
import std.fs.*
import yjson.*
import yjson_support.*

func todoTestInstallNative(product: ProductRuntime): ProductPluginRecord {
    let record=match(product.importLocalPlugin(getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow())){
        case PluginRegistryResult.Ok(value)=>value
        case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}
    let directory=product.settingsRoot+"/plugins"
    if(!exists(Path(directory))){Directory.create(directory,recursive:true)}
    File.writeTo(directory+"/todo-tools.json",stringifyUnifiedJson(objectValue([
        ValueField("schema",textValue("axyndra.todo-tools/v1")),ValueField("namespace",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),
        ValueField("package_digest",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),ValueField("tool",textValue("todo")),ValueField("command",textValue("todo"))])).toArray())
    File.writeTo(directory+"/documents.json",stringifyUnifiedJson(objectValue([
        ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
            ValueField("namespace",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),ValueField("package_digest",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
            ValueField("tools",listValue([objectValue([ValueField("name",textValue("todo")),ValueField("preparation_provider",textValue("prepare_document")),
                ValueField("documents",listValue([objectValue([ValueField("key",textValue("todo")),ValueField("read",boolValue(true)),ValueField("write",boolValue(true))])]))])]))])]))])).toArray())
    match(product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)),true)){
        case PluginRegistryResult.Ok(enabled)=>enabled.close();case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}
    record
}
