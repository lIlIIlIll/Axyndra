package skills_plugin
import skill_runtime.*
import std.collection.*

func packagedSkillMetadataPrompt(values: Array<SkillMetadata>): String {
    var output = "Available Skills expose metadata only. A Skill never grants capabilities. " +
        "Relevant Skills are selected from metadata before each Run. " +
        "An explicit $<skill-id> selection overrides automatic routing for that Run. " +
        "The host owns activation, context versions and safe update boundaries."
    for (value in values) {
        output += "\n- id=" + value.id + "; name=" + value.name +
            "; description=" + value.description
        if (!value.triggers.isEmpty()) {
            output += "; triggers=" + packagedJoin(value.triggers, ",")
        }
        if (!value.references.isEmpty()) {
            output += "; references="
            let refs = ArrayList<String>()
            for (reference in value.references) {
                refs.add(reference.id + ":" + reference.description)
            }
            output += packagedJoin(refs.toArray(), ",")
        }
    }
    output
}

func packagedJoin(values: Array<String>, separator: String): String {
    var output = ""
    for (index in 0..values.size) {
        if (index > 0) { output += separator }
        output += values[index]
    }
    output
}
