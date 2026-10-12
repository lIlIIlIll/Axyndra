import vm from 'node:vm';
import { createRequire } from 'node:module';
import readline from 'node:readline';
process.stdout.write('READY|js|1\n');
const require = createRequire(import.meta.url);
let context;
function fresh() {
  context = vm.createContext({ Buffer, fetch, process, require, setTimeout, clearTimeout, URL, TextEncoder, TextDecoder });
}
fresh();
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of rl) {
  const started = Date.now(); let out = []; let err = []; let exitCode = 0; let timedOut = false;
  try {
    const first = line.indexOf('|'), second = line.indexOf('|', first + 1);
    const timeoutMs = Number(line.slice(0, first));
    if (line.slice(first + 1, second) === '1') fresh();
    const code = Buffer.from(line.slice(second + 1), 'hex').toString('utf8');
    const format = value => typeof value === 'string' ? value : Bun.inspect(value);
    context.console = { log: (...v) => out.push(v.map(format).join(' ')), error: (...v) => err.push(v.map(format).join(' ')), warn: (...v) => err.push(v.map(format).join(' ')) };
    context.print = (...v) => out.push(v.map(format).join(' '));
    context.display = value => out.push(typeof value === 'string' ? value : JSON.stringify(value, null, 2));
    const asyncCell = /(^|[^A-Za-z0-9_$])await\s|(^|\n)\s*return\b/.test(code);
    const source = asyncCell ? '(async()=>{\n' + code + '\n})()' : code;
    let value = new vm.Script(source, { filename: '<eval>' }).runInContext(context, { timeout: timeoutMs });
    if (value && typeof value.then === 'function') {
      value = await Promise.race([value, new Promise((_, reject) => setTimeout(() => reject(new Error('__OMP_EVAL_TIMEOUT__')), timeoutMs))]);
    }
    if (value !== undefined) context.display(value);
  } catch (e) {
    const message = String(e && e.stack ? e.stack : e);
    timedOut = message.includes('__OMP_EVAL_TIMEOUT__') || message.includes('Script execution timed out');
    exitCode = timedOut ? 124 : 1;
    err.push(timedOut ? 'eval cell timed out' : message);
  }
  const encode = value => Buffer.from(value).toString('hex');
  process.stdout.write('OK|' + exitCode + '|' + (timedOut ? 1 : 0) + '|' + (Date.now() - started) + '|' + encode(out.join('\n')) + '|' + encode(err.join('\n')) + '\n');
  if (timedOut) setImmediate(() => process.exit(0));
}
