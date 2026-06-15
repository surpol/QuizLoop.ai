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

    const readinessMatch = path.match(/^\/notes\/([^/]+)\/cert-readiness$/);
    if (request.method === "GET" && readinessMatch) {
      return json({ readiness: await certReadiness(env.DB, readinessMatch[1]) });
    }

    const learnerReportMatch = path.match(/^\/notes\/([^/]+)\/learner-report$/);
    if (request.method === "POST" && learnerReportMatch) {
      return json(await learnerReport(env, learnerReportMatch[1]));
    }

    if (request.method === "GET" && path === "/lab") {
      return json(await labSnapshot(env.DB));
    }

    if (request.method === "GET" && path === "/evidence") {
      return json(await evidenceSnapshot(env.DB));
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
      return json(await startQuiz(env, quizMatch[1], {
        focus: url.searchParams.get("focus") || "",
        plan: url.searchParams.get("plan") || "free"
      }));
    }

    if (quizMatch && request.method === "POST") {
      const body = await readJSON(request);
      return json(await submitQuiz(env, quizMatch[1], body.answers || [], body.plan || "free"));
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

function clamp01(value) {
  return Math.max(0, Math.min(1, Number(value || 0)));
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
  await ensureColumns(db, "questions", [
    ["source_provider", "TEXT NOT NULL DEFAULT ''"],
    ["source_url", "TEXT NOT NULL DEFAULT ''"],
    ["source_license", "TEXT NOT NULL DEFAULT ''"],
    ["provenance_kind", "TEXT NOT NULL DEFAULT 'quizloop_seed'"],
    ["generation_source", "TEXT NOT NULL DEFAULT ''"]
  ]);
}

async function ensureColumns(db, tableName, additions) {
  const existing = await db.prepare(`PRAGMA table_info(${tableName})`).all();
  const names = new Set((existing.results || []).map((column) => String(column.name || "")));
  for (const [name, definition] of additions) {
    if (!names.has(name)) {
      await db.prepare(`ALTER TABLE ${tableName} ADD COLUMN ${name} ${definition}`).run();
    }
  }
}

async function listNotes(db) {
  const rows = await db.prepare(`
    SELECT
      n.*,
      COUNT(DISTINCT q.id) AS question_count,
      COUNT(DISTINCT CASE WHEN qq.state = 'ready' THEN qq.id END) AS queued_quiz_count,
      COUNT(DISTINCT a.id) AS attempt_count,
      AVG(a.score) AS average_score,
      COUNT(DISTINCT s.id) AS quiz_count,
      (SELECT latest.score FROM quiz_sessions latest WHERE latest.note_id = n.id ORDER BY latest.created_at DESC LIMIT 1) AS latest_score
    FROM notes n
    LEFT JOIN questions q ON q.note_id = n.id
    LEFT JOIN quiz_queue qq ON qq.note_id = n.id
    LEFT JOIN attempts a ON a.note_id = n.id
    LEFT JOIN quiz_sessions s ON s.note_id = n.id
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
      AVG(a.score) AS average_score,
      COUNT(DISTINCT s.id) AS quiz_count,
      (SELECT latest.score FROM quiz_sessions latest WHERE latest.note_id = n.id ORDER BY latest.created_at DESC LIMIT 1) AS latest_score
    FROM notes n
    LEFT JOIN questions q ON q.note_id = n.id
    LEFT JOIN quiz_queue qq ON qq.note_id = n.id
    LEFT JOIN attempts a ON a.note_id = n.id
    LEFT JOIN quiz_sessions s ON s.note_id = n.id
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
    averageScore: Number(row.average_score || 0),
    quizCount: Number(row.quiz_count || 0),
    latestScore: Number(row.latest_score || 0)
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

async function ensureQuestions(env, noteId, options = {}) {
  const allowAI = options.allowAI !== false;
  const shouldQueue = options.queue !== false;
  const note = await noteSummary(env.DB, noteId);
  const existing = await env.DB.prepare(`SELECT prompt, answer FROM questions WHERE note_id = ?`).bind(noteId).all();
  let existingQuestions = existing.results || [];
  const seedQuestions = certificationSeedQuestions(note);
  let insertedQuestions = false;
  for (const question of seedQuestions) {
    if (existingQuestions.length >= desiredQuestionCount(note)) break;
    if (isDuplicateQuestion(question, existingQuestions)) continue;
    await insertQuestion(env.DB, noteId, question);
    existingQuestions.push(question);
    insertedQuestions = true;
  }
  const minimumQuizBank = seedQuestions.length > 0 && existingQuestions.length > 0
    ? Math.min(initialQuizBankSize(note), existingQuestions.length)
    : initialQuizBankSize(note);
  if (allowAI && existingQuestions.length < minimumQuizBank) {
    while (existingQuestions.length < minimumQuizBank) {
      const needed = Math.min(12, minimumQuizBank - existingQuestions.length);
      const questions = await generateQuestions(env, note, needed, existingQuestions, false);
      if (!questions.length) break;
      for (const question of questions) {
        if (isDuplicateQuestion(question, existingQuestions)) continue;
        await insertQuestion(env.DB, noteId, question);
        existingQuestions.push(question);
        insertedQuestions = true;
      }
    }
  }
  if (insertedQuestions) {
    await env.DB.prepare(`DELETE FROM quiz_queue WHERE note_id = ? AND state = 'ready'`).bind(noteId).run();
  }
  if (shouldQueue) {
    await queueQuiz(env.DB, noteId, "", allowAI ? "adaptive" : "free");
  }
  return noteSummary(env.DB, noteId);
}

async function insertQuestion(db, noteId, question) {
  const choices = normalizeChoices(question.answer, question.choices);
  await db.prepare(`
    INSERT INTO questions (
      id, note_id, topic, subtopic, prompt, answer, choices,
      source_provider, source_url, source_license, provenance_kind, generation_source,
      created_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).bind(
    crypto.randomUUID(),
    noteId,
    String(question.topic || "Core Ideas").slice(0, 80),
    String(question.subtopic || "Understanding").slice(0, 80),
    String(question.prompt || "").slice(0, 400),
    String(question.answer || "").slice(0, 240),
    JSON.stringify(choices),
    String(question.sourceProvider || "QuizLoop").slice(0, 80),
    String(question.sourceUrl || "").slice(0, 240),
    String(question.sourceLicense || "").slice(0, 80),
    String(question.provenanceKind || "quizloop_seed").slice(0, 80),
    String(question.generationSource || "").slice(0, 180),
    now()
  ).run();
}

async function queueQuiz(db, noteId, focus = "", plan = "adaptive") {
  const ready = await db.prepare(`SELECT id FROM quiz_queue WHERE note_id = ? AND state = 'ready' LIMIT 1`).bind(noteId).first();
  if (ready) return;
  const note = await noteSummary(db, noteId);
  const totalQuestions = Number(note?.questionCount || 0);
  const quizSize = adaptiveQuizSize(note, focus, totalQuestions);
  const minimumUsefulQuizSize = Math.min(4, totalQuestions);
  const candidateLimit = Math.max(48, quizSize * 6);
  const freePractice = plan !== "adaptive";
  if (freePractice) {
    let rows = await db.prepare(`
      SELECT * FROM questions
      WHERE note_id = ?
        AND (? = '' OR topic = ? OR subtopic = ?)
      ORDER BY RANDOM()
      LIMIT ?
    `).bind(noteId, focus, focus, focus, Math.max(quizSize * 2, quizSize)).all();
    if (focus && rows.results.length < minimumUsefulQuizSize) {
      rows = await db.prepare(`
        SELECT * FROM questions
        WHERE note_id = ?
        ORDER BY RANDOM()
        LIMIT ?
      `).bind(noteId, Math.max(quizSize * 2, quizSize)).all();
    }
    const ids = randomQuizRows(rows.results || [], quizSize).map((row) => row.id);
    if (ids.length === 0) return;
    await db.prepare(`
      INSERT INTO quiz_queue (id, note_id, state, question_ids, summary, created_at)
      VALUES (?, ?, 'ready', ?, 'Free random practice from the saved question bank.', ?)
    `).bind(crypto.randomUUID(), noteId, JSON.stringify(ids), now()).run();
    return;
  }
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

function randomQuizRows(rows, limit) {
  const selected = [];
  const seenPrompts = new Set();
  for (const row of rows) {
    const key = normalize(row.prompt);
    if (seenPrompts.has(key)) continue;
    selected.push(row);
    seenPrompts.add(key);
    if (selected.length >= limit) break;
  }
  return selected;
}

function initialQuizBankSize(note) {
  const desired = desiredQuestionCount(note);
  if (isCertificationNote(note)) return desired;
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

async function startQuiz(env, noteId, options = {}) {
  const focus = String(options.focus || "");
  const plan = options.plan === "adaptive" || options.plan === "pro" || options.plan === "paid"
    ? "adaptive"
    : "free";
  const allowAI = plan === "adaptive";
  if (focus || plan === "free") {
    await env.DB.prepare(`DELETE FROM quiz_queue WHERE note_id = ? AND state = 'ready'`).bind(noteId).run();
  }
  await ensureQuestions(env, noteId, { allowAI, queue: false });
  await queueQuiz(env.DB, noteId, focus, plan);
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
  return { questions, nextQuiz: null, queue: { id: queued.id, reason: plan, summary: queued.summary } };
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

async function submitQuiz(env, noteId, answers, plan = "free") {
  const adaptive = plan === "adaptive" || plan === "pro" || plan === "paid";
  const answerItems = Array.isArray(answers)
    ? answers
    : Object.entries(answers || {}).map(([questionId, response]) => ({ questionId, response }));
  const attemptIds = [];
  let earned = 0;
  const details = [];
  for (const item of answerItems) {
    const question = await env.DB.prepare(`SELECT * FROM questions WHERE id = ? AND note_id = ?`).bind(item.questionId, noteId).first();
    if (!question) continue;
    const response = String(item.response || "");
    const score = normalize(response) === normalize(question.answer) ? 1 : 0;
    earned += score;
    const feedback = quizFeedback(question, response, score);
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
  if (adaptive && score >= 0.9) {
    await expandAfterMastery(env, noteId);
  }
  await ensureQuestions(env, noteId, { allowAI: adaptive, queue: false });
  await env.DB.prepare(`DELETE FROM quiz_queue WHERE note_id = ? AND state = 'ready'`).bind(noteId).run();
  await queueQuiz(env.DB, noteId, "", adaptive ? "adaptive" : "free");
  return {
    id: sessionId,
    noteId,
    score,
    details,
    nextQuiz: { status: "ready", saved: details.length },
    plan: adaptive ? "adaptive" : "free",
    learningEvidence: {
      headline: adaptive ? "AI coaching memory updated" : "Practice history saved",
      summary: adaptive
        ? "D1 saved this quiz attempt, updated each question score, and prepared an adaptive follow-up."
        : "D1 saved this quiz attempt. Free mode keeps questions random and does not use AI adaptation.",
      nextAction: adaptive ? "Next quiz adapts from this attempt." : "Next quiz is random from the bank."
    }
  };
}

function quizFeedback(question, response, score) {
  const topic = String(question.topic || "this exam area");
  const subtopic = String(question.subtopic || "this concept");
  const answer = String(question.answer || "the correct answer");
  if (score === 1) {
    return `Correct. For ${subtopic}, the key exam signal is ${answer}.`;
  }
  return `You chose ${response || "no answer"}, but this question is testing ${subtopic}. The correct match is ${answer}. Revisit this under ${topic}; QuizLoop will bring it back in a later quiz.`;
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

async function certReadiness(db, noteId) {
  const note = await noteSummary(db, noteId);
  if (!note) return null;
  const rows = await db.prepare(`
    SELECT
      q.topic,
      COUNT(DISTINCT q.id) AS question_count,
      COUNT(a.id) AS attempted_count,
      AVG(COALESCE(a.score, q.understanding_score, 0)) AS score
    FROM questions q
    LEFT JOIN attempts a ON a.question_id = q.id
    WHERE q.note_id = ?
    GROUP BY q.topic
    ORDER BY q.topic
  `).bind(noteId).all();
  const domains = (rows.results || []).map((row) => ({
    title: row.topic || "Practice",
    score: clamp01(Number(row.score || 0)),
    attemptedCount: Number(row.attempted_count || 0),
    questionCount: Number(row.question_count || 0)
  }));
  const attempted = domains.reduce((sum, domain) => sum + domain.attemptedCount, 0);
  const questionCount = domains.reduce((sum, domain) => sum + domain.questionCount, 0);
  const weighted = domains.reduce((sum, domain) => sum + domain.score * Math.max(1, domain.questionCount), 0);
  const denominator = domains.reduce((sum, domain) => sum + Math.max(1, domain.questionCount), 0) || 1;
  const readiness = attempted > 0
    ? clamp01(weighted / denominator)
    : 0;
  return {
    exam: note.title,
    readiness,
    passingScore: /cloud practitioner|clf/i.test(note.title)
      ? 700
      : /solution|architect|saa/i.test(note.title)
        ? 720
        : 70,
    domains: domains.length ? domains : [{
      title: "Practice",
      score: readiness,
      attemptedCount: attempted,
      questionCount
    }]
  };
}

async function learnerReport(env, noteId) {
  const note = await noteSummary(env.DB, noteId);
  if (!note) throw new Error("Note not found.");
  const readiness = await certReadiness(env.DB, noteId);
  const sessions = await env.DB.prepare(`
    SELECT score, created_at
    FROM quiz_sessions
    WHERE note_id = ?
    ORDER BY created_at DESC
    LIMIT 5
  `).bind(noteId).all();
  const weakest = [...(readiness?.domains || [])].sort((a, b) => a.score - b.score)[0];
  const latest = sessions.results?.[0];
  const deterministic = [
    `${note.title}: ${Math.round(Number(readiness?.readiness || 0) * 100)}% readiness from ${Number(note.attemptCount || 0)} saved answers.`,
    latest ? `Latest quiz: ${Math.round(Number(latest.score || 0) * 100)}%.` : "No completed quiz yet.",
    weakest ? `Next focus: ${weakest.title}.` : "Next focus: take the first quiz.",
    "QuizLoop will keep recycling weak concepts and mixing in fresh questions until the evidence improves."
  ].join("\n");

  const geminiKey = String(env.GEMINI_API_KEY || "");
  if (!geminiKey) {
    return { report: deterministic, model: "local evidence summary" };
  }

  try {
    const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${env.GEMINI_MODEL || "gemini-2.5-flash"}:generateContent?key=${geminiKey}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        contents: [{
          parts: [{
            text: `Write a concise learner progress report from this QuizLoop evidence. No hype. Mention next focus.\n${JSON.stringify({ note, readiness, sessions: sessions.results || [] }).slice(0, 8000)}`
          }]
        }]
      })
    });
    if (!response.ok) throw new Error(`Gemini returned ${response.status}`);
    const payload = await response.json();
    const text = payload.candidates?.[0]?.content?.parts?.map((part) => part.text || "").join("\n").trim();
    return { report: text || deterministic, model: env.GEMINI_MODEL || "gemini-2.5-flash" };
  } catch {
    return { report: deterministic, model: "local evidence summary" };
  }
}

async function labSnapshot(db) {
  const notes = await listNotes(db);
  const exams = [];
  for (const note of notes) {
    const readiness = await certReadiness(db, note.id);
    const domainBreakdown = await db.prepare(`
      SELECT topic, COUNT(*) AS total
      FROM questions
      WHERE note_id = ?
      GROUP BY topic
      ORDER BY total DESC, topic
    `).bind(note.id).all();
    const sourceBreakdown = await db.prepare(`
      SELECT
        CASE
          WHEN source_provider IS NULL OR source_provider = '' THEN 'QuizLoop bank'
          ELSE source_provider
        END AS sourceProvider,
        COUNT(*) AS count
      FROM questions
      WHERE note_id = ?
      GROUP BY sourceProvider
      ORDER BY count DESC, sourceProvider
    `).bind(note.id).all();
    const readyQueueRows = await db.prepare(`
      SELECT id, state, question_ids, summary, created_at
      FROM quiz_queue
      WHERE note_id = ? AND state = 'ready'
      ORDER BY created_at DESC
      LIMIT 2
    `).bind(note.id).all();
    const recent = await db.prepare(`
      SELECT score, created_at
      FROM quiz_sessions
      WHERE note_id = ?
      ORDER BY created_at DESC
      LIMIT 6
    `).bind(note.id).all();
    const latestMisses = await db.prepare(`
      SELECT q.topic, q.subtopic, q.prompt, q.answer, a.response, a.score, a.feedback, a.created_at
      FROM attempts a
      JOIN questions q ON q.id = a.question_id
      WHERE a.note_id = ? AND a.score < 1
      ORDER BY a.created_at DESC
      LIMIT 8
    `).bind(note.id).all();
    const weakQuestions = await db.prepare(`
      SELECT q.topic, q.subtopic, q.prompt, q.answer, COUNT(a.id) AS attempts, AVG(a.score) AS averageScore
      FROM questions q
      JOIN attempts a ON a.question_id = q.id
      WHERE q.note_id = ?
      GROUP BY q.id
      HAVING attempts > 0 AND averageScore < 0.8
      ORDER BY averageScore ASC, attempts DESC
      LIMIT 8
    `).bind(note.id).all();
    const readyQueue = [];
    for (const row of readyQueueRows.results || []) {
      const ids = safeJSON(row.question_ids, []);
      const questions = [];
      for (const id of ids.slice(0, 14)) {
        const question = await db.prepare(`SELECT * FROM questions WHERE id = ? AND note_id = ?`).bind(id, note.id).first();
        if (question) questions.push({ ...questionDTO(question), provenanceKind: "d1_queue" });
      }
      readyQueue.push({
        id: row.id,
        reason: row.summary || row.state || "ready",
        createdAt: Number(row.created_at || 0),
        questions
      });
    }
    exams.push({
      id: note.id,
      note,
      readiness,
      domainBreakdown: (domainBreakdown.results || []).map((row) => ({
        topic: row.topic || "Practice",
        total: Number(row.total || 0),
        scenario: 0,
        application: Number(row.total || 0),
        trap: 0
      })),
      sourceBreakdown: (sourceBreakdown.results || []).map((row) => ({
        sourceProvider: row.sourceProvider || row.sourceprovider || "QuizLoop bank",
        count: Number(row.count || 0)
      })),
      readyQueue,
      latestMisses: latestMisses.results || [],
      weakQuestions: weakQuestions.results || [],
      recentSessions: recent.results || []
    });
  }
  return {
    generatedAt: Date.now(),
    database: "Cloudflare D1",
    exams
  };
}

async function evidenceSnapshot(db) {
  const notes = await listNotes(db);
  const sessions = await allSessions(db);
  const actions = await db.prepare(`
    SELECT action_type, object_type, object_id, created_at
    FROM user_actions
    ORDER BY created_at DESC
    LIMIT 50
  `).all();
  return {
    generatedAt: Date.now(),
    database: "Cloudflare D1",
    notes,
    sessions,
    actions: actions.results || []
  };
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
  const probe = { title, body, sourceType: "certs" };
  if (isCloudPractitionerNote(probe)) {
    return "AWS Cloud Practitioner prep covering cloud concepts, security, core AWS services, pricing, billing, and support.";
  }
  if (isSolutionsArchitectNote(probe)) {
    return "AWS Solutions Architect Associate prep covering secure, resilient, high-performing, and cost-optimized architectures.";
  }
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

function isCertificationNote(note) {
  return String(note?.sourceType || note?.source_type || "").toLowerCase() === "certs"
    || /^##\s*Certification:/i.test(String(note?.body || ""));
}

function isCloudPractitionerNote(note) {
  const text = `${note?.title || ""}\n${note?.body || ""}`;
  return /cloud practitioner|clf-c02/i.test(text);
}

function isSolutionsArchitectNote(note) {
  const text = `${note?.title || ""}\n${note?.body || ""}`;
  return /solutions architect|saa-c03/i.test(text);
}

function certificationSeedQuestions(note) {
  if (isSolutionsArchitectNote(note)) return [
    ...solutionsArchitectSeedQuestions(),
    ...solutionsArchitectSupplementalQuestions()
  ];
  if (isCloudPractitionerNote(note)) return cloudPractitionerSeedQuestions();
  return [];
}

function seedQuestion(topic, subtopic, prompt, answer, choices) {
  return {
    topic,
    subtopic,
    prompt,
    answer,
    choices: normalizeChoices(answer, choices)
  };
}

function cloudPractitionerSeedQuestions() {
  const q = seedQuestion;
  return [
    q("Cloud Concepts", "Value proposition", "A startup wants to avoid buying servers up front and pay only as usage grows. Which cloud benefit does this describe?", "trading capital expense for variable expense", ["trading capital expense for variable expense", "increasing fixed hardware contracts", "owning physical servers for every workload", "removing all customer responsibilities"]),
    q("Cloud Concepts", "Elasticity", "A retail site needs capacity to rise during a holiday sale and fall afterward. Which AWS Cloud concept is being used?", "elasticity", ["elasticity", "data residency", "reserved capacity only", "manual procurement"]),
    q("Cloud Concepts", "Scalability", "A workload needs to add resources as demand increases over time. Which cloud concept does this describe?", "scalability", ["scalability", "immutability", "data sovereignty", "root access"]),
    q("Cloud Concepts", "Agility", "A team wants to launch test environments quickly without waiting for hardware procurement. Which AWS Cloud benefit is most relevant?", "agility", ["agility", "fixed capacity", "manual data center expansion", "long-term hardware leasing"]),
    q("Cloud Concepts", "Availability Zones", "Which infrastructure design helps applications stay available by placing resources in isolated locations within a Region?", "Availability Zones", ["Availability Zones", "IAM users", "AWS Budgets", "Amazon Machine Images"]),
    q("Cloud Concepts", "Regions", "A business must keep workloads in a specific geographic area. Which AWS global infrastructure unit should it choose?", "Region", ["Region", "IAM role", "Cost Explorer", "Spot Instance"]),
    q("Cloud Concepts", "Edge locations", "Which part of AWS global infrastructure helps deliver cached content closer to end users?", "edge locations", ["edge locations", "IAM groups", "Reserved Instances", "security groups"]),
    q("Cloud Concepts", "Fault tolerance", "A workload continues operating even when one component fails. Which design goal does this best represent?", "fault tolerance", ["fault tolerance", "single-AZ deployment", "manual scaling", "cost allocation tagging"]),
    q("Security and Compliance", "Shared responsibility", "Under the shared responsibility model, which responsibility belongs to AWS?", "security of the cloud, including physical facilities and managed infrastructure", ["security of the cloud, including physical facilities and managed infrastructure", "classifying customer data stored in S3", "creating least-privilege IAM policies for users", "configuring customer network access rules"]),
    q("Security and Compliance", "Customer responsibility", "A company stores customer records in Amazon S3. Which task is the customer's responsibility?", "controlling data access and configuration", ["controlling data access and configuration", "maintaining AWS physical data centers", "patching the underlying S3 storage fleet", "replacing failed AWS networking hardware"]),
    q("Security and Compliance", "IAM", "Which AWS service helps manage users, groups, roles, and permissions?", "AWS Identity and Access Management (IAM)", ["AWS Identity and Access Management (IAM)", "Amazon CloudFront", "AWS Pricing Calculator", "Amazon Route 53"]),
    q("Security and Compliance", "MFA", "Which security practice adds an extra sign-in factor beyond a password?", "multi-factor authentication (MFA)", ["multi-factor authentication (MFA)", "AWS Cost Explorer", "Amazon S3 lifecycle rules", "edge caching"]),
    q("Security and Compliance", "Least privilege", "An administrator grants only the permissions a user needs for a job. Which security principle is being applied?", "least privilege", ["least privilege", "public access by default", "unlimited root access", "single Availability Zone"]),
    q("Security and Compliance", "Compliance reports", "Which AWS service or resource provides access to AWS compliance reports?", "AWS Artifact", ["AWS Artifact", "Amazon EC2 Auto Scaling", "AWS Budgets", "Amazon DynamoDB"]),
    q("Security and Compliance", "Encryption keys", "Which AWS service helps create and manage encryption keys?", "AWS Key Management Service (KMS)", ["AWS Key Management Service (KMS)", "Amazon Route 53", "AWS Budgets", "Amazon CloudFront"]),
    q("Security and Compliance", "DDoS protection", "Which AWS service helps protect applications from DDoS attacks?", "AWS Shield", ["AWS Shield", "AWS Pricing Calculator", "Amazon EFS", "AWS Artifact"]),
    q("Security and Compliance", "Web application firewall", "Which service helps filter malicious web traffic using configurable rules?", "AWS WAF", ["AWS WAF", "Amazon RDS", "AWS Cost Explorer", "Amazon EBS"]),
    q("Security and Compliance", "Threat detection", "Which AWS service provides intelligent threat detection for AWS accounts and workloads?", "Amazon GuardDuty", ["Amazon GuardDuty", "AWS Budgets", "Amazon Route 53", "Amazon CloudFront"]),
    q("Cloud Technology and Services", "Serverless compute", "A team wants to run code without provisioning or managing servers. Which AWS service best fits?", "AWS Lambda", ["AWS Lambda", "Amazon EC2", "Amazon EBS", "Amazon VPC"]),
    q("Cloud Technology and Services", "Virtual servers", "Which AWS service provides resizable virtual servers?", "Amazon EC2", ["Amazon EC2", "Amazon S3", "AWS Artifact", "AWS Budgets"]),
    q("Cloud Technology and Services", "Object storage", "Which AWS service is designed for object storage?", "Amazon S3", ["Amazon S3", "Amazon EBS", "Amazon RDS", "Amazon VPC"]),
    q("Cloud Technology and Services", "Block storage", "Which AWS storage service provides block storage volumes for EC2 instances?", "Amazon EBS", ["Amazon EBS", "Amazon S3", "Amazon Route 53", "AWS Shield"]),
    q("Cloud Technology and Services", "File storage", "Which AWS service provides shared file storage that can be mounted by multiple compute resources?", "Amazon EFS", ["Amazon EFS", "AWS Lambda", "Amazon DynamoDB", "AWS Artifact"]),
    q("Cloud Technology and Services", "Relational database", "Which AWS service is a managed relational database service?", "Amazon RDS", ["Amazon RDS", "Amazon DynamoDB", "Amazon CloudFront", "AWS Shield"]),
    q("Cloud Technology and Services", "NoSQL database", "Which AWS database service is a managed NoSQL key-value and document database?", "Amazon DynamoDB", ["Amazon DynamoDB", "Amazon RDS", "Amazon EBS", "AWS Cost Explorer"]),
    q("Cloud Technology and Services", "Networking", "Which AWS service lets customers isolate cloud resources in a logically separated network?", "Amazon VPC", ["Amazon VPC", "Amazon CloudFront", "AWS Budgets", "AWS Artifact"]),
    q("Cloud Technology and Services", "DNS", "Which AWS service provides DNS routing and domain registration features?", "Amazon Route 53", ["Amazon Route 53", "AWS Lambda", "Amazon EBS", "AWS KMS"]),
    q("Cloud Technology and Services", "Content delivery", "Which AWS service is a content delivery network for caching content closer to users?", "Amazon CloudFront", ["Amazon CloudFront", "Amazon VPC", "AWS Cost Explorer", "AWS KMS"]),
    q("Cloud Technology and Services", "Monitoring", "Which AWS service collects metrics, logs, and alarms for AWS resources?", "Amazon CloudWatch", ["Amazon CloudWatch", "AWS Artifact", "Amazon S3 Glacier", "AWS Marketplace"]),
    q("Cloud Technology and Services", "Load balancing", "A web app needs to distribute incoming traffic across multiple targets. Which AWS service should be used?", "Elastic Load Balancing", ["Elastic Load Balancing", "AWS Artifact", "Amazon S3 Glacier", "AWS Pricing Calculator"]),
    q("Cloud Technology and Services", "Auto Scaling", "Which AWS capability adjusts compute capacity automatically based on demand?", "Auto Scaling", ["Auto Scaling", "AWS Artifact", "Amazon Route 53 registration only", "AWS Budgets"]),
    q("Cloud Technology and Services", "Message queues", "Which AWS service can decouple application components using message queues?", "Amazon SQS", ["Amazon SQS", "AWS Artifact", "Amazon EBS", "AWS Shield"]),
    q("Billing, Pricing, and Support", "Cost Explorer", "Which AWS tool helps monitor and visualize AWS spending over time?", "AWS Cost Explorer", ["AWS Cost Explorer", "Amazon Route 53", "AWS Lambda", "AWS Artifact"]),
    q("Billing, Pricing, and Support", "Budgets", "A learner wants alerts when AWS spend approaches a planned amount. Which tool should they use?", "AWS Budgets", ["AWS Budgets", "Amazon CloudWatch Logs only", "Amazon S3 Versioning", "AWS Shield Advanced"]),
    q("Billing, Pricing, and Support", "Pricing Calculator", "Before deploying a workload, a team wants to estimate monthly AWS costs. Which tool should they use?", "AWS Pricing Calculator", ["AWS Pricing Calculator", "AWS Artifact", "Amazon GuardDuty", "Amazon VPC"]),
    q("Billing, Pricing, and Support", "Savings Plans", "A company has steady compute usage and wants lower prices in exchange for a usage commitment. Which pricing option fits?", "Savings Plans", ["Savings Plans", "AWS Artifact reports", "MFA devices", "edge locations"]),
    q("Billing, Pricing, and Support", "Spot Instances", "A fault-tolerant batch job can be interrupted. Which EC2 purchasing option can provide the lowest cost?", "Spot Instances", ["Spot Instances", "Dedicated Hosts", "On-Demand Instances only", "AWS Support Enterprise"]),
    q("Billing, Pricing, and Support", "Trusted Advisor", "Which AWS service gives recommendations across cost optimization, security, fault tolerance, performance, and service limits?", "AWS Trusted Advisor", ["AWS Trusted Advisor", "Amazon DynamoDB", "AWS CloudFormation", "Amazon EFS"]),
    q("Billing, Pricing, and Support", "Support plans", "What do AWS Support plans vary by?", "response times and access levels", ["response times and access levels", "S3 bucket version counts", "EC2 instance operating systems", "Availability Zone names"]),
    q("Billing, Pricing, and Support", "Free Tier", "Which AWS program lets new customers try eligible services within usage limits at no additional charge?", "AWS Free Tier", ["AWS Free Tier", "AWS Shield Advanced", "Amazon Inspector", "AWS Organizations"])
  ];
}

function solutionsArchitectSeedQuestions() {
  const q = seedQuestion;
  return [
    q("Design Secure Architectures", "Least privilege", "An application needs temporary access to an S3 bucket from EC2 without storing long-term keys. What should the architect use?", "an IAM role attached to the EC2 instance", ["an IAM role attached to the EC2 instance", "an IAM user access key stored on the instance", "the AWS account root user credentials", "a public S3 bucket policy"]),
    q("Design Secure Architectures", "Private subnet egress", "Instances in a private subnet need outbound internet access for updates without accepting inbound internet traffic. Which component should be placed in a public subnet?", "NAT gateway", ["NAT gateway", "internet gateway attached directly to the private subnet", "AWS Direct Connect gateway only", "VPC peering connection"]),
    q("Design Secure Architectures", "KMS", "Which AWS service is commonly used to create and manage encryption keys for AWS resources?", "AWS Key Management Service (KMS)", ["AWS Key Management Service (KMS)", "Amazon Route 53", "AWS Cost Explorer", "Amazon CloudFront"]),
    q("Design Secure Architectures", "Security groups", "Which VPC control acts as a stateful firewall for EC2 instances?", "security group", ["security group", "network ACL only", "route table", "internet gateway"]),
    q("Design Secure Architectures", "Network ACLs", "Which VPC control is stateless and applies at the subnet boundary?", "network ACL", ["network ACL", "security group", "IAM role", "KMS key alias"]),
    q("Design Secure Architectures", "Secrets", "An application needs to rotate database credentials automatically. Which AWS service should be evaluated?", "AWS Secrets Manager", ["AWS Secrets Manager", "AWS Budgets", "Amazon CloudFront", "Amazon Athena"]),
    q("Design Secure Architectures", "Private service access", "Applications in private subnets need private connectivity to AWS services such as Secrets Manager. Which VPC feature should be used?", "an interface VPC endpoint", ["an interface VPC endpoint", "a public internet gateway only", "an S3 bucket notification", "an account alias"]),
    q("Design Secure Architectures", "S3 presigned URL", "A private S3 object must be downloadable by a user for a short time without making the bucket public. Which approach should be used?", "an Amazon S3 presigned URL", ["an Amazon S3 presigned URL", "an Amazon EC2 key pair", "an AWS CloudTrail lookup event", "an Amazon VPC route table"]),
    q("Design Secure Architectures", "SCP guardrails", "An organization wants to prevent member accounts from disabling CloudTrail, even if administrators have broad IAM permissions. Which control is most appropriate?", "an AWS Organizations service control policy", ["an AWS Organizations service control policy", "an S3 lifecycle policy", "an ELB target group", "a CloudFront cache policy"]),
    q("Design Secure Architectures", "TLS certificates", "A public Application Load Balancer needs an AWS-managed TLS certificate for HTTPS. Which service should provide the certificate?", "AWS Certificate Manager", ["AWS Certificate Manager", "AWS Cost Explorer", "Amazon S3 Inventory", "Amazon Kinesis Data Firehose"]),
    q("Design Secure Architectures", "Security findings", "A security team wants a centralized service to view and prioritize security findings from GuardDuty and Inspector. Which service should be used?", "AWS Security Hub", ["AWS Security Hub", "AWS Cost and Usage Report", "Amazon CloudFront Functions", "Amazon RDS Proxy"]),
    q("Design Secure Architectures", "KMS key policy", "A KMS key must be usable only by a specific application role and key administrators. Which policy type directly controls access to the key?", "a KMS key policy", ["a KMS key policy", "an Amazon SQS redrive policy", "a Route 53 routing policy", "an Amazon EFS lifecycle policy"]),
    q("Design Resilient Architectures", "Load balancing", "A web tier should distribute traffic across healthy instances in multiple Availability Zones. Which service fits?", "Elastic Load Balancing", ["Elastic Load Balancing", "AWS Budgets", "Amazon Athena", "AWS Artifact"]),
    q("Design Resilient Architectures", "Decoupling", "A workload needs to buffer messages between producers and consumers so failures in one layer do not stop the other. Which service is commonly used?", "Amazon SQS", ["Amazon SQS", "Amazon Route 53", "AWS Config", "Amazon EBS"]),
    q("Design Resilient Architectures", "Object durability", "Which storage service is designed for highly durable object storage across multiple facilities?", "Amazon S3", ["Amazon S3", "instance store", "single-AZ Amazon EBS only", "AWS CloudShell"]),
    q("Design Resilient Architectures", "Multi-AZ database", "A relational database needs automatic failover to another Availability Zone. Which RDS configuration should be used?", "Multi-AZ deployment", ["Multi-AZ deployment", "single-AZ deployment", "S3 Transfer Acceleration", "CloudFront signed cookies"]),
    q("Design Resilient Architectures", "S3 version recovery", "A company wants to recover previous object versions after accidental overwrites in Amazon S3. Which feature should be enabled?", "S3 Versioning", ["S3 Versioning", "Amazon Inspector", "AWS Budgets", "VPC Flow Logs"]),
    q("Design Resilient Architectures", "Auto Scaling replacement", "An application should replace unhealthy EC2 instances automatically. Which capability should be used?", "EC2 Auto Scaling health checks and replacement", ["EC2 Auto Scaling health checks and replacement", "AWS Artifact agreement download", "Route 53 domain registration only", "Cost Explorer forecasts"]),
    q("Design Resilient Architectures", "Fanout messaging", "A checkout service must publish events to multiple independent downstream services. Which AWS service is commonly used for fanout messaging?", "Amazon SNS", ["Amazon SNS", "Amazon EBS", "AWS CloudHSM", "Amazon RDS Proxy"]),
    q("Design Resilient Architectures", "Central backup", "A company needs centrally managed backup policies across AWS services and accounts. Which service should be used?", "AWS Backup", ["AWS Backup", "Amazon CloudFront", "AWS WAF", "Amazon Athena"]),
    q("Design Resilient Architectures", "Regional failover", "An application has endpoints in two Regions and should route around unhealthy endpoints. Which Route 53 feature is needed?", "health checks with failover routing", ["health checks with failover routing", "private DNS names only", "weighted records without health checks", "domain privacy protection"]),
    q("Design Resilient Architectures", "Event routing", "Several services need to react independently when an order status changes. Which event service can route events to multiple targets using rules?", "Amazon EventBridge", ["Amazon EventBridge", "Amazon EBS direct APIs", "AWS CloudHSM", "RDS Performance Insights"]),
    q("Design Resilient Architectures", "Aurora DR", "A business-critical Aurora database requires low recovery time in another Region. Which feature is designed for this pattern?", "Amazon Aurora Global Database", ["Amazon Aurora Global Database", "EBS Fast Snapshot Restore", "IAM Identity Center", "S3 Transfer Acceleration"]),
    q("Design Resilient Architectures", "Dead-letter queue", "Messages that fail processing repeatedly need to be isolated for later inspection without blocking the main queue. Which feature should be configured?", "an Amazon SQS dead-letter queue", ["an Amazon SQS dead-letter queue", "a CloudFront origin request policy", "an AWS KMS alias", "an EC2 placement group"]),
    q("Design High-Performing Architectures", "Caching", "A read-heavy application needs lower database latency for repeated queries. Which service can add an in-memory cache layer?", "Amazon ElastiCache", ["Amazon ElastiCache", "AWS Artifact", "AWS Pricing Calculator", "Amazon Glacier Flexible Retrieval"]),
    q("Design High-Performing Architectures", "Content delivery", "A global website needs static content cached close to viewers. Which AWS service is most appropriate?", "Amazon CloudFront", ["Amazon CloudFront", "AWS Organizations", "Amazon EBS", "AWS KMS"]),
    q("Design High-Performing Architectures", "Read scaling", "An application needs to scale read traffic for a relational database. Which feature can help?", "read replicas", ["read replicas", "root user access keys", "S3 lifecycle expiration", "AWS Support case severity"]),
    q("Design High-Performing Architectures", "Serverless burst", "A bursty event workload needs to run code without managing servers. Which service is best suited?", "AWS Lambda", ["AWS Lambda", "EC2 Dedicated Hosts only", "AWS Artifact", "AWS Budgets"]),
    q("Design High-Performing Architectures", "RDS connection pooling", "A Lambda application frequently opens connections to an RDS database and risks exhausting database connections. Which service helps manage connection pooling?", "Amazon RDS Proxy", ["Amazon RDS Proxy", "AWS Cost Explorer", "CloudFront Functions", "AWS Artifact"]),
    q("Design High-Performing Architectures", "DynamoDB latency", "An application requires single-digit millisecond performance at any scale for key-value data. Which database service is designed for this?", "Amazon DynamoDB", ["Amazon DynamoDB", "Amazon EFS", "AWS CloudTrail", "Amazon Route 53"]),
    q("Design High-Performing Architectures", "Global acceleration", "A latency-sensitive application needs static Anycast IP addresses and optimized routing to regional endpoints. Which service should be used?", "AWS Global Accelerator", ["AWS Global Accelerator", "AWS Budgets", "S3 Glacier Deep Archive", "IAM Access Analyzer"]),
    q("Design High-Performing Architectures", "Shared POSIX file system", "A Linux application running on several EC2 instances needs a shared POSIX file system. Which service should be selected?", "Amazon EFS", ["Amazon EFS", "S3 Glacier Flexible Retrieval", "AWS Secrets Manager", "Amazon EventBridge"]),
    q("Design High-Performing Architectures", "Data warehouse", "A company needs a managed petabyte-scale data warehouse for SQL analytics. Which AWS service is most appropriate?", "Amazon Redshift", ["Amazon Redshift", "Amazon Route 53", "AWS Shield", "Amazon SQS"]),
    q("Design High-Performing Architectures", "Streaming data", "An application must ingest and process streaming click events in near real time. Which service family is most appropriate?", "Amazon Kinesis", ["Amazon Kinesis", "AWS Pricing Calculator", "EBS Snapshots", "AWS CloudHSM"]),
    q("Design High-Performing Architectures", "Placement group", "A high-performance computing workload needs low-latency network performance between EC2 instances. Which placement strategy should be used?", "a cluster placement group", ["a cluster placement group", "a spread placement group for every instance", "an S3 access point", "a Cost Explorer report"]),
    q("Design High-Performing Architectures", "Provisioned Lambda", "A latency-sensitive Lambda function must reduce cold start impact for predictable traffic. Which feature should be configured?", "Lambda provisioned concurrency", ["Lambda provisioned concurrency", "Amazon S3 Versioning", "Organizations tag policies", "EBS encryption by default"]),
    q("Design Cost-Optimized Architectures", "Cost visibility", "Which AWS service helps analyze and visualize spending trends?", "AWS Cost Explorer", ["AWS Cost Explorer", "Amazon VPC", "Amazon CloudFront", "AWS Shield"]),
    q("Design Cost-Optimized Architectures", "Compute commitment", "A workload has steady compute usage across instance families and Regions. Which pricing model provides flexible savings for a usage commitment?", "Compute Savings Plans", ["Compute Savings Plans", "On-Demand Instances only", "AWS Free Tier alerts", "Route 53 latency routing"]),
    q("Design Cost-Optimized Architectures", "Storage class", "Objects are rarely accessed but require milliseconds retrieval when needed. Which S3 storage class can reduce cost while keeping immediate retrieval?", "S3 Standard-Infrequent Access", ["S3 Standard-Infrequent Access", "S3 Glacier Deep Archive", "EBS Provisioned IOPS only", "RDS Reserved Instances"]),
    q("Design Cost-Optimized Architectures", "Unknown access pattern", "A dataset has unknown and changing access patterns. Which S3 storage class automatically optimizes storage cost?", "S3 Intelligent-Tiering", ["S3 Intelligent-Tiering", "EC2 Spot Instances", "AWS Shield Advanced", "Route 53 Resolver"]),
    q("Design Cost-Optimized Architectures", "Idle resources", "Which AWS tool can recommend rightsizing and identify idle resources to reduce cost?", "AWS Compute Optimizer", ["AWS Compute Optimizer", "AWS CloudHSM", "Kinesis Data Streams", "Amazon Inspector"]),
    q("Design Cost-Optimized Architectures", "Cross-AZ transfer", "A workload frequently transfers large amounts of data between Availability Zones. What should the architect evaluate first?", "whether components can be placed to reduce cross-AZ data transfer", ["whether components can be placed to reduce cross-AZ data transfer", "whether to disable all encryption", "whether to move IAM users into S3", "whether to remove every load balancer"]),
    q("Design Cost-Optimized Architectures", "Cost allocation", "A finance team needs to attribute AWS costs to departments and projects. Which practice supports this?", "apply cost allocation tags", ["apply cost allocation tags", "disable AWS Budgets", "use one root user for all teams", "store logs only on instance store"]),
    q("Design Cost-Optimized Architectures", "Right-sizing", "A fleet of EC2 instances is consistently underutilized. Which action should be taken first for cost optimization?", "right-size or downsize the instances", ["right-size or downsize the instances", "move every instance to Dedicated Hosts", "disable all CloudWatch metrics", "store logs only on root volumes"]),
    q("Design Cost-Optimized Architectures", "S3 lifecycle", "Temporary objects must be deleted automatically after 30 days. Which feature should be configured?", "an S3 Lifecycle expiration rule", ["an S3 Lifecycle expiration rule", "an AWS Shield response team case", "an RDS read replica", "a Route 53 failover record"]),
    q("Design Cost-Optimized Architectures", "Spot fit", "Which workload is the best fit for Spot Instances?", "fault-tolerant batch processing that can be interrupted", ["fault-tolerant batch processing that can be interrupted", "a single database requiring no interruption", "a control plane that cannot restart", "a legacy license tied to one host"]),
    q("Design Cost-Optimized Architectures", "VPC endpoint cost", "A company pays NAT Gateway data processing charges for private subnet traffic to supported AWS services. Which design could reduce cost?", "use VPC endpoints for supported services", ["use VPC endpoints for supported services", "route all traffic through another NAT gateway", "disable security groups on instances", "copy all data to instance store"])
  ];
}

function solutionsArchitectSupplementalQuestions() {
  const q = seedQuestion;
  return [
    q("Design Secure Architectures", "IAM federation", "A company wants employees to sign in to AWS with corporate directory credentials instead of separate IAM users. Which service should be used?", "AWS IAM Identity Center", ["AWS IAM Identity Center", "AWS Artifact", "Amazon CloudFront", "AWS Cost Explorer"]),
    q("Design Secure Architectures", "Cross-account access", "A security account must read logs from multiple workload accounts without creating long-term access keys. What should be configured?", "cross-account IAM roles", ["cross-account IAM roles", "shared root user credentials", "public S3 buckets", "unrestricted security groups"]),
    q("Design Secure Architectures", "S3 public access", "A company must prevent accidental public exposure of S3 buckets across an account. Which feature should be enabled?", "S3 Block Public Access", ["S3 Block Public Access", "CloudFront standard logging", "EC2 user data", "RDS Performance Insights"]),
    q("Design Secure Architectures", "S3 encryption", "An S3 bucket must encrypt objects with customer managed keys and audit key usage. Which option fits best?", "SSE-KMS with a customer managed KMS key", ["SSE-KMS with a customer managed KMS key", "SSE-S3 with no KMS integration", "public read access", "instance store encryption"]),
    q("Design Secure Architectures", "Database encryption", "A new Amazon RDS database must be encrypted at rest. When should encryption be enabled?", "when the DB instance is created", ["when the DB instance is created", "only after deleting all snapshots", "only after enabling public access", "after disabling backups"]),
    q("Design Secure Architectures", "Secrets retrieval", "An ECS task needs to retrieve database credentials securely at runtime. Which service should store the credentials?", "AWS Secrets Manager", ["AWS Secrets Manager", "Amazon Route 53", "AWS Budgets", "Amazon CloudFront"]),
    q("Design Secure Architectures", "Private API access", "An internal application must expose an API only inside a VPC. Which API Gateway endpoint type should be used?", "private API endpoint", ["private API endpoint", "edge-optimized public endpoint", "public static website endpoint", "global accelerator endpoint"]),
    q("Design Secure Architectures", "WAF placement", "A public web application behind CloudFront needs protection from common SQL injection and cross-site scripting attempts. What should be added?", "AWS WAF web ACL", ["AWS WAF web ACL", "AWS Cost Explorer report", "RDS read replica", "S3 lifecycle rule"]),
    q("Design Secure Architectures", "VPC Flow Logs", "A team needs to inspect accepted and rejected IP traffic metadata for a VPC. Which feature should be enabled?", "VPC Flow Logs", ["VPC Flow Logs", "AWS Pricing Calculator", "Amazon EFS lifecycle", "S3 Transfer Acceleration"]),
    q("Design Secure Architectures", "Private S3 access", "EC2 instances in a private subnet need private access to Amazon S3 without using a NAT gateway. Which endpoint should be configured?", "gateway VPC endpoint for S3", ["gateway VPC endpoint for S3", "internet gateway on the private subnet", "EBS direct API endpoint", "Route 53 weighted record"]),
    q("Design Secure Architectures", "Mutual TLS", "A private application must verify client certificates before allowing API requests. Which feature can help?", "mutual TLS on API Gateway", ["mutual TLS on API Gateway", "AWS Budgets alerts", "S3 Intelligent-Tiering", "EC2 hibernation"]),
    q("Design Secure Architectures", "Centralized identity", "An organization needs centralized workforce access to multiple AWS accounts and cloud applications. Which service should be selected?", "AWS IAM Identity Center", ["AWS IAM Identity Center", "Amazon Kinesis", "AWS Batch", "Amazon EBS"]),
    q("Design Secure Architectures", "Key rotation", "A compliance requirement says encryption keys must rotate automatically each year. Which AWS feature supports this for KMS keys?", "automatic key rotation", ["automatic key rotation", "S3 Transfer Acceleration", "Route 53 latency routing", "EC2 placement groups"]),
    q("Design Secure Architectures", "Network segmentation", "A three-tier application should keep databases unreachable from the internet. Where should database subnets be placed?", "private subnets with no direct internet route", ["private subnets with no direct internet route", "public subnets with public IPs", "edge locations", "AWS Marketplace"]),
    q("Design Secure Architectures", "ALB authentication", "A web app behind an Application Load Balancer needs user authentication before forwarding requests. Which ALB feature helps?", "ALB authentication with an identity provider", ["ALB authentication with an identity provider", "S3 lifecycle transitions", "AWS Budgets actions", "EBS Fast Snapshot Restore"]),
    q("Design Secure Architectures", "Inspector", "A team wants automated vulnerability management for EC2 instances and container images. Which service should be used?", "Amazon Inspector", ["Amazon Inspector", "AWS Cost Explorer", "Amazon Route 53", "AWS Artifact"]),
    q("Design Secure Architectures", "Macie", "A security team must discover sensitive data such as personally identifiable information in S3 buckets. Which service should be used?", "Amazon Macie", ["Amazon Macie", "Amazon EFS", "AWS Compute Optimizer", "Amazon EventBridge Scheduler"]),
    q("Design Secure Architectures", "CloudTrail integrity", "A company wants evidence that CloudTrail log files were not modified after delivery. What should be enabled?", "CloudTrail log file validation", ["CloudTrail log file validation", "EC2 detailed monitoring", "S3 static website hosting", "RDS Proxy"]),
    q("Design Resilient Architectures", "Stateless web tier", "A web application needs to scale horizontally and replace instances freely. Where should session state be stored?", "an external store such as ElastiCache or DynamoDB", ["an external store such as ElastiCache or DynamoDB", "only on instance memory", "inside user data scripts", "in a local instance store volume"]),
    q("Design Resilient Architectures", "Multi-AZ ALB", "A public application load balancer must survive an Availability Zone impairment. What should the target architecture include?", "targets in multiple Availability Zones", ["targets in multiple Availability Zones", "one target in one subnet", "a single NAT gateway only", "one EBS volume shared across AZs"]),
    q("Design Resilient Architectures", "RDS backups", "A database must support point-in-time recovery after accidental data changes. Which RDS feature should be enabled?", "automated backups", ["automated backups", "public accessibility", "single-AZ only", "manual DNS records"]),
    q("Design Resilient Architectures", "S3 cross-region replication", "Objects in one Region must be copied automatically to another Region for disaster recovery. Which feature should be configured?", "S3 Cross-Region Replication", ["S3 Cross-Region Replication", "S3 Transfer Acceleration only", "EBS Multi-Attach", "CloudFront invalidations"]),
    q("Design Resilient Architectures", "DynamoDB global tables", "A DynamoDB application needs active-active low-latency access from two Regions. Which feature should be used?", "DynamoDB global tables", ["DynamoDB global tables", "single-region on-demand backups", "EBS snapshots", "Route 53 domain registration"]),
    q("Design Resilient Architectures", "SQS visibility timeout", "Messages are processed twice because workers need more time than the current queue setting. What should be adjusted?", "SQS visibility timeout", ["SQS visibility timeout", "S3 object lock", "EC2 tenancy", "CloudFront price class"]),
    q("Design Resilient Architectures", "Lambda retries", "A Lambda function asynchronously processes events and failed events need to be stored for review. What should be configured?", "a Lambda dead-letter queue or failure destination", ["a Lambda dead-letter queue or failure destination", "an internet gateway", "an RDS read replica", "an IAM password policy"]),
    q("Design Resilient Architectures", "EBS recovery", "An EC2-hosted application needs restore points for attached block volumes. Which mechanism should be used?", "EBS snapshots", ["EBS snapshots", "S3 bucket policies", "Route 53 resolver rules", "CloudFront functions"]),
    q("Design Resilient Architectures", "Auto Scaling AZ rebalance", "An Auto Scaling group should maintain capacity across Availability Zones when one zone has fewer healthy instances. Which capability helps?", "Availability Zone rebalancing", ["Availability Zone rebalancing", "S3 object tagging", "CloudTrail Insights", "IAM access key rotation"]),
    q("Design Resilient Architectures", "Aurora replicas", "An Aurora cluster needs high availability for reads and faster failover. What should be added?", "Aurora Replicas in multiple Availability Zones", ["Aurora Replicas in multiple Availability Zones", "single-AZ instance store", "one NAT gateway per account", "CloudFront signed URLs"]),
    q("Design Resilient Architectures", "Step Functions", "A workflow coordinates several Lambda tasks and needs retries, branching, and state tracking. Which service should orchestrate it?", "AWS Step Functions", ["AWS Step Functions", "AWS Budgets", "Amazon EBS", "Amazon Route 53"]),
    q("Design Resilient Architectures", "EventBridge replay", "An event-driven application needs to replay past events after a downstream outage. Which EventBridge feature can support this?", "EventBridge archive and replay", ["EventBridge archive and replay", "EC2 Dedicated Hosts", "AWS Artifact reports", "S3 static website hosting"]),
    q("Design Resilient Architectures", "Backup vault", "A company needs immutable backups protected from deletion during a ransomware event. Which AWS Backup feature helps?", "AWS Backup Vault Lock", ["AWS Backup Vault Lock", "CloudFront origin shield", "Route 53 simple routing", "EC2 user data"]),
    q("Design Resilient Architectures", "Route 53 health checks", "Users should be sent to a healthy regional endpoint if the primary endpoint fails. What should be configured?", "Route 53 failover routing with health checks", ["Route 53 failover routing with health checks", "one A record without health checks", "S3 event notifications", "IAM Identity Center"]),
    q("Design Resilient Architectures", "Queue buffering", "A sudden spike in orders should not overwhelm backend workers. Which design pattern helps absorb the spike?", "buffer requests in Amazon SQS", ["buffer requests in Amazon SQS", "store requests on EC2 instance memory", "disable Auto Scaling", "use one synchronous database transaction for all work"]),
    q("Design Resilient Architectures", "EFS availability", "A shared file system must be highly available across multiple Availability Zones. Which service is designed for this?", "Amazon EFS with regional storage", ["Amazon EFS with regional storage", "EC2 instance store", "single-AZ EBS volume", "AWS CloudShell home directory"]),
    q("Design High-Performing Architectures", "CloudFront dynamic acceleration", "A global application needs lower latency for both static and dynamic HTTP content. Which service should sit in front of the application?", "Amazon CloudFront", ["Amazon CloudFront", "AWS Budgets", "AWS Organizations", "Amazon EBS"]),
    q("Design High-Performing Architectures", "DynamoDB scaling", "An unpredictable key-value workload needs to scale capacity without manual throughput planning. Which DynamoDB mode fits?", "on-demand capacity mode", ["on-demand capacity mode", "single-AZ reserved capacity", "manual AMI rotation", "S3 One Zone-IA"]),
    q("Design High-Performing Architectures", "DAX", "A DynamoDB workload has microsecond read latency requirements for repeated reads. Which service can cache reads?", "DynamoDB Accelerator (DAX)", ["DynamoDB Accelerator (DAX)", "AWS Artifact", "Amazon S3 Glacier", "AWS Budgets"]),
    q("Design High-Performing Architectures", "Aurora read scaling", "A read-heavy Aurora application needs to offload read traffic from the writer. What should be added?", "Aurora read replicas", ["Aurora read replicas", "a single NAT gateway", "S3 Versioning", "IAM password policy"]),
    q("Design High-Performing Architectures", "S3 multipart upload", "A client uploads very large objects to Amazon S3 and wants better throughput and retry behavior. Which upload method should be used?", "multipart upload", ["multipart upload", "single PUT only", "Route 53 failover", "AWS Backup Vault Lock"]),
    q("Design High-Performing Architectures", "Transfer Acceleration", "Users far from the target Region need faster uploads to an S3 bucket. Which S3 feature can help?", "S3 Transfer Acceleration", ["S3 Transfer Acceleration", "S3 Object Lock", "RDS Proxy", "EC2 Auto Recovery"]),
    q("Design High-Performing Architectures", "Lambda concurrency", "A function must reserve capacity so other functions cannot consume all account concurrency. What should be configured?", "reserved concurrency", ["reserved concurrency", "S3 bucket versioning", "CloudFront geo restriction", "VPC flow logs"]),
    q("Design High-Performing Architectures", "ALB routing", "A microservices app needs to route requests to different target groups based on URL paths. Which load balancer supports this?", "Application Load Balancer", ["Application Load Balancer", "Network Load Balancer only", "Classic Load Balancer only", "AWS Global Accelerator only"]),
    q("Design High-Performing Architectures", "NLB use case", "A workload needs ultra-low-latency TCP traffic handling and static IP addresses per Availability Zone. Which load balancer fits?", "Network Load Balancer", ["Network Load Balancer", "Application Load Balancer", "AWS Budgets", "Amazon Macie"]),
    q("Design High-Performing Architectures", "Graviton", "A compute workload can run on ARM and needs better price performance. Which EC2 processor family should be evaluated?", "AWS Graviton", ["AWS Graviton", "AWS Artifact", "Amazon GuardDuty", "S3 Glacier Deep Archive"]),
    q("Design High-Performing Architectures", "EC2 Auto Scaling policy", "An application should add instances when average CPU remains high. Which feature should be configured?", "an EC2 Auto Scaling target tracking policy", ["an EC2 Auto Scaling target tracking policy", "an S3 lifecycle policy", "a KMS alias", "an AWS Budget report"]),
    q("Design High-Performing Architectures", "OpenSearch", "An application needs low-latency full-text search over product documents. Which AWS service should be selected?", "Amazon OpenSearch Service", ["Amazon OpenSearch Service", "AWS CloudTrail", "Amazon EBS", "AWS Config"]),
    q("Design High-Performing Architectures", "Athena", "Analysts need to query data in S3 using SQL without managing servers. Which service should be used?", "Amazon Athena", ["Amazon Athena", "Amazon Route 53", "AWS Shield", "Amazon EC2 Auto Scaling"]),
    q("Design High-Performing Architectures", "Kinesis shards", "A Kinesis Data Streams workload is throttled because records exceed stream capacity. What should be increased?", "the number of shards", ["the number of shards", "the IAM password length", "the S3 retention period", "the Route 53 TTL only"]),
    q("Design High-Performing Architectures", "EBS volume type", "A database on EC2 needs predictable high IOPS and low latency. Which EBS volume type should be considered?", "Provisioned IOPS SSD", ["Provisioned IOPS SSD", "Throughput Optimized HDD for boot volumes", "S3 Glacier Deep Archive", "EFS Infrequent Access only"]),
    q("Design Cost-Optimized Architectures", "Reserved Instances", "A database runs steadily for the next three years and uses a specific RDS engine and Region. Which purchase option can reduce cost?", "Reserved Instances", ["Reserved Instances", "Spot Instances", "On-Demand only", "AWS Free Tier"]),
    q("Design Cost-Optimized Architectures", "Savings Plans scope", "A fleet uses EC2, Lambda, and Fargate with steady usage. Which commitment model can reduce compute costs across these services?", "Compute Savings Plans", ["Compute Savings Plans", "S3 Intelligent-Tiering", "AWS Artifact", "Route 53 health checks"]),
    q("Design Cost-Optimized Architectures", "Spot architecture", "A batch job can retry failed work and tolerate interruption. Which compute option should be considered first?", "EC2 Spot Instances", ["EC2 Spot Instances", "EC2 Dedicated Hosts only", "RDS Multi-AZ", "AWS Shield Advanced"]),
    q("Design Cost-Optimized Architectures", "S3 lifecycle tiers", "Logs are accessed often for 30 days, rarely for a year, then retained for compliance. Which feature automates storage tier movement?", "S3 Lifecycle rules", ["S3 Lifecycle rules", "S3 Block Public Access", "CloudFront signed cookies", "IAM Identity Center"]),
    q("Design Cost-Optimized Architectures", "Intelligent-Tiering", "A data lake has objects with unpredictable access patterns and needs automatic storage cost optimization. Which S3 class should be used?", "S3 Intelligent-Tiering", ["S3 Intelligent-Tiering", "S3 Standard only", "EBS gp3", "RDS Multi-AZ"]),
    q("Design Cost-Optimized Architectures", "Compute Optimizer", "A workload is overprovisioned and the team wants machine-learning based rightsizing recommendations. Which service helps?", "AWS Compute Optimizer", ["AWS Compute Optimizer", "Amazon Macie", "Route 53 Resolver", "AWS Certificate Manager"]),
    q("Design Cost-Optimized Architectures", "Trusted Advisor cost", "A team wants recommendations for idle load balancers and underutilized resources. Which service provides cost optimization checks?", "AWS Trusted Advisor", ["AWS Trusted Advisor", "Amazon GuardDuty", "AWS WAF", "Amazon SQS"]),
    q("Design Cost-Optimized Architectures", "NAT cost", "Private subnet workloads send large traffic to S3 through a NAT gateway. Which change can reduce NAT data processing cost?", "use an S3 gateway VPC endpoint", ["use an S3 gateway VPC endpoint", "add another NAT gateway for the same traffic", "move all data to instance store", "disable route tables"]),
    q("Design Cost-Optimized Architectures", "CloudFront cost", "A global website repeatedly serves the same static assets from an S3 origin. Which service can reduce origin requests and improve performance?", "Amazon CloudFront", ["Amazon CloudFront", "AWS Organizations", "AWS Secrets Manager", "Amazon RDS Proxy"]),
    q("Design Cost-Optimized Architectures", "gp3 migration", "An EBS gp2 volume needs lower cost and separately configurable IOPS and throughput. Which volume type is often a better fit?", "EBS gp3", ["EBS gp3", "EBS st1 as a boot volume", "S3 Glacier Deep Archive", "EC2 instance store only"]),
    q("Design Cost-Optimized Architectures", "Idle scheduling", "Development EC2 instances are only needed during business hours. What is a cost-optimized approach?", "stop or schedule instances when not in use", ["stop or schedule instances when not in use", "run them 24/7 on On-Demand", "move them to Dedicated Hosts", "disable monitoring and leave them running"]),
    q("Design Cost-Optimized Architectures", "Data transfer", "A chatty application sends frequent cross-AZ traffic between tiers. What should be reviewed for cost optimization?", "placing tightly coupled components in the same Availability Zone when appropriate", ["placing tightly coupled components in the same Availability Zone when appropriate", "turning off all encryption", "using root credentials", "moving static files to RDS"]),
    q("Design Cost-Optimized Architectures", "Log retention", "CloudWatch Logs are retained forever but only needed for 90 days. What should be configured?", "log group retention settings", ["log group retention settings", "S3 static website hosting", "Route 53 latency routing", "EC2 key pairs"]),
    q("Design Cost-Optimized Architectures", "Serverless fit", "A low-traffic API has unpredictable bursts and long idle periods. Which compute model can avoid paying for idle servers?", "AWS Lambda", ["AWS Lambda", "always-on oversized EC2 instances", "Dedicated Hosts", "single-AZ RDS only"]),
    q("Design Cost-Optimized Architectures", "CUR analysis", "A company wants detailed AWS billing data delivered to S3 for analysis. Which billing feature should be configured?", "AWS Cost and Usage Report", ["AWS Cost and Usage Report", "AWS Shield", "Amazon EFS", "AWS Systems Manager Session Manager"])
  ];
}

function desiredQuestionCount(note) {
  if (isSolutionsArchitectNote(note)) return 128;
  if (isCloudPractitionerNote(note)) return 240;
  if (isCertificationNote(note)) return 120;
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
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);
  try {
    const response = await fetch(`${baseURL}/api/chat`, {
      method: "POST",
      headers,
      signal: controller.signal,
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
  } finally {
    clearTimeout(timeout);
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
