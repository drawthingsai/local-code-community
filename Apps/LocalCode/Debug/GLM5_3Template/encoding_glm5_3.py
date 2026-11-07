"""Reference encoder for the GLM-5.3 / GLM-5.3-Flash chat format.

Plain-Python transcription of zai-org/GLM-5.3-Flash chat_template.jinja
(HF commit 46a050bec1, 2026-10-15) so the layout can be read without Jinja.
It is checked byte-for-byte against the official template by fuzz_glm5_3.py.

Special tokens (shared tokenizer.json for GLM-5 .. GLM-5.3-Flash):
  154820 <|endoftext|>   154822 [gMASK]   154824 <sop>
  154826 <|system|>      154827 <|user|>  154828 <|assistant|>  154829 <|observation|>
  154830/1 <|begin_of_image|>/<|end_of_image|>   154832/3 <|begin_of_video|>/<|end_of_video|>
  154834/5 <|begin_of_audio|>/<|end_of_audio|>   154854 <|image|>   154855 <|video|>
  154841/2 <think> </think>   154843/4 <tool_call> </tool_call>
  154845/6 <tool_response> </tool_response>   154847/8 <arg_key> </arg_key>
  154849/50 <arg_value> </arg_value>
Stop tokens (generation_config eos_token_id): 154820, 154827 (<|user|>), 154829 (<|observation|>).
"""

import json

TOOLS_PREAMBLE = (
    "\n# Tools\n\nYou may call one or more functions to assist with the user query.\n\n"
    "You are provided with function signatures within <tools></tools> XML tags:\n<tools>\n"
)
TOOLS_POSTAMBLE = (
    "</tools>\n\nFor each function call, output the function name and arguments within the "
    "following XML format:\n<tool_call>{function-name}<arg_key>{arg-key-1}</arg_key>"
    "<arg_value>{arg-value-1}</arg_value><arg_key>{arg-key-2}</arg_key>"
    "<arg_value>{arg-value-2}</arg_value>...</tool_call>"
)
IMAGE = "<|begin_of_image|><|image|><|end_of_image|>"  # <|image|> is expanded by the processor
VIDEO = "<|begin_of_video|><|video|><|end_of_video|>"
AUDIO = "<|begin_of_audio|><|end_of_audio|>"


def tojson(v):
    # transformers' tojson filter: json.dumps(ensure_ascii=False), default ", " / ": " separators.
    return json.dumps(v, ensure_ascii=False)


def unwrap(tool):
    return tool["function"] if "function" in tool else tool


def tool_to_json(tool):
    # Keys keep insertion order; `defer_loading` and `strict` are dropped; the key is NOT escaped.
    return "{" + ", ".join('"%s": %s' % (k, tojson(v)) for k, v in tool.items()
                           if k not in ("defer_loading", "strict")) + "}"


def visible_text(content):
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for item in content:
            if isinstance(item, str):
                out.append(item)
            elif isinstance(item, dict):
                t = item.get("type")
                if t == "text":
                    out.append(item["text"])
                elif t in ("image", "image_url"):
                    out.append(IMAGE)
                elif t in ("video", "video_url"):
                    out.append(VIDEO)
                elif t in ("audio", "audio_url", "input_audio"):
                    out.append(AUDIO)
        return "".join(out)
    return str(content)


def tool_references(refs, tools):
    out = "<tool_response><tools>\n"
    for ref in refs:
        for tool in tools or []:
            tool = unwrap(tool)
            if tool.get("name") == ref.get("name"):
                out += tool_to_json(tool) + "\n"
    return out + "</tools></tool_response>"


def is_tool_reference_list(x):
    return isinstance(x, list) and x and isinstance(x[0], dict) and x[0].get("type") == "tool_reference"


def is_list_of_outputs(m):
    c = m.get("content")
    return isinstance(c, list) and c and isinstance(c[0], dict) and "output" in c[0]


def id_of(obj):
    return obj.get("tool_call_id") or obj.get("id") or ""


def render_tool_response(m, tools):
    c = m.get("content")
    if isinstance(c, str):
        return "<tool_response>" + c + "</tool_response>"
    if is_tool_reference_list(c):
        return tool_references(c, tools)
    if is_list_of_outputs(m):
        out = ""
        for entry in c:
            o = entry.get("output")
            out += tool_references(o, tools) if is_tool_reference_list(o) else \
                "<tool_response>" + visible_text(o) + "</tool_response>"
        return out
    return "<tool_response>" + visible_text(c) + "</tool_response>"


def render_observation_block(messages, start, tools):
    """One <|observation|> for a run of consecutive `tool` messages.

    Results are re-ordered to the order of the preceding assistant's tool_calls when every
    result id is non-empty, unique, and present among the (non-empty, unique) tool_call ids;
    otherwise they are emitted in message order.
    """
    end = start
    while end + 1 < len(messages) and messages[end + 1]["role"] == "tool":
        end += 1
    entries = []  # (result id, message index, entry index or -1)
    for k in range(start, end + 1):
        m = messages[k]
        if is_list_of_outputs(m):
            entries += [(id_of(e), k, i) for i, e in enumerate(m["content"])]
        else:
            entries.append((id_of(m), k, -1))
    prev = messages[start - 1] if start > 0 else None
    tcs = [id_of(tc) for tc in (prev or {}).get("tool_calls") or []] \
        if prev and prev["role"] == "assistant" else []
    res = [e[0] for e in entries]
    can_sort = (bool(tcs) and "" not in res and "" not in tcs and len(set(res)) == len(res)
                and len(set(tcs)) == len(tcs) and all(r in tcs for r in res))
    out = "<|observation|>"
    if can_sort:
        for _, k, i in sorted(entries, key=lambda e: tcs.index(e[0])):
            if i >= 0:
                o = messages[k]["content"][i].get("output")
                out += tool_references(o, tools) if is_tool_reference_list(o) else \
                    "<tool_response>" + visible_text(o) + "</tool_response>"
            else:
                out += render_tool_response(messages[k], tools)
    else:
        for k in range(start, end + 1):
            out += render_tool_response(messages[k], tools)
    return out


def encode(messages, tools=None, reasoning_effort=None, clear_thinking=False, add_generation_prompt=True):
    effort = reasoning_effort if reasoning_effort in ("low", "high") else "max"
    out = "[gMASK]<sop><|system|>Reasoning Effort: " + effort.capitalize()
    if tools:
        out += "<|system|>" + TOOLS_PREAMBLE
        for tool in tools:
            tool = unwrap(tool)
            if not tool.get("defer_loading"):
                out += tool_to_json(tool) + "\n"
        out += TOOLS_POSTAMBLE
    last_user = max((i for i, m in enumerate(messages) if m["role"] == "user"), default=-1)
    for idx, m in enumerate(messages):
        role = m["role"]
        if role == "system":
            out += "<|system|>" + visible_text(m.get("content"))
        elif role == "user":
            out += "<|user|>" + visible_text(m.get("content"))
        elif role == "assistant":
            out += "<|assistant|>"
            content = visible_text(m.get("content"))
            reasoning = None
            if isinstance(m.get("reasoning_content"), str):
                reasoning = m["reasoning_content"]
            elif "</think>" in content:
                reasoning = content.split("</think>")[0].split("<think>")[-1]
                content = content.split("</think>")[-1]
            if (not clear_thinking or idx > last_user) and reasoning is not None:
                out += "<think>" + reasoning + "</think>"  # verbatim, no strip
            else:
                out += "<think></think>"
            if content.strip():
                out += content.strip()  # content IS stripped
            for tc in m.get("tool_calls") or []:
                tc = tc.get("function") or tc
                out += "<tool_call>" + tc["name"]
                for k, v in tc["arguments"].items():
                    out += "<arg_key>%s</arg_key><arg_value>%s</arg_value>" % (
                        k, v if isinstance(v, str) else tojson(v))
                out += "</tool_call>"
        elif role == "tool":
            if idx == 0 or messages[idx - 1]["role"] != "tool":
                out += render_observation_block(messages, idx, tools)
    if add_generation_prompt:
        out += "<|assistant|><think>"
    return out
