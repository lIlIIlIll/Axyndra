'use strict';

const readline = require('node:readline');
const protocol = require('./protocol_v2.js');
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  const message = JSON.parse(line);
  if (message.type !== 'hello') return;
  const mode = message.extension_id.slice(message.extension_id.lastIndexOf('.') + 1);
  const ready = { ...message };
  if (mode === 'protocol') ready.protocol = 'foreign-protocol';
  if (mode === 'extension_id') ready.extension_id = 'foreign-extension';
  if (mode === 'extension_version') ready.extension_version = '9.9.9';
  if (mode === 'generation') ready.generation += 1;
  if (mode === 'capabilities') ready.capabilities = ['workspace.admin'];
  protocol.sendReady(ready, [
    { name: 'echo', description: 'echo', input_schema: { type: 'object' } }
  ]);
});
