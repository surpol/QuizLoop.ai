const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
  "access-control-allow-headers": "content-type"
};

export async function onRequest(context) {
  const { request, env } = context;
  if (request.method === "OPTIONS") return json({});
  const url = new URL(request.url);
  const path = `/${(context.params.path || []).join("/")}`;

  try {
    if (!env.DB) return json({ error: "Cloudflare D1 binding DB is missing." }, 500);
    await ensureSchema(env.DB);

    if (request.method === "GET" && path === "/health") {
      const gemma = await gemmaHealth(env);
      return json({
        ok: true,
        mode: "cloudflare",
        model: gemma.model,
        intelligence: gemma,
        database: "Cloudflare D1"
      });
    }

    if (request.method === "GET" && path === "/notes") {
      return json({ notes: await listNotes(env.DB) });
    }

    if (request.method === "POST" && path === "/notes") {
      const body = await readJSON(request);
      const note = await createNote(env, body.title, body.body, body.sourceType || "text");
      return json({ note, nextQuiz: { status: note.queuedQuizCount > 0 ? "ready" : "preparing", saved: note.questionCount } }, 201);
    }

    if (request.method === "POST" && path === "/notes/shape") {
      const body = await readJSON(request);
      const shaped = await shapeNote(env, body.title, body.body, body.sourceType || "text");
      return json({ note: shaped });
    }

    if (request.method === "GET" && path === "/wiki/search") {
      const query = String(url.searchParams.get("q") || "").trim();
      if (query.length < 2) return json({ error: "Search needs at least 2 characters." }, 400);
      return json({ results: await searchWikipedia(query) });
    }

    if (request.method === "POST" && path === "/wiki/import") {
      const body = await readJSON(request);
      const article = await wikipediaArticle(body.title);
      const note = await createNote(env, article.title, article.text, "wikipedia");
      return json({ note, nextQuiz: { status: note.queuedQuizCount > 0 ? "ready" : "preparing", saved: note.questionCount } }, 201);
    }

    if (request.method === "GET" && path === "/quizzes") {
      return json({ sessions: await allSessions(env.DB) });
    }

    const sessionMatch = path.match(/^\/quiz-sessions\/([^/]+)$/);
    if (request.method === "GET" && sessionMatch) {
      const session = await sessionDetail(env.DB, sessionMatch[1]);
      if (!session) return json({ error: "Session not found." }, 404);
      return json({ session });
    }

    const focusMatch = path.match(/^\/notes\/([^/]+)\/focus-options$/);
    if (request.method === "GET" && focusMatch) {
      return json({ options: await focusOptions(env.DB, focusMatch[1]) });
    }

    const noteMatch = path.match(/^\/notes\/([^/]+)$/);
    if (noteMatch && (request.method === "PUT" || request.method === "PATCH")) {
      const body = await readJSON(request);
      const note = await updateNote(env, noteMatch[1], body.title, body.body, body.sourceType || "text");
      return json({ note, nextQuiz: { status: note.queuedQuizCount > 0 ? "ready" : "preparing", saved: note.questionCount } });
    }

    if (noteMatch && request.method === "DELETE") {
      await deleteNote(env.DB, noteMatch[1]);
      return json({ ok: true });
    }

    const buildMatch = path.match(/^\/notes\/([^/]+)\/build$/);
    if (buildMatch && request.method === "POST") {
      const note = await ensureQuestions(env, buildMatch[1]);
      return json({ note, nextQuiz: { status: note.queuedQuizCount > 0 ? "ready" : "preparing", saved: note.questionCount } }, 202);
    }

    const quizMatch = path.match(/^\/notes\/([^/]+)\/quiz$/);
    if (quizMatch && request.method === "GET") {
      return json(await startQuiz(env, quizMatch[1], url.searchParams.get("focus") || ""));
    }

    if (quizMatch && request.method === "POST") {
      const body = await readJSON(request);
      return json(await submitQuiz(env, quizMatch[1], body.answers || []));
    }

    if (request.method === "POST" && path === "/actions") {
      const body = await readJSON(request);
      await env.DB.prepare(`
        INSERT INTO user_actions (id, note_id, action_type, object_type, object_id, payload, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `).bind(
        crypto.randomUUID(),
        body.noteId || null,
        String(body.actionType || "ui.action"),
        String(body.objectType || ""),
        String(body.objectId || ""),
        JSON.stringify(body.payload || {}),
        now()
      ).run();
      return json({ ok: true }, 201);
    }

    if (request.method === "GET" && path === "/backup") {
      return json({ exportedAt: Date.now(), notes: await listNotes(env.DB), sessions: await allSessions(env.DB) });
    }

    if (request.method === "POST" && path === "/backup/restore") {
      return json({ ok: false, error: "Cloudflare restore is not implemented yet." }, 501);
    }

    return json({ error: "Not found." }, 404);
  } catch (error) {
    return json({ error: error.message || "Server error." }, 500);
  }
}

function json(payload, status = 200) {
  return new Response(JSON.stringify(payload), { status, headers: JSON_HEADERS });
}

async function readJSON(request) {
  try {
    return await request.json();
  } catch {
    return {};
  }
}

function now() {
  return Date.now() / 1000;
}

async function ensureSchema(db) {
  const statements = [
    `CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '', source_type TEXT NOT NULL DEFAULT 'text', status TEXT NOT NULL DEFAULT 'ready', created_at REAL NOT NULL)`,
    `CREATE TABLE IF NOT EXISTS questions (id TEXT PRIMARY KEY, note_id TEXT NOT NULL, topic TEXT NOT NULL, subtopic TEXT NOT NULL, prompt TEXT NOT NULL, answer TEXT NOT NULL, choices TEXT NOT NULL, understanding_score REAL NOT NULL DEFAULT 0, created_at REAL NOT NULL, last_seen_at REAL)`,
    `CREATE TABLE IF NOT EXISTS quiz_queue (id TEXT PRIMARY KEY, note_id TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'ready', question_ids TEXT NOT NULL DEFAULT '[]', summary TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL, consumed_at REAL)`,
    `CREATE TABLE IF NOT EXISTS attempts (id TEXT PRIMARY KEY, note_id TEXT NOT NULL, question_id TEXT NOT NULL, response TEXT NOT NULL, answer TEXT NOT NULL, score REAL NOT NULL, feedback TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL)`,
    `CREATE TABLE IF NOT EXISTS quiz_sessions (id TEXT PRIMARY KEY, note_id TEXT NOT NULL, score REAL NOT NULL, attempt_ids TEXT NOT NULL DEFAULT '[]', created_at REAL NOT NULL)`,
    `CREATE TABLE IF NOT EXISTS user_actions (id TEXT PRIMARY KEY, note_id TEXT, action_type TEXT NOT NULL, object_type TEXT NOT NULL DEFAULT '', object_id TEXT NOT NULL DEFAULT '', payload TEXT NOT NULL DEFAULT '{}', created_at REAL NOT NULL)`
  ];
  for (const statement of statements) await db.prepare(statement).run();
}

async function listNotes(db) {
  const rows = await db.prepare(`
    SELECT
      n.*,
      COUNT(DISTINCT q.id) AS question_count,
      COUNT(DISTINCT CASE WHEN qq.state = 'ready' THEN qq.id END) AS queued_quiz_count,
      COUNT(DISTINCT a.id) AS attempt_count,
      AVG(a.score) AS average_score
    FROM notes n
    LEFT JOIN questions q ON q.note_id = n.id
    LEFT JOIN quiz_queue qq ON qq.note_id = n.id
    LEFT JOIN attempts a ON a.note_id = n.id
    GROUP BY n.id
    ORDER BY n.created_at DESC
  `).all();
  return rows.results.map(noteDTO);
}

async function noteSummary(db, noteId) {
  const row = await db.prepare(`
    SELECT
      n.*,
      COUNT(DISTINCT q.id) AS question_count,
      COUNT(DISTINCT CASE WHEN qq.state = 'ready' THEN qq.id END) AS queued_quiz_count,
      COUNT(DISTINCT a.id) AS attempt_count,
      AVG(a.score) AS average_score
    FROM notes n
    LEFT JOIN questions q ON q.note_id = n.id
    LEFT JOIN quiz_queue qq ON qq.note_id = n.id
    LEFT JOIN attempts a ON a.note_id = n.id
    WHERE n.id = ?
    GROUP BY n.id
  `).bind(noteId).first();
  return row ? noteDTO(row) : null;
}

function noteDTO(row) {
  return {
    id: row.id,
    title: row.title,
    body: row.body,
    summary: row.summary || "",
    sourceType: row.source_type || "text",
    status: row.status || "ready",
    createdAt: Number(row.created_at || 0),
    sectionCount: 0,
    questionCount: Number(row.question_count || 0),
    queuedQuizCount: Number(row.queued_quiz_count || 0),
    attemptCount: Number(row.attempt_count || 0),
    averageScore: Number(row.average_score || 0)
  };
}

async function createNote(env, title, body, sourceType = "text") {
  const cleanBody = String(body || "").trim();
  if (!cleanBody) throw new Error("Note text is required.");
  const id = crypto.randomUUID();
  const cleanTitle = String(title || "Untitled Note").trim() || "Untitled Note";
  const summary = await summarizeNote(env, cleanTitle, cleanBody);
  await env.DB.prepare(`
    INSERT INTO notes (id, title, body, summary, source_type, status, created_at)
    VALUES (?, ?, ?, ?, ?, 'ready', ?)
  `).bind(id, cleanTitle, cleanBody, summary, String(sourceType || "text"), now()).run();
  await ensureQuestions(env, id);
  return noteSummary(env.DB, id);
}

async function updateNote(env, noteId, title, body, sourceType = "text") {
  const cleanBody = String(body || "").trim();
  if (!cleanBody) throw new Error("Note text is required.");
  const cleanTitle = String(title || "Untitled Note").trim() || "Untitled Note";
  const summary = await summarizeNote(env, cleanTitle, cleanBody);
  await env.DB.prepare(`UPDATE notes SET title = ?, body = ?, summary = ?, source_type = ?, status = 'ready' WHERE id = ?`)
    .bind(cleanTitle, cleanBody, summary, String(sourceType || "text"), noteId)
    .run();
  await env.DB.prepare(`DELETE FROM questions WHERE note_id = ?`).bind(noteId).run();
  await env.DB.prepare(`DELETE FROM quiz_queue WHERE note_id = ?`).bind(noteId).run();
  await ensureQuestions(env, noteId);
  return noteSummary(env.DB, noteId);
}

async function deleteNote(db, noteId) {
  for (const table of ["attempts", "quiz_sessions", "quiz_queue", "questions", "notes"]) {
    await db.prepare(`DELETE FROM ${table} WHERE ${table === "notes" ? "id" : "note_id"} = ?`).bind(noteId).run();
  }
}

async function ensureQuestions(env, noteId) {
  const note = await noteSummary(env.DB, noteId);
  const existing = await env.DB.prepare(`SELECT prompt, answer FROM questions WHERE note_id = ?`).bind(noteId).all();
  const existingQuestions = existing.results || [];
  const desired = desiredQuestionCount(note);
  const minimumQuizBank = initialQuizBankSize(note);
  let insertedQuestions = false;
  if (existingQuestions.length < minimumQuizBank) {
    const questions = await generateQuestions(env, note, minimumQuizBank - existingQuestions.length, existingQuestions, false);
    for (const question of questions) {
      await insertQuestion(env.DB, noteId, question);
      insertedQuestions = true;
    }
  }
  if (insertedQuestions) {
    await env.DB.prepare(`DELETE FROM quiz_queue WHERE note_id = ? AND state = 'ready'`).bind(noteId).run();
  }
  await queueQuiz(env.DB, noteId);
  return noteSummary(env.DB, noteId);
}

async function insertQuestion(db, noteId, question) {
  const choices = normalizeChoices(question.answer, question.choices);
  await db.prepare(`
    INSERT INTO questions (id, note_id, topic, subtopic, prompt, answer, choices, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).bind(
    crypto.randomUUID(),
    noteId,
    String(question.topic || "Core Ideas").slice(0, 80),
    String(question.subtopic || "Understanding").slice(0, 80),
    String(question.prompt || "").slice(0, 400),
    String(question.answer || "").slice(0, 240),
    JSON.stringify(choices),
    now()
  ).run();
}

async function queueQuiz(db, noteId, focus = "") {
  const ready = await db.prepare(`SELECT id FROM quiz_queue WHERE note_id = ? AND state = 'ready' LIMIT 1`).bind(noteId).first();
  if (ready) return;
  const note = await noteSummary(db, noteId);
  const totalQuestions = Number(note?.questionCount || 0);
  const quizSize = adaptiveQuizSize(note, focus, totalQuestions);
  const minimumUsefulQuizSize = Math.min(4, totalQuestions);
  const candidateLimit = Math.max(48, quizSize * 6);
  let rows = await db.prepare(`
    SELECT * FROM questions
    WHERE note_id = ?
      AND (? = '' OR topic = ? OR subtopic = ?)
    ORDER BY COALESCE(understanding_score, 0) ASC, COALESCE(last_seen_at, 0) ASC, RANDOM()
    LIMIT ?
  `).bind(noteId, focus, focus, focus, candidateLimit).all();
  if (focus && rows.results.length < minimumUsefulQuizSize) {
    rows = await db.prepare(`
      SELECT * FROM questions
      WHERE note_id = ?
      ORDER BY COALESCE(understanding_score, 0) ASC, COALESCE(last_seen_at, 0) ASC, RANDOM()
      LIMIT ?
    `).bind(noteId, candidateLimit).all();
  }
  const ids = selectQuizRows(rows.results || [], quizSize).map((row) => row.id);
  if (ids.length === 0) return;
  await db.prepare(`
    INSERT INTO quiz_queue (id, note_id, state, question_ids, summary, created_at)
    VALUES (?, ?, 'ready', ?, 'Quiz prepared from Cloudflare D1 memory.', ?)
  `).bind(crypto.randomUUID(), noteId, JSON.stringify(ids), now()).run();
}

function initialQuizBankSize(note) {
  const desired = desiredQuestionCount(note);
  return Math.max(1, Math.min(desired, adaptiveQuizSize(note, "", desired)));
}

function adaptiveQuizSize(note, focus = "", availableQuestions = 0) {
  const available = Math.max(0, Number(availableQuestions || 0));
  if (available <= 0) return 0;
  if (available <= 6) return available;

  const attempts = Number(note?.attemptCount || 0);
  const sourceType = String(note?.sourceType || "");
  const focused = Boolean(String(focus || "").trim());

  if (focused) return Math.min(available, attempts >= 12 ? 8 : 6);
  if (available <= 10) return Math.min(available, 8);
  if (available <= 18) return Math.min(available, attempts >= 12 ? 12 : 10);
  if (sourceType === "books") return Math.min(available, attempts >= 24 ? 14 : 12);
  return Math.min(available, attempts >= 24 ? 12 : 10);
}

function selectQuizRows(rows, limit) {
  const selected = [];
  const pushIf = (row, predicate) => {
    if (selected.length >= limit || selected.some((item) => item.id === row.id)) return;
    if (predicate(row, selected)) selected.push(row);
  };

  for (const row of rows) {
    pushIf(row, (candidate, current) =>
      !current.some((item) => normalize(item.topic) === normalize(candidate.topic)) &&
      isDiverseQuizCandidate(candidate, current)
    );
  }
  for (const row of rows) {
    pushIf(row, (candidate, current) => isDiverseQuizCandidate(candidate, current));
  }
  for (const row of rows) {
    pushIf(row, (candidate, current) =>
      !current.some((item) => normalize(item.prompt) === normalize(candidate.prompt))
    );
  }
  return selected.slice(0, limit);
}

function isDiverseQuizCandidate(candidate, selected) {
  return !selected.some((item) =>
    normalize(item.subtopic) === normalize(candidate.subtopic) ||
    normalize(item.answer) === normalize(candidate.answer) ||
    quizPromptFamily(item.prompt) === quizPromptFamily(candidate.prompt) ||
    tokenOverlap(normalize(item.prompt), normalize(candidate.prompt)) >= 0.68
  );
}

function quizPromptFamily(prompt) {
  const clean = normalize(prompt)
    .replace(/\blebron\b|\bjames\b/g, "")
    .replace(/\b\d+\b/g, "#")
    .replace(/\s+/g, " ")
    .trim();
  if (/^what record .* hold regarding the most/.test(clean)) return "record-most";
  if (/^how many .* mvp/.test(clean)) return "count-mvp";
  if (/^how many .* all star/.test(clean)) return "count-all-star";
  if (/^how many .* all defensive/.test(clean)) return "count-defense";
  if (/^how many .* finals/.test(clean)) return "count-finals";
  if (/^how many .* championships/.test(clean)) return "count-championships";
  if (/^how many/.test(clean)) return clean.split(" ").slice(0, 5).join(" ");
  return clean.split(" ").slice(0, 7).join(" ");
}

async function startQuiz(env, noteId, focus = "") {
  if (focus) {
    await env.DB.prepare(`DELETE FROM quiz_queue WHERE note_id = ? AND state = 'ready'`).bind(noteId).run();
    await queueQuiz(env.DB, noteId, focus);
  }
  await ensureQuestions(env, noteId);
  let queued = await env.DB.prepare(`SELECT * FROM quiz_queue WHERE note_id = ? AND state = 'ready' ORDER BY created_at LIMIT 1`).bind(noteId).first();
  if (!queued) return { questions: [], nextQuiz: { status: "preparing", saved: 0 } };
  let ids = [];
  try {
    ids = JSON.parse(queued.question_ids || "[]");
  } catch {
    ids = [];
  }
  const questions = [];
  for (const id of ids) {
    const row = await env.DB.prepare(`SELECT * FROM questions WHERE id = ? AND note_id = ?`).bind(id, noteId).first();
    if (row) questions.push(questionDTO(row));
  }
  await env.DB.prepare(`UPDATE quiz_queue SET state = 'consumed', consumed_at = ? WHERE id = ?`).bind(now(), queued.id).run();
  await env.DB.prepare(`UPDATE questions SET last_seen_at = ? WHERE id IN (${ids.map(() => "?").join(",") || "NULL"})`).bind(now(), ...ids).run();
  return { questions, nextQuiz: null, queue: { id: queued.id, reason: "cloudflare", summary: queued.summary } };
}

function questionDTO(row) {
  return {
    id: row.id,
    variantId: row.id,
    deliveryType: "multiple_choice",
    topic: row.topic,
    subtopic: row.subtopic,
    assessmentAngle: "recall",
    prompt: row.prompt,
    answer: row.answer,
    choices: normalizeChoices(row.answer, safeJSON(row.choices, []))
  };
}

async function submitQuiz(env, noteId, answers) {
  const attemptIds = [];
  let earned = 0;
  const details = [];
  for (const item of answers) {
    const question = await env.DB.prepare(`SELECT * FROM questions WHERE id = ? AND note_id = ?`).bind(item.questionId, noteId).first();
    if (!question) continue;
    const response = String(item.response || "");
    const score = normalize(response) === normalize(question.answer) ? 1 : 0;
    earned += score;
    const feedback = score === 1 ? "Correct." : `Review this idea. Correct answer: ${question.answer}`;
    const attemptId = crypto.randomUUID();
    attemptIds.push(attemptId);
    details.push({
      id: attemptId,
      questionId: question.id,
      topic: question.topic,
      subtopic: question.subtopic,
      prompt: question.prompt,
      response,
      answer: question.answer,
      score,
      feedback
    });
    await env.DB.prepare(`
      INSERT INTO attempts (id, note_id, question_id, response, answer, score, feedback, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(attemptId, noteId, question.id, response, question.answer, score, feedback, now()).run();
    await env.DB.prepare(`UPDATE questions SET understanding_score = ?, last_seen_at = ? WHERE id = ?`)
      .bind(score, now(), question.id)
      .run();
  }
  const score = details.length ? earned / details.length : 0;
  const sessionId = crypto.randomUUID();
  await env.DB.prepare(`INSERT INTO quiz_sessions (id, note_id, score, attempt_ids, created_at) VALUES (?, ?, ?, ?, ?)`)
    .bind(sessionId, noteId, score, JSON.stringify(attemptIds), now())
    .run();
  await env.DB.prepare(`DELETE FROM quiz_queue WHERE note_id = ? AND state = 'ready'`).bind(noteId).run();
  if (score >= 0.9) {
    await expandAfterMastery(env, noteId);
  }
  await ensureQuestions(env, noteId);
  return {
    id: sessionId,
    noteId,
    score,
    details,
    nextQuiz: { status: "ready", saved: details.length },
    learningEvidence: { summary: "D1 saved this quiz attempt and updated each question's understanding score." }
  };
}

async function expandAfterMastery(env, noteId) {
  const note = await noteSummary(env.DB, noteId);
  const existing = await env.DB.prepare(`SELECT prompt, answer FROM questions WHERE note_id = ?`).bind(noteId).all();
  const existingQuestions = existing.results || [];
  if (existingQuestions.length >= 24) return;
  try {
    const questions = await generateQuestions(env, note, Math.min(4, 24 - existingQuestions.length), existingQuestions, false);
    for (const question of questions) await insertQuestion(env.DB, noteId, question);
  } catch {
    // Keep grading reliable even if the model cannot expand the bank on this pass.
  }
}

async function allSessions(db) {
  const rows = await db.prepare(`
    SELECT s.*, n.title AS note_title
    FROM quiz_sessions s
    JOIN notes n ON n.id = s.note_id
    ORDER BY s.created_at DESC
    LIMIT 100
  `).all();
  return rows.results.map((row) => ({
    id: row.id,
    noteId: row.note_id,
    noteTitle: row.note_title,
    score: Number(row.score || 0),
    createdAt: Number(row.created_at || 0),
    attemptCount: safeJSON(row.attempt_ids, []).length
  }));
}

async function sessionDetail(db, sessionId) {
  const session = await db.prepare(`
    SELECT s.*, n.title AS note_title
    FROM quiz_sessions s
    JOIN notes n ON n.id = s.note_id
    WHERE s.id = ?
  `).bind(sessionId).first();
  if (!session) return null;
  const ids = safeJSON(session.attempt_ids, []);
  const attempts = [];
  for (const id of ids) {
    const row = await db.prepare(`
      SELECT a.*, q.topic, q.subtopic, q.prompt
      FROM attempts a
      LEFT JOIN questions q ON q.id = a.question_id
      WHERE a.id = ?
    `).bind(id).first();
    if (row) attempts.push({
      id: row.id,
      topic: row.topic || "Saved Attempt",
      subtopic: row.subtopic || "Earlier quiz",
      prompt: row.prompt || "Original question unavailable.",
      response: row.response,
      answer: row.answer,
      score: Number(row.score || 0),
      feedback: row.feedback || ""
    });
  }
  return {
    id: session.id,
    noteId: session.note_id,
    noteTitle: session.note_title,
    score: Number(session.score || 0),
    createdAt: Number(session.created_at || 0),
    attempts
  };
}

async function focusOptions(db, noteId) {
  const rows = await db.prepare(`
    SELECT topic, subtopic, COUNT(*) AS question_count
    FROM questions
    WHERE note_id = ?
    GROUP BY topic, subtopic
    ORDER BY topic, subtopic
  `).bind(noteId).all();
  const topics = new Set();
  const options = [];
  for (const row of rows.results) {
    if (!topics.has(row.topic)) {
      topics.add(row.topic);
      options.push({ type: "topic", value: row.topic, topic: row.topic, subtopic: "", questionCount: 0 });
    }
    options.push({ type: "subtopic", value: row.subtopic, topic: row.topic, subtopic: row.subtopic, questionCount: Number(row.question_count || 0) });
  }
  return options;
}

async function searchWikipedia(query) {
  const payload = await wikipediaJSON({
    action: "query",
    list: "search",
    srsearch: query,
    srlimit: "6",
    srprop: "snippet"
  });
  return (payload.query?.search || [])
    .filter(isUsefulWikipediaResult)
    .slice(0, 6)
    .map((item) => ({
      title: item.title,
      snippet: decodeHTML(String(item.snippet || "").replace(/<[^>]+>/g, ""))
    }));
}

function isUsefulWikipediaResult(item) {
  const text = `${item.title || ""} ${item.snippet || ""}`.toLowerCase();
  const blocked = [" sex", "porn", "erotic", "sexual"];
  return !blocked.some((term) => text.includes(term));
}

function decodeHTML(value) {
  return String(value)
    .replace(/&quot;/g, "\"")
    .replace(/&#039;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">");
}

async function wikipediaArticle(title) {
  const cleanTitle = String(title || "").trim();
  if (!cleanTitle) throw new Error("Wikipedia title is required.");
  const payload = await wikipediaJSON({
    action: "query",
    prop: "extracts",
    exintro: "0",
    explaintext: "1",
    redirects: "1",
    titles: cleanTitle
  });
  const page = payload.query?.pages?.find((candidate) => candidate.missing !== true);
  if (!page?.extract) throw new Error("Wikipedia article text was not available.");
  return {
    title: page.title || cleanTitle,
    text: String(page.extract || "").replace(/\n{3,}/g, "\n\n").trim()
  };
}

async function wikipediaJSON(params) {
  const url = new URL("https://en.wikipedia.org/w/api.php");
  url.searchParams.set("format", "json");
  url.searchParams.set("formatversion", "2");
  url.searchParams.set("origin", "*");
  for (const [key, value] of Object.entries(params)) {
    url.searchParams.set(key, value);
  }

  const response = await fetch(url, {
    headers: {
      accept: "application/json",
      "user-agent": "QuizLoop.ai/1.0 (https://accordian-bgp.pages.dev; Kaggle Gemma 4 Good demo)"
    }
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`Wikipedia request failed: ${response.status}`);
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new Error("Wikipedia returned an unreadable response. Please try a more specific search.");
  }
}

async function summarizeNote(env, title, body) {
  const fallback = String(body || "").split(/\s+/).slice(0, 32).join(" ");
  const result = await gemmaJSON(env, `
Summarize this note for a learner in one sentence. Use only the note.
Return {"summary":"..."}.
TITLE: ${title}
NOTE: ${String(body || "").slice(0, 5000)}
`);
  return String(result?.summary || fallback || "QuizLoop will prepare quizzes from this note.").slice(0, 420);
}

async function shapeNote(env, title, body, sourceType) {
  const raw = String(body || "").trim();
  if (!raw) throw new Error("Note text is required.");
  const result = await gemmaJSON(env, `
Shape this raw note for quiz generation. Use only the provided text. Return JSON:
{"title":"short title","body":"clear structured note","feedback":["what improved","what would help quizzes"]}
SOURCE_TYPE: ${sourceType}
TITLE: ${title || "Untitled Note"}
NOTE: ${raw.slice(0, 8000)}
`);
  return {
    title: String(result?.title || title || "Untitled Note"),
    body: String(result?.body || raw),
    feedback: Array.isArray(result?.feedback) ? result.feedback.slice(0, 3).map(String) : ["Structured the note for quiz generation."]
  };
}

function desiredQuestionCount(note) {
  const words = String(note.body || "").split(/\s+/).filter(Boolean).length;
  return Math.max(8, Math.min(24, Math.ceil(words / 70) * 4));
}

async function generateQuestions(env, note, requestedCount = desiredQuestionCount(note), existingQuestions = [], requireFull = true) {
  const target = Math.max(1, Math.min(16, Number(requestedCount || 0)));
  const gemma = gemmaStatus(env);
  if (!gemma.available) {
    throw new Error("Gemma is not connected. Connect the model endpoint before building quizzes.");
  }
  const questions = [];
  const blockedPrompts = existingQuestions.map((question) => String(question.prompt || "")).filter(Boolean);
  for (let pass = 0; pass < 3 && questions.length < target; pass += 1) {
    const missing = target - questions.length;
    const result = await gemmaJSON(env, `
Create exactly ${missing} new high-quality multiple-choice quiz questions from this note.
Use only the note. Avoid duplicate questions and avoid these existing prompts:
${[...blockedPrompts, ...questions.map((question) => question.prompt)].map((prompt) => `- ${prompt}`).join("\n") || "- none yet"}

Return JSON only with this exact shape:
{"questions":[{"topic":"specific topic","subtopic":"specific subtopic","prompt":"clear question","answer":"correct answer from the note","choices":["wrong but plausible","correct answer from the note","wrong but plausible","wrong but plausible"]}]}

Rules:
- Every question must test a different idea from the note.
- Prefer meaningful understanding checks over tiny isolated facts.
- Wrong choices must be plausible, not silly, generic, or meta.
- Do not ask about "this note" as an object.
- Prefer factual, conceptual, cause/effect, sequence, and evidence questions.
- If the note is math, include concrete calculation questions with numerical answers.

TITLE: ${note.title}
NOTE: ${note.body.slice(0, 9000)}
`);
    for (const question of Array.isArray(result?.questions) ? result.questions : []) {
      if (!validGeneratedQuestion(question)) continue;
      if (isDuplicateQuestion(question, [...existingQuestions, ...questions])) continue;
      questions.push(question);
      if (questions.length >= target) break;
    }
  }
  if (questions.length >= target || (!requireFull && questions.length > 0)) return questions.slice(0, target);
  throw new Error(`Gemma produced ${questions.length} valid questions, but ${target} were needed. Rebuild this quiz after checking the note or model connection.`);
}

function validGeneratedQuestion(question) {
  if (!question || typeof question !== "object") return false;
  const prompt = String(question.prompt || "").trim();
  const answer = String(question.answer || "").trim();
  const choices = Array.isArray(question.choices) ? question.choices.map(String).filter(Boolean) : [];
  if (prompt.length < 18 || answer.length < 2 || choices.length < 4) return false;
  if (/which term appears|what source is this note|this note about/i.test(prompt)) return false;
  const uniqueChoices = new Set(choices.map(normalize));
  return uniqueChoices.size >= 4 && uniqueChoices.has(normalize(answer));
}

function isDuplicateQuestion(candidate, existingQuestions) {
  const prompt = normalize(candidate.prompt);
  const answer = normalize(candidate.answer);
  return existingQuestions.some((existing) => {
    const existingPrompt = normalize(existing.prompt);
    const existingAnswer = normalize(existing.answer);
    const promptSimilarity = tokenOverlap(prompt, existingPrompt);
    const answerSimilarity = tokenOverlap(answer, existingAnswer);
    return prompt === existingPrompt ||
      promptSimilarity >= 0.78 ||
      (answer === existingAnswer && promptSimilarity >= 0.45) ||
      (answer.length > 12 && answerSimilarity >= 0.82 && promptSimilarity >= 0.45);
  });
}

function tokenOverlap(left, right) {
  const leftTokens = new Set(String(left || "").split(/\s+/).filter((token) => token.length > 2));
  const rightTokens = new Set(String(right || "").split(/\s+/).filter((token) => token.length > 2));
  if (leftTokens.size === 0 || rightTokens.size === 0) return 0;
  let shared = 0;
  for (const token of leftTokens) {
    if (rightTokens.has(token)) shared += 1;
  }
  return shared / Math.min(leftTokens.size, rightTokens.size);
}

function gemmaStatus(env) {
  const baseURL = String(env.GEMMA_BASE_URL || "").replace(/\/$/, "");
  const reachable = Boolean(baseURL && !baseURL.includes("127.0.0.1") && !baseURL.includes("localhost"));
  return {
    available: reachable,
    model: env.GEMMA_MODEL || "gemma4:e2b",
    provider: reachable ? "Gemma 4 via Ollama-compatible endpoint" : "Gemma endpoint required",
    message: reachable
      ? "Gemma is connected for note shaping, quiz generation, and grading."
      : "Gemma is not connected to this hosted domain. Quiz generation is paused until a model endpoint is configured."
  };
}

async function gemmaHealth(env) {
  const status = gemmaStatus(env);
  if (!status.available) return status;
  const baseURL = String(env.GEMMA_BASE_URL || "").replace(/\/$/, "");
  const headers = {};
  if (env.GEMMA_API_TOKEN) headers["x-accordian-model-token"] = env.GEMMA_API_TOKEN;
  try {
    const response = await fetch(`${baseURL}/api/tags`, { headers });
    if (!response.ok) throw new Error(`model endpoint returned ${response.status}`);
    const payload = await response.json();
    const models = Array.isArray(payload.models) ? payload.models : [];
    const expectedModel = env.GEMMA_MODEL || "gemma4:e2b";
    const hasModel = models.some((model) => model.name === expectedModel || model.model === expectedModel);
    return {
      ...status,
      available: hasModel,
      message: hasModel
        ? "Gemma is connected for note shaping, quiz generation, and grading."
        : `Gemma endpoint is reachable, but ${expectedModel} is not installed.`
    };
  } catch {
    return {
      ...status,
      available: false,
      message: "Gemma is required but the model endpoint is not answering right now."
    };
  }
}

async function gemmaJSON(env, prompt) {
  const baseURL = String(env.GEMMA_BASE_URL || "").replace(/\/$/, "");
  if (!baseURL || baseURL.includes("127.0.0.1") || baseURL.includes("localhost")) return null;
  const headers = { "content-type": "application/json" };
  if (env.GEMMA_API_TOKEN) headers["x-accordian-model-token"] = env.GEMMA_API_TOKEN;
  try {
    const response = await fetch(`${baseURL}/api/chat`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        model: env.GEMMA_MODEL || "gemma4:e2b",
        stream: false,
        think: false,
        format: "json",
        messages: [{ role: "user", content: prompt }]
      })
    });
    if (!response.ok) return null;
    const payload = await response.json();
    return JSON.parse(String(payload.message?.content || "{}").match(/\{[\s\S]*\}/)?.[0] || "{}");
  } catch {
    return null;
  }
}

function sourceGroundedQuestions(note, target = 6) {
  const sentences = meaningfulSentences(note.body);
  const first = sentences[0] || `${note.title} is the subject of this note.`;
  const numberSentence = sentences.find((sentence) => /\b\d[\d,]*(?:\.\d+)?\b/.test(sentence));
  const questions = [
    statementQuestion(note, first),
    detailQuestion(note, numberSentence || sentences[1] || first)
  ];

  for (const sentence of sentences.slice(1)) {
    if (questions.length >= target) break;
    const answer = conciseSentence(sentence);
    if (questions.some((question) => normalize(question.answer) === normalize(answer))) continue;
    questions.push({
      topic: "Source Understanding",
      subtopic: note.title,
      prompt: "Which detail is stated in the note?",
      answer,
      choices: makeStatementChoices(answer, note.title)
    });
  }

  return questions.slice(0, Math.max(2, target));
}

function meaningfulSentences(body) {
  return String(body || "")
    .replace(/\[[^\]]+\]/g, "")
    .split(/(?<=[.!?])\s+/)
    .map((sentence) => sentence.replace(/\s+/g, " ").trim())
    .filter((sentence) =>
      sentence.length >= 45 &&
      sentence.length <= 260 &&
      !/^==/.test(sentence) &&
      !/^(see also|references|external links)$/i.test(sentence)
    )
    .slice(0, 20);
}

function statementQuestion(note, sentence) {
  const answer = conciseSentence(sentence);
  return {
    topic: "Core Understanding",
    subtopic: note.title,
    prompt: `Which statement best matches the note about ${note.title}?`,
    answer,
    choices: makeStatementChoices(answer, note.title)
  };
}

function detailQuestion(note, sentence) {
  const answer = conciseSentence(sentence);
  return {
    topic: "Evidence",
    subtopic: note.title,
    prompt: "Which specific detail is supported by the note?",
    answer,
    choices: makeStatementChoices(answer, note.title)
  };
}

function conciseSentence(sentence) {
  const clean = String(sentence || "").replace(/\s+/g, " ").trim();
  if (clean.length <= 150) return clean;
  const clause = clean.split(/;|, and |, but /)[0].trim();
  return clause.length >= 35 && clause.length <= 150 ? clause : `${clean.slice(0, 147).trim()}...`;
}

function makeStatementChoices(answer, title) {
  const variants = new Set([answer]);
  for (const variant of [
    mutateNumber(answer),
    invertRelationship(answer),
    swapTimeOrder(answer),
    softenOrReverseClaim(answer, title)
  ]) {
    if (variant && normalize(variant) !== normalize(answer)) variants.add(variant);
  }
  variants.add(`The note says the opposite of this detail about ${title}.`);
  variants.add(`This detail is not stated in the source text about ${title}.`);
  variants.add(`The note presents ${title} as unrelated to this idea.`);
  return [...variants];
}

function mutateNumber(value) {
  return String(value).replace(/\b(\d[\d,]*)(?:\.\d+)?\b/, (match) => {
    const numeric = Number(match.replace(/,/g, ""));
    if (!Number.isFinite(numeric)) return match;
    const changed = numeric >= 1000 ? numeric + 1000 : numeric + 1;
    return String(changed).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  });
}

function invertRelationship(value) {
  const replacements = [
    [/\bhas also won\b/i, "has not won"],
    [/\bhave also won\b/i, "have not won"],
    [/\bhas won\b/i, "has not won"],
    [/\bhave won\b/i, "have not won"],
    [/\bhave gained\b/i, "have not gained"],
    [/\bhas gained\b/i, "has not gained"],
    [/\bis a\b/i, "is not a"],
    [/\bare a\b/i, "are not a"],
    [/\bwas a\b/i, "was not a"],
    [/\bwere a\b/i, "were not a"],
    [/\bhave\b/i, "do not have"],
    [/\bhas\b/i, "does not have"],
    [/\bshare\b/i, "do not share"],
    [/\bperform\b/i, "do not perform"],
    [/\binclude\b/i, "exclude"]
  ];
  for (const [pattern, replacement] of replacements) {
    if (pattern.test(value)) return String(value).replace(pattern, replacement);
  }
  return "";
}

function swapTimeOrder(value) {
  const replacements = [
    [/\bbefore\b/i, "after"],
    [/\bafter\b/i, "before"],
    [/\bfirst\b/i, "last"],
    [/\bdeveloped\b/i, "declined"],
    [/\bmodern\b/i, "ancient"],
    [/\bsuperior\b/i, "inferior"],
    [/\binferior\b/i, "superior"],
    [/\bsame\b/i, "different"],
    [/\bwidely\b/i, "barely"],
    [/\bdomesticated\b/i, "wild"],
    [/\bpopular\b/i, "least common"]
  ];
  for (const [pattern, replacement] of replacements) {
    if (pattern.test(value)) return String(value).replace(pattern, replacement);
  }
  return "";
}

function softenOrReverseClaim(value, title) {
  const clean = String(value || "");
  const replacements = [
    [/\bbasketball\b/ig, "baseball"],
    [/\bLos Angeles Lakers\b/ig, "Boston Celtics"],
    [/\bgold medals?\b/ig, "silver medals"],
    [/\bU\.S\.\b/ig, "Canada"],
    [/\bgreatest\b/ig, "least accomplished"],
    [/\bhumans?\b/ig, "plants"],
    [/\bwolves?\b/ig, "birds"],
    [/\bdogs?\b/ig, "cats"]
  ];
  for (const [pattern, replacement] of replacements) {
    if (pattern.test(clean)) return clean.replace(pattern, replacement);
  }
  return "";
}

function normalizeChoices(answer, choices = []) {
  const seen = new Set();
  const all = [answer, ...choices].map(String).filter(Boolean).filter((choice) => {
    const key = normalize(choice);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  while (all.length < 4) all.push(`Option ${all.length + 1}`);
  return shuffle(all.slice(0, 4));
}

function shuffle(items) {
  return items.map((value) => ({ value, sort: Math.random() })).sort((a, b) => a.sort - b.sort).map((item) => item.value);
}

function normalize(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function safeJSON(value, fallback) {
  try {
    return JSON.parse(value || "");
  } catch {
    return fallback;
  }
}
