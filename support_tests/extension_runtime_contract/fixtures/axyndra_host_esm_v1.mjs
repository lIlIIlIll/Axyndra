import readline from 'node:readline';
import protocol from './protocol_v2.js';

const VERSION = 'axyndra-host-esm-v1';
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  const message = JSON.parse(line);
  if (message.type === 'hello') {
    protocol.sendReady(message, [
      { name: 'echo', description: 'Echo a JSON value from ESM.', input_schema: { type: 'object' } }
    ]);
  } else if (message.type === 'invoke' && message.tool === 'echo') {
    const args = message.arguments || {};
    protocol.sendReply(message, 'result', {
      ok: true,
      result: { version: VERSION, value: args.value === undefined ? null : args.value }
    });
  } else if (message.type === 'close') {
    process.exit(0);
  }
});
