#!/usr/bin/env python3
"""Drive livecopilot-inference like LocalLiveProvider, pacing a synthetic 16 kHz mono PCM16 WAV in real time.
Reports model load time, per-request inference time and when text appears on the audio timeline.
Prints no transcript text, only timings and character counts. Use synthetic speech only, e.g.:
  say -v Tingting -o zh.wav --data-format=LEI16@16000 "<synthetic sentence>"
  python3 -I scripts/measure-local-asr.py Resources/LocalRuntime/livecopilot-inference zipformer <model-dir> zh.wav [chunk_ms] [fast]"""
import base64, json, subprocess, sys, time, wave

runtime, mode, model, wav = sys.argv[1:5]
chunk_ms = int(sys.argv[5]) if len(sys.argv) > 5 else 100
pace = sys.argv[6] != "fast" if len(sys.argv) > 6 else True

with wave.open(wav) as w:
    assert w.getframerate() == 16000 and w.getsampwidth() == 2 and w.getnchannels() == 1
    pcm = w.readframes(w.getnframes())
speech_ms = len(pcm) // 32
pcm = bytes(16000) + pcm + bytes(32000 * 3)  # 0.5 s lead-in, 3 s trailing silence

t0 = time.monotonic()
p = subprocess.Popen([runtime, mode, model], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
ready = json.loads(p.stdout.readline())
load_ms = (time.monotonic() - t0) * 1000

def call(op, data=b""):
    msg = {"id": "x", "op": op}
    if op == "audio": msg["pcm"] = base64.b64encode(data).decode()
    p.stdin.write((json.dumps(msg) + "\n").encode()); p.stdin.flush()
    return json.loads(p.stdout.readline())

step = 32 * chunk_ms
calls, first_partial, finals = [], None, []
start = time.monotonic()
for i in range(0, len(pcm), step):
    audio_ms = (i + step) // 32
    if pace:
        due = start + audio_ms / 1000
        if due > time.monotonic(): time.sleep(due - time.monotonic())
    c0 = time.monotonic()
    r = call("audio", pcm[i:i + step])
    calls.append((time.monotonic() - c0) * 1000)
    if r.get("partial") and first_partial is None: first_partial = audio_ms
    for s in r.get("segments", []):
        finals.append({"audio_ms_at_emit": audio_ms, "seg_end_ms": s["end_ms"], "chars": len(s["text"].strip())})
f0 = time.monotonic(); r = call("flush"); flush_ms = (time.monotonic() - f0) * 1000
p.stdin.close(); p.wait()
calls.sort()
print(json.dumps({
    "ready": ready.get("ready"), "load_ms": round(load_ms), "speech_end_audio_ms": 500 + speech_ms,
    "chunk_ms": chunk_ms, "calls": len(calls),
    "call_ms_p50": round(calls[len(calls) // 2], 1), "call_ms_p95": round(calls[int(len(calls) * .95)], 1), "call_ms_max": round(calls[-1], 1),
    "rtf": round(sum(calls) / (len(pcm) / 32), 3), "first_partial_audio_ms": first_partial,
    "finals": finals, "flush_ms": round(flush_ms), "flush_segments": len(r.get("segments", [])),
}))
