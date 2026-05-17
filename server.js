const express = require('express');
const path = require('path');

const app = express();
app.use(express.json({ limit: '64kb' }));
app.use(express.static(path.join(__dirname, 'chat', 'public'), { extensions: ['html'] }));

const PORT      = process.env.PORT || 3000;
const LLAMA_URL = (process.env.LLAMA_URL || '').replace(/\/+$/, '');
const MODEL     = process.env.MODEL || 'gemma';

const BASE_PROMPT = `あなたは経験豊富な日本企業の人事面接官です。日本の新卒採用面接を想定し、候補者(ユーザー)に質問を投げかけて深掘りしてください。
- 落ち着いた敬語と簡潔な文体を保つ
- 1ターンの返答は150文字以内
- 候補者の回答が抽象的なら具体例を求める
- 一度に質問するのは1つだけ
- 過度に褒めず、批評的かつ建設的に
- 会話の最後は必ず質問で締める`;

const HINT_PROMPT = `あなたは候補者を支援するコーチです。直前の面接官の質問に対して、答え方の型を120文字以内でやさしく示してください。回答そのものではなく、構成のヒントを箇条書きで。`;

const SUGG_PROMPT = `次の面接の流れから、候補者が次に返答しそうな短いフレーズを必ず5つ、ちょうど5つだけJSON配列で出力してください。各40文字以内、互いに異なる方向性で。出力はJSON配列のみ。例:
["はい、ありがとうございます。","具体例を挙げますと…","少し考えさせてください。","結論から申し上げます。","正直に申し上げると…"]`;

const CATEGORIES = {
  self_pr: {
    name:  '自己PR',
    focus: '候補者の強み・自己PRを掘り下げる質問を中心にする。エピソードの再現性と汎用性を問う。',
    intro: 'それではまず、ご自身の強みを30秒程度で教えてください。',
    suggs: [
      '私の強みは粘り強さです。',
      '周囲を巻き込む力が強みです。',
      '分析力には自信があります。',
      '結論から申し上げますね。',
      '具体的なエピソードがあります。',
    ],
  },
  gakuchika: {
    name:  'ガクチカ',
    focus: '学生時代に最も注力した経験(ガクチカ)を中心に、課題設定・行動・成果・学びを掘り下げる。',
    intro: '学生時代にもっとも力を入れて取り組んだことを、結論から教えてください。',
    suggs: [
      '部活動で大会成績を伸ばしました。',
      'アルバイトでの改善経験があります。',
      'サークルで〇〇を立ち上げました。',
      '研究に打ち込みました。',
      '長期インターンで成果を出しました。',
    ],
  },
  motivation: {
    name:  '志望動機',
    focus: '志望動機・キャリア観・業界企業理解を掘り下げる。Why this industry / Why us / Why now を問う。',
    intro: '当社を志望される理由を、業界選びの背景を含めて教えてください。',
    suggs: [
      '貴社の〇〇という事業に惹かれました。',
      '長期的に△△を実現したいです。',
      '〇〇業界の将来性に魅力を感じます。',
      '社員の方々の雰囲気に共感しました。',
      'インターンでの経験がきっかけです。',
    ],
  },
  reverse: {
    name:  '逆質問',
    focus: '候補者からの逆質問を引き出す。役割を逆転させ、面接官として丁寧に答え、さらに深い質問を促す。',
    intro: 'ここからは何か質問はありますか。会社のこと、業務のこと、何でも構いません。',
    suggs: [
      '配属後の研修内容を教えてください。',
      '若手の活躍事例を伺いたいです。',
      'チームの雰囲気を教えてください。',
      '評価制度について詳しく聞かせてください。',
      '今後の事業展望はいかがですか。',
    ],
  },
};

let category    = 'self_pr';
let history     = [];
let suggestions = [];
let questionNum = 0;
let startedAt   = null;
let sseClients  = [];

function state() {
  return { category, questionNum, startedAt, categoryName: CATEGORIES[category].name };
}

function broadcast(event) {
  const data = `data: ${JSON.stringify(event)}\n\n`;
  for (const c of sseClients) {
    try { c.write(data); } catch (_) {}
  }
}

function snapshot() {
  broadcast({ type: 'snapshot', history, suggestions, state: state() });
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
  res.write(`data: ${JSON.stringify({ type: 'snapshot', history, suggestions, state: state() })}\n\n`);
  sseClients.push(res);
  req.on('close', () => {
    sseClients = sseClients.filter(c => c !== res);
  });
});

async function callLlama(messages, maxTokens = 400, temperature = 1.0, topP = 0.95, topK = 64) {
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
        top_p:       topP,
        top_k:       topK,
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

// Gemma 4 supports a native `system` role and standard role alternation,
// so just prepend the system prompt to the conversation. Consecutive
// same-role turns are merged as a defensive measure for any chat
// template that still requires strict alternation.
function buildMessages(systemContent, slice) {
  const out  = [{ role: 'system', content: systemContent }];
  const conv = (slice || history).filter(m => m.kind !== 'hint');
  let lastRole = 'system';
  for (const m of conv) {
    if (m.role === lastRole && m.role !== 'system') {
      out[out.length - 1].content += '\n\n' + m.content;
    } else {
      out.push({ role: m.role, content: m.content });
      lastRole = m.role;
    }
  }
  return out;
}

async function generateSuggestions() {
  try {
    const messages = buildMessages(
      SUGG_PROMPT + '\n\nテーマ: ' + CATEGORIES[category].focus,
      history.slice(-6),
    );
    if (messages.length < 2) {
      messages.push({ role: 'user', content: '候補者の最初の返答候補を5つください。' });
    }
    const txt = await callLlama(messages, 250, 0.6);
    const m = txt.match(/\[[\s\S]*\]/);
    if (!m) return [];
    const arr = JSON.parse(m[0]);
    return Array.isArray(arr) ? arr.slice(0, 5).map(s => String(s).slice(0, 60)) : [];
  } catch (_) {
    return [];
  }
}

function startCategory(cat) {
  category    = cat;
  history     = [{ role: 'assistant', content: CATEGORIES[cat].intro, ts: Date.now() }];
  suggestions = CATEGORIES[cat].suggs.slice();
  questionNum = 1;
  startedAt   = Date.now();
  snapshot();
}

app.post('/api/start', (req, res) => {
  startCategory(category);
  res.json({ ok: true });
});

app.post('/api/category', (req, res) => {
  const c = String(req.body?.category || '');
  if (!CATEGORIES[c]) return res.status(400).json({ error: 'bad category' });
  startCategory(c);
  res.json({ ok: true });
});

app.post('/api/say', async (req, res) => {
  const text = String(req.body?.text || '').trim();
  if (!text)              return res.status(400).json({ error: 'empty' });
  if (text.length > 1000) return res.status(413).json({ error: 'too long' });

  if (!startedAt) startedAt = Date.now();

  const userMsg = { role: 'user', content: text, ts: Date.now() };
  history.push(userMsg);
  broadcast({ type: 'append', message: userMsg, state: state() });

  suggestions = [];
  broadcast({ type: 'suggestions', suggestions });

  try {
    const reply = await callLlama(buildMessages(
      BASE_PROMPT + '\n\n今回のテーマ: ' + CATEGORIES[category].focus,
    ));
    questionNum += 1;
    const aiMsg = { role: 'assistant', content: reply || '（応答が空でした）', ts: Date.now() };
    history.push(aiMsg);
    broadcast({ type: 'append', message: aiMsg, state: state() });
  } catch (e) {
    const err = { role: 'assistant', content: `（エラー: ${e.message}）`, ts: Date.now() };
    history.push(err);
    broadcast({ type: 'append', message: err, state: state() });
    res.status(502).json({ error: e.message });
    return;
  }

  suggestions = await generateSuggestions();
  broadcast({ type: 'suggestions', suggestions });
  res.json({ ok: true });
});

app.post('/api/hint', async (req, res) => {
  const lastQ = [...history].reverse().find(m => m.role === 'assistant' && m.kind !== 'hint');
  if (!lastQ) return res.status(400).json({ error: 'no question yet' });
  try {
    const hint = await callLlama([
      { role: 'system', content: HINT_PROMPT },
      { role: 'user',   content: '面接官の質問:\n' + lastQ.content },
    ], 250, 0.5);
    const aiMsg = {
      role: 'assistant',
      content: 'HINT: ' + hint,
      ts: Date.now(),
      kind: 'hint',
    };
    history.push(aiMsg);
    broadcast({ type: 'append', message: aiMsg, state: state() });
    res.json({ ok: true });
  } catch (e) {
    res.status(502).json({ error: e.message });
  }
});

app.post('/api/reset', (req, res) => {
  history     = [];
  suggestions = [];
  questionNum = 0;
  startedAt   = null;
  snapshot();
  res.json({ ok: true });
});

app.get('/api/health', (req, res) => {
  res.json({
    ok:        true,
    hasLlama:  !!LLAMA_URL,
    model:     MODEL,
    messages:  history.length,
    listeners: sseClients.length,
    state:     state(),
  });
});

app.listen(PORT, () => {
  console.log(`server on :${PORT}`);
  console.log(`llama: ${LLAMA_URL || '(not configured)'}`);
});
