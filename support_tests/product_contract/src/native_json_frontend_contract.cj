package product_contract

import agent_domain.*
import agent_product.*
import shell_native_contract.*
import std.fs.*
import yjson.*
import yjson_support.*

// Exercise the public selected frontend and the original Native bridge. These
// calls use installed packages, operator configuration and canonical startup;
// no test-created ToolResult, Source, admission or receipt substitutes for them.
func runNativeJsonFrontendContract204(root: String): Unit {
    let scope = NativeShellContractScope(root)
    try {
        let binding = scope.binding()
        let thread = SessionId("native-json-frontend")
        binding.start(thread)
        for (mode in ["default", "seconds", "milliseconds"]) {
            let input = objectValue([ValueField("command", textValue("printf 'json-雪'"))])
            if (mode == "seconds") { input.put("timeout", integerValue(1)) }
            if (mode == "milliseconds") { input.put("timeout_ms", integerValue(1000)) }
            let before = encodeAgentValue(input)
            let acquired = if (mode == "default") {
                binding.product.invokeShellTool(thread, input).value().getOrThrow()
            } else { binding.invoke(thread, input) }
            let output = binding.observe(thread, acquired)
            expect(!output.isError && output.status == "complete", "actual selected JSON command completes")
            expect(output.output.field("stdout").getOrThrow().text == "json-雪", "complete original UTF8 output survives bridge copying")
            expect(output.output.field("exit_code").getOrThrow().asNumberText() == "0", "actual backend exits successfully")
            expect(output.receiptId != "", "actual command owns its canonical receipt")
            expect(encodeAgentValue(input) == before, "default timeout freezing leaves caller arguments unchanged")
        }
        let beforeRejected = binding.count("SELECT COUNT(*) FROM operations")
        let rejectedArguments = [
            objectValue([ValueField("command", textValue("printf forbidden > rejected.txt")),
                ValueField("timeout", integerValue(1)), ValueField("timeout_ms", integerValue(1000))]),
            objectValue([ValueField("command", textValue("printf forbidden > rejected.txt")),
                ValueField("timeout", textValue("1"))]),
            objectValue([ValueField("command", textValue("printf forbidden > rejected.txt")),
                ValueField("timeout", integerValue(0))])
        ]
        let expectedCodes = ["shell.timeout_invalid", "shell.timeout_invalid", "shell.timeout_exceeds_service"]
        for (index in 0..rejectedArguments.size) {
            let rejected = binding.product.invokeShellTool(thread, rejectedArguments[index])
            expect(rejected.isError(), "conflicting, wrong-type and over-profile timeouts remain refused")
            let code = rejected.error().getOrThrow().code
            expect(code == expectedCodes[index], "original exact typed timeout refusal survives")
            expect(binding.count("SELECT COUNT(*) FROM operations") == beforeRejected, "argument rejection cannot create another canonical root")
            expect(!exists(root + "/rejected.txt"), "argument rejection has no process effect")
        }
        expect(binding.count("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") == 7,
            "one original startup and three actual root/child pairs complete")
    } finally { scope.close() }
}
