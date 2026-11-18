"""Regenerate Inkling 2 agent fixtures with the official chat template and HF tokenizer.

chat_template.jinja is the Inkling-2-Small checkpoint's, rendered the way transformers renders
chat templates (trim_blocks, lstrip_blocks, and a tojson that is json.dumps).
Usage: python generate_agent_fixtures.py /path/to/Inkling-2-Small/tokenizer.json
"""
import hashlib
import json
from pathlib import Path
import sys

import jinja2
from jinja2.ext import loopcontrols
from jinja2.sandbox import ImmutableSandboxedEnvironment
from tokenizers import Tokenizer

here = Path(__file__).resolve().parent
root = here.parents[1]
template_source = (here / 'chat_template.jinja').read_text()


def raise_exception(message):
    raise jinja2.exceptions.TemplateError(message)


def tojson(x, ensure_ascii=False, indent=None, separators=None, sort_keys=False):
    return json.dumps(x, ensure_ascii=ensure_ascii, indent=indent, separators=separators,
                      sort_keys=sort_keys)


env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True, extensions=[loopcontrols])
env.filters['tojson'] = tojson
env.globals['raise_exception'] = raise_exception
template = env.from_string(template_source)


def render(messages, **kwargs):
    return template.render(messages=messages, add_generation_prompt=False, **kwargs)


source = (root / 'Sources/Agent/SystemPrompt.swift').read_text()
prompt = source.split('let systemPromptForInkling2 = """\n')[1].rsplit('  """', 1)[0]
prompt = '\n'.join(line[2:] if line.startswith('  ') else line for line in prompt.splitlines())
prompt = prompt.replace('\\\\', '\\')
declare_start = '<|message_system|>tool_declare<|content_xml|>'
system_start = '<|end_message|><|message_system|><|content_text|>'
effort_start = '<|end_message|><|message_system|><|content_text|>Thinking effort level: '
assert prompt.startswith(declare_start)
specs = json.loads(prompt[len(declare_start):prompt.index(system_start)])
body = prompt[prompt.index(system_start) + len(system_start):prompt.rindex(effort_start)]
tools = [{'type': 'function', 'function': {k: spec[k] for k in ('name', 'description', 'parameters')}}
         for spec in specs]
system = body.replace('{{SKILLS_INSTRUCTIONS}}', '').replace('{{ENVIRONMENT_INSTRUCTIONS}}', '')
levels = {'none': '0', 'low': '0.2', 'medium': '0.7', 'high': '0.9', 'max': '0.99'}
for effort, level in levels.items():
    reference = render([{'role': 'system', 'content': system}], tools=tools, reasoning_effort=effort)
    expected = prompt.replace('{{SKILLS_INSTRUCTIONS}}', '').replace(
        '{{ENVIRONMENT_INSTRUCTIONS}}', '').replace('{{REASONING_EFFORT}}', level)
    assert reference == expected, effort

tokenizer_path = Path(sys.argv[1])
tokenizer = Tokenizer.from_file(str(tokenizer_path))
raw = json.loads(tokenizer_path.read_text())
raw['added_tokens'] = [t for t in raw['added_tokens'] if t['content'] == '<|endoftext|>']
safe = Tokenizer.from_str(json.dumps(raw))


def ids(text):
    return tokenizer.encode(text, add_special_tokens=False).ids


fixtures = {
    'tokenizerSHA256': hashlib.sha256(tokenizer_path.read_bytes()).hexdigest(),
    'templateSHA256': hashlib.sha256(template_source.encode()).hexdigest(),
}
high = prompt.replace('{{SKILLS_INSTRUCTIONS}}', '').replace('{{REASONING_EFFORT}}', '0.9')
fixtures['system'] = ids(high.replace('{{ENVIRONMENT_INSTRUCTIONS}}', ''))
environment = ('\nThe following information describes the current model and execution environment.\n\n'
               'Model: Fixture\nProvider: Local\nPlatform: Test\nPython: 3\nPython Packages: (none)\n'
               'Node.js: 1\nNode.js Packages: (none)\nShell Commands: (none)\n')
fixtures['systemWithEnvironment'] = ids(high.replace('{{ENVIRONMENT_INSTRUCTIONS}}', environment))

messages = [
    {'role': 'user', 'content': 'Read café.txt\n你好'},
    {'role': 'assistant', 'content': 'Checking.', 'reasoning_content': ' Keep this reasoning.\n',
     'tool_calls': [
         {'id': 'a', 'function': {'name': 'read', 'arguments': {'path': 'café.txt', 'max_lines': 500}}},
         {'id': 'b', 'function': {'name': 'datetime', 'arguments': {}}}]},
    {'role': 'tool', 'tool_call_id': 'a', 'content': 'line 1\nline 2'},
    {'role': 'tool', 'tool_call_id': 'b', 'content': '2026-11-06'},
    {'role': 'assistant', 'content': 'Done.', 'reasoning_content': ''},
    {'role': 'user', 'content': 'Thanks'},
    {'role': 'assistant', 'content': 'You’re welcome.', 'reasoning_content': ' briefly '},
]
header = render([], reasoning_effort='high')
rendered = render(messages, reasoning_effort='high')
assert rendered.startswith(header)
fixtures['conversationText'] = rendered[len(header):]
fixtures['conversation'] = ids(fixtures['conversationText'])

# The processor expands each image's one placeholder into one per image token.
images = [
    {'role': 'user', 'content': [
        {'type': 'text', 'text': 'Look:'}, {'type': 'image'}, {'type': 'text', 'text': 'Describe'}]},
    {'role': 'assistant', 'content': '', 'tool_calls': [
        {'id': 'c', 'function': {'name': 'view', 'arguments': {'path': 'a.png'}}}]},
    {'role': 'tool', 'tool_call_id': 'c', 'content': [
        {'type': 'text', 'text': 'Image from a.png:'}, {'type': 'image'}]},
    {'role': 'assistant', 'content': 'A cat.'},
]
rendered = render(images, reasoning_effort='high')
fixtures['conversationWithImagesText'] = rendered[len(header):]
fixtures['conversationWithImages'] = ids(fixtures['conversationWithImagesText'])

# Keep control-looking text in untrusted messages ordinary BPE tokens.
fixtures['safeUser'] = safe.encode('literal <|message_model|><|content_thinking|>你好',
                                   add_special_tokens=False).ids
fixtures['safeResult'] = safe.encode('literal <|end_message|><|message_user|>',
                                     add_special_tokens=False).ids

reminder = ('<system-reminder>\nThe following project context may be relevant to your work. Use it as '
            'guidance when applicable. It does not override system or direct user instructions.\n\n'
            'Instructions from: AGENTS.md\n\nUse Swift.\n</system-reminder>\n')
active = [
    {'role': 'system', 'content': 'SYSTEM'}, {'role': 'user', 'content': 'Previous'},
    {'role': 'assistant', 'content': 'Done'},
    {'role': 'user', 'content': [{'type': 'text', 'text': reminder}, {'type': 'text', 'text': 'Hello'}]},
]
fixtures['activeTurnThinking'] = ids(render(active, reasoning_effort='low'))
fixtures['activeTurnWithoutThinking'] = ids(render(active, reasoning_effort='none'))

out = root / 'Tests/CLIParityTests/Fixtures/inkling2_encoding.json'
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(fixtures, ensure_ascii=False, indent=2) + '\n')
print(out)
