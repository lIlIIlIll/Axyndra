package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// Pure file-change decisions. These bytes never call File, Directory,
// Process or a Store; the generic actual Workspace executor is their consumer.
class NativeManagedSkillProposals {
    private let existing: Array<String>
    private let proposals = ArrayList<AgentValue>()
    init(existing: Array<String>) { this.existing = existing.clone() }
    func changes(): Array<AgentValue> { proposals.toArray() }
    func write(action: String, name: String, description: String, body: String): Result<String> {
        let present=existing.contains(name)
        if (action=="create" && present) { return memoryPersistenceError<String>("skill.already_exists",
            "Managed skill \""+name+"\" already exists. Use action \"update\" to change it.") }
        if (action=="update" && !present) { return memoryPersistenceError<String>("skill.not_found",
            "Managed skill \""+name+"\" does not exist. Use action \"create\" to add it.") }
        let content="---\nname: "+name+"\ndescription: "+quoteYaml(description)+"\n---\n\n"+body.trimAscii()+"\n"
        if(content.size>64000){return memoryPersistenceError<String>("skill.too_large","Managed skill exceeds the 64000 byte limit.")}
        let path="managed-skills/"+name+"/SKILL.md"
        proposals.add(objectValue([ValueField("path",textValue(path)),ValueField("mode",textValue(if(present){"replace"}else{"create"})),
            ValueField("content",textValue(content))])); Result.Ok(path)
    }
    func delete(name: String): Result<Unit> {
        if(!existing.contains(name)){return memoryPersistenceError<Unit>("skill.not_found","Managed skill \""+name+"\" does not exist.")}
        proposals.add(objectValue([ValueField("path",textValue("managed-skills/"+name)),ValueField("mode",textValue("delete_tree")),
            ValueField("content",nullValue())])); Result.Ok(())
    }
}
func memoryPersistenceError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput,code,message))
}
func quoteYaml(value: String): String {
    "\"" + value.replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", " ")
        .replace("\r", " ") + "\""
}
