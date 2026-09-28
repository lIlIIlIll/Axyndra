import readline from 'node:readline';

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  const message = JSON.parse(line);
  if (message.type === 'hello') {
    process.stdout.write(JSON.stringify({
      type: 'ready',
      protocol: message.protocol,
      extension_id: message.extension_id,
      extension_version: message.extension_version,
      generation: message.generation,
      capabilities: message.capabilities,
      tools: [{ name: 'echo', description: 'Echo a JSON value.', input_schema: { type: 'object' } }]
    }) + '\n');
  } else if (message.type === 'invoke') {
    process.stdout.write(JSON.stringify({
      type: 'register_tool',
      protocol: message.protocol,
      extension_id: message.extension_id,
      extension_version: message.extension_version,
      generation: message.generation,
      id: message.id,
      tool: message.tool,
      thread_id: message.thread_id,
      run_id: message.run_id,
      epoch: message.epoch,
      operation_id: message.operation_id,
      call_id: message.call_id,
      descriptor: { name: 'late-tool', description: 'Not part of the frozen Run tool set.', input_schema: { type: 'object' } }
    }) + '\n');
  } else if (message.type === 'close') {
    process.exit(0);
  }
});
