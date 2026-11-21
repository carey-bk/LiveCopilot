"""Stage pinned universal offline runtimes outside the source tree for both distribution channels."""
from pathlib import Path
import os, hashlib, json, shutil, subprocess as sp, sys, tempfile
APP = Path(__file__).resolve().parents[1]
PINS = APP / "Resources/OfflineAssetPins"

def asset_root():
    return Path(os.environ.get("LIVECOPILOT_ASSET_ROOT", Path.home()/"Library/Application Support/LiveCopilotBuildAssets/v1")).expanduser().resolve()

def sha256(path):
    with path.open("rb") as stream:
        checksum = hashlib.sha256()
        for block in iter(lambda: stream.read(1 << 20), b""):
            checksum.update(block)
    return checksum.hexdigest()

def verify_assets(root):
    manifest = json.loads((PINS/"assets.json").read_bytes())
    for name, digest in manifest.items():
        file = root/name
        if not file.is_file() or not file.resolve().is_relative_to(root) or sha256(file) != digest:
            raise ValueError(f"Missing or mismatched build asset: {file}")
    return manifest


def stage(work, laya_variant=None, *, bundle_speech=True):
    root = asset_root()
    manifest = verify_assets(root)
    assets = work / "resources"
    runtime = assets / "LocalRuntime"
    model = assets / "OfflineModels/arctic-m-v2-int8"
    runtime.mkdir(parents=True)
    model.mkdir(parents=True)
    pins = json.loads((PINS / "arctic.json").read_text())
    receipt = {}
    def copy_verified(src, dest, sha):
        shutil.copyfile(src, dest)
        if sha256(dest) != sha:
            raise ValueError(f"Invalid staged asset: {src}")

    for name in ("ms-model_int8.onnx", "tokenizer.json"):
        copy_verified(root/"arctic"/name, model / name, pins[name]["sha256"])
        receipt[name] = (model / name).stat().st_size
    (model / "installed.json").write_text(json.dumps(receipt))
    for name in ("libonnxruntime.dylib", "libsherpa-onnx-c-api.dylib", "LICENSE-zipformer.txt", "NOTICE-zipformer.txt", "zipformer-bpe.vocab"):
        copy_verified(root/"runtime"/name, runtime/name, manifest["runtime/"+name])
    # Raise only the packaged copies' advertised floor. Preserve the original SDK and slices.
    if bundle_speech:
        for library in runtime.glob("*.dylib"):
            slices = []
            for arch in ("arm64", "x86_64"):
                thin = work/(library.name+"-"+arch)
                raised = Path(str(thin)+".min14")
                sp.run(["lipo",library,"-thin",arch,"-output",thin],check=True)
                load = sp.check_output(["xcrun","vtool","-show-build",thin],text=True)
                sdk = next(line.split()[-1] for line in load.splitlines() if line.strip().startswith("sdk "))
                sp.run(["xcrun","vtool","-set-build-version","macos","14.0",sdk,"-replace","-output",raised,thin],check=True)
                slices.append(raised)
            sp.run(["lipo","-create",*slices,"-output",library],check=True)
    include = work / "include"
    (include / "sherpa-onnx/c-api").mkdir(parents=True)
    copy_verified(root/"headers/ort.h", include / "ort.h","573a117ae6b83ead7f53da6cedaa0d7b7d9cdb45c0ba4726bac9081e67696a82")
    copy_verified(root/"headers/sherpa-onnx/c-api/c-api.h", include / "sherpa-onnx/c-api/c-api.h","2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce")
    sp.run(["xcrun","clang++","-O2","-std=c++17","-fobjc-arc","-arch","arm64","-arch","x86_64","-mmacosx-version-min=14.0","-I",include,
            APP/"Native/LocalInference.mm",APP/"Native/tokenizer/arctic_tokenizer.cpp","-framework","Foundation","-L",runtime,"-lonnxruntime","-lsherpa-onnx-c-api","-Wl,-rpath,@executable_path/../Frameworks","-o",runtime/"livecopilot-inference"],check=True)
    # Use the exact compiled graph that passed the signed-protocol parity run.
    lr = assets/"LayaRuntime"
    lr.mkdir()
    source = root/"w8-g64"
    receipt_path = PINS/"w8-g64-receipt.json"
    pinned = json.loads(receipt_path.read_bytes())
    if laya_variant is not None:
        source, evidence = laya_variant
        if evidence.get("candidate") != "w8-g64" or not evidence.get("accepted"):
            raise ValueError("Expected accepted W8 G64 evaluation")
    if pinned != json.loads((source/"receipt.json").read_bytes()):
        raise ValueError("W8 G64 receipt mismatch")
    precision = pinned["precision"]
    bundle_laya = assets/"OfflineModels/laya"
    for name, digest in pinned["files"].items():
        (bundle_laya/name).parent.mkdir(parents=True,exist_ok=True)
        copy_verified(source/name,bundle_laya/name,digest)
    for name in ("LICENSE","NOTICE","FINETUNE-NOTICE.txt"):
        copy_verified(root/"notices"/name,bundle_laya/name,manifest["notices/"+name])
    for dest in (lr/f"native-{precision}.json", bundle_laya/"receipt.json"):
        shutil.copyfile(receipt_path, dest)
    shutil.copyfile(receipt_path, lr/"native-coreml.json")
    shutil.copyfile(APP/"Resources/LayaRuntime/native-question.json",lr/"native-question.json")
    if sum(f.stat().st_size for f in lr.rglob("*") if f.is_file()) > 2*1024*1024:
        raise ValueError("LayaRuntime exceeds 2 MiB")
    native = APP/"Native/Laya"
    slices = []
    for arch in ("arm64","x86_64"):
        binary=work/("laya-"+arch)
        sp.run(["xcrun","swiftc","-O","-target",arch+"-apple-macosx14.0","-D","MAS_COREML",
                native/"main.swift",native/"Tokenizer.swift",native/"CoreMLEngine.swift","-o",binary],check=True)
        slices.append(binary)
    sp.run(["lipo","-create",*slices,"-output",runtime/"livecopilot-laya"],check=True)
    if bundle_speech:
        zip_dir = assets/"OfflineModels/zipformer-streaming-zh-en-hotwords-v1"
        zip_dir.mkdir()
        speech = json.loads((APP.parent/"docs/zipformer-model-manifest.json").read_text())["objects"]
        for item in speech:
            name=item["name"]
            copy_verified(root/"zipformer"/name,zip_dir/name,item["sha256"])
        (zip_dir/"installed.json").write_text(json.dumps({i["name"]:i["size"] for i in speech}))
    return assets, runtime, pins, receipt

def write_notices(work, precision="w8"):
    notices=(APP/"Resources/ThirdPartyNotices.txt").read_text()
    begin=notices.index("Native runtime versions:")
    end=notices.index("sherpa-onnx (Apache-2.0)",begin)
    notices=notices[:begin]+f"""Bundled models in the Mac App Store engineering candidate:
    Snowflake Arctic embed m v2.0, Apache-2.0, https://huggingface.co/Snowflake/snowflake-arctic-embed-m-v2.0
    Bilingual Zipformer, Apache-2.0, https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20
    Silero VAD, MIT, https://github.com/snakers4/silero-vad
    Fine-tuned Laya {precision.upper()}, see OfflineModels/laya/LICENSE, NOTICE and FINETUNE-NOTICE.txt.

    """+notices[end:]
    (work/"ThirdPartyNotices.txt").write_text(notices)

def embed_web(contents):
    # Only replace managed build outputs under the destination app.
    if contents.parent.suffix != ".app" or contents.name != "Contents" or "/Applications/" in str(contents.resolve()):
        raise ValueError("Expected a staging app")
    with tempfile.TemporaryDirectory(prefix="lc-web-stage-",dir=None) as folder:
        work=Path(folder)
        assets,runtime,_,_=stage(work,bundle_speech=False)
        write_notices(work)
        for section,pattern in (("Helpers","livecopilot-*"),("Frameworks","*.dylib")):
            dest=contents/section
            dest.mkdir(exist_ok=True)
            for item in runtime.glob(pattern):
                target=dest/item.name
                shutil.copy2(item,target)
                sp.run(["codesign","-fs","-",target],check=True)
        for item in list(runtime.glob("*.dylib"))+list(runtime.glob("livecopilot-*")):
            item.unlink()
        res=contents/"Resources"
        for item in assets.iterdir():
            dest=res/item.name
            if dest.exists(): shutil.rmtree(dest)
            shutil.copytree(item,dest)
        shutil.copy2(work/"ThirdPartyNotices.txt",res/"ThirdPartyNotices.txt")

if __name__=="__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--verify-assets":
        print(f"Verified {len(verify_assets(asset_root()))} pinned files in {asset_root()}")
    elif len(sys.argv) == 3 and sys.argv[1] == "--import-assets":
        source = Path(sys.argv[2]).expanduser().resolve()
        manifest = verify_assets(source)
        target = asset_root()
        if target.exists():
            verify_assets(target)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(dir=target.parent, prefix=".asset-import-") as scratch:
                staged = Path(scratch)/"v1"
                for name in manifest:
                    dest = staged/name
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source/name, dest)
                verify_assets(staged)
                staged.rename(target)
        print(f"Verified {len(manifest)} pinned files in {target}")
    elif len(sys.argv) == 2 and not sys.argv[1].startswith("-"):
        embed_web(Path(sys.argv[1]))
    else:
        sys.exit("Usage: stage-offline-runtime.py CONTENTS | --verify-assets | --import-assets SOURCE_ROOT")
