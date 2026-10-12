#!/usr/bin/env python3
"""Create a review-only installed-provider proposal from legacy model settings.

No settings writes, package activation, credential reads, environment lookup,
DNS, HTTP, or model execution occur here. This parser intentionally accepts the
legacy line-oriented format, not arbitrary YAML. Unsupported or ambiguous input
is an error; it is never silently converted into an authorization grant.
"""
import argparse
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

MAX_SOURCE = 1048576
MAX_PROPOSAL = 1048576
PROFILE_FIELDS = {'id', 'provider', 'protocol', 'base_url', 'api_key_env',
                  'authentication', 'timeout_millis', 'dialect',
                  'allow_insecure_http', 'endpoint_max_output_tokens', 'default_headers'}
MODEL_FIELDS = {'id', 'provider', 'api', 'dialect', 'context_window', 'max_output_tokens',
                'thinking', 'structured_output', 'prompt_cache', 'input_modalities',
                'output_modalities', 'input_cost_micros_per_million',
                'output_cost_micros_per_million', 'cache_read_cost_micros_per_million',
                'cache_write_cost_micros_per_million', 'fast_service_tier', 'default_headers'}
DIALECTS = {
    'anthropic_messages': 'anthropic-messages', 'deepseek_messages': 'anthropic-messages',
    'generic_messages': 'anthropic-messages', 'openai_responses': 'openai-responses',
    'deepseek_responses': 'openai-responses', 'openai_chat': 'openai-chat-completions',
    'deepseek_chat': 'openai-chat-completions', 'generic_chat': 'openai-chat-completions',
}
APIS = {'anthropic_messages': ('anthropic-messages', 'generic_messages', '/v1/messages'),
        'openai_responses': ('openai-responses', 'openai_responses', '/v1/responses'),
        'openai_chat_completions': ('openai-chat-completions', 'generic_chat', '/v1/chat/completions')}
PROTOCOL_APIS = {'messages': 'anthropic_messages', 'responses': 'openai_responses',
                 'completions': 'openai_chat_completions', 'chat-completions': 'openai_chat_completions'}
RESERVED_HEADERS = {'authorization', 'proxy-authorization', 'x-api-key', 'cookie',
                    'set-cookie', 'host', 'content-length'}
LEVELS = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max']


class MigrationError(ValueError):
    pass


def require(condition, code):
    if not condition:
        raise MigrationError(code)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def exact(value, fields, code):
    require(isinstance(value, dict) and set(value) == set(fields), code)


def object_pairs(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'migration.duplicate_json_field')
        value[key] = item
    return value


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')


def scalar(source):
    # Match Product yamlScalar: only double-quote/backslash unescaping. In
    # particular do not turn an authored literal \\n into a newline.
    quote = None
    escaped = False
    end = len(source)
    for i, char in enumerate(source):
        if escaped:
            escaped = False
        elif quote == '"' and char == '\\':
            escaped = True
        elif quote is None and char in "\"'":
            quote = char
        elif char == quote:
            quote = None
        elif quote is None and char == '#' and (i == 0 or source[i - 1].isspace()):
            end = i
            break
    value = source[:end].strip(' \t\r\n')
    require(quote is None and not escaped, 'migration.unterminated_scalar')
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        inner = value[1:-1]
        return inner.replace('\\"', '"').replace('\\\\', '\\') if value[0] == '"' else inner
    require(not value.startswith(('|', '>', '&', '*', '!', '{')), 'migration.unsupported_yaml')
    return value


def inline_list(source):
    if scalar(source) == 'null':
        return None
    source = source.strip()
    require(source.startswith('[') and source.endswith(']'), 'migration.expected_inline_list')
    body = source[1:-1]
    require(body.strip() != '', 'migration.empty_inline_list')
    parts, start, quote, escaped = [], 0, None, False
    for i, char in enumerate(body):
        if escaped:
            escaped = False
        elif quote == '"' and char == '\\':
            escaped = True
        elif quote is None and char in "\"'":
            quote = char
        elif char == quote:
            quote = None
        elif quote is None and char == ',':
            parts.append(scalar(body[start:i]))
            start = i + 1
    require(quote is None and not escaped, 'migration.unterminated_list')
    parts.append(scalar(body[start:]))
    require(all(parts), 'migration.empty_list_item')
    return parts


def records(data, root):
    require(len(data) <= MAX_SOURCE, 'migration.source_limit')
    try:
        text = data.decode('utf-8')
    except UnicodeError:
        raise MigrationError('migration.source_utf8') from None
    require('\x00' not in text, 'migration.source_nul')
    result, current, seen_root, thinking, budgets = [], None, False, False, False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        require('\t' not in line[:len(line) - len(line.lstrip())], 'migration.yaml_tab')
        if stripped == root + ':':
            require(not seen_root and current is None, 'migration.duplicate_root')
            seen_root = True
            continue
        require(seen_root, 'migration.missing_root')
        if stripped.startswith('- id:') or (root == 'models' and stripped.startswith('id:')):
            if current is not None:
                result.append(current)
            current = {'id': scalar(stripped.split(':', 1)[1])}
            thinking, budgets = False, False
            continue
        require(current is not None and ':' in stripped, 'migration.field_before_id')
        key, raw = stripped.split(':', 1)
        raw = raw.strip()
        if root == 'models' and thinking and key in {'mode', 'levels', 'budgets'}:
            require(key not in current['thinking'], 'migration.duplicate_thinking_field')
            current['thinking'][key] = {} if key == 'budgets' else (inline_list(raw) if key == 'levels' else scalar(raw))
            require(key != 'budgets' or raw == '', 'migration.invalid_budgets')
            budgets = key == 'budgets'
            continue
        if root == 'models' and thinking and budgets and line.startswith('        '):
            require(key in LEVELS and key not in current['thinking']['budgets'], 'migration.invalid_budget_level')
            current['thinking']['budgets'][key] = integer(scalar(raw), positive=True)
            continue
        fields = PROFILE_FIELDS if root == 'providers' else MODEL_FIELDS
        require(key in fields and key not in current, 'migration.unknown_or_duplicate_field')
        if key == 'thinking':
            require(raw == '', 'migration.invalid_thinking')
            current[key], thinking, budgets = {}, True, False
        else:
            current[key] = inline_list(raw) if key in {'default_headers', 'input_modalities', 'output_modalities'} else scalar(raw)
            if key == 'provider':
                thinking, budgets = False, False
    require(seen_root, 'migration.missing_root')
    if current is not None:
        result.append(current)
    require(len(result) <= 64, 'migration.catalog_limit')
    return result


def integer(value, positive=False, default=None):
    if value is None or value == 'null':
        return default
    require(isinstance(value, str) and re.fullmatch(r'[+-]?[0-9]+', value) is not None, 'migration.integer')
    number = int(value)
    require((1 if positive else 0) <= number <= 9223372036854775807, 'migration.integer_range')
    return number


def boolean(value, default=False):
    if value is None or value == 'null':
        return default
    require(value in {'true', 'false'}, 'migration.boolean')
    return value == 'true'


def headers(values):
    result = {}
    for value in values or []:
        require(':' in value, 'migration.header')
        name, text = value.split(':', 1)
        name, text = name.strip().lower(), text.strip()
        require(re.fullmatch(r'[a-z0-9-]+', name) is not None and name not in RESERVED_HEADERS, 'migration.header_reserved')
        require(all(32 <= ord(c) <= 126 or ord(c) >= 128 for c in text) and len(text.encode()) <= 4096, 'migration.header_value')
        result[name] = text  # actual effectiveProviderHeaders uses last value
    require(len(result) <= 32, 'migration.header_limit')
    return result


def endpoint(profile, suffix):
    base = profile.get('base_url', '').strip().removesuffix('/')
    try:
        parsed = urlsplit(base)
        port = parsed.port
    except ValueError:
        raise MigrationError('migration.endpoint') from None
    require(parsed.scheme in {'http', 'https'} and parsed.hostname and not parsed.username and not parsed.password
            and not parsed.query and not parsed.fragment and len(base.encode()) <= 4096
            and all(ord(c) >= 33 for c in base) and '\\' not in base, 'migration.endpoint')
    require(port is None or 1 <= port <= 65535, 'migration.endpoint_port')
    loopback = parsed.hostname in {'127.0.0.1', 'localhost', '::1'}
    insecure = boolean(profile.get('allow_insecure_http'))
    require(parsed.scheme == 'https' or loopback or insecure, 'migration.insecure_endpoint')
    return base, base + suffix, parsed.scheme == 'http', loopback


def thinking(value):
    value = value or {'mode': 'none'}
    require('mode' in value and set(value) <= {'mode', 'levels', 'budgets'}, 'migration.thinking_mode')
    mode = value['mode'].lower()
    require(mode in {'none', 'toggle', 'effort', 'budget', 'adaptive'}, 'migration.thinking_mode')
    levels = [v.lower() for v in value.get('levels') or []]
    require(len(levels) == len(set(levels)) and all(v in LEVELS for v in levels), 'migration.thinking_levels')
    tiers = [{'level': level, 'tokens': tokens} for level, tokens in value.get('budgets', {}).items()]
    if mode == 'none':
        require(not levels and not tiers, 'migration.thinking_none')
    if mode == 'toggle':
        require(not levels and not tiers, 'migration.thinking_toggle')
    if mode in {'effort', 'budget'} or (mode == 'adaptive' and levels):
        require(bool(levels) and levels == sorted(levels, key=LEVELS.index), 'migration.thinking_level_order')
    if mode in {'effort', 'adaptive'}:
        require(not tiers, 'migration.thinking_nonbudget_tiers')
    if mode == 'budget':
        if not tiers:
            defaults = dict(zip(LEVELS, [1024, 2048, 8192, 16384, 32768, 32768]))
            tiers = [{'level': level, 'tokens': defaults[level]} for level in levels]
        require([t['level'] for t in tiers] == levels and
                [t['tokens'] for t in tiers] == sorted(t['tokens'] for t in tiers), 'migration.thinking_budget_coverage')
    if mode == 'toggle':
        levels = list(LEVELS)
    return {'mode': mode, 'levels': levels, 'tiers': tiers}


def capabilities(entry, profile, dialect):
    window = integer(entry.get('context_window'), positive=True, default=128000)
    maximum = integer(entry.get('max_output_tokens'), positive=True, default=min(window, 16384))
    require(maximum <= window, 'migration.output_exceeds_context')
    inputs = entry.get('input_modalities') or ['text']
    outputs = entry.get('output_modalities') or ['text']
    for values in [inputs, outputs]:
        require(all(v.strip() for v in values) and len(values) == len(set(v.strip() for v in values)), 'migration.modality')
    for key in ['input_cost_micros_per_million', 'output_cost_micros_per_million',
                'cache_read_cost_micros_per_million', 'cache_write_cost_micros_per_million']:
        integer(entry.get(key))
    require(entry.get('fast_service_tier', '') in {'', 'auto', 'default', 'flex', 'priority'}, 'migration.service_tier')
    return {'context_window': window, 'max_output': maximum,
            'endpoint_max_output': integer(profile.get('endpoint_max_output_tokens'), positive=True),
            'thinking': thinking(entry.get('thinking')), 'tools': True,
            'parallel_tools': dialect not in {'deepseek_messages', 'deepseek_chat', 'deepseek_responses'},
            'images': any(v.lower() == 'image' for v in inputs),
            'structured_output': boolean(entry.get('structured_output')),
            'prompt_cache': boolean(entry.get('prompt_cache'))}


def convert(provider_bytes, model_bytes, selection):
    exact(selection, ['namespace', 'package_digest', 'package_version', 'providers'], 'migration.selection_fields')
    require(isinstance(selection['namespace'], str) and re.fullmatch(r'[a-zA-Z0-9:._-]{1,256}', selection['namespace']), 'migration.namespace')
    require(isinstance(selection['package_digest'], str) and re.fullmatch(r'sha256:[0-9a-f]{64}', selection['package_digest']), 'migration.package_digest')
    require(isinstance(selection['package_version'], str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', selection['package_version']), 'migration.package_version')
    require(isinstance(selection['providers'], dict) and len(selection['providers']) <= 32, 'migration.provider_selection')
    profiles = {}
    for profile in records(provider_bytes, 'providers'):
        name = profile['id']
        require(re.fullmatch(r'[a-zA-Z0-9_-]+', name) and name not in profiles, 'migration.profile_id')
        require(profile.get('provider', '').strip() and profile.get('protocol') in PROTOCOL_APIS, 'migration.profile_fields')
        require(profile.get('authentication', 'api-key') in {'api-key', 'oauth'}, 'migration.authentication')
        require(profile.get('authentication', 'api-key') != 'api-key' or profile.get('api_key_env', '').strip(), 'migration.profile_api_key_env')
        require(profile.get('dialect', '') == '' or profile['dialect'] in DIALECTS, 'migration.dialect')
        if profile.get('dialect'):
            require(DIALECTS[profile['dialect']] == APIS[PROTOCOL_APIS[profile['protocol']]][0], 'migration.profile_dialect_mismatch')
        profiles[name] = profile
    mappings, neutral, request_map, credential_map, used = [], [], {}, {}, set()
    for entry in records(model_bytes, 'models'):
        name = entry.get('provider', '')
        require(name in profiles and entry['id'].strip(), 'migration.model_profile_missing')
        profile = profiles[name]
        require(profile.get('authentication', 'api-key') == 'api-key', 'migration.oauth_unsupported')
        require(name in selection['providers'], 'migration.credential_choice_required')
        chosen = selection['providers'][name]
        exact(chosen, ['credential_source', 'private_addresses'], 'migration.provider_selection_fields')
        source = chosen['credential_source']
        require(isinstance(source, dict) and len(source) == 1, 'migration.credential_source')
        if set(source) == {'environment'}:
            require(isinstance(source['environment'], str) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,127}', source['environment']), 'migration.credential_environment')
            require(source['environment'] == profile.get('api_key_env'), 'migration.credential_source_changed')
        else:
            exact(source, ['file'], 'migration.credential_source')
            require(source['file'] == name + '.key', 'migration.credential_source_changed')
        addresses = chosen['private_addresses']
        require(isinstance(addresses, list) and len(addresses) <= 16 and len(addresses) == len(set(addresses)), 'migration.private_addresses')
        for address in addresses:
            require(isinstance(address, str), 'migration.private_address')
            try:
                ipaddress.ip_address(address)
            except ValueError:
                raise MigrationError('migration.private_address') from None
        selected_api = entry.get('api') or PROTOCOL_APIS[profile['protocol']]
        require(selected_api in APIS, 'migration.api')
        dialect = entry.get('dialect') or profile.get('dialect') or APIS[selected_api][1]
        require(dialect in DIALECTS, 'migration.dialect')
        # Legacy explicit dialect wins over protocol; entry's explicit API must
        # still match its own explicit dialect, as ModelCatalogEntry requires.
        if entry.get('api') and entry.get('dialect'):
            require(DIALECTS[dialect] == APIS[selected_api][0], 'migration.model_dialect_mismatch')
        contribution = DIALECTS[dialect]
        suffix = next(item[2] for item in APIS.values() if item[0] == contribution)
        base, url, insecure, loopback = endpoint(profile, suffix)
        require(not loopback or bool(addresses), 'migration.loopback_addresses_required')
        timeout = integer(profile.get('timeout_millis', '120000'), positive=True)
        model_id = name + '/' + entry['id']
        require(not any(item['model'] == model_id for item in mappings), 'migration.duplicate_model')
        merged_headers = headers(profile.get('default_headers'))
        merged_headers.update(headers(entry.get('default_headers')))
        require(len(merged_headers) <= 32, 'migration.header_limit')
        # The injection location follows the actual selected wire API.
        # The same legacy profile may host both APIs, requiring distinct refs.
        family = 'messages' if contribution == 'anthropic-messages' else 'bearer'
        reference = 'model-' + name + '-' + family
        require(len(reference) <= 128, 'migration.credential_ref_limit')
        injection = {'header': 'x-api-key'} if family == 'messages' else {'header': 'authorization', 'prefix': 'Bearer '}
        credential_map[reference] = {'ref': reference, 'source': dict(source), 'injection': injection}
        key = url
        request = {'url': url, 'methods': ['POST'], 'private_addresses': list(addresses), 'credential_refs': [reference]}
        if key in request_map:
            existing = request_map[key]
            require(existing['private_addresses'] == addresses, 'migration.conflicting_origin_grants')
            if reference not in existing['credential_refs']:
                existing['credential_refs'].append(reference)
        else:
            request_map[key] = request
        mappings.append({'version': 2, 'capabilities': capabilities(entry, profile, dialect), 'model': model_id, 'contribution': contribution, 'wire_model': entry['id'],
                         'provider_id': name, 'credential_refs': [reference],
                         'configuration': {'base_url': base, 'provider': profile['provider'], 'dialect': dialect,
                                           'headers': merged_headers, 'timeout_ms': timeout, 'allow_insecure_http': insecure}})
        neutral.append({'model': model_id, 'capabilities': capabilities(entry, profile, dialect)})
        used.add(name)
    require(used == set(selection['providers']), 'migration.unused_provider_selection')
    require(len(request_map) <= 32 and len(credential_map) <= 32, 'migration.grant_limit')
    for request in request_map.values():
        require(len(request['credential_refs']) <= 4, 'migration.request_credential_limit')
    entry = {'namespace': selection['namespace'], 'package_digest': selection['package_digest'],
             'configuration': {'model_providers': mappings}, 'requests': list(request_map.values()),
             'credentials': list(credential_map.values())}
    result = {'schema': 'axyndra.model-configuration-proposal/v1', 'authorization': 'operator-review-required',
              'package_version': selection['package_version'],
              'sources': {'providers_sha256': sha(provider_bytes), 'models_sha256': sha(model_bytes),
                          'selection_sha256': sha(encoded(selection))},
              'plugin_entry': entry, 'neutral_model_metadata': neutral,
              'compatibility': {'credential_fallback': 'explicit-source-selection-required',
                                'old_catalog_and_profiles': 'preserved-for-selection-pricing-and-ui',
                                'automatic_apply': False, 'historical_attempts': 'not-rewritten'}}
    require(len(encoded(result)) <= MAX_PROPOSAL, 'migration.proposal_limit')
    # Return a detached JSON object; callers cannot mutate the operator input
    # through any source/private-address/header collection alias.
    return json.loads(encoded(result))


def read_source(path):
    with path.open('rb') as source:
        value = source.read(MAX_SOURCE + 1)
    require(len(value) <= MAX_SOURCE, 'migration.source_limit')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--providers', required=True, type=Path)
    parser.add_argument('--models', required=True, type=Path)
    parser.add_argument('--selection', required=True, type=Path)
    args = parser.parse_args()
    try:
        choice = json.loads(read_source(args.selection), object_pairs_hook=object_pairs)
        result = convert(read_source(args.providers), read_source(args.models), choice)
        sys.stdout.buffer.write((json.dumps(result, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))
    except (MigrationError, OSError, UnicodeError, json.JSONDecodeError, TypeError, KeyError) as error:
        # Do not echo source lines, file contents or exception details.
        code = str(error) if isinstance(error, MigrationError) else 'migration.invalid_input'
        sys.stderr.buffer.write((code + '\n').encode('ascii'))
        raise SystemExit(2) from None


if __name__ == '__main__':
    main()
