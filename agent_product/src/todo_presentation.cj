package agent_product

import agent_cli.*

import std.deriving.*

@Derive[Equatable]
public enum ProductTodoStatus {
    Pending | InProgress | Completed | Abandoned | Blocked
}

public class ProductTodoItem {
    public let content: String
    public let status: ProductTodoStatus
    public let blocker: String

    public init(
        content: String,
        status!: ProductTodoStatus = ProductTodoStatus.Pending,
        blocker!: String = ""
    ) {
        if (content.trimAscii() == "") {
            throw IllegalArgumentException("todo item content must not be empty")
        }
        this.content = content
        this.status = status
        this.blocker = blocker
    }
}

public class ProductTodoPhase {
    public let name: String
    public let tasks: Array<ProductTodoItem>

    public init(name: String, tasks: Array<ProductTodoItem>) {
        if (name.trimAscii() == "") {
            throw IllegalArgumentException("todo phase name must not be empty")
        }
        this.name = name
        this.tasks = tasks
    }
}


// Read-only UI rendering. Native remains the sole parser, normalizer and writer.
// This does not update the editor digest or create a Tool/Run/approval.
func productTodoDisplayMarkdown(phases:Array<ProductTodoPhase>):String {
    if(phases.isEmpty()){return "# Todos\n"}
    var text=""
    for(index in 0..phases.size){
        if(index>0){text+="\n"}
        text+="# "+phases[index].name+"\n"
        for(task in phases[index].tasks){
            let marker=match(task.status){
                case ProductTodoStatus.Pending=>" "
                case ProductTodoStatus.InProgress=>"/"
                case ProductTodoStatus.Completed=>"x"
                case ProductTodoStatus.Abandoned=>"-"
                case ProductTodoStatus.Blocked=>"!"}
            text+="- ["+marker+"] "+task.content
            if(task.status==ProductTodoStatus.Blocked && task.blocker.trimAscii()!=""){
                text+=" <!-- blocker: "+task.blocker.replace("-->","-- >").replace("\r"," ").replace("\n"," ").trimAscii()+" -->"}
            text+="\n"}}
    text
}

func productTodoSlashDefinition():SlashCommandDefinition {
SlashCommandDefinition(
            "todo",
            "Work modes",
            "Manage the session todo list",
            usage: "/todo [subcommand]",
            subcommands: [
                "edit",
                "copy",
                "export",
                "import",
                "append",
                "start",
                "done",
                "drop",
                "rm",
                "help",
                "?"
            ],
            pathArgumentPrefixes: [["export"], ["import"]]
        )
}
