package provider_driver

import agent_core.*
import agent_domain.*
import agent_product.*
import std.env.*
import tool_runtime.*

main(): Int64 {
    let arguments = getCommandLine()
    if (arguments.size != 2) {
        println("usage: provider_driver cancel|timeout|concurrency")
        return 2
    }
    let command = arguments[1]
    let product = match (openProduct(config: ProductConfig(
        workspaceRoot: ".",
        approvalMode: ApprovalMode.Yolo,
        modelAttemptRecovery: if (command == "timeout") {
            ModelAttemptRecoveryPolicy(
                mode: ModelAttemptRecoveryMode.Disabled,
                maxRecoveryRetries: 0
            )
        } else { ModelAttemptRecoveryPolicy() },
        modelStreamFaultProfile: if (command == "timeout") {
            Some(ModelStreamFaultProfile(
                "ProviderDriverTimeoutV1",
                faultDelayMillis: 100
            ))
        } else { None }
    ))) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    match (command) {
        case "cancel" => cancelSmoke(product)
        case "timeout" => timeoutSmoke(product)
        case "concurrency" => concurrencySmoke(product)
        case _ =>
            println("usage: provider_driver cancel|timeout|concurrency")
            2
    }
}

func cancelSmoke(product: ProductRuntime): Int64 {
    let request = product.request("cancel-smoke")
    let future = spawn {
        product.client.start(request, { _ => () })
    }
    sleep(Duration.millisecond * 20)
    match (product.client.cancel(request.runId)) {
        case Result.Ok(_) => ()
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    match (future.get()) {
        case Result.Err(error) => match (error.kind) {
            case AgentErrorKind.Cancelled =>
                println("cancel smoke passed")
                0
            case _ =>
                printError(error)
                1
        }
        case Result.Ok(_) =>
            println("cancel smoke failed: request completed")
            1
    }
}

func timeoutSmoke(product: ProductRuntime): Int64 {
    match (product.client.start(
        product.request("timeout-smoke"),
        { _ => () }
    )) {
        case Result.Err(error) => match (error.kind) {
            case AgentErrorKind.Timeout =>
                println("timeout smoke passed")
                0
            case _ =>
                printError(error)
                1
        }
        case Result.Ok(_) =>
            println("timeout smoke failed: request completed")
            1
    }
}

func concurrencySmoke(product: ProductRuntime): Int64 {
    let first = product.request(
        "Reply with exactly concurrency-one. Do not call tools."
    )
    let second = product.request(
        "Reply with exactly concurrency-two. Do not call tools."
    )
    let one = spawn {
        product.client.start(first, { _ => () })
    }
    let two = spawn {
        product.client.start(second, { _ => () })
    }
    let firstOk = completed("concurrency-one", one.get())
    let secondOk = completed("concurrency-two", two.get())
    if (firstOk && secondOk) {
        println("concurrency smoke passed")
        0
    } else {
        println("concurrency smoke failed")
        1
    }
}

func completed(
    label: String,
    result: Result<AgentRunOutcome>
): Bool {
    match (result) {
        case Result.Ok(AgentRunOutcome.Completed(_)) => true
        case Result.Ok(AgentRunOutcome.AwaitingApproval(_, _)) =>
            println(label + " unexpectedly requested approval")
            false
        case Result.Err(error) =>
            println(label + " failed: " + error.code + ": " + error.message)
            false
    }
}

func printError(error: AgentError): Unit {
    println(error.code + ": " + error.message)
}
