"""Fuzz encoding_glm5_3.encode against the official Jinja template (transformers renderer).

usage: python3 -I fuzz_glm5_3.py <chat_template.jinja> <directory of encoding_glm5_3.py> [cases]
"""
import random
import sys

from transformers.utils.chat_template_utils import render_jinja_template

sys.path.insert(0, sys.argv[2])
import encoding_glm5_3 as enc  # noqa: E402

TEMPLATE = open(sys.argv[1]).read()
N = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
rng = random.Random(1234)

WORDS = ["hi", " spaced ", "\nnl\n", "中文", "émoji 🙂", "a\"q", "<b>", "  ", "", "x" * 5, "tab\t"]


def text():
    return "".join(rng.choice(WORDS) for _ in range(rng.randint(0, 4)))


def content():
    r = rng.random()
    if r < 0.6:
        return text()
    if r < 0.65:
        return None
    parts = []
    for _ in range(rng.randint(1, 4)):
        t = rng.choice(["text", "text", "image_url", "image", "video_url", "input_audio", "str"])
        parts.append(text() if t == "str" else {"type": "text", "text": text()} if t == "text" else {"type": t})
    return parts


def arg_value():
    return rng.choice([text(), rng.randint(-5, 500), 3.25, True, False, None, ["a", 1, "中"],
                       {"k": "v", "n": [1, 2]}, "", "  pad  ", "line1\nline2"])


TOOL_NAMES = ["read_file", "bash", "mcp__srv__do", "tool_search", "hidden_one"]


def make_tools():
    tools = []
    for n in TOOL_NAMES:
        fn = {"name": n, "description": "desc " + n + rng.choice(["", " ü", " \"q\""]),
              "parameters": {"type": "object", "properties": {"a": {"type": "string"}}}}
        if rng.random() < 0.25:
            fn["defer_loading"] = True
        if rng.random() < 0.2:
            fn["strict"] = True
        tools.append({"type": "function", "function": fn} if rng.random() < 0.8 else fn)
    return tools


def conversation():
    msgs = []
    if rng.random() < 0.7:
        msgs.append({"role": "system", "content": content()})
    for _ in range(rng.randint(1, 5)):
        msgs.append({"role": "user", "content": content()})
        if rng.random() < 0.1:
            msgs.append({"role": "system", "content": text()})
        for _ in range(rng.randint(0, 3)):
            a = {"role": "assistant"}
            r = rng.random()
            if r < 0.5:
                a["reasoning_content"] = text()
            elif r < 0.6:
                a["reasoning_content"] = None
            c = content() if rng.random() < 0.8 else None
            if rng.random() < 0.15:
                c = rng.choice(["", "<think>"]) + text() + "</think>" + text()
            a["content"] = c
            calls = []
            if rng.random() < 0.6:
                for j in range(rng.randint(1, 3)):
                    args = {rng.choice(["a", "b", "path", "kéy", "cmd"]) + str(i): arg_value()
                            for i in range(rng.randint(0, 3))}
                    cid = rng.choice(["call_%d_%d" % (len(msgs), j)] * 8 + ["", "dup"])
                    call = {"type": "function", "function": {"name": rng.choice(TOOL_NAMES), "arguments": args}}
                    if cid or rng.random() < 0.5:
                        call["id"] = cid
                    calls.append(call)
                a["tool_calls"] = calls
            msgs.append(a)
            if calls:
                results = []
                for call in calls:
                    cid = call.get("id", "")
                    r = rng.random()
                    if r < 0.6:
                        results.append({"role": "tool", "tool_call_id": cid, "content": text()})
                    elif r < 0.75:
                        results.append({"role": "tool", "tool_call_id": cid, "content": content() or "x"})
                    elif r < 0.85:
                        results.append({"role": "tool", "tool_call_id": cid,
                                        "content": [{"type": "tool_reference", "name": rng.choice(TOOL_NAMES)}]})
                    else:
                        results.append({"role": "tool", "content": [
                            {"tool_call_id": cid, "output": rng.choice([text(), [{"type": "text", "text": text()}],
                                                                        [{"type": "tool_reference", "name": "hidden_one"}]])}]})
                if rng.random() < 0.5:
                    rng.shuffle(results)
                if rng.random() < 0.1 and results:
                    results.pop()
                if rng.random() < 0.05:
                    results.append({"role": "tool", "tool_call_id": "stray", "content": "s"})
                msgs.extend(results)
                if rng.random() < 0.3:
                    break
    return msgs


fails = 0
skipped = 0
for n in range(N):
    msgs = conversation()
    tools = make_tools() if rng.random() < 0.8 else rng.choice([None, []])
    kw = {}
    if rng.random() < 0.7:
        kw["reasoning_effort"] = rng.choice(["low", "high", "max", "medium", "xhigh", None])
    if rng.random() < 0.5:
        kw["clear_thinking"] = rng.choice([True, False])
    agp = rng.random() < 0.8
    try:
        want = render_jinja_template(conversations=[msgs], tools=tools, chat_template=TEMPLATE,
                                     add_generation_prompt=agp, **kw)[0][0]
    except Exception as e:  # The template raises for tool_reference without tools.
        assert not tools, (e, tools)
        skipped += 1
        continue
    got = enc.encode(msgs, tools=tools, reasoning_effort=kw.get("reasoning_effort"),
                     clear_thinking=kw.get("clear_thinking", False), add_generation_prompt=agp)
    if got != want:
        fails += 1
        if fails <= 3:
            i = next(i for i in range(min(len(got), len(want))) if got[i] != want[i]) if got[:len(want)] != want[:len(got)] else min(len(got), len(want))
            print("MISMATCH #%d at %d\n want: %r\n  got: %r" % (n, i, want[max(0, i - 80):i + 80], got[max(0, i - 80):i + 80]))
print("cases=%d mismatches=%d skipped(no-tools + tool_reference)=%d" % (N, fails, skipped))
