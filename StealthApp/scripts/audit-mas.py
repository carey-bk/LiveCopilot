"""Inspect each shipped Mach-O, its load paths, signing and sandbox, plus the model receipts."""
import hashlib
import json
import plistlib
import re
import subprocess as sp
import sys
from pathlib import Path
h=Path(__file__).resolve().parent
app=Path(sys.argv[1])
contents=app/"Contents"
res=contents/"Resources"
def run(*cmd):
    return sp.check_output([str(x) for x in cmd],stderr=sp.DEVNULL)
def entitlements(p):
    raw=run("codesign","-d","--entitlements",":-",p)
    return plistlib.loads(raw) if raw.strip() else {}
sp.run(["codesign","--verify","--deep","--strict",app],check=True)
info = plistlib.loads((contents/"Info.plist").read_bytes())
assert info["LSMinimumSystemVersion"] == "14.0"
usage = {key: info[key] for key in ("NSMicrophoneUsageDescription", "NSScreenCaptureUsageDescription", "NSSpeechRecognitionUsageDescription")}
assert all(value.strip() for value in usage.values())
sp.run(["python3", h/"verify-bundled-weights.py", app], stdout=sys.stderr, check=True)
ent=entitlements(app)
assert all(ent.get(key) is True for key in ("com.apple.security.network.client", "com.apple.security.device.audio-input"))
assert ent.get("com.apple.security.app-sandbox") is True
code={}
for f in [*sorted((contents/"MacOS").iterdir()),*sorted((contents/"Helpers").iterdir()),*sorted((contents/"Frameworks").iterdir())]:
    archs=run("lipo","-archs",f).decode().split()
    assert set(archs)=={"arm64","x86_64"}
    links=run("otool","-L",f).decode().splitlines()
    deps=sorted({line.strip().split(" (compatibility")[0] for line in links if line.startswith("\t")})
    assert all(d.startswith(("/System/Library/","/usr/lib/","@rpath/","@executable_path/")) for d in deps)
    for d in deps:
        if d.startswith("@rpath/") and not d.startswith("@rpath/libswift"):
            assert (contents/"Frameworks"/d[len("@rpath/"):]).exists(),d
    record=dict(architectures=archs,dependencies=deps,sha256=hashlib.sha256(f.read_bytes()).hexdigest())
    record["deployment_targets"] = {}
    record["rpaths"] = {}
    for arch in archs:
        build = run("xcrun","vtool","-arch",arch,"-show-build",f).decode()
        floor = next(line.split()[-1] for line in build.splitlines() if line.strip().startswith("minos "))
        assert floor == "14.0", (f.name, arch, floor)
        record["deployment_targets"][arch] = floor
        load = run("otool","-arch",arch,"-l",f).decode()
        rpaths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (\S+)",load)
        assert set(rpaths) <= {"/usr/lib/swift","@loader_path","@executable_path/../Frameworks"}, (f, arch, rpaths)
        record["rpaths"][arch] = rpaths
        imports = run("nm","-arch",arch,"-u",f)
        assert not re.search(rb"\b_(?:CGS[A-Z]|SLS[A-Z]|_AXUI|_LS[A-Z])",imports), (f,arch)
        assert b"/PrivateFrameworks/" not in run("otool","-arch",arch,"-L",f)
    raw = f.read_bytes()
    for symbol in (b"CGSMainConnectionID", b"CGRegionCreateWithRect", b"CGSSetWindowCaptureExcludeShape"):
        assert symbol not in raw, (f.name, symbol)
    if f.parent.name=="Helpers":
        signed=entitlements(f)
        assert signed.get("com.apple.security.inherit") and signed.get("com.apple.security.app-sandbox")
        record["entitlements"]=signed
    code[str(f.relative_to(contents))]=record
macho_magic = {bytes.fromhex(x) for x in ("feedface","cefaedfe","feedfacf","cffaedfe","cafebabe","bebafeca","cafebabf","bfbafeca")}
for path in contents.rglob("*"):
    if path.is_file():
        with path.open("rb") as stream:
            header = stream.read(4)
        if header in macho_magic:
            assert str(path.relative_to(contents)) in code, path
        assert not header.startswith(b"#!"), path
assert not any(p.suffix in (".gguf",".py") or "Sparkle" in p.name for p in contents.rglob("*"))
assert not any(k.startswith("SU") for k in plistlib.loads((contents/"Info.plist").read_bytes()))
def size(p):return sum(x.stat().st_size for x in p.rglob("*") if x.is_file())
assert size(res/"LayaRuntime")<=2*1024*1024
expected = Path(sys.argv[2]) if len(sys.argv) > 2 else h.parent/"Resources/OfflineAssetPins/w8-g64-receipt.json"
pins=json.loads(expected.read_bytes())
laya=res/"OfflineModels/laya"
resources = res/"LayaRuntime"
assert json.loads((laya/"receipt.json").read_bytes())==pins==json.loads((resources/f'native-{pins["precision"]}.json').read_bytes())
if pins["precision"] != "fp16":
    assert json.loads((resources/"native-coreml.json").read_bytes()) == pins
    assert (laya/"embeddings.bin").is_file() and (laya/"encoder.mlmodelc").is_dir()
    assert not (laya/"fp16.mlmodelc").exists()
for k,v in pins["files"].items():assert hashlib.sha256((laya/k).read_bytes()).hexdigest()==v
for directory in (res/"OfflineModels").iterdir():
    if directory==laya:continue
    for k,v in json.loads((directory/"installed.json").read_bytes()).items():assert (directory/k).stat().st_size==v
print(json.dumps(dict(usage_descriptions=usage, minimum_system_version=info["LSMinimumSystemVersion"],architecture_evidence=code,bundle=str(app),bytes=size(app),entitlements=ent,laya_runtime_bytes=size(res/"LayaRuntime"),laya_precision=pins["precision"],
                      resources={x.name:size(x) for x in (res/"OfflineModels").iterdir()},signed="ad-hoc",deep_strict=True),indent=2))
