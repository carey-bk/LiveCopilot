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


def public_https(url, allow_query=False):
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.fragment or (parsed.query and not allow_query):
        raise ValueError('Download URLs must be public HTTPS URLs without credentials or fragments.')


public_https(github_download)
# New downloads are free: GitHub is the main source, netdisks are labelled backups.
# Netdisk share links may carry their extraction code as a query; the code is also shown as text.
BACKUP_HOSTS = {'baidu': 'pan.baidu.com', 'quark': 'pan.quark.cn'}
backups = download.get('backups', [])
for backup in backups:
    public_https(backup['url'], allow_query=True)
    assert urlsplit(backup['url']).hostname == BACKUP_HOSTS[backup['name']], 'Backup links must point at their netdisk.'
version = download['version']
assert re.fullmatch(r'\d+\.\d+(?:\.\d+)?', version), 'download.json needs a MAJOR.MINOR version (older releases had a patch).'
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


def source_chip(source):
    """'[S1] Name · Part' becomes the answer card's S1 source chip."""
    match = re.match(r'\[(S\d+)\]\s*(.*)', source)
    badge, name = match.groups() if match else ('', source)
    return f'<span class="src-chip"><b>{html.escape(badge)}</b>{html.escape(name)}</span>'


def backup_links(copy, prefix, label_key, anchor=False):
    """Secondary netdisk buttons: grey official logo, name, and the extraction code beside it."""
    if not backups:
        return ''
    items = []
    for backup in backups:
        name = html.escape(copy['backup_' + backup['name']])
        code = f'<span class="code">{html.escape(copy["backup_code"])} {html.escape(backup["code"])}</span>' if backup.get('code') else ''
        logo = f'<img src="{prefix}assets/netdisk-{backup["name"]}.png" width="16" height="16" alt="" />'
        items.append(f'<a class="mirror" href="{html.escape(backup["url"], quote=True)}" rel="noopener">{logo}{name}{code}</a>')
    anchor_id = ' id="backup-downloads"' if anchor else ''
    return f'<div class="mirrors"{anchor_id}><span class="mirrors-label">{html.escape(copy[label_key])}</span>{"".join(items)}</div>'


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
    badge = '<b>' + version + '</b>'
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
        download_url=html.escape(github_download, quote=True),
        backup_markup=backup_links(copy, prefix, 'backup_label', anchor=True),
        backup_hero_markup=backup_links(copy, prefix, 'backup_hero'),
        # English reads "New in 2.7", so the version badge follows the text there.
        # The pill opens the published release notes.
        pill_markup='<a class="release-pill' + (' end' if english else '') + '" href="' + release_url + '">' + (label + badge if english else badge + label) + '</a>',
        # The settings counter shows the example's real length against the app's 4000-character limit.
        style_count=str(len(copy['style_example'])),
        # Source chips carry their S1/S2 badge separately, as in the 2.11 answer card.
        hero_chip1=html.escape(re.sub(r'^\[S\d\]\s*', '', copy['hero_source1'])),
        hero_chip2=html.escape(re.sub(r'^\[S\d\]\s*', '', copy['hero_source2'])),
        hero_subtitle_markup=phrases(copy['hero_subtitle_phrases'], english),
        hero_cost_markup=phrases(copy['hero_cost_phrases'], english),
        hero_question=html.escape((' ' if english else '').join(hero['question'])),
        hero_answer_markup=(' ' if english else '').join(f'<span class="ph">{html.escape(part)}</span>' for part in hero['answer']),
        # The scenario panel is complete without JavaScript; the script swaps examples in place.
        case_question=html.escape(case['question']), case_answer=html.escape(case['answer']),
        case_passage_text=html.escape(case['passage']),
        case_documents_markup=''.join(f'<span>{html.escape(name)}</span>' for name in case['documents']),
        case_sources_markup=''.join(source_chip(source) for source in case['sources']),
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
