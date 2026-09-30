'use strict';

const readline = require('node:readline');
const protocol = require('./protocol_v2.js');
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  const message = JSON.parse(line);
  if (message.type === 'hello') {
    protocol.sendReady(message, [
      { name: 'echo', description: 'echo', input_schema: { type: 'object' } }
    ]);
  } else if (message.type === 'invoke') {
    process.stdout.write('protocol noise\n');
  }
});
