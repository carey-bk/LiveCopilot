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
CONTEXT_TOKENS = 1024
QUESTIONS = {
    "needs_response": {
        "type": "noul",
        "instructions": "Based on the recent conversation, does the latest speaker want the listener to respond now, with enough intent to begin a useful answer?",
        "criteria": {
            "true": "A new request or contextual follow-up has clear intent. Imperatives, ellipsis and unfinished grammar qualify when the main request is already understandable.",
            "false": "No response is requested: narration, an answer, acknowledgement, mere quotation, withdrawal or explicit waiting. Also wait if essential intent is still unknown. Handled requests are background only.",
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
    value = result["answers"]["needs_response"]["noul"]
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


def recent_context(context):
    """Accept the app's structured turns; keep legacy diagnostic context readable."""
    if not context.strip():
        return "Room", []
    if not context.lstrip().startswith("{"):
        return "Room", [{"speaker": "Unknown", "text": context, "handled": False}]
    value = strict_loads(context)
    if not isinstance(value, dict) or set(value) != {"currentSpeaker", "recentTurns"}:
        raise ValueError("invalid_context")
    speaker, turns = value["currentSpeaker"], value["recentTurns"]
    if not isinstance(speaker, str) or len(speaker) > 32 or not isinstance(turns, list) or len(turns) > 80:
        raise ValueError("invalid_context")
    for turn in turns:
        if (not isinstance(turn, dict) or set(turn) != {"speaker", "text", "handled"}
                or not isinstance(turn["speaker"], str) or len(turn["speaker"]) > 32
                or not isinstance(turn["text"], str) or type(turn["handled"]) is not bool):
            raise ValueError("invalid_context")
    return speaker, turns


def prepare_state(agent, text, context):
    from laya_mlx.common import build_prefix
    tok = agent.tok
    latest = text.replace(tok.mask_token, " ")
    speaker, turns = recent_context(context)
    history = [{"speaker": t["speaker"], "text": t["text"].replace(tok.mask_token, " "),
                "handled": t["handled"]} for t in turns]
    turns = []
    internal = agent._to_internal(QUESTIONS["needs_response"])
    prefix, markers = build_prefix(tok, internal, agent.cfg.get("head_max_len", 256))
    maximum = agent.cfg.get("max_len", 0)
    if type(maximum) is not int or maximum != CONTEXT_TOKENS or len(markers) != 2:
        raise ValueError("invalid_budget")
    room = maximum - len(prefix) - 1

    def render():
        return json.dumps({"previous_turns": turns, "current_speaker": speaker,
                           "current_utterance": latest}, ensure_ascii=False, separators=(",", ":"))

    state = render()
    # Reserve the current turn first, then fill backwards from newest history.
    # Do not repeatedly tokenize the entire (up to 60 KB) transcript to remove
    # old turns. A long recent answer retains its tail for contextual follow-ups.
    while len(token_ids(tok, state)) > room:
        count = len(token_ids(tok, state))
        budget = len(token_ids(tok, latest)) - (count - room) - 8
        if budget <= 0:
            raise ValueError("invalid_budget")
        latest = suffix(tok, latest, budget)
        state = render()
    for turn in reversed(history):
        turns.insert(0, turn)
        state = render()
        if len(token_ids(tok, state)) <= room:
            continue
        while len(token_ids(tok, state)) > room:
            excess = len(token_ids(tok, state)) - room
            budget = len(token_ids(tok, turns[0]["text"])) - excess - 8
            if budget > 0:
                turns[0]["text"] = suffix(tok, turns[0]["text"], budget)
            else:
                turns.pop(0)
            state = render()
        break
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


def model_path(installation, resources, installation_receipt):
    """Verify the accepted downloaded checkpoint; never silently use an old model.

    Explicit local research bundles remain supported, but release packaging rejects
    their large weights. Installation switches preserve previous versions on disk.
    """
    manifest = resources / "response-model.json"
    model = resources / "ResponseModel"
    if not manifest.exists() and not model.exists():
        return installation / "model"
    receipt = strict_loads(manifest.read_bytes())
    if not model.exists():
        pins = strict_loads((resources / "pins.json").read_bytes())
        if installation_receipt.get("pin_id") != pins.get("id"):
            raise ValueError("response_model_update_required")
        model = installation / "model"
    question_sha = hashlib.sha256(json.dumps(QUESTIONS, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    required = {"model.safetensors", "rl_agent_config.json", "mlx_config.json",
                "encoder/config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"}
    files = receipt.get("files")
    if (model.is_symlink() or receipt.get("schema") != 1 or receipt.get("context_tokens") != CONTEXT_TOKENS
            or receipt.get("question_sha256") != question_sha
            or receipt.get("runtime_pin_id") != installation_receipt.get("runtime_pin_id", installation_receipt.get("pin_id"))
            or not isinstance(files, dict) or not required.issubset(files)):
        raise ValueError("invalid_response_model")
    root = model.resolve(strict=True)
    for name, digest in files.items():
        relative = Path(name)
        file = model / relative
        if (relative.is_absolute() or ".." in relative.parts or file.is_symlink()
                or not file.is_file() or root not in file.resolve().parents):
            raise ValueError("invalid_response_model")
        h = hashlib.sha256()
        with file.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1048576), b""):
                h.update(chunk)
        if h.hexdigest() != digest:
            raise ValueError("invalid_response_model")
    return model


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
    # Run below foreground video conferencing priority so Teams/Zoom stay smooth.
    try:
        os.nice(10)
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
        receipt = verify_installation(installation)
        sys.path.insert(0, str(installation / "source"))
        import laya_mlx
        try:
            import mlx.core as mx
            if hasattr(mx, "set_cache_limit"):
                mx.set_cache_limit(256 * 1024 * 1024)
            elif hasattr(mx, "metal") and hasattr(mx.metal, "set_cache_limit"):
                mx.metal.set_cache_limit(256 * 1024 * 1024)
        except Exception:
            pass
        model = model_path(installation, Path(__file__).resolve().parent, receipt)
        agent = laya_mlx.load(model, dtype="float16")
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
