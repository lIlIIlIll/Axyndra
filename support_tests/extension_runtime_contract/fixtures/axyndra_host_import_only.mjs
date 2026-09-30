import { basename } from 'node:path';
import readline from 'node:readline';

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.once('line', () => {
  process.stdout.write(JSON.stringify({
    type: 'module_imported',
    file: basename(import.meta.url)
  }) + '\n');
});
