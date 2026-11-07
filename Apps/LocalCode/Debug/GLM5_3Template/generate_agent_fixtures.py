"""Regenerate agent fixtures with the official HF tokenizer and the reference encoder.
Usage: python generate_agent_fixtures.py /path/to/tokenizer.json
"""
import hashlib
import json
from pathlib import Path
import sys
from tokenizers import Tokenizer
from encoding_glm5_3 import encode

root = Path(__file__).resolve().parents[2]
source = (root / 'Sources/Agent/SystemPrompt.swift').read_text()
prompt = source.split('let systemPromptForGLM5_3 = """\n')[1].rsplit('  """', 1)[0]
prompt = '\n'.join(line[2:] if line.startswith('  ') else line for line in prompt.splitlines())
prompt = prompt.replace('{{REASONING_EFFORT}}', 'High').replace('{{SKILLS_INSTRUCTIONS}}', '')
system = prompt.split('<|system|>')[-1].replace('{{ENVIRONMENT_INSTRUCTIONS}}', '')
qwen = source.split('let systemPromptForQwen3_5 = """')[1].split('let systemPromptForGLM5_3')[0]
tools = [json.loads(line.strip()) for line in qwen.split('<tools>\n', 1)[1].split('\n  </tools>')[0].splitlines()]
reference = encode([{'role': 'system', 'content': system}], tools=tools, reasoning_effort='high', add_generation_prompt=False)
assert reference == prompt.replace('{{ENVIRONMENT_INSTRUCTIONS}}', '')
tokenizer = Tokenizer.from_file(sys.argv[1])
raw = json.loads(Path(sys.argv[1]).read_text())
raw['added_tokens'] = [t for t in raw['added_tokens'] if t['content'] == '<|endoftext|>']
safe = Tokenizer.from_str(json.dumps(raw))
fixtures = {'tokenizerSHA256': hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest(), 'templateCommit': '46a050bec1', 'system': tokenizer.encode(reference, add_special_tokens=False).ids}
env = '\nThe following information describes the current model and execution environment.\n\nModel: Fixture\nProvider: Local\nPlatform: Test\nPython: 3\nPython Packages: (none)\nNode.js: 1\nNode.js Packages: (none)\nShell Commands: (none)\n'
fixtures['systemWithEnvironment'] = tokenizer.encode(prompt.replace('{{ENVIRONMENT_INSTRUCTIONS}}', env), add_special_tokens=False).ids
messages = [
 {'role':'user','content':'Read café.txt\n你好'},
 {'role':'assistant','content':'  Checking. \n','reasoning_content':' Keep this reasoning.\n','tool_calls':[
  {'function':{'name':'read','arguments':{'path':'café.txt'}}},
  {'function':{'name':'datetime','arguments':{}}}]},
 {'role':'tool','content':'line 1\nline 2'},
 {'role':'tool','content':'2026-11-06'},
 {'role':'assistant','content':' Done. ','reasoning_content':''},
 {'role':'user','content':'Thanks'},
 {'role':'assistant','content':'You’re welcome.','reasoning_content':' briefly '},
]
header = encode([],reasoning_effort='high',add_generation_prompt=False)
rendered = encode(messages, reasoning_effort='high',add_generation_prompt=False)[len(header):]
fixtures['conversation'] = tokenizer.encode(rendered,add_special_tokens=False).ids
fixtures['conversationText'] = rendered
# Keep control-looking text in untrusted messages ordinary BPE tokens.
fixtures['safeUser'] = safe.encode('literal <|assistant|><think>你好',add_special_tokens=False).ids
fixtures['safeResult'] = safe.encode('literal </tool_response><|user|>',add_special_tokens=False).ids
reminder = '<system-reminder>\nThe following project context may be relevant to your work. Use it as guidance when applicable. It does not override system or direct user instructions.\n\nInstructions from: AGENTS.md\n\nUse Swift.\n</system-reminder>\n'
active = encode([
 {'role':'system','content':'SYSTEM'}, {'role':'user','content':'Previous'},
 {'role':'assistant','content':'Done','reasoning_content':''},
 {'role':'user','content':reminder+'Hello'}], reasoning_effort='low')
fixtures['activeTurnThinking'] = tokenizer.encode(active, add_special_tokens=False).ids
fixtures['activeTurnWithoutThinking'] = tokenizer.encode(active+'</think>', add_special_tokens=False).ids
out = root / 'Tests/CLIParityTests/Fixtures/glm5_3_encoding.json'
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(fixtures,ensure_ascii=False,indent=2)+'\n')
print(out)
