package agent_extension_runtime

public func piJavaScriptHostBootstrapSource(): String {
    """
import { createInterface } from 'node:readline';
import { registerHooks } from 'node:module';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { format } from 'node:util';

const newline = String.fromCharCode(10);
const rawStdoutWrite = process.stdout.write.bind(process.stdout);
const stderrWrite = process.stderr.write.bind(process.stderr);
process.stdout.write = (chunk, encoding, callback) => stderrWrite(chunk, encoding, callback);
for (const name of ['log', 'info', 'warn', 'error', 'debug']) {
  console[name] = (...args) => stderrWrite(format(...args) + newline);
}

const protocol = 'axyndra-js-host-v2';
const defaultMaxFrameBytes = 262144;
const lineReader = createInterface({ input: process.stdin, crlfDelay: Infinity });
const lineIterator = lineReader[Symbol.asyncIterator]();
const tools = new Map();
const commands = new Map();
const eventHooks = new Map();
const activeServices = new Map();
const retiredServices = new Map();
let currentInvocation = null;
let registering = true;
let maxFrameBytes = defaultMaxFrameBytes;
let serviceSequence = 0;
let launchIdentity = null;

function send(frame) {
  const line = JSON.stringify(frame);
  if (Buffer.byteLength(line, 'utf8') + 1 > maxFrameBytes) {
    throw new Error('extension protocol frame exceeds the configured limit');
  }
  rawStdoutWrite(line + newline);
}

function baseFrame(type, identity = launchIdentity) {
  return {
    type,
    protocol,
    extension_id: identity.extension_id,
    extension_version: identity.extension_version,
    generation: identity.generation,
  };
}

function invocationFrame(type, invocation, extra = {}) {
  return {
    ...baseFrame(type, invocation),
    id: invocation.id,
    tool: invocation.tool,
    kind: invocation.kind,
    command_id: invocation.command_id,
    thread_id: invocation.thread_id,
    run_id: invocation.run_id,
    epoch: invocation.epoch,
    operation_id: invocation.operation_id,
    call_id: invocation.call_id,
    ...extra,
  };
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
}

function checkedOptions(value, allowed, label) {
  if (value === undefined) return {};
  if (!isPlainObject(value)) throw new Error(label + ' options must be an object');
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new Error(label + ' option is unsupported: ' + key);
  }
  return value;
}

function typeString(options) {
  const value = checkedOptions(options, new Set(['description']), 'Type.String');
  const schema = { type: 'string' };
  if (value.description !== undefined) {
    if (typeof value.description !== 'string') throw new Error('Type.String description must be text');
    schema.description = value.description;
  }
  return Object.freeze(schema);
}

function typeObject(properties, options) {
  const value = checkedOptions(options, new Set(['description']), 'Type.Object');
  if (!isPlainObject(properties)) throw new Error('Type.Object properties must be an object');
  const schemaProperties = Object.create(null);
  const required = [];
  for (const [name, property] of Object.entries(properties)) {
    if (name.length === 0 || name === '__proto__' || !isPlainObject(property) || property.type !== 'string') {
      throw new Error('Type.Object supports only named Type.String properties');
    }
    schemaProperties[name] = property;
    required.push(name);
  }
  const schema = { type: 'object', properties: schemaProperties };
  if (required.length > 0) schema.required = required;
  if (value.description !== undefined) {
    if (typeof value.description !== 'string') throw new Error('Type.Object description must be text');
    schema.description = value.description;
  }
  return Object.freeze(schema);
}

const Type = new Proxy(Object.freeze({ Object: typeObject, String: typeString }), {
  get(object, property, receiver) {
    if (typeof property === 'symbol' || Object.prototype.hasOwnProperty.call(object, property)) {
      return Reflect.get(object, property, receiver);
    }
    throw extensionError('extension.pi_type_unsupported', 'TypeBox helper is unsupported: ' + String(property));
  },
});
Object.defineProperty(globalThis, '__axyndraPiType', { value: Type, writable: false, configurable: false });

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === '@earendil-works/pi-ai' || specifier === 'typebox') {
      return { url: 'data:text/javascript,' + encodeURIComponent('export const Type = globalThis.__axyndraPiType;'), shortCircuit: true };
    }
    if (specifier === '@earendil-works/pi-coding-agent') {
      return { url: 'data:text/javascript,' + encodeURIComponent('export function defineTool(tool) { return tool; }'), shortCircuit: true };
    }
    return nextResolve(specifier, context);
  },
});

function safeMessage(error) {
  let value = String(error && error.message ? error.message : error);
  const root = process.cwd();
  const rootUrl = pathToFileURL(root).href;
  value = value.split(rootUrl).join('<plugin>').split(root).join('<plugin>');
  return value.slice(0, 512);
}

function extensionError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function registerTool(definition) {
  if (!registering) throw extensionError('extension.pi_registration_closed', 'Pi tools must be registered during extension initialization');
  if (!isPlainObject(definition)) throw extensionError('extension.pi_tool_invalid', 'Pi tool definition must be an object');
  const allowed = new Set(['name', 'label', 'description', 'parameters', 'execute']);
  for (const key of Object.keys(definition)) {
    if (!allowed.has(key)) throw extensionError('extension.pi_tool_unsupported', 'Pi tool definition uses an unsupported property: ' + key);
  }
  if (typeof definition.name !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(definition.name)) {
    throw extensionError('extension.pi_tool_invalid', 'Pi tool name must contain 1 to 64 letters, digits, underscores, or hyphens');
  }
  if (tools.has(definition.name)) throw extensionError('extension.pi_tool_duplicate', 'Pi extension registered a duplicate tool name');
  if (tools.size >= 128) throw extensionError('extension.pi_tool_limit', 'Pi extension exceeded the tool registration limit');
  if (typeof definition.description !== 'string' || definition.description.length > 8192) {
    throw extensionError('extension.pi_tool_invalid', 'Pi tool description must be text no longer than 8192 characters');
  }
  if (definition.label !== undefined && (typeof definition.label !== 'string' || definition.label.length > 256)) {
    throw extensionError('extension.pi_tool_invalid', 'Pi tool label must be text no longer than 256 characters');
  }
  if (!isPlainObject(definition.parameters) || definition.parameters.type !== 'object' || typeof definition.execute !== 'function') {
    throw extensionError('extension.pi_tool_invalid', 'Pi tool requires an object schema and execute function');
  }
  let inputSchema;
  try {
    inputSchema = JSON.stringify(definition.parameters);
  } catch (_) {
    throw extensionError('extension.pi_tool_schema_invalid', 'Pi tool schema is not JSON serializable');
  }
  if (Buffer.byteLength(inputSchema, 'utf8') > maxFrameBytes / 2) {
    throw extensionError('extension.pi_tool_schema_too_large', 'Pi tool schema exceeds the registration limit');
  }
  tools.set(definition.name, { execute: definition.execute, description: definition.description, inputSchema: JSON.parse(inputSchema) });
}
function registerEvent(event, handler) {
  if (!registering) throw extensionError('extension.pi_registration_closed', 'Pi event handlers must be registered during extension initialization');
  if (typeof event !== 'string') throw extensionError('extension.pi_event_invalid', 'Pi event name must be text');
  if (event !== 'tool_call' && event !== 'tool_result') {
    throw extensionError('extension.pi_event_unsupported', 'Pi event is unsupported: ' + event);
  }
  if (typeof handler !== 'function') throw extensionError('extension.pi_event_invalid', 'Pi event handler must be a function');
  let handlers = eventHooks.get(event);
  if (!handlers) { handlers = []; eventHooks.set(event, handlers); }
  if (handlers.length >= 32) throw extensionError('extension.pi_event_limit', 'Pi event exceeded the 32-handler limit');
  const registration = { handler, active: true };
  handlers.push(registration);
  return () => {
    if (!registering) throw extensionError('extension.pi_event_unsubscribe_unsupported', 'Pi event handlers cannot be removed after extension initialization');
    registration.active = false;
  };
}
function registerCommand(name, options = {}) {
  if (!registering) throw extensionError('extension.pi_registration_closed', 'Pi commands must be registered during extension initialization');
  if (typeof name !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(name)) {
    throw extensionError('extension.pi_command_invalid', 'Pi command name must contain 1 to 64 lowercase letters, digits, underscores, or hyphens');
  }
  if (tools.has(name) || commands.has(name)) throw extensionError('extension.pi_command_duplicate', 'Pi extension registered a duplicate command name');
  if (commands.size >= 64) throw extensionError('extension.pi_command_limit', 'Pi extension exceeded the command registration limit');
  const value = checkedOptions(options, new Set(['description', 'handler']), 'pi.registerCommand');
  if (value.description !== undefined && (typeof value.description !== 'string' || value.description.length > 8192)) {
    throw extensionError('extension.pi_command_invalid', 'Pi command description must be bounded text');
  }
  if (typeof value.handler !== 'function') throw extensionError('extension.pi_command_invalid', 'Pi command requires a handler function');
  commands.set(name, { description: value.description || '', handler: value.handler });
}
function shellQuote(value) {
  if (typeof value !== 'string' || value.includes(String.fromCharCode(0))) {
    throw new Error('pi.exec command and arguments must be NUL-free strings');
  }
  let result = "'";
  for (const character of value) {
    if (character === "'") result += "'" + String.fromCharCode(92) + "''";
    else result += character;
  }
  return result + "'";
}

function retireService(requestId, pending) {
  activeServices.delete(requestId);
  if (pending.abortHandler) {
    pending.invocation.controller.signal.removeEventListener('abort', pending.abortHandler);
  }
  retiredServices.set(requestId, pending.invocation);
  while (retiredServices.size > 128) {
    retiredServices.delete(retiredServices.keys().next().value);
  }
}

function serviceRequest(invocation, service, argumentsValue) {
  const requestId = 'pi-service-' + String(++serviceSequence);
  return new Promise((resolvePromise, rejectPromise) => {
    const signal = invocation.controller.signal;
    const pending = {
      invocation,
      resolve: resolvePromise,
      reject: rejectPromise,
      settled: false,
      abortHandler: null,
    };
    const abortHandler = () => {
      if (pending.settled) return;
      pending.settled = true;
      retireService(requestId, pending);
      rejectPromise(signal.reason || extensionError(
        'extension.pi_tool_cancelled', 'Pi tool invocation was cancelled'
      ));
    };
    pending.abortHandler = abortHandler;
    activeServices.set(requestId, pending);
    signal.addEventListener('abort', abortHandler, { once: true });
    if (signal.aborted) {
      abortHandler();
      return;
    }
    try {
      send(invocationFrame('service_request', invocation, {
        request_id: requestId,
        service,
        arguments: argumentsValue,
      }));
    } catch (error) {
      if (!pending.settled) {
        pending.settled = true;
        activeServices.delete(requestId);
        signal.removeEventListener('abort', abortHandler);
        rejectPromise(error);
      }
    }
  });
}
function makePiFacade() {
  const target = Object.freeze({
    registerTool,
    registerCommand,
    on: registerEvent,
    exec: async (command, args = [], options = {}) => {
      const invocation = currentInvocation;
      if (!invocation || invocation.done || invocation.kind !== 'tool') throw extensionError('extension.pi_exec_outside_invocation', 'pi.exec is available only while a tool is executing');
      if (invocation.controller.signal.aborted) throw invocation.controller.signal.reason || new Error('Pi tool was cancelled');
      if (typeof command !== 'string' || command.length === 0 || command.length > 4096 ||
          !Array.isArray(args) || args.length > 128 || args.some((item) => typeof item !== 'string' || item.length > 16384)) {
        throw extensionError('extension.pi_exec_arguments_invalid', 'pi.exec requires a bounded command and string argument array');
      }
      const execOptions = checkedOptions(options, new Set(['cwd', 'timeout', 'signal']), 'pi.exec');
      if (execOptions.signal !== undefined && execOptions.signal !== invocation.controller.signal) {
        throw extensionError('extension.pi_exec_signal_unsupported', 'pi.exec only accepts the active invocation AbortSignal');
      }
      const cwd = execOptions.cwd === undefined ? invocation.context.cwd : execOptions.cwd;
      if (typeof cwd !== 'string' || cwd.length > 4096 || cwd.includes(String.fromCharCode(0))) {
        throw extensionError('extension.pi_exec_cwd_invalid', 'pi.exec cwd must be a bounded NUL-free path');
      }
      if (cwd !== invocation.context.cwd) {
        throw extensionError('extension.pi_exec_cwd_unsupported', 'pi.exec cwd overrides must match the active tool context');
      }
      let timeoutSeconds;
      if (execOptions.timeout !== undefined) {
        if (typeof execOptions.timeout !== 'number' || !Number.isFinite(execOptions.timeout) || execOptions.timeout < 1 || execOptions.timeout > 600000) {
          throw extensionError('extension.pi_exec_timeout_invalid', 'pi.exec timeout must be between 1 and 600000 milliseconds');
        }
        timeoutSeconds = Math.ceil(execOptions.timeout / 1000);
      }
      const commandLine = [command, ...args].map(shellQuote).join(' ');
      if (Buffer.byteLength(commandLine, 'utf8') > 131072) {
        throw extensionError('extension.pi_exec_arguments_invalid', 'pi.exec command exceeds the request limit');
      }
      const requestArguments = { command: commandLine };
      if (timeoutSeconds !== undefined) requestArguments.timeout = timeoutSeconds;
      const response = await serviceRequest(invocation, 'exec', requestArguments);
      if (!isPlainObject(response) || !isPlainObject(response.output) ||
          !Number.isInteger(response.output.exit_code) || typeof response.output.stdout !== 'string' ||
          typeof response.output.stderr !== 'string' || typeof response.output.timed_out !== 'boolean') {
        throw extensionError('extension.pi_exec_response_invalid', 'host returned an invalid pi.exec result');
      }
      return {
        code: response.output.exit_code,
        stdout: response.output.stdout,
        stderr: response.output.stderr,
        killed: response.output.timed_out,
      };
    },
  });
  return new Proxy(target, {
    get(object, property, receiver) {
      if (typeof property === 'symbol' || Object.prototype.hasOwnProperty.call(object, property)) {
        return Reflect.get(object, property, receiver);
      }
      throw extensionError('extension.pi_api_unsupported', 'Pi ExtensionAPI member is unsupported: ' + String(property));
    },
  });
}

function makeContext(value, invocation) {
  const cwd = value && typeof value.cwd === 'string' ? value.cwd : '';
  const hasUI = value && value.has_ui === true;
  const signal = invocation.controller.signal;
  const requireUI = () => {
    if (!hasUI) throw extensionError(
      'extension.pi_interaction_unsupported',
      'Pi UI interaction is unavailable because this invocation has no frontend responder',
    );
    if (invocation.done) throw extensionError(
      'extension.pi_invocation_closed', 'Pi UI interaction is unavailable after invocation completion',
    );
    if (signal.aborted) throw signal.reason || extensionError(
      'extension.pi_tool_cancelled', 'Pi tool invocation was cancelled',
    );
  };
  const interactionOptions = (options) => {
    const parsed = checkedOptions(options, new Set(['signal', 'timeout']), 'Pi UI');
    if (parsed.signal !== undefined && parsed.signal !== signal) {
      throw extensionError('extension.pi_ui_signal_unsupported', 'Pi UI only accepts the active invocation AbortSignal');
    }
    if (parsed.timeout === undefined) return {};
    if (typeof parsed.timeout !== 'number' || !Number.isFinite(parsed.timeout) ||
        parsed.timeout < 1 || parsed.timeout > 600000) {
      throw extensionError('extension.pi_ui_timeout_invalid', 'Pi UI timeout must be between 1 and 600000 milliseconds');
    }
    return { timeout: parsed.timeout };
  };
  const ui = Object.freeze({
    notify(message, type = 'info') {
      requireUI();
      if (typeof message !== 'string' || message.trim().length === 0 || message.length > 4096 ||
          !['info', 'warning', 'error'].includes(type)) {
        throw extensionError('extension.pi_ui_arguments_invalid', 'Pi notification message or type is invalid');
      }
      void serviceRequest(invocation, 'ui.notify', { message, type }).catch(() => {});
    },
    async select(title, options, optionsValue = {}) {
      requireUI();
      const parsed = interactionOptions(optionsValue);
      if (typeof title !== 'string' || title.trim().length === 0 || title.length > 4096 ||
          !Array.isArray(options) || options.length === 0 || options.length > 64 ||
          options.some((item) => typeof item !== 'string' || item.trim().length === 0 || item.length > 256) ||
          new Set(options).size !== options.length) {
        throw extensionError('extension.pi_ui_arguments_invalid', 'Pi selection title and options are invalid');
      }
      const request = { title, options };
      if (parsed.timeout !== undefined) request.timeout = parsed.timeout;
      const response = await serviceRequest(invocation, 'ui.select', request);
      if (!isPlainObject(response)) throw extensionError(
        'extension.pi_ui_response_invalid', 'host returned an invalid Pi selection result',
      );
      if (response.cancelled === true || response.value === undefined) return undefined;
      if (typeof response.value !== 'string' || !options.includes(response.value)) {
        throw extensionError('extension.pi_ui_response_invalid', 'host returned a choice outside the Pi selection options');
      }
      return response.value;
    },
    async confirm(title, message, optionsValue = {}) {
      requireUI();
      const parsed = interactionOptions(optionsValue);
      if (typeof title !== 'string' || title.trim().length === 0 || title.length > 4096 ||
          typeof message !== 'string' || message.length > 4096) {
        throw extensionError('extension.pi_ui_arguments_invalid', 'Pi confirmation title and message are invalid');
      }
      const request = { title, message };
      if (parsed.timeout !== undefined) request.timeout = parsed.timeout;
      const response = await serviceRequest(invocation, 'ui.confirm', request);
      if (!isPlainObject(response) || typeof response.confirmed !== 'boolean') {
        throw extensionError('extension.pi_ui_response_invalid', 'host returned an invalid Pi confirmation result');
      }
      return response.confirmed;
    },
  });
  const target = Object.freeze({ cwd, hasUI, signal, ui });
  return new Proxy(target, {
    get(object, property, receiver) {
      if (typeof property === 'symbol' || Object.prototype.hasOwnProperty.call(object, property)) {
        return Reflect.get(object, property, receiver);
      }
      throw extensionError('extension.pi_context_unsupported', 'Pi tool context member is unsupported: ' + String(property));
    },
  });
}

function normalizeResult(value) {
  if (!isPlainObject(value) || !Array.isArray(value.content) || value.content.length > 128) {
    throw extensionError('extension.pi_result_invalid', 'Pi tool must return a result with a bounded content array');
  }
  for (const item of value.content) {
    if (!isPlainObject(item) || item.type !== 'text' || typeof item.text !== 'string' || item.text.length > maxFrameBytes / 2) {
      throw extensionError('extension.pi_result_unsupported', 'Pi tool results currently support bounded text content only');
    }
  }
  const output = { content: value.content.map((item) => ({ type: 'text', text: item.text })) };
  if (Object.prototype.hasOwnProperty.call(value, 'details')) output.details = value.details;
  let encoded;
  try {
    encoded = JSON.stringify(output);
  } catch (_) {
    throw extensionError('extension.pi_result_invalid', 'Pi tool result details must be JSON serializable');
  }
  if (Buffer.byteLength(encoded, 'utf8') + 512 > maxFrameBytes) {
    throw extensionError('extension.pi_result_too_large', 'Pi tool result exceeds the protocol frame limit');
  }
  return JSON.parse(encoded);
}
function freezeJson(value) {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    for (const key of Object.keys(value)) freezeJson(value[key]);
    Object.freeze(value);
  }
  return value;
}
function normalizeEventHookResult(eventName, event, returned) {
  if (!isPlainObject(event) || event.type !== eventName) {
    throw extensionError('extension.pi_event_invalid', 'Pi event payload is invalid');
  }
  if (eventName === 'tool_call') {
    if (!isPlainObject(event.input)) throw extensionError('extension.pi_event_invalid', 'Pi tool_call input must be an object');
    Object.freeze(event);
    if (returned !== undefined && !isPlainObject(returned)) {
      throw extensionError('extension.pi_event_result_invalid', 'Pi tool_call handler result must be an object');
    }
    let block = false;
    let reason = '';
    if (returned !== undefined) {
      for (const key of Object.keys(returned)) {
        if (key !== 'block' && key !== 'reason') {
          throw extensionError('extension.pi_event_result_unsupported', 'Pi tool_call result property is unsupported: ' + key);
        }
      }
      if (returned.block !== undefined && typeof returned.block !== 'boolean') {
        throw extensionError('extension.pi_event_result_invalid', 'Pi tool_call block must be boolean');
      }
      if (returned.reason !== undefined && (typeof returned.reason !== 'string' || returned.reason.length > 512)) {
        throw extensionError('extension.pi_event_result_invalid', 'Pi tool_call reason must be bounded text');
      }
      block = returned.block === true;
      reason = returned.reason || '';
    }
    const result = { input: event.input, block };
    if (reason !== '') result.reason = reason;
    return result;
  }
  freezeJson(event);
  if (returned !== undefined) {
    throw extensionError('extension.pi_event_result_unsupported', 'Pi tool_result handlers are observational and cannot replace committed results');
  }
  return { observed: true };
}

function settleServices(invocation, error) {
  for (const [requestId, pending] of activeServices) {
    if (pending.invocation === invocation && !pending.settled) {
      pending.settled = true;
      retireService(requestId, pending);
      pending.reject(error);
    }
  }
}

function resolveEventHook(reference) {
  const match = /^(tool_call|tool_result):([0-9]+)$/.exec(reference);
  if (!match) return null;
  const handlers = eventHooks.get(match[1]);
  const registration = handlers && handlers[Number(match[2])];
  if (!registration || !registration.active) return null;
  return { event: match[1], registration };
}

async function runInvocation(message) {
  const kind = message.kind === undefined ? 'tool' : message.kind;
  if (kind !== 'tool' && kind !== 'command' && kind !== 'hook') {
    throw extensionError('extension.pi_invocation_kind_invalid', 'Pi invocation kind is invalid');
  }
  const hook = kind === 'hook' ? resolveEventHook(message.command_id) : null;
  const registered = kind === 'tool' ? tools.get(message.tool) :
    kind === 'command' ? commands.get(message.tool) : hook && hook.registration;
  if (!registered) {
    const code = kind === 'tool' ? 'extension.pi_tool_not_registered' :
      kind === 'command' ? 'extension.pi_command_not_registered' : 'extension.pi_event_not_registered';
    throw extensionError(code, 'Pi invocation names an unregistered ' + kind);
  }
  const controller = new AbortController();
  const invocation = { ...message, controller, context: null, done: false };
  const context = makeContext(message.context, invocation);
  invocation.context = context;
  currentInvocation = invocation;
  const onUpdate = (partialResult) => {
    if (invocation.done || invocation.controller.signal.aborted) return;
    const normalized = normalizeResult(partialResult);
    send(invocationFrame('progress', invocation, { progress: normalized }));
  };
  try {
    let result;
    if (kind === 'tool') {
      result = await registered.execute(
        message.id,
        message.arguments,
        controller.signal,
        onUpdate,
        context,
      );
      result = normalizeResult(result);
    } else if (kind === 'command') {
      if (!isPlainObject(message.arguments) || typeof message.arguments.command_args !== 'string') {
        throw extensionError('extension.pi_command_arguments_invalid', 'Pi command arguments must be text');
      }
      const returned = await registered.handler(message.arguments.command_args, context);
      if (returned !== undefined) throw extensionError('extension.pi_command_result_unsupported', 'Pi command handlers must not return a value');
      result = { content: [] };
    } else {
      if (!isPlainObject(message.arguments) || !isPlainObject(message.arguments.event)) {
        throw extensionError('extension.pi_event_invalid', 'Pi event invocation must contain an event object');
      }
      const event = message.arguments.event;
      if (event.type !== hook.event) throw extensionError('extension.pi_event_invalid', 'Pi event type does not match its registration');
      if (hook.event === 'tool_call') {
        if (!isPlainObject(event.input)) throw extensionError('extension.pi_event_invalid', 'Pi tool_call input must be an object');
        Object.freeze(event);
      } else {
        freezeJson(event);
      }
      const returned = await registered.handler(event, context);
      result = normalizeEventHookResult(hook.event, event, returned);
    }
    invocation.done = true;
    settleServices(invocation, new Error('Pi invocation completed'));
    send(invocationFrame('result', invocation, { ok: true, result }));
  } catch (error) {
    invocation.done = true;
    settleServices(invocation, error);
    if (controller.signal.aborted) {
      send(invocationFrame('cancelled', invocation, { reason: 'extension.pi_tool_cancelled' }));
    } else {
      send(invocationFrame('result', invocation, {
        ok: false,
        result: { error: { code: error && typeof error.code === 'string' ? error.code : 'extension.pi_tool_failed', message: safeMessage(error) } },
      }));
    }
  } finally {
    if (currentInvocation === invocation) currentInvocation = null;
  }
}

function serviceResponseMatchesInvocation(message, invocation) {
  return message.id === invocation.id && message.kind === invocation.kind &&
    message.command_id === invocation.command_id && message.thread_id === invocation.thread_id &&
    message.run_id === invocation.run_id && message.epoch === invocation.epoch &&
    message.operation_id === invocation.operation_id && message.call_id === invocation.call_id;
}

function handleServiceResponse(message) {
  if (typeof message.request_id !== 'string') {
    throw extensionError('extension.pi_service_identity_invalid', 'host service response omitted its request id');
  }
  const pending = activeServices.get(message.request_id);
  if (pending) {
    if (pending.invocation !== currentInvocation ||
        !serviceResponseMatchesInvocation(message, pending.invocation)) {
      throw extensionError('extension.pi_service_identity_invalid', 'host service response does not match the active invocation');
    }
    activeServices.delete(message.request_id);
    pending.settled = true;
    pending.invocation.controller.signal.removeEventListener('abort', pending.abortHandler);
    if (message.ok === true) pending.resolve(message.result);
    else pending.reject(extensionError(
      message.error && typeof message.error.code === 'string' ? message.error.code : 'extension.pi_service_failed',
      message.error && typeof message.error.message === 'string' ? message.error.message : 'host service request failed',
    ));
    return;
  }
  const retiredInvocation = retiredServices.get(message.request_id);
  if (retiredInvocation && serviceResponseMatchesInvocation(message, retiredInvocation)) {
    retiredServices.delete(message.request_id);
    return;
  }
  if (!currentInvocation || !serviceResponseMatchesInvocation(message, currentInvocation)) {
    throw extensionError('extension.pi_service_identity_invalid', 'host service response does not match the active invocation');
  }
  throw extensionError('extension.pi_service_response_unknown', 'host service response does not match a pending request');
}

async function readMessage() {
  const next = await lineIterator.next();
  if (next.done) throw extensionError('extension.pi_host_closed', 'host closed the extension input');
  let message;
  try { message = JSON.parse(next.value); }
  catch (_) { throw extensionError('extension.pi_protocol_invalid', 'host sent invalid JSON'); }
  if (!isPlainObject(message) || message.protocol !== protocol ||
      message.extension_id !== launchIdentity.extension_id ||
      message.extension_version !== launchIdentity.extension_version ||
      message.generation !== launchIdentity.generation) {
    throw extensionError('extension.pi_identity_invalid', 'host frame identity does not match this extension process');
  }
  return message;
}

async function initialize() {
  const first = await lineIterator.next();
  if (first.done) throw extensionError('extension.pi_hello_missing', 'host did not send an initialization frame');
  const hello = JSON.parse(first.value);
  if (!isPlainObject(hello) || hello.type !== 'hello' || hello.protocol !== protocol ||
      typeof hello.extension_id !== 'string' || typeof hello.extension_version !== 'string' ||
      !Number.isInteger(hello.generation) || hello.generation < 1 || !Array.isArray(hello.capabilities)) {
    throw extensionError('extension.pi_hello_invalid', 'host initialization frame is invalid');
  }
  launchIdentity = {
    extension_id: hello.extension_id,
    extension_version: hello.extension_version,
    generation: hello.generation,
  };
  if (Number.isInteger(hello.max_frame_bytes) && hello.max_frame_bytes >= 1024) maxFrameBytes = hello.max_frame_bytes;
  const entrypoint = resolve(process.cwd(), process.argv[1]);
  const module = await import(pathToFileURL(entrypoint).href);
  if (typeof module.default !== 'function') {
    throw extensionError('extension.pi_default_export_invalid', 'Pi extension default export must be a function');
  }
  const pi = makePiFacade();
  await module.default(pi);
  registering = false;
  const eventDescriptors = [];
  for (const [event, handlers] of eventHooks) {
    for (let index = 0; index < handlers.length; index++) {
      if (handlers[index].active) eventDescriptors.push({ event, index });
    }
  }
  if (tools.size === 0 && commands.size === 0 && eventDescriptors.length === 0) {
    throw extensionError('extension.pi_registration_empty', 'Pi extension must register at least one tool, command, or supported event');
  }
  const descriptors = [...tools.entries()].map(([name, value]) => ({
    name,
    description: value.description,
    input_schema: value.inputSchema,
  }));
  const commandDescriptors = [...commands.entries()].map(([name, value]) => ({ name, description: value.description }));
  send({ ...baseFrame('ready'), capabilities: hello.capabilities, tools: descriptors, commands: commandDescriptors, hooks: eventDescriptors });
}

async function main() {
  try {
    await initialize();
  } catch (error) {
    if (launchIdentity) {
      send({
        ...baseFrame('error'),
        code: error && typeof error.code === 'string' ? error.code : 'extension.pi_initialization_failed',
        message: safeMessage(error),
      });
    }
    process.exitCode = 1;
    return;
  }
  while (true) {
    let message;
    try { message = await readMessage(); }
    catch (_) { return; }
    if (message.type === 'invoke') {
      if (currentInvocation) {
        send(invocationFrame('result', message, {
          ok: false,
          result: { error: { code: 'extension.pi_invocation_busy', message: 'Pi host already has an active invocation' } },
        }));
      } else {
        void runInvocation(message).catch((error) => {
          try {
            send(invocationFrame('result', message, {
              ok: false,
              result: { error: { code: 'extension.pi_tool_failed', message: safeMessage(error) } },
            }));
          } catch (_) {}
        });
      }
    } else if (message.type === 'service_response') {
      handleServiceResponse(message);
    } else if (message.type === 'cancel') {
      if (currentInvocation && message.id === currentInvocation.id &&
          message.thread_id === currentInvocation.thread_id && message.run_id === currentInvocation.run_id &&
          message.epoch === currentInvocation.epoch && message.operation_id === currentInvocation.operation_id &&
          message.call_id === currentInvocation.call_id) {
        currentInvocation.controller.abort(extensionError('extension.pi_tool_cancelled', 'Pi tool invocation was cancelled'));
      }
    } else if (message.type === 'close') {
      lineReader.close();
      return;
    } else {
      throw extensionError('extension.pi_message_unsupported', 'host sent an unsupported protocol message');
    }
  }
}

void main().catch((error) => {
  console.error(safeMessage(error));
  process.exitCode = 1;
});
"""
}
