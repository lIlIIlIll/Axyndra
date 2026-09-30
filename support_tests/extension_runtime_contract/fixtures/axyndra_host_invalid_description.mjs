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
      tools: [
        { name: 'bad-description', description: 42, input_schema: { type: 'object' } }
      ]
    }) + '\n');
  } else if (message.type === 'close') {
    process.exit(0);
  }
});
