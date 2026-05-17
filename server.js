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

// Suggestion direction templates: each category enforces an MECE breakdown
// of 5 candidate-perspective options, with a category-specific few-shot
// example so Gemma 4 E2B stays in the right register.
const SUGG_TEMPLATES = {
  self_pr: {
    directions:
      '(1)結論として強みを名指す (2)その強みを発揮した具体エピソード (3)別の関連エピソードや裏付け (4)数字や成果で示す (5)その経験から得た学び',
    example:
      '["私の強みは粘り強さです。","ゼミで半年間データ収集を続けました。","アルバイトでは新人指導も担いました。","結果として売上を120%にできました。","続ければ必ず形になると学びました。"]',
  },
  gakuchika: {
    directions:
      '(1)取り組んだ活動の事実を述べる (2)直面した課題を述べる (3)自分の役割や工夫を述べる (4)結果を数字や事実で示す (5)そこから得た学びと活かし方',
    example:
      '["大学では100人規模のサークルで運営を担いました。","参加率が30%まで落ち込む課題に直面しました。","個別に意見を聞いて施策を再設計しました。","半年で参加率を70%まで回復させました。","当事者意識を引き出す難しさを学びました。"]',
  },
  motivation: {
    directions:
      '(1)会社の事業や強みへの共感 (2)業界・市場の魅力 (3)自分のキャリア軸との合致 (4)具体的なプロダクトや事例への共感 (5)入社後に実現したいこと',
    example:
      '["貴社の◯◯事業に強く共感しました。","業界の急成長と社会的意義に魅力を感じます。","私の◯◯軸と方向性が合致します。","◯◯というプロダクトの思想に惹かれました。","入社後は◯◯を実現したいです。"]',
  },
  reverse: {
    directions:
      '5つは異なるテーマの質問: (1)業務内容や仕事の進め方 (2)評価制度・キャリアパス (3)カルチャー・チームの雰囲気 (4)研修・育成の仕組み (5)事業の今後・成長戦略。直前の回答の深掘りは禁止、別テーマで5つ揃える',
    example:
      '["配属後の具体的な業務内容を伺えますか。","若手の評価とキャリア形成について教えてください。","チームの雰囲気や働き方を伺いたいです。","新人育成や研修の仕組みはどうなっていますか。","今後の事業展開について伺えますか。"]',
  },
};

function suggSystemPrompt(cat) {
  const t = SUGG_TEMPLATES[cat] || SUGG_TEMPLATES.self_pr;
  return `あなたは就活生(候補者)の立場で次の発言候補を5つ生成するアシスタントです。

【絶対ルール】
- 出力は ["a","b","c","d","e"] のJSON配列のみ。5要素ちょうど。各40文字以内。
- 5つはMECE(互いに重ならず、全体として網羅的)、それぞれ論理的に独立した意味を持つこと
- すべて候補者(就活生)の一人称口調: 「私は…」「…と考えています」「…させていただきます」
- 方向性: ${t.directions}

【絶対禁止】
- 面接官の言葉や評価コメント (✗「興味深いですね」「ありがとうございます、次に…」「素晴らしいご回答です」)
- "面接官:" "候補者:" などのラベル
- 前置き・説明・コードブロック・改行
- 同じ意味の言い換えや微妙な差しかない案 (5つは明確に違う内容に)

良い例: ${t.example}`;
}

const END_PROMPT = `あなたは経験豊富な日本企業の人事面接官です。直前の面接内容を踏まえて、候補者へのフィードバックを次の3項目で日本語で出力してください。

強み: (35文字以内)
改善点: (35文字以内)
総評: (50文字以内)

各項目を改行で分け、合計120文字以内。前置きや締めの挨拶は不要。`;

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
    const recent = history.slice(-6)
      .filter(m => m.kind !== 'hint' && m.kind !== 'end')
      .map(m => (m.role === 'assistant' ? '面接官' : '候補者') + ': ' + m.content)
      .join('\n');

    const userPrompt =
      'テーマ: ' + CATEGORIES[category].focus +
      (recent ? '\n\n直前のやり取り:\n' + recent : '') +
      '\n\n候補者が次に発言しそうな短いフレーズを必ず5つ、JSON配列のみで出力してください。例外なく ["...", "...", "...", "...", "..."] の形式で。';

    const txt = await callLlama([
      { role: 'system', content: suggSystemPrompt(category) },
      { role: 'user',   content: userPrompt },
    ], 300, 0.5);

    const m = txt.match(/\[[\s\S]*?\]/);
    if (!m) return [];
    let arr;
    try { arr = JSON.parse(m[0]); } catch { return []; }
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
      { role: 'user',   content: '今回の面接:\n' + transcript + '\n\n上記の形式でフィードバックをお願いします。' },
    ], 400, 0.5);
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
