const express = require('express');
const path = require('path');

const app = express();
app.use(express.json({ limit: '64kb' }));
app.use(express.static(path.join(__dirname, 'public'), { extensions: ['html'] }));

const PORT = process.env.PORT || 4000;

// After this long with no Reachy heartbeat (speech POST or command poll),
// the robot is treated as offline and the display shows a warning.
const REACHY_TIMEOUT_MS = Number(process.env.REACHY_TIMEOUT_MS || 15000);
const HISTORY_LIMIT     = Number(process.env.HISTORY_LIMIT || 50);

// Commands the display is allowed to send. Anything else is rejected so a
// stray/garbled request can never drive the robot into an unknown motion.
const COMMANDS = new Set([
  'look_left', 'look_right', 'look_up', 'look_down', 'look_user',
  'nod', 'shake_head',
  'wave', 'dance',
  'happy', 'surprised', 'thinking', 'idle', 'excited',
  'start_conversation', 'pause_conversation',
  'stop', 'clear_text',
]);

// Fallback emotion guess from the text, used only when the Reachy side does
// not send an explicit `emotion`. Order matters: first match wins.
const EMOTION_RULES = [
  { emo: 'excited',   re: /(すご|わくわく|ワクワク|興奮|素晴らし|やったー|最高|amazing|awesome)/i },
  { emo: 'happy',     re: /(嬉し|楽し|うれし|たのし|やった|大好き|good|nice|happy)/i },
  { emo: 'surprised', re: /(えっ|まさか|びっくり|驚|なんと|本当に|そうなの|really\?)/i },
  { emo: 'thinking',  re: /(うーん|考え|難し|そうですね|どうだろ|えーと|hmm|let me think)/i },
  { emo: 'friendly',  re: /(よろしく|ありがと|どういたしまして|一緒|仲良|thank)/i },
];

function inferEmotion(text) {
  const t = String(text || '');
  for (const r of EMOTION_RULES) if (r.re.test(t)) return r.emo;
  return 'neutral';
}

// ---------- in-memory state ----------
let speechHistory = [];     // [{ speaker, text, emotion, state, ts }]
let latest        = null;   // last *reachy* speech, shown big in the bubble
let robotState    = 'idle'; // idle | listening | thinking | speaking | error
let emotion       = 'idle';
let reachySeen    = 0;      // ts of last heartbeat from the Reachy side
let commandQueue  = [];     // pending commands for the Reachy side to pull
let sseClients    = [];
let cmdSeq        = 0;
let lastConn      = false;

function reachyConnected() {
  return reachySeen > 0 && Date.now() - reachySeen < REACHY_TIMEOUT_MS;
}

function status() {
  return {
    connected:     reachyConnected(),
    robot_state:   robotState,
    emotion,
    display_state: sseClients.length ? 'connected' : 'idle',
    listeners:     sseClients.length,
  };
}

function broadcast(event) {
  const data = `data: ${JSON.stringify(event)}\n\n`;
  for (const c of sseClients) {
    try { c.write(data); } catch (_) {}
  }
}

// Refresh the Reachy heartbeat. If this is a fresh (re)connection, push a
// status update to the displays immediately rather than waiting for the
// periodic monitor.
function touchReachy() {
  reachySeen = Date.now();
  if (!lastConn) {
    lastConn = true;
    broadcast({ type: 'status', status: status() });
  }
}

// Permissive CORS for the JSON API so the Reachy client / a phone control UI
// served from another origin can reach it. SSE included.
app.use('/api', (req, res, next) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

// ---------- SSE stream for displays ----------
app.get('/api/events', (req, res) => {
  res.writeHead(200, {
    'Content-Type':      'text/event-stream',
    'Cache-Control':     'no-cache, no-transform',
    'Connection':        'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.flushHeaders && res.flushHeaders();
  res.write(`data: ${JSON.stringify({ type: 'snapshot', latest, history: speechHistory, status: status() })}\n\n`);
  sseClients.push(res);
  req.on('close', () => {
    sseClients = sseClients.filter(c => c !== res);
  });
});

// ---------- Reachy → relay: speech text ----------
app.post('/api/speech', (req, res) => {
  const b    = req.body || {};
  const text = String(b.text || '').trim();
  if (!text)              return res.status(400).json({ error: 'empty' });
  if (text.length > 2000) return res.status(413).json({ error: 'too long' });

  const speaker = b.speaker === 'user' ? 'user' : 'reachy';
  const emo = b.emotion || (speaker === 'reachy' ? inferEmotion(text) : 'neutral');
  const st  = b.state   || (speaker === 'reachy' ? 'speaking' : 'listening');

  const msg = { speaker, text, emotion: emo, state: st, ts: Date.now() };

  touchReachy();
  if (speaker === 'reachy') {
    latest     = msg;
    emotion    = emo;
    robotState = st;
  } else {
    robotState = 'listening';
  }

  speechHistory.push(msg);
  if (speechHistory.length > HISTORY_LIMIT) speechHistory.shift();

  broadcast({ type: 'speech', message: msg, status: status() });
  res.json({ ok: true });
});

// ---------- Reachy → relay: state / emotion only (no text) ----------
app.post('/api/state', (req, res) => {
  const b = req.body || {};
  if (b.state)   robotState = String(b.state);
  if (b.emotion) emotion    = String(b.emotion);
  touchReachy();
  broadcast({ type: 'status', status: status() });
  res.json({ ok: true });
});

// ---------- display → relay: control command ----------
app.post('/api/command', (req, res) => {
  const cmd = String(req.body?.command || '');
  if (!COMMANDS.has(cmd)) return res.status(400).json({ error: 'unknown command' });

  // clear_text is a display-side concern; also forward it so the Reachy side
  // can clear any local transcript if it wants to.
  if (cmd === 'clear_text') {
    speechHistory = [];
    latest = null;
    broadcast({ type: 'clear', status: status() });
  }

  const item = { id: ++cmdSeq, command: cmd, params: req.body?.params || {}, ts: Date.now() };
  commandQueue.push(item);
  if (commandQueue.length > 50) commandQueue.shift();

  // Echo to displays so the UI can confirm the command was accepted.
  broadcast({ type: 'command', command: cmd, status: status() });
  res.json({ ok: true, id: item.id });
});

// ---------- Reachy ← relay: pull pending commands (also a heartbeat) ----------
app.get('/api/commands', (req, res) => {
  touchReachy();
  const out = commandQueue;
  commandQueue = [];
  res.json({ commands: out });
});

// ---------- clear transcript ----------
app.post('/api/clear', (req, res) => {
  speechHistory = [];
  latest = null;
  broadcast({ type: 'clear', status: status() });
  res.json({ ok: true });
});

app.get('/favicon.ico', (req, res) => res.status(204).end());

app.get('/api/health', (req, res) => {
  res.json({
    ok:        true,
    status:    status(),
    history:   speechHistory.length,
    queued:    commandQueue.length,
    listeners: sseClients.length,
  });
});

// Detect connect/disconnect transitions and keep SSE alive.
setInterval(() => {
  const c = reachyConnected();
  if (c !== lastConn) {
    lastConn = c;
    broadcast({ type: 'status', status: status() });
    if (!c) {
      robotState = 'idle';
      broadcast({ type: 'error', message: 'Reachy Miniとの接続が切れました' });
    }
  }
}, 3000);
setInterval(() => broadcast({ type: 'ping', ts: Date.now() }), 25000);

app.listen(PORT, () => {
  console.log(`reachy-link relay on :${PORT}`);
});
