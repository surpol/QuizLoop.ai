import http from "node:http";
import { readFileSync, existsSync, mkdirSync, writeFileSync, renameSync, unlinkSync, copyFileSync } from "node:fs";
import { extname, join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";

const __dirname = dirname(fileURLToPath(import.meta.url));
const publicDir = join(__dirname, "public");
const dataDir = join(__dirname, "data");
const dbPath = process.env.ACCORDIAN_DB_PATH || join(dataDir, "accordian.sqlite");
const port = Number(process.env.PORT || 4173);
const host = process.env.HOST || "127.0.0.1";
const gemmaBaseURL = process.env.GEMMA_BASE_URL || "http://127.0.0.1:11434";
const gemmaModel = process.env.GEMMA_MODEL || "gemma4:e2b";
const expansionInFlight = new Set();
const initialBuildInFlight = new Set();

mkdirSync(dataDir, { recursive: true });
mkdirSync(dirname(dbPath), { recursive: true });

function sqlEscape(value) {
  return String(value ?? "").replaceAll("'", "''");
}

function sqlite(sql, { json = false } = {}) {
  const args = json ? ["-json", dbPath, sql] : [dbPath, sql];
  const result = spawnSync("sqlite3", args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(result.stderr || "SQLite query failed");
  }
  return json ? JSON.parse(result.stdout || "[]") : result.stdout;
}

function initDB() {
  sqlite(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS notes (
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      summary TEXT NOT NULL DEFAULT '',
      source_type TEXT NOT NULL DEFAULT 'text',
      status TEXT NOT NULL DEFAULT 'new',
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS topics (
      id TEXT PRIMARY KEY NOT NULL,
      note_id TEXT NOT NULL,
      title TEXT NOT NULL,
      summary TEXT NOT NULL DEFAULT '',
      importance REAL NOT NULL DEFAULT 1,
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS concepts (
      id TEXT PRIMARY KEY NOT NULL,
      note_id TEXT NOT NULL,
      topic_id TEXT,
      title TEXT NOT NULL,
      source_excerpt TEXT NOT NULL DEFAULT '',
      importance REAL NOT NULL DEFAULT 1,
      difficulty REAL NOT NULL DEFAULT 1,
      understanding_score REAL NOT NULL DEFAULT 0,
      mastery_state TEXT NOT NULL DEFAULT 'new',
      last_tested_at REAL,
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS learning_segments (
      id TEXT PRIMARY KEY NOT NULL,
      note_id TEXT NOT NULL,
      topic_id TEXT,
      topic_title TEXT NOT NULL,
      subtopic_title TEXT NOT NULL,
      text TEXT NOT NULL,
      evidence TEXT NOT NULL DEFAULT '',
      importance REAL NOT NULL DEFAULT 1,
      difficulty REAL NOT NULL DEFAULT 1,
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS book_sections (
      id TEXT PRIMARY KEY NOT NULL,
      note_id TEXT NOT NULL,
      section_index INTEGER NOT NULL,
      title TEXT NOT NULL,
      text TEXT NOT NULL,
      word_count INTEGER NOT NULL DEFAULT 0,
      summary TEXT NOT NULL DEFAULT '',
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS questions (
      id TEXT PRIMARY KEY NOT NULL,
      note_id TEXT NOT NULL,
      topic_id TEXT,
      segment_id TEXT,
      concept_id TEXT,
      topic TEXT NOT NULL,
      subtopic TEXT NOT NULL,
      assessment_angle TEXT NOT NULL DEFAULT 'recall',
      concept_signature TEXT NOT NULL DEFAULT '',
      generation_source TEXT NOT NULL DEFAULT 'initial',
      prompt TEXT NOT NULL,
      answer TEXT NOT NULL,
      choices TEXT NOT NULL,
      importance REAL NOT NULL DEFAULT 1,
      difficulty REAL NOT NULL DEFAULT 1,
      understanding_score REAL NOT NULL DEFAULT 0,
      mastery_state TEXT NOT NULL DEFAULT 'new',
      last_seen_at REAL,
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS question_variants (
      id TEXT PRIMARY KEY NOT NULL,
      question_id TEXT NOT NULL,
      note_id TEXT NOT NULL,
      delivery_type TEXT NOT NULL,
      prompt TEXT NOT NULL,
      answer TEXT NOT NULL,
      choices TEXT NOT NULL DEFAULT '[]',
      rubric TEXT NOT NULL DEFAULT '',
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS attempts (
      id TEXT PRIMARY KEY NOT NULL,
      question_id TEXT NOT NULL,
      variant_id TEXT NOT NULL DEFAULT '',
      note_id TEXT NOT NULL,
      topic_snapshot TEXT NOT NULL DEFAULT '',
      subtopic_snapshot TEXT NOT NULL DEFAULT '',
      prompt_snapshot TEXT NOT NULL DEFAULT '',
      answer_snapshot TEXT NOT NULL DEFAULT '',
      response TEXT NOT NULL,
      score REAL NOT NULL,
      feedback TEXT NOT NULL DEFAULT '',
      matched_ideas TEXT NOT NULL DEFAULT '[]',
      missing_ideas TEXT NOT NULL DEFAULT '[]',
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS quiz_sessions (
      id TEXT PRIMARY KEY NOT NULL,
      note_id TEXT NOT NULL,
      score REAL NOT NULL,
      attempt_ids TEXT NOT NULL,
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS journey_assignments (
      id TEXT PRIMARY KEY NOT NULL,
      note_id TEXT NOT NULL,
      segment_id TEXT,
      question_id TEXT,
      type TEXT NOT NULL DEFAULT 'quiz',
      reason TEXT NOT NULL DEFAULT '',
      priority REAL NOT NULL DEFAULT 1,
      due_at REAL NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      created_at REAL NOT NULL,
      completed_at REAL
    );
    CREATE TABLE IF NOT EXISTS concept_memory (
      note_id TEXT NOT NULL,
      concept_signature TEXT NOT NULL,
      topic TEXT NOT NULL,
      subtopic TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      average_score REAL NOT NULL DEFAULT 0,
      latest_score REAL NOT NULL DEFAULT 0,
      last_seen REAL NOT NULL DEFAULT 0,
      PRIMARY KEY (note_id, concept_signature)
    );
    CREATE TABLE IF NOT EXISTS learning_memory (
      question_id TEXT PRIMARY KEY NOT NULL,
      concept_id TEXT,
      note_id TEXT NOT NULL,
      latest_score REAL NOT NULL DEFAULT 0,
      average_score REAL NOT NULL DEFAULT 0,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      multiple_choice_score REAL NOT NULL DEFAULT 0,
      short_answer_score REAL NOT NULL DEFAULT 0,
      delivery_variety INTEGER NOT NULL DEFAULT 0,
      weakness_reason TEXT NOT NULL DEFAULT '',
      next_due_at REAL,
      mastery_state TEXT NOT NULL DEFAULT 'new',
      updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS quiz_memory (
      id TEXT PRIMARY KEY NOT NULL,
      quiz_id TEXT,
      note_id TEXT NOT NULL,
      title TEXT NOT NULL DEFAULT '',
      selected_focus TEXT,
      reason TEXT NOT NULL DEFAULT '',
      target_concepts TEXT NOT NULL DEFAULT '[]',
      avoided_concepts TEXT NOT NULL DEFAULT '[]',
      question_mix TEXT NOT NULL DEFAULT '{}',
      model_name TEXT NOT NULL DEFAULT '',
      prompt_version TEXT NOT NULL DEFAULT '',
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS quiz_queue (
      id TEXT PRIMARY KEY NOT NULL,
      note_id TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'ready',
      reason TEXT NOT NULL DEFAULT '',
      question_ids TEXT NOT NULL DEFAULT '[]',
      summary TEXT NOT NULL DEFAULT '',
      target_concepts TEXT NOT NULL DEFAULT '[]',
      avoided_concepts TEXT NOT NULL DEFAULT '[]',
      created_at REAL NOT NULL,
      consumed_at REAL
    );
    CREATE TABLE IF NOT EXISTS answer_evaluations (
      id TEXT PRIMARY KEY NOT NULL,
      attempt_id TEXT NOT NULL,
      question_id TEXT NOT NULL,
      note_id TEXT NOT NULL,
      score REAL NOT NULL,
      verdict TEXT NOT NULL DEFAULT '',
      matched_ideas TEXT NOT NULL DEFAULT '[]',
      missing_ideas TEXT NOT NULL DEFAULT '[]',
      model_name TEXT NOT NULL DEFAULT '',
      prompt_version TEXT NOT NULL DEFAULT '',
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS model_runs (
      id TEXT PRIMARY KEY NOT NULL,
      note_id TEXT,
      task TEXT NOT NULL,
      prompt_version TEXT NOT NULL,
      status TEXT NOT NULL,
      detail TEXT NOT NULL DEFAULT '',
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS user_actions (
      id TEXT PRIMARY KEY NOT NULL,
      note_id TEXT,
      action_type TEXT NOT NULL,
      object_type TEXT NOT NULL DEFAULT '',
      object_id TEXT NOT NULL DEFAULT '',
      payload TEXT NOT NULL DEFAULT '{}',
      created_at REAL NOT NULL
    );
  `);
  ensureColumns("notes", [
    ["source_type", "TEXT NOT NULL DEFAULT 'text'"]
  ]);
  ensureColumns("attempts", [
    ["variant_id", "TEXT NOT NULL DEFAULT ''"],
    ["topic_snapshot", "TEXT NOT NULL DEFAULT ''"],
    ["subtopic_snapshot", "TEXT NOT NULL DEFAULT ''"],
    ["prompt_snapshot", "TEXT NOT NULL DEFAULT ''"],
    ["answer_snapshot", "TEXT NOT NULL DEFAULT ''"],
    ["matched_ideas", "TEXT NOT NULL DEFAULT '[]'"],
    ["missing_ideas", "TEXT NOT NULL DEFAULT '[]'"]
  ]);
  ensureColumns("questions", [
    ["topic_id", "TEXT"],
    ["segment_id", "TEXT"],
    ["concept_id", "TEXT"],
    ["assessment_angle", "TEXT NOT NULL DEFAULT 'recall'"],
    ["concept_signature", "TEXT NOT NULL DEFAULT ''"],
    ["generation_source", "TEXT NOT NULL DEFAULT 'initial'"],
    ["understanding_score", "REAL NOT NULL DEFAULT 0"],
    ["mastery_state", "TEXT NOT NULL DEFAULT 'new'"],
    ["last_seen_at", "REAL"]
  ]);
  ensureColumns("user_actions", [
    ["note_id", "TEXT"],
    ["object_type", "TEXT NOT NULL DEFAULT ''"],
    ["object_id", "TEXT NOT NULL DEFAULT ''"],
    ["payload", "TEXT NOT NULL DEFAULT '{}'"]
  ]);
  ensureColumns("quiz_queue", [
    ["state", "TEXT NOT NULL DEFAULT 'ready'"],
    ["reason", "TEXT NOT NULL DEFAULT ''"],
    ["question_ids", "TEXT NOT NULL DEFAULT '[]'"],
    ["summary", "TEXT NOT NULL DEFAULT ''"],
    ["target_concepts", "TEXT NOT NULL DEFAULT '[]'"],
    ["avoided_concepts", "TEXT NOT NULL DEFAULT '[]'"],
    ["consumed_at", "REAL"]
  ]);

  sqlite(`
    UPDATE notes
    SET status = CASE
      WHEN (SELECT COUNT(*) FROM questions WHERE questions.note_id = notes.id) > 0 THEN 'ready'
      ELSE 'new'
    END
    WHERE status = 'building';
  `);
}

initDB();

function ensureColumns(tableName, additions) {
  const columns = sqlite(`PRAGMA table_info(${tableName});`, { json: true }).map((column) => column.name);
  for (const [name, definition] of additions) {
    if (!columns.includes(name)) {
      sqlite(`ALTER TABLE ${tableName} ADD COLUMN ${name} ${definition};`);
    }
  }
}

function noteSummary(noteId) {
  const rows = sqlite(`
    SELECT
      n.id,
      n.title,
      n.body,
      n.summary,
      n.source_type,
      n.status,
      n.created_at,
      COUNT(DISTINCT bs.id) AS section_count,
      COUNT(DISTINCT q.id) AS question_count,
      COUNT(DISTINCT qq.id) AS queued_quiz_count,
      COUNT(DISTINCT a.id) AS attempt_count,
      COALESCE(NULLIF(AVG(q.understanding_score), 0), AVG(a.score), 0) AS average_score
    FROM notes n
    LEFT JOIN book_sections bs ON bs.note_id = n.id
    LEFT JOIN questions q ON q.note_id = n.id
    LEFT JOIN quiz_queue qq ON qq.note_id = n.id AND qq.state = 'ready'
    LEFT JOIN attempts a ON a.note_id = n.id
    WHERE n.id = '${sqlEscape(noteId)}'
    GROUP BY n.id
  `, { json: true })[0];
  return rows ? normalizeNote(rows) : null;
}

function normalizeNote(row) {
  return {
    id: row.id,
    title: row.title,
    body: row.body,
    summary: row.summary || "",
    sourceType: row.source_type || "text",
    status: row.status,
    createdAt: row.created_at,
    sectionCount: Number(row.section_count || 0),
    questionCount: Number(row.question_count || 0),
    queuedQuizCount: Number(row.queued_quiz_count || 0),
    attemptCount: Number(row.attempt_count || 0),
    averageScore: Number(row.average_score || 0)
  };
}

function listNotes() {
  ensureAutomaticQueues();
  return sqlite(`
    SELECT
      n.id,
      n.title,
      n.body,
      n.summary,
      n.source_type,
      n.status,
      n.created_at,
      COUNT(DISTINCT bs.id) AS section_count,
      COUNT(DISTINCT q.id) AS question_count,
      COUNT(DISTINCT qq.id) AS queued_quiz_count,
      COUNT(DISTINCT a.id) AS attempt_count,
      COALESCE(NULLIF(AVG(q.understanding_score), 0), AVG(a.score), 0) AS average_score
    FROM notes n
    LEFT JOIN book_sections bs ON bs.note_id = n.id
    LEFT JOIN questions q ON q.note_id = n.id
    LEFT JOIN quiz_queue qq ON qq.note_id = n.id AND qq.state = 'ready'
    LEFT JOIN attempts a ON a.note_id = n.id
    GROUP BY n.id
    ORDER BY n.created_at DESC
  `, { json: true }).map(normalizeNote);
}

async function readJSON(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString("utf8");
  return text ? JSON.parse(text) : {};
}

async function readRequestBuffer(request, maxBytes = 50 * 1024 * 1024) {
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > maxBytes) {
      throw new Error("Backup file is too large.");
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

function writeJSON(response, status, payload) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(payload));
}

function exportBackup(response) {
  sqlite("PRAGMA wal_checkpoint(TRUNCATE);");
  const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-");
  response.writeHead(200, {
    "content-type": "application/octet-stream",
    "content-disposition": `attachment; filename="accordian-backup-${stamp}.sqlite"`
  });
  response.end(readFileSync(dbPath));
}

async function restoreBackup(request) {
  const buffer = await readRequestBuffer(request);
  if (buffer.length < 100 || buffer.slice(0, 16).toString("utf8") !== "SQLite format 3\u0000") {
    throw new Error("This is not a valid Accordian backup file.");
  }

  const tempPath = join(dataDir, `restore-${crypto.randomUUID()}.sqlite`);
  const oldPath = join(dataDir, `before-restore-${Date.now()}.sqlite`);
  writeFileSync(tempPath, buffer);
  try {
    const check = spawnSync("sqlite3", [tempPath, "PRAGMA integrity_check;"], { encoding: "utf8" });
    if (check.status !== 0 || !String(check.stdout || "").includes("ok")) {
      throw new Error("Backup integrity check failed.");
    }
    if (existsSync(dbPath)) copyFileSync(dbPath, oldPath);
    renameSync(tempPath, dbPath);
    initDB();
    return { ok: true, notes: listNotes() };
  } catch (error) {
    if (existsSync(tempPath)) unlinkSync(tempPath);
    throw error;
  }
}

async function wikipediaJSON(params) {
  const url = new URL("https://en.wikipedia.org/w/api.php");
  url.searchParams.set("format", "json");
  url.searchParams.set("formatversion", "2");
  for (const [key, value] of Object.entries(params)) {
    url.searchParams.set(key, value);
  }

  const response = await fetch(url, {
    headers: {
      "user-agent": "AccordianLearningDemo/1.0 (local Kaggle demo)"
    }
  });
  if (!response.ok) {
    throw new Error(`Wikipedia request failed: ${response.status}`);
  }
  return response.json();
}

async function searchWikipedia(query) {
  const payload = await wikipediaJSON({
    action: "query",
    list: "search",
    srsearch: query,
    srlimit: "8",
    srprop: "snippet"
  });

  return (payload.query?.search || []).map((item) => ({
    title: item.title,
    pageId: item.pageid,
    snippet: String(item.snippet || "").replace(/<[^>]*>/g, "")
  }));
}

async function wikipediaArticle(title) {
  const payload = await wikipediaJSON({
    action: "query",
    prop: "extracts",
    exintro: "0",
    explaintext: "1",
    redirects: "1",
    titles: title
  });

  const page = payload.query?.pages?.find((candidate) => candidate.missing !== true);
  if (!page?.extract) {
    throw new Error("Wikipedia article text was not available.");
  }

  return {
    title: page.title || title,
    text: page.extract
      .replace(/\n{3,}/g, "\n\n")
      .trim()
  };
}

function isBookSourceType(sourceType) {
  return String(sourceType || "").toLowerCase() === "books";
}

function wordCount(text) {
  return String(text || "").trim().split(/\s+/).filter(Boolean).length;
}

function splitBookIntoSections(text) {
  const clean = String(text || "").replace(/\r/g, "").trim();
  if (!clean) return [];
  const headingParts = clean
    .split(/\n(?=(?:chapter|part|book|section)\s+[\divxlcdm]+[\s:.-])/i)
    .map((part) => part.trim())
    .filter((part) => wordCount(part) >= 80);
  const sourceParts = headingParts.length >= 2 ? headingParts : [clean];
  const sections = [];
  for (const part of sourceParts) {
    const words = part.split(/\s+/).filter(Boolean);
    const heading = part.split("\n").find((line) => line.trim().length > 0)?.trim() || "";
    for (let index = 0; index < words.length; index += 950) {
      const slice = words.slice(index, index + 1100).join(" ");
      if (wordCount(slice) < 60) continue;
      sections.push({
        title: heading && index === 0 ? heading.slice(0, 120) : `Section ${sections.length + 1}`,
        text: slice,
        wordCount: wordCount(slice)
      });
    }
  }
  return sections.length ? sections : [{ title: "Section 1", text: clean, wordCount: wordCount(clean) }];
}

function storeBookSections(noteId, text) {
  sqlite(`DELETE FROM book_sections WHERE note_id = '${sqlEscape(noteId)}';`);
  const sections = splitBookIntoSections(text);
  sections.forEach((section, index) => {
    sqlite(`
      INSERT INTO book_sections (
        id, note_id, section_index, title, text, word_count, created_at
      ) VALUES (
        '${crypto.randomUUID()}',
        '${sqlEscape(noteId)}',
        ${index},
        '${sqlEscape(section.title)}',
        '${sqlEscape(section.text)}',
        ${Number(section.wordCount || 0)},
        ${Date.now() / 1000}
      );
    `);
  });
  return sections.length;
}

function bookStudyText(noteId, limit = 4200) {
  const sections = sqlite(`
    SELECT section_index, title, text
    FROM book_sections
    WHERE note_id = '${sqlEscape(noteId)}'
    ORDER BY section_index ASC
    LIMIT 4
  `, { json: true });
  const joined = sections.map((section) => (
    `## ${section.title || `Section ${Number(section.section_index || 0) + 1}`}\n${section.text || ""}`
  )).join("\n\n");
  return joined.slice(0, limit);
}

function sourceTextForGeneration(note, limit = 3000) {
  if (isBookSourceType(note?.sourceType || note?.source_type)) {
    const text = bookStudyText(note.id, limit);
    if (text.trim()) return text;
  }
  return String(note?.body || "").slice(0, limit);
}

function createNote(title, text, sourceType = "text") {
  const id = crypto.randomUUID();
  const cleanSourceType = isBookSourceType(sourceType) ? "books" : String(sourceType || "text").slice(0, 40);
  sqlite(`
    INSERT INTO notes (id, title, body, source_type, status, created_at)
    VALUES ('${id}', '${sqlEscape(title)}', '${sqlEscape(text)}', '${sqlEscape(cleanSourceType)}', 'new', ${Date.now() / 1000});
  `);
  const sectionCount = isBookSourceType(cleanSourceType) ? storeBookSections(id, text) : 0;
  recordUserAction({
    noteId: id,
    actionType: "note.created",
    objectType: "note",
    objectId: id,
    payload: { title, sourceType: cleanSourceType, wordCount: wordCount(text), sectionCount }
  });
  return noteSummary(id);
}

function updateNote(noteId, title, text, sourceType = "text") {
  const note = noteSummary(noteId);
  if (!note) return null;
  const cleanSourceType = isBookSourceType(sourceType) ? "books" : String(sourceType || note.sourceType || "text").slice(0, 40);
  sqlite(`
    UPDATE notes
    SET title = '${sqlEscape(title)}',
        body = '${sqlEscape(text)}',
        source_type = '${sqlEscape(cleanSourceType)}',
        summary = '',
        status = 'new'
    WHERE id = '${sqlEscape(noteId)}';

    DELETE FROM quiz_queue WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM question_variants WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM answer_evaluations WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM attempts WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM quiz_sessions WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM quiz_memory WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM learning_memory WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM concept_memory WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM questions WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM concepts WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM learning_segments WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM book_sections WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM journey_assignments WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM topics WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM model_runs WHERE note_id = '${sqlEscape(noteId)}';
  `);
  const sectionCount = isBookSourceType(cleanSourceType) ? storeBookSections(noteId, text) : 0;
  recordUserAction({
    noteId,
    actionType: "note.updated",
    objectType: "note",
    objectId: noteId,
    payload: { title, sourceType: cleanSourceType, wordCount: wordCount(text), sectionCount }
  });
  return noteSummary(noteId);
}

function recordUserAction({ noteId = null, actionType, objectType = "", objectId = "", payload = {} }) {
  sqlite(`
    INSERT INTO user_actions (
      id, note_id, action_type, object_type, object_id, payload, created_at
    ) VALUES (
      '${crypto.randomUUID()}',
      ${noteId ? `'${sqlEscape(noteId)}'` : "NULL"},
      '${sqlEscape(actionType)}',
      '${sqlEscape(objectType)}',
      '${sqlEscape(objectId)}',
      '${sqlEscape(JSON.stringify(payload || {}))}',
      ${Date.now() / 1000}
    );
  `);
}

function normalizeText(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function compactConceptText(value) {
  return normalizeText(value)
    .replace(/\b(what|which|how|why|does|do|is|are|the|a|an|in|of|for|to|from|with|and|or|its|their|this|that|kind|type|role|function|relationship|mechanism|principle|application|context|defined|contribute|allow|allows|class|classes)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function conceptFamilyFromText(...values) {
  const text = normalizeText(values.join(" "));
  if (text.includes("inheritance") && text.includes("interface")) return "inheritance-interfaces";
  if (text.includes("object") && text.includes("class")) return "object-class";
  if (text.includes("inheritance") || text.includes("reuse behavior")) return "inheritance";
  if (text.includes("interface") || text.includes("capabilities") || text.includes("implement")) return "interfaces";
  if (text.includes("bytecode") || text.includes("jvm") || text.includes("platform")) return "jvm-bytecode";
  if (text.includes("class based") || text.includes("programming language")) return "java-language-type";
  if (text.includes("encapsulation") || (text.includes("data") && text.includes("behavior"))) return "encapsulation";
  return "";
}

function canonicalConceptKey(question) {
  const prompt = question.canonical_prompt || question.prompt || question.variant_prompt || "";
  const concept = question.concept || question.subtopic || question.subtopic_title || "";
  const excerpt = question.source_excerpt || question.sourceExcerpt || "";
  const answer = question.canonical_answer || question.answer || question.variant_answer || "";
  const family = conceptFamilyFromText(concept, prompt, answer, excerpt);
  const conceptStem = compactConceptText(concept || prompt).split(" ").slice(0, 7).join(" ");
  const answerStem = compactConceptText(answer).split(" ").slice(0, 8).join(" ");
  return [family || conceptStem || answerStem, answerStem].filter(Boolean).join(":").slice(0, 180);
}

function conceptRootKey(question) {
  const key = canonicalConceptKey(question);
  const answerRoot = compactConceptText(question.canonical_answer || question.answer || question.variant_answer || "")
    .split(" ")
    .slice(0, 7)
    .join(" ");
  const conceptRoot = key.split(":")[0] || "";
  return (answerRoot || conceptRoot || key).slice(0, 140);
}

function answerMemoryKey(question) {
  return compactConceptText(question.canonical_answer || question.answer || question.variant_answer || "")
    .split(" ")
    .slice(0, 10)
    .join(" ");
}

function tokenSet(value) {
  return new Set(compactConceptText(value).split(" ").filter((token) => token.length > 1));
}

function answerKeysOverlap(left, right) {
  const leftTokens = tokenSet(left);
  const rightTokens = tokenSet(right);
  if (leftTokens.size === 0 || rightTokens.size === 0) return false;
  let overlap = 0;
  for (const token of leftTokens) {
    if (rightTokens.has(token)) overlap += 1;
  }
  return overlap / Math.min(leftTokens.size, rightTokens.size) >= 0.8;
}

function tokenOverlapRatio(left, right) {
  const leftTokens = tokenSet(left);
  const rightTokens = tokenSet(right);
  if (leftTokens.size === 0 || rightTokens.size === 0) return 0;
  let overlap = 0;
  for (const token of leftTokens) {
    if (rightTokens.has(token)) overlap += 1;
  }
  return overlap / Math.min(leftTokens.size, rightTokens.size);
}

function answerKeyOverlapsAny(answerKey, otherKeys) {
  return [...otherKeys].some((otherKey) => answerKeysOverlap(answerKey, otherKey));
}

function conceptSignature(question) {
  return canonicalConceptKey(question) || crypto.randomUUID();
}

function promptFingerprint(prompt) {
  return normalizeText(prompt).slice(0, 260);
}

function quizLegitimacyKey(row) {
  const answer = answerMemoryKey(row);
  const angle = normalizeText(row.assessment_angle || "recall");
  return [canonicalConceptKey(row), angle, answer]
    .filter(Boolean)
    .join(":")
    .slice(0, 180);
}

function shuffled(values) {
  return [...values].sort(() => Math.random() - 0.5);
}

function recordModelRun({ noteId, task, promptVersion, status, detail = "" }) {
  sqlite(`
    INSERT INTO model_runs (id, note_id, task, prompt_version, status, detail, created_at)
    VALUES (
      '${crypto.randomUUID()}',
      ${noteId ? `'${sqlEscape(noteId)}'` : "NULL"},
      '${sqlEscape(task)}',
      '${sqlEscape(promptVersion)}',
      '${sqlEscape(status)}',
      '${sqlEscape(detail)}',
      ${Date.now() / 1000}
    );
  `);
}

function parseJSONFromModelText(content) {
  const cleaned = content
    .replace(/```json/gi, "```")
    .replace(/```/g, "")
    .trim();
  const start = cleaned.indexOf("{");
  const end = cleaned.lastIndexOf("}");
  if (start === -1 || end === -1) {
    throw new Error("Gemma did not return JSON.");
  }
  return JSON.parse(cleaned.slice(start, end + 1));
}

async function gemmaText(prompt, timeoutMs = 120000, options = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const response = await fetch(`${gemmaBaseURL}/api/chat`, {
    method: "POST",
    signal: controller.signal,
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: gemmaModel,
      stream: false,
      think: false,
      ...(options.format ? { format: options.format } : {}),
      messages: [
        {
          role: "user",
          content: prompt
        }
      ]
    })
  });
  clearTimeout(timeout);
  if (!response.ok) {
    throw new Error(`Gemma request failed: ${response.status}`);
  }

  const payload = await response.json();
  return payload.message?.content || "";
}

async function gemmaJSON(prompt, timeoutMs = 120000) {
  const content = await gemmaText(prompt, timeoutMs, { format: "json" });
  try {
    return parseJSONFromModelText(content);
  } catch (error) {
    const repaired = await gemmaText(`
Repair this into valid JSON only.
Do not add commentary.
Preserve all fields and arrays that are already present.
If an item is malformed, fix commas/brackets/quotes rather than deleting the whole item.

BROKEN_JSON_TEXT:
${content}
`, 60000, { format: "json" });
    try {
      return parseJSONFromModelText(repaired);
    } catch {
      throw error;
    }
  }
}

function noteShapePromptFor({ title, body, sourceType }) {
  const cleanTitle = String(title || "Untitled Note").slice(0, 180);
  const cleanSourceType = String(sourceType || "text").slice(0, 40);
  const text = String(body || "").slice(0, 12000);
  const modeGuidance = isBookSourceType(cleanSourceType)
    ? `Book notes should be organized into: Book or source, passage/chapter, source text, key ideas, evidence, and what the learner wants to understand. If this is a long pasted book, preserve the source text and add structure around it.`
    : cleanSourceType === "math"
      ? `Math notes should be organized into: concept, formulas/rules, worked example, common mistakes, and practice goals. Keep formulas readable as plain text.`
      : `General notes should be organized into: source text, key ideas, important facts, relationships, and what the learner should be able to explain.`;

  return `
You are shaping a student's raw note so Accordian.ai can create better quizzes from it.
Use ONLY the text provided. Do not add outside facts.
Preserve the user's meaning and important source wording.
Make the note clearer, more structured, and easier to quiz.
If the pasted text is already good, keep it mostly intact and add light headings.
Return valid JSON only.

SOURCE_TYPE: ${cleanSourceType}
TITLE: ${cleanTitle}

MODE_GUIDANCE:
${modeGuidance}

Return this exact JSON shape:
{
  "title": "short improved title",
  "body": "improved note text with headings",
  "feedback": ["short note about what improved", "short note about what would make quizzes better"]
}

RAW_NOTE:
${text}
`;
}

async function shapeNoteDraft({ title, body, sourceType }) {
  const result = await gemmaJSON(noteShapePromptFor({ title, body, sourceType }), 90000);
  const shapedTitle = String(result.title || title || "Untitled Note").trim().slice(0, 180);
  const shapedBody = String(result.body || body || "").trim();
  const feedback = Array.isArray(result.feedback)
    ? result.feedback.map((item) => String(item).trim()).filter(Boolean).slice(0, 3)
    : [];
  if (!shapedBody) throw new Error("Gemma did not return shaped note text.");
  return {
    title: shapedTitle || "Untitled Note",
    body: shapedBody,
    feedback
  };
}

function questionTargetFor(text) {
  const words = text.trim().split(/\s+/).filter(Boolean).length;
  if (words < 120) return 8;
  if (words < 400) return 12;
  if (words < 900) return 18;
  if (words < 1800) return 24;
  return 32;
}

function isMathNote(note) {
  return /^##\s*Math Topic:/i.test(String(note?.body || ""));
}

function minimumQuestionBankFor(note) {
  if (isMathNote(note)) return 2;
  const words = String(note?.body || "").trim().split(/\s+/).filter(Boolean).length;
  if (words < 80) return 3;
  if (words < 160) return 4;
  return Math.min(6, Math.max(5, questionTargetFor(note?.body || "")));
}

function noteNeedsQuestionBackfill(note) {
  if (!note?.id) return Number(note?.questionCount || 0) < minimumQuestionBankFor(note);
  return viableQuestionCount(note.id, note) < minimumQuestionBankFor(note);
}

function quizPromptFor(note, target) {
  const safeTarget = isMathNote(note) ? 4 : Math.min(8, Math.max(5, target));
  const sourceText = sourceTextForGeneration(note, isMathNote(note) ? 2200 : isBookSourceType(note?.sourceType) ? 4200 : 2600);
  if (isMathNote(note)) {
    return `
You are creating a short math quiz from a structured math note.
Use ONLY the note text. Do not use outside facts.
Create exactly ${safeTarget} useful multiple-choice question objects.
Cover formula recall, worked-example reasoning, common mistakes, and practice application.
At least half of the questions must require doing the math from the formulas or worked examples.
Ask actual student-facing questions. Do not ask meta questions about what the student wants to practice.
Do not use wording like "practice to practice", "what should you practice", or "which topic is listed".
For math application questions, include concrete numbers in the prompt and make the correct answer a computed result.
Keep prompts concise. Make every answer exactly match one of the 4 choices.
Return valid JSON only. No markdown. No commentary.

Return only JSON:
{
  "summary": "1 sentence student-friendly summary",
  "questions": [
    {
      "topic": "math topic",
      "concept": "specific concept",
      "segment": "specific subtopic",
      "source_excerpt": "exact note-backed text this question tests",
      "assessment_angle": "definition | procedure | mistake | application",
      "canonical_prompt": "stable question",
      "canonical_answer": "source-backed answer",
      "accepted_answers": ["equivalent answer"],
      "importance": 0.8,
      "difficulty": 0.6,
      "variants": [
        {
          "delivery_type": "multiple_choice",
          "prompt": "MC prompt",
          "answer": "correct choice",
          "choices": ["correct choice", "distractor", "distractor", "distractor"],
          "rubric": "what must be known"
        }
      ]
    }
  ]
}

NOTE TITLE:
${note.title}

NOTE TEXT:
${sourceText}
`;
  }
  return `
You are building durable learning objects for an education app.
Use ONLY the note text. Do not use outside facts.
Create exactly ${safeTarget} useful question objects for a fast first quiz.
Avoid duplicate prompts. Avoid trivia unless it anchors an important idea.
Cover definitions, causes, locations, sequences, comparisons, consequences, and applied understanding where the note supports it.
For cause/effect or sequence questions, the answer must be temporally consistent with the note. A later event cannot cause an earlier event.
Prefer one durable question per distinct concept. Do not create multiple questions whose correct answer is the same fact.
Each question object must include one multiple_choice variant.
Every multiple_choice variant must have exactly 4 choices and one exact answer that appears in choices.
If source text says "As of the 2025 season" with a cumulative/team-history record, phrase the prompt as "as of the 2025 season" or "through the 2025 season"; do not ask for "the 2025 season record" unless the note gives that single-season record.
Return valid JSON only. No markdown. No commentary.

Return only JSON:
{
  "summary": "2 sentence student-friendly summary",
  "questions": [
    {
      "topic": "broad topic",
      "concept": "specific concept",
      "segment": "specific subtopic or segment title",
      "source_excerpt": "exact note-backed text this question tests",
      "assessment_angle": "definition | cause | sequence | comparison | consequence | application | detail",
      "canonical_prompt": "stable question object",
      "canonical_answer": "source-backed answer",
      "accepted_answers": ["equivalent answer"],
      "importance": 0.8,
      "difficulty": 0.6,
      "variants": [
        {
          "delivery_type": "multiple_choice",
          "prompt": "MC prompt",
          "answer": "correct choice",
          "choices": ["correct choice", "distractor", "distractor", "distractor"],
          "rubric": "what must be known"
        }
      ]
    }
  ]
}

NOTE TITLE:
${note.title}

NOTE TEXT:
${sourceText}
`;
}

function existingPromptFingerprints(noteId) {
  return new Set(sqlite(`
    SELECT canonical_prompt AS prompt FROM (
      SELECT prompt AS canonical_prompt FROM questions WHERE note_id = '${sqlEscape(noteId)}'
      UNION ALL
      SELECT prompt AS canonical_prompt FROM question_variants WHERE note_id = '${sqlEscape(noteId)}'
    )
  `, { json: true }).map((row) => promptFingerprint(row.prompt)));
}

function existingConceptSignatures(noteId) {
  return new Set(sqlite(`
    SELECT concept_signature
    FROM questions
    WHERE note_id = '${sqlEscape(noteId)}'
      AND concept_signature != ''
  `, { json: true }).map((row) => row.concept_signature));
}

function existingCanonicalConceptKeys(noteId) {
  return new Set(sqlite(`
    SELECT topic, subtopic, prompt, answer, assessment_angle, concept_signature
    FROM questions
    WHERE note_id = '${sqlEscape(noteId)}'
  `, { json: true }).map((row) => canonicalConceptKey({
    topic: row.topic,
    subtopic: row.subtopic,
    prompt: row.prompt,
    answer: row.answer,
    assessment_angle: row.assessment_angle,
    concept_signature: row.concept_signature
  })).filter(Boolean));
}

function existingAnswerConceptPairs(noteId) {
  return new Set(sqlite(`
    SELECT topic, subtopic, prompt, answer
    FROM questions
    WHERE note_id = '${sqlEscape(noteId)}'
  `, { json: true }).map((row) => {
    const conceptKey = canonicalConceptKey(row).split(":")[0] || "";
    const answerKey = compactConceptText(row.answer).split(" ").slice(0, 8).join(" ");
    return `${conceptKey}:${answerKey}`;
  }).filter((key) => key !== ":"));
}

function existingAnswerKeys(noteId) {
  return new Set(sqlite(`
    SELECT answer FROM questions
    WHERE note_id = '${sqlEscape(noteId)}'
  `, { json: true }).map((row) => answerMemoryKey(row)).filter(Boolean));
}

function viableQuestionCount(noteId, note = null) {
  const sourceNote = note || noteSummary(noteId);
  return sqlite(`
    SELECT
      q.*,
      v.id AS variant_id,
      v.delivery_type,
      v.prompt AS variant_prompt,
      v.answer AS variant_answer,
      v.choices AS variant_choices
    FROM questions q
    LEFT JOIN question_variants v ON v.question_id = q.id
    WHERE q.note_id = '${sqlEscape(noteId)}'
      AND COALESCE(v.delivery_type, 'multiple_choice') = 'multiple_choice'
    GROUP BY q.id
  `, { json: true }).filter((row) => !isLowQualityQuestion(row, sourceNote)).length;
}

function uncoveredNotePassages(note, existingQuestions) {
  const coveredText = existingQuestions
    .flatMap((item) => [item.topic, item.subtopic, item.prompt, item.answer])
    .join(" ");
  const coveredTokens = tokenSet(coveredText);
  return sourceTextForGeneration(note, 9000)
    .split(/(?<=[.!?])\s+/)
    .map((sentence) => sentence.trim())
    .filter((sentence) => sentence.length > 60)
    .map((sentence) => {
      const tokens = tokenSet(sentence);
      if (tokens.size === 0) return null;
      let overlap = 0;
      for (const token of tokens) {
        if (coveredTokens.has(token)) overlap += 1;
      }
      return {
        text: sentence.slice(0, 500),
        novelty: 1 - (overlap / tokens.size)
      };
    })
    .filter(Boolean)
    .sort((left, right) => right.novelty - left.novelty)
    .slice(0, 10);
}

function learningContextForNote(noteId) {
  const note = noteSummary(noteId);
  const conceptMemory = sqlite(`
    SELECT
      concept_signature,
      topic,
      subtopic,
      attempts,
      average_score,
      latest_score,
      last_seen
    FROM concept_memory
    WHERE note_id = '${sqlEscape(noteId)}'
    ORDER BY average_score ASC, last_seen DESC
    LIMIT 40
  `, { json: true });
  const segments = sqlite(`
    SELECT id, topic_title, subtopic_title, text, evidence, importance, difficulty, created_at
    FROM learning_segments
    WHERE note_id = '${sqlEscape(noteId)}'
    ORDER BY importance DESC, created_at ASC
    LIMIT 80
  `, { json: true });
  const assignments = sqlite(`
    SELECT id, segment_id, question_id, type, reason, priority, due_at, status, created_at, completed_at
    FROM journey_assignments
    WHERE note_id = '${sqlEscape(noteId)}'
    ORDER BY status ASC, priority DESC, due_at ASC
    LIMIT 80
  `, { json: true });
  const questionMemory = sqlite(`
    SELECT
      q.id,
      q.topic,
      q.subtopic,
      q.prompt,
      q.answer,
      q.assessment_angle,
      q.concept_signature,
      q.understanding_score,
      q.mastery_state,
      q.last_seen_at,
      COALESCE(lm.average_score, 0) AS average_score,
      COALESCE(lm.latest_score, 0) AS latest_score,
      COALESCE(lm.attempt_count, 0) AS attempt_count,
      COALESCE(lm.weakness_reason, '') AS weakness_reason
    FROM questions q
    LEFT JOIN learning_memory lm ON lm.question_id = q.id
    WHERE q.note_id = '${sqlEscape(noteId)}'
    ORDER BY q.last_seen_at DESC NULLS LAST, q.created_at DESC
    LIMIT 80
  `, { json: true }).map((row) => ({
    ...row,
    canonicalConceptKey: canonicalConceptKey(row)
  }));
  const recentAttempts = sqlite(`
    SELECT
      a.question_id,
      a.variant_id,
      a.topic_snapshot AS topic,
      a.subtopic_snapshot AS subtopic,
      a.prompt_snapshot AS prompt,
      a.answer_snapshot AS answer,
      a.response,
      a.score,
      a.feedback,
      a.created_at
    FROM attempts a
    WHERE a.note_id = '${sqlEscape(noteId)}'
    ORDER BY a.created_at DESC
    LIMIT 40
  `, { json: true }).map((row) => ({
    ...row,
    canonicalConceptKey: canonicalConceptKey(row)
  }));
  const quizHistory = sqlite(`
    SELECT id, score, attempt_ids, created_at
    FROM quiz_sessions
    WHERE note_id = '${sqlEscape(noteId)}'
    ORDER BY created_at DESC
    LIMIT 10
  `, { json: true });
  const quizMemory = sqlite(`
    SELECT title, selected_focus, reason, target_concepts, avoided_concepts, question_mix, model_name, prompt_version, created_at
    FROM quiz_memory
    WHERE note_id = '${sqlEscape(noteId)}'
    ORDER BY created_at DESC
    LIMIT 20
  `, { json: true }).map((row) => ({
    ...row,
    target_concepts: (() => {
      try { return JSON.parse(row.target_concepts || "[]"); } catch { return []; }
    })(),
    avoided_concepts: (() => {
      try { return JSON.parse(row.avoided_concepts || "[]"); } catch { return []; }
    })(),
    question_mix: (() => {
      try { return JSON.parse(row.question_mix || "{}"); } catch { return {}; }
    })()
  }));
  const answerEvaluations = sqlite(`
    SELECT question_id, score, verdict, matched_ideas, missing_ideas, model_name, prompt_version, created_at
    FROM answer_evaluations
    WHERE note_id = '${sqlEscape(noteId)}'
    ORDER BY created_at DESC
    LIMIT 40
  `, { json: true }).map((row) => ({
    ...row,
    matched_ideas: (() => {
      try { return JSON.parse(row.matched_ideas || "[]"); } catch { return []; }
    })(),
    missing_ideas: (() => {
      try { return JSON.parse(row.missing_ideas || "[]"); } catch { return []; }
    })()
  }));
  const actions = sqlite(`
    SELECT action_type, object_type, object_id, payload, created_at
    FROM user_actions
    WHERE note_id = '${sqlEscape(noteId)}' OR note_id IS NULL
    ORDER BY created_at DESC
    LIMIT 60
  `, { json: true }).map((row) => ({
    ...row,
    payload: (() => {
      try {
        return JSON.parse(row.payload || "{}");
      } catch {
        return {};
      }
    })()
  }));
  const latestQuiz = quizHistory[0] || null;
  const latestAttemptIds = latestQuiz
    ? String(latestQuiz.attempt_ids || "").split(/\n+/).map((id) => id.trim()).filter(Boolean)
    : [];
  const latestAssigned = latestAttemptIds.length
    ? sqlite(`
      SELECT
        a.question_id,
        a.topic_snapshot AS topic,
        a.subtopic_snapshot AS subtopic,
        a.prompt_snapshot AS prompt,
        a.answer_snapshot AS answer,
        a.response,
        a.score
      FROM attempts a
      WHERE a.id IN (${latestAttemptIds.map((id) => `'${sqlEscape(id)}'`).join(",")})
    `, { json: true }).map((row) => ({
      ...row,
      canonicalConceptKey: canonicalConceptKey(row)
    }))
    : [];
  const masteredConcepts = questionMemory
    .filter((row) => Number(row.understanding_score || 0) >= 0.9 || row.mastery_state === "strong" || row.mastery_state === "mastered")
    .map((row) => row.canonicalConceptKey);
  const weakConcepts = questionMemory
    .filter((row) => Number(row.average_score || 0) < 0.8 && Number(row.attempt_count || 0) > 0)
    .map((row) => ({
      key: row.canonicalConceptKey,
      prompt: row.prompt,
      answer: row.answer,
      averageScore: Number(row.average_score || 0),
      latestScore: Number(row.latest_score || 0),
      attempts: Number(row.attempt_count || 0)
    }));
  return {
    note: note ? {
      id: note.id,
      title: note.title,
      summary: note.summary,
      questionCount: note.questionCount,
      attemptCount: note.attemptCount,
      averageScore: note.averageScore
    } : null,
    latestQuiz: latestQuiz ? {
      id: latestQuiz.id,
      score: Number(latestQuiz.score || 0),
      createdAt: Number(latestQuiz.created_at || 0)
    } : null,
    latestAssigned,
    masteredConcepts: [...new Set(masteredConcepts)],
    weakConcepts,
    segments,
    assignments,
    conceptMemory,
    questionMemory,
    recentAttempts,
    quizMemory,
    answerEvaluations,
    quizHistory: quizHistory.map((row) => ({
      id: row.id,
      score: Number(row.score || 0),
      createdAt: Number(row.created_at || 0)
    })),
    recentActions: actions
  };
}

function topicIdFor(noteId, title, summary = "", importance = 1) {
  const cleanTitle = String(title || "Main Topic").trim();
  const existing = sqlite(`
    SELECT id FROM topics
    WHERE note_id = '${sqlEscape(noteId)}'
      AND lower(title) = lower('${sqlEscape(cleanTitle)}')
    LIMIT 1
  `, { json: true })[0];
  if (existing?.id) return existing.id;
  const id = crypto.randomUUID();
  sqlite(`
    INSERT INTO topics (id, note_id, title, summary, importance, created_at)
    VALUES (
      '${id}',
      '${sqlEscape(noteId)}',
      '${sqlEscape(cleanTitle)}',
      '${sqlEscape(summary)}',
      ${Number(importance || 1)},
      ${Date.now() / 1000}
    );
  `);
  return id;
}

function conceptIdFor(noteId, topicId, question) {
  const title = String(question.concept || question.subtopic || question.subtopic_title || question.canonical_prompt || question.prompt || "Core Concept").trim();
  const existing = sqlite(`
    SELECT id FROM concepts
    WHERE note_id = '${sqlEscape(noteId)}'
      AND lower(title) = lower('${sqlEscape(title)}')
    LIMIT 1
  `, { json: true })[0];
  if (existing?.id) return existing.id;
  const id = crypto.randomUUID();
  sqlite(`
    INSERT INTO concepts (
      id, note_id, topic_id, title, source_excerpt, importance, difficulty,
      understanding_score, mastery_state, created_at
    ) VALUES (
      '${id}',
      '${sqlEscape(noteId)}',
      '${sqlEscape(topicId)}',
      '${sqlEscape(title)}',
      '${sqlEscape(question.source_excerpt || question.sourceExcerpt || "")}',
      ${Number(question.importance || 1)},
      ${Number(question.difficulty || 1)},
      0,
      'new',
      ${Date.now() / 1000}
    );
  `);
  return id;
}

function segmentIdFor(noteId, topicId, question) {
  const topicTitle = String(question.topic || question.topic_title || "Main Topic").trim();
  const subtopicTitle = String(question.segment || question.concept || question.subtopic || question.subtopic_title || "Core Segment").trim();
  const existing = sqlite(`
    SELECT id FROM learning_segments
    WHERE note_id = '${sqlEscape(noteId)}'
      AND lower(topic_title) = lower('${sqlEscape(topicTitle)}')
      AND lower(subtopic_title) = lower('${sqlEscape(subtopicTitle)}')
    LIMIT 1
  `, { json: true })[0];
  if (existing?.id) return existing.id;
  const id = crypto.randomUUID();
  sqlite(`
    INSERT INTO learning_segments (
      id, note_id, topic_id, topic_title, subtopic_title, text, evidence,
      importance, difficulty, created_at
    ) VALUES (
      '${id}',
      '${sqlEscape(noteId)}',
      '${sqlEscape(topicId)}',
      '${sqlEscape(topicTitle)}',
      '${sqlEscape(subtopicTitle)}',
      '${sqlEscape(question.source_excerpt || question.sourceExcerpt || question.text || question.canonical_prompt || question.prompt || "")}',
      '${sqlEscape(question.source_excerpt || question.sourceExcerpt || question.evidence || "")}',
      ${Number(question.importance || 1)},
      ${Number(question.difficulty || 1)},
      ${Date.now() / 1000}
    );
  `);
  return id;
}

function normalizeChoice(value) {
  const raw = String(value || "").trim();
  const numeric = raw.replace(/[,%°]/g, "").trim();
  if (/^-?\d+(?:\.\d+)?$/.test(numeric)) {
    return String(Number(numeric));
  }
  return normalizeText(raw).replace(/\s+/g, " ").trim();
}

function recordNumbers(value) {
  const match = String(value || "").match(/(\d{1,4})\s*[–-]\s*(\d{1,4})(?:\s*[–-]\s*(\d{1,4}))?\s*\(\.\d{3}\)/);
  if (!match) return null;
  return {
    wins: Number(match[1]),
    losses: Number(match[2]),
    ties: Number(match[3] || 0)
  };
}

function looksLikeCumulativeRecord(value) {
  const record = recordNumbers(value);
  if (!record) return false;
  return record.wins + record.losses + record.ties > 25;
}

function repairSeasonRecordPrompt(prompt, answer, sourceExcerpt = "") {
  let cleanPrompt = String(prompt || "").trim();
  if (!cleanPrompt) return cleanPrompt;
  if (!looksLikeCumulativeRecord(answer)) return cleanPrompt;
  const source = normalizeText(sourceExcerpt);
  const hasAsOfSeasonEvidence = /\bas of (the )?\d{4} season\b/.test(source);
  if (!hasAsOfSeasonEvidence) return cleanPrompt;
  cleanPrompt = cleanPrompt.replace(/\bfor the (\d{4}) season\b/gi, "as of the $1 season");
  cleanPrompt = cleanPrompt.replace(/\bfor (\d{4})\b/gi, "as of $1");
  return cleanPrompt;
}

function validatedMultipleChoiceVariant(variant, fallbackPrompt, fallbackAnswer) {
  const prompt = String(variant.prompt || fallbackPrompt || "").trim();
  const rawAnswer = String(variant.answer || fallbackAnswer || "").trim();
  const rawChoices = Array.isArray(variant.choices)
    ? variant.choices.map((choice) => String(choice || "").trim()).filter(Boolean)
    : [];
  if (!prompt || !rawAnswer) return { valid: false, reason: "missing_prompt_or_answer" };
  if (rawChoices.length !== 4) return { valid: false, reason: "choice_count" };

  const normalizedChoices = rawChoices.map(normalizeChoice);
  if (new Set(normalizedChoices).size !== 4) return { valid: false, reason: "duplicate_choices" };
  const displayChoices = rawChoices.map((choice) => normalizeText(choice));
  if (new Set(displayChoices).size !== 4) return { valid: false, reason: "duplicate_display_choices" };

  const answerNorm = normalizeChoice(rawAnswer);
  const answerIndex = normalizedChoices.findIndex((choice) => choice === answerNorm);
  if (answerIndex === -1) return { valid: false, reason: "answer_not_in_choices" };

  const answer = rawChoices[answerIndex];
  const distractors = rawChoices.filter((_, index) => index !== answerIndex);
  const brokenDistractor = distractors.some((choice) => {
    const choiceNorm = normalizeChoice(choice);
    if (!choiceNorm || choiceNorm.length < 2) return true;
    if (choiceNorm === answerNorm) return true;
    if (answerNorm.length >= 8 && choiceNorm.includes(answerNorm)) return true;
    if (choiceNorm.length >= 8 && answerNorm.includes(choiceNorm)) return true;
    const formulaLike = /[=^√]|\bsqrt\b/i.test(choice) || /[=^√]|\bsqrt\b/i.test(answer);
    if (!formulaLike && tokenSet(choiceNorm).size >= 3 && tokenSet(answerNorm).size >= 3 && tokenOverlapRatio(choiceNorm, answerNorm) >= 0.66) return true;
    return false;
  });
  if (brokenDistractor) return { valid: false, reason: "broken_distractor" };

  return {
    valid: true,
    variant: {
      ...variant,
      delivery_type: "multiple_choice",
      prompt,
      answer,
      choices: rawChoices
    }
  };
}

function hasRepeatedAdjacentWords(value) {
  const words = normalizeText(value).split(" ").filter(Boolean);
  return words.some((word, index) => index > 0 && word === words[index - 1] && word.length > 2);
}

function isLowQualityQuestion(question, note) {
  const prompt = String(question.canonical_prompt || question.prompt || question.variants?.[0]?.prompt || "").trim();
  const answer = String(question.canonical_answer || question.answer || question.variants?.[0]?.answer || "").trim();
  const normalizedPrompt = normalizeText(prompt);
  if (!prompt || !answer) return true;
  if (hasRepeatedAdjacentWords(prompt)) return true;

  const choices = (() => {
    if (Array.isArray(question.choices)) return question.choices;
    if (Array.isArray(question.variants?.[0]?.choices)) return question.variants[0].choices;
    const encoded = question.variant_choices || question.choices;
    if (typeof encoded === "string" && encoded.trim().startsWith("[")) {
      try { return JSON.parse(encoded); } catch { return []; }
    }
    return [];
  })();
  if (choices.length > 0 && !validatedMultipleChoiceVariant({ prompt, answer, choices }, prompt, answer).valid) return true;

  const blockedMetaPatterns = [
    /\bpractice to practice\b/i,
    /\bwhat (do|should|would) you want to practice\b/i,
    /\bwhat type of .* should you practice\b/i,
    /\bwhich .* is listed\b/i,
    /\baccording to the section titled what i want to practice\b/i,
    /\bwhich (action|of the following) is (listed as )?a common mistake\b/i
  ];
  if (blockedMetaPatterns.some((pattern) => pattern.test(prompt))) return true;

  if (isMathNote(note)) {
    const angle = normalizeText(question.assessment_angle || question.assessmentAngle || "");
    const looksApplication = angle.includes("application") || /\b(solve|find|calculate|compute|evaluate|at\s+\d{1,2}:\d{2}|for\s+\d+|from\s+\d+|if\s+)\b/i.test(prompt);
    const hasNumbers = /\d/.test(prompt);
    const isMetaPractice = /\bpractice\b/i.test(prompt) && !looksApplication;
    if (isMetaPractice) return true;
    if (looksApplication && !hasNumbers) return true;
    if (normalizedPrompt.split(" ").length < 4) return true;
  }

  return false;
}

function hasSourceBackedDistractor(variant, sourceText) {
  const evidence = normalizeText(sourceText || "");
  if (!evidence) return false;
  const answer = normalizeChoice(variant.answer || "");
  return (variant.choices || [])
    .filter((choice) => normalizeChoice(choice) !== answer)
    .some((choice) => {
      const normalized = normalizeChoice(choice);
      return normalized.length >= 4 && evidence.includes(normalized);
    });
}

function insertVariant(noteId, questionId, variant) {
  const type = String(variant.delivery_type || variant.deliveryType || "multiple_choice").trim();
  const prompt = repairSeasonRecordPrompt(
    variant.prompt || "",
    variant.answer || "",
    variant.source_excerpt || variant.sourceExcerpt || variant.evidence || ""
  );
  const answer = String(variant.answer || "").trim();
  if (!prompt || !answer) return false;
  const choices = Array.isArray(variant.choices) ? variant.choices.filter(Boolean).map(String) : [];
  if (type === "multiple_choice") {
    const validation = validatedMultipleChoiceVariant(variant, prompt, answer);
    if (!validation.valid) return false;
    variant = validation.variant;
  }
  sqlite(`
    INSERT INTO question_variants (
      id, question_id, note_id, delivery_type, prompt, answer, choices, rubric, created_at
    ) VALUES (
      '${crypto.randomUUID()}',
      '${sqlEscape(questionId)}',
      '${sqlEscape(noteId)}',
      '${sqlEscape(type)}',
      '${sqlEscape(prompt)}',
      '${sqlEscape(answer)}',
      '${sqlEscape(JSON.stringify(type === "multiple_choice" ? shuffled(choices) : choices))}',
      '${sqlEscape(variant.rubric || "")}',
      ${Date.now() / 1000}
    );
  `);
  return true;
}

function insertQuestions(noteId, questions, generationSource) {
  const note = noteSummary(noteId);
  const existing = existingPromptFingerprints(noteId);
  const existingConcepts = existingConceptSignatures(noteId);
  const existingCanonicalKeys = existingCanonicalConceptKeys(noteId);
  const existingAnswerPairs = existingAnswerConceptPairs(noteId);
  const existingAnswers = existingAnswerKeys(noteId);
  let saved = 0;
  for (const question of questions) {
    const variants = Array.isArray(question.variants) && question.variants.length > 0
      ? question.variants
      : [{
          delivery_type: "multiple_choice",
          prompt: question.prompt,
          answer: question.answer,
          choices: question.choices,
          rubric: question.grading_rubric || ""
        }];
    const sourceExcerpt = question.source_excerpt || question.sourceExcerpt || question.evidence || "";
    const rawPrompt = String(question.canonical_prompt || question.prompt || variants[0]?.prompt || "").trim();
    const answer = String(question.canonical_answer || question.answer || variants[0]?.answer || "").trim();
    const prompt = repairSeasonRecordPrompt(rawPrompt, answer, sourceExcerpt);
    if (isLowQualityQuestion({ ...question, canonical_prompt: prompt, canonical_answer: answer }, note)) continue;
    const fingerprint = promptFingerprint(prompt);
    const normalizedQuestion = { ...question, prompt, answer, source_excerpt: sourceExcerpt };
    const signature = conceptSignature(normalizedQuestion);
    const canonicalKey = canonicalConceptKey(normalizedQuestion);
    const conceptRoot = conceptRootKey(normalizedQuestion);
    const answerRoot = answerMemoryKey({ answer });
    const answerPair = `${conceptRoot}:${answerRoot}`;
    if (
      !prompt ||
      !answer ||
      existing.has(fingerprint) ||
      existingConcepts.has(signature) ||
      existingCanonicalKeys.has(canonicalKey) ||
      existingAnswerPairs.has(answerPair) ||
      answerKeyOverlapsAny(answerRoot, existingAnswers)
    ) continue;
    existing.add(fingerprint);
    existingConcepts.add(signature);
    existingCanonicalKeys.add(canonicalKey);
    existingAnswerPairs.add(answerPair);
    existingAnswers.add(answerRoot);
    const topicTitle = question.topic || question.topic_title || "Main Topic";
    const topicId = topicIdFor(noteId, topicTitle, "", question.importance || 1);
    const segmentId = segmentIdFor(noteId, topicId, question);
    const conceptId = conceptIdFor(noteId, topicId, question);
    const questionId = crypto.randomUUID();
    const acceptedAnswers = Array.isArray(question.accepted_answers || question.acceptedAnswers)
      ? (question.accepted_answers || question.acceptedAnswers)
      : [answer];
    const mcVariant = variants.find((variant) => (variant.delivery_type || variant.deliveryType || "multiple_choice") === "multiple_choice") || variants[0] || {};
    mcVariant.prompt = repairSeasonRecordPrompt(mcVariant.prompt || prompt, mcVariant.answer || answer, sourceExcerpt);
    mcVariant.source_excerpt = sourceExcerpt;
    const mcValidation = validatedMultipleChoiceVariant(mcVariant, prompt, answer);
    if (!mcValidation.valid) continue;
    const cleanMCVariant = mcValidation.variant;
    const choices = cleanMCVariant.choices;
    sqlite(`
      INSERT INTO questions (
        id, note_id, topic_id, segment_id, concept_id, topic, subtopic, assessment_angle, concept_signature,
        generation_source, prompt, answer, choices, importance, difficulty,
        understanding_score, mastery_state, created_at
      ) VALUES (
        '${questionId}',
        '${sqlEscape(noteId)}',
        '${sqlEscape(topicId)}',
        '${sqlEscape(segmentId)}',
        '${sqlEscape(conceptId)}',
        '${sqlEscape(question.topic || "Main Topic")}',
        '${sqlEscape(question.concept || question.subtopic || "Core Idea")}',
        '${sqlEscape(question.assessment_angle || question.assessmentAngle || "recall")}',
        '${sqlEscape(signature)}',
        '${sqlEscape(generationSource)}',
        '${sqlEscape(prompt)}',
        '${sqlEscape(cleanMCVariant.answer)}',
        '${sqlEscape(JSON.stringify(shuffled(choices)))}',
        ${Number(question.importance || 1)},
        ${Number(question.difficulty || 1)},
        0,
        'new',
        ${Date.now() / 1000}
      );
    `);
    let variantSaved = false;
    for (const variant of [cleanMCVariant, ...variants.filter((candidate) => candidate !== mcVariant)]) {
      const normalizedVariant = {
        ...variant,
        prompt: variant.prompt || prompt,
        answer: variant.answer || cleanMCVariant.answer
      };
      variantSaved = insertVariant(noteId, questionId, normalizedVariant) || variantSaved;
    }
    if (!variantSaved) continue;
    saved += 1;
  }
  return saved;
}

function saveQuestions(noteId, summary, questions) {
  sqlite(`DELETE FROM quiz_queue WHERE note_id = '${sqlEscape(noteId)}';`);
  sqlite(`DELETE FROM question_variants WHERE note_id = '${sqlEscape(noteId)}';`);
  sqlite(`DELETE FROM questions WHERE note_id = '${sqlEscape(noteId)}';`);
  sqlite(`DELETE FROM concepts WHERE note_id = '${sqlEscape(noteId)}';`);
  sqlite(`DELETE FROM learning_segments WHERE note_id = '${sqlEscape(noteId)}';`);
  sqlite(`DELETE FROM journey_assignments WHERE note_id = '${sqlEscape(noteId)}';`);
  sqlite(`DELETE FROM topics WHERE note_id = '${sqlEscape(noteId)}';`);
  const saved = insertQuestions(noteId, questions, "initial");
  recordUserAction({
    noteId,
    actionType: "note.analyzed",
    objectType: "note",
    objectId: noteId,
    payload: { savedQuestions: saved, summary: summary || "" }
  });
  sqlite(`
    UPDATE notes
    SET summary = '${sqlEscape(summary || "")}',
        status = 'ready'
    WHERE id = '${sqlEscape(noteId)}';
  `);
  return saved;
}

function deleteNote(noteId) {
  const note = noteSummary(noteId);
  if (!note) return false;
  sqlite(`
    DELETE FROM quiz_queue WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM question_variants WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM answer_evaluations WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM attempts WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM quiz_sessions WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM quiz_memory WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM learning_memory WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM concept_memory WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM questions WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM concepts WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM learning_segments WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM book_sections WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM journey_assignments WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM topics WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM model_runs WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM user_actions WHERE note_id = '${sqlEscape(noteId)}';
    DELETE FROM notes WHERE id = '${sqlEscape(noteId)}';
  `);
  return true;
}

function rowsToQuiz(rows) {
  return rows.map((row) => ({
    id: row.id,
    variantId: row.variant_id || "",
    deliveryType: row.delivery_type || "multiple_choice",
    topic: row.topic,
    subtopic: row.subtopic,
    assessmentAngle: row.assessment_angle || "recall",
    prompt: row.variant_prompt || row.prompt,
    answer: row.variant_answer || row.answer,
    choices: JSON.parse(row.variant_choices || row.choices || "[]")
  }));
}

function recordQuizStarted(noteId, quiz) {
  recordUserAction({
    noteId,
    actionType: "quiz.started",
    objectType: "quiz",
    objectId: "",
    payload: {
      questionCount: quiz.length,
      questions: quiz.map((question) => ({
        id: question.id,
        variantId: question.variantId,
        topic: question.topic,
        subtopic: question.subtopic,
        prompt: question.prompt,
        answer: question.answer,
        canonicalConceptKey: canonicalConceptKey(question)
      }))
    }
  });
  saveQuizMemory({
    noteId,
    title: "Started quiz",
    reason: "Stored assigned concepts for the quiz Gemma and SQLite memory loop.",
    questions: quiz,
    promptVersion: "quiz_started.web.v1"
  });
}

function selectedQuizRows(noteId, options = {}) {
  const note = noteSummary(noteId);
  const focus = normalizeText(options.focus || "");
  const masteredQuizFingerprints = recentMasteredQuizFingerprints(noteId);
  const latestSession = sqlite(`
    SELECT attempt_ids, score
    FROM quiz_sessions
    WHERE note_id = '${sqlEscape(noteId)}'
    ORDER BY created_at DESC
    LIMIT 1
  `, { json: true })[0];
  const latestSessionScore = Number(latestSession?.score ?? -1);
  const latestAttemptIds = String(latestSession?.attempt_ids || "")
    .split(/\n+/)
    .map((id) => id.trim())
    .filter(Boolean);
  const latestQuestionIds = latestAttemptIds.length
    ? new Set(sqlite(`
      SELECT question_id FROM attempts
      WHERE id IN (${latestAttemptIds.map((id) => `'${sqlEscape(id)}'`).join(",")})
    `, { json: true }).map((row) => row.question_id))
    : new Set();
  const recentCorrectQuestionIds = new Set(sqlite(`
    SELECT question_id
    FROM attempts
    WHERE note_id = '${sqlEscape(noteId)}'
      AND score >= 0.95
      AND created_at >= ${(Date.now() / 1000) - (7 * 86400)}
    ORDER BY created_at DESC
    LIMIT 80
  `, { json: true }).map((row) => row.question_id));

  const rows = sqlite(`
    SELECT
      q.*,
      v.id AS variant_id,
      v.delivery_type,
      v.prompt AS variant_prompt,
      v.answer AS variant_answer,
      v.choices AS variant_choices,
      v.rubric AS variant_rubric,
      COALESCE(MAX(a.created_at), 0) AS last_seen,
      COALESCE(AVG(a.score), -1) AS average_score,
      COUNT(a.id) AS attempt_count
    FROM questions q
    LEFT JOIN question_variants v ON v.question_id = q.id
    LEFT JOIN attempts a ON a.question_id = q.id
    WHERE q.note_id = '${sqlEscape(noteId)}'
      AND COALESCE(v.delivery_type, 'multiple_choice') = 'multiple_choice'
    GROUP BY q.id
  `, { json: true }).filter((row) => {
    if (isLowQualityQuestion(row, note)) return false;
    if (!focus) return true;
    return normalizeText(`${row.topic || ""} ${row.subtopic || ""}`).includes(focus);
  });

  const pool = rows.length - latestQuestionIds.size >= 8
    ? rows.filter((row) => latestQuestionIds.has(row.id) === false)
    : rows;
  const latestConceptKeys = new Set(rows
    .filter((row) => latestQuestionIds.has(row.id))
    .map((row) => canonicalConceptKey(row)));
  const latestConceptRoots = new Set(rows
    .filter((row) => latestQuestionIds.has(row.id))
    .map((row) => conceptRootKey(row))
    .filter(Boolean));
  const latestAnswerKeys = new Set(rows
    .filter((row) => latestQuestionIds.has(row.id))
    .map((row) => answerMemoryKey(row))
    .filter(Boolean));
  const weakConceptKeys = new Set(rows
    .filter((row) => Number(row.attempt_count || 0) > 0 && Number(row.average_score) < 0.8)
    .map((row) => canonicalConceptKey(row)));
  const weakRoots = new Set(rows
    .filter((row) => Number(row.attempt_count || 0) > 0 && Number(row.average_score) < 0.8)
    .map((row) => conceptRootKey(row))
    .filter(Boolean));
  const recentCorrectRows = rows.filter((row) => recentCorrectQuestionIds.has(row.id));
  const recentCorrectConceptKeys = new Set(recentCorrectRows.map((row) => canonicalConceptKey(row)).filter(Boolean));
  const recentCorrectConceptRoots = new Set(recentCorrectRows.map((row) => conceptRootKey(row)).filter(Boolean));
  const recentCorrectAnswerKeys = new Set(recentCorrectRows.map((row) => answerMemoryKey(row)).filter(Boolean));
  const recentCorrectPromptKeys = new Set(recentCorrectRows.map((row) => promptFingerprint(row.variant_prompt || row.prompt)).filter(Boolean));
  const wasRecentlyCorrect = (row) => {
    const conceptKey = canonicalConceptKey(row);
    const conceptRoot = conceptRootKey(row);
    const answerKey = answerMemoryKey(row);
    const promptKey = promptFingerprint(row.variant_prompt || row.prompt);
    return recentCorrectQuestionIds.has(row.id) ||
      recentCorrectConceptKeys.has(conceptKey) ||
      recentCorrectConceptRoots.has(conceptRoot) ||
      recentCorrectPromptKeys.has(promptKey) ||
      (answerKey && (recentCorrectAnswerKeys.has(answerKey) || answerKeyOverlapsAny(answerKey, recentCorrectAnswerKeys)));
  };
  const viableFreshRows = rows.filter((row) => {
    const conceptKey = canonicalConceptKey(row);
    const conceptRoot = conceptRootKey(row);
    if (latestSessionScore >= 0.95 && wasRecentlyCorrect(row)) return false;
    return !wasRecentlyCorrect(row) ||
      weakConceptKeys.has(conceptKey) ||
      weakRoots.has(conceptRoot);
  });
  const canServeWithoutRecentCorrect = note
    ? viableFreshRows.length >= Math.min(minimumQuestionBankFor(note), 8)
    : viableFreshRows.length >= 3;

  const ranked = pool.sort((left, right) => {
    const score = (row) => {
      const average = Number(row.average_score);
      const attempts = Number(row.attempt_count || 0);
      const lastSeen = Number(row.last_seen || 0);
      const age = lastSeen === 0 ? 30 : Math.min(30, ((Date.now() / 1000) - lastSeen) / 86400);
      const conceptKey = canonicalConceptKey(row);
      const conceptRoot = conceptRootKey(row);
      const answerKey = answerMemoryKey(row);
      const recentlyCorrect = wasRecentlyCorrect(row);
      const recentlyMastered = latestSessionScore >= 0.95 &&
        (
          latestConceptKeys.has(conceptKey) ||
          latestConceptRoots.has(conceptRoot) ||
          latestAnswerKeys.has(answerKey) ||
          answerKeyOverlapsAny(answerKey, latestAnswerKeys)
        ) &&
        !weakConceptKeys.has(conceptKey) &&
        !weakRoots.has(conceptRoot);
      const justMasteredPenalty = recentlyMastered
        ? -700
        : 0;
      const recentCorrectPenalty = canServeWithoutRecentCorrect && recentlyCorrect
        ? -1200
        : 0;
      return (
        (attempts === 0 ? 1000 : 0) +
        (average >= 0 && average < 0.8 ? 500 : 0) +
        (latestQuestionIds.has(row.id) ? -250 : 0) +
        justMasteredPenalty +
        recentCorrectPenalty +
        Number(row.importance || 1) * 30 +
        Number(row.difficulty || 1) * (latestSessionScore >= 0.95 ? 45 : 20) +
        age +
        Math.random()
      );
    };
    return score(right) - score(left);
  });

  const selected = [];
  const selectedKeys = new Set();
  const selectedConceptRoots = new Set();
  const selectedSubtopics = new Map();
  const selectedAnswers = new Map();
  for (const row of ranked) {
    const key = quizLegitimacyKey(row);
    const conceptRoot = conceptRootKey(row) || key;
    const answerKey = answerMemoryKey(row);
    const subtopicKey = normalizeText(row.subtopic || row.topic || "topic");
    const subtopicCount = selectedSubtopics.get(subtopicKey) || 0;
    const answerCount = selectedAnswers.get(answerKey) || 0;
    const isWeak = weakConceptKeys.has(canonicalConceptKey(row));
    const isWeakRoot = weakRoots.has(conceptRoot);
    const recentlyMasteredConcept = latestConceptKeys.has(canonicalConceptKey(row)) ||
      latestConceptRoots.has(conceptRoot);
    const recentlyMasteredAnswer = answerKey &&
      (latestAnswerKeys.has(answerKey) || answerKeyOverlapsAny(answerKey, latestAnswerKeys));
    const recentlyCorrect = wasRecentlyCorrect(row);
    if (selectedKeys.has(key)) continue;
    if (selectedConceptRoots.has(conceptRoot)) continue;
    if (latestSessionScore >= 0.95 && recentlyCorrect) continue;
    if (canServeWithoutRecentCorrect && recentlyCorrect && !isWeak && !isWeakRoot) continue;
    if (
      latestSessionScore >= 0.95 &&
      (recentlyMasteredConcept || recentlyMasteredAnswer) &&
      !isWeak &&
      !isWeakRoot
    ) continue;
    if (answerKey && answerCount >= 1 && ranked.length - selected.length > 3) continue;
    if (subtopicCount >= 1 && ranked.length - selected.length > 3) continue;
    selected.push(row);
    selectedKeys.add(key);
    selectedConceptRoots.add(conceptRoot);
    selectedSubtopics.set(subtopicKey, subtopicCount + 1);
    if (answerKey) selectedAnswers.set(answerKey, answerCount + 1);
    if (selected.length >= 8) break;
  }

  const sorted = [...selected];
  if (sorted.length < Math.min(5, ranked.length)) {
    for (const row of ranked) {
      if (sorted.some((candidate) => candidate.id === row.id)) continue;
      const key = quizLegitimacyKey(row);
      const conceptRoot = conceptRootKey(row) || key;
      const answerKey = answerMemoryKey(row);
      const matchingKey = sorted.some((candidate) => quizLegitimacyKey(candidate) === key);
      const matchingConcept = sorted.some((candidate) => (conceptRootKey(candidate) || quizLegitimacyKey(candidate)) === conceptRoot);
      const matchingAnswer = answerKey && sorted.some((candidate) => {
        const candidateAnswer = answerMemoryKey(candidate);
        return candidateAnswer === answerKey || answerKeysOverlap(candidateAnswer, answerKey);
      });
      if (matchingKey || matchingConcept || matchingAnswer) continue;
      const recentlyMasteredAnswer = answerKey &&
        (latestAnswerKeys.has(answerKey) || answerKeyOverlapsAny(answerKey, latestAnswerKeys));
      const recentlyCorrect = wasRecentlyCorrect(row);
      if (latestSessionScore >= 0.95 && recentlyCorrect) continue;
      if (canServeWithoutRecentCorrect && recentlyCorrect) continue;
      if (
        latestSessionScore >= 0.95 &&
        (latestConceptRoots.has(conceptRoot) || recentlyMasteredAnswer)
      ) continue;
      sorted.push(row);
      if (sorted.length >= 8) break;
    }
  }
  const minimumRows = note ? Math.min(minimumQuestionBankFor(note), ranked.length, 8) : Math.min(3, ranked.length);
  if (sorted.length < minimumRows) {
    for (const row of ranked) {
      if (sorted.some((candidate) => candidate.id === row.id)) continue;
      if (latestSessionScore >= 0.95 && wasRecentlyCorrect(row)) continue;
      sorted.push(row);
      if (sorted.length >= minimumRows) break;
    }
  }
  const quiz = rowsToQuiz(sorted);

  const quizFingerprint = quizConceptSetFingerprint(quiz);
  const canMoveBeyondMasteredSet = rows.length > (note ? minimumQuestionBankFor(note) + 1 : quiz.length);
  if (quiz.length > 0 && masteredQuizFingerprints.has(quizFingerprint) && canMoveBeyondMasteredSet) {
    recordUserAction({
      noteId,
      actionType: "quiz.suppressed_mastered_repeat",
      objectType: "quiz",
      objectId: "",
      payload: {
        reason: "The selected concept set was already mastered at 100%.",
        questionCount: quiz.length,
        conceptFingerprint: quizFingerprint,
        questions: quiz.map((question) => ({
          id: question.id,
          topic: question.topic,
          subtopic: question.subtopic,
          prompt: question.prompt,
          canonicalConceptKey: canonicalConceptKey(question)
        }))
      }
    });
    saveQuizMemory({
      noteId,
      title: "Suppressed quiz",
      reason: "Avoided serving a concept set that was already mastered at 100%.",
      questions: quiz,
      promptVersion: "quiz_suppressed_mastered_repeat.web.v1"
    });
    const nextQuiz = queueNextQuiz(noteId, quiz.map((question) => ({
      ...question,
      response: question.answer,
      score: 1,
      feedback: "Mastered concept set suppressed. Generate harder adjacent checks.",
      canonicalConceptKey: canonicalConceptKey(question)
    })), {
      force: true,
      reason: "mastered_repeat_suppressed"
    });
    return { rows: [], suppressed: true, nextQuiz };
  }

  return { rows: sorted, suppressed: false, nextQuiz: null };
}

function readyQueue(noteId) {
  return sqlite(`
    SELECT *
    FROM quiz_queue
    WHERE note_id = '${sqlEscape(noteId)}'
      AND state = 'ready'
    ORDER BY created_at ASC
    LIMIT 1
  `, { json: true })[0] || null;
}

function queuedQuizCount(noteId) {
  return Number(sqlite(`
    SELECT COUNT(*) AS count
    FROM quiz_queue
    WHERE note_id = '${sqlEscape(noteId)}'
      AND state = 'ready'
  `, { json: true })[0]?.count || 0);
}

function questionRowsByIds(noteId, ids) {
  const note = noteSummary(noteId);
  const cleanIds = (ids || []).map((id) => String(id || "").trim()).filter(Boolean);
  if (cleanIds.length === 0) return [];
  const rows = sqlite(`
    SELECT
      q.*,
      v.id AS variant_id,
      v.delivery_type,
      v.prompt AS variant_prompt,
      v.answer AS variant_answer,
      v.choices AS variant_choices,
      v.rubric AS variant_rubric
    FROM questions q
    LEFT JOIN question_variants v ON v.question_id = q.id
    WHERE q.note_id = '${sqlEscape(noteId)}'
      AND q.id IN (${cleanIds.map((id) => `'${sqlEscape(id)}'`).join(",")})
      AND COALESCE(v.delivery_type, 'multiple_choice') = 'multiple_choice'
  `, { json: true }).filter((row) => !isLowQualityQuestion(row, note));
  const order = new Map(cleanIds.map((id, index) => [id, index]));
  return rows.sort((left, right) => (order.get(left.id) ?? 999) - (order.get(right.id) ?? 999));
}

function latestQuizEvidence(noteId, rows, reason) {
  const concepts = rows.map((row) => conceptRootKey(row)).filter(Boolean);
  const latest = sqlite(`
    SELECT score, attempt_ids
    FROM quiz_sessions
    WHERE note_id = '${sqlEscape(noteId)}'
    ORDER BY created_at DESC
    LIMIT 1
  `, { json: true })[0];
  if (!latest) {
    return {
      summary: "Starter quiz prepared from the note.",
      targetConcepts: concepts,
      avoidedConcepts: []
    };
  }
  const ids = String(latest.attempt_ids || "").split(/\n+/).map((id) => id.trim()).filter(Boolean);
  const attempts = ids.length
    ? sqlite(`
      SELECT prompt_snapshot AS prompt, answer_snapshot AS answer, score
      FROM attempts
      WHERE id IN (${ids.map((id) => `'${sqlEscape(id)}'`).join(",")})
    `, { json: true })
    : [];
  const missed = attempts.filter((attempt) => Number(attempt.score || 0) < 1);
  const mastered = attempts.filter((attempt) => Number(attempt.score || 0) >= 1);
  const avoidedConcepts = mastered.map((attempt) => conceptRootKey(attempt)).filter(Boolean);
  const summary = missed.length > 0
    ? `Next quiz revisits ${missed.length} missed idea${missed.length === 1 ? "" : "s"} and adds related checks.`
    : Number(latest.score || 0) >= 0.95
      ? `Previous quiz was ${Math.round(Number(latest.score || 0) * 100)}%, so this quiz avoids mastered answers and looks for fresh concepts.`
      : `Next quiz uses your last score to rebalance weak and new concepts.`;
  return { summary, targetConcepts: concepts, avoidedConcepts, reason };
}

function enqueueQuizForNote(noteId, reason = "prepared", options = {}) {
  if (queuedQuizCount(noteId) > 0) {
    return { status: "already_ready", saved: 0 };
  }
  const note = noteSummary(noteId);
  const selected = selectedQuizRows(noteId, options);
  if (selected.suppressed) return selected.nextQuiz || { status: "preparing", saved: 0 };
  const rows = selected.rows || [];
  if (rows.length === 0) return { status: "empty", saved: 0 };
  const viableCount = note ? viableQuestionCount(noteId, note) : rows.length;
  const minimumServableRows = Math.min(minimumQuestionBankFor(note), Math.max(2, viableCount));
  if (note && rows.length < minimumServableRows) {
    return { status: "insufficient_viable_questions", saved: rows.length };
  }
  const id = crypto.randomUUID();
  const evidence = latestQuizEvidence(noteId, rows, reason);
  sqlite(`
    INSERT INTO quiz_queue (
      id, note_id, state, reason, question_ids,
      summary, target_concepts, avoided_concepts, created_at
    )
    VALUES (
      '${id}',
      '${sqlEscape(noteId)}',
      'ready',
      '${sqlEscape(reason)}',
      '${sqlEscape(JSON.stringify(rows.map((row) => row.id)))}',
      '${sqlEscape(evidence.summary)}',
      '${sqlEscape(JSON.stringify(evidence.targetConcepts))}',
      '${sqlEscape(JSON.stringify(evidence.avoidedConcepts))}',
      ${Date.now() / 1000}
    );
  `);
  recordUserAction({
    noteId,
    actionType: "quiz.queued",
    objectType: "quiz_queue",
    objectId: id,
    payload: { reason, questionIds: rows.map((row) => row.id), evidence }
  });
  return { status: "ready", saved: rows.length, evidence };
}

async function prepareInitialQuiz(noteId) {
  const note = noteSummary(noteId);
  if (!note) return { saved: 0, status: "missing_note" };
  sqlite(`UPDATE notes SET status = 'building' WHERE id = '${sqlEscape(noteId)}';`);
  try {
    const target = questionTargetFor(sourceTextForGeneration(note, 9000));
    const result = await gemmaJSON(quizPromptFor(note, target));
    let saved = saveQuestions(noteId, result.summary, result.questions || []);
    const minimum = minimumQuestionBankFor(note);
    if (saved < minimum) {
      const backfill = await gemmaJSON(coverageBackfillPromptFor(note, minimum - saved), 90000);
      saved += insertQuestions(noteId, backfill.questions || [], "initial_coverage_backfill");
    }
    enqueueQuizForNote(noteId, "starter");
    recordModelRun({
      noteId,
      task: "initial_quiz_build",
      promptVersion: "web.initial_quiz_build.v2",
      status: "ok",
      detail: `Saved ${saved} questions. Minimum viable bank: ${minimum}.`
    });
    return { saved, status: "ready" };
  } catch (error) {
    sqlite(`UPDATE notes SET status = 'new' WHERE id = '${sqlEscape(noteId)}';`);
    recordModelRun({
      noteId,
      task: "initial_quiz_build",
      promptVersion: "web.initial_quiz_build.v2",
      status: "error",
      detail: error.message || "Initial build failed."
    });
    return { saved: 0, status: "error", error: error.message || "Initial build failed." };
  }
}

function queueInitialQuiz(noteId) {
  if (initialBuildInFlight.has(noteId)) {
    return { status: "already_preparing", saved: 0 };
  }
  if (initialBuildInFlight.size > 0) {
    return { status: "deferred", saved: 0 };
  }
  if (queuedQuizCount(noteId) > 0) {
    return { status: "already_ready", saved: 0 };
  }
  const note = noteSummary(noteId);
  if (!note) return { status: "missing_note", saved: 0 };
  if (note.questionCount > 0) {
    const queued = enqueueQuizForNote(noteId, "starter");
    if (queued.status === "empty" || queued.status === "insufficient_viable_questions") {
      return queueNextQuiz(noteId, [], {
        force: true,
        reason: queued.status === "empty" ? "no_ready_quiz_unlock" : "low_question_bank"
      });
    }
    return queued;
  }
  initialBuildInFlight.add(noteId);
  prepareInitialQuiz(noteId)
    .catch((error) => {
      recordModelRun({
        noteId,
        task: "initial_quiz_build",
        promptVersion: "web.initial_quiz_build.v2",
        status: "error",
        detail: error.message || "Initial build failed."
      });
    })
    .finally(() => initialBuildInFlight.delete(noteId));
  return { status: "preparing", saved: 0 };
}

function consumeQueuedQuiz(noteId) {
  const queued = readyQueue(noteId);
  if (!queued) return null;
  let ids = [];
  try {
    ids = JSON.parse(queued.question_ids || "[]");
  } catch {
    ids = [];
  }
  const quiz = rowsToQuiz(questionRowsByIds(noteId, ids));
  sqlite(`
    UPDATE quiz_queue
    SET state = 'consumed',
        consumed_at = ${Date.now() / 1000}
    WHERE id = '${sqlEscape(queued.id)}';
  `);
  return { quiz, queue: queued };
}

function startQuiz(noteId) {
  let note = noteSummary(noteId);
  if (!note) return { questions: [], nextQuiz: { status: "missing_note", saved: 0 } };
  if (note.status === "building" && !initialBuildInFlight.has(noteId) && !expansionInFlight.has(noteId) && Number(note.questionCount || 0) > 0) {
    sqlite(`UPDATE notes SET status = 'ready' WHERE id = '${sqlEscape(noteId)}';`);
    note = noteSummary(noteId);
  }
  let queuedQuiz = consumeQueuedQuiz(noteId);
  if (!queuedQuiz && (note.status === "building" || initialBuildInFlight.has(noteId) || expansionInFlight.has(noteId))) {
    return { questions: [], nextQuiz: { status: "preparing", saved: 0 } };
  }
  if (!queuedQuiz && note.questionCount > 0 && noteNeedsQuestionBackfill(note)) {
    sqlite(`DELETE FROM quiz_queue WHERE note_id = '${sqlEscape(noteId)}' AND state = 'ready';`);
    return {
      questions: [],
      nextQuiz: queueNextQuiz(noteId, [], {
        force: true,
        reason: "low_question_bank"
      })
    };
  }
  if (!queuedQuiz) {
    const queued = queueInitialQuiz(noteId);
    if (queued.status === "ready" || queued.status === "already_ready") {
      queuedQuiz = consumeQueuedQuiz(noteId);
    } else if (queued.status === "insufficient_viable_questions") {
      return {
        questions: [],
        nextQuiz: queueNextQuiz(noteId, [], {
          force: true,
          reason: "low_question_bank"
        })
      };
    } else {
      return { questions: [], nextQuiz: queued };
    }
  }
  const quiz = queuedQuiz?.quiz || [];
  recordQuizStarted(noteId, quiz || []);
  return {
    questions: quiz || [],
    nextQuiz: null,
    queue: queuedQuiz?.queue ? {
      id: queuedQuiz.queue.id,
      reason: queuedQuiz.queue.reason,
      summary: queuedQuiz.queue.summary
    } : null
  };
}

function startFocusedQuiz(noteId, focus) {
  const cleanFocus = String(focus || "").trim();
  if (!cleanFocus) return startQuiz(noteId);
  sqlite(`DELETE FROM quiz_queue WHERE note_id = '${sqlEscape(noteId)}' AND state = 'ready';`);
  const queued = enqueueQuizForNote(noteId, `focus:${cleanFocus}`, { focus: cleanFocus });
  if (queued.status === "ready") return startQuiz(noteId);
  return {
    questions: [],
    nextQuiz: queueNextQuiz(noteId, [], {
      force: true,
      reason: "focused_quiz",
      focus: cleanFocus
    })
  };
}

function quizFocusOptions(noteId) {
  const topicRows = sqlite(`
    SELECT
      topic,
      COUNT(*) AS question_count,
      COALESCE(AVG(understanding_score), 0) AS average_score
    FROM questions
    WHERE note_id = '${sqlEscape(noteId)}'
      AND TRIM(topic) <> ''
    GROUP BY topic
    ORDER BY topic COLLATE NOCASE
  `, { json: true }).map((row) => ({
    type: "topic",
    value: row.topic || "",
    topic: row.topic || "Topic",
    subtopic: "",
    questionCount: Number(row.question_count || 0),
    averageScore: Number(row.average_score || 0)
  })).filter((row) => row.value);

  const subtopicRows = sqlite(`
    SELECT
      topic,
      subtopic,
      COUNT(*) AS question_count,
      COALESCE(AVG(understanding_score), 0) AS average_score
    FROM questions
    WHERE note_id = '${sqlEscape(noteId)}'
      AND TRIM(topic) <> ''
      AND TRIM(subtopic) <> ''
    GROUP BY topic, subtopic
    ORDER BY topic COLLATE NOCASE, subtopic COLLATE NOCASE
  `, { json: true }).map((row) => ({
    type: "subtopic",
    value: `${row.topic || ""} ${row.subtopic || ""}`.trim(),
    topic: row.topic || "Topic",
    subtopic: row.subtopic || "Concept",
    questionCount: Number(row.question_count || 0),
    averageScore: Number(row.average_score || 0)
  })).filter((row) => row.value);

  const seen = new Set();
  return [...topicRows, ...subtopicRows].filter((row) => {
    const key = `${row.type}:${normalizeText(row.value)}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function repairMissingQuizQueues() {
  ensureAutomaticQueues();
}

function ensureAutomaticQueues() {
  const newNotes = sqlite(`
    SELECT n.id
    FROM notes n
    WHERE n.status = 'new'
      AND (SELECT COUNT(*) FROM questions q WHERE q.note_id = n.id) = 0
    ORDER BY n.created_at
    LIMIT 1
  `, { json: true });
  for (const note of newNotes) {
    queueInitialQuiz(note.id);
  }

  const notes = sqlite(`
    SELECT n.id
    FROM notes n
    LEFT JOIN quiz_queue qq ON qq.note_id = n.id AND qq.state = 'ready'
    WHERE n.status = 'ready'
    GROUP BY n.id
    HAVING COUNT(qq.id) = 0
      AND (SELECT COUNT(*) FROM questions q WHERE q.note_id = n.id) > 0
  `, { json: true });
  for (const note of notes) {
    enqueueQuizForNote(note.id, "startup_repair");
  }

  const lowBanks = sqlite(`
    SELECT n.id
    FROM notes n
    WHERE n.status = 'ready'
      AND (SELECT COUNT(*) FROM questions q WHERE q.note_id = n.id) > 0
      AND (SELECT COUNT(*) FROM questions q WHERE q.note_id = n.id) < 5
    ORDER BY n.created_at
    LIMIT 1
  `, { json: true });
  for (const note of lowBanks) {
    queueInitialQuiz(note.id);
  }
}

function updateConceptMemory(noteId, question, score) {
  const signature = question.concept_signature || conceptSignature(question);
  const existing = sqlite(`
    SELECT * FROM concept_memory
    WHERE note_id = '${sqlEscape(noteId)}'
      AND concept_signature = '${sqlEscape(signature)}'
  `, { json: true })[0];
  const attempts = Number(existing?.attempts || 0) + 1;
  const previousAverage = Number(existing?.average_score || 0);
  const average = ((previousAverage * (attempts - 1)) + Number(score || 0)) / attempts;
  sqlite(`
    INSERT OR REPLACE INTO concept_memory (
      note_id, concept_signature, topic, subtopic, attempts, average_score, latest_score, last_seen
    ) VALUES (
      '${sqlEscape(noteId)}',
      '${sqlEscape(signature)}',
      '${sqlEscape(question.topic || "Topic")}',
      '${sqlEscape(question.subtopic || "Subtopic")}',
      ${attempts},
      ${average},
      ${Number(score || 0)},
      ${Date.now() / 1000}
    );
  `);
}

function updateLearningMemory(noteId, question, variant, score) {
  const questionId = question.id;
  const rows = sqlite(`
    SELECT
      a.score,
      a.created_at,
      COALESCE(v.delivery_type, 'multiple_choice') AS delivery_type
    FROM attempts a
    LEFT JOIN question_variants v ON v.id = a.variant_id
    WHERE a.question_id = '${sqlEscape(questionId)}'
    ORDER BY a.created_at DESC
  `, { json: true });
  const attemptCount = rows.length;
  const average = attemptCount
    ? rows.reduce((sum, row) => sum + Number(row.score || 0), 0) / attemptCount
    : Number(score || 0);
  const latest = Number(score || 0);
  const deliveryTypes = new Set(rows.map((row) => row.delivery_type || "multiple_choice"));
  if (variant?.delivery_type) deliveryTypes.add(variant.delivery_type);
  const mcRows = rows.filter((row) => (row.delivery_type || "multiple_choice") === "multiple_choice");
  const shortRows = rows.filter((row) => row.delivery_type === "short_answer");
  const mcScore = mcRows.length ? mcRows.reduce((sum, row) => sum + Number(row.score || 0), 0) / mcRows.length : 0;
  const shortScore = shortRows.length ? shortRows.reduce((sum, row) => sum + Number(row.score || 0), 0) / shortRows.length : 0;
  const varietyBonus = Math.min(1, deliveryTypes.size / 2);
  const understanding = Math.max(0, Math.min(1, (latest * 0.4) + (average * 0.35) + (varietyBonus * 0.15) + (Number(question.difficulty || 1) * 0.1)));
  const masteryState = understanding >= 0.95 && deliveryTypes.size >= 2
    ? "mastered"
    : understanding >= 0.8
      ? "strong"
      : latest > average
        ? "improving"
        : average < 0.5 && attemptCount > 1
          ? "weak"
          : "learning";
  const weaknessReason = masteryState === "weak"
    ? "Recent attempts show this question is still unstable."
    : deliveryTypes.size < 2
      ? "Needs another delivery type before mastery."
      : "";

  sqlite(`
    INSERT OR REPLACE INTO learning_memory (
      question_id, concept_id, note_id, latest_score, average_score, attempt_count,
      multiple_choice_score, short_answer_score, delivery_variety, weakness_reason,
      next_due_at, mastery_state, updated_at
    ) VALUES (
      '${sqlEscape(questionId)}',
      '${sqlEscape(question.concept_id || "")}',
      '${sqlEscape(noteId)}',
      ${latest},
      ${average},
      ${attemptCount},
      ${mcScore},
      ${shortScore},
      ${deliveryTypes.size},
      '${sqlEscape(weaknessReason)}',
      ${Date.now() / 1000 + (masteryState === "mastered" ? 604800 : masteryState === "strong" ? 259200 : 86400)},
      '${sqlEscape(masteryState)}',
      ${Date.now() / 1000}
    );
  `);
  sqlite(`
    UPDATE questions
    SET understanding_score = ${understanding},
        mastery_state = '${sqlEscape(masteryState)}',
        last_seen_at = ${Date.now() / 1000}
    WHERE id = '${sqlEscape(questionId)}';
  `);
  if (question.concept_id) {
    sqlite(`
      UPDATE concepts
      SET understanding_score = (
            SELECT COALESCE(AVG(understanding_score), 0)
            FROM questions
            WHERE concept_id = '${sqlEscape(question.concept_id)}'
          ),
          mastery_state = CASE
            WHEN (
              SELECT COALESCE(MIN(understanding_score), 0)
              FROM questions
              WHERE concept_id = '${sqlEscape(question.concept_id)}'
            ) >= 0.95 THEN 'mastered'
            ELSE 'learning'
          END,
          last_tested_at = ${Date.now() / 1000}
      WHERE id = '${sqlEscape(question.concept_id)}';
    `);
  }
}

function saveAnswerEvaluation({ attemptId, question, noteId, score, verdict, matchedIdeas = [], missingIdeas = [] }) {
  sqlite(`
    INSERT INTO answer_evaluations (
      id, attempt_id, question_id, note_id, score, verdict,
      matched_ideas, missing_ideas, model_name, prompt_version, created_at
    ) VALUES (
      '${crypto.randomUUID()}',
      '${sqlEscape(attemptId)}',
      '${sqlEscape(question.id)}',
      '${sqlEscape(noteId)}',
      ${Number(score || 0)},
      '${sqlEscape(verdict)}',
      '${sqlEscape(JSON.stringify(matchedIdeas))}',
      '${sqlEscape(JSON.stringify(missingIdeas))}',
      '${sqlEscape(gemmaModel)}',
      'local_multiple_choice.v1',
      ${Date.now() / 1000}
    );
  `);
}

function saveQuizMemory({ noteId, quizId = "", title = "", reason = "", questions = [], details = [], promptVersion = "quiz_memory.web.v1" }) {
  const targetConcepts = [...new Set(questions.map((question) => canonicalConceptKey(question)).filter(Boolean))];
  const avoidedConcepts = [...new Set(details
    .filter((detail) => Number(detail.score || 0) >= 0.9)
    .map((detail) => detail.canonicalConceptKey || canonicalConceptKey(detail))
    .filter(Boolean))];
  const questionMix = questions.reduce((mix, question) => {
    const angle = question.assessmentAngle || question.assessment_angle || "recall";
    mix[angle] = (mix[angle] || 0) + 1;
    return mix;
  }, {});
  sqlite(`
    INSERT INTO quiz_memory (
      id, quiz_id, note_id, title, selected_focus, reason,
      target_concepts, avoided_concepts, question_mix, model_name, prompt_version, created_at
    ) VALUES (
      '${crypto.randomUUID()}',
      '${sqlEscape(quizId)}',
      '${sqlEscape(noteId)}',
      '${sqlEscape(title)}',
      NULL,
      '${sqlEscape(reason)}',
      '${sqlEscape(JSON.stringify(targetConcepts))}',
      '${sqlEscape(JSON.stringify(avoidedConcepts))}',
      '${sqlEscape(JSON.stringify(questionMix))}',
      '${sqlEscape(gemmaModel)}',
      '${sqlEscape(promptVersion)}',
      ${Date.now() / 1000}
    );
  `);
}

function conceptSetFingerprintFromKeys(keys) {
  return [...new Set((keys || []).map(String).filter(Boolean))].sort().join("||");
}

function quizConceptSetFingerprint(questions) {
  return conceptSetFingerprintFromKeys((questions || []).map((question) => canonicalConceptKey(question)));
}

function recentMasteredQuizFingerprints(noteId) {
  return new Set(sqlite(`
    SELECT qm.target_concepts
    FROM quiz_memory qm
    JOIN quiz_sessions qs ON qs.id = qm.quiz_id
    WHERE qm.note_id = '${sqlEscape(noteId)}'
      AND qm.title = 'Completed quiz'
      AND qs.score >= 0.999
    ORDER BY qm.created_at DESC
    LIMIT 12
  `, { json: true }).map((row) => {
    try {
      return conceptSetFingerprintFromKeys(JSON.parse(row.target_concepts || "[]"));
    } catch {
      return "";
    }
  }).filter(Boolean));
}

function quizExpansionPromptFor(note, details, target, options = {}) {
  const existing = sqlite(`
    SELECT
      q.topic,
      q.subtopic,
      q.assessment_angle,
      q.prompt,
      q.answer,
      COALESCE(lm.average_score, 0) AS average_score,
      COALESCE(lm.mastery_state, 'new') AS mastery_state,
      COALESCE(lm.weakness_reason, '') AS weakness_reason
    FROM questions q
    LEFT JOIN learning_memory lm ON lm.question_id = q.id
    WHERE q.note_id = '${sqlEscape(note.id)}'
    ORDER BY q.created_at DESC
    LIMIT 80
  `, { json: true });
  const recentAssigned = sqlite(`
    SELECT
      a.topic_snapshot AS topic,
      a.subtopic_snapshot AS subtopic,
      a.prompt_snapshot AS prompt,
      a.answer_snapshot AS answer,
      a.response,
      a.score,
      a.created_at
    FROM attempts a
    WHERE a.note_id = '${sqlEscape(note.id)}'
    ORDER BY a.created_at DESC
    LIMIT 30
  `, { json: true });
  const weak = details
    .filter((item) => item.score < 1)
    .map((item) => ({
      topic: item.topic,
      subtopic: item.subtopic,
      prompt: item.prompt,
      learner_answer: item.response,
      correct_answer: item.answer
    }));
  const quizScore = details.length
    ? details.reduce((sum, item) => sum + Number(item.score || 0), 0) / details.length
    : 0;
  const uncovered = uncoveredNotePassages(note, existing);

  if (options.force) {
    const mastered = details.map((item) => ({
      topic: item.topic,
      subtopic: item.subtopic,
      prompt: item.prompt,
      answer: item.answer,
      concept: item.canonicalConceptKey || canonicalConceptKey(item)
    }));
    const existingAnswers = existing.map((item) => ({
      topic: item.topic,
      subtopic: item.subtopic,
      prompt: item.prompt,
      answer: item.answer,
      answer_key: answerMemoryKey(item),
      concept_key: canonicalConceptKey(item)
    }));
    return `
You are Accordian's mastery-expansion agent.
Use ONLY the note text. Return valid JSON only.

The learner mastered the concepts below. Create ${target} harder or adjacent question objects from the same note.
Do not repeat any existing prompt. Do not ask the same fact in the same way.
Do not return a question whose correct answer is equivalent to an existing answer.
Do not turn a mastered answer into a new prompt. Move to a fresh adjacent concept from the note.
Prioritize the untapped note passages. They are the evidence SQLite found that is least covered by prior questions.
Prefer comparison, sequence, consequence, and application checks over basic recall.
For math notes, at least half of the questions must require calculation with concrete numbers.
For math notes, do not ask meta questions about what the learner wants to practice or what is listed in a section.
Every question must be answerable from the note text.
Every question needs one multiple_choice variant with exactly 4 choices and the exact answer included.

Return exactly:
{
  "questions": [
    {
      "topic": "broad topic",
      "concept": "specific concept",
      "source_excerpt": "exact evidence from the note",
      "assessment_angle": "comparison | sequence | consequence | application | cause | detail",
      "canonical_prompt": "harder note-backed prompt",
      "canonical_answer": "short source-backed answer",
      "accepted_answers": ["equivalent answer"],
      "importance": 1,
      "difficulty": 1.2,
      "variants": [
        {
          "delivery_type": "multiple_choice",
          "prompt": "MC prompt",
          "answer": "correct choice",
          "choices": ["correct choice", "plausible distractor", "plausible distractor", "plausible distractor"],
          "rubric": "what understanding this tests"
        }
      ]
    }
  ]
}

MASTERED CONCEPTS:
${JSON.stringify(mastered, null, 2)}

RECENT ASSIGNED QUESTIONS AND RESULTS:
${JSON.stringify(recentAssigned, null, 2)}

EXISTING QUESTIONS AND ANSWERS TO AVOID:
${JSON.stringify(existingAnswers.slice(0, 40), null, 2)}

UNTAPPED NOTE PASSAGES TO TARGET FIRST:
${JSON.stringify(uncovered, null, 2)}

NOTE TITLE:
${note.title}

NOTE TEXT:
${sourceTextForGeneration(note, 3000)}
`;
  }

  const learningContext = learningContextForNote(note.id);

  return `
You are Accordian's learning-object expansion agent.
Use ONLY the note text. Do not use outside facts.
Create ${target} fresh durable question objects for the NEXT quiz.
Expansion reason: ${options.reason || "post_quiz_expansion"}.

Goals:
- Address the learner's missed concepts with adjacent questions, not duplicates.
- Add new important concepts from the note that are not covered by existing questions.
- Build from basic recall toward application and comparison when the note supports it.
- For cause/effect or sequence questions, the answer must be temporally consistent with the note. A later event cannot cause an earlier event.
- Avoid all existing prompts and avoid trivial wording changes.
- Avoid repeating recent assigned concepts unless the learner missed that exact concept.
- Prioritize the untapped note passages from SQLite before creating any question from already-covered areas.
- If the latest quiz score is 100%, create adjacent or harder concepts from the note instead of repeating mastered concepts.
- If expansion reason is mastered_repeat_suppressed, the learner already mastered the selected concepts. Generate harder, adjacent, or more integrative checks from the note. Do not return any question that tests the same answer in the same way.
- Prefer one durable question per distinct concept. Do not create multiple questions whose correct answer is the same fact.
- For math notes, at least half of the questions must require calculation with concrete numbers.
- For math notes, do not ask meta questions about what the learner wants to practice or what is listed in a section.
- Include a multiple_choice variant for every question.
- Include a short_answer variant when useful.
- Every multiple_choice variant must have exactly 4 choices and one exact answer present in choices.

Return only JSON:
{
  "questions": [
    {
      "topic": "broad topic",
      "concept": "specific concept",
      "source_excerpt": "exact note-backed text this question tests",
      "assessment_angle": "definition | cause | sequence | comparison | consequence | application | detail",
      "canonical_prompt": "stable question object",
      "canonical_answer": "source-backed answer",
      "accepted_answers": ["equivalent answer"],
      "importance": 0.8,
      "difficulty": 0.6,
      "variants": [
        {
          "delivery_type": "multiple_choice",
          "prompt": "MC prompt",
          "answer": "correct choice",
          "choices": ["correct choice", "distractor", "distractor", "distractor"],
          "rubric": "what must be known"
        },
        {
          "delivery_type": "short_answer",
          "prompt": "short answer prompt",
          "answer": "expected answer",
          "choices": [],
          "rubric": "main ideas required"
        }
      ]
    }
  ]
}

MISSED CONCEPTS:
${JSON.stringify(weak, null, 2)}

LATEST QUIZ SCORE:
${quizScore}

RECENT ASSIGNED QUESTIONS AND RESULTS:
${JSON.stringify(recentAssigned, null, 2)}

LEARNING CONTEXT OBJECT FROM SQLITE:
${JSON.stringify(learningContext, null, 2)}

EXISTING QUESTIONS TO AVOID:
${JSON.stringify(existing.slice(0, 60), null, 2)}

UNTAPPED NOTE PASSAGES TO TARGET FIRST:
${JSON.stringify(uncovered, null, 2)}

NOTE TITLE:
${note.title}

NOTE TEXT:
${sourceTextForGeneration(note, 6000)}
`;
}

function coverageBackfillPromptFor(note, target) {
  const existing = sqlite(`
    SELECT topic, subtopic, prompt, answer
    FROM questions
    WHERE note_id = '${sqlEscape(note.id)}'
    ORDER BY created_at DESC
    LIMIT 120
  `, { json: true });
  const uncovered = uncoveredNotePassages(note, existing);
  const existingAnswers = existing
    .map((item) => answerMemoryKey(item))
    .filter(Boolean)
    .slice(0, 40);
  return `
You are Accordian's coverage backfill agent.
Use ONLY UNTAPPED_PASSAGES. Create exactly ${target} fresh multiple-choice question objects.
Do not reuse or paraphrase any EXISTING_ANSWER_KEYS.
For cause/effect or sequence questions, the answer must be temporally consistent with the source passage. A later event cannot cause an earlier event.
For math notes, create real calculation or procedure questions with concrete numbers, not meta practice-plan questions.
Each question needs exactly 4 choices and one exact answer present in choices.
Incorrect choices must be false for the source excerpt. Do not use another true item from the same list as a distractor.
Return JSON only:
{
  "questions": [
    {
      "topic": "broad topic",
      "concept": "specific concept",
      "source_excerpt": "exact evidence",
      "assessment_angle": "definition | cause | sequence | comparison | consequence | application | detail",
      "canonical_prompt": "question",
      "canonical_answer": "answer",
      "importance": 1,
      "difficulty": 0.8,
      "variants": [
        {
          "delivery_type": "multiple_choice",
          "prompt": "MC prompt",
          "answer": "correct choice",
          "choices": ["correct choice", "plausible distractor", "plausible distractor", "plausible distractor"],
          "rubric": "what understanding this tests"
        }
      ]
    }
  ]
}

EXISTING_ANSWER_KEYS:
${JSON.stringify(existingAnswers)}

UNTAPPED_PASSAGES:
${JSON.stringify(uncovered.slice(0, 5).map((item) => item.text), null, 2)}

NOTE TITLE:
${note.title}
`;
}

async function prepareNextQuiz(noteId, details, options = {}) {
  const note = noteSummary(noteId);
  if (!note) return { saved: 0, status: "missing_note" };
  const missCount = details.filter((item) => item.score < 1).length;
  const currentCount = Number(note.questionCount || 0);
  const maxCount = Math.max(questionTargetFor(sourceTextForGeneration(note, 9000)) * 2, 24);
  if (!options.force && currentCount >= maxCount && missCount === 0) {
    const queued = enqueueQuizForNote(noteId, "scheduled");
    return { saved: queued.saved || 0, status: queued.status === "empty" ? "enough_questions" : queued.status };
  }

  const target = options.force
    ? Math.min(8, Math.max(6, Math.ceil(questionTargetFor(sourceTextForGeneration(note, 9000)) / 3)))
    : Math.min(6, Math.max(4, missCount, Math.ceil(questionTargetFor(sourceTextForGeneration(note, 9000)) / 4)));
  sqlite(`UPDATE notes SET status = 'building' WHERE id = '${sqlEscape(noteId)}';`);
  try {
    const backfillOnly = options.reason === "no_ready_quiz_unlock" || options.reason === "low_question_bank";
    const result = await gemmaJSON(backfillOnly
      ? coverageBackfillPromptFor(note, target)
      : quizExpansionPromptFor(note, details, target, options),
      backfillOnly ? 90000 : 120000);
    let saved = insertQuestions(noteId, result.questions || [], backfillOnly
      ? "coverage_backfill"
      : options.force ? "mastery_expansion" : "post_quiz_expansion");
    if (saved === 0 && !backfillOnly) {
      const backfill = await gemmaJSON(coverageBackfillPromptFor(note, target), 90000);
      saved = insertQuestions(noteId, backfill.questions || [], "coverage_backfill");
    }
    const refreshed = noteSummary(noteId);
    const queued = noteNeedsQuestionBackfill(refreshed)
      ? { status: "insufficient_bank", saved: 0 }
      : enqueueQuizForNote(noteId, options.force ? "mastery_expansion" : "follow_up", { focus: options.focus || "" });
    if (queued.status === "insufficient_bank" || queued.status === "insufficient_viable_questions") {
      sqlite(`DELETE FROM quiz_queue WHERE note_id = '${sqlEscape(noteId)}' AND state = 'ready';`);
    }
    sqlite(`UPDATE notes SET status = 'ready' WHERE id = '${sqlEscape(noteId)}';`);
    recordModelRun({
      noteId,
      task: options.force ? "mastery_expansion" : "post_quiz_expansion",
      promptVersion: options.force ? "web.quiz_mastery_expansion.v1" : "web.quiz_expansion.v1",
      status: "ok",
      detail: `Saved ${saved} fresh questions.`
    });
    return { saved, status: queued.status === "empty" ? "ok" : queued.status };
  } catch (error) {
    enqueueQuizForNote(noteId, "recovery");
    sqlite(`UPDATE notes SET status = 'ready' WHERE id = '${sqlEscape(noteId)}';`);
    recordModelRun({
      noteId,
      task: options.force ? "mastery_expansion" : "post_quiz_expansion",
      promptVersion: options.force ? "web.quiz_mastery_expansion.v1" : "web.quiz_expansion.v1",
      status: "error",
      detail: error.message || "Expansion failed."
    });
    return { saved: 0, status: "error", error: error.message || "Expansion failed." };
  }
}

function queueNextQuiz(noteId, details, options = {}) {
  if (expansionInFlight.has(noteId)) {
    return { status: "already_preparing", saved: 0 };
  }
  expansionInFlight.add(noteId);
  prepareNextQuiz(noteId, details, options)
    .catch((error) => {
      recordModelRun({
        noteId,
        task: options.force ? "mastery_expansion" : "post_quiz_expansion",
        promptVersion: options.force ? "web.quiz_mastery_expansion.v1" : "web.quiz_expansion.v1",
        status: "error",
        detail: error.message || "Expansion failed."
      });
    })
    .finally(() => expansionInFlight.delete(noteId));
  return { status: "preparing", saved: 0 };
}

async function submitQuiz(noteId, answers) {
  const attemptIds = [];
  let earned = 0;
  let possible = 0;
  const details = [];

  for (const answer of answers) {
    const question = sqlite(`
      SELECT * FROM questions WHERE id = '${sqlEscape(answer.questionId)}' AND note_id = '${sqlEscape(noteId)}'
    `, { json: true })[0];
    if (!question) continue;
    const variant = answer.variantId
      ? sqlite(`
        SELECT * FROM question_variants
        WHERE id = '${sqlEscape(answer.variantId)}'
          AND question_id = '${sqlEscape(answer.questionId)}'
      `, { json: true })[0]
      : null;
    const expectedAnswer = variant?.answer || question.answer;
    const promptSnapshot = variant?.prompt || question.prompt;
    const score = answer.response === expectedAnswer ? 1 : 0;
    const feedback = score === 1
      ? "Correct. Keep moving."
      : `Review this idea. Correct answer: ${expectedAnswer}`;
    const id = crypto.randomUUID();
    attemptIds.push(id);
    earned += score * Number(question.importance || 1) * Number(question.difficulty || 1);
    possible += Number(question.importance || 1) * Number(question.difficulty || 1);
    sqlite(`
      INSERT INTO attempts (
        id, question_id, variant_id, note_id, topic_snapshot, subtopic_snapshot,
        prompt_snapshot, answer_snapshot, response, score, feedback,
        matched_ideas, missing_ideas, created_at
      )
      VALUES (
        '${id}',
        '${sqlEscape(question.id)}',
        '${sqlEscape(variant?.id || "")}',
        '${sqlEscape(noteId)}',
        '${sqlEscape(question.topic)}',
        '${sqlEscape(question.subtopic)}',
        '${sqlEscape(promptSnapshot)}',
        '${sqlEscape(expectedAnswer)}',
        '${sqlEscape(answer.response || "")}',
        ${score},
        '${sqlEscape(feedback)}',
        '${sqlEscape(JSON.stringify(score === 1 ? [expectedAnswer] : []))}',
        '${sqlEscape(JSON.stringify(score === 1 ? [] : [expectedAnswer]))}',
        ${Date.now() / 1000}
      );
    `);
    saveAnswerEvaluation({
      attemptId: id,
      question,
      noteId,
      score,
      verdict: feedback,
      matchedIdeas: score === 1 ? [expectedAnswer] : [],
      missingIdeas: score === 1 ? [] : [expectedAnswer]
    });
    details.push({
      questionId: question.id,
      variantId: variant?.id || "",
      topic: question.topic,
      subtopic: question.subtopic,
      prompt: promptSnapshot,
      response: answer.response,
      answer: expectedAnswer,
      score,
      feedback,
      canonicalConceptKey: canonicalConceptKey(question)
    });
    recordUserAction({
      noteId,
      actionType: "answer.submitted",
      objectType: "attempt",
      objectId: id,
      payload: {
        questionId: question.id,
        variantId: variant?.id || "",
        prompt: promptSnapshot,
        response: answer.response || "",
        expectedAnswer,
        score,
        canonicalConceptKey: canonicalConceptKey(question)
      }
    });
    updateConceptMemory(noteId, question, score);
    updateLearningMemory(noteId, question, variant, score);
  }

  const score = possible === 0 ? 0 : earned / possible;
  const sessionId = crypto.randomUUID();
  sqlite(`
    INSERT INTO quiz_sessions (id, note_id, score, attempt_ids, created_at)
    VALUES (
      '${sessionId}',
      '${sqlEscape(noteId)}',
      ${score},
      '${sqlEscape(attemptIds.join("\n"))}',
      ${Date.now() / 1000}
    );
  `);
  recordUserAction({
    noteId,
    actionType: "quiz.completed",
    objectType: "quiz_session",
    objectId: sessionId,
    payload: {
      score,
      attemptIds,
      details
    }
  });
  saveQuizMemory({
    noteId,
    quizId: sessionId,
    title: "Completed quiz",
    reason: "Saved completed quiz outcome and concept avoidance signals.",
    questions: details,
    details,
    promptVersion: "quiz_completed.web.v1"
  });

  const nextQuiz = queueNextQuiz(noteId, details, score >= 0.999
    ? { force: true, reason: "perfect_score_mastery_unlock" }
    : {});
  const missed = details.filter((detail) => Number(detail.score || 0) < 1);
  const mastered = details.filter((detail) => Number(detail.score || 0) >= 1);
  const learningEvidence = {
    summary: missed.length > 0
      ? `Accordian saved ${missed.length} missed idea${missed.length === 1 ? "" : "s"} and is preparing related checks.`
      : `Accordian saved ${mastered.length} mastered idea${mastered.length === 1 ? "" : "s"} and is preparing fresh or harder checks.`,
    masteredConcepts: mastered.map((detail) => conceptRootKey(detail)).filter(Boolean),
    missedConcepts: missed.map((detail) => conceptRootKey(detail)).filter(Boolean)
  };
  return { id: sessionId, score, details, nextQuiz, learningEvidence };
}

function history(noteId) {
  return sqlite(`
    SELECT
      s.*,
      n.title AS note_title
    FROM quiz_sessions s
    LEFT JOIN notes n ON n.id = s.note_id
    WHERE s.note_id = '${sqlEscape(noteId)}'
    ORDER BY s.created_at DESC
    LIMIT 20
  `, { json: true }).map((session) => ({
    id: session.id,
    noteId: session.note_id,
    noteTitle: session.note_title || "Untitled Note",
    score: Number(session.score || 0),
    createdAt: Number(session.created_at || 0)
  }));
}

function allHistory() {
  return sqlite(`
    SELECT
      s.*,
      n.title AS note_title
    FROM quiz_sessions s
    LEFT JOIN notes n ON n.id = s.note_id
    ORDER BY s.created_at DESC
    LIMIT 80
  `, { json: true }).map((session) => ({
    id: session.id,
    noteId: session.note_id,
    noteTitle: session.note_title || "Untitled Note",
    score: Number(session.score || 0),
    createdAt: Number(session.created_at || 0)
  }));
}

function sessionDetail(sessionId) {
  const session = sqlite(`
    SELECT
      s.*,
      n.title AS note_title
    FROM quiz_sessions s
    LEFT JOIN notes n ON n.id = s.note_id
    WHERE s.id = '${sqlEscape(sessionId)}'
  `, { json: true })[0];

  if (!session) return null;

  const attemptIds = String(session.attempt_ids || "")
    .split(/\n+/)
    .map((id) => id.trim())
    .filter(Boolean);

  const idList = attemptIds.map((id) => `'${sqlEscape(id)}'`).join(",");
  const attempts = idList
    ? sqlite(`
      SELECT
        a.id,
        a.response,
        a.score,
        a.feedback,
        a.created_at,
        COALESCE(q.topic, NULLIF(a.topic_snapshot, '')) AS topic,
        COALESCE(q.subtopic, NULLIF(a.subtopic_snapshot, '')) AS subtopic,
        COALESCE(q.prompt, NULLIF(a.prompt_snapshot, '')) AS prompt,
        COALESCE(q.answer, NULLIF(a.answer_snapshot, '')) AS answer
      FROM attempts a
      LEFT JOIN questions q ON q.id = a.question_id
      WHERE a.id IN (${idList})
    `, { json: true })
    : [];

  const order = new Map(attemptIds.map((id, index) => [id, index]));
  attempts.sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));

  return {
    id: session.id,
    noteId: session.note_id,
    noteTitle: session.note_title || "Untitled Note",
    score: Number(session.score || 0),
    createdAt: Number(session.created_at || 0),
    attempts: attempts.map((attempt) => ({
      id: attempt.id,
      topic: attempt.topic || "Saved Attempt",
      subtopic: attempt.subtopic || "Earlier quiz",
      prompt: attempt.prompt || "Original question unavailable for this older attempt.",
      response: attempt.response || "",
      answer: attempt.answer || "See feedback",
      score: Number(attempt.score || 0),
      feedback: attempt.feedback || ""
    }))
  };
}

async function handleAPI(request, response, url) {
  if ((request.method === "GET" || request.method === "HEAD") && url.pathname === "/api/health") {
    return writeJSON(response, 200, {
      ok: true,
      mode: "web",
      model: gemmaModel,
      database: dbPath
    });
  }

  if (request.method === "GET" && url.pathname === "/api/notes") {
    return writeJSON(response, 200, { notes: listNotes() });
  }

  if (request.method === "GET" && url.pathname === "/api/model") {
    return writeJSON(response, 200, {
      mode: "ollama",
      endpoint: gemmaBaseURL,
      model: gemmaModel
    });
  }

  if (request.method === "GET" && url.pathname === "/api/backup") {
    return exportBackup(response);
  }

  if (request.method === "POST" && url.pathname === "/api/backup/restore") {
    return writeJSON(response, 200, await restoreBackup(request));
  }

  if (request.method === "GET" && url.pathname === "/api/quizzes") {
    return writeJSON(response, 200, { sessions: allHistory() });
  }

  if (request.method === "POST" && url.pathname === "/api/actions") {
    const body = await readJSON(request);
    recordUserAction({
      noteId: body.noteId || null,
      actionType: String(body.actionType || "ui.action"),
      objectType: String(body.objectType || ""),
      objectId: String(body.objectId || ""),
      payload: body.payload || {}
    });
    return writeJSON(response, 201, { ok: true });
  }

  if (request.method === "GET" && url.pathname === "/api/wiki/search") {
    const query = String(url.searchParams.get("q") || "").trim();
    if (query.length < 2) return writeJSON(response, 400, { error: "Search needs at least 2 characters." });
    return writeJSON(response, 200, { results: await searchWikipedia(query) });
  }

  if (request.method === "POST" && url.pathname === "/api/wiki/import") {
    const body = await readJSON(request);
    const title = String(body.title || "").trim();
    if (!title) return writeJSON(response, 400, { error: "Wikipedia title is required." });
    const article = await wikipediaArticle(title);
    const note = createNote(article.title, article.text);
    recordUserAction({
      noteId: note.id,
      actionType: "wikipedia.imported",
      objectType: "note",
      objectId: note.id,
      payload: { title: article.title }
    });
    queueInitialQuiz(note.id);
    return writeJSON(response, 201, { note: noteSummary(note.id), nextQuiz: { status: "preparing", saved: 0 } });
  }

  if (request.method === "POST" && url.pathname === "/api/notes/shape") {
    const body = await readJSON(request);
    const title = String(body.title || "Untitled Note").trim();
    const text = String(body.body || "").trim();
    const sourceType = String(body.sourceType || body.source_type || "text").trim();
    if (!text) return writeJSON(response, 400, { error: "Note text is required." });
    const shaped = await shapeNoteDraft({ title, body: text, sourceType });
    return writeJSON(response, 200, { note: shaped });
  }

  if (request.method === "POST" && url.pathname === "/api/notes") {
    const body = await readJSON(request);
    const title = String(body.title || "Untitled Note").trim();
    const text = String(body.body || "").trim();
    const sourceType = String(body.sourceType || body.source_type || "text").trim();
    if (!text) return writeJSON(response, 400, { error: "Note text is required." });
    const note = createNote(title, text, sourceType);
    queueInitialQuiz(note.id);
    return writeJSON(response, 201, { note: noteSummary(note.id), nextQuiz: { status: "preparing", saved: 0 } });
  }

  const noteMatch = url.pathname.match(/^\/api\/notes\/([^/]+)$/);
  if ((request.method === "PUT" || request.method === "PATCH") && noteMatch) {
    const noteId = noteMatch[1];
    const body = await readJSON(request);
    const title = String(body.title || "Untitled Note").trim();
    const text = String(body.body || "").trim();
    const sourceType = String(body.sourceType || body.source_type || "text").trim();
    if (!text) return writeJSON(response, 400, { error: "Note text is required." });
    const note = updateNote(noteId, title, text, sourceType);
    if (!note) return writeJSON(response, 404, { error: "Note not found." });
    queueInitialQuiz(note.id);
    return writeJSON(response, 200, { note: noteSummary(note.id), nextQuiz: { status: "preparing", saved: 0 } });
  }

  if (request.method === "DELETE" && noteMatch) {
    const noteId = noteMatch[1];
    const deleted = deleteNote(noteId);
    if (!deleted) return writeJSON(response, 404, { error: "Note not found." });
    return writeJSON(response, 200, { ok: true });
  }

  const buildMatch = url.pathname.match(/^\/api\/notes\/([^/]+)\/build$/);
  if (request.method === "POST" && buildMatch) {
    const noteId = buildMatch[1];
    const note = noteSummary(noteId);
    if (!note) return writeJSON(response, 404, { error: "Note not found." });
    const result = queueInitialQuiz(noteId);
    return writeJSON(response, 202, { note: noteSummary(noteId), nextQuiz: result });
  }

  const quizMatch = url.pathname.match(/^\/api\/notes\/([^/]+)\/quiz$/);
  if (request.method === "GET" && quizMatch) {
    const noteId = quizMatch[1];
    const focus = String(url.searchParams.get("focus") || "").trim();
    return writeJSON(response, 200, focus ? startFocusedQuiz(noteId, focus) : startQuiz(noteId));
  }

  const focusMatch = url.pathname.match(/^\/api\/notes\/([^/]+)\/focus-options$/);
  if (request.method === "GET" && focusMatch) {
    const noteId = focusMatch[1];
    return writeJSON(response, 200, { options: quizFocusOptions(noteId) });
  }

  const submitMatch = url.pathname.match(/^\/api\/notes\/([^/]+)\/quiz$/);
  if (request.method === "POST" && submitMatch) {
    const noteId = submitMatch[1];
    const body = await readJSON(request);
    return writeJSON(response, 200, await submitQuiz(noteId, body.answers || []));
  }

  const historyMatch = url.pathname.match(/^\/api\/notes\/([^/]+)\/history$/);
  if (request.method === "GET" && historyMatch) {
    return writeJSON(response, 200, { sessions: history(historyMatch[1]) });
  }

  const contextMatch = url.pathname.match(/^\/api\/notes\/([^/]+)\/learning-context$/);
  if (request.method === "GET" && contextMatch) {
    return writeJSON(response, 200, { context: learningContextForNote(contextMatch[1]) });
  }

  const sessionMatch = url.pathname.match(/^\/api\/quiz-sessions\/([^/]+)$/);
  if (request.method === "GET" && sessionMatch) {
    const session = sessionDetail(sessionMatch[1]);
    if (!session) return writeJSON(response, 404, { error: "Quiz session not found." });
    return writeJSON(response, 200, { session });
  }

  return writeJSON(response, 404, { error: "Not found." });
}

function serveStatic(response, pathname) {
  const filePath = pathname === "/" ? join(publicDir, "index.html") : join(publicDir, pathname);
  if (!filePath.startsWith(publicDir) || !existsSync(filePath)) {
    response.writeHead(404);
    response.end("Not found");
    return;
  }
  const type = {
    ".html": "text/html",
    ".css": "text/css",
    ".js": "application/javascript",
    ".svg": "image/svg+xml",
    ".webmanifest": "application/manifest+json"
  }[extname(filePath)] || "application/octet-stream";
  response.writeHead(200, { "content-type": type });
  response.end(readFileSync(filePath));
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  try {
    if (url.pathname.startsWith("/api/")) {
      await handleAPI(request, response, url);
      return;
    }
    serveStatic(response, decodeURIComponent(url.pathname));
  } catch (error) {
    writeJSON(response, 500, { error: error.message || "Server error" });
  }
});

repairMissingQuizQueues();

server.listen(port, host, () => {
  console.log(`Accordian web running at http://${host}:${port}`);
  console.log(`Gemma endpoint: ${gemmaBaseURL} (${gemmaModel})`);
});
