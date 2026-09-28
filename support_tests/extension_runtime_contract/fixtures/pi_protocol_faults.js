'use strict';

const readline = require('node:readline');
const protocol = require('./protocol_v2.js');
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const tools = [
  { name: 'echo', description: 'protocol fault fixture', input_schema: { type: 'object' } }
];
let mode = '';

input.on('line', line => {
  const message = JSON.parse(line);
  if (message.type === 'hello') {
    mode = message.extension_id.slice(message.extension_id.lastIndexOf('.') + 1);
    protocol.sendReady(message, tools);
    return;
  }
  if (message.type === 'close') {
    process.exit(0);
    return;
  }
  if (message.type === 'cancel') {
    if (mode !== 'ignore_cancel') protocol.sendReply(message, 'cancelled');
    return;
  }
  if (message.type !== 'invoke') return;
  if (mode === 'disconnect') {
    process.exit(0);
    return;
  }
  if (mode === 'ignore_cancel') return;
  if (mode === 'stderr_flood') process.stderr.write('x'.repeat(131072));
  if (mode === 'progress_wrong_id') {
    protocol.sendReply(message, 'progress', { id: 'stale-invocation', progress: { step: 1 } });
    return;
  }
  if (mode === 'progress_flood') {
    for (let i = 0; i < 129; i++) protocol.sendReply(message, 'progress', { progress: { step: i } });
    return;
  }
  const mismatch = {
    wrong_protocol: { protocol: 'foreign-protocol' },
    wrong_extension_id: { extension_id: 'foreign-extension' },
    wrong_extension_version: { extension_version: '9.9.9' },
    wrong_generation: { generation: 999 },
    wrong_invocation_id: { id: 'invoke-old' },
    wrong_tool: { tool: 'foreign-tool' },
    wrong_thread_id: { thread_id: 'foreign-thread' },
    wrong_run_id: { run_id: 'foreign-run' },
    wrong_epoch: { epoch: 999 },
    wrong_operation_id: { operation_id: 'foreign-operation' },
    wrong_call_id: { call_id: 'foreign-call' }
  }[mode];
  const fields = { ok: true, result: { mode, arguments: message.arguments }, ...(mismatch || {}) };
  protocol.sendReply(message, 'result', fields);
  if (mode === 'duplicate_result') protocol.sendReply(message, 'result', fields);
  if (mode === 'late_service') {
    setTimeout(() => protocol.sendReply(message, 'service_request', {
      request_id: 'late-side-effect',
      service: 'exec',
      arguments: { tool: 'write', arguments: { path: 'late.txt', content: 'denied' } }
    }), 20);
  }
});
