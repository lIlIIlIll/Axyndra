'use strict';

const readline = require('node:readline');
const protocol = require('./protocol_v2.js');

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  const message = JSON.parse(line);
  if (message.type === 'hello') {
    protocol.sendReady(message, [
      { name: 'environment', description: 'Report the host environment.', input_schema: { type: 'object' } }
    ]);
    return;
  }
  if (message.type === 'invoke' && message.tool === 'environment') {
    protocol.sendReply(message, 'result', {
      ok: true,
      result: {
        home: process.env.HOME || '',
        path: process.env.PATH || '',
        tmpdir: process.env.TMPDIR || ''
      }
    });
  }
  if (message.type === 'cancel') protocol.sendReply(message, 'cancelled');
  if (message.type === 'close') process.exit(0);
});