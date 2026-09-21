#!/usr/bin/env python3
"""Private offline NDJSON inference. Never print input, paths, or exception details."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys

MAX_LINE = 131072
MAX_TEXT = 65536
QUESTIONS = {
    "needs_response": {
        "type": "choice",
        "instructions": "Classify the latest utterance by its conversational intent.",
        "criteria": {
            "respond": "A direct question or request addressed to the listener, asking them to answer or explain.",
            "wait": "A statement, acknowledgement, quoted or reported question, or unfinished thought.",
        },
    }
}


def strict_loads(data):
    def constant(_):
        raise ValueError("nonfinite")
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate")
            result[key] = value
        return result
    return json.loads(data, parse_constant=constant, object_pairs_hook=pairs)


def checked_score(result):
    value = result["answers"]["needs_response"]["probabilities"]["respond"]
    if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1:
        raise ValueError("invalid_score")
    return float(value)


def token_ids(tok, text):
    return tok(text, add_special_tokens=False)["input_ids"]


def suffix(tok, text, budget):
    """Keep an original Unicode suffix, using real tokenizer offsets and counts."""
    if budget <= 0:
        return ""
    for _ in range(16):
        encoded = tok.backend.encode(text, add_special_tokens=False)
        if len(encoded.ids) <= budget:
            return text
        start = encoded.offsets[-budget][0]
        # Special-token offsets can be zero. Always make bounded progress.
        text = text[max(1, start):]
    # Conservative fallback still measures the actual tokens; never guesses chars/tokens.
    while text and len(token_ids(tok, text)) > budget:
        text = text[len(text) // 2 + 1:]
    return text


def prepare_state(agent, text, context):
    from laya_mlx.common import build_prefix
    tok = agent.tok
    text = text.replace(tok.mask_token, " ")
    context = context.replace(tok.mask_token, " ")
    internal = agent._to_internal(QUESTIONS["needs_response"])
    prefix, markers = build_prefix(tok, internal, agent.cfg.get("head_max_len", 192))
    maximum = agent.cfg.get("max_len", 512)
    if type(maximum) is not int or maximum > 1024 or len(markers) != 2:
        raise ValueError("invalid_budget")
    room = maximum - len(prefix) - 1  # Includes question/options, CLS/SEP/MASK, final SEP.
    # Classify only the current utterance. Duplicating it in a conversation field
    # inflated confidence and made ordinary statements trigger in local smoke checks.
    # Recent context remains attached to the downstream reasoning request in Swift.
    latest = suffix(tok, text, max(1, room - 24))
    state = json.dumps({"latest_utterance": latest}, ensure_ascii=False)
    for _ in range(16):
        count = len(token_ids(tok, state))
        if count <= room:
            break
        latest = suffix(tok, latest, len(token_ids(tok, latest)) - (count - room + 8))
        state = json.dumps({"latest_utterance": latest}, ensure_ascii=False)
    expected = len(prefix) + len(token_ids(tok, state)) + 1
    items, _ = agent.prepare(state, QUESTIONS)
    if not latest.strip() or expected > maximum or len(items) != 1 or len(items[0]["ids"]) != expected:
        raise ValueError("invalid_budget")
    return state, expected


def predict(agent, text, context):
    state, count = prepare_state(agent, text, context)
    return checked_score(agent.predict(state, QUESTIONS)), count


def validate_request(request):
    if not isinstance(request, dict) or set(request) != {"id", "op", "text", "context"}:
        raise ValueError("invalid_request")
    if not isinstance(request["id"], str) or not re.fullmatch(r"[A-Za-z0-9-]{1,64}", request["id"]):
        raise ValueError("invalid_request")
    if request["op"] != "predict":
        raise ValueError("invalid_request")
    for name in ("text", "context"):
        value = request[name]
        if not isinstance(value, str) or len(value.encode("utf-8", "strict")) > MAX_TEXT:
            raise ValueError("invalid_request")
    if not request["text"].strip():
        raise ValueError("invalid_request")


def verify_installation(path):
    receipt = strict_loads((path / "receipt.json").read_bytes())
    if receipt.get("schema") != 1 or not receipt.get("files"):
        raise ValueError("invalid_installation")
    for name, digest in receipt["files"].items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("invalid_installation")
        file = path / relative
        if file.is_symlink() or not file.is_file():
            raise ValueError("invalid_installation")
        h = hashlib.sha256()
        with file.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1048576), b""):
                h.update(chunk)
        if h.hexdigest() != digest:
            raise ValueError("invalid_installation")
    return receipt


def emit(stream, payload):
    encoded = json.dumps(payload, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode() + b"\n"
    if len(encoded) > 4096:
        raise ValueError("invalid_response")
    stream.write(encoded)
    stream.flush()


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--installation", required=True)
    args = parser.parse_args()
    # Dedicated process group allows native cancellation to kill every owned process.
    try:
        os.setpgid(0, 0)
    except OSError:
        pass
    os.environ.update(HF_HUB_OFFLINE="1", HUGGINGFACE_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
                      HF_HUB_DISABLE_TELEMETRY="1", TOKENIZERS_PARALLELISM="false")
    for name in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "OPENAI_API_KEY", "DEEPSEEK_API_KEY"):
        os.environ.pop(name, None)
    # Reserve original stdout for protocol even if an imported library prints diagnostics.
    channel = os.fdopen(os.dup(1), "wb", buffering=0)
    with open(os.devnull, "wb") as null:
        os.dup2(null.fileno(), 1)
        os.dup2(null.fileno(), 2)
    try:
        installation = Path(args.installation).resolve(strict=True)
        verify_installation(installation)
        sys.path.insert(0, str(installation / "source"))
        import laya_mlx
        agent = laya_mlx.load(installation / "model", dtype="float16")
        predict(agent, "The meeting starts at nine.", "")
        emit(channel, {"ready": True, "protocol": 1})
    except Exception:
        emit(channel, {"ready": False, "error": "load_failed"})
        return 2
    while True:
        line = sys.stdin.buffer.readline(MAX_LINE + 1)
        if not line:
            return 0
        if len(line) > MAX_LINE or not line.endswith(b"\n"):
            emit(channel, {"error": "invalid_request"})
            return 3
        identifier = None
        try:
            request = strict_loads(line.decode("utf-8", "strict"))
            validate_request(request)
            identifier = request["id"]
            score, count = predict(agent, request["text"], request["context"])
            emit(channel, {"id": identifier, "score": score, "input_tokens": count})
        except Exception:
            emit(channel, {"id": identifier, "error": "prediction_failed"})


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BrokenPipeError, KeyboardInterrupt):
        raise SystemExit(0)
