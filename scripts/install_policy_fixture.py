#!/usr/bin/env python3
"""Install a test policy using the real CLI and explicit operator configuration."""
import json
from pathlib import Path
import subprocess

def install_policy_fixture(app, package, home, workspace, environment, *, key, provider):
    package=Path(package).resolve(strict=True)
    manifest=json.loads((package/'axyndra.plugin.json').read_text(encoding='utf-8'))
    def command(arguments):
        completed=subprocess.run([str(app),'--cwd',str(workspace),*arguments],cwd=workspace,
            env=environment,capture_output=True,text=True,timeout=60)
        if completed.returncode:
            raise AssertionError('normal plugin CLI failed: '+completed.stderr[-4096:])
        return completed.stdout
    command(['plugin','import',str(package),'--scope','user'])
    records=json.loads(command(['plugin','list','--json']))
    namespace='axyndra:'+manifest['id']
    selected=[r for r in records if r['namespace']==namespace]
    if len(selected)!=1:raise AssertionError('expected one imported native policy')
    record=selected[0]
    command(['plugin','enable',record['id'],'--scope','user'])
    path=Path(home)/'plugins/policies.json'
    value=json.loads(path.read_text()) if path.exists() else {'version':1,'bindings':{}}
    if value.get('version')!=1 or key in value['bindings']:
        raise AssertionError('fixture refuses to overwrite an existing policy selection')
    value['bindings'][key]={'namespace':namespace,'provider':provider,'package_digest':record['content_digest']}
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value)+'\n',encoding='utf-8')
    return record
