'use strict';

const fs = require('node:fs');
const childProcess = require('node:child_process');
const net = require('node:net');
const readline = require('node:readline');
const protocol = require('./protocol_v2.js');
const VERSION = 'pi-fixed-v1';

function send(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

async function permissionProbe() {
  let filesystemDenied = false;
  let processDenied = false;
  try {
    fs.readFileSync('/etc/passwd', 'utf8');
  } catch (error) {
    filesystemDenied = error && (error.code === 'ERR_ACCESS_DENIED' || String(error.message).includes('permission'));
  }
  try {
    childProcess.execFileSync('/bin/echo', ['blocked'], { encoding: 'utf8' });
  } catch (error) {
    processDenied = error && (error.code === 'ERR_ACCESS_DENIED' || String(error.message).includes('permission'));
  }
  const networkDenied = await new Promise(resolve => {
    const server = net.createServer();
    process.once('uncaughtException', error => {
      resolve(error && (error.code === 'ERR_ACCESS_DENIED' || String(error.message).includes('permission')));
    });
    server.once('error', error => {
      resolve(error && (error.code === 'ERR_ACCESS_DENIED' || String(error.message).includes('permission')));
    });
    server.listen(0, '127.0.0.1', () => {
      server.close(() => resolve(false));
    });
  });
  return {
    filesystemDenied: Boolean(filesystemDenied),
    processDenied: Boolean(processDenied),
    networkDenied: Boolean(networkDenied)
  };
}

function invoke(message) {
  const args = message.arguments || {};
  if (message.tool === 'delayed') {
    protocol.sendReply(message, 'progress', { progress: { stage: 'waiting', version: VERSION } });
    setTimeout(() => protocol.sendReply(message, 'result', {
      ok: true,
      result: { version: VERSION, delayed: true }
    }), 5000);
    return;
  }
  if (message.tool === 'probe') {
    permissionProbe().then(result => {
      protocol.sendReply(message, 'result', { ok: true, result });
    });
    return;
  }
  if (message.tool === 'echo') {
    protocol.sendReply(message, 'progress', { progress: { stage: 'echoing', version: VERSION } });
    protocol.sendReply(message, 'result', {
      ok: true,
      result: { version: VERSION, value: args.value === undefined ? null : args.value }
    });
    return;
  }
  protocol.sendReply(message, 'result', { ok: false, result: { code: 'unknown_tool' } });
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  let message;
  try {
    message = JSON.parse(line);
  } catch (error) {
    send({ type: 'fatal', error: 'invalid_json' });
    process.exitCode = 2;
    return;
  }
  if (message.type === 'hello') {
    protocol.sendReady(message, [
      { name: 'echo', description: 'Echo a JSON value.', input_schema: { type: 'object' } },
      { name: 'probe', description: 'Report denied ambient operations.', input_schema: { type: 'object' } },
      { name: 'delayed', description: 'Wait for cancellation.', input_schema: { type: 'object' } }
    ]);
    return;
  }
  if (message.type === 'invoke') invoke(message);
  if (message.type === 'cancel') protocol.sendReply(message, 'cancelled');
  if (message.type === 'close') process.exit(0);
});
