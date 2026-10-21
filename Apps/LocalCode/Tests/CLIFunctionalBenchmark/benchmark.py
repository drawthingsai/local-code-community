import argparse
import hashlib
import http.server
import json
from pathlib import Path
import re
import signal
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--cli', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--model-store', type=Path, default=Path.home() / 'Documents/Models/qwen_3.8_27b_i4x.ckpt')
parser.add_argument('--tokenizer-dir', type=Path, help='Directory with vocab.json and merges.txt; required for raw benchmarks.')
parser.add_argument('--stage', choices=['surface', 'remote', 'remote-controls', 'local', 'raw'], required=True)
parser.add_argument('--filter', default='')
args = parser.parse_args()
CLI = str(Path(args.cli).resolve())
OUT = args.output.resolve()
OUT.mkdir(parents=True, exist_ok=True)
MODEL = str(args.model_store.resolve())
if args.stage == 'raw' and args.tokenizer_dir is None:
    parser.error('--tokenizer-dir is required for raw benchmarks')
with open(CLI, 'rb') as binary:
    SHA = hashlib.file_digest(binary, 'sha256').hexdigest()
RESULTS = OUT / (args.stage + '-results.jsonl')
completed_results = []

def project(name):
    p = OUT / 'projects' / name
    p.mkdir(parents=True, exist_ok=True)
    return p

def run(name, argv, *, expected=0, stdin=None, contains=(), check=None, timeout=180,
        cancel=None):
    if args.filter and args.filter not in name:
        return None
    folder = OUT / args.stage / name
    attempt = 1
    while folder.exists():
        attempt += 1
        folder = OUT / args.stage / f'{name}-attempt-{attempt}'
    folder.mkdir(parents=True, exist_ok=True)
    record_path = folder / 'record.json'
    argv = [str(v).replace('@RESULT@', str(record_path)) for v in argv]
    if '--result-json' in argv:
        record_path = Path(argv[len(argv) - 1 - argv[::-1].index('--result-json') + 1])
    start = time.monotonic()
    result = {'case': name, 'attempt': attempt, 'stage': args.stage, 'binary_sha256': SHA,
              'log_directory': str(folder),
              'command': [CLI, *argv], 'started_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    with (folder / 'stdout').open('w') as stdout, (folder / 'stderr').open('w') as stderr:
        p = subprocess.Popen([CLI, *argv], cwd=OUT, stdin=subprocess.PIPE,
                             stdout=stdout, stderr=stderr, text=True)
        try:
            if cancel:
                sig, marker = cancel
                deadline = start + timeout
                while p.poll() is None and time.monotonic() < deadline:
                    if marker in (folder / 'stderr').read_text(errors='replace'):
                        break
                    time.sleep(.05)
                assert p.poll() is None, 'Process ended before cancellation'
                assert marker in (folder / 'stderr').read_text(errors='replace'), 'Cancellation marker missing'
                cancel_start = time.monotonic()
                p.send_signal(sig)
                p.communicate(timeout=90)
                result['cancel_seconds'] = time.monotonic() - cancel_start
            else:
                p.communicate(input=stdin, timeout=timeout)
        except BaseException as e:
            if p.poll() is None:
                p.send_signal(signal.SIGTERM)
                try:
                    p.communicate(timeout=30)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.communicate()
            result['harness_error'] = str(e)
    result['seconds'] = time.monotonic() - start
    result['exit'] = p.returncode
    text = (folder / 'stdout').read_text(errors='replace') + (folder / 'stderr').read_text(errors='replace')
    failures = []
    record = None
    try:
        if record_path.exists():
            record = json.loads(record_path.read_text())
    except (ValueError, OSError) as error:
        failures.append('Invalid saved JSON: ' + str(error))
    if 'harness_error' in result:
        failures.append(result['harness_error'])
    if p.returncode != expected:
        failures.append(f'expected exit {expected}, got {p.returncode}: {text[-1500:]}')
    for value in contains:
        if value not in text:
            failures.append('missing output: ' + value)
    if record:
        result['agent_seconds'] = record['durationMilliseconds'] / 1000
        result['non_agent_seconds'] = result['seconds'] - result['agent_seconds']
        result['requests'] = record.get('requests')
        result['generated_tokens'] = record.get('generatedTokens')
        result['final_text'] = record.get('finalText')
    if check:
        try:
            check(record, text)
        except Exception as e:
            failures.append(str(e) or type(e).__name__)
    result['passed'] = not failures
    result['failures'] = failures
    completed_results.append(result)
    with RESULTS.open('a') as f:
        f.write(json.dumps(result) + '\n')
    print(('PASS' if result['passed'] else 'FAIL'), name, round(result['seconds'], 3), failures, flush=True)
    return record

def require(value, description):
    assert value, description

def tool_check(names, marker=None):
    def check(record, text):
        require(record is not None, 'Missing saved record')
        calls = []
        responses = []
        for entry in record['state']['transcript']:
            for c in entry.get('content', []):
                if c['type'] == 'tool_call':
                    calls.append(c['tool_call'])
                if c['type'] == 'tool_result':
                    responses.append(c['tool_result'])
        require({c['id'] for c in calls} == {r['toolCallID'] for r in responses},
                'Saved tool calls and results do not match')
        serialized = json.dumps(record['state']['transcript'])
        for name in names:
            require('"name": "' + name + '"' in serialized, 'Missing tool call ' + name)
        require('"isError": true' not in serialized, 'Tool returned isError')
        require('exit=127' not in serialized and 'command not found' not in serialized,
                'Embedded command not found')
        if marker:
            require(marker in record['finalText'], 'Final response missing ' + marker)
    return check

def remote(name, message, *, names=(), marker='BENCH_OK', extra=(), setup=None,
           check=None, input_mode='message', repeat=1, expected=0, cancel=None, discover=False):
    if args.filter and args.filter not in name:
        return
    p = project(name)
    if setup:
        setup(p)
    for i in range(repeat):
        argv = ['remote-agent', '--provider', 'anthropic', '--model', 'claude-sonnet-4-6',
                '--project', p, '--reasoning-effort', 'low', '--maximum-rounds', '12',
                '--web-search-provider', 'disabled', '--trace', '--result-json', '@RESULT@']
        if not discover:
            argv += ['--context-window-tokens', '200000', '--maximum-output-tokens', '1024']
        if input_mode == 'file':
            prompt = OUT / (name + '-prompt.txt')
            prompt.write_text(message)
            argv += ['--prompt-file', prompt]
        elif input_mode == 'stdin':
            argv += ['--prompt-file', '-']
        else:
            argv += ['--message', message]
        def validate(r, t):
            tool_check(names, marker)(r, t)
            if check:
                check(p, r, t)
        run(name + (f'-{i+1}' if repeat > 1 else ''), argv + list(extra),
            check=validate, stdin=message if input_mode == 'stdin' else None,
            expected=expected, cancel=cancel)

if args.stage == 'surface':
    for cmd in [[], ['generate'], ['models'], ['local-agent'], ['remote-agent'], ['auth'],
                ['auth', 'login'], ['auth', 'status'], ['auth', 'logout']]:
        for n in range(5):
            run('help-' + ('-'.join(cmd) or 'root') + '-' + str(n+1), cmd + ['--help'], contains=['USAGE:'])
    p = project('surface')
    local = ['local-agent', '--model', 'qwen_3.8_27b_i4x.ckpt', '--project', p]
    remote_base = ['remote-agent', '--provider', 'anthropic', '--model', 'claude-sonnet-4-6', '--project', p]
    run('models-installed', ['models'], contains=['qwen_3.8_27b_i4x.ckpt\tinstalled'])
    run('models-empty-directory', ['models', '--models-dir', p], contains=['qwen_3.8_27b_i4x.ckpt\tmissing'])
    run('auth-status', ['auth', 'status', '--provider', 'anthropic'], contains=['Saved OAuth credentials'])
    cases = [
        ('prompt-conflict', local + ['--message', 'x', '--prompt-file', '-'], None, 'exactly one'),
        ('stdin-empty', local + ['--prompt-file', '-'], ' \n', 'prompt is empty'),
        ('checkpoint-missing', local + ['--message', 'x', '--model-store', '/missing/model.ckpt'], None, 'does not exist'),
        ('model-unknown', ['local-agent', '--model', 'MISSING', '--message', 'x'], None, 'Unknown model'),
        ('budget-invalid', local + ['--message', 'x', '--maximum-generated-tokens', '0'], None, 'positive'),
        ('thinking-invalid', local + ['--message', 'x', '--thinking-budget=-1'], None, 'between'),
        ('prefill-invalid', local + ['--message', 'x', '--chunked-prefill-max-length', '1'], None, 'between'),
        ('streaming-qwen', local + ['--message', 'x', '--weights-streaming', '8'], None, 'DeepSeek'),
        ('workspace-outside', local + ['--message', 'x', '--workspace', project('other')], None, 'inside'),
        ('key-override-missing', remote_base + ['--message', 'x', '--api-key-environment', 'CLI_BENCH_UNSET'], None, 'CLI_BENCH_UNSET'),
        ('kagi-key-missing', remote_base + ['--message', 'x', '--web-search-provider', 'kagi', '--web-search-api-key-environment', 'CLI_BENCH_UNSET'], None, 'CLI_BENCH_UNSET'),
        ('remote-context-invalid', remote_base + ['--message', 'x', '--context-window-tokens', '1'], None, '4096'),
        ('remote-rounds-invalid', remote_base + ['--message', 'x', '--maximum-rounds', '0'], None, 'greater than zero'),
        ('remote-compaction-invalid', remote_base + ['--message', 'x', '--compaction-threshold', '.2'], None, '0.35'),
        ('auth-custom-endpoint', ['auth', 'login', '--provider', 'anthropic', '--base-url', 'https://example.com'], None, 'official endpoint'),
        ('auth-unsupported-provider', ['auth', 'login', '--provider', 'openrouter'], None, 'supports'),
        ('raw-zero', ['generate', '--max-new-tokens', '0'], None, 'positive'),
        ('raw-modes-conflict', ['generate', '--ttft-tokens', '16', '--mtp-generate'], None, 'only one'),
    ]
    for name, argv, stdin, content in cases:
        run(name, argv, expected=64, stdin=stdin, contains=[content])

if args.stage == 'remote':
    remote('plain-text', 'Reply exactly BENCH_OK. Do not use tools.', repeat=3)
    remote('prompt-file', 'Reply exactly BENCH_OK. Do not use tools.', input_mode='file')
    remote('stdin', 'Reply exactly BENCH_OK. Do not use tools.', input_mode='stdin')
    remote('write', 'Call write to create output.txt containing exactly WRITE_42. Then reply BENCH_OK.', names=['write'],
           check=lambda p,r,t: require((p/'output.txt').read_text() == 'WRITE_42', 'Wrong written bytes'))
    setup = lambda p: (p/'input.txt').write_text('first ALPHA\nsecond BETA\nthird GAMMA\n')
    remote('read', 'Use read on input.txt. Reply with its third line followed by BENCH_OK.', names=['read'], setup=setup,
           check=lambda p,r,t: require('third GAMMA' in r['finalText'], 'Read contents incorrect'))
    remote('more', 'Read input.txt with max_lines=1, then call more with count=2. Reply with the third line and BENCH_OK.', names=['read','more'], setup=setup,
           check=lambda p,r,t: require('third GAMMA' in r['finalText'], 'Continuation incorrect'))
    remote('edit', 'Use edit to replace second BETA with second DELTA in input.txt. Reply BENCH_OK.', names=['edit'], setup=setup,
           check=lambda p,r,t: require((p/'input.txt').read_text() == 'first ALPHA\nsecond DELTA\nthird GAMMA\n', 'Edit corrupted bytes'))
    remote('search', 'Use search query BETA in input.txt. Reply with the matching line and BENCH_OK.', names=['search'], setup=setup,
           check=lambda p,r,t: require('second BETA' in r['finalText'], 'Search incorrect'))
    remote('list', 'Use list on . and report the input file name and BENCH_OK.', names=['list'], setup=setup,
           check=lambda p,r,t: require('input.txt' in r['finalText'], 'List incorrect'))
    remote('datetime', 'Use datetime with timezone UTC and report the resulting UTC date and BENCH_OK.', names=['datetime'])
    remote('memory', 'Using only memory tools, append MEM_42 to target memory, read it, replace MEM_42 with MEM_43, read it, remove MEM_43, and read again. Confirm the final memory has no entries. Reply BENCH_OK.', names=['memory'],
           check=lambda p,r,t: require('MEM_43' not in (p/'.localc/MEMORY.md').read_text(), 'Memory removal failed'))
    commands = [
        ('bash-printf', 'printf PRINTF_OK', 'PRINTF_OK'),
        ('bash-echo', 'echo ECHO_OK', 'ECHO_OK'),
        ('bash-shell', 'printf "alpha\\nbeta\\n" | sort > sorted.txt; cat sorted.txt', 'beta'),
        ('python', '''python3 -c 'import json; print(json.dumps({"value": 6 * 7}))' ''', '42'),
        ('node', '''node -e 'console.log(JSON.stringify({value: 6 * 7}))' ''', '42'),
        ('npm', 'npm --version', '11.19.0'),
        ('npx', 'npx --version', '11.19.0'),
        ('lean', "check_lean 'theorem bench_truth : True := by trivial'", 'status: valid'),
        ('z3', 'z3 --version', 'Z3 version'),
    ]
    for name, command, output in commands:
        remote(name, 'Call bash exactly once with command ' + json.dumps(command.strip()) + '. Do not retry or substitute commands if it fails. Report the actual output, then BENCH_OK.', names=['bash'],
               check=lambda p,r,t,output=output: require(output in json.dumps(r['state']['transcript']), 'Missing command output ' + output))
    def npm_setup(p):
        (p/'package.json').write_text(json.dumps({'name':'cli-bench-project','version':'1.0.0','private':True,'scripts':{'bench':'node bench.cjs'}}))
        (p/'bench.cjs').write_text('require("fs").writeFileSync("npm-output.txt", "NPM_RUN_47"); console.log("NPM_RUN_47");\n')
    remote('package-npm-run', 'Use bash exactly once to run npm run bench. Report its actual output, then BENCH_OK.',
           setup=npm_setup,names=['bash'],check=lambda p,r,t: require((p/'npm-output.txt').read_text()=='NPM_RUN_47','npm script did not execute'))
    def npx_setup(p):
        npm_setup(p)
        module=p/'node_modules/cli-bench'
        module.mkdir(parents=True,exist_ok=True)
        (module/'package.json').write_text(json.dumps({'name':'cli-bench','version':'1.0.0','bin':{'cli-bench':'main.cjs'}}))
        script=module/'main.cjs'
        script.write_text('#!/usr/bin/env node\nrequire("fs").writeFileSync("npx-output.txt", "NPX_RUN_58"); console.log("NPX_RUN_58");\n')
        script.chmod(0o755)
        link=p/'node_modules/.bin/cli-bench'
        link.parent.mkdir(exist_ok=True)
        if not link.exists():
            link.symlink_to('../cli-bench/main.cjs')
    remote('package-npx-local', 'Use bash exactly once to run npx --no-install cli-bench. Do not install or download anything. Report actual output, then BENCH_OK.',
           setup=npx_setup,names=['bash'],check=lambda p,r,t: require((p/'npx-output.txt').read_text()=='NPX_RUN_58','npx local command did not execute'))
    remote('check-smt', 'Call check_smt with code (assert false). Report unsat and BENCH_OK.', names=['check_smt'],
           check=lambda p,r,t: require('unsat' in r['finalText'], 'Expected unsat'))
    remote('job-wait', 'Call bash with command "sleep 2; printf JOB_OK", refresh_sec=0.01, timeout_sec=15. Call bash_status on its returned job ID, then bash_wait with refresh_sec=5 to collect completion. Report JOB_OK and BENCH_OK.', names=['bash','bash_status','bash_wait'])
    remote('job-stop', 'Call bash with command "sleep 20; printf SHOULD_NOT_RUN", refresh_sec=0.01, timeout_sec=30. Call bash_status on its job ID, then bash_stop to stop it immediately. Reply BENCH_OK.', names=['bash','bash_status','bash_stop'])
    remote('search-disabled', 'Is websearch available in your tool list? Do not invoke other tools. Report whether it is disabled, then finish BENCH_OK.',
           check=lambda p,r,t: require('disabled' in r['finalText'].lower() and '\"name\": \"websearch\"' not in json.dumps(r['state']['transcript']), 'Disabled search not respected'))
    remote('search-live', 'Call websearch for query "Swift programming language official documentation". Report a swift.org result URL, then BENCH_OK.', names=['websearch'], extra=['--web-search-provider','duckduckgo'],
           check=lambda p,r,t: require('swift.org' in r['finalText'], 'Missing relevant search result'))
    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body=b'<html><head><title>CLI fixture</title></head><body><h1>WEB_FETCH_73</h1><p>Benchmark fixture.</p></body></html>'
            self.send_response(200); self.send_header('Content-Type','text/html'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *values):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        remote('webfetch', f'Call webfetch for http://127.0.0.1:{server.server_port}/page. Quote the text after the # heading marker verbatim. Append the literal marker BENCH_OK to your answer.', names=['webfetch'],
               check=lambda p,r,t: require('WEB_FETCH_73' in r['finalText'], 'Wrong fetched page'))
    finally:
        server.shutdown()

    remote('metadata-auto', 'Reply exactly BENCH_OK. Do not use tools.', discover=True)
    for effort in ['medium','high','max']:
        remote('reasoning-' + effort, 'What is 19 * 23? Reply with the number followed by BENCH_OK.',
               extra=['--reasoning-effort', effort],
               check=lambda p,r,t: require('437' in r['finalText'], 'Arithmetic incorrect'))
    remote('runtime-ios-system', 'Call bash to run python3 -c \'print("RUNTIME_42")\'. Report its output, then BENCH_OK.',
           names=['bash'], extra=['--runtime','ios-system'],
           check=lambda p,r,t: require('RUNTIME_42' in r['finalText'], 'Runtime output missing'))

    def skills(p):
        (p/'AGENTS.md').write_text('If asked for the project marker, reply OLD_INSTRUCTION.\n')
        (p/'AGENTS.override.md').write_text('The project marker is PROJECT_83. Include it when asked.\n')
        skill = p/'.agents/skills/bench-skill'
        skill.mkdir(parents=True, exist_ok=True)
        (skill/'SKILL.md').write_text('---\nname: bench-skill\ndescription: Use when asked for the benchmark skill marker.\n---\nThe benchmark skill marker is SKILL_94. Read this file to obtain it.\n')
    remote('project-and-skill', 'Report the project marker from project instructions, then use bench-skill to report its marker. Append BENCH_OK.',
           setup=skills, names=['read'], check=lambda p,r,t: require('PROJECT_83' in r['finalText'] and 'SKILL_94' in r['finalText'] and 'OLD_INSTRUCTION' not in r['finalText'], 'Instructions or skill incorrect'))

    if not args.filter or 'resume' in args.filter:
        p = project('remote-resume')
        saved = OUT / 'remote-resume.json'
        base = ['remote-agent','--provider','anthropic','--model','claude-sonnet-4-6',
                '--project',p,'--reasoning-effort','low','--context-window-tokens','200000',
                '--maximum-output-tokens','1024','--web-search-provider','disabled','--result-json','@RESULT@']
        first = run('resume-initial', base + ['--message','Remember the private benchmark marker ORCHID_639. Reply SAVED.'], contains=['SAVED'])
        if first:
            saved.write_text(json.dumps(first))
            old = len(first['state']['transcript'])
            run('resume-same-file', base[:-2] + ['--resume',saved,'--result-json',saved,'--message','What marker did I ask you to remember? Reply only that marker.'],
                contains=['ORCHID_639'], check=lambda r,t: require(len(json.loads(saved.read_text())['state']['transcript']) > old, 'Resume did not append transcript'))
            run('resume-wrong-project', base + ['--project',project('wrong-remote-project'),'--resume',saved,'--message','x'], expected=64, contains=['different provider, model, endpoint, or project'])

if args.stage == 'remote-controls':
    p = project('remote-controls')
    base = ['remote-agent','--provider','anthropic','--model','claude-sonnet-4-6',
            '--project',p,'--reasoning-effort','low','--context-window-tokens','200000',
            '--maximum-output-tokens','1024','--web-search-provider','disabled','--trace','--result-json','@RESULT@']
    def template_setup(p):
        template=p/'.localc/templated_system_prompt_claude-sonnet-4-6.md'
        template.parent.mkdir(exist_ok=True)
        template.write_text('The custom template marker is TEMPLATE_96. Answer the user concisely.\n')
    remote('custom-template', 'What is the custom template marker? Append BENCH_OK.', setup=template_setup,
           check=lambda p,r,t: require('TEMPLATE_96' in r['finalText'], 'Custom template not loaded'))
    def ancestor_setup(p):
        skill = p.parent/'.agents/skills/ancestor-bench'
        skill.mkdir(parents=True,exist_ok=True)
        (skill/'SKILL.md').write_text('---\nname: ancestor-bench\ndescription: Use to find the ancestor marker.\n---\nThe ancestor marker is ANCESTOR_35.\n')
    remote('ancestor-skill', 'Read the ancestor-bench skill to get the ancestor marker. Report it followed by BENCH_OK.',
           setup=ancestor_setup,extra=['--workspace',OUT/'projects'],names=['read'],
           check=lambda p,r,t: require('ANCESTOR_35' in r['finalText'], 'Ancestor skill not read'))
    remote('builtin-skill', 'Use read to open the SKILL.md for the bundled answers-charts skill from your skill catalog. Report its name followed by BENCH_OK.',names=['read'],
           check=lambda p,r,t: require('/app_bundle/' in json.dumps(r['state']['transcript']), 'Bundled skill path not exercised'))
    run('round-cap', base + ['--maximum-rounds','1','--message','Use write to create round.txt containing ROUND_42. Then reply DONE.'], expected=1,
        check=lambda r,t: require(r and r.get('error') and 'round_limit_reached' in json.dumps(r['state']['transcript']) and not (p/'round.txt').exists(), 'Round cap did not stop tool execution/save error'))
    run('output-cap', base + ['--maximum-output-tokens','512','--message','Output a numbered list of 2000 distinct short sentences. Do not use tools or stop early.'], expected=1,
        check=lambda r,t: require(r and r.get('error') and r['requests'], 'Output cap missing error snapshot'))
    for sig in [signal.SIGINT,signal.SIGTERM]:
        run('remote-' + sig.name, base + ['--message','Use bash with command "sleep 20; echo WAIT_FINISHED", refresh_sec=25, timeout_sec=30. Then reply DONE.'],
            cancel=(sig,'[running] bash'), expected=128+sig,
            check=lambda r,t: require(r and r.get('error') and 'cancelled' in json.dumps(r['state']['transcript']).lower(), 'Missing cancelled transcript'))
    def failtool(r,t):
        require(r and 'Error:' in json.dumps(r['state']['transcript']), 'Missing expected tool error')
        require('EXPECTED_ERROR' in r['finalText'], 'Agent did not report tool error')
    run('missing-file', base + ['--message','Use read on missing-does-not-exist.txt. Do not create it or retry. If it fails, reply EXPECTED_ERROR.'], check=failtool)
    (p/'edit.txt').write_text('KEEP_THIS_FILE\n')
    run('edit-no-match', base + ['--message','Use edit to replace ABSENT_TEXT with MODIFIED in edit.txt. Do not retry. If it fails, reply EXPECTED_ERROR.'],
        check=lambda r,t: (failtool(r,t),require((p/'edit.txt').read_text()=='KEEP_THIS_FILE\n','Failed edit modified file')))
    run('missing-key-boundary', base + ['--api-key-environment','CLI_BENCH_UNSET','--message','hello'], expected=64, contains=['CLI_BENCH_UNSET'])
    # Synthetic, completed history exercises a real Claude checkpoint request.
    seed = {'provider':'anthropic','model':'claude-sonnet-4-6','baseURL':'https://api.anthropic.com/v1',
            'project':str(p),'state':{'transcript':[]}}
    for i in range(12):
        text = ('Keep the important marker COMPACT_72 for the active task.\n' if i==0 else '') + (f'Completed historical note {i}. ' * 240)
        seed['state']['transcript'] += [
            {'role':'user','content':[{'type':'text','text':text}]},
            {'role':'assistant','content':[{'type':'text','text':f'Finished note {i}.'}]}]
    seed_path=OUT/'synthetic-history.json'
    seed_path.write_text(json.dumps(seed))
    run('live-compaction-synthetic-history', base + ['--resume',seed_path,'--context-window-tokens','32768',
        '--compaction-threshold','.35','--compaction-target','.2','--message','What important marker was saved for the active task? Reply only that marker.'],
        contains=['COMPACT_72'], check=lambda r,t: require(r and 'CONTEXT CHECKPOINT' in json.dumps(r['state']['transcript']) and len(r['state']['transcript']) < 24, 'History not compacted'), timeout=180)

if args.stage == 'local':
    p = project('local')
    base = ['local-agent','--model','qwen_3.8_27b_i4x.ckpt','--project',p,
            '--thinking-budget','0','--maximum-generated-tokens','768','--web-search-provider','disabled',
            '--trace','--result-json','@RESULT@']
    def localcheck(r,t):
        require(r and r['prefixTokens'] and not r['interrupted'] and not r['stoppedAtTokenLimit'], 'Local run incomplete')
        require(all(c.get('response') for c in r['toolCalls']), 'Missing saved tool responses')
    for i in range(3):
        run(f'plain-local-{i+1}', base + ['--message','Reply exactly LOCAL_42. Do not use tools.'], contains=['LOCAL_42'], check=localcheck)
    first = run('local-tools', base + ['--model-store',MODEL,'--workspace',OUT/'projects','--message',
         'Use write to create local.txt containing exactly LOCAL_TOOL_57. Use read to verify the file, then reply DONE.'],
         contains=['DONE'], check=lambda r,t: (localcheck(r,t), require((p/'local.txt').read_text() == 'LOCAL_TOOL_57', 'Wrong written file'),
         require({'write','read'} <= {c['request']['function'] for c in r['toolCalls']}, 'Missing tool calls')))
    if first:
        saved = OUT/'local-resume.json'
        saved.write_text(json.dumps(first))
        run('local-resume', base + ['--resume',saved,'--message','What exact text did you write? Reply only that text.'],
            contains=['LOCAL_TOOL_57'], check=localcheck)
    run('local-stdin-options', base + ['--model','Qwen 3.8 27B (4-bit S)','--models-dir',str(Path(MODEL).parent),'--prompt-file','-',
        '--reasoning-effort','low','--no-deterministic','--chunked-prefill-max-length','1024',
        '--queue-watermark','16','--disable-mfa-apple-neural-engine'], stdin='Reply exactly STDIN_84. Do not use tools.',
        contains=['STDIN_84'], check=localcheck)
    run('local-token-cap', base + ['--message','Explain binary search in detail.','--maximum-generated-tokens','1'], expected=64,
        check=lambda r,t: require(r and r['stoppedAtTokenLimit'] and r['generatedTokens'] >= 1 and r['prefixTokens'], 'Missing cap snapshot'))
    for sig in [signal.SIGINT, signal.SIGTERM]:
        run('local-' + sig.name, base + ['--message','Write a long essay about algorithms.'],
            cancel=(sig,'[prefill]'), expected=128+sig,
            check=lambda r,t: require(r and r['interrupted'], 'Missing cancellation snapshot'))

if args.stage == 'raw':
    base = ['--variant','qwen3.6-27b','--model-store',MODEL,
            '--tokenizer-dir',str(args.tokenizer_dir.resolve()),
            '--prompt','Hello','--max-new-tokens','32']
    run('default-generate-trace', base + ['--trace'], contains=['generated_ids:','partial_ids:'])
    for i in range(3):
        run(f'generation-timing-{i+1}', ['generate'] + base + ['--prefill-token-count','8','--measure-generation','--summary-only'],
            contains=['generation_generated_tokens: 32','generation_prompt_tokens: 8'])
    run('ttft', ['generate'] + base + ['--ttft-tokens','256','--ttft-runs','5','--ttft-warmups','1'],
        contains=['ttft_runs: 5','ttft_tokens: 256','ttft_median_ms:'])
    for i in range(3):
        run(f'mtp-generate-{i+1}', ['generate'] + base + ['--prefill-token-count','8','--mtp-generate','--summary-only'],
            contains=['generation_generated_tokens: 32','generation_prompt_tokens: 8','mtp_generation_accepted_drafts:'])
    run('mtp-draft-depth', ['generate'] + base + ['--mtp-draft-tokens','4','--mtp-draft-starts','4'],
        contains=['mtp_draft_starts: 4','mtp_draft_max_tokens: 4'])
    reference=[]
    def collect_reference(r,t):
        match=re.search(r'^generated_ids: ([0-9,]+)$',t,re.M)
        require(match is not None,'Missing reference token IDs')
        reference.extend(int(x) for x in match.group(1).split(','))
        require(len(reference)==32,'Wrong reference token count')
    run('greedy-equivalence-reference', ['generate'] + base + ['--prefill-token-count','8','--measure-generation'], check=collect_reference)
    def compare_greedy(r,t):
        match=re.search(r'^generated_ids: ([0-9,]+)$',t,re.M)
        require(match is not None,'Missing MTP token IDs')
        require([int(x) for x in match.group(1).split(',')]==reference,'MTP token IDs differ from ordinary greedy output')
    run('greedy-equivalence-mtp', ['generate'] + base + ['--prefill-token-count','8','--mtp-generate'], check=compare_greedy)

if not completed_results:
    parser.error('No cases matched the requested stage/filter')
raise SystemExit(0 if all(r['passed'] for r in completed_results) else 1)
