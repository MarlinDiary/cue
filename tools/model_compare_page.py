"""Builds the comparison page from a `-modelLab run` (Cue/Views/ModelLab.swift, DEBUG builds only).

The run happens inside the app on a simulator whose keychain holds the OpenAI key, so the key never leaves it; copy
the app's Documents/lab folder out, then:

    python3 tools/model_compare_page.py <lab folder> model-compare.html

Prices are $ per 1M tokens as of 2026-10; update PRICES when they change. The conclusion block in the page is the
2026-10-10 run's and is to be rewritten for another run.
"""
import base64, glob, html, io, json, os, sys
sys.path.append('/Users/marlin/Library/Python/3.9/lib/python/site-packages')
from PIL import Image

LAB, OUT = sys.argv[1], sys.argv[2]
PRICES = {  # $ per 1M tokens: input, cached input, output
    'gpt-6.1-sol': (2.0, 0.20, 10.0), 'gpt-6-sol': (2.0, 0.20, 10.0),
    'gpt-6-luna': (0.10, 0.01, 0.50), 'gpt-6-astra': (10.0, 1.0, 50.0),
}
IMAGE_OUT, IMAGE_TEXT_IN = 30.0, 5.0
NAMES = {'gpt-6-luna': 'Luna（最便宜）', 'gpt-6.1-sol': 'Sol 6.1（现在用的）', 'gpt-6-astra': 'Astra（最贵）'}
ORDER = ['gpt-6-luna', 'gpt-6.1-sol', 'gpt-6-astra']
QUALITY = {'high': '高质量（现在用的）', 'medium': '中等质量'}

def entry_cost(model, usage):
    p_in, p_cached, p_out = PRICES[model]
    cached = (usage.get('input_tokens_details') or {}).get('cached_tokens', 0)
    fresh = usage.get('input_tokens', 0) - cached
    return (fresh * p_in + cached * p_cached + usage.get('output_tokens', 0) * p_out) / 1e6

def cold_cost(model, usage):
    p_in, _, p_out = PRICES[model]
    return (usage.get('input_tokens', 0) * p_in + usage.get('output_tokens', 0) * p_out) / 1e6

def image_cost(usage):
    text_in = (usage.get('input_tokens_details') or {}).get('text_tokens', usage.get('input_tokens', 0))
    return (usage.get('output_tokens', 0) * IMAGE_OUT + text_in * IMAGE_TEXT_IN) / 1e6

entries, pictures, words = {}, {}, []
for path in sorted(glob.glob(os.path.join(LAB, '*--*.json'))):
    meta = json.load(open(path))
    stem = os.path.basename(path)[:-5]
    slug = stem.split('--')[0]
    if 'model' in meta:
        if meta['input'] not in words: words.append(meta['input'])
        try: meta['parsed'] = json.loads(meta['entry'])
        except Exception: meta['parsed'] = None
        meta['cost'] = entry_cost(meta['model'], meta['usage'])
        meta['cold'] = cold_cost(meta['model'], meta['usage'])
        entries[(meta['input'], meta['model'])] = meta
    else:
        meta['cost'] = image_cost(meta['usage'])
        meta['file'] = os.path.join(LAB, stem + '.png')
        pictures[(slug, meta['quality'])] = meta
slugs = {w: w.replace(' ', '-') for w in words}

def picture_tag(path):
    image = Image.open(path).convert('RGBA')
    card = Image.new('RGBA', image.size, (255, 255, 255, 255))
    card.alpha_composite(image)
    buffer = io.BytesIO()
    card.convert('RGB').save(buffer, 'JPEG', quality=90)
    return '<img src="data:image/jpeg;base64,%s">' % base64.b64encode(buffer.getvalue()).decode()

def esc(text): return html.escape(text or '')

def entry_html(meta):
    e = meta.get('parsed')
    if not e: return '<p class="err">没有生成出来</p>'
    out = ['<div class="hw">%s</div>' % esc(e.get('headword'))]
    if e.get('phoneticUS'): out.append('<div class="ipa">/%s/</div>' % esc(e['phoneticUS']))
    out.append('<div class="summary">%s</div>' % esc(e.get('summary')))
    if e.get('question'): out.append('<div class="q">你问的：%s</div>' % esc(e['question']))
    for part in e.get('parts') or []:
        out.append('<div class="pos">%s</div><ol>' % esc(part.get('pos')))
        for s in part.get('senses') or []:
            out.append('<li><b>%s</b> <span class="en">%s</span><div class="ex">%s</div><div class="exz">%s</div></li>'
                       % (esc(s.get('chinese')), esc(s.get('english')), esc(s.get('example')), esc(s.get('exampleChinese'))))
        out.append('</ol>')
    if e.get('exchange'):
        out.append('<div class="label">对话</div>')
        for line in e['exchange']:
            out.append('<div class="ex">%s</div><div class="exz">%s</div>' % (esc(line.get('english')), esc(line.get('chinese'))))
    if e.get('collocations'):
        out.append('<div class="label">搭配 / 其他说法</div><ul>')
        for c in e['collocations']:
            out.append('<li>%s <span class="zh">%s</span></li>' % (esc(c.get('phrase')), esc(c.get('chinese'))))
        out.append('</ul>')
    if e.get('note'): out.append('<div class="label">用法</div><p>%s</p>' % esc(e['note']))
    if e.get('etymology'): out.append('<div class="label">词源</div><p>%s</p>' % esc(e['etymology']))
    out.append('<div class="label">画面说明</div><p class="idea">%s</p>' % esc(e.get('pictureIdea')))
    return '\n'.join(out)

def stats(meta):
    u = meta['usage']
    reasoning = (u.get('output_tokens_details') or {}).get('reasoning_tokens', 0)
    return '%.1f 秒 · 输入 %d · 输出 %d（推理 %d）· <b>$%.4f</b>' % (
        meta['seconds'], u.get('input_tokens', 0), u.get('output_tokens', 0), reasoning, meta['cost'])

# Averages.
models = [m for m in ORDER if any(k[1] == m for k in entries)]
rows = []
for m in models:
    ms = [entries[(w, m)] for w in words if (w, m) in entries]
    rows.append((NAMES.get(m, m), sum(x['seconds'] for x in ms) / len(ms), sum(x['cost'] for x in ms) / len(ms),
                 sum(x['cold'] for x in ms) / len(ms)))
qrows = []
for q in ['high', 'medium']:
    ps = [pictures[(slugs[w], q)] for w in words if (slugs[w], q) in pictures]
    if ps: qrows.append((QUALITY[q], q, sum(p['seconds'] for p in ps) / len(ps), sum(p['cost'] for p in ps) / len(ps),
                         sum(p['usage'].get('output_tokens', 0) for p in ps) / len(ps)))

parts = ['''<!doctype html><html lang="zh-Hans"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>模型与画质对比</title>
<style>
:root { --bg: #f2f2f7; --card: #fff; --text: #1c1c1e; --muted: #8e8e93; --line: #e5e5ea; --accent: #1c1c1e; }
@media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --text: #f2f2f7; --muted: #8e8e93; --line: #38383a; } }
body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, "PingFang SC", sans-serif; }
main { max-width: 1280px; margin: 0 auto; padding: 24px 16px 64px; }
h1 { font-size: 26px; margin: 0 0 4px; } h2 { font-size: 22px; margin: 40px 0 12px; }
.sub { color: var(--muted); margin-bottom: 20px; }
table { border-collapse: collapse; background: var(--card); border-radius: 12px; overflow: hidden; margin: 8px 0 4px; }
td, th { padding: 8px 14px; text-align: left; border-bottom: 1px solid var(--line); }
th { color: var(--muted); font-weight: 500; font-size: 13px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 12px; }
.card { background: var(--card); border-radius: 16px; padding: 16px; }
.pics { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px; margin-bottom: 12px; }
.pics img { width: 100%; max-width: 384px; display: block; margin: 0 auto; border-radius: 12px; }
.cap { font-size: 13px; color: var(--muted); text-align: center; margin-top: 6px; }
.cap b, .stats b { color: var(--text); }
.model { font-weight: 600; margin-bottom: 2px; } .stats { font-size: 12px; color: var(--muted); margin-bottom: 10px; }
.hw { font: 600 26px/1.2 "New York", Georgia, serif; } .ipa, .q { color: var(--muted); }
.summary { margin: 4px 0 8px; } .pos { font-style: italic; color: var(--muted); margin-top: 8px; font-family: Georgia, serif; }
ol, ul { padding-left: 20px; margin: 4px 0; } li { margin-bottom: 6px; }
.en { color: var(--muted); } .ex { font-family: Georgia, serif; font-style: italic; } .exz, .zh { color: var(--muted); }
.label { font-size: 12px; color: var(--muted); letter-spacing: .04em; margin-top: 10px; }
p { margin: 2px 0; } .idea { font-size: 13px; color: var(--muted); } .err { color: #c00; }
</style></head><body><main>
<h1>词条模型 × 图片画质 对比</h1>
<div class="sub">同样的 5 个输入，三个模型各写一遍词条（推理强度都是 low）；图片用 Sol 6.1 写的画面说明，分别以高质量和中等质量各画一张（图为 App 实际保存的 768 px 版本）。</div>
<div class="card" style="margin-bottom:8px"><div class="model">结论</div><ul>
<li><b>词条：Sol 6.1 和 Astra 几乎一样</b>，frugal 的两句例句一字不差。Astra 的用法说明稍细一点（如提醒 Let me think about it 可能被听成婉拒），但贵 5 倍，不值。</li>
<li><b>Luna 便宜 20 倍，释义和例句基本可用，弱在两处：</b>画面说明想得差（frugal 写成「一碗菜汤」，take for granted 写成「刷牙不关水龙头」，图就表达不出词义）；短语的「其他说法」是现编的（assume without question），违反提示要求。图是照画面说明画的，所以换 Luna 省下的钱会在图上亏回来。</li>
<li><b>图片：在 App 的显示尺寸下，中等质量和高质量很接近。</b>按 1:1 像素放大看，中等在金属和人脸上稍软、有点颗粒。中等便宜约 72%（$0.015 对 $0.055），也快将近一半（21 秒对 37 秒）。</li>
<li><b>要省钱，先降画质，别换词条模型：</b>Sol + 中等质量每 100 词约 $2.4，比 Luna + 高质量（约 $5.5）便宜，词条也更好。</li>
</ul></div>
<h2>平均每次</h2><table><tr><th>词条模型</th><th>耗时</th><th>每条（命中缓存，本次实际）</th><th>每条（未命中缓存）</th></tr>''']
for name, sec, cost, cold in rows:
    parts.append('<tr><td>%s</td><td>%.1f 秒</td><td>$%.4f</td><td>$%.4f</td></tr>' % (name, sec, cost, cold))
parts.append('</table><table><tr><th>图片画质</th><th>耗时</th><th>输出 token</th><th>每张成本</th></tr>')
for name, q, sec, cost, tokens in qrows:
    parts.append('<tr><td>%s</td><td>%.1f 秒</td><td>%d</td><td>$%.4f</td></tr>' % (name, sec, tokens, cost))
parts.append('</table>')
# 100 words under each combination.
parts.append('<table><tr><th>100 个词的成本（词条按未命中缓存算）</th>' + ''.join('<th>%s</th>' % q[0] for q in qrows) + '</tr>')
for name, sec, cost, cold in rows:
    parts.append('<tr><td>%s</td>' % name + ''.join('<td>$%.2f</td>' % (100 * (cold + q[3])) for q in qrows) + '</tr>')
parts.append('</table><div class="sub">OpenAI 会自动缓存反复出现的长提示词（词条的固定说明约 2,150 token），命中时这部分按一折计费。一个人隔一阵加一个词时多半不命中；有了自己的服务器、很多人一起用时基本都命中。</div>')

for w in words:
    slug = slugs[w]
    parts.append('<h2>%s</h2><div class="pics">' % esc(w))
    for q in ['high', 'medium']:
        p = pictures.get((slug, q))
        if p and os.path.exists(p['file']):
            parts.append('<div class="card">%s<div class="cap">%s · %.0f 秒 · <b>$%.3f</b></div></div>'
                         % (picture_tag(p['file']), QUALITY[q], p['seconds'], p['cost']))
        else:
            parts.append('<div class="card err">%s：没有画出来</div>' % QUALITY[q])
    parts.append('</div><div class="grid">')
    for m in models:
        meta = entries.get((w, m))
        parts.append('<div class="card"><div class="model">%s</div>' % NAMES.get(m, m))
        if meta:
            parts.append('<div class="stats">%s</div>%s' % (stats(meta), entry_html(meta)))
        else:
            parts.append('<p class="err">没有结果</p>')
        parts.append('</div>')
    parts.append('</div>')
total = sum(m['cost'] for m in entries.values()) + sum(p['cost'] for p in pictures.values())
parts.append('<p class="sub" style="margin-top:32px">这次对比总共花费约 $%.2f（按 Luna $0.10/$0.50、Sol $2/$10、Astra $10/$50 每百万 token，图片输出 $30/百万 token 计）。</p></main></body></html>' % total)
open(OUT, 'w').write('\n'.join(parts))
print('wrote', OUT, os.path.getsize(OUT), 'bytes; total cost $%.3f' % total)
