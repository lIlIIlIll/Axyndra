# Copied into a temporary executable with the current Python shebang by check.py.
import json
import os
from pathlib import Path
import sys
import time

record = Path(os.environ['GITHUB_PLUGIN_COMMANDS'])
with record.open('a') as stream:
    stream.write(json.dumps({'pid': os.getpid(), 'argv': sys.argv[1:]}, ensure_ascii=False) + '\n')
mode = os.environ['GITHUB_PLUGIN_TEST_MODE']
if mode == 'hang':
    time.sleep(60)
elif mode == 'fail':
    raise SystemExit(7)
elif sys.argv[1:] == ['remote', 'get-url', '--push', '--all', 'origin']:
    print('https://github.com/owner/project.git')
else:
    print(json.dumps({'argv': sys.argv[1:], 'fixture': 'actual subprocess'}, ensure_ascii=False))
