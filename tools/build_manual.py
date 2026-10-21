# -*- coding: utf-8 -*-
# ============================================================
# build_manual.py : README と docs/*.md から説明書 app/manual.html (1 冊) を作る
#   Author: yuichi
#
#   開発側の PC で使う道具です。社内 PC (監視 PC) では不要です。
#   MD を直したら、これを実行して manual.html を作り直してください。
#
#   必要なもの: Python 3.8 以上、markdown-it-py、mdit-py-plugins
#     pip install markdown-it-py mdit-py-plugins
#   使い方 (リポジトリの一番上で):
#     python tools/build_manual.py
#
#   出力は外部ファイルに頼らない 1 ファイルの HTML です (画像も埋め込み)。
#   Edge などで file:// のまま開けます。
# ============================================================
import base64
import datetime
import html
import os
import re
import sys
import urllib.parse

from markdown_it import MarkdownIt
from mdit_py_plugins.anchors import anchors_plugin

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'app', 'manual.html')

# 説明書に入れる順番: (キー, MD のパス, 目次での見出し)
DOCS = [
    ('readme',      'README.md',                 'はじめに・使い方'),
    ('architecture', 'docs/architecture.md',     '設計メモ'),
    ('functions',   'docs/functions.md',         '関数表'),
    ('at-commands', 'docs/at-commands.md',       'AT コマンドの対応範囲'),
    ('at-command-table', 'docs/at-command-table.md', 'AT コマンド表'),
    ('deploy',      'docs/deploy-via-git.md',    'Git 経由で社内 PC に導入する'),
]
# MD のファイル名 → キー (リンクの付け替えに使う)
FILE_KEY = {}
for key, path, _ in DOCS:
    FILE_KEY[path] = key
    FILE_KEY[os.path.basename(path)] = key


def slugify(text):
    """GitHub と同じ考え方の見出し ID (小文字化、記号を除く、空白は -)。日本語は残す。"""
    s = text.strip().lower()
    s = re.sub(r'[^\w\- ]', '', s, flags=re.UNICODE)
    return s.replace(' ', '-')


def render(key, path):
    with open(os.path.join(ROOT, path), encoding='utf-8-sig') as f:
        src = f.read()
    md = (MarkdownIt('commonmark', {'html': True, 'linkify': False, 'typographer': False})
          .enable('table').enable('strikethrough'))
    md.use(anchors_plugin, min_level=1, max_level=4,
           slug_func=lambda s, k=key: k + '-' + slugify(s))
    tokens = md.parse(src)
    # 目次用に h2 を集める
    heads = []
    for i, t in enumerate(tokens):
        if t.type == 'heading_open' and t.tag in ('h1', 'h2'):
            text = tokens[i + 1].content
            heads.append((t.tag, t.attrs.get('id'), re.sub(r'[*`]', '', text)))
    body = md.renderer.render(tokens, md.options, {})
    body = fix_links(body, key, path)
    return body, heads


def fix_links(body, key, path):
    base_dir = os.path.dirname(path)

    def href(m):
        url = html.unescape(m.group(1))
        if re.match(r'^[a-z]+:', url):          # http: https: mailto: など
            return m.group(0)
        if url.startswith('#'):                  # 同じ文書の中
            frag = urllib.parse.unquote(url[1:])
            return 'href="#%s-%s"' % (key, slugify(frag))
        file, _, frag = url.partition('#')
        file = urllib.parse.unquote(file)
        norm = os.path.normpath(os.path.join(base_dir, file)).replace(os.sep, '/')
        k = FILE_KEY.get(norm) or FILE_KEY.get(os.path.basename(norm))
        if k:                                    # ほかの MD → 説明書の中の節
            frag = urllib.parse.unquote(frag)
            return 'href="#%s"' % ((k + '-' + slugify(frag)) if frag else 'doc-' + k)
        # それ以外 (LICENSE など) は、app/ から見た相対パスにする
        rel = os.path.relpath(os.path.join(ROOT, norm), os.path.dirname(OUT)).replace(os.sep, '/')
        return 'href="%s"' % html.escape(rel)

    def img(m):
        src = html.unescape(m.group(1))
        p = os.path.normpath(os.path.join(ROOT, base_dir, urllib.parse.unquote(src)))
        if os.path.isfile(p):
            ext = os.path.splitext(p)[1].lower().lstrip('.')
            mime = {'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'gif': 'image/gif', 'svg': 'image/svg+xml'}.get(ext, 'application/octet-stream')
            with open(p, 'rb') as f:
                data = base64.b64encode(f.read()).decode('ascii')
            return 'src="data:%s;base64,%s"' % (mime, data)
        return m.group(0)

    body = re.sub(r'href="([^"]*)"', href, body)
    body = re.sub(r'src="([^"]*)"', img, body)
    return body


CSS = """
:root { --fg:#1f2328; --sub:#59636e; --line:#d1d9e0; --bg:#ffffff; --code:#f6f8fa; --accent:#0969da; --head:#0b1120; }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg);
       font-family:"Yu Gothic UI","Meiryo UI","Meiryo",sans-serif; font-size:15px; line-height:1.75; }
header.top { background:var(--head); color:#f8fafc; padding:18px 24px; }
header.top h1 { margin:0; font-size:1.4rem; color:#38bdf8; }
header.top p { margin:4px 0 0; font-size:.85rem; color:#94a3b8; }
main { max-width:980px; margin:0 auto; padding:16px 24px 64px; }
nav.toc { border:1px solid var(--line); border-radius:8px; padding:12px 20px; margin:16px 0 32px; background:#fbfcfd; }
nav.toc h2 { margin:0 0 6px; font-size:1.05rem; border:0; }
nav.toc ol { margin:0; padding-left:1.4em; }
nav.toc ol ol { padding-left:1.2em; font-size:.92rem; }
nav.toc a { text-decoration:none; }
section.doc { border-top:3px solid var(--head); padding-top:8px; margin-top:48px; }
h1,h2,h3,h4 { line-height:1.4; scroll-margin-top:12px; }
h1 { font-size:1.6rem; }
h2 { font-size:1.3rem; border-bottom:1px solid var(--line); padding-bottom:4px; margin-top:2em; }
h3 { font-size:1.12rem; margin-top:1.6em; }
a { color:var(--accent); }
code { font-family:Consolas,"BIZ UDGothic","MS Gothic",monospace; font-size:.9em; background:var(--code); padding:.1em .35em; border-radius:4px; }
pre { background:var(--code); border:1px solid var(--line); border-radius:6px; padding:12px 14px; overflow-x:auto; line-height:1.5; }
pre code { background:none; padding:0; font-size:.88em; }
table { border-collapse:collapse; margin:12px 0; display:block; overflow-x:auto; max-width:100%; }
th, td { border:1px solid var(--line); padding:6px 10px; vertical-align:top; }
th { background:#f0f3f6; text-align:left; white-space:nowrap; }
img { max-width:100%; border:1px solid var(--line); border-radius:6px; }
.back { display:inline-block; margin-top:8px; font-size:.85rem; }
@media print {
  header.top { background:none; color:#000; border-bottom:2px solid #000; }
  header.top h1 { color:#000; }
  nav.toc { break-after:page; }
  section.doc { break-before:page; border-top:0; margin-top:0; }
  .back { display:none; }
  a { color:inherit; text-decoration:none; }
  pre, table, img { break-inside:avoid; }
}
"""


def main():
    sections = []
    toc = []
    for key, path, label in DOCS:
        body, heads = render(key, path)
        sub = ''.join('<li><a href="#%s">%s</a></li>' % (i, html.escape(t)) for tag, i, t in heads if tag == 'h2')
        toc.append('<li><a href="#doc-%s">%s</a>%s</li>' % (key, html.escape(label), ('<ol>%s</ol>' % sub) if sub else ''))
        sections.append('<section class="doc" id="doc-%s">\n<p class="back"><a href="#toc">▲ 目次へ</a>　(元原稿: %s)</p>\n%s</section>'
                        % (key, html.escape(path), body))
    today = datetime.date.today().isoformat()
    page = """<!DOCTYPE html>
<!-- CsqWatch 説明書 (tools/build_manual.py で生成。直接編集せず、元の MD を直して作り直すこと)   Author: yuichi -->
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CsqWatch 説明書</title>
<style>%s</style>
</head>
<body>
<header class="top">
  <h1>CsqWatch 説明書</h1>
  <p>Author: yuichi ／ 作成 %s ／ README と docs の MD から生成(Ctrl+F で検索できます)</p>
</header>
<main>
<nav class="toc" id="toc">
<h2>目次</h2>
<ol>
%s
</ol>
</nav>
%s
</main>
</body>
</html>
""" % (CSS, today, '\n'.join(toc), '\n'.join(sections))
    with open(OUT, 'w', encoding='utf-8', newline='\r\n') as f:
        f.write(page)
    print('作成しました: ' + os.path.relpath(OUT, ROOT) + '  (%d KB)' % (os.path.getsize(OUT) // 1024))


if __name__ == '__main__':
    sys.exit(main())
