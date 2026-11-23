"""Build an isolated sandboxed Universal MAS engineering app from this checkout."""
import argparse
import json
import plistlib
import subprocess as sp
import tempfile
import runpy
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent
parser = argparse.ArgumentParser()
parser.add_argument("--laya-assets", type=Path)
parser.add_argument("--laya-evaluation", type=Path)
parser.add_argument("--evidence-dir", type=Path)
args = parser.parse_args()
if bool(args.laya_assets) != bool(args.laya_evaluation):
    parser.error("--laya-assets and --laya-evaluation must be passed together")
variant = (args.laya_assets, json.loads(args.laya_evaluation.read_text())) if args.laya_assets else None
work = Path(tempfile.mkdtemp(prefix="lc-mas-build-", dir=None))
staging = runpy.run_path(str(APP/"scripts/stage-offline-runtime.py"))
assets, runtime, pins, receipt = staging["stage"](work, variant)
def plist(path,obj):
    path.write_bytes(plistlib.dumps(obj))
child=work/"inherit.plist"
plist(child,{"com.apple.security.app-sandbox":True,"com.apple.security.inherit":True})
for binfile in [*runtime.glob("*.dylib"),runtime/"livecopilot-inference",runtime/"livecopilot-laya"]:
    sp.run(["codesign","-fs","-",*(["--entitlements",child] if binfile.suffix!=".dylib" else []),binfile],check=True)
info=plistlib.loads((APP/"Resources/Info.plist").read_bytes())
plist(work/"Info.plist",{k:v for k,v in info.items() if not k.startswith("SU")})
ent=plistlib.loads((APP/"Resources/LiveCopilot.entitlements").read_bytes())
ent.update({"com.apple.security.app-sandbox":True,"com.apple.security.files.user-selected.read-only":True})
plist(work/"App.entitlements",ent)
resources=[{"path":str(APP/"Resources"/name),"buildPhase":"resources",**({"type":"folder"} if (APP/"Resources"/name).is_dir() else {})}
           for name in ("AppIcon.icns","OpenAI-Logomark.svg","GitHub-Mark.svg","MetricIcons","ProviderLogos","AnalysisConfigurations.json","ThirdPartyNotices.txt")]
# Package source-specific notices with the files shipped in this variant.
staging["write_notices"](work, variant[1]["candidate"].split("-")[0] if variant else "w8")
resources[-1]["path"]=str(work/"ThirdPartyNotices.txt")
for item in assets.iterdir():
    resources.append({"path":str(item),"type":"folder","buildPhase":"resources"})
settings=dict(PRODUCT_BUNDLE_IDENTIFIER="com.livecopilot.mas.candidate",APP_DISPLAY_NAME="LiveCopilot MAS",INFOPLIST_FILE=str(work/"Info.plist"),
              CODE_SIGN_ENTITLEMENTS=str(work/"App.entitlements"),SWIFT_ACTIVE_COMPILATION_CONDITIONS="MAS_OFFLINE LAYA_NATIVE_ONLY",SWIFT_VERSION="5.0",
              CODE_SIGN_IDENTITY="-",ENABLE_HARDENED_RUNTIME="YES",ONLY_ACTIVE_ARCH="NO",ARCHS="arm64 x86_64")
target=dict(type="application",platform="macOS",deploymentTarget="14.0",configFiles={"Release":str(APP/"Version.xcconfig")},
            sources=[{"path":str(APP/"Sources")},*resources],settings={"base":settings})
(work/"project.json").write_text(json.dumps({"name":"LiveCopilotMAS","targets":{"LiveCopilotMAS":target}}))
sp.run(["xcodegen","generate","--spec",work/"project.json"],check=True)
sp.run(["xcodebuild","-project",work/"LiveCopilotMAS.xcodeproj","-scheme","LiveCopilotMAS","-configuration","Release","-destination","generic/platform=macOS","-derivedDataPath",work/"derived","ARCHS=arm64 x86_64","ONLY_ACTIVE_ARCH=NO","build"],check=True)
bundle=work/"derived/Build/Products/Release/LiveCopilotMAS.app"
contents=bundle/"Contents"
packaged=contents/"Resources/LocalRuntime"
for kind,items in (("Helpers",packaged.glob("livecopilot-*")),("Frameworks",packaged.glob("*.dylib"))):
    (contents/kind).mkdir(exist_ok=True)
    for item in items:
        item.rename(contents/kind/item.name)
sp.run(["codesign","-fs","-","--options","runtime","--entitlements",work/"App.entitlements",bundle],check=True)
sp.run(["codesign","--verify","--deep","--strict",bundle],check=True)
audit_args = ["python3", HERE/"audit-mas.py", bundle]
audit_args.append(APP/"Resources/OfflineAssetPins/w8-g64-receipt.json")
audit = sp.check_output(audit_args)
output = args.evidence_dir or work
output.mkdir(parents=True, exist_ok=True)
(output/"package.json").write_bytes(audit)
candidate = {"path": str(bundle), "arctic": {k:pins[k] for k in receipt},
             "bytes": sum(p.stat().st_size for p in bundle.rglob("*") if p.is_file())}
(output/"candidate.json").write_text(json.dumps(candidate, indent=2))
print(json.dumps(candidate), flush=True)
