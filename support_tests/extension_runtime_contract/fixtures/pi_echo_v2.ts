'use strict';

type FileApi = {
  readFileSync(path: string, encoding: string): string;
};

type ChildProcessApi = {
  execFileSync(path: string, args: string[], options: { encoding: string }): string;
};

type LineReader = {
  on(event: string, listener: (line: string) => void): void;
};

type ReadlineApi = {
  createInterface(options: { input: object; crlfDelay: number }): LineReader;
};

type InputArguments = {
  value?: unknown;
};

type InputMessage = {
  type?: string;
  protocol?: string;
  extension_id?: string;
  extension_version?: string;
  generation?: number | string;
  capabilities?: string[];
  id?: string;
  tool?: string;
  thread_id?: string;
  run_id?: string;
  epoch?: number;
  operation_id?: string;
  call_id?: string;
  arguments?: InputArguments;
};

type ProtocolApi = {
  sendReady(message: InputMessage, tools: object[]): void;
  sendReply(message: InputMessage, type: string, fields?: object): void;
};

const fs: FileApi = require('node:fs');
const childProcess: ChildProcessApi = require('node:child_process');
const readline: ReadlineApi = require('node:readline');
const protocol: ProtocolApi = require('./protocol_v2.js');
const VERSION: string = 'pi-fixed-ts-v2';

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isAccessDenied(error: unknown): boolean {
  if (!isRecord(error)) return false;
  return (error.code === 'ERR_ACCESS_DENIED') ||
    (typeof error.message === 'string' && error.message.includes('permission'));
}

function parseMessage(line: string): InputMessage {
  const raw: unknown = JSON.parse(line);
  if (!isRecord(raw)) throw new Error('message must be an object');
  const args = isRecord(raw.arguments) ? { value: raw.arguments.value } : undefined;
  return {
    type: typeof raw.type === 'string' ? raw.type : undefined,
    protocol: typeof raw.protocol === 'string' ? raw.protocol : undefined,
    extension_id: typeof raw.extension_id === 'string' ? raw.extension_id : undefined,
    extension_version: typeof raw.extension_version === 'string' ? raw.extension_version : undefined,
    generation: typeof raw.generation === 'number' || typeof raw.generation === 'string' ? raw.generation : undefined,
    capabilities: Array.isArray(raw.capabilities) ? raw.capabilities as string[] : undefined,
    id: typeof raw.id === 'string' ? raw.id : undefined,
    tool: typeof raw.tool === 'string' ? raw.tool : undefined,
    thread_id: typeof raw.thread_id === 'string' ? raw.thread_id : undefined,
    run_id: typeof raw.run_id === 'string' ? raw.run_id : undefined,
    epoch: typeof raw.epoch === 'number' ? raw.epoch : undefined,
    operation_id: typeof raw.operation_id === 'string' ? raw.operation_id : undefined,
    call_id: typeof raw.call_id === 'string' ? raw.call_id : undefined,
    arguments: args
  };
}

function send(message: object): void {
  process.stdout.write(JSON.stringify(message) + '\n');
}

function permissionProbe(): object {
  let filesystemDenied = false;
  let processDenied = false;
  try {
    fs.readFileSync('/etc/passwd', 'utf8');
  } catch (error: unknown) {
    filesystemDenied = isAccessDenied(error);
  }
  try {
    childProcess.execFileSync('/bin/echo', ['blocked'], { encoding: 'utf8' });
  } catch (error: unknown) {
    processDenied = isAccessDenied(error);
  }
  return { filesystemDenied: Boolean(filesystemDenied), processDenied: Boolean(processDenied) };
}

function invoke(message: InputMessage): void {
  const args = message.arguments;
  if (message.tool === 'delayed') {
    protocol.sendReply(message, 'progress', { progress: { stage: 'waiting', version: VERSION } });
    setTimeout(() => protocol.sendReply(message, 'result', {
      ok: true,
      result: { version: VERSION, delayed: true }
    }), 5000);
    return;
  }
  if (message.tool === 'probe') {
    protocol.sendReply(message, 'result', { ok: true, result: permissionProbe() });
    return;
  }
  if (message.tool === 'echo') {
    protocol.sendReply(message, 'progress', { progress: { stage: 'echoing', version: VERSION } });
    protocol.sendReply(message, 'result', {
      ok: true,
      result: { version: VERSION, value: args?.value === undefined ? null : args.value, release: 'fixed-ts-v2' }
    });
    return;
  }
  protocol.sendReply(message, 'result', { ok: false, result: { code: 'unknown_tool' } });
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', (line: string) => {
  let message: InputMessage;
  try {
    message = parseMessage(line);
  } catch (error: unknown) {
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
