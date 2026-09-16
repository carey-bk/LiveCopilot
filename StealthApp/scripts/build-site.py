#!/usr/bin/env python3
"""Render two static language pages. No frontend dependencies or third-party requests."""
from pathlib import Path
from string import Template
import html
import json
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'site'
OUTPUT = ROOT / '_site'
BASE = 'https://carey-bk.github.io/LiveCopilot/'
content = json.loads((SOURCE / 'content.json').read_text())
assert content['zh'].keys() == content['en'].keys(), 'Both language pages need matching content.'
template = Template((SOURCE / 'template.html').read_text())
OUTPUT.mkdir(exist_ok=True)
for language, copy in content.items():
    english = language == 'en'
    # Only explicitly marked display strings support Markdown emphasis. Escape
    # first so supplied copy cannot introduce arbitrary HTML or attributes.
    data = {key: (re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', html.escape(value, quote=True))
                  if key.endswith('_rich') else html.escape(value, quote=True))
            for key, value in copy.items()}
    data.update(lang='en' if english else 'zh-CN', prefix='../' if english else '',
                home='./', zh_url='../' if english else './', en_url='./' if english else 'en/',
                zh_current='' if english else 'aria-current="page"',
                en_current='aria-current="page"' if english else '',
                canonical=BASE + ('en/' if english else ''),
                download_url='https://github.com/carey-bk/LiveCopilot/releases/download/v1.3.2/LiveCopilot-1.3.2-macOS-universal.dmg')
    destination = OUTPUT / ('en' if english else '')
    destination.mkdir(exist_ok=True)
    (destination / 'index.html').write_text(template.substitute(data))
for name in ['styles.css', 'demo.js']:
    shutil.copyfile(SOURCE / name, OUTPUT / name)
shutil.copytree(SOURCE / 'assets', OUTPUT / 'assets', dirs_exist_ok=True)
(OUTPUT / '.nojekyll').write_text('')
(OUTPUT / 'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n'
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    f'<url><loc>{BASE}</loc></url><url><loc>{BASE}en/</loc></url></urlset>\n')
print('Built Chinese and English pages in _site/.')
