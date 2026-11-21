#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
model="${1:?Pass an isolated native model directory}"
work="$(mktemp -d)"
trap 'rm -r "$work"' EXIT
suite="${2:-research_notes/laya-slim-eval}"
[[ -f "$suite/oracle.json" && -f "$suite/oracle-long.json" && -f "$suite/long_suite.py" ]] || { echo "Pass the frozen tokenizer fixture directory as argument 2." >&2; exit 1; }
python3 -B - "$suite" "$work/long.json" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from long_suite import expand
rows = json.loads((Path(sys.argv[1]) / "oracle-long.json").read_bytes())
Path(sys.argv[2]).write_text(json.dumps([expand(row) for row in rows], ensure_ascii=False))
PY
xcrun swiftc -O -parse-as-library StealthApp/Native/Laya/Tokenizer.swift \
  StealthApp/Tests/LayaNativeTokenizerChecks.swift -o "$work/checks"
"$work/checks" "$model/tokenizer/tokenizer.json" StealthApp/Resources/LayaRuntime/native-question.json \
  "$suite/oracle.json" "$work/long.json"
