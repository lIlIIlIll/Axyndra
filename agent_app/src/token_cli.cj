package agent_app

import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*

func runTokenCli(
    product: ProductRuntime,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") ||
        hasArgument(arguments, "-h")) {
        println(
            "axyndra token <provider-profile> [--raw] " +
            "[--force-refresh] [-a|--account <n>] [-l|--list]"
        )
        return 0
    }
    let positional = tokenPositionals(arguments)
    if (positional.size != 1) {
        println(
            "Usage: axyndra token <provider-profile> [--raw] " +
            "[--force-refresh] [-a|--account <n>] [-l|--list]"
        )
        return 1
    }
    let unknown = unknownTokenOption(arguments)
    if (unknown != "") {
        println("Error: unknown token option: " + unknown)
        return 2
    }
    let missingValue = missingTokenOptionValue(arguments)
    if (missingValue != "") {
        println("Error: " + missingValue + " requires an account value")
        return 2
    }
    let account = argumentValue(arguments, "--account")
    let shortAccount = argumentValue(arguments, "-a")
    if (hasArgument(arguments, "--list") ||
        hasArgument(arguments, "-l") ||
        account != "" || shortAccount != "") {
        println(
            "Error: no OAuth accounts found for provider profile \"" +
            positional[0] + "\". API-key profiles do not have " +
            "selectable accounts."
        )
        return 1
    }
    let credential = match (product.credential(
        profileId: positional[0]
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            println(error.code + ": " + error.message)
            return 1
    }
    if (!hasArgument(arguments, "--raw")) {
        match (decodeAgentValue(credential)) {
            case Result.Ok(value) =>
                match (value.field("token")) {
                    case Some(token) =>
                        if (token.kind == ValueKind.Text &&
                            token.text != "") {
                            println(token.text)
                            return 0
                        }
                    case None => ()
                }
            case Result.Err(_) => ()
        }
    }
    println(credential)
    0
}

func tokenPositionals(arguments: Array<String>): Array<String> {
    let values = ArrayList<String>()
    var skipNext = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--account" || argument == "-a") {
            skipNext = true
            continue
        }
        if (!argument.startsWith("-")) { values.add(argument) }
    }
    values.toArray()
}

func unknownTokenOption(arguments: Array<String>): String {
    var skipNext = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--account" || argument == "-a") {
            skipNext = true
            continue
        }
        if (argument == "--raw" ||
            argument == "--force-refresh" ||
            argument == "--list" ||
            argument == "-l" ||
            argument == "--help" ||
            argument == "-h") {
            continue
        }
        if (argument.startsWith("-")) { return argument }
    }
    ""
}

func missingTokenOptionValue(arguments: Array<String>): String {
    var index: Int64 = 0
    while (index < arguments.size) {
        let argument = arguments[index]
        if (argument == "--account" || argument == "-a") {
            if (index + 1 >= arguments.size ||
                arguments[index + 1].startsWith("-")) {
                return argument
            }
            index += 2
            continue
        }
        index += 1
    }
    ""
}
