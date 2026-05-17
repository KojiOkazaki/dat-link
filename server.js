const express = require('express');
const path = require('path');

const app = express();
app.use(express.json({ limit: '64kb' }));
app.use(express.static(path.join(__dirname, 'chat', 'public'), { extensions: ['html'] }));

const PORT      = process.env.PORT || 3000;
const LLAMA_URL = (process.env.LLAMA_URL || '').replace(/\/+$/, '');
const MODEL     = process.env.MODEL || 'gemma';

const SYSTEM_PROMPT = `あなたは経験豊富な日本企業の人事面接官です。日本の新卒採用面接を想定し、候補者(ユーザー)に質問を投げかけて深掘りしてください。
- 落ち着いた敬語と簡潔な文体を保つ
- 1ターンの返答は150文字以内
- 候補者の回答が抽象的なら具体例を求める
- 一度に質問するのは1つだけ
- 過度に褒めず、批評的かつ建設的に
- 会話の最後は必ず質問で締める`;

const HINT_PROMPT = `あなたは候補者を支援するコーチです。直前の面接官の質問に対して、答え方の型を120文字以内でやさしく示してください。回答そのものではなく、構成のヒントを箇条書きで。`;

const SUGG_PROMPT = `次の面接の流れから、候補者が次に返答しそうな短いフレーズを必ず3つ、ちょうど3つだけJSON配列で出力してください。各40文字以内。出力はJSON配列のみ。例:
["はい、ありがとうございます。","具体例を挙げますと…","少し考えさせてください。"]`;

const INTRO = '本日はお時間をいただきありがとうございます。それではまず、自己紹介を簡潔にお願いします。';
const INTRO_SUGGS = [
  'はい、よろしくお願いします。',
  '〇〇大学の△△と申します。',
  '少し緊張していますが頑張ります。',
];

let history     = [];
let suggestions = [];
let sseClients  = [];

function broadcast(event) {
  const data = `data: ${JSON.stringify(event)}\n\n`;
  for (const c of sseClients) {
    try { c.write(data); } catch (_) {}
  }
}

setInterval(() => broadcast({ type: 'ping', ts: Date.now() }), 25000);

app.get('/api/events', (req, res) => {
  res.writeHead(200, {
    'Content-Type':                'text/event-stream',
    'Cache-Control':               'no-cache, no-transform',
    'Connection':                  'keep-alive',
    'X-Accel-Buffering':           'no',
    'Access-Control-Allow-Origin': '*',
  });
  res.flushHeaders && res.flushHeaders();
  res.write(`data: ${JSON.stringify({ type: 'snapshot', history, suggestions })}\n\n`);
  sseClients.push(res);
  req.on('close', () => {
    sseClients = sseClients.filter(c => c !== res);
  });
});

async function callLlama(messages, maxTokens = 400, temperature = 0.7) {
  if (!LLAMA_URL) throw new Error('LLAMA_URL not configured');
  const ctrl = new AbortController();
  const to   = setTimeout(() => ctrl.abort(), 60000);
  try {
    const r = await fetch(`${LLAMA_URL}/v1/chat/completions`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({
        model: MODEL,
        messages,
        max_tokens:  maxTokens,
        temperature,
        stream: false,
      }),
      signal: ctrl.signal,
    });
    if (!r.ok) throw new Error(`llama ${r.status}`);
    const j = await r.json();
    return (j.choices?.[0]?.message?.content || '').trim();
  } finally {
    clearTimeout(to);
  }
}

async function generateSuggestions() {
  try {
    const txt = await callLlama([
      { role: 'system', content: SUGG_PROMPT },
      ...history.slice(-6).map(({ role, content }) => ({ role, content })),
    ], 200, 0.5);
    const m = txt.match(/\[[\s\S]*\]/);
    if (!m) return [];
    const arr = JSON.parse(m[0]);
    return Array.isArray(arr) ? arr.slice(0, 3).map(s => String(s).slice(0, 60)) : [];
  } catch (_) {
    return [];
  }
}

app.post('/api/start', (req, res) => {
  history = [{ role: 'assistant', content: INTRO, ts: Date.now() }];
  suggestions = INTRO_SUGGS.slice();
  broadcast({ type: 'snapshot', history, suggestions });
  res.json({ ok: true });
});

app.post('/api/say', async (req, res) => {
  const text = String(req.body?.text || '').trim();
  if (!text)            return res.status(400).json({ error: 'empty' });
  if (text.length > 1000) return res.status(413).json({ error: 'too long' });

  const userMsg = { role: 'user', content: text, ts: Date.now() };
  history.push(userMsg);
  broadcast({ type: 'append', message: userMsg });

  suggestions = [];
  broadcast({ type: 'suggestions', suggestions });

  try {
    const reply = await callLlama([
      { role: 'system', content: SYSTEM_PROMPT },
      ...history.map(({ role, content }) => ({ role, content })),
    ]);
    const aiMsg = { role: 'assistant', content: reply || '（応答が空でした）', ts: Date.now() };
    history.push(aiMsg);
    broadcast({ type: 'append', message: aiMsg });
  } catch (e) {
    const err = { role: 'assistant', content: `（エラー: ${e.message}）`, ts: Date.now() };
    history.push(err);
    broadcast({ type: 'append', message: err });
    res.status(502).json({ error: e.message });
    return;
  }

  suggestions = await generateSuggestions();
  broadcast({ type: 'suggestions', suggestions });
  res.json({ ok: true });
});

app.post('/api/hint', async (req, res) => {
  const lastQ = [...history].reverse().find(m => m.role === 'assistant');
  if (!lastQ) return res.status(400).json({ error: 'no question yet' });
  try {
    const hint = await callLlama([
      { role: 'system', content: HINT_PROMPT },
      { role: 'user',   content: `面接官の質問:\n${lastQ.content}` },
    ], 250, 0.4);
    const aiMsg = {
      role: 'assistant',
      content: 'HINT: ' + hint,
      ts: Date.now(),
      kind: 'hint',
    };
    history.push(aiMsg);
    broadcast({ type: 'append', message: aiMsg });
    res.json({ ok: true });
  } catch (e) {
    res.status(502).json({ error: e.message });
  }
});

app.post('/api/reset', (req, res) => {
  history     = [];
  suggestions = [];
  broadcast({ type: 'snapshot', history, suggestions });
  res.json({ ok: true });
});

app.get('/api/health', (req, res) => {
  res.json({
    ok:        true,
    hasLlama:  !!LLAMA_URL,
    model:     MODEL,
    messages:  history.length,
    listeners: sseClients.length,
  });
});

app.listen(PORT, () => {
  console.log(`server on :${PORT}`);
  console.log(`llama: ${LLAMA_URL || '(not configured)'}`);
});
