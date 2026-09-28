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
        { name: 'alpha', description: 'A valid earlier candidate.', input_schema: { type: 'object' } },
        { name: 'beta', description: 'An invalid later candidate.', input_schema: 'not-an-object' }
      ]
    }) + '\n');
  } else if (message.type === 'close') {
    process.exit(0);
  }
});
