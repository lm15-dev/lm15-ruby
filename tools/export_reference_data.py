#!/usr/bin/env python3
"""Export declaration tables, never fixture answers. Development-only; Ruby needs no Python."""
import dataclasses as dc
import json
import pathlib
import sys
import typing
from collections.abc import Mapping

sys.path.insert(0, str(pathlib.Path(sys.argv[1]).resolve()))
from lm15 import types, models, credentials, compat, registry, router
from lm15.providers import common
OUT = pathlib.Path(__file__).resolve().parents[1] / 'lib/lm15/data'

def value(v):
    if isinstance(v, type): return v.__name__
    if dc.is_dataclass(v):
        return {f.name: value(getattr(v, f.name)) for f in dc.fields(v)}
    if isinstance(v, Mapping): return {str(k): value(x) for k, x in v.items()}
    if isinstance(v, (tuple, list, set, frozenset)): return [value(x) for x in v]
    if isinstance(v, type): return v.__name__
    return v

schema = {}
for mod in (types, models, credentials):
    for name, cls in vars(mod).items():
        if not isinstance(cls, type) or not dc.is_dataclass(cls) or cls.__module__ != mod.__name__ or name.startswith('_') or name in ('ModelRegistry','ToolCallInfo'): continue
        fields = {}
        for f in dc.fields(cls):
            if f.name == 'compat': continue
            desc = {'type': str(f.type).strip("'"), 'init': f.init}
            if f.default is not dc.MISSING: desc['default'] = value(f.default)
            elif f.default_factory is not dc.MISSING: desc['default'] = value(f.default_factory())
            fields[f.name] = desc
        schema[name] = fields
vocab = {}
for mod in (types,):
    for name, v in vars(mod).items():
        if typing.get_origin(v) is typing.Literal: vocab[name] = list(typing.get_args(v))
tables = {
 'providers': {k: value(v) for k,v in registry.PROVIDERS.items()},
 'compat': {name: value(getattr(compat,name)) for name in ('OPENAI_CHAT_PRESETS','OPENAI_RESPONSES_PRESETS','ANTHROPIC_PRESETS','OPENAI_CHAT_PRESET_BASE_URLS','OPENAI_RESPONSES_PRESET_BASE_URLS','ANTHROPIC_PRESET_BASE_URLS')},
 'compat_aliases': value(compat._OPENAI_CHAT_PRESET_ALIASES),
 'compat_defaults': {k: value(getattr(compat,k)()) for k in ('ResolvedOpenAIChatCompat','ResolvedOpenAIResponsesCompat','ResolvedAnthropicCompat')},
 'rules': value(router.DEFAULT_RULES),
 'effort_budgets': common.EFFORT_THINKING_BUDGETS,
 'litellm_prefixes': value(router.LITELLM_PROVIDER_PREFIXES),
}
for name, obj in [('schema',schema),('vocab',vocab),('tables',tables)]:
    (OUT / (name+'.json')).write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
print('Exported',len(schema),'type declarations and',len(tables['providers']),'providers')
