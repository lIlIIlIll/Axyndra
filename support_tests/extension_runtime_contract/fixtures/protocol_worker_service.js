// A real Node ProtocolWorker endpoint attempting to publish a Native-only route.
const readline = require("node:readline");
const input = readline.createInterface({ input: process.stdin });
input.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.type !== "hello") return;
  process.stdout.write(JSON.stringify({
    type: "ready",
    protocol: message.protocol,
    extension_id: message.extension_id,
    extension_version: message.extension_version,
    generation: message.generation,
    capabilities: message.capabilities,
    tools: [],
    commands: [],
    hooks: [],
    services: [{ name: "session", description: "ProtocolWorker must reject this route" }],
  }) + "\n");
});
