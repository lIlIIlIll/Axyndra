'use strict';

const readline = require('node:readline');
const protocol = require('./protocol_v2.js');
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  const message = JSON.parse(line);
  if (message.type === 'hello') {
    protocol.sendReady(message, [
      { name: 'same', description: 'first', input_schema: { type: 'object' } },
      { name: 'same', description: 'second', input_schema: { type: 'object' } }
    ]);
  }
});
