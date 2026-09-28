'use strict';

const readline = require('node:readline');
const protocol = require('./protocol_v2.js');
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  const message = JSON.parse(line);
  if (message.type === 'hello') {
    protocol.sendReady(message, [
      { name: 'silent', description: 'silent', input_schema: { type: 'object' } }
    ]);
  } else if (message.type === 'cancel') {
    protocol.sendReply(message, 'cancelled');
  } else if (message.type === 'close') {
    process.exit(0);
  }
});
