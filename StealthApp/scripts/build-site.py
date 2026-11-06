#!/usr/bin/env python3
"""Render three static language pages. No build dependencies or third-party requests."""
from pathlib import Path
from string import Template
import hashlib
import html
import json
import re
import shutil
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'site'
OUTPUT = ROOT / '_site'
BASE = 'https://carey-bk.github.io/LiveCopilot/'
ASSETS = ['styles.css', 'demo.js']
download = json.loads((SOURCE / 'download.json').read_text())
github_download = download['github_url']
mirror_download = download.get('mirror_url')
for url in [github_download, mirror_download]:
    if url is None:
        continue
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('Download URLs must be public HTTPS URLs without credentials, query strings or fragments.')
version = download['version']
assert re.fullmatch(r'\d+\.\d+\.\d+', version), 'download.json needs a semantic version.'
assert re.fullmatch(r'[0-9a-f]{64}', download['sha256']), 'download.json needs a SHA-256 digest.'
release_url = f'https://github.com/carey-bk/LiveCopilot/releases/tag/v{version}'
size = f"{download['size'] / 1_000_000:.2f} MB"
content = json.loads((SOURCE / 'content.json').read_text())
assert all(copy.keys() == content['en'].keys() for copy in content.values()), 'All language pages need matching content.'
locales = {'zh': ('', 'zh-Hans'), 'en': ('en', 'en'), 'zh-Hant': ('zh-Hant', 'zh-Hant')}
examples = json.loads((SOURCE / 'examples.json').read_text())
assert all(examples[language].keys() == examples['en'].keys() for language in locales), 'All languages need matching examples.'
template = Template((SOURCE / 'template.html').read_text())
asset_version = hashlib.sha256(b''.join((SOURCE / name).read_bytes() for name in ASSETS)).hexdigest()[:12]
# Output is disposable; clean it so retired runtime assets cannot ship.
if OUTPUT.exists():
    shutil.rmtree(OUTPUT)
OUTPUT.mkdir()


def phrases(text, english):
    """Chinese copy marked with | breaks only between phrases; English wraps normally."""
    parts = [html.escape(part, quote=True) for part in text.split('|')]
    return ' '.join(parts) if english else '<wbr>'.join(f'<span class="ph">{part}</span>' for part in parts)


for language, copy in content.items():
    english = language == 'en'
    # Version and size come from download.json so the copy cannot drift from the release.
    copy = {key: value.replace('{version}', version).replace('{size}', size) for key, value in copy.items()}
    data = {key: html.escape(value, quote=True) for key, value in copy.items()}
    sample = examples[language]
    hero = sample['hero']
    case = sample['meeting']
    path, lang = locales[language]
    prefix = '../' if path else ''
    badge = '<b>' + '.'.join(version.split('.')[:2]) + '</b>'
    label = '<span>' + data['pill_text'] + '</span>'
    data.update(
        lang=lang, prefix=prefix, home='./', version=version, sha256=download['sha256'],
        asset_version=asset_version, release_url=release_url,
        zh_url=prefix or './', en_url=prefix + 'en/', hant_url=prefix + 'zh-Hant/',
        zh_current='aria-current="page"' if language == 'zh' else '',
        en_current='aria-current="page"' if english else '',
        hant_current='aria-current="page"' if language == 'zh-Hant' else '',
        canonical=BASE + (path + '/' if path else ''),
        demo_examples=json.dumps(sample, ensure_ascii=False).replace('<', '\\u003c'),
        download_url=html.escape(mirror_download or github_download, quote=True),
        fallback_markup=('<a class="fallback" href="' + html.escape(github_download, quote=True) + '">' + data['download_fallback_label'] + '</a>') if mirror_download else '',
        # English reads "New in 2.7", so the version badge follows the text there.
        # The pill opens the published release notes.
        pill_markup='<a class="release-pill' + (' end' if english else '') + '" href="' + release_url + '">' + (label + badge if english else badge + label) + '</a>',
        # The settings counter shows the example's real length against the app's 4000-character limit.
        style_count=str(len(copy['style_example'])),
        hero_subtitle_markup=phrases(copy['hero_subtitle_phrases'], english),
        hero_cost_markup=phrases(copy['hero_cost_phrases'], english),
        hero_question=html.escape((' ' if english else '').join(hero['question'])),
        hero_answer_markup=(' ' if english else '').join(f'<span class="ph">{html.escape(part)}</span>' for part in hero['answer']),
        # The scenario panel is complete without JavaScript; the script swaps examples in place.
        case_question=html.escape(case['question']), case_answer=html.escape(case['answer']),
        case_passage_text=html.escape(case['passage']),
        case_documents_markup=''.join(f'<span>{html.escape(name)}</span>' for name in case['documents']),
        case_sources_markup=''.join(f'<p>{html.escape(source)}</p>' for source in case['sources']),
    )
    destination = OUTPUT / path
    destination.mkdir(exist_ok=True)
    (destination / 'index.html').write_text(template.substitute(data))
for name in ASSETS:
    shutil.copyfile(SOURCE / name, OUTPUT / name)
shutil.copytree(SOURCE / 'assets', OUTPUT / 'assets', dirs_exist_ok=True)
if (SOURCE / 'updates').exists():
    shutil.copytree(SOURCE / 'updates', OUTPUT / 'updates', dirs_exist_ok=True)
(OUTPUT / '.nojekyll').write_text('')
(OUTPUT / 'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n'
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    f'<url><loc>{BASE}</loc></url><url><loc>{BASE}en/</loc></url><url><loc>{BASE}zh-Hant/</loc></url></urlset>\n')
print('Built English, Traditional Chinese and Simplified Chinese pages in _site/.')
