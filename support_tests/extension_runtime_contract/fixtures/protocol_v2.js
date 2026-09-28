'use strict';

function send(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

function sendReady(message, tools) {
  send({
    type: 'ready',
    protocol: message.protocol,
    extension_id: message.extension_id,
    extension_version: message.extension_version,
    generation: message.generation,
    capabilities: message.capabilities,
    tools
  });
}

function sendReply(message, type, fields = {}) {
  send({
    type,
    protocol: message.protocol,
    extension_id: message.extension_id,
    extension_version: message.extension_version,
    generation: message.generation,
    id: message.id,
    tool: message.tool,
    thread_id: message.thread_id,
    run_id: message.run_id,
    epoch: message.epoch,
    operation_id: message.operation_id,
    call_id: message.call_id,
    ...fields
  });
}

module.exports = { sendReady, sendReply };
