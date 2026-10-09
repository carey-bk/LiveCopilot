#!/usr/bin/env python3
"""Render two static language pages. No build dependencies or third-party requests."""
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
download = json.loads((SOURCE / 'download.json').read_text())
github_download = download['github_url']
mirror_download = download.get('mirror_url')
for url in [github_download, mirror_download]:
    if url is None:
        continue
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('Download URLs must be public HTTPS URLs without credentials, query strings or fragments.')
content = json.loads((SOURCE / 'content.json').read_text())
assert content['zh'].keys() == content['en'].keys(), 'Both language pages need matching content.'
template = Template((SOURCE / 'template.html').read_text())
# Output is disposable; clean it so retired runtime assets cannot ship.
if OUTPUT.exists():
    shutil.rmtree(OUTPUT)
OUTPUT.mkdir()
for language, copy in content.items():
    english = language == 'en'
    # Only explicitly marked display strings support Markdown emphasis. Escape
    # first so supplied copy cannot introduce arbitrary HTML or attributes.
    data = {key: (re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', html.escape(value, quote=True))
                  if key.endswith('_rich') else html.escape(value, quote=True))
            for key, value in copy.items()}
    data['asset_version'] = hashlib.sha256(b''.join((SOURCE / name).read_bytes() for name in ['demo.js', 'phase5.css', 'product.css', 'styles.css'])).hexdigest()[:12]
    data.update(lang='en' if english else 'zh-CN', prefix='../' if english else '',
                home='./', zh_url='../' if english else './', en_url='./' if english else 'en/',
                zh_current='' if english else 'aria-current="page"',
                en_current='aria-current="page"' if english else '',
                canonical=BASE + ('en/' if english else ''),
                download_url=html.escape(mirror_download or github_download, quote=True),
                download_fallback=('<p class="install-note"><a class="text-link" href="' + html.escape(github_download, quote=True) + '">' + ('Alternative: GitHub download' if english else '备用：GitHub 下载') + '</a></p>') if mirror_download else '')
    title_lines = copy['hero_title'].split('\n')
    data['hero_title_markup'] = ''.join('<span class="title-line">' + ''.join('<span class="title-character">' + html.escape(c) + '</span>' for c in line) + '</span>' for line in title_lines) + '<span class="title-cursor" aria-hidden="true"></span>'
    # One product structure for every section; translated text is already escaped.
    components = SOURCE / 'components'
    answer_template = Template((components / 'product-answer.html').read_text())
    transcript_template = Template((components / 'product-transcript.html').read_text())
    product_template = Template((components / 'product-ui.html').read_text())
    answer = answer_template.substitute(data)
    transcript = transcript_template.substitute(data)
    for instance in ['hero', 'edge']:
        data['product_' + instance] = product_template.substitute(
            data, variant=instance, instance=instance,
            product_answer_fragment=answer, product_transcript_fragment=transcript)
    data['product_hero'] = data['product_hero'].replace('<h4>', '<h4 aria-level="2">')
    data['product_edge'] = data['product_edge'].replace(data['product_status'], data['product_ready'])
    data['product_edge'] = re.sub(r'(data-part="empty")\s+hidden', r'\1', data['product_edge'])
    data['product_answer'] = '<div data-product="answer">' + answer + '</div>'
    data['product_transcript'] = '<div data-product="transcript">' + transcript + '</div>'
    short_copy = dict(data, demo_reply=data['demo_reply'],
                      product_evidence_text=data['workflow_evidence_text'])
    data['product_workflow_answer'] = '<div data-product="workflow">' + answer_template.substitute(short_copy) + '</div>'
    data['product_case_answer'] = '<div data-product="case">' + answer + '</div>'
    destination = OUTPUT / ('en' if english else '')
    destination.mkdir(exist_ok=True)
    (destination / 'index.html').write_text(template.substitute(data))
for name in ['styles.css', 'product.css', 'phase5.css', 'demo.js']:
    shutil.copyfile(SOURCE / name, OUTPUT / name)
shutil.copytree(SOURCE / 'assets', OUTPUT / 'assets', dirs_exist_ok=True)
if (SOURCE / 'updates').exists():
    shutil.copytree(SOURCE / 'updates', OUTPUT / 'updates', dirs_exist_ok=True)
(OUTPUT / '.nojekyll').write_text('')
(OUTPUT / 'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n'
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    f'<url><loc>{BASE}</loc></url><url><loc>{BASE}en/</loc></url></urlset>\n')
print('Built Chinese and English pages in _site/.')
