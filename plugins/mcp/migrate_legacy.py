#!/usr/bin/env python3
"""Read historical MCP YAML and print an inert, independently namespaced draft."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

SCALARS={'id','enabled','transport','command','cwd','network','url','bearer_token_env','origin','prefer_sse','max_frame_bytes','request_timeout_ms','graceful_shutdown_ms'}
BLOCKS={'args','env','secret_env','headers','trusted_read_only_tools'}
ENV=re.compile(r'[A-Za-z_][A-Za-z0-9_]*\Z')
ID=re.compile(r'[A-Za-z0-9_-]+\Z')
HEADER=re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+\Z")
RESERVED={"authorization","accept","content-type","origin","mcp-protocol-version","mcp-method","mcp-name"}
MAX_SOURCE=1048576

class MigrationError(ValueError):
    pass

def fail(message):
    raise MigrationError(message)

def scalar(source):
    single=double=escaped=False
    for index,char in enumerate(source):
        if double and escaped:
            escaped=False;continue
        if double and char=='\\':
            escaped=True;continue
        if not single and char=='"':
            double=not double;continue
        if not double and char=="'":
            single=not single;continue
        if not single and not double and char=='#' and (index==0 or source[index-1] in ' \t'):
            source=source[:index];break
    value=source.strip(' \t\r\n')
    if len(value)>=2 and value[0]==value[-1] and value[0] in ('"',"'"):
        inner=value[1:-1]
        return inner.replace('\\"','"').replace('\\\\','\\') if value[0]=='"' else inner
    return value

def field(source):
    if ':' not in source:fail("legacy field requires ':'")
    name,value=source.split(':',1);name=name.strip(' \t\r\n')
    if not name:fail('legacy field name is empty')
    return name,scalar(value)

def boolean(value):
    if value.lower() not in ('true','false'):fail('legacy boolean must be true or false')
    return value.lower()=='true'

def integer(value):
    if not re.fullmatch(r'[+-]?[0-9]+',value):fail('legacy framing value must be an Int64')
    number=int(value)
    if not -(1<<63)<=number<(1<<63):fail('legacy framing value exceeds Int64')
    return number

def secret_name(name):
    name=name.upper().replace('-','_')
    return any(part in name for part in ('SECRET','TOKEN','PASSWORD','PASSWD','CREDENTIAL','API_KEY','COOKIE')) or name.endswith('_KEY') or name=='SSH_AUTH_SOCK'

def secure_url(value,*,origin=False):
    if not value or any(ord(c)<33 or ord(c)>126 for c in value) or '\\' in value:fail('legacy HTTP URL is invalid')
    try:
        parsed=urlsplit(value);port=parsed.port
    except ValueError:fail('legacy HTTP URL is invalid')
    if parsed.username is not None or parsed.password is not None or parsed.fragment or not parsed.hostname:fail('legacy HTTP URL authority is invalid')
    if parsed.scheme!='https' and not (parsed.scheme=='http' and parsed.hostname.lower() in ('localhost','127.0.0.1','::1')):fail('legacy HTTP URL requires HTTPS or exact loopback HTTP')
    if port is not None and not 1<=port<=65535:fail('legacy HTTP port is invalid')
    if origin and (parsed.path or parsed.query):fail('legacy Origin requires an authority only')

def finalize(server):
    if not ID.fullmatch(server.get('id','')):fail('legacy server id must use letters, digits, hyphen or underscore')
    if 'enabled' not in server or 'transport' not in server:fail('legacy server requires explicit enabled and transport')
    server['enabled']=boolean(server['enabled'])
    transport=server['transport']
    for name,default in (('max_frame_bytes',8388608),('request_timeout_ms',30000),('graceful_shutdown_ms',3000)):
        server[name]=integer(server[name]) if name in server else default
    if server['max_frame_bytes']<1024 or server['request_timeout_ms']<=0 or server['graceful_shutdown_ms']<0:fail('legacy framing limits are invalid')
    if transport=='stdio':
        if not server.get('command'):fail('legacy stdio command is required')
        if {'url','bearer_token_env','origin','prefer_sse','headers'} & server.keys():fail('legacy stdio contains HTTP-only fields')
        network=server.get('network','denied')
        if network not in ('denied','host'):fail('legacy stdio proxy requires egress rules; boolean network is invalid')
        for target,source in server.get('env',{}).items():
            if secret_name(target) or secret_name(source):fail('legacy secret-like bindings must use secret_env')
    elif transport=='streamable-http':
        if {'command','args','cwd','env','secret_env','network'} & server.keys():fail('legacy HTTP contains stdio-only fields')
        secure_url(server.get('url',''))
        if server.get('origin'):secure_url(server['origin'],origin=True)
        if 'bearer_token_env' in server and not ENV.fullmatch(server['bearer_token_env']):fail('legacy bearer source must be an environment name')
        server['prefer_sse']=boolean(server['prefer_sse']) if 'prefer_sse' in server else False
    else:fail('legacy transport must be stdio or streamable-http')
    return server

def parse(source):
    seen=set();servers=[];current=None;section=''
    for line in source.split('\n'):
        trimmed=line.strip(' \t\r\n')
        if not trimmed or trimmed.startswith('#'):continue
        prefix=line[:len(line)-len(line.lstrip(' \t'))]
        if '\t' in prefix:fail('legacy indentation must use spaces')
        indent=len(prefix)
        if indent==0:
            if current is not None:fail('legacy top-level field follows server entries')
            name,value=field(trimmed)
            if name not in ('version','servers') or name in seen:fail('legacy top-level field is unknown or repeated')
            seen.add(name)
            if name=='version' and value!='1':fail('legacy version must be 1')
            if name=='servers' and value!='':fail('legacy servers must be a block list')
            section='';continue
        if 'servers' not in seen:fail('legacy entry precedes servers')
        if indent==2:
            if not trimmed.startswith('- '):fail('legacy servers must be a block list')
            if current is not None:servers.append(finalize(current))
            current={};section='';name,value=field(trimmed[2:].strip())
        elif indent==4:
            if current is None:fail('legacy field precedes server')
            name,value=field(trimmed);section=''
            if name in BLOCKS:
                if name in current or value!='':fail('legacy block is repeated or not block syntax')
                current[name]=[] if name in ('args','trusted_read_only_tools') else {};section=name;continue
        elif indent==6:
            if current is None or section not in BLOCKS:fail('legacy nested field is unexpected')
            if section in ('args','trusted_read_only_tools'):
                if not trimmed.startswith('- '):fail('legacy nested list requires dash')
                value=scalar(trimmed[2:].strip())
                if section=='trusted_read_only_tools' and (not value or value in current[section]):fail('legacy trusted names must be unique and nonempty')
                current[section].append(value)
            else:
                name,value=field(trimmed)
                if not value or not ENV.fullmatch(value):fail('legacy source must be an environment name')
                if section=='headers':
                    lower=name.lower()
                    if not HEADER.fullmatch(name) or lower in RESERVED:fail("legacy header is reserved or invalid")
                    if lower in {key.lower() for key in current[section]}:fail('legacy HTTP header is repeated')
                else:
                    if not ENV.fullmatch(name):fail('legacy environment target is invalid')
                    if name in current.get('env',{}) or name in current.get('secret_env',{}):fail('legacy environment target is repeated')
                current[section][name]=value
            continue
        else:fail('legacy indentation is unsupported')
        if name not in SCALARS or name in current:fail('legacy server field is unknown or repeated')
        current[name]=value
    if seen!={'version','servers'}:fail('legacy document requires version and servers')
    if current is not None:servers.append(finalize(current))
    ids=[item['id'] for item in servers]
    if len(ids)!=len(set(ids)):fail('legacy server id is repeated')
    return servers

def package_id(server_id):
    return 'mcp-client-'+hashlib.sha256(server_id.encode()).hexdigest()

def convert(raw,*,present=True):
    source=raw.decode('utf-8',errors='strict')
    servers=parse(source) if present else []
    converted=[]
    for item in servers:
        identifier=package_id(item['id'])
        config={'version':1,'transport':'stdio' if item['transport']=='stdio' else 'http',
                'request_timeout_ms':item['request_timeout_ms'],'directory':{'max_pages':1024,'max_tools':8192},
                'framing':{'max_frame_bytes':item['max_frame_bytes'],'graceful_shutdown_ms':item['graceful_shutdown_ms']}}
        entry={'legacy_id':item['id'],'previously_enabled':item['enabled'],'package_id':identifier,
               'namespace':'axyndra:'+identifier,'configuration':config,'trusted_read_only_tools':item.get('trusted_read_only_tools',[]),
               'read_only_tools':['t_'+hashlib.sha256(name.encode('utf-8')).hexdigest() for name in item.get('trusted_read_only_tools',[])],
               'protocol_limits':{'max_frame_bytes':4194304,'max_input_bytes':1048576,'max_prepare_bytes':2097152,
                                  'max_result_bytes':3932160,'max_directory_bytes':3932160,'max_tools':8192,
                                  'call_timeout_ms':item['request_timeout_ms']},
               'payload_limits':{'version':1,'max_message_bytes':16777216,'max_input_bytes':4194304,
                                 'max_prepare_bytes':8388608,'max_result_bytes':8388608,'max_write_bytes':4128768}}
        if item['transport']=='stdio':
            entry['endpoint_request']={'service_id':item['id'],'executable':item['command'],'arguments':item.get('args',[]),
                                      'cwd':item.get('cwd',''),'network':{'mode':item.get('network','denied')},
                                      'environment':item.get('env',{}),
                                      'secret_env':{target:'legacy-secret-'+str(index) for index,target in enumerate(item.get('secret_env',{}))},
                                      'credential_refs':['legacy-secret-'+str(index) for index in range(len(item.get('secret_env',{})))],
                                      'lifecycle_policy':{'schema':'axyndra.process-shutdown/v1','grace_ms':item['graceful_shutdown_ms']}}
            entry['credential_source_requests']=[{'ref':'legacy-secret-'+str(index),'source':{'environment':name}} for index,(target,name) in enumerate(item.get('secret_env',{}).items())]
        else:
            credentials=[]
            if item.get('bearer_token_env'):
                credentials.append({'ref':'legacy-bearer','source':{'environment':item['bearer_token_env']},'injection':{'header':'Authorization','prefix':'Bearer '}})
            for index,(header,name) in enumerate(item.get('headers',{}).items()):
                credentials.append({'ref':'legacy-header-'+str(index),'source':{'environment':name},'injection':{'header':header,'prefix':''}})
            config['http']={'url':item['url'],'credential_refs':[binding['ref'] for binding in credentials],
                            'max_response_bytes':item['max_frame_bytes'],'prefer_sse':item['prefer_sse'],
                            'origin':item.get('origin',''),'headers':{}}
            entry['endpoint_request']={'service_id':'session','url':item['url'],'methods':['POST']}
            entry['credential_source_requests']=credentials
        entry['operator_review']=['Build/install the independent package id, disabled; obtain its real immutable content digest.',
            'Choose exact process mounts/cwd, explicit network/HTTP egress/TLS trust and resources; review credential sources without exposing their values.',
            'Publish reviewed generic operator grants with that exact namespace/digest and frozen profile; explicitly approve discovery. Previously enabled is historical data only.']
        converted.append(entry)
    return {'schema':'axyndra.mcp-legacy-draft/v1','source':{'present':present,'sha256':hashlib.sha256(raw).hexdigest(),
            'bytes_base64':base64.b64encode(raw).decode('ascii')},'activation':'none','servers':converted}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path,help='historical version1 mcp.yml; missing file means zero servers')
    arguments=parser.parse_args()
    try:
        try:
            with arguments.source.open('rb') as source:raw=source.read(MAX_SOURCE+1)
            if len(raw)>MAX_SOURCE:fail('historical source exceeds read-only draft input bound')
            present=True
        except FileNotFoundError:raw=b'';present=False
        result=convert(raw,present=present)
    except (MigrationError,UnicodeError,OSError) as error:
        print(json.dumps({'ok':False,'code':'mcp_legacy.draft_rejected','message':str(error)}),file=sys.stderr);return 2
    print(json.dumps(result,ensure_ascii=False,indent=2));return 0

if __name__=='__main__':
    raise SystemExit(main())
