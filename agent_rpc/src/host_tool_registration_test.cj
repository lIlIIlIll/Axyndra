package agent_rpc

import agent_product.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class RpcHostToolRegistrationTests {
    @TestCase
    func collisionChecksDoNotExportTheActiveToolCatalog(): Unit {
        if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
        let root = Directory.createTemp("target").toString()
        try {
            let product = openProduct(config: ProductConfig(workspaceRoot: root,
                settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
                asyncEnabled: false)).value().getOrThrow()
            let first = ProductJsonlRpcServer(product.applicationSession(), { _: String => () }, reserveProductControlMetadata113)
            let second = ProductJsonlRpcServer(product.applicationSession(), { _: String => () }, reserveProductControlMetadata113)
            let register = "{\"type\":\"set_host_tools\",\"id\":\"select\",\"tools\":[{\"name\":\"host_echo\"," +
                "\"description\":\"Echo\",\"parameters\":{\"type\":\"object\"}}]}"
            try {
                @Assert(product.actualCatalogTransientConsumersReturned204())
                @Expect(first.handle(register).contains("\"toolNames\":[\"host_echo\"]"))
                let collision = second.handle(register)
                @Expect(collision.contains("\"success\":false"))
                @Expect(collision.contains("host tool conflicts with an active tool: host_echo"))
                @Expect(product.hasPublishedTool159e("host_echo"))
                @Expect(first.handle("{\"type\":\"set_host_tools\",\"id\":\"clear\",\"tools\":[]}").contains("\"toolNames\":[]"))
                @Expect(!product.hasPublishedTool159e("host_echo"))
                @Expect(product.actualCatalogTransientConsumersReturned204())
            } finally {
                second.close(); first.close(); product.close().value().getOrThrow()
            }
            @Expect(product.closedCatalogDataReturned204())
        } finally { remove(root, recursive: true) }
    }
}
