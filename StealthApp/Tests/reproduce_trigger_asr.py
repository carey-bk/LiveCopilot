"""Opt-in local synthetic speech reproduction; no credentials or network."""
import argparse
import base64
import json
from pathlib import Path
import selectors
import subprocess
import time
import wave


class Worker:
    def __init__(self, command):
        self.p = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        assert self.read().get('ready')

    def read(self):
        with selectors.DefaultSelector() as selector:
            selector.register(self.p.stdout, selectors.EVENT_READ)
            if not selector.select(90):
                self.p.kill()
                raise TimeoutError('local worker')
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError('local worker closed')
        return json.loads(line)

    def call(self, **payload):
        payload['id'] = 'synthetic'
        self.p.stdin.write(json.dumps(payload, ensure_ascii=False) + '\n')
        self.p.stdin.flush()
        value = self.read()
        assert 'error' not in value, value
        return value

    def close(self):
        self.p.terminate()
        self.p.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--executable', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--laya', action='store_true')
    args = parser.parse_args()
    root = Path(args.output); root.mkdir(parents=True, exist_ok=True)
    support = Path.home() / 'Library/Application Support/LiveCopilot'
    questions = ['日本的首都是哪里', '告诉我你的经历', '跟我说你的学历情况', '讲讲冒泡排序',
                 '讲讲项目中的困难', '你在项目中遇到的最大困难是什么', '今天的会议到这里结束',
                 '我不知道日本的首都是哪里', '讲讲项目中的困难以及解决方法']
    rows = []
    for i, question in enumerate(questions):
        for rate in ([160, 210, 260] if '困难' in question else [210]):
            audio = root / f'case-{i}-{rate}.wav'
            if not audio.exists():
                subprocess.run(['/usr/bin/say', '-v', 'Tingting', '-r', str(rate), '-o', str(audio),
                                '--file-format=WAVE', '--data-format=LEI16@16000', question], check=True)
            with wave.open(str(audio)) as f:
                assert (f.getframerate(), f.getnchannels(), f.getsampwidth()) == (16000, 1, 2)
                pcm = bytes(16000) + f.readframes(f.getnframes()) + bytes(32000 * 2)
            worker = Worker([args.executable, 'paraformer', str(support / 'Models/paraformer-streaming-zh-en-int8-v1')])
            segments, previews = [], []
            start = time.monotonic()
            try:
                for offset in range(0, len(pcm), 3200):
                    value = worker.call(op='audio', pcm=base64.b64encode(pcm[offset:offset + 3200]).decode())
                    segments.extend(value.get('segments', []))
                    preview = value.get('partial', '')
                    if preview and (not previews or previews[-1]['text'] != preview):
                        previews.append({'text': preview, 'audio_ms': (offset + 3200) // 32})
                segments.extend(worker.call(op='flush').get('segments', []))
            finally:
                worker.close()
            row = dict(question=question, rate=rate, segments=segments, previews=previews,
                       decode_ms=round((time.monotonic() - start) * 1000))
            rows.append(row)
            (root / 'asr.json').write_text(json.dumps(rows, indent=2, ensure_ascii=False) + '\n')
            print(question, rate, '=>', ''.join(x['text'] for x in segments), flush=True)
    if args.laya:
        install = (support / 'Laya/current').resolve()
        script = Path(__file__).resolve().parents[1] / 'Resources/LayaRuntime/worker.py'
        worker = Worker([str(install / 'venv/bin/python3'), '-I', '-B', str(script), '--installation', str(install)])
        results = []
        try:
            for question in questions:
                for text in [question, question + '？']:
                    value = worker.call(op='predict', text=text, context='')
                    results.append(dict(text=text, score=value['score']))
                    print(text, '=>', value['score'], flush=True)
        finally:
            worker.close()
        (root / 'laya.json').write_text(json.dumps(results, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
