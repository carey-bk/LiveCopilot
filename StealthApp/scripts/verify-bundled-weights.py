"""Validate signed-bundle resource contents against source-controlled release pins."""
import hashlib
import json
from pathlib import Path
import sys

pins = Path(__file__).resolve().parents[1]/"Resources/OfflineAssetPins"
resources = Path(sys.argv[1])/"Contents/Resources"
models = resources/"OfflineModels"
expected = json.loads((pins/"w8-g64-receipt.json").read_bytes())
for file in [models/"laya/receipt.json",resources/"LayaRuntime/native-coreml.json",resources/"LayaRuntime/native-w8.json"]:
    assert json.loads(file.read_bytes()) == expected, file
manifest = json.loads((pins/"assets.json").read_bytes())
locations = {"w8-g64": "laya", "arctic": "arctic-m-v2-int8", "notices": "laya"}
if (models/"zipformer-streaming-zh-en-hotwords-v1").exists():
    locations["zipformer"] = "zipformer-streaming-zh-en-hotwords-v1"
for name, digest in manifest.items():
    group, relative = name.split("/", 1)
    if group in locations:
        file = models/locations[group]/relative
        assert file.is_file() and hashlib.sha256(file.read_bytes()).hexdigest() == digest, file
arctic = models/"arctic-m-v2-int8"
expected_sizes = {name.split("/",1)[1]: (arctic/name.split("/",1)[1]).stat().st_size for name in manifest if name.startswith("arctic/")}
assert json.loads((arctic/"installed.json").read_bytes()) == expected_sizes
print("Verified bundled Arctic, Laya and included speech model receipts")
