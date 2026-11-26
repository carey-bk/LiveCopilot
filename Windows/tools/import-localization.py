"""Build-time import of Swift chrome and ICU Hans-Hant snapshots; Core has no ICU P/Invoke dependency."""
from pathlib import Path
import ctypes, ctypes.util, json, re
repo = Path(__file__).resolve().parents[2]
core = repo / 'StealthApp/Sources/Stealth/Core'
resources = repo / 'Windows/src/LiveCopilot.Core/Resources'
string = r'"(?:[^"\\]|\\.)*"'
localization = (core / 'Localization.swift').read_text()
copy = localization.split('static let chinese: [String: String] = [', 1)[1].split('\n    ]', 1)[0]
values = {json.loads(k): json.loads(v) for k, v in re.findall(f'({string}):\s*({string})', copy)}
http = (core / 'ServiceHTTPFailure.swift').read_text()
messages = dict(re.findall(r'case \.(\w+): return (' + string + ')', http))
for kind, value in re.findall(r'ServiceHTTPFailure.Kind\.(\w+).message:\s*(' + string + ')', copy):
    values[json.loads(messages[kind])] = json.loads(value)
assert len(values) == len(re.findall(r':\s*' + string, copy)), 'Lost dictionary entry'
(resources / 'Localization.zh-Hans.json').write_text(json.dumps(values, ensure_ascii=False, indent=2) + '\n')
libname = ctypes.util.find_library('icui18n')
lib = ctypes.CDLL(libname)
version = re.search(r'\.so\.(\d+)', libname).group(1)
u16 = ctypes.c_uint16
ptr = ctypes.POINTER(u16)
open_ = getattr(lib, 'utrans_openU_' + version)
open_.argtypes = [ptr, ctypes.c_int32, ctypes.c_int, ptr, ctypes.c_int32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int32)]
open_.restype = ctypes.c_void_p
transform = getattr(lib, 'utrans_transUChars_' + version)
transform.argtypes = [ctypes.c_void_p, ptr, ctypes.POINTER(ctypes.c_int32), ctypes.c_int32, ctypes.c_int32, ctypes.POINTER(ctypes.c_int32), ctypes.POINTER(ctypes.c_int32)]
name = 'Hans-Hant'.encode('utf-16-le')
err = ctypes.c_int32(0)
trans = open_((u16 * (len(name)//2)).from_buffer_copy(name), len(name)//2, 0, None, 0, None, ctypes.byref(err))
assert trans and err.value <= 0

def convert(text):
    data = text.encode('utf-16-le'); length = ctypes.c_int32(len(data)//2)
    buf = (u16 * (max(32, length.value * 4)))()
    ctypes.memmove(buf, data, len(data))
    end = ctypes.c_int32(length.value); err = ctypes.c_int32(0)
    transform(trans, buf, ctypes.byref(length), len(buf), 0, ctypes.byref(end), ctypes.byref(err))
    assert err.value <= 0
    return bytes(buf)[:length.value*2].decode('utf-16-le')

# Exact application phrases preserve contextual conversion (e.g. 历史记录).
phrases = set(values.values())
files = ['AppPreferences', 'Localization', 'ServiceGuide', 'AnalysisModelCatalog', 'AnalysisConfigurations', 'AnalysisPricing']
for file in files:
    for literal in re.findall(string, (core / (file + '.swift')).read_text()):
        if '\\(' in literal: continue
        try: text = json.loads(literal)
        except json.JSONDecodeError: continue
        if re.search('[\u3400-\u9fff]', text): phrases.add(text)
# Character fallback serves interpolated application copy; never run over arbitrary user text.
mapping = {chr(n): convert(chr(n)) for n in range(0x3400, 0xa000)}
mapping = {k:v for k,v in mapping.items() if k != v}
mapping.update({p: convert(p) for p in phrases if p != convert(p)})
(resources / 'Interface.zh-Hant.json').write_text(json.dumps(mapping, ensure_ascii=False, indent=2) + '\n')
print(f'Imported {len(values)} strings; {len(mapping)} ICU {version} conversion entries.')
