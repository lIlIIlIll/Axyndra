'use strict';

function send(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

function envelope(type, message, fields = {}) {
  return {
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
  };
}

function sendReady(message) {
  send({
    type: 'ready',
    protocol: message.protocol,
    extension_id: message.extension_id,
    extension_version: message.extension_version,
    generation: message.generation,
    capabilities: message.capabilities,
    tools: [{ name: 'service', input_schema: { type: 'object' } }]
  });
}

process.stdin.setEncoding('utf8');
let buffer = '';
process.stdin.on('data', chunk => {
  buffer += chunk;
  for (;;) {
    const end = buffer.indexOf('\n');
    if (end < 0) return;
    const message = JSON.parse(buffer.slice(0, end));
    buffer = buffer.slice(end + 1);
    if (message.type === 'hello') {
      sendReady(message);
    } else if (message.type === 'invoke') {
      send(envelope('progress', message, { progress: { phase: 'calling-service' } }));
      if (message.arguments.mode === 'flood') {
        for (let index = 0; index < 33; index++) {
          send(envelope('service_request', message, {
            request_id: 'flood-' + index,
            service: 'exec',
            arguments: { command: 'printf bounded' }
          }));
        }
        return;
      }
      send(envelope('service_request', message, {
        request_id: 'service-1',
        service: 'exec',
        arguments: { command: 'printf controlled' }
      }));
    } else if (message.type === 'service_response') {
      send(envelope('result', message, {
        ok: message.ok,
        result: {
          request_id: message.request_id,
          service_result: message.result,
          service_error: message.error
        }
      }));
    } else if (message.type === 'cancel') {
      send(envelope('cancelled', message));
    } else if (message.type === 'close') {
      process.exit(0);
    }
  }
});