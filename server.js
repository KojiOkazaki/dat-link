const express = require('express');
const path = require('path');

const app = express();
app.use(express.json({ limit: '64kb' }));
app.use(express.static(path.join(__dirname, 'chat', 'public'), { extensions: ['html'] }));

const PORT      = process.env.PORT || 3000;
const LLAMA_URL = (process.env.LLAMA_URL || '').replace(/\/+$/, '');
const MODEL     = process.env.MODEL || 'gemma';

const BASE_PROMPT = `あなたは経験豊富な日本企業の人事面接官です。日本の新卒採用面接を想定し、候補者(ユーザー)に1つだけ質問を投げかけて深掘りしてください。
- 落ち着いた敬語、簡潔な文体
- 1ターンは必ず80文字以内、句点1〜2個程度
- 候補者の回答が抽象的なら具体例を求める
- 過度に褒めず、批評的かつ建設的に
- 会話の最後は必ず質問で締める`;

const HINT_PROMPT = `あなたは候補者を支援するコーチです。直前の面接官の質問に対して、答え方の型を100文字以内で短く示してください。回答そのものではなく構成のヒントだけ。改行で2〜3点に分けてください。`;

// 2 high-quality, MECE candidate replies per category. Each option is meant
// to stand on its own as a complete answer to the interviewer's last turn.
const SUGG_TEMPLATES = {
  self_pr: {
    directions:
      '2つはMECE: (1)結論として強みを名指し、それを発揮した状況を一言添える (2)その強みが具体的に発揮された経験を1つ詳しく述べる',
    example:
      '["私の強みは粘り強さで、半年続けた研究で成果を出したことに表れています。","ゼミでは収集したデータを粘り強く検証し、当初の2倍の精度を実現しました。"]',
  },
  gakuchika: {
    directions:
      '2つはMECE: (1)取り組んだ事実と直面した課題を端的に述べる (2)自分の役割や工夫と、それによる結果・学びを述べる',
    example:
      '["大学では100名規模のサークルで運営を担い、参加率の低下という課題に直面しました。","個別ヒアリングと施策の再設計を主導し、半年で参加率を70%まで回復させました。"]',
  },
  motivation: {
    directions:
      '2つはMECE: (1)貴社の事業やプロダクトへの共感理由を具体的に述べる (2)入社後に実現したいことや自分のキャリア軸との合致を述べる',
    example:
      '["貴社の◯◯事業の社会的意義と中長期での将来性に強く共感しました。","入社後はまず◯◯分野で経験を積み、3年後には△△を担いたいと考えています。"]',
  },
};

function suggSystemPrompt(cat) {
  const t = SUGG_TEMPLATES[cat] || SUGG_TEMPLATES.self_pr;
  return `あなたは就活生(候補者)の立場で、面接官の直前の質問への返答候補を2つだけ生成するアシスタントです。数より質を優先してください。

【絶対ルール】
- 出力は ["a","b"] のJSON配列のみ。2要素ちょうど。各60文字以内。
- 各候補はそれ単体で完結した1ターンの面接回答として成立すること
- 敬語と論理構成 (主張→理由 or 結論→具体) が整っていること
- 直前の質問に直接答えていること (脱線や別話題への移動は禁止)
- 2つはMECE: ${t.directions}
- すべて候補者(就活生)の一人称口調

【絶対禁止】
- 面接官の言葉や評価コメント (✗「興味深いですね」「ありがとうございます、次に…」)
- "面接官:" "候補者:" などのラベル
- 前置き・説明・コードブロック・改行
- 「○○です。」だけの抽象一文 (具体性を必ず加える)

良い例: ${t.example}`;
}

const END_PROMPT = `あなたは経験豊富な日本企業の人事面接官です。直前の面接内容を踏まえて、候補者へのフィードバックを以下の形式で具体的に日本語で出力してください。

【強み】良かった発言を1つ引用し、なぜ評価できるか理由を添える (90文字以内)
【改善点】物足りない発言を1つ引用し、どう深めるべきか提案する (90文字以内)
【次回への提案】次の面接で具体的に変えるべき1点を述べる (60文字以内)
【総評】全体の印象と推奨度を1〜2文で (60文字以内)

各項目を改行で分けて出力。必ず候補者の実発言に触れること(例: 「◯◯と述べた点」)。
前置き・締めの挨拶・余計な記号は不要。合計300文字以内。`;

const CATEGORIES = {
  self_pr: {
    name:  '自己PR',
    focus: '候補者の強み・自己PRを掘り下げる質問を中心にする。エピソードの再現性と汎用性を問う。',
    intro: 'それではまず、ご自身の強みを30秒程度で教えてください。',
    suggs: [
      '私の強みは粘り強さで、半年間の研究で結果を出したことに表れています。',
      '周囲を巻き込む力が強みで、ゼミ運営でメンバーの参加率を高めました。',
    ],
  },
  gakuchika: {
    name:  'ガクチカ',
    focus: '学生時代に最も注力した経験(ガクチカ)を中心に、課題設定・行動・成果・学びを掘り下げる。',
    intro: '学生時代にもっとも力を入れて取り組んだことを、結論から教えてください。',
    suggs: [
      '100名規模のサークル運営で参加率の低下という課題に取り組みました。',
      '個別ヒアリングと施策の見直しを主導し、半年で参加率を70%まで回復しました。',
    ],
  },
  motivation: {
    name:  '志望動機',
    focus: '志望動機・キャリア観・業界企業理解を掘り下げる。Why this industry / Why us / Why now を問う。',
    intro: '当社を志望される理由を、業界選びの背景を含めて教えてください。',
    suggs: [
      '貴社の◯◯事業の社会的意義と将来性に強く共感しました。',
      '入社後はまず◯◯分野で経験を積み、◯年後に△△を実現したいです。',
    ],
  },
};

let category    = 'self_pr';
let history     = [];
let suggestions = [];
let questionNum = 0;
let startedAt   = null;
let ended       = false;
let sseClients  = [];

function state() {
  return { category, questionNum, startedAt, ended, categoryName: CATEGORIES[category].name };
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
        stream:      false,
        // Disable Gemma 4 thinking mode: with it on, the model spends
        // the entire budget on reasoning_content and returns an empty
        // assistant message. E2B/E4B support a clean disable.
        chat_template_kwargs: { enable_thinking: false },
      }),
      signal: ctrl.signal,
    });
    if (!r.ok) throw new Error(`llama ${r.status}`);
    const j = await r.json();
    const m = j.choices?.[0]?.message;
    const content = (m?.content || '').trim();
    if (content) return content;
    // Fallback: some servers still emit a thinking block when content is empty.
    return (m?.reasoning_content || '').trim();
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
  const conv = (slice || history).filter(m => m.kind !== 'hint' && m.kind !== 'end');
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
    const conv = history.filter(m => m.kind !== 'hint' && m.kind !== 'end');
    if (!conv.length) return [];

    // Pull out the most recent interviewer turn — that's what the candidate
    // is actually answering. Suggestions must hang off this directly.
    const lastQ = [...conv].reverse().find(m => m.role === 'assistant');
    if (!lastQ) return [];

    const flow = conv.slice(-6)
      .map(m => (m.role === 'assistant' ? '面接官' : '候補者') + ': ' + m.content)
      .join('\n');

    const userPrompt =
      'テーマ: ' + CATEGORIES[category].focus +
      '\n\nこれまでの会話の流れ:\n' + flow +
      '\n\n面接官が今投げかけた質問:\n「' + lastQ.content + '」\n\n' +
      'この質問に対する候補者の返答候補を、会話の流れと矛盾せず、質問の意図に直接答える形で必ず2つ作成してください。形式は厳密に ["回答A", "回答B"] のJSON配列のみ。';

    const txt = await callLlama([
      { role: 'system', content: suggSystemPrompt(category) },
      { role: 'user',   content: userPrompt },
    ], 350, 0.4);

    const m = txt.match(/\[[\s\S]*?\]/);
    if (!m) return [];
    let arr;
    try { arr = JSON.parse(m[0]); } catch { return []; }
    return Array.isArray(arr) ? arr.slice(0, 2).map(s => String(s).slice(0, 80)) : [];
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
  ended       = false;
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
  if (ended)              return res.status(409).json({ error: 'interview already ended' });

  if (!startedAt) startedAt = Date.now();

  const userMsg = { role: 'user', content: text, ts: Date.now() };
  history.push(userMsg);
  broadcast({ type: 'append', message: userMsg, state: state() });

  suggestions = [];
  broadcast({ type: 'suggestions', suggestions });

  try {
    const reply = await callLlama(buildMessages(
      BASE_PROMPT + '\n\n今回のテーマ: ' + CATEGORIES[category].focus,
    ), 250);
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

app.post('/api/end', async (req, res) => {
  const conv = history.filter(m => m.kind !== 'hint' && m.kind !== 'end');
  if (conv.length < 2) return res.status(400).json({ error: 'not enough turns' });
  try {
    const transcript = conv
      .map(m => (m.role === 'assistant' ? '面接官' : '候補者') + ': ' + m.content)
      .join('\n');
    const summary = await callLlama([
      { role: 'system', content: END_PROMPT },
      { role: 'user',   content: '今回の面接記録:\n' + transcript + '\n\n上記の発言内容に具体的に触れながら、指定された4項目でフィードバックをお願いします。' },
    ], 700, 0.5);
    const endMsg = {
      role: 'assistant',
      content: summary || '(フィードバックを生成できませんでした)',
      ts: Date.now(),
      kind: 'end',
    };
    history.push(endMsg);
    suggestions = [];
    ended = true;
    broadcast({ type: 'append', message: endMsg, state: state() });
    broadcast({ type: 'suggestions', suggestions });
    res.json({ ok: true });
  } catch (e) {
    res.status(502).json({ error: e.message });
  }
});

app.post('/api/hint', async (req, res) => {
  if (ended) return res.status(409).json({ error: 'interview already ended' });
  const lastQ = [...history].reverse().find(m => m.role === 'assistant' && m.kind !== 'hint' && m.kind !== 'end');
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
  ended       = false;
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
