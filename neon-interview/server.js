const express = require('express');
const path = require('path');

const app = express();
app.use(express.json({ limit: '64kb' }));
app.use(express.static(path.join(__dirname, 'chat', 'public'), { extensions: ['html'] }));

const PORT      = process.env.PORT || 3000;
const LLAMA_URL = (process.env.LLAMA_URL || '').replace(/\/+$/, '');
const MODEL     = process.env.MODEL || 'gemma';

const BASE_PROMPT = `You are a senior interviewer at a top US tech company running a mock interview. You are friendly but sharp - direct, critical, and constructive. Speak plainly, like a real American interviewer.
- Ask exactly ONE focused question per turn
- Keep each turn under 120 characters, one or two sentences max
- If an answer is vague or generic, push for a specific example, number, or trade-off
- Never over-praise; treat the candidate like a peer
- Always end your turn with a question`;

const HINT_PROMPT = `You are a coach helping a candidate prepare to answer. Given the interviewer's last question, give a short structural hint (NOT the answer itself) in 2-3 bullet points, under 160 characters total. Use the STAR or claim-evidence-impact frame where it fits. Plain English, no preamble.`;

// 2 high-quality, MECE candidate replies per category. Each option stands
// on its own as a complete one-turn answer to the interviewer's last
// question.
const SUGG_TEMPLATES = {
  behavioral: {
    directions:
      'Two options, MECE: (1) lead with the situation + your strength in one tight sentence (2) give a concrete action you took and a measurable result',
    example:
      '["My strength is ownership - last year I drove a migration that cut p99 latency in half.","I led the rollout end to end, shipped weekly, and reduced incident rate by 40% in two quarters."]',
  },
  technical: {
    directions:
      'Two options, MECE: (1) state the high-level approach with its time/space complexity (2) name a concrete data structure or trade-off you would use first',
    example:
      '["I would use a hash map for O(1) lookups and iterate once, giving O(n) time and O(n) space.","I would start with a min-heap of size k - that keeps memory bounded and gives O(n log k)."]',
  },
  case: {
    directions:
      'Two options, MECE: (1) frame the problem - state your assumptions and the structure you will use (2) make one concrete quantitative estimate or recommendation',
    example:
      '["First I would segment the market by age and price tier, then size the top two segments.","I estimate 30M target users at $8/mo gives $2.9B ARR - I would prioritize the mobile launch."]',
  },
};

function suggSystemPrompt(cat) {
  const t = SUGG_TEMPLATES[cat] || SUGG_TEMPLATES.behavioral;
  return `You generate exactly 2 candidate replies for a US interview candidate answering the interviewer's last question. Quality over quantity.

HARD RULES:
- Output is ONLY a JSON array of exactly 2 strings. No prose, no code fence.
- Each string under 90 characters
- Each reply is a complete first-person candidate turn, not a fragment
- Direct, confident, plain American English (first person, "I")
- Each reply directly answers the interviewer's last question (no tangents)
- The two replies are MECE: ${t.directions}

NEVER OUTPUT:
- Interviewer language or evaluations (X "Great question," "Thanks, next we will...")
- Labels like "Interviewer:" or "Candidate:"
- Preambles, explanations, code fences, or newlines
- Pure abstractions like "I am hardworking." - always include a specific example or number

GOOD EXAMPLE: ${t.example}`;
}

const END_PROMPT = `You are the senior interviewer wrapping up the mock interview. Give the candidate direct, specific feedback in plain American English. Output the four sections below, separated by blank lines.

STRENGTH: Quote one good moment from the candidate and say why it landed. <= 110 chars.
GAP: Quote one weak moment and explain what was missing. <= 110 chars.
NEXT TIME: One concrete thing to change in the next interview. <= 80 chars.
VERDICT: Overall impression and recommendation in one sentence. <= 80 chars.

Always reference what the candidate actually said (paraphrase or quote). No greetings, no sign-off, no extra symbols. Total under 380 characters.`;

const CATEGORIES = {
  behavioral: {
    name:  'Behavioral',
    focus: 'Behavioral round. Probe past experience using STAR. Push for specific actions and measurable results.',
    intro: "Let's start behavioral. Tell me about a time you owned a problem end to end - what was the impact?",
    suggs: [
      'I owned the checkout latency project end to end and cut p99 from 1.4s to 600ms in 8 weeks.',
      'My strength is ownership - last quarter I drove a migration that removed 30% of our oncall pages.',
    ],
  },
  technical: {
    name:  'Technical',
    focus: 'Technical round. Probe coding, data structures, and system design. Push for complexity and trade-offs.',
    intro: 'Technical round. Walk me through how you would design a rate limiter for a public API.',
    suggs: [
      'I would use a token bucket per user in Redis, refilled per second - O(1) per check and easy to tune.',
      'I would start with a fixed-window counter, then move to sliding-log if we need smoother enforcement.',
    ],
  },
  case: {
    name:  'Case',
    focus: 'Case round. Probe structured problem-solving on business or product cases. Push for assumptions and numbers.',
    intro: 'Case round. A new social app wants to launch in the US - how would you size the opportunity?',
    suggs: [
      'I would segment by age and price tier, then size the top two segments before estimating ARPU.',
      'I assume 200M US smartphone users, 15% target rate, $5/mo ARPU - roughly $1.8B addressable.',
    ],
  },
};

let category    = 'behavioral';
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
        // assistant message.
        chat_template_kwargs: { enable_thinking: false },
      }),
      signal: ctrl.signal,
    });
    if (!r.ok) throw new Error(`llama ${r.status}`);
    const j = await r.json();
    const m = j.choices?.[0]?.message;
    const content = (m?.content || '').trim();
    if (content) return content;
    return (m?.reasoning_content || '').trim();
  } finally {
    clearTimeout(to);
  }
}

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

    const lastQ = [...conv].reverse().find(m => m.role === 'assistant');
    if (!lastQ) return [];

    const flow = conv.slice(-6)
      .map(m => (m.role === 'assistant' ? 'Interviewer' : 'Candidate') + ': ' + m.content)
      .join('\n');

    const userPrompt =
      'Theme: ' + CATEGORIES[category].focus +
      '\n\nConversation so far:\n' + flow +
      '\n\nInterviewer\'s latest question:\n"' + lastQ.content + '"\n\n' +
      'Generate exactly 2 candidate replies that directly answer this question, are consistent with the conversation, and follow the rules. Output strictly as ["reply A","reply B"].';

    const txt = await callLlama([
      { role: 'system', content: suggSystemPrompt(category) },
      { role: 'user',   content: userPrompt },
    ], 350, 0.4);

    const m = txt.match(/\[[\s\S]*?\]/);
    if (!m) return [];
    let arr;
    try { arr = JSON.parse(m[0]); } catch { return []; }
    return Array.isArray(arr) ? arr.slice(0, 2).map(s => String(s).slice(0, 110)) : [];
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
  if (text.length > 1200) return res.status(413).json({ error: 'too long' });
  if (ended)              return res.status(409).json({ error: 'interview already ended' });

  if (!startedAt) startedAt = Date.now();

  const userMsg = { role: 'user', content: text, ts: Date.now() };
  history.push(userMsg);
  broadcast({ type: 'append', message: userMsg, state: state() });

  suggestions = [];
  broadcast({ type: 'suggestions', suggestions });

  try {
    const reply = await callLlama(buildMessages(
      BASE_PROMPT + '\n\nThis round: ' + CATEGORIES[category].focus,
    ), 250);
    questionNum += 1;
    const aiMsg = { role: 'assistant', content: reply || '(empty response)', ts: Date.now() };
    history.push(aiMsg);
    broadcast({ type: 'append', message: aiMsg, state: state() });
  } catch (e) {
    const err = { role: 'assistant', content: `(error: ${e.message})`, ts: Date.now() };
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
      .map(m => (m.role === 'assistant' ? 'Interviewer' : 'Candidate') + ': ' + m.content)
      .join('\n');
    const summary = await callLlama([
      { role: 'system', content: END_PROMPT },
      { role: 'user',   content: 'Interview transcript:\n' + transcript + '\n\nWrite the four-section feedback referencing what the candidate actually said.' },
    ], 700, 0.5);
    const endMsg = {
      role: 'assistant',
      content: summary || '(could not generate feedback)',
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
      { role: 'user',   content: "Interviewer's question:\n" + lastQ.content },
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

// Server-side TTS: proxy to Google Translate's public TTS endpoint and
// stream MP3 back. Default language is en (US English voice) so audio
// always plays through the device that loaded the page (i.e. the MRBD
// speakers).
app.get('/api/tts', async (req, res) => {
  const text = String(req.query.text || '').slice(0, 200).trim();
  if (!text) return res.status(400).send('empty');
  const lang = String(req.query.lang || 'en').slice(0, 8);
  const url  = 'https://translate.googleapis.com/translate_tts'
             + '?ie=UTF-8&client=tw-ob'
             + '&tl=' + encodeURIComponent(lang)
             + '&q='  + encodeURIComponent(text);
  try {
    const r = await fetch(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/537.36',
        'Accept':     'audio/mpeg, */*',
      },
    });
    if (!r.ok) return res.status(502).send('tts upstream ' + r.status);
    const buf = Buffer.from(await r.arrayBuffer());
    res.set('Content-Type',  'audio/mpeg');
    res.set('Cache-Control', 'public, max-age=3600');
    res.set('Content-Length', String(buf.length));
    res.send(buf);
  } catch (e) {
    res.status(500).send(e.message);
  }
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
