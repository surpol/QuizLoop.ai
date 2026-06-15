import http from "node:http";
import { readFileSync, existsSync, mkdirSync, writeFileSync, renameSync, unlinkSync, copyFileSync } from "node:fs";
import { extname, join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";

const __dirname = dirname(fileURLToPath(import.meta.url));

function loadLocalEnv() {
  const envPath = join(__dirname, ".env");
  if (!existsSync(envPath)) return;
  for (const line of readFileSync(envPath, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const splitIndex = trimmed.indexOf("=");
    if (splitIndex === -1) continue;
    const key = trimmed.slice(0, splitIndex).trim();
    const rawValue = trimmed.slice(splitIndex + 1).trim();
    if (!key || process.env[key] !== undefined) continue;
    process.env[key] = rawValue.replace(/^['"]|['"]$/g, "");
  }
}

loadLocalEnv();

const publicDir = join(__dirname, "public");
const dataDir = join(__dirname, "data");
const dbPath = process.env.QUIZLOOP_DB_PATH || process.env.ACCORDIAN_DB_PATH || join(dataDir, "quizloop.sqlite");
const port = Number(process.env.PORT || 4173);
const host = process.env.HOST || "127.0.0.1";
const gemmaBaseURL = process.env.GEMMA_BASE_URL || "http://127.0.0.1:11434";
const gemmaModel = process.env.GEMMA_MODEL || "gemma4:e2b";
const geminiApiKey = process.env.GEMINI_API_KEY || "";
const geminiModel = process.env.GEMINI_MODEL || "gemini-2.5-flash";
const expansionInFlight = new Set();
const initialBuildInFlight = new Set();
const cloudPractitionerDomains = [
  { key: "cloud_concepts", title: "Cloud Concepts", weight: 0.24, keywords: ["cloud concepts", "value proposition", "benefit", "economies", "agility", "elasticity", "well-architected", "migration", "global infrastructure"] },
  { key: "security_compliance", title: "Security and Compliance", weight: 0.30, keywords: ["security", "compliance", "shared responsibility", "iam", "identity", "access", "encryption", "governance", "artifact", "audit", "guardduty", "inspector", "shield", "waf", "kms"] },
  { key: "technology_services", title: "Cloud Technology and Services", weight: 0.34, keywords: ["technology", "services", "compute", "ec2", "lambda", "storage", "s3", "database", "rds", "dynamodb", "network", "vpc", "route 53", "cloudfront", "analytics", "ai", "ml", "monitoring"] },
  { key: "billing_support", title: "Billing, Pricing, and Support", weight: 0.12, keywords: ["billing", "pricing", "cost", "support", "budget", "cost explorer", "calculator", "trusted advisor", "marketplace", "free tier", "reserved", "savings plan"] }
];
const solutionsArchitectDomains = [
  { key: "secure_architectures", title: "Design Secure Architectures", weight: 0.30, keywords: ["secure", "security", "iam", "identity", "policy", "least privilege", "encryption", "kms", "secrets", "vpc", "network", "private", "public", "compliance", "logging"] },
  { key: "resilient_architectures", title: "Design Resilient Architectures", weight: 0.26, keywords: ["resilient", "resilience", "availability", "multi-az", "multi region", "backup", "restore", "disaster recovery", "failover", "auto scaling", "load balancer", "rto", "rpo"] },
  { key: "high_performing_architectures", title: "Design High-Performing Architectures", weight: 0.24, keywords: ["performance", "high-performing", "latency", "throughput", "cache", "cloudfront", "elasticache", "read replica", "sqs", "sns", "kinesis", "scaling"] },
  { key: "cost_optimized_architectures", title: "Design Cost-Optimized Architectures", weight: 0.20, keywords: ["cost", "cost-optimized", "savings", "reserved", "spot", "right size", "lifecycle", "storage class", "budget", "cost explorer", "pricing"] }
];
const genericCertificationDomains = [
  { key: "core_concepts", title: "Core Concepts", weight: 0.30, keywords: ["core", "concept", "definition", "fundamental", "service", "principle"] },
  { key: "scenario_decisions", title: "Scenario Decisions", weight: 0.30, keywords: ["scenario", "choose", "best", "design", "requirement", "tradeoff", "use case"] },
  { key: "security_operations", title: "Security and Operations", weight: 0.25, keywords: ["security", "operation", "monitoring", "troubleshoot", "access", "policy", "governance"] },
  { key: "exam_traps", title: "Exam Traps", weight: 0.15, keywords: ["trap", "similar", "compare", "difference", "exception", "pitfall"] }
];

mkdirSync(dataDir, { recursive: true });
mkdirSync(dirname(dbPath), { recursive: true });

function sqlEscape(value) {
  return String(value ?? "").replaceAll("'", "''");
}

function sqlite(sql, { json = false } = {}) {
  const args = json ? ["-json", dbPath, sql] : [dbPath, sql];
  const result = spawnSync("sqlite3", args, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(`${result.stderr || "SQLite query failed"}\nSQL: ${sql.slice(0, 500)}`);
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
      source_id TEXT NOT NULL DEFAULT '',
      source_provider TEXT NOT NULL DEFAULT '',
      source_url TEXT NOT NULL DEFAULT '',
      source_license TEXT NOT NULL DEFAULT '',
      source_license_url TEXT NOT NULL DEFAULT '',
      provenance_kind TEXT NOT NULL DEFAULT 'ai_generated',
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS question_sources (
      id TEXT PRIMARY KEY NOT NULL,
      provider TEXT NOT NULL,
      source_key TEXT NOT NULL DEFAULT '',
      source_url TEXT NOT NULL DEFAULT '',
      license_name TEXT NOT NULL DEFAULT '',
      license_url TEXT NOT NULL DEFAULT '',
      citation TEXT NOT NULL DEFAULT '',
      certification_code TEXT NOT NULL DEFAULT '',
      provenance_kind TEXT NOT NULL DEFAULT 'curated',
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
    CREATE TABLE IF NOT EXISTS leads (
      id TEXT PRIMARY KEY NOT NULL,
      email TEXT NOT NULL,
      name TEXT NOT NULL DEFAULT '',
      audience TEXT NOT NULL DEFAULT '',
      goal TEXT NOT NULL DEFAULT '',
      source TEXT NOT NULL DEFAULT 'landing',
      status TEXT NOT NULL DEFAULT 'new',
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
    ["last_seen_at", "REAL"],
    ["source_id", "TEXT NOT NULL DEFAULT ''"],
    ["source_provider", "TEXT NOT NULL DEFAULT ''"],
    ["source_url", "TEXT NOT NULL DEFAULT ''"],
    ["source_license", "TEXT NOT NULL DEFAULT ''"],
    ["source_license_url", "TEXT NOT NULL DEFAULT ''"],
    ["provenance_kind", "TEXT NOT NULL DEFAULT 'ai_generated'"]
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

function deterministicId(namespace, value) {
  return crypto.createHash("sha1").update(`${namespace}:${value}`).digest("hex").slice(0, 24);
}

function sourceMetadataFor(generationSource, note = null, question = {}) {
  const source = String(generationSource || question.generation_source || "initial");
  const lower = source.toLowerCase();
  const certCode = isSolutionsArchitectNote(note)
    ? "SAA-C03"
    : isCloudPractitionerNote(note)
      ? "CLF-C02"
      : "";
  if (lower.startsWith("cloudcertprep:")) {
    const candidateCode = source.split(":")[1] || "";
    const code = /^([a-z]+-)?[a-z]{2,4}-\d{2,3}$/i.test(candidateCode)
      ? candidateCode.toUpperCase()
      : certCode || "";
    return {
      id: deterministicId("question-source", `cloudcertprep:${code || candidateCode || "unknown"}`),
      provider: "CloudCertPrep",
      sourceKey: source,
      sourceUrl: "https://github.com/nastaso/cloudcertprep",
      licenseName: "MIT",
      licenseUrl: "https://github.com/nastaso/cloudcertprep/blob/main/LICENSE",
      citation: `CloudCertPrep ${code} MIT-licensed practice question bank`,
      certificationCode: code,
      provenanceKind: "licensed_bank"
    };
  }
  if (lower.includes("cloud_practitioner") || lower.includes("solutions_architect") || lower.includes("starter_bank") || lower.includes("expanded_bank")) {
    return {
      id: deterministicId("question-source", `quizloop-curated:${certCode || lower}`),
      provider: "QuizLoop curated bank",
      sourceKey: source,
      sourceUrl: certCode === "SAA-C03"
        ? "https://docs.aws.amazon.com/aws-certification/latest/solutions-architect-associate-03.html"
        : certCode === "CLF-C02"
          ? "https://docs.aws.amazon.com/aws-certification/latest/cloud-practitioner-02.html"
          : "",
      licenseName: "QuizLoop original",
      licenseUrl: "",
      citation: certCode
        ? `QuizLoop original scenarios mapped to the official ${certCode} exam guide domains`
        : "QuizLoop original curated practice bank",
      certificationCode: certCode,
      provenanceKind: "curated_bank"
    };
  }
  return {
    id: deterministicId("question-source", `gemma:${lower}`),
    provider: "Gemma 4",
    sourceKey: source,
    sourceUrl: "",
    licenseName: "AI-generated supplemental",
    licenseUrl: "",
    citation: "Generated from the user's note and saved learning history",
    certificationCode: certCode,
    provenanceKind: "ai_supplemental"
  };
}

function registerQuestionSource(metadata) {
  if (!metadata?.id) return "";
  sqlite(`
    INSERT OR IGNORE INTO question_sources (
      id, provider, source_key, source_url, license_name, license_url,
      citation, certification_code, provenance_kind, created_at
    ) VALUES (
      '${sqlEscape(metadata.id)}',
      '${sqlEscape(metadata.provider)}',
      '${sqlEscape(metadata.sourceKey || "")}',
      '${sqlEscape(metadata.sourceUrl || "")}',
      '${sqlEscape(metadata.licenseName || "")}',
      '${sqlEscape(metadata.licenseUrl || "")}',
      '${sqlEscape(metadata.citation || "")}',
      '${sqlEscape(metadata.certificationCode || "")}',
      '${sqlEscape(metadata.provenanceKind || "curated")}',
      ${Date.now() / 1000}
    );
  `);
  return metadata.id;
}

function backfillQuestionSourceMetadata() {
  const rows = sqlite(`
    SELECT
      q.generation_source,
      n.id AS note_id,
      n.title,
      n.body,
      n.source_type
    FROM questions q
    LEFT JOIN notes n ON n.id = q.note_id
    GROUP BY q.generation_source, n.id
  `, { json: true });
  for (const row of rows) {
    const source = String(row.generation_source || "initial");
    const note = {
      id: row.note_id,
      title: row.title || "",
      body: row.body || "",
      sourceType: row.source_type || "",
      source_type: row.source_type || ""
    };
    const metadata = sourceMetadataFor(source, note);
    registerQuestionSource(metadata);
    sqlite(`
      UPDATE questions
      SET source_id = '${sqlEscape(metadata.id)}',
          source_provider = '${sqlEscape(metadata.provider)}',
          source_url = '${sqlEscape(metadata.sourceUrl || "")}',
          source_license = '${sqlEscape(metadata.licenseName || "")}',
          source_license_url = '${sqlEscape(metadata.licenseUrl || "")}',
          provenance_kind = '${sqlEscape(metadata.provenanceKind || "curated")}'
      WHERE generation_source = '${sqlEscape(source)}'
        AND note_id = '${sqlEscape(row.note_id || "")}';
    `);
  }
  sqlite(`
    DELETE FROM question_sources
    WHERE id NOT IN (
      SELECT DISTINCT source_id FROM questions WHERE TRIM(COALESCE(source_id, '')) <> ''
    );
  `);
}

backfillQuestionSourceMetadata();

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
      (SELECT COUNT(*) FROM book_sections bs WHERE bs.note_id = n.id) AS section_count,
      (SELECT COUNT(*) FROM questions q WHERE q.note_id = n.id) AS question_count,
      (SELECT COUNT(*) FROM quiz_queue qq WHERE qq.note_id = n.id AND qq.state = 'ready') AS queued_quiz_count,
      (SELECT COUNT(*) FROM attempts a WHERE a.note_id = n.id) AS attempt_count,
      (SELECT COUNT(*) FROM quiz_sessions s WHERE s.note_id = n.id) AS quiz_count,
      (SELECT AVG(a.score) FROM attempts a WHERE a.note_id = n.id) AS attempt_average,
      (SELECT AVG(q.understanding_score) FROM questions q WHERE q.note_id = n.id AND q.understanding_score > 0) AS question_average,
      (SELECT s.score FROM quiz_sessions s WHERE s.note_id = n.id ORDER BY s.created_at DESC LIMIT 1) AS latest_quiz_score,
      (SELECT AVG(score) FROM (
        SELECT s.score
        FROM quiz_sessions s
        WHERE s.note_id = n.id
        ORDER BY s.created_at DESC
        LIMIT 5
      )) AS recent_quiz_score
    FROM notes n
    WHERE n.id = '${sqlEscape(noteId)}'
  `, { json: true })[0];
  return rows ? withViableCertificationQuestionCount(normalizeNote(rows)) : null;
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
    quizCount: Number(row.quiz_count || 0),
    latestScore: Number(row.latest_quiz_score || 0),
    recentScore: Number(row.recent_quiz_score || 0),
    averageScore: String(row.source_type || "text").toLowerCase() === "certs"
      ? Number(row.recent_quiz_score ?? row.attempt_average ?? 0)
      : Number(row.question_average ?? row.attempt_average ?? 0)
  };
}

function withViableCertificationQuestionCount(note) {
  if (!note || !isCertificationNote(note)) return note;
  return {
    ...note,
    questionCount: viableQuestionCount(note.id, note)
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
      (SELECT COUNT(*) FROM book_sections bs WHERE bs.note_id = n.id) AS section_count,
      (SELECT COUNT(*) FROM questions q WHERE q.note_id = n.id) AS question_count,
      (SELECT COUNT(*) FROM quiz_queue qq WHERE qq.note_id = n.id AND qq.state = 'ready') AS queued_quiz_count,
      (SELECT COUNT(*) FROM attempts a WHERE a.note_id = n.id) AS attempt_count,
      (SELECT COUNT(*) FROM quiz_sessions s WHERE s.note_id = n.id) AS quiz_count,
      (SELECT AVG(a.score) FROM attempts a WHERE a.note_id = n.id) AS attempt_average,
      (SELECT AVG(q.understanding_score) FROM questions q WHERE q.note_id = n.id AND q.understanding_score > 0) AS question_average,
      (SELECT s.score FROM quiz_sessions s WHERE s.note_id = n.id ORDER BY s.created_at DESC LIMIT 1) AS latest_quiz_score,
      (SELECT AVG(score) FROM (
        SELECT s.score
        FROM quiz_sessions s
        WHERE s.note_id = n.id
        ORDER BY s.created_at DESC
        LIMIT 5
      )) AS recent_quiz_score
    FROM notes n
    ORDER BY n.created_at DESC
  `, { json: true }).map((row) => withViableCertificationQuestionCount(normalizeNote(row)));
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
    "content-disposition": `attachment; filename="quizloop-backup-${stamp}.sqlite"`
  });
  response.end(readFileSync(dbPath));
}

async function restoreBackup(request) {
  const buffer = await readRequestBuffer(request);
  if (buffer.length < 100 || buffer.slice(0, 16).toString("utf8") !== "SQLite format 3\u0000") {
    throw new Error("This is not a valid QuizLoop backup file.");
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
      "user-agent": "QuizLoopLearningDemo/1.0 (local demo)"
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

function isCertificationSourceType(sourceType) {
  return String(sourceType || "").toLowerCase() === "certs";
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
  const angle = normalizeText(question.assessment_angle || question.assessmentAngle || "");
  const prompt = normalizeText(question.canonical_prompt || question.prompt || question.variant_prompt || "");
  const answerRoot = compactConceptText(question.canonical_answer || question.answer || question.variant_answer || "")
    .split(" ")
    .slice(0, 7)
    .join(" ");
  const conceptRoot = key.split(":")[0] || "";
  if (angle.includes("trap") || prompt.includes("weakest fit") || prompt.includes("does not fit")) {
    return (conceptRoot || answerRoot || key).slice(0, 140);
  }
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

function compactSubtopicKey(question) {
  return compactConceptText(question.concept || question.subtopic || question.subtopic_title || "")
    .replace(/\b(service selection|design rationale|capability checkpoint|implementation action|exam trap|practice|scenario|tradeoff|detail|application)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .split(" ")
    .slice(0, 6)
    .join(" ");
}

function adaptiveConceptKeys(question) {
  return [
    conceptRootKey(question),
    answerMemoryKey(question),
    compactSubtopicKey(question)
  ].map((key) => String(key || "").trim()).filter(Boolean);
}

function conceptKeysMatch(leftKeys, rightKeys) {
  const left = (Array.isArray(leftKeys) ? leftKeys : [leftKeys]).filter(Boolean);
  const right = (Array.isArray(rightKeys) ? rightKeys : [rightKeys]).filter(Boolean);
  const generic = new Set([
    "amazon", "aws", "service", "services", "design", "architecture", "architectures",
    "option", "choice", "application", "workload", "company", "data"
  ]);
  const meaningfulOverlapRatio = (leftKey, rightKey) => {
    const leftTokens = [...tokenSet(leftKey)].filter((token) => token.length >= 3 && !generic.has(token));
    const rightTokens = new Set([...tokenSet(rightKey)].filter((token) => token.length >= 3 && !generic.has(token)));
    if (leftTokens.length === 0 || rightTokens.size === 0) return 0;
    const overlap = leftTokens.filter((token) => rightTokens.has(token)).length;
    return overlap / Math.min(leftTokens.length, rightTokens.size);
  };
  for (const leftKey of left) {
    for (const rightKey of right) {
      if (!leftKey || !rightKey) continue;
      if (leftKey === rightKey || leftKey.includes(rightKey) || rightKey.includes(leftKey)) return true;
      if (meaningfulOverlapRatio(leftKey, rightKey) >= 0.5) return true;
      const leftTokens = tokenSet(leftKey);
      const rightTokens = tokenSet(rightKey);
      for (const token of leftTokens) {
        if (token.length >= 5 && !generic.has(token) && rightTokens.has(token)) return true;
      }
    }
  }
  return false;
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

async function geminiText(prompt, timeoutMs = 90000) {
  if (!geminiApiKey) {
    throw new Error("GEMINI_API_KEY is not configured.");
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(geminiModel)}:generateContent`, {
    method: "POST",
    signal: controller.signal,
    headers: {
      "content-type": "application/json",
      "x-goog-api-key": geminiApiKey
    },
    body: JSON.stringify({
      contents: [
        {
          parts: [
            { text: prompt }
          ]
        }
      ],
      generationConfig: {
        temperature: 0.35,
        maxOutputTokens: 900
      }
    })
  });
  clearTimeout(timeout);

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(`Gemini request failed: ${response.status} ${detail.slice(0, 180)}`);
  }

  const payload = await response.json();
  return payload.candidates?.[0]?.content?.parts
    ?.map((part) => part.text || "")
    .join("")
    .trim() || "";
}

function noteShapePromptFor({ title, body, sourceType }) {
  const cleanTitle = String(title || "Untitled Note").slice(0, 180);
  const cleanSourceType = String(sourceType || "text").slice(0, 40);
  const text = String(body || "").slice(0, 12000);
  const modeGuidance = isBookSourceType(cleanSourceType)
    ? `Book notes should be organized into: Book or source, passage/chapter, source text, key ideas, evidence, and what the learner wants to understand. If this is a long pasted book, preserve the source text and add structure around it.`
    : cleanSourceType === "math"
      ? `Math notes should be organized into: concept, formulas/rules, worked example, common mistakes, and practice goals. Keep formulas readable as plain text.`
      : isCertificationSourceType(cleanSourceType)
        ? `Certification notes should be organized into: exam goal, domains, source material, service/term definitions, scenario patterns, common traps, and what the learner should be able to decide under exam pressure. Do not include exam dumps or copyrighted exam questions.`
        : `General notes should be organized into: source text, key ideas, important facts, relationships, and what the learner should be able to explain.`;

  return `
You are shaping a student's raw note so QuizLoop.ai can create better quizzes from it.
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

function isCertificationNote(note) {
  return isCertificationSourceType(note?.sourceType || note?.source_type)
    || /^##\s*Certification:/i.test(String(note?.body || ""));
}

function isCloudPractitionerNote(note) {
  const text = `${note?.title || ""}\n${note?.body || ""}`;
  return /AWS Certified Cloud Practitioner|Cloud Practitioner|CLF-C02/i.test(text);
}

function isSolutionsArchitectNote(note) {
  const text = `${note?.title || ""}\n${note?.body || ""}`;
  return /AWS Certified Solutions Architect|Solutions Architect|SAA-C03/i.test(text);
}

function certificationDomainsFor(note) {
  if (isSolutionsArchitectNote(note)) return solutionsArchitectDomains;
  if (isCloudPractitionerNote(note)) return cloudPractitionerDomains;
  return genericCertificationDomains;
}

function usesOfficialCertificationDomains(note) {
  return isCloudPractitionerNote(note) || isSolutionsArchitectNote(note);
}

function certificationExamFor(note) {
  if (isCloudPractitionerNote(note)) {
    return {
      name: "AWS Certified Cloud Practitioner CLF-C02",
      scoredQuestions: 50,
      unscoredQuestions: 15,
      passingScore: 700
    };
  }
  if (isSolutionsArchitectNote(note)) {
    return {
      name: "AWS Certified Solutions Architect - Associate SAA-C03",
      scoredQuestions: 50,
      unscoredQuestions: 15,
      passingScore: 720
    };
  }
  return {
    name: "Certification prep",
    scoredQuestions: 50,
    unscoredQuestions: 15,
    passingScore: 700
  };
}

function cloudPractitionerSeedQuestions() {
  const item = (topic, concept, prompt, answer, choices, angle = "scenario") => ({
    topic,
    concept,
    segment: concept,
    source_excerpt: "QuizLoop Cloud Practitioner starter map",
    assessment_angle: angle,
    canonical_prompt: prompt,
    canonical_answer: answer,
    accepted_answers: [answer],
    importance: topic === "Cloud Technology and Services" || topic === "Security and Compliance" ? 1 : 0.8,
    difficulty: angle === "scenario" || angle === "tradeoff" ? 0.9 : 0.6,
    variants: [{
      delivery_type: "multiple_choice",
      prompt,
      answer,
      choices,
      rubric: `Tests ${concept} for Cloud Practitioner readiness.`
    }]
  });
  return [
    item("Cloud Concepts", "Cloud value proposition", "A startup wants to avoid buying servers up front and pay only as usage grows. Which cloud benefit does this describe?", "trading capital expense for variable expense", ["trading capital expense for variable expense", "increasing fixed data center contracts", "owning physical hardware for compliance", "removing all operational responsibility"], "definition"),
    item("Cloud Concepts", "Elasticity", "A retail site needs capacity to rise during a holiday sale and fall afterward. Which AWS Cloud concept is being used?", "elasticity", ["elasticity", "data residency", "reserved capacity only", "manual procurement"], "scenario"),
    item("Cloud Concepts", "Global infrastructure", "Which infrastructure design helps applications stay available by placing resources in isolated locations within a Region?", "Availability Zones", ["Availability Zones", "IAM users", "AWS Budgets", "Amazon Machine Images"], "definition"),
    item("Cloud Concepts", "Fault tolerance", "A workload continues operating even when one component fails. Which design goal does this best represent?", "fault tolerance", ["fault tolerance", "single-AZ deployment", "manual scaling", "cost allocation tagging"], "definition"),
    item("Security and Compliance", "Shared responsibility model", "Under the shared responsibility model, which responsibility belongs to AWS?", "security of the cloud, including physical facilities and managed infrastructure", ["security of the cloud, including physical facilities and managed infrastructure", "classifying customer data stored in S3", "creating least-privilege IAM policies for application users", "configuring customer-owned network access rules"], "scenario"),
    item("Security and Compliance", "Customer responsibility", "A company stores customer records in Amazon S3. Which task is the customer's responsibility?", "controlling data access and configuration", ["controlling data access and configuration", "maintaining AWS physical data centers", "patching the underlying S3 storage fleet", "replacing failed AWS networking hardware"], "scenario"),
    item("Security and Compliance", "IAM", "Which AWS service helps manage users, groups, roles, and permissions?", "AWS Identity and Access Management (IAM)", ["AWS Identity and Access Management (IAM)", "Amazon CloudFront", "AWS Pricing Calculator", "Amazon Route 53"], "definition"),
    item("Security and Compliance", "Compliance reports", "Which AWS service or resource provides access to AWS compliance reports?", "AWS Artifact", ["AWS Artifact", "Amazon EC2 Auto Scaling", "AWS Budgets", "Amazon DynamoDB"], "definition"),
    item("Cloud Technology and Services", "Compute service selection", "A team wants to run code without provisioning or managing servers. Which AWS service best fits?", "AWS Lambda", ["AWS Lambda", "Amazon EC2", "Amazon EBS", "Amazon VPC"], "scenario"),
    item("Cloud Technology and Services", "Virtual servers", "Which AWS service provides resizable virtual servers?", "Amazon EC2", ["Amazon EC2", "Amazon S3", "AWS Artifact", "AWS Budgets"], "definition"),
    item("Cloud Technology and Services", "Object storage", "Which AWS service is designed for object storage?", "Amazon S3", ["Amazon S3", "Amazon EBS", "Amazon RDS", "Amazon VPC"], "definition"),
    item("Cloud Technology and Services", "Managed relational database", "Which AWS service is a managed relational database service?", "Amazon RDS", ["Amazon RDS", "Amazon DynamoDB", "Amazon CloudFront", "AWS Shield"], "definition"),
    item("Cloud Technology and Services", "Content delivery", "Which AWS service is a content delivery network for caching content closer to users?", "Amazon CloudFront", ["Amazon CloudFront", "Amazon VPC", "AWS Cost Explorer", "AWS KMS"], "definition"),
    item("Billing, Pricing, and Support", "Cost monitoring", "Which AWS tool helps monitor and visualize AWS spending over time?", "AWS Cost Explorer", ["AWS Cost Explorer", "Amazon Route 53", "AWS Lambda", "AWS Artifact"], "definition"),
    item("Billing, Pricing, and Support", "Budget alerts", "A learner wants alerts when AWS spend approaches a planned amount. Which tool should they use?", "AWS Budgets", ["AWS Budgets", "Amazon CloudWatch Logs only", "Amazon S3 Versioning", "AWS Shield Advanced"], "scenario"),
    item("Billing, Pricing, and Support", "Support plan differences", "What do AWS Support plans vary by?", "response times and access levels", ["response times and access levels", "S3 bucket version counts", "EC2 instance operating systems", "Availability Zone names"], "definition"),
    item("Billing, Pricing, and Support", "Trusted Advisor", "Which AWS service gives recommendations across cost optimization, security, fault tolerance, performance, and service limits?", "AWS Trusted Advisor", ["AWS Trusted Advisor", "Amazon DynamoDB", "AWS CloudFormation", "Amazon EFS"], "definition")
  ];
}

function cloudPractitionerSupplementalSeedQuestions() {
  const item = (topic, concept, prompt, answer, choices, angle = "scenario") => ({
    topic,
    concept,
    segment: concept,
    source_excerpt: "QuizLoop Cloud Practitioner expanded starter bank",
    assessment_angle: angle,
    canonical_prompt: prompt,
    canonical_answer: answer,
    accepted_answers: [answer],
    importance: topic === "Cloud Technology and Services" || topic === "Security and Compliance" ? 1 : 0.85,
    difficulty: angle === "scenario" || angle === "tradeoff" ? 1 : 0.7,
    variants: [{
      delivery_type: "multiple_choice",
      prompt,
      answer,
      choices,
      rubric: `Tests ${concept} for Cloud Practitioner readiness.`
    }]
  });
  return [
    item("Cloud Concepts", "High availability", "A company wants an application to remain accessible during infrastructure disruption. Which cloud design goal is this?", "high availability", ["high availability", "capital expense", "data classification", "manual patching"], "scenario"),
    item("Cloud Concepts", "Scalability", "A workload needs to add resources as demand grows over time. Which cloud concept does this describe?", "scalability", ["scalability", "immutability", "data sovereignty", "root access"], "definition"),
    item("Cloud Concepts", "Agility", "A team wants to launch test environments quickly without waiting for hardware procurement. Which AWS Cloud benefit is most relevant?", "agility", ["agility", "fixed capacity", "long-term hardware leasing", "manual data center expansion"], "scenario"),
    item("Cloud Concepts", "Operational excellence", "A team uses monitoring, automation, and repeatable processes to improve workloads. Which Well-Architected pillar does this align with?", "operational excellence", ["operational excellence", "single point of failure", "physical security", "untracked spending"], "scenario"),
    item("Cloud Concepts", "Edge locations", "Which part of AWS global infrastructure helps deliver cached content closer to end users?", "edge locations", ["edge locations", "IAM groups", "Reserved Instances", "security groups"], "definition"),
    item("Cloud Concepts", "Regions", "A business must keep workloads in a specific geographic area. Which AWS global infrastructure unit should it choose?", "Region", ["Region", "IAM role", "Cost Explorer", "Spot Instance"], "scenario"),
    item("Security and Compliance", "MFA", "Which security practice adds an extra sign-in factor beyond a password?", "multi-factor authentication (MFA)", ["multi-factor authentication (MFA)", "AWS Cost Explorer", "Amazon S3 lifecycle rules", "edge caching"], "definition"),
    item("Security and Compliance", "Least privilege", "An administrator grants only the permissions a user needs for a job. Which security principle is being applied?", "least privilege", ["least privilege", "public access by default", "unlimited root access", "single Availability Zone"], "scenario"),
    item("Security and Compliance", "Encryption keys", "Which AWS service helps create and manage encryption keys?", "AWS Key Management Service (KMS)", ["AWS Key Management Service (KMS)", "Amazon Route 53", "AWS Budgets", "Amazon CloudFront"], "definition"),
    item("Security and Compliance", "DDoS protection", "Which AWS service helps protect applications from DDoS attacks?", "AWS Shield", ["AWS Shield", "AWS Pricing Calculator", "Amazon EFS", "AWS Artifact"], "definition"),
    item("Security and Compliance", "Web application firewall", "Which service helps filter malicious web traffic using configurable rules?", "AWS WAF", ["AWS WAF", "Amazon RDS", "AWS Cost Explorer", "Amazon EBS"], "definition"),
    item("Security and Compliance", "Threat detection", "Which AWS service provides intelligent threat detection for AWS accounts and workloads?", "Amazon GuardDuty", ["Amazon GuardDuty", "AWS Budgets", "Amazon Route 53", "Amazon CloudFront"], "definition"),
    item("Security and Compliance", "Vulnerability management", "Which AWS service helps scan workloads for software vulnerabilities and unintended network exposure?", "Amazon Inspector", ["Amazon Inspector", "AWS Free Tier", "Amazon S3", "Elastic Load Balancing"], "definition"),
    item("Security and Compliance", "Root user protection", "Which action best protects the AWS account root user?", "enable MFA and avoid routine root user use", ["enable MFA and avoid routine root user use", "share the root password with admins", "use root credentials in application code", "disable all account alerts"], "scenario"),
    item("Cloud Technology and Services", "Elastic Load Balancing", "A web app needs to distribute incoming traffic across multiple targets. Which AWS service should be used?", "Elastic Load Balancing", ["Elastic Load Balancing", "AWS Artifact", "Amazon S3 Glacier", "AWS Pricing Calculator"], "scenario"),
    item("Cloud Technology and Services", "Auto Scaling", "Which AWS capability adjusts compute capacity automatically based on demand?", "Auto Scaling", ["Auto Scaling", "AWS Artifact", "Amazon Route 53 registration only", "AWS Budgets"], "definition"),
    item("Cloud Technology and Services", "Block storage", "Which AWS storage service provides block storage volumes for EC2 instances?", "Amazon EBS", ["Amazon EBS", "Amazon S3", "Amazon Route 53", "AWS Shield"], "definition"),
    item("Cloud Technology and Services", "File storage", "Which AWS service provides shared file storage that can be mounted by multiple compute resources?", "Amazon EFS", ["Amazon EFS", "AWS Lambda", "Amazon DynamoDB", "AWS Artifact"], "definition"),
    item("Cloud Technology and Services", "NoSQL database", "Which AWS database service is a managed NoSQL key-value and document database?", "Amazon DynamoDB", ["Amazon DynamoDB", "Amazon RDS", "Amazon EBS", "AWS Cost Explorer"], "definition"),
    item("Cloud Technology and Services", "Virtual private network", "Which AWS service lets customers isolate cloud resources in a logically separated network?", "Amazon VPC", ["Amazon VPC", "Amazon CloudFront", "AWS Budgets", "AWS Artifact"], "definition"),
    item("Cloud Technology and Services", "DNS", "Which AWS service provides DNS routing and domain registration features?", "Amazon Route 53", ["Amazon Route 53", "AWS Lambda", "Amazon EBS", "AWS KMS"], "definition"),
    item("Cloud Technology and Services", "Monitoring", "Which AWS service collects metrics, logs, and alarms for AWS resources?", "Amazon CloudWatch", ["Amazon CloudWatch", "AWS Artifact", "Amazon S3 Glacier", "AWS Marketplace"], "definition"),
    item("Cloud Technology and Services", "Object archive", "A company needs low-cost long-term archive storage for rarely accessed objects. Which S3 storage class family is relevant?", "S3 Glacier storage classes", ["S3 Glacier storage classes", "Amazon EC2 On-Demand", "AWS IAM policies", "Amazon Route 53 hosted zones"], "scenario"),
    item("Cloud Technology and Services", "Managed queue", "Which AWS service can decouple application components using message queues?", "Amazon SQS", ["Amazon SQS", "AWS Artifact", "Amazon EBS", "AWS Shield"], "definition"),
    item("Cloud Technology and Services", "Notifications", "Which AWS service can publish messages to subscribers such as email, SMS, or application endpoints?", "Amazon SNS", ["Amazon SNS", "Amazon RDS", "AWS Budgets", "Amazon VPC"], "definition"),
    item("Cloud Technology and Services", "Infrastructure as code", "Which AWS service provisions infrastructure from templates?", "AWS CloudFormation", ["AWS CloudFormation", "AWS Shield", "Amazon CloudWatch Logs only", "AWS Free Tier"], "definition"),
    item("Billing, Pricing, and Support", "Pricing Calculator", "Before deploying a workload, a team wants to estimate monthly AWS costs. Which tool should they use?", "AWS Pricing Calculator", ["AWS Pricing Calculator", "AWS Artifact", "Amazon GuardDuty", "Amazon VPC"], "scenario"),
    item("Billing, Pricing, and Support", "Savings Plans", "A company has steady compute usage and wants lower prices in exchange for a usage commitment. Which pricing option fits?", "Savings Plans", ["Savings Plans", "AWS Artifact reports", "MFA devices", "edge locations"], "scenario"),
    item("Billing, Pricing, and Support", "Reserved Instances", "A workload will run predictably for a long term. Which EC2 pricing model can reduce cost with a reservation commitment?", "Reserved Instances", ["Reserved Instances", "Spot Instances only", "AWS WAF rules", "Amazon S3 buckets"], "scenario"),
    item("Billing, Pricing, and Support", "Spot Instances", "A fault-tolerant batch job can be interrupted. Which EC2 purchasing option can provide the lowest cost?", "Spot Instances", ["Spot Instances", "Dedicated Hosts", "On-Demand Instances only", "AWS Support Enterprise"], "scenario"),
    item("Billing, Pricing, and Support", "On-Demand pricing", "Which pricing model lets customers pay for compute capacity with no long-term commitment?", "On-Demand pricing", ["On-Demand pricing", "Reserved capacity only", "prepaid data center contracts", "root account billing"], "definition"),
    item("Billing, Pricing, and Support", "Free Tier", "Which AWS program lets new customers try eligible services within usage limits at no additional charge?", "AWS Free Tier", ["AWS Free Tier", "AWS Shield Advanced", "Amazon Inspector", "AWS Organizations"], "definition"),
    item("Billing, Pricing, and Support", "Consolidated billing", "Which AWS service helps centrally manage multiple AWS accounts and consolidated billing?", "AWS Organizations", ["AWS Organizations", "Amazon CloudFront", "AWS Lambda", "Amazon EFS"], "definition"),
    item("Billing, Pricing, and Support", "Marketplace", "Where can customers find and subscribe to third-party software that runs on AWS?", "AWS Marketplace", ["AWS Marketplace", "AWS Artifact", "AWS IAM Identity Center", "Amazon Route 53"], "definition"),
    item("Billing, Pricing, and Support", "Basic Support", "Which support plan is included for all AWS customers?", "Basic Support", ["Basic Support", "Enterprise Support", "Business Support", "Developer Support"], "definition"),
    item("Billing, Pricing, and Support", "Technical account manager", "Which AWS Support plan includes a designated Technical Account Manager?", "Enterprise Support", ["Enterprise Support", "Basic Support", "Developer Support", "Free Tier"], "definition")
  ];
}

function cloudPractitionerQuestionBank() {
  return [
    ...cloudPractitionerSeedQuestions(),
    ...cloudPractitionerSupplementalSeedQuestions()
  ];
}

function solutionsArchitectSeedQuestions() {
  const item = (topic, concept, prompt, answer, choices, angle = "scenario") => ({
    topic,
    concept,
    segment: concept,
    source_excerpt: "QuizLoop Solutions Architect starter map",
    assessment_angle: angle,
    canonical_prompt: prompt,
    canonical_answer: answer,
    accepted_answers: [answer],
    importance: topic === "Design Secure Architectures" || topic === "Design Resilient Architectures" ? 1 : 0.9,
    difficulty: angle === "scenario" || angle === "tradeoff" ? 1 : 0.7,
    variants: [{
      delivery_type: "multiple_choice",
      prompt,
      answer,
      choices,
      rubric: `Tests ${concept} for Solutions Architect Associate readiness.`
    }]
  });
  return [
    item("Design Secure Architectures", "Least privilege", "An application needs temporary access to an S3 bucket from EC2 without storing long-term keys. What should the architect use?", "an IAM role attached to the EC2 instance", ["an IAM role attached to the EC2 instance", "an IAM user access key stored on the instance", "the AWS account root user credentials", "a public S3 bucket policy"], "scenario"),
    item("Design Secure Architectures", "Private subnet access", "Instances in a private subnet need outbound internet access for updates without accepting inbound internet traffic. Which component should be placed in a public subnet?", "NAT gateway", ["NAT gateway", "internet gateway attached directly to the private subnet", "AWS Direct Connect gateway only", "VPC peering connection"], "scenario"),
    item("Design Secure Architectures", "Encryption keys", "Which AWS service is commonly used to create and manage encryption keys for AWS resources?", "AWS Key Management Service (KMS)", ["AWS Key Management Service (KMS)", "Amazon Route 53", "AWS Cost Explorer", "Amazon CloudFront"], "definition"),
    item("Design Secure Architectures", "Network controls", "Which VPC control is stateful and attached to an elastic network interface?", "security group", ["security group", "network ACL", "route table", "internet gateway"], "definition"),
    item("Design Resilient Architectures", "Multi-AZ databases", "A production relational database needs high availability across Availability Zones with automatic failover. Which design is best?", "Amazon RDS Multi-AZ deployment", ["Amazon RDS Multi-AZ deployment", "single EC2 instance with an EBS volume", "Amazon S3 Standard-IA only", "one NAT gateway in one Availability Zone"], "scenario"),
    item("Design Resilient Architectures", "Load balancing", "A web tier should distribute traffic across healthy instances in multiple Availability Zones. Which service fits?", "Elastic Load Balancing", ["Elastic Load Balancing", "AWS Budgets", "Amazon Athena", "AWS Artifact"], "scenario"),
    item("Design Resilient Architectures", "Decoupling", "A workload needs to buffer messages between producers and consumers so failures in one layer do not stop the other. Which service is commonly used?", "Amazon SQS", ["Amazon SQS", "Amazon Route 53", "AWS Config", "Amazon EBS"], "scenario"),
    item("Design Resilient Architectures", "Object durability", "Which storage service is designed for highly durable object storage across multiple facilities?", "Amazon S3", ["Amazon S3", "instance store", "single-AZ Amazon EBS only", "AWS CloudShell"], "definition"),
    item("Design High-Performing Architectures", "Caching", "A read-heavy application needs lower database latency for repeated queries. Which service can add an in-memory cache layer?", "Amazon ElastiCache", ["Amazon ElastiCache", "AWS Artifact", "AWS Pricing Calculator", "Amazon Glacier Flexible Retrieval"], "scenario"),
    item("Design High-Performing Architectures", "Content delivery", "A global website needs static content cached close to viewers. Which AWS service is most appropriate?", "Amazon CloudFront", ["Amazon CloudFront", "AWS Organizations", "Amazon EBS", "AWS KMS"], "scenario"),
    item("Design High-Performing Architectures", "Read scaling", "An application needs to scale read traffic for a relational database. Which feature can help?", "read replicas", ["read replicas", "root user access keys", "S3 lifecycle expiration", "AWS Support case severity"], "scenario"),
    item("Design High-Performing Architectures", "Serverless scale", "A bursty event workload needs to run code without managing servers. Which service is best suited?", "AWS Lambda", ["AWS Lambda", "Amazon EC2 Dedicated Hosts only", "AWS Artifact", "AWS Budgets"], "scenario"),
    item("Design Cost-Optimized Architectures", "Storage lifecycle", "Objects are rarely accessed after 90 days but must be retained. Which design can reduce cost?", "S3 Lifecycle transition to a lower-cost storage class", ["S3 Lifecycle transition to a lower-cost storage class", "keep all objects in S3 Standard forever", "copy objects to multiple active RDS databases", "increase provisioned IOPS for all objects"], "scenario"),
    item("Design Cost-Optimized Architectures", "Compute pricing", "A flexible batch job can tolerate interruption. Which EC2 purchasing option is usually most cost-effective?", "Spot Instances", ["Spot Instances", "On-Demand Instances for all capacity", "Dedicated Hosts for every job", "Savings Plans with no usage commitment"], "scenario"),
    item("Design Cost-Optimized Architectures", "Rightsizing", "A workload is over-provisioned after a traffic drop. Which action supports cost optimization?", "right-size resources based on utilization", ["right-size resources based on utilization", "disable all monitoring", "add more idle instances", "store all data in the most expensive storage class"], "scenario"),
    item("Design Cost-Optimized Architectures", "Cost visibility", "Which AWS service helps analyze and visualize spending trends?", "AWS Cost Explorer", ["AWS Cost Explorer", "Amazon VPC", "Amazon CloudFront", "AWS Shield"], "definition")
  ];
}

function solutionsArchitectSupplementalSeedQuestions() {
  const item = (topic, concept, prompt, answer, choices, angle = "scenario") => ({
    topic,
    concept,
    segment: concept,
    source_excerpt: "QuizLoop Solutions Architect supplemental architecture bank",
    assessment_angle: angle,
    canonical_prompt: prompt,
    canonical_answer: answer,
    accepted_answers: [answer],
    importance: topic === "Design Secure Architectures" || topic === "Design Resilient Architectures" ? 1 : 0.9,
    difficulty: angle === "tradeoff" || angle === "application" ? 1.1 : 0.9,
    variants: [{
      delivery_type: "multiple_choice",
      prompt,
      answer,
      choices,
      rubric: `Tests ${concept} for Solutions Architect Associate readiness.`
    }]
  });
  return [
    item("Design Secure Architectures", "S3 public access prevention", "A company must ensure that no S3 buckets are accidentally made public. Which feature provides an account-level guardrail?", "S3 Block Public Access", ["S3 Block Public Access", "Amazon CloudFront signed URLs", "Amazon S3 Transfer Acceleration", "Amazon Route 53 health checks"]),
    item("Design Secure Architectures", "Secrets management", "An application needs to rotate database credentials automatically. Which AWS service is designed for this requirement?", "AWS Secrets Manager", ["AWS Secrets Manager", "AWS Trusted Advisor", "Amazon CloudWatch Metrics", "AWS Pricing Calculator"]),
    item("Design Secure Architectures", "Private AWS service access", "Instances in a private subnet need private connectivity to Amazon S3 without traversing the internet. Which design should be used?", "a gateway VPC endpoint for Amazon S3", ["a gateway VPC endpoint for Amazon S3", "an internet gateway on the private subnet", "AWS Shield Advanced on the bucket", "Amazon CloudFront invalidation"]),
    item("Design Secure Architectures", "Centralized identity", "A company wants workforce users to sign in to multiple AWS accounts with centralized identity. Which service should be used?", "AWS IAM Identity Center", ["AWS IAM Identity Center", "Amazon GuardDuty", "Amazon Simple Queue Service", "AWS Database Migration Service"]),
    item("Design Secure Architectures", "Database encryption", "A regulated workload requires encryption at rest for an Amazon RDS database. Which control should be enabled?", "RDS storage encryption with AWS KMS", ["RDS storage encryption with AWS KMS", "Amazon Route 53 DNSSEC only", "Elastic Load Balancing stickiness", "Amazon SQS long polling"]),
    item("Design Secure Architectures", "Web layer protection", "A public web application needs protection from common web exploits such as SQL injection and cross-site scripting. Which service should be placed in front of it?", "AWS WAF", ["AWS WAF", "AWS Cost Explorer", "Amazon EFS", "AWS Cloud9"]),
    item("Design Secure Architectures", "Audit logging", "A security team needs a record of API calls made in an AWS account. Which service should be enabled?", "AWS CloudTrail", ["AWS CloudTrail", "Amazon CloudFront", "AWS Lambda", "Amazon EBS"]),
    item("Design Secure Architectures", "Network ACL behavior", "Which statement correctly describes network ACLs in a VPC?", "Network ACLs are stateless subnet-level controls", ["Network ACLs are stateless subnet-level controls", "Network ACLs are stateful instance-level controls", "Network ACLs replace IAM policies for S3", "Network ACLs encrypt data at rest"]),
    item("Design Resilient Architectures", "Cross-Region disaster recovery", "A workload needs disaster recovery in another AWS Region with minimal data loss. Which design best supports this?", "replicate data to a secondary Region and define failover", ["replicate data to a secondary Region and define failover", "deploy every component to one Availability Zone", "store backups only on instance store", "disable health checks to reduce cost"], "application"),
    item("Design Resilient Architectures", "Route 53 failover", "A website should direct users to a healthy secondary endpoint if the primary endpoint fails. Which Route 53 capability supports this?", "failover routing with health checks", ["failover routing with health checks", "weighted routing without health checks", "private hosted zones for public users", "geoproximity routing only"]),
    item("Design Resilient Architectures", "Stateless application tier", "Why should web application session state usually be stored outside individual EC2 instances?", "so instances can be replaced or scaled without losing sessions", ["so instances can be replaced or scaled without losing sessions", "so every instance requires manual recovery", "so one Availability Zone stores all sessions", "so security groups become unnecessary"], "tradeoff"),
    item("Design Resilient Architectures", "RDS read replica limitation", "Which RDS feature primarily improves read scalability and can help disaster recovery, but does not provide automatic synchronous failover like Multi-AZ?", "read replicas", ["read replicas", "RDS Multi-AZ deployment", "Amazon S3 Versioning", "Elastic Load Balancing"], "tradeoff"),
    item("Design Resilient Architectures", "S3 accidental deletion recovery", "A company wants to recover previous object versions after accidental overwrites in Amazon S3. Which feature should be enabled?", "S3 Versioning", ["S3 Versioning", "Amazon Inspector", "AWS Budgets", "Amazon VPC Flow Logs"]),
    item("Design Resilient Architectures", "Auto Scaling health replacement", "An application should replace unhealthy EC2 instances automatically. Which service capability should be used?", "EC2 Auto Scaling health checks and replacement", ["EC2 Auto Scaling health checks and replacement", "AWS Artifact agreement download", "Amazon Route 53 domain registration only", "AWS Cost Explorer forecasts"]),
    item("Design Resilient Architectures", "Event-driven decoupling", "A checkout service must publish events to multiple independent downstream services. Which AWS service is commonly used for fanout messaging?", "Amazon SNS", ["Amazon SNS", "Amazon EBS", "AWS CloudHSM", "Amazon RDS Proxy"]),
    item("Design Resilient Architectures", "Backup policy", "A company needs centrally managed backup policies across AWS services and accounts. Which service should be used?", "AWS Backup", ["AWS Backup", "Amazon CloudFront", "AWS WAF", "Amazon Athena"]),
    item("Design High-Performing Architectures", "Database connection pooling", "A Lambda application frequently opens connections to an RDS database and risks exhausting database connections. Which service helps manage connection pooling?", "Amazon RDS Proxy", ["Amazon RDS Proxy", "AWS Cost Explorer", "Amazon CloudFront Functions", "AWS Artifact"]),
    item("Design High-Performing Architectures", "Low-latency key-value access", "An application requires single-digit millisecond performance at any scale for key-value data. Which database service is designed for this?", "Amazon DynamoDB", ["Amazon DynamoDB", "Amazon EFS", "AWS CloudTrail", "Amazon Route 53"]),
    item("Design High-Performing Architectures", "Global traffic acceleration", "A latency-sensitive application needs static Anycast IP addresses and optimized routing to regional endpoints. Which service should be used?", "AWS Global Accelerator", ["AWS Global Accelerator", "AWS Budgets", "Amazon S3 Glacier Deep Archive", "AWS IAM Access Analyzer"]),
    item("Design High-Performing Architectures", "Shared file performance", "A Linux application running on several EC2 instances needs a shared POSIX file system. Which service should be selected?", "Amazon EFS", ["Amazon EFS", "Amazon S3 Glacier Flexible Retrieval", "AWS Secrets Manager", "Amazon EventBridge"]),
    item("Design High-Performing Architectures", "Analytical warehouse", "A company needs a managed petabyte-scale data warehouse for SQL analytics. Which AWS service is most appropriate?", "Amazon Redshift", ["Amazon Redshift", "Amazon Route 53", "AWS Shield", "Amazon SQS"]),
    item("Design High-Performing Architectures", "Asynchronous stream processing", "An application must ingest and process streaming click events in near real time. Which service family is most appropriate?", "Amazon Kinesis", ["Amazon Kinesis", "AWS Pricing Calculator", "Amazon EBS Snapshots", "AWS CloudHSM"]),
    item("Design High-Performing Architectures", "Container orchestration", "A team wants to run containers with AWS-managed orchestration and integrate with load balancing and IAM. Which service fits?", "Amazon ECS", ["Amazon ECS", "AWS Artifact", "Amazon Route 53 Resolver Query Logging", "AWS Cost and Usage Reports"]),
    item("Design High-Performing Architectures", "Static website hosting", "A simple static website needs low-cost hosting without servers. Which service can host the files directly?", "Amazon S3 static website hosting", ["Amazon S3 static website hosting", "Amazon RDS Multi-AZ", "AWS Direct Connect", "Amazon EC2 Dedicated Hosts"]),
    item("Design Cost-Optimized Architectures", "Compute commitment choice", "A workload has steady compute usage across instance families and Regions. Which pricing model provides flexible savings for a usage commitment?", "Compute Savings Plans", ["Compute Savings Plans", "On-Demand Instances only", "AWS Free Tier alerts", "Amazon Route 53 latency routing"], "tradeoff"),
    item("Design Cost-Optimized Architectures", "Storage class selection", "Objects are accessed milliseconds when needed but are rarely accessed. Which S3 storage class can reduce cost while keeping immediate retrieval?", "S3 Standard-Infrequent Access", ["S3 Standard-Infrequent Access", "S3 Glacier Deep Archive", "Amazon EBS Provisioned IOPS only", "Amazon RDS Reserved Instances"], "tradeoff"),
    item("Design Cost-Optimized Architectures", "Unpredictable access storage", "A dataset has unknown and changing access patterns. Which S3 storage class automatically optimizes storage cost?", "S3 Intelligent-Tiering", ["S3 Intelligent-Tiering", "Amazon EC2 Spot Instances", "AWS Shield Advanced", "Amazon Route 53 Resolver"]),
    item("Design Cost-Optimized Architectures", "Idle resource detection", "Which AWS tool can recommend rightsizing and identify idle resources to reduce cost?", "AWS Compute Optimizer", ["AWS Compute Optimizer", "AWS CloudHSM", "Amazon Kinesis Data Streams", "Amazon Inspector"]),
    item("Design Cost-Optimized Architectures", "Data transfer cost", "A workload frequently transfers large amounts of data between Availability Zones. What should the architect evaluate first?", "whether components can be placed to reduce cross-AZ data transfer", ["whether components can be placed to reduce cross-AZ data transfer", "whether to disable all encryption", "whether to move IAM users into S3", "whether to remove every load balancer"], "application"),
    item("Design Cost-Optimized Architectures", "Cost allocation", "A finance team needs to attribute AWS costs to departments and projects. Which practice supports this?", "apply cost allocation tags", ["apply cost allocation tags", "disable AWS Budgets", "use one root user for all teams", "store logs only on instance store"]),
    item("Design Cost-Optimized Architectures", "Graviton migration", "A compatible Linux workload needs better price performance on EC2. Which option should be evaluated?", "AWS Graviton-based instances", ["AWS Graviton-based instances", "AWS Artifact reports", "Amazon Route 53 hosted zones", "AWS IAM Identity Center assignments"], "tradeoff"),
    item("Design Cost-Optimized Architectures", "Managed service choice", "A small team wants to reduce operational effort for a relational database. Which choice is usually more operationally efficient than self-managing a database on EC2?", "Amazon RDS", ["Amazon RDS", "Amazon EC2 instance store", "AWS CloudShell", "Amazon Route 53 traffic policies"], "tradeoff")
  ];
}

function solutionsArchitectAdvancedSeedQuestions() {
  const item = (topic, concept, prompt, answer, choices, angle = "scenario") => ({
    topic,
    concept,
    segment: concept,
    source_excerpt: "QuizLoop Solutions Architect advanced architecture bank",
    assessment_angle: angle,
    canonical_prompt: prompt,
    canonical_answer: answer,
    accepted_answers: [answer],
    importance: topic === "Design Secure Architectures" || topic === "Design Resilient Architectures" ? 1 : 0.9,
    difficulty: 1.15,
    variants: [{
      delivery_type: "multiple_choice",
      prompt,
      answer,
      choices,
      rubric: `Tests ${concept} for Solutions Architect Associate readiness.`
    }]
  });
  return [
    item("Design Secure Architectures", "SCP guardrails", "An organization wants to prevent member accounts from disabling AWS CloudTrail, even if an administrator has broad IAM permissions. Which control is most appropriate?", "an AWS Organizations service control policy", ["an AWS Organizations service control policy", "an Amazon S3 lifecycle policy", "an Elastic Load Balancing target group", "an Amazon CloudFront cache policy"], "application"),
    item("Design Secure Architectures", "Permission boundaries", "A company lets teams create IAM roles but must limit the maximum permissions those roles can ever receive. Which IAM feature should be used?", "an IAM permissions boundary", ["an IAM permissions boundary", "an Amazon Route 53 hosted zone", "an Amazon EBS snapshot", "an AWS Budgets alert"], "application"),
    item("Design Secure Architectures", "TLS certificates", "A public Application Load Balancer needs an AWS-managed TLS certificate for HTTPS. Which service should provide the certificate?", "AWS Certificate Manager", ["AWS Certificate Manager", "AWS Cost Explorer", "Amazon S3 Inventory", "Amazon Kinesis Data Firehose"], "scenario"),
    item("Design Secure Architectures", "Presigned object access", "A private S3 object must be downloadable by a user for a short time without making the bucket public. Which approach should be used?", "an Amazon S3 presigned URL", ["an Amazon S3 presigned URL", "an Amazon EC2 key pair", "an AWS CloudTrail lookup event", "an Amazon VPC route table"], "scenario"),
    item("Design Secure Architectures", "Interface endpoints", "Applications in private subnets need private connectivity to AWS services such as AWS Secrets Manager. Which VPC feature should be used?", "an interface VPC endpoint", ["an interface VPC endpoint", "a public internet gateway only", "an Amazon S3 bucket notification", "an AWS Organizations account alias"], "scenario"),
    item("Design Secure Architectures", "Key policy control", "A KMS key must be usable only by a specific application role and key administrators. Which policy type directly controls access to the key?", "a KMS key policy", ["a KMS key policy", "an Amazon SQS redrive policy", "an Amazon Route 53 routing policy", "an Amazon EFS lifecycle policy"], "scenario"),
    item("Design Secure Architectures", "Central security findings", "A security team wants a centralized service to view and prioritize security findings from services such as GuardDuty and Inspector. Which service should be used?", "AWS Security Hub", ["AWS Security Hub", "AWS Cost and Usage Report", "Amazon CloudFront Functions", "Amazon RDS Proxy"], "scenario"),
    item("Design Secure Architectures", "S3 object ownership", "A bucket receives objects from another AWS account and the bucket owner must own the uploaded objects. Which S3 feature helps enforce this?", "S3 Object Ownership bucket owner enforced", ["S3 Object Ownership bucket owner enforced", "Amazon EC2 Auto Scaling warm pools", "AWS Lambda provisioned concurrency", "Amazon Route 53 geolocation routing"], "scenario"),
    item("Design Resilient Architectures", "Dead-letter queues", "Messages that fail processing repeatedly need to be isolated for later inspection without blocking the main queue. Which feature should be configured?", "an Amazon SQS dead-letter queue", ["an Amazon SQS dead-letter queue", "an Amazon CloudFront origin request policy", "an AWS KMS alias", "an Amazon EC2 placement group"], "scenario"),
    item("Design Resilient Architectures", "Aurora cross-region recovery", "A business-critical Aurora database requires low recovery time in another Region. Which feature is designed for this pattern?", "Amazon Aurora Global Database", ["Amazon Aurora Global Database", "Amazon EBS Fast Snapshot Restore", "AWS IAM Identity Center", "Amazon S3 Transfer Acceleration"], "scenario"),
    item("Design Resilient Architectures", "S3 regional copy", "Objects in one S3 bucket must be copied automatically to a bucket in another Region for disaster recovery. Which feature should be configured?", "S3 Cross-Region Replication", ["S3 Cross-Region Replication", "Amazon EC2 hibernation", "AWS Config conformance packs", "Amazon VPC traffic mirroring"], "scenario"),
    item("Design Resilient Architectures", "Multi-target event routing", "Several services need to react independently when an order status changes. Which event service can route events to multiple targets using rules?", "Amazon EventBridge", ["Amazon EventBridge", "Amazon EBS direct APIs", "AWS CloudHSM", "Amazon RDS Performance Insights"], "scenario"),
    item("Design Resilient Architectures", "Backup immutability", "A company needs backups protected against accidental or malicious deletion during a retention period. Which AWS Backup feature helps?", "AWS Backup Vault Lock", ["AWS Backup Vault Lock", "AWS CloudFormation drift detection", "Amazon CloudWatch metric math", "Amazon VPC IPAM"], "scenario"),
    item("Design Resilient Architectures", "EFS availability", "An application uses Amazon EFS across multiple Availability Zones. Which design supports availability for EC2 clients in each AZ?", "create mount targets in each required Availability Zone", ["create mount targets in each required Availability Zone", "place one NAT gateway in a single private subnet", "disable all security group rules", "store EFS data on instance store"], "scenario"),
    item("Design Resilient Architectures", "Blue green deployments", "A team wants to reduce deployment risk by shifting traffic between old and new application versions. Which strategy best matches this goal?", "blue green deployment", ["blue green deployment", "single instance replacement", "manual database password rotation", "one-zone storage only"], "scenario"),
    item("Design Resilient Architectures", "Health-based routing", "An application has endpoints in two Regions and should route around unhealthy endpoints. Which Route 53 feature is needed?", "health checks with failover routing", ["health checks with failover routing", "private DNS names only", "weighted records without health checks", "domain privacy protection"], "scenario"),
    item("Design High-Performing Architectures", "Aurora read scaling", "A read-heavy Aurora workload needs to scale read traffic away from the writer instance. Which feature should be used?", "Aurora Replicas", ["Aurora Replicas", "AWS Budgets reports", "Amazon S3 Object Lock", "AWS CloudTrail Lake"], "scenario"),
    item("Design High-Performing Architectures", "Lambda cold start reduction", "A latency-sensitive Lambda function must reduce cold start impact for predictable traffic. Which feature should be configured?", "Lambda provisioned concurrency", ["Lambda provisioned concurrency", "Amazon S3 Versioning", "AWS Organizations tag policies", "Amazon EBS encryption by default"], "scenario"),
    item("Design High-Performing Architectures", "Compute placement", "A high-performance computing workload needs low-latency network performance between EC2 instances. Which placement strategy should be used?", "a cluster placement group", ["a cluster placement group", "a spread placement group for every instance", "an Amazon S3 access point", "an AWS Cost Explorer report"], "scenario"),
    item("Design High-Performing Architectures", "EBS performance", "A database workload on EC2 needs predictable high IOPS block storage. Which storage option should be evaluated?", "Amazon EBS Provisioned IOPS volumes", ["Amazon EBS Provisioned IOPS volumes", "Amazon S3 Glacier Deep Archive", "Amazon Route 53 Resolver DNS Firewall", "AWS IAM Access Analyzer"], "scenario"),
    item("Design High-Performing Architectures", "File system for compute", "A machine learning training job needs high-performance shared storage integrated with S3 datasets. Which service is designed for this?", "Amazon FSx for Lustre", ["Amazon FSx for Lustre", "AWS Secrets Manager", "Amazon Route 53 health checks", "AWS Artifact agreements"], "scenario"),
    item("Design High-Performing Architectures", "API response caching", "A REST API has repeated read requests and needs lower backend load. Which API Gateway feature can help?", "API Gateway caching", ["API Gateway caching", "AWS Backup Vault Lock", "Amazon EBS Multi-Attach", "AWS Organizations consolidated billing"], "scenario"),
    item("Design High-Performing Architectures", "CloudFront origin load", "A global application wants to improve cache hit ratio and reduce repeated requests to the origin. Which CloudFront feature can help?", "CloudFront Origin Shield", ["CloudFront Origin Shield", "AWS CloudHSM key rotation", "Amazon VPC Flow Logs", "AWS Database Migration Service"], "scenario"),
    item("Design High-Performing Architectures", "DynamoDB hot keys", "A DynamoDB table has uneven traffic concentrated on one partition key. What should the architect improve?", "the partition key design", ["the partition key design", "the AWS Support plan name", "the S3 bucket ACL owner", "the CloudTrail event history filter"], "scenario"),
    item("Design Cost-Optimized Architectures", "Instance rightsizing", "A fleet of EC2 instances is consistently underutilized. Which action should be taken first for cost optimization?", "right-size or downsize the instances", ["right-size or downsize the instances", "move every instance to Dedicated Hosts", "disable all CloudWatch metrics", "store application logs on root volumes only"], "scenario"),
    item("Design Cost-Optimized Architectures", "Auto Scaling scale-in", "A workload has predictable low-traffic periods. Which design reduces cost while preserving availability during demand spikes?", "configure Auto Scaling to scale in during low demand", ["configure Auto Scaling to scale in during low demand", "keep maximum capacity running all day", "disable load balancer health checks", "use a single root user for deployments"], "scenario"),
    item("Design Cost-Optimized Architectures", "S3 expiration", "Temporary objects must be deleted automatically after 30 days. Which feature should be configured?", "an S3 Lifecycle expiration rule", ["an S3 Lifecycle expiration rule", "an AWS Shield response team case", "an Amazon RDS read replica", "an Amazon Route 53 failover record"], "scenario"),
    item("Design Cost-Optimized Architectures", "Cost anomaly detection", "A team wants automated alerts for unusual AWS spending patterns. Which service should be used?", "AWS Cost Anomaly Detection", ["AWS Cost Anomaly Detection", "AWS Certificate Manager", "Amazon EC2 Image Builder", "Amazon VPC Reachability Analyzer"], "scenario"),
    item("Design Cost-Optimized Architectures", "Reserved capacity scope", "A database runs continuously and predictably on Amazon RDS. Which purchase option can reduce cost for the database?", "Amazon RDS Reserved Instances", ["Amazon RDS Reserved Instances", "Amazon S3 presigned URLs", "AWS WAF managed rules", "Amazon SQS visibility timeout"], "scenario"),
    item("Design Cost-Optimized Architectures", "Spot interruption fit", "Which workload is the best fit for Spot Instances?", "fault-tolerant batch processing that can be interrupted", ["fault-tolerant batch processing that can be interrupted", "a single database requiring no interruption", "a control plane that cannot restart", "a legacy license tied to one host"], "scenario"),
    item("Design Cost-Optimized Architectures", "Compute Optimizer signal", "Which information does AWS Compute Optimizer primarily use to recommend rightsizing?", "resource utilization metrics", ["resource utilization metrics", "IAM password policy names", "Route 53 domain registration dates", "S3 object legal hold text"], "scenario"),
    item("Design Cost-Optimized Architectures", "Architecture cost tradeoff", "A company pays for NAT Gateway data processing from private subnets. Which design could reduce cost for traffic to supported AWS services?", "use VPC endpoints for supported services", ["use VPC endpoints for supported services", "route all traffic through another NAT gateway", "disable security groups on instances", "copy all data to instance store"], "scenario")
  ];
}

function solutionsArchitectQuestionBank() {
  return [
    ...solutionsArchitectSeedQuestions(),
    ...solutionsArchitectSupplementalSeedQuestions(),
    ...solutionsArchitectAdvancedSeedQuestions(),
    ...solutionsArchitectProductionExpansionQuestions()
  ];
}

function solutionsArchitectProductionExpansionQuestions() {
  const genericDistractors = [
    "AWS Artifact",
    "AWS Budgets",
    "Amazon Route 53 domain registration",
    "Amazon EC2 instance store",
    "AWS CloudShell",
    "Amazon CloudWatch dashboards only",
    "AWS Support cases",
    "Amazon S3 static website hosting"
  ];
  const pickDistractors = (answer, preferred = []) => {
    const normalizedAnswer = normalizeText(answer);
    const choices = [...preferred, ...genericDistractors]
      .filter((choice) => normalizeText(choice) !== normalizedAnswer)
      .filter((choice, index, list) => list.findIndex((item) => normalizeText(item) === normalizeText(choice)) === index)
      .slice(0, 3);
    return [answer, ...choices];
  };
  const item = (topic, concept, prompt, answer, distractors, angle = "scenario", difficulty = 1.05) => ({
    topic,
    concept,
    segment: concept,
    source_excerpt: "QuizLoop SAA-C03 production expansion bank mapped to the official AWS exam guide domains.",
    assessment_angle: angle,
    canonical_prompt: prompt,
    canonical_answer: answer,
    accepted_answers: [answer],
    importance: topic === "Design Secure Architectures" ? 1 : topic === "Design Resilient Architectures" ? 0.95 : 0.9,
    difficulty,
    variants: [{
      delivery_type: "multiple_choice",
      prompt,
      answer,
      choices: pickDistractors(answer, distractors),
      rubric: `Tests ${concept} for Solutions Architect Associate readiness.`
    }]
  });
  const actionFor = (value) => {
    const clean = String(value || "").trim();
    if (/^(place|co-locate|move|use|enable|create|store|run|route|send|deliver|replicate|cache|encrypt|retain|archive)\b/i.test(clean)) {
      return clean.charAt(0).toUpperCase() + clean.slice(1);
    }
    if (/^(an?|the)\s/i.test(clean)) return `Configure ${clean.replace(/^(an?|the)\s+/i, "")}`;
    return `Configure ${clean}`;
  };
  const scenario = ({ topic, concept, stem, answer, distractors, reason, wrongReasons = [], difficulty = 1.05 }) => {
    const action = actionFor(answer);
    const actionDistractors = distractors.map(actionFor);
    const trapAnswer = distractors[0] || genericDistractors[0];
    return [
      item(topic, `${concept} service selection`, `${stem} Which option should the solutions architect choose?`, answer, distractors, "scenario", difficulty),
      item(topic, `${concept} implementation action`, `${stem} Which implementation action best matches the requirement?`, action, actionDistractors, "application", difficulty + 0.05),
      item(topic, `${concept} design rationale`, `${stem} Why is this design choice appropriate?`, reason, wrongReasons, "tradeoff", difficulty + 0.05),
      item(topic, `${concept} capability checkpoint`, `${stem} Which capability is the main reason this option fits?`, reason, wrongReasons, "detail", difficulty + 0.1),
      item(topic, `${concept} exam trap`, `${stem} Which choice is the weakest fit for this requirement?`, trapAnswer, [answer, ...distractors.slice(1)], "trap", difficulty + 0.1)
    ];
  };
  const secure = [
    ["IAM role for compute", "An application on Amazon EC2 needs to read from Amazon S3 without storing long-term credentials.", "an IAM role attached to the EC2 instance", ["an IAM user access key on the instance", "the AWS account root user", "a public S3 bucket policy"], "it provides temporary credentials through the instance profile", ["it makes the bucket public", "it removes the need for authorization", "it stores static credentials in user data"]],
    ["Cross-account role access", "A workload in one AWS account needs controlled access to resources in another account.", "a cross-account IAM role with a trust policy", ["a shared root user", "an unrestricted access key", "a public subnet"], "the trust policy defines which external principal can assume the role", ["it bypasses IAM evaluation", "it copies user passwords between accounts", "it disables CloudTrail logging"]],
    ["IAM Identity Center", "A company needs centralized workforce access to many AWS accounts with existing corporate identities.", "AWS IAM Identity Center", ["IAM access keys", "Amazon Cognito identity pools", "AWS Secrets Manager"], "it federates workforce identities and assigns permission sets across accounts", ["it replaces all application user pools", "it stores database credentials for workloads", "it creates VPC peering routes"]],
    ["KMS envelope encryption", "An application must encrypt sensitive records and use auditable key access.", "AWS Key Management Service", ["Amazon Route 53", "AWS Cost Explorer", "Amazon EFS lifecycle management"], "it centralizes key management and records key usage through AWS logging integrations", ["it accelerates DNS resolution", "it estimates monthly spend", "it replaces application authentication"]],
    ["Secrets rotation", "A database password must be stored securely and rotated automatically.", "AWS Secrets Manager", ["AWS Systems Manager Session Manager", "Amazon CloudFront", "AWS Shield Standard"], "it stores secrets securely and supports managed rotation workflows", ["it caches static web objects", "it manages DNS failover", "it reserves compute capacity"]],
    ["Private service access", "Instances in private subnets need to call AWS services without traversing the public internet.", "VPC endpoints", ["internet gateway only", "Elastic IP addresses on every instance", "public S3 website hosting"], "they provide private connectivity to supported AWS services from the VPC", ["they make instances publicly reachable", "they replace route tables for all traffic", "they disable security groups"]],
    ["S3 public access guardrail", "A company wants to reduce the chance that S3 buckets are accidentally exposed publicly.", "S3 Block Public Access", ["S3 Transfer Acceleration", "Amazon EBS encryption", "Amazon Route 53 Resolver"], "it blocks public ACLs and policies at the account or bucket level", ["it improves upload speed from remote users", "it provisions TLS certificates", "it rotates database credentials"]],
    ["S3 immutability", "Compliance requires records in S3 to be retained in a write-once-read-many model.", "S3 Object Lock", ["S3 Intelligent-Tiering", "Amazon EFS Access Points", "AWS CloudTrail Lake"], "it enforces retention so objects cannot be overwritten or deleted during the retention period", ["it automatically lowers storage cost based on access", "it shares POSIX files across EC2", "it signs temporary downloads"]],
    ["Web exploit filtering", "An internet-facing application must block common HTTP attacks such as SQL injection patterns.", "AWS WAF", ["AWS Transit Gateway", "Amazon SQS", "AWS Backup"], "it applies web ACL rules before requests reach the application", ["it asynchronously queues messages", "it creates centralized backups", "it connects thousands of VPCs"]],
    ["DDoS response", "A public application needs enhanced DDoS protection and access to specialized response support.", "AWS Shield Advanced", ["AWS Shield Standard only", "Amazon Inspector", "Amazon Macie"], "it adds advanced detection, mitigation, cost protection, and response support", ["it scans EC2 software vulnerabilities", "it discovers sensitive data in S3", "it creates DNS records"]],
    ["Sensitive data discovery", "Security teams need to discover and classify sensitive data stored in S3 buckets.", "Amazon Macie", ["AWS Certificate Manager", "Amazon EventBridge", "Amazon EBS snapshots"], "it uses managed data discovery to identify sensitive information in S3", ["it provisions public TLS certificates", "it routes application events", "it creates block storage backups"]],
    ["Central findings", "A company wants one place to aggregate and prioritize security findings from GuardDuty, Inspector, and other services.", "AWS Security Hub", ["AWS Config only", "Amazon CloudFront", "AWS DataSync"], "it consolidates security findings and maps them to security standards", ["it migrates files from on premises", "it caches content globally", "it stores relational data"]],
    ["Network inspection", "Traffic between subnets must be inspected by managed firewall rules.", "AWS Network Firewall", ["AWS WAF only", "Amazon Route 53", "AWS CloudFormation StackSets"], "it provides managed stateful network inspection in the VPC path", ["it only filters Layer 7 web requests", "it registers domain names", "it deploys stacks across accounts"]],
    ["S3 access analysis", "An architect needs to identify S3 buckets or IAM roles that allow external access.", "IAM Access Analyzer", ["AWS Budgets", "Amazon CloudWatch Logs Insights", "Amazon ECR"], "it analyzes policies to find resources shared outside the intended zone of trust", ["it forecasts monthly costs", "it queries log text", "it stores container images"]],
    ["Private application access", "Employees need private access to internal web applications without exposing them directly to the internet.", "AWS Verified Access", ["public Application Load Balancer only", "Amazon S3 website endpoint", "AWS Batch"], "it evaluates identity and device context before granting application access", ["it removes identity checks", "it is only for batch jobs", "it publishes static files"]],
    ["Certificate automation", "A public load balancer needs managed TLS certificates with automatic renewal.", "AWS Certificate Manager", ["AWS Secrets Manager", "Amazon GuardDuty", "Amazon EBS"], "it provisions and renews public certificates for integrated AWS services", ["it detects malicious account behavior", "it stores block volumes", "it rotates database passwords"]],
    ["Config compliance", "A regulated workload needs continuous checks that resources remain configured according to rules.", "AWS Config rules", ["Amazon Athena", "Amazon Kinesis Data Streams", "AWS Snowball"], "they evaluate resource configuration changes against compliance rules", ["they ingest streaming records", "they transfer offline data", "they query S3 data with SQL"]],
    ["Private API access", "A private API should be reachable only from specific VPCs.", "API Gateway private API with VPC endpoint policy", ["edge-optimized public API only", "public S3 bucket policy", "internet gateway route"], "the API endpoint and endpoint policy restrict access to private VPC paths", ["it exposes the API globally by default", "it makes S3 public", "it avoids authorization entirely"]],
    ["CloudFront private content", "Paid video content should be delivered through CloudFront only to authorized viewers.", "CloudFront signed URLs or signed cookies", ["public S3 object ACLs", "AWS Budgets alerts", "Amazon EBS encryption only"], "signed URLs or cookies restrict access to private content at the distribution edge", ["public ACLs expose content", "budget alerts do not authorize viewers", "block encryption does not control CDN access"]]
  ];
  const resilient = [
    ["Multi-AZ web tier", "A web application must continue running if one Availability Zone fails.", "deploy across multiple Availability Zones behind a load balancer", ["single EC2 instance in one subnet", "one NAT gateway for all tiers only", "manual DNS edits after failure"], "it removes a single-AZ dependency and routes traffic only to healthy targets", ["it depends on manual recovery", "it stores state on one instance", "it disables health checks"]],
    ["RDS automatic failover", "A relational database needs standby capacity and automatic failover inside a Region.", "Amazon RDS Multi-AZ deployment", ["RDS read replica only", "Amazon S3 Versioning", "AWS Backup copy only"], "Multi-AZ keeps a synchronous standby for high availability", ["read replicas are always synchronous failover targets", "object versioning replaces database failover", "backup copies keep the database online"]],
    ["Aurora reader endpoint", "A read-heavy Aurora application needs to spread reads across replicas.", "Aurora reader endpoint", ["Aurora cluster endpoint for every read", "AWS Config aggregator", "Amazon SNS FIFO topic"], "it load balances read traffic across available Aurora Replicas", ["it sends every read to the writer", "it evaluates compliance rules", "it preserves message ordering"]],
    ["SQS buffering", "Spiky request traffic must not overwhelm a backend worker service.", "Amazon SQS queue between producers and workers", ["direct synchronous calls only", "Amazon EBS Multi-Attach", "AWS Artifact"], "the queue buffers work so consumers can process at their own rate", ["it requires every component to scale at the same moment", "it shares block storage across all workers", "it downloads compliance reports"]],
    ["EventBridge decoupling", "Several services need to react independently when an order status changes.", "Amazon EventBridge event bus and rules", ["one shared database trigger only", "AWS Cost Explorer", "Amazon EC2 key pairs"], "it routes events to multiple targets without tight service coupling", ["it estimates costs", "it grants SSH access", "it forces point-to-point dependencies"]],
    ["Step Functions orchestration", "A business workflow has retries, branching, and multiple service calls.", "AWS Step Functions", ["Amazon CloudFront", "Amazon EBS snapshots", "AWS Shield Standard"], "it coordinates workflow state, retries, and service integrations", ["it caches static content", "it creates block snapshots", "it only mitigates common DDoS attacks"]],
    ["S3 replication", "Critical objects must be available in a second Region for disaster recovery.", "S3 Cross-Region Replication", ["S3 lifecycle expiration only", "Amazon EFS One Zone", "AWS Budgets"], "it automatically copies eligible objects to a bucket in another Region", ["it deletes objects after a retention period", "it stores files in one AZ", "it alerts on spend"]],
    ["DynamoDB global app", "A global application needs low-latency reads and writes in multiple Regions.", "DynamoDB global tables", ["DynamoDB local secondary indexes only", "Amazon RDS single-AZ", "Amazon EBS snapshots"], "they provide multi-Region, active-active replication for DynamoDB tables", ["they only change sort-key query patterns", "they keep one database instance", "they are offline backups"]],
    ["Route 53 failover", "Users should be routed to a healthy secondary endpoint when the primary health check fails.", "Route 53 failover routing", ["Route 53 simple routing only", "AWS IAM Identity Center", "Amazon Inspector"], "health checks can control DNS answers for primary and secondary endpoints", ["simple routing has no health-based failover", "identity federation controls sign-in", "vulnerability scans route users"]],
    ["CloudFront origin failover", "A CDN distribution should use a secondary origin when the primary origin returns errors.", "CloudFront origin failover", ["CloudFront signed cookies only", "AWS Backup Vault Lock", "Amazon VPC Flow Logs"], "origin groups can retry requests against a secondary origin", ["signed cookies are only an access control mechanism", "backup immutability does not route traffic", "flow logs record network metadata"]],
    ["Auto Scaling recovery", "Unhealthy application instances must be replaced automatically.", "EC2 Auto Scaling with health checks", ["manual instance replacement", "S3 Object Lock", "AWS CloudTrail lookup events"], "Auto Scaling can terminate unhealthy instances and launch replacements", ["it requires human intervention for every failure", "it enforces object retention", "it searches audit events"]],
    ["Elastic Beanstalk deployment", "A team wants managed deployment policies such as rolling and immutable deployments for a web app.", "AWS Elastic Beanstalk deployment policies", ["AWS Artifact reports", "Amazon S3 Transfer Acceleration", "Amazon Macie"], "the service manages application version deployment patterns and health", ["it accelerates object uploads", "it classifies sensitive data", "it downloads agreements"]],
    ["Backup centralization", "Multiple AWS services need centrally managed backup plans and cross-account backup governance.", "AWS Backup", ["Amazon CloudFront", "AWS Cloud9", "Amazon API Gateway cache"], "it centrally defines backup plans, vaults, and supported service backups", ["it is an IDE", "it caches API responses", "it distributes content globally"]],
    ["Backup immutability", "Backups must be protected from deletion during a retention window.", "AWS Backup Vault Lock", ["S3 Intelligent-Tiering", "Amazon Route 53 Resolver", "AWS License Manager"], "it enforces retention and write-once-read-many style protection for backup vaults", ["it optimizes object storage cost", "it resolves DNS", "it tracks licenses"]],
    ["DMS migration resilience", "An on-premises database migration must keep source and target in sync with minimal downtime.", "AWS Database Migration Service with ongoing replication", ["AWS Snowball Edge only", "manual full exports", "Amazon EBS direct APIs"], "ongoing replication reduces cutover downtime during migration", ["offline transfer alone does not keep changes synchronized", "manual exports increase downtime", "block APIs do not migrate database changes"]],
    ["EFS regional file system", "A shared file system must remain available across multiple Availability Zones.", "Amazon EFS Regional file system", ["Amazon EFS One Zone", "EC2 instance store", "Amazon S3 Glacier Deep Archive"], "Regional EFS stores data redundantly across multiple Availability Zones", ["One Zone keeps data in one AZ", "instance store is tied to the instance", "archive storage is not a mounted file system"]],
    ["RDS point-in-time restore", "A database team must recover from accidental data changes to a recent point in time.", "RDS automated backups with point-in-time restore", ["RDS read replica promotion only", "Amazon S3 Transfer Acceleration", "AWS WAF managed rules"], "automated backups support restoring the database to a specific time within the retention window", ["read replicas are not a complete accidental-change recovery plan", "transfer acceleration speeds uploads", "WAF filters web requests"]]
  ];
  const performance = [
    ["DynamoDB low latency", "A key-value workload needs consistent single-digit millisecond access at scale.", "Amazon DynamoDB", ["Amazon RDS for every key-value request", "Amazon EFS", "AWS Batch"], "it is a managed NoSQL service designed for high-scale low-latency key-value access", ["relational engines are not always the best key-value fit", "shared file storage is not a key-value database", "batch jobs do not serve online requests"]],
    ["DAX caching", "A DynamoDB read-heavy application needs microsecond read performance for eventually consistent reads.", "DynamoDB Accelerator (DAX)", ["Amazon ElastiCache for Memcached only", "AWS WAF", "Amazon EBS io2"], "DAX is an in-memory cache purpose-built for DynamoDB read acceleration", ["WAF filters web traffic", "EBS io2 is block storage", "Memcached is not integrated as a DynamoDB cache layer"]],
    ["ElastiCache session cache", "A web application needs an in-memory cache for session data and frequently read values.", "Amazon ElastiCache", ["Amazon S3 Glacier", "AWS CloudTrail", "AWS Organizations"], "it provides managed Redis or Memcached caching for low-latency reads", ["archive storage is not a cache", "audit logs do not cache application data", "organizations manage accounts"]],
    ["RDS Proxy scaling", "A serverless application opens many short-lived connections to an RDS database.", "Amazon RDS Proxy", ["AWS Global Accelerator", "Amazon Macie", "Amazon EBS snapshots"], "it pools and manages database connections for scalable application access", ["it optimizes internet routing", "it discovers sensitive data", "snapshots are backups"]],
    ["CloudFront global cache", "A global user base needs low-latency access to static and cacheable content.", "Amazon CloudFront", ["AWS Direct Connect", "AWS Secrets Manager", "Amazon SQS"], "edge caching reduces latency and origin load for distributed users", ["private circuits do not cache content", "secrets storage does not deliver content", "queues do not serve web assets"]],
    ["Global Accelerator latency", "A TCP application needs static Anycast IPs and optimized routing to healthy Regional endpoints.", "AWS Global Accelerator", ["Amazon CloudFront signed URLs", "AWS Config", "Amazon EFS"], "it uses the AWS global network to route users to healthy endpoints with static Anycast IPs", ["signed URLs control access to content", "config evaluates resources", "EFS is file storage"]],
    ["Kinesis streaming", "Clickstream events must be ingested continuously and processed in near real time.", "Amazon Kinesis Data Streams", ["AWS Glue Data Catalog only", "Amazon S3 Glacier", "AWS Shield"], "it captures and stores streaming records for consumers to process", ["a catalog only stores metadata", "archive storage is not near-real-time ingestion", "DDoS protection does not ingest events"]],
    ["Firehose delivery", "Streaming events need simple managed delivery into S3 with optional transformation.", "Amazon Data Firehose", ["Amazon Route 53", "AWS Backup", "IAM Access Analyzer"], "it manages loading streaming data into destinations such as S3 and Redshift", ["DNS does not load streams", "backup services do not ingest streams", "policy analysis does not deliver records"]],
    ["FSx Lustre HPC", "A high-performance compute job needs a parallel file system linked to S3 datasets.", "Amazon FSx for Lustre", ["Amazon EFS One Zone", "AWS Secrets Manager", "Amazon RDS Proxy"], "it is designed for high-performance workloads and can integrate with S3", ["Secrets Manager stores credentials", "RDS Proxy handles DB connections", "EFS One Zone is not the HPC parallel file system choice"]],
    ["EBS io2 database", "A self-managed database on EC2 needs high durability and provisioned IOPS block storage.", "Amazon EBS io2 volumes", ["Amazon S3 Standard", "AWS WAF", "Amazon SNS"], "io2 provides durable block storage with provisioned IOPS for demanding workloads", ["S3 is object storage", "WAF filters web requests", "SNS publishes messages"]],
    ["Placement group HPC", "EC2 instances need very low network latency between each other for tightly coupled processing.", "cluster placement group", ["partition placement group", "spread placement group for maximum separation", "public subnet only"], "cluster placement places instances close together for low-latency networking", ["partition placement separates groups for distributed systems", "spread placement maximizes separation", "subnet type alone does not optimize placement"]],
    ["ALB routing", "HTTP requests need path-based routing to different target groups.", "Application Load Balancer", ["Network Load Balancer", "Gateway Load Balancer", "AWS Transit Gateway"], "ALB supports Layer 7 routing rules such as host and path conditions", ["NLB is Layer 4", "Gateway Load Balancer is for appliances", "Transit Gateway connects networks"]],
    ["NLB latency", "A TCP workload requires very high throughput and static IP support.", "Network Load Balancer", ["Application Load Balancer", "AWS WAF", "Amazon CloudFront Functions"], "NLB handles Layer 4 traffic at high performance and can use static IPs", ["ALB is better for Layer 7 HTTP rules", "WAF is web filtering", "CloudFront Functions run at the edge"]],
    ["S3 Transfer Acceleration", "Remote users upload large objects to S3 from distant geographic locations.", "S3 Transfer Acceleration", ["S3 Object Lock", "Amazon EBS snapshots", "AWS KMS aliases"], "it uses AWS edge locations to accelerate long-distance transfers into S3", ["Object Lock enforces retention", "snapshots back up block volumes", "aliases identify KMS keys"]],
    ["Athena ad hoc analytics", "Analysts need serverless SQL queries directly against data stored in Amazon S3.", "Amazon Athena", ["Amazon RDS Proxy", "AWS DataSync", "Amazon MQ"], "Athena runs SQL on S3 data without managing query servers", ["RDS Proxy manages DB connections", "DataSync transfers files", "MQ is message broker service"]],
    ["OpenSearch search", "An application needs managed full-text search and log analytics capabilities.", "Amazon OpenSearch Service", ["Amazon SQS", "AWS Backup", "Amazon ECR"], "it provides managed search and analytics for text and log data", ["queues decouple messages", "backup manages recovery points", "ECR stores container images"]],
    ["Aurora Serverless scaling", "A relational workload has variable demand and needs capacity to scale automatically with minimal administration.", "Amazon Aurora Serverless v2", ["Amazon RDS magnetic storage", "Amazon EC2 Dedicated Hosts", "AWS Artifact"], "it adjusts database capacity automatically for variable relational workloads", ["magnetic storage is legacy storage", "Dedicated Hosts solve host isolation needs", "Artifact provides compliance documents"]]
  ];
  const cost = [
    ["Compute Savings Plans", "A steady compute workload spans several instance families and needs commitment-based discounts.", "Compute Savings Plans", ["EC2 Instance Savings Plans only", "Spot Instances for noninterruptible work", "Dedicated Hosts for every workload"], "they provide flexible discounts for eligible compute usage in exchange for a commitment", ["Spot can be interrupted", "Dedicated Hosts solve licensing/isolation more than broad savings", "instance-only plans are less flexible"]],
    ["Spot batch", "A batch processing workload can checkpoint progress and tolerate interruption.", "EC2 Spot Instances", ["On-Demand Instances only", "Reserved Instances for all capacity", "Dedicated Hosts"], "Spot can reduce cost for fault-tolerant interruptible workloads", ["On-Demand is flexible but usually higher cost", "Reserved capacity is for predictable steady use", "Dedicated Hosts are for host-level needs"]],
    ["S3 lifecycle", "Objects are frequently accessed for 30 days and then rarely read for years.", "S3 Lifecycle policy", ["S3 Block Public Access", "Amazon EBS Fast Snapshot Restore", "AWS Global Accelerator"], "lifecycle rules transition or expire objects automatically based on age", ["public access controls do not move storage classes", "snapshot restore is for EBS", "routing acceleration does not manage object cost"]],
    ["S3 Intelligent-Tiering", "A dataset has unknown access patterns and should automatically move between access tiers.", "S3 Intelligent-Tiering", ["S3 One Zone-IA for all objects", "Amazon EFS Standard only", "Amazon RDS Reserved Instances"], "it monitors access patterns and moves objects to cost-effective tiers", ["One Zone-IA has availability tradeoffs", "EFS is file storage", "RDS reservations apply to databases"]],
    ["VPC endpoint cost", "Private subnets send large amounts of traffic to S3 through a NAT gateway.", "gateway VPC endpoint for Amazon S3", ["additional NAT gateways for S3 traffic", "public IPs on every instance", "AWS Shield Advanced"], "it keeps S3 traffic private and can reduce NAT data processing charges", ["more NAT gateways do not remove S3 data processing", "public IPs increase exposure", "Shield protects against DDoS"]],
    ["CloudFront cost", "A popular site repeatedly serves the same static files from an origin in one Region.", "Amazon CloudFront caching", ["larger origin instances only", "manual object downloads", "AWS Config remediation"], "caching reduces repeated origin requests and data transfer from the origin", ["bigger origins do not reduce repeated transfer", "manual downloads are not scalable", "config remediation is compliance automation"]],
    ["Compute Optimizer", "EC2 and Lambda resources appear over-provisioned and need rightsizing recommendations.", "AWS Compute Optimizer", ["AWS Artifact", "Amazon Macie", "AWS Certificate Manager"], "it analyzes utilization metrics and recommends resource sizing changes", ["Artifact provides compliance documents", "Macie classifies sensitive data", "ACM manages certificates"]],
    ["Trusted Advisor cost", "An account needs checks for idle load balancers and underutilized resources.", "AWS Trusted Advisor", ["Amazon GuardDuty", "Amazon Kinesis", "AWS Step Functions"], "it includes cost optimization checks for common waste patterns", ["GuardDuty detects threats", "Kinesis ingests streams", "Step Functions orchestrates workflows"]],
    ["Reserved RDS", "A production RDS database runs continuously with predictable usage.", "Amazon RDS Reserved Instances", ["DynamoDB on-demand mode", "EC2 Spot Instances", "Amazon S3 Object Lock"], "reserved database capacity can lower cost for steady database workloads", ["on-demand is for variable DynamoDB usage", "Spot is interruptible compute", "Object Lock is retention"]],
    ["DynamoDB capacity mode", "A DynamoDB workload has unpredictable traffic and the team wants to avoid capacity planning.", "DynamoDB on-demand capacity mode", ["provisioned capacity without auto scaling", "RDS Reserved Instances", "Amazon EBS Cold HDD"], "on-demand charges per request and handles unpredictable traffic without planning throughput", ["provisioned capacity requires planning", "RDS reservations are unrelated", "EBS is block storage"]],
    ["Graviton price performance", "A Linux application can run on ARM and needs better compute price performance.", "AWS Graviton instances", ["Dedicated Hosts only", "Mac instances", "GPU instances for all workloads"], "Graviton can improve price performance for compatible workloads", ["Dedicated Hosts solve licensing/isolation", "Mac instances target Apple workloads", "GPU instances target accelerated computing"]],
    ["Cost allocation", "Finance needs to show AWS spend by team, environment, and application.", "cost allocation tags", ["security groups", "NACL ephemeral ports", "S3 presigned URLs"], "tags let billing reports group and allocate costs by business dimensions", ["security controls do not classify spend", "network ports do not organize billing", "presigned URLs grant temporary object access"]],
    ["Cost anomaly alerts", "A team wants alerts when AWS spend unexpectedly changes from normal patterns.", "AWS Cost Anomaly Detection", ["AWS Network Firewall", "Amazon RDS Proxy", "AWS IAM Identity Center"], "it detects unusual spend patterns and can notify teams", ["Network Firewall inspects traffic", "RDS Proxy pools connections", "Identity Center federates users"]],
    ["License optimization", "A company brings existing software licenses and must track usage against license terms.", "AWS License Manager", ["AWS CloudTrail Lake", "Amazon S3 Transfer Acceleration", "Amazon SNS"], "it helps manage license usage and rules across AWS and on premises", ["CloudTrail Lake stores audit events", "Transfer Acceleration speeds uploads", "SNS publishes notifications"]],
    ["Serverless cost fit", "A workload runs only in response to occasional events and is idle most of the day.", "AWS Lambda", ["always-on EC2 fleet", "Dedicated Hosts", "provisioned RDS writer only"], "pay-per-invocation serverless compute can avoid idle capacity cost", ["always-on fleets pay while idle", "Dedicated Hosts are not usually lowest-cost for bursts", "RDS writer does not run code"]],
    ["Data transfer placement", "Two chatty services frequently exchange large volumes of data across Availability Zones.", "place tightly coupled components in the same Availability Zone when availability requirements allow", ["force all traffic through a NAT gateway", "copy IAM users between accounts", "disable encryption everywhere"], "reducing unnecessary cross-AZ data transfer can lower network cost", ["NAT gateways can add processing charges", "IAM users do not affect transfer cost", "disabling encryption is not a cost strategy"]],
    ["EBS gp3 migration", "A workload uses older EBS volume types and needs lower storage cost with independently configurable performance.", "migrate suitable volumes to Amazon EBS gp3", ["move all data to io2 Block Express", "store database files in AWS Artifact", "use Dedicated Hosts for storage"], "gp3 can lower cost while allowing IOPS and throughput to be configured separately", ["io2 Block Express targets extreme performance needs", "Artifact is not storage for database files", "Dedicated Hosts are compute hosts"]]
  ];
  return [
    ...secure.flatMap(([concept, stem, answer, distractors, reason, wrongReasons]) => scenario({ topic: "Design Secure Architectures", concept, stem, answer, distractors, reason, wrongReasons })),
    ...resilient.flatMap(([concept, stem, answer, distractors, reason, wrongReasons]) => scenario({ topic: "Design Resilient Architectures", concept, stem, answer, distractors, reason, wrongReasons })),
    ...performance.flatMap(([concept, stem, answer, distractors, reason, wrongReasons]) => scenario({ topic: "Design High-Performing Architectures", concept, stem, answer, distractors, reason, wrongReasons })),
    ...cost.flatMap(([concept, stem, answer, distractors, reason, wrongReasons]) => scenario({ topic: "Design Cost-Optimized Architectures", concept, stem, answer, distractors, reason, wrongReasons }))
  ];
}

function quizSizeForNote(note) {
  if (isCertificationNote(note)) return 10;
  return 8;
}

function certificationQuizDomainTargets(note, quizSize = quizSizeForNote(note)) {
  const domains = certificationDomainsFor(note);
  const initial = domains.map((domain) => {
    const exact = domain.weight * quizSize;
    return {
      title: domain.title,
      target: Math.floor(exact),
      remainder: exact - Math.floor(exact)
    };
  });
  let assigned = initial.reduce((sum, item) => sum + item.target, 0);
  for (const item of [...initial].sort((left, right) => right.remainder - left.remainder)) {
    if (assigned >= quizSize) break;
    item.target += 1;
    assigned += 1;
  }
  const targets = new Map();
  for (const item of initial) targets.set(item.title, Math.max(1, item.target));
  return targets;
}

function cloudPractitionerDomainFor(value) {
  const text = normalizeText(value);
  let best = cloudPractitionerDomains[0];
  let bestScore = 0;
  for (const domain of cloudPractitionerDomains) {
    const score = domain.keywords.reduce((sum, keyword) => (
      text.includes(normalizeText(keyword)) ? sum + 1 : sum
    ), 0);
    if (score > bestScore) {
      best = domain;
      bestScore = score;
    }
  }
  return best;
}

function certificationDomainFor(note, value) {
  const domains = certificationDomainsFor(note);
  const text = normalizeText(value);
  let best = domains[0];
  let bestScore = 0;
  for (const domain of domains) {
    const score = domain.keywords.reduce((sum, keyword) => (
      text.includes(normalizeText(keyword)) ? sum + 1 : sum
    ), 0);
    if (score > bestScore) {
      best = domain;
      bestScore = score;
    }
  }
  return best;
}

function minimumQuestionBankFor(note) {
  if (isMathNote(note)) return 2;
  if (isCertificationNote(note)) return quizSizeForNote(note);
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
  const safeTarget = isMathNote(note)
    ? 4
    : isCertificationNote(note)
      ? Math.min(12, Math.max(10, target))
      : Math.min(8, Math.max(5, target));
  const sourceText = sourceTextForGeneration(note, isMathNote(note) ? 2200 : isBookSourceType(note?.sourceType) ? 4200 : isCertificationNote(note) ? 3600 : 2600);
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
  if (isCertificationNote(note)) {
    return `
You are creating certification prep questions for QuizLoop.ai.
Use ONLY the note text. Do not use outside facts.
Do not create exam dumps. Do not imitate private or copyrighted exam questions.
Create exactly ${safeTarget} useful multiple-choice question objects.
Prioritize scenario judgment, service tradeoffs, definitions, shared responsibility, cost/security/resilience reasoning, and common traps supported by the note.
Every prompt should help the learner prepare for a certification exam by testing a decision or concept, not by memorizing a random phrase.
Do not ask meta questions about the note template, high-yield study areas, listed practice goals, or what the learner wants to practice.
Ask the actual certification concept directly.
	For AWS certification notes, organize questions across the note's official-style domain mix:
	${certificationDomainsFor(note).map((domain) => `- ${domain.title}: ${Math.round(domain.weight * 100)}% of scored prep`).join("\n")}
	Prefer the highest-weighted domains when the note supports them.
Avoid duplicate prompts. Avoid multiple questions with the same correct answer.
Every multiple_choice variant must have exactly 4 choices and one exact answer that appears in choices.
Make distractors plausible and close, but clearly wrong based on the note.
Do not use tiny actor-label choices such as "AWS", "customers", "data", or "security" as standalone answer choices unless the question is explicitly asking for an actor label.
For responsibility, pricing, architecture, or service-selection questions, every choice should be a full phrase or a recognizable AWS service/tool name.
Return valid JSON only. No markdown. No commentary.

Return only JSON:
{
  "summary": "2 sentence student-friendly summary",
  "questions": [
    {
	      "topic": "${certificationDomainsFor(note).map((domain) => domain.title).join(" | ")}",
      "concept": "specific exam concept",
      "segment": "specific service, scenario, or trap",
      "source_excerpt": "exact note-backed text this question tests",
      "assessment_angle": "definition | scenario | tradeoff | security | cost | resilience | trap",
      "canonical_prompt": "stable question object",
      "canonical_answer": "source-backed answer",
      "accepted_answers": ["equivalent answer"],
      "importance": 0.8,
      "difficulty": 0.6,
      "variants": [
        {
          "delivery_type": "multiple_choice",
          "prompt": "certification-style MC prompt",
          "answer": "correct choice",
          "choices": ["correct choice", "plausible distractor", "plausible distractor", "plausible distractor"],
          "rubric": "what decision or concept must be known"
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

function multipleChoiceQuestionRows(noteId) {
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
  `, { json: true });
}

function viableQuestionRows(noteId, note = null) {
  const sourceNote = note || noteSummary(noteId);
  return multipleChoiceQuestionRows(noteId).filter((row) => !isLowQualityQuestion(row, sourceNote));
}

function viableQuestionCount(noteId, note = null) {
  return viableQuestionRows(noteId, note).length;
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

function repairQuestionPrompt(prompt) {
  return String(prompt || "")
    .replace(
      /\bObjects are accessed milliseconds when needed but are rarely accessed\b/gi,
      "Objects must be retrieved in milliseconds when needed but are rarely accessed"
    )
    .trim();
}

function validatedMultipleChoiceVariant(variant, fallbackPrompt, fallbackAnswer) {
  const prompt = repairQuestionPrompt(variant.prompt || fallbackPrompt || "");
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
  const prompt = String(question.variant_prompt || question.canonical_prompt || question.prompt || question.variants?.[0]?.prompt || "").trim();
  const answer = String(question.variant_answer || question.canonical_answer || question.answer || question.variants?.[0]?.answer || "").trim();
  const normalizedPrompt = normalizeText(prompt);
  if (!prompt || !answer) return true;
  if (hasRepeatedAdjacentWords(prompt)) return true;
  if (isCertificationNote(note) && usesOfficialCertificationDomains(note)) {
    const promptWords = normalizedPrompt.split(" ").filter(Boolean).length;
    if (promptWords < 5 || prompt.length < 28) return true;
    const officialTopics = new Set(certificationDomainsFor(note).map((domain) => normalizeText(domain.title)));
    if (!officialTopics.has(normalizeText(question.topic || ""))) return true;
  }
  if (isCertificationNote(note)) {
    const ambiguousSingleSelectPatterns = [
      /\bwhich of the following\b[^?]*\bare\b/i,
      /\bwhich of the following (strategies|methods|options|statements|services|features|functions)\b[^?]*\b(help|support|enable|allow|provide)\b/i,
      /\bwhich functions can\b/i,
      /\bwhich (aws )?(services|features|statements|options|benefits|advantages)\b[^?]*\bare\b/i,
      /\bwhat are the (advantages|benefits|components|services|features)\b/i
    ];
    if (ambiguousSingleSelectPatterns.some((pattern) => pattern.test(prompt))) return true;
  }

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
  if (isCertificationNote(note) && choices.length > 0 && hasWeakCertificationChoices({ prompt, choices })) return true;

  const blockedMetaPatterns = [
    /\bpractice to practice\b/i,
    /\bwhat (do|should|would) you want to practice\b/i,
    /\bwhat type of .* should you practice\b/i,
    /\bwhat .* should .* focus\b/i,
    /\bwhat is the focus area when learning\b/i,
    /\bwhich skill should you focus on\b/i,
    /\bwhat does .* aim to test\b/i,
    /\bgoal of understanding the distinction\b/i,
    /\btelling similar .* apart\b.*\b(test|focus|goal|skill)\b/i,
    /\b(candidate|learner|student)\b.*\b(focus|practice|study|prepare)\b/i,
    /\bfocus on when dealing with\b/i,
    /\bprimary goal of studying\b/i,
    /\bmain objective for building readiness\b/i,
    /\bobjective when studying\b/i,
    /\bnot explicitly listed\b/i,
    /\bwhich concept is not .*listed\b/i,
    /\bexam goal\b/i,
    /\bstudy notes? (are|were )?provided\b/i,
    /\bpersonalize the question bank\b/i,
    /\bwhich .* is listed\b/i,
    /\baccording to .*high[- ]yield\b/i,
    /\bhigh[- ]yield\b/i,
    /\bwhich .* (are|is) specifically mentioned\b/i,
    /\bwhich .* (are|is) mentioned\b/i,
    /\bmentioned in relation to\b/i,
    /\bwhich .* (are|is) mentioned as high[- ]yield\b/i,
    /\bhigh[- ]yield (areas|study topics|practice points)\b/i,
    /\baccording to the section titled what i want to practice\b/i,
    /\baccording to the section titled what i want to understand\b/i,
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

function hasWeakCertificationChoices({ prompt, choices }) {
  const normalizedPrompt = normalizeText(prompt);
  const asksActor = /\b(who|which party|which actor|responsible party)\b/.test(normalizedPrompt);
  const serviceLike = /^(amazon\s+|aws\s+|ec2$|s3$|iam$|vpc$|rds$|dynamodb$|lambda$|cloudfront$|route\s*53$|cloudwatch$|ebs$|efs$|kms$|waf$|mfa$|guardduty$|inspector$|trusted advisor$|cost explorer$|aws budgets$|pricing calculator$)/i;
  const weakExact = new Set([
    "aws",
    "customer",
    "customers",
    "user",
    "users",
    "data",
    "security",
    "compliance",
    "configuration",
    "infrastructure"
  ]);
  return choices.some((choice) => {
    const clean = normalizeText(choice);
    const tokenCount = clean.split(" ").filter(Boolean).length;
    if (weakExact.has(clean) && !asksActor) return true;
    if (tokenCount <= 1 && !serviceLike.test(choice) && !asksActor) return true;
    return false;
  });
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
  const cleanPrompt = repairQuestionPrompt(prompt);
  if (!cleanPrompt || !answer) return false;
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
      '${sqlEscape(cleanPrompt)}',
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
  const sourceMetadata = sourceMetadataFor(generationSource, note);
  registerQuestionSource(sourceMetadata);
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
    const prompt = repairQuestionPrompt(repairSeasonRecordPrompt(rawPrompt, answer, sourceExcerpt));
    if (isLowQualityQuestion({ ...question, canonical_prompt: prompt, canonical_answer: answer }, note)) continue;
    const fingerprint = promptFingerprint(prompt);
    const normalizedQuestion = { ...question, prompt, answer, source_excerpt: sourceExcerpt };
    const signature = conceptSignature(normalizedQuestion);
    const canonicalKey = canonicalConceptKey(normalizedQuestion);
    const conceptRoot = conceptRootKey(normalizedQuestion);
    const answerRoot = answerMemoryKey({ answer });
    const answerPair = `${conceptRoot}:${answerRoot}`;
    const requireUniqueAnswer = !isCertificationNote(note);
    if (
      !prompt ||
      !answer ||
      existing.has(fingerprint) ||
      existingConcepts.has(signature) ||
      existingCanonicalKeys.has(canonicalKey) ||
      (requireUniqueAnswer && existingAnswerPairs.has(answerPair)) ||
      (requireUniqueAnswer && answerKeyOverlapsAny(answerRoot, existingAnswers))
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
    const questionSource = sourceMetadataFor(question.generation_source || generationSource, note, question);
    registerQuestionSource(questionSource);
    sqlite(`
      INSERT INTO questions (
        id, note_id, topic_id, segment_id, concept_id, topic, subtopic, assessment_angle, concept_signature,
        generation_source, prompt, answer, choices, importance, difficulty,
        understanding_score, mastery_state, source_id, source_provider, source_url,
        source_license, source_license_url, provenance_kind, created_at
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
        '${sqlEscape(questionSource.id)}',
        '${sqlEscape(questionSource.provider)}',
        '${sqlEscape(questionSource.sourceUrl || "")}',
        '${sqlEscape(questionSource.licenseName || "")}',
        '${sqlEscape(questionSource.licenseUrl || "")}',
        '${sqlEscape(questionSource.provenanceKind || "curated")}',
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

function ensureCertificationStarterBank(noteId, note = noteSummary(noteId)) {
  if (!note) return 0;
  if (isCloudPractitionerNote(note)) {
    return insertQuestions(noteId, cloudPractitionerQuestionBank(), "cloud_practitioner_expanded_bank");
  }
  if (isSolutionsArchitectNote(note)) {
    return insertQuestions(noteId, solutionsArchitectQuestionBank(), "solutions_architect_expanded_bank");
  }
  return 0;
}

function queueCertificationFromSourceBank(noteId, reason = "source_bank") {
  let note = noteSummary(noteId);
  if (!note || !isCertificationNote(note)) return null;
  const starterSaved = ensureCertificationStarterBank(noteId, note);
  if (starterSaved > 0) note = noteSummary(noteId);
  const viableCount = viableQuestionCount(noteId, note);
  if (viableCount < minimumQuestionBankFor(note)) {
    recordModelRun({
      noteId,
      task: "certification_source_bank",
      promptVersion: "web.certification_source_bank.v1",
      status: "insufficient_source_bank",
      detail: `Only ${viableCount} viable source-bank questions are available.`
    });
    sqlite(`UPDATE notes SET status = 'ready' WHERE id = '${sqlEscape(noteId)}';`);
    return { status: "insufficient_source_bank", saved: viableCount };
  }
  let queued = enqueueQuizForNote(noteId, reason, {
    allowMasteredSuppression: false
  });
  if (queued.status === "empty" || queued.status === "insufficient_viable_questions") {
    queued = enqueueQuizForNote(noteId, `${reason}_review`, {
      allowMasteredSuppression: false,
      relaxed: true
    });
  }
  sqlite(`UPDATE notes SET status = 'ready' WHERE id = '${sqlEscape(noteId)}';`);
  return queued;
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
    prompt: repairQuestionPrompt(row.variant_prompt || row.prompt),
    answer: row.variant_answer || row.answer,
    choices: JSON.parse(row.variant_choices || row.choices || "[]"),
    sourceProvider: row.source_provider || "",
    provenanceKind: row.provenance_kind || "",
    sourceUrl: row.source_url || ""
  }));
}

function startableQueuedQuiz(noteId, attempts = 3) {
  for (let index = 0; index < attempts; index += 1) {
    const queuedQuiz = consumeQueuedQuiz(noteId);
    if (queuedQuiz?.quiz?.length) return queuedQuiz;
    const queued = queueInitialQuiz(noteId);
    if (!["ready", "already_ready"].includes(queued.status)) return null;
  }
  return null;
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

function questionSourcePriority(row, note) {
  if (!isCertificationNote(note)) return 0;
  const provenance = String(row.provenance_kind || "").toLowerCase();
  const provider = String(row.source_provider || "").toLowerCase();
  if (provenance === "licensed_bank" || provider.includes("cloudcertprep")) return 180;
  if (provenance === "curated_bank" || provider.includes("quizloop curated")) return 120;
  if (provenance === "ai_supplemental") return 30;
  const source = String(row.generation_source || "").toLowerCase();
  if (source.startsWith("cloudcertprep:")) return 160;
  if (source.includes("expanded_bank")) return 100;
  if (source.includes("starter_bank")) return 40;
  if (source.includes("post_quiz") || source.includes("mastery") || source.includes("coverage")) return 70;
  return 0;
}

function isSourceBankQuestion(row) {
  const provenance = String(row.provenance_kind || "").toLowerCase();
  const provider = String(row.source_provider || "").toLowerCase();
  const source = String(row.generation_source || "").toLowerCase();
  return provenance === "licensed_bank" ||
    provenance === "curated_bank" ||
    provider.includes("cloudcertprep") ||
    provider.includes("quizloop curated") ||
    source.startsWith("cloudcertprep:") ||
    source.includes("cloud_practitioner") ||
    source.includes("solutions_architect") ||
    source.includes("starter_bank") ||
    source.includes("expanded_bank");
}

function selectedQuizRows(noteId, options = {}) {
  const note = noteSummary(noteId);
  const quizSize = quizSizeForNote(note);
  const focus = normalizeText(options.focus || "");
  const relaxed = Boolean(options.relaxed);
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
  const latestAttemptRows = latestAttemptIds.length
    ? sqlite(`
      SELECT question_id, score FROM attempts
      WHERE id IN (${latestAttemptIds.map((id) => `'${sqlEscape(id)}'`).join(",")})
    `, { json: true })
    : [];
  const latestQuestionIds = latestAttemptRows.length
    ? new Set(latestAttemptRows.map((row) => row.question_id))
    : new Set();
  const latestMissedQuestionIds = new Set(latestAttemptRows
    .filter((row) => Number(row.score || 0) < 0.95)
    .map((row) => row.question_id));
  const recentAssignedRows = sqlite(`
    SELECT question_id
    FROM attempts
    WHERE note_id = '${sqlEscape(noteId)}'
      AND created_at >= ${(Date.now() / 1000) - (2 * 86400)}
    ORDER BY created_at DESC
    LIMIT 80
  `, { json: true });
  const recentAssignedLimit = isCertificationNote(note) ? quizSize * 4 : 80;
  const recentAssignedQuestionIds = new Set(recentAssignedRows
    .slice(0, recentAssignedLimit)
    .map((row) => row.question_id));
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
  const sourceBankRows = isCertificationNote(note)
    ? rows.filter((row) => isSourceBankQuestion(row))
    : rows;
  const selectionRows = isCertificationNote(note) && sourceBankRows.length >= quizSize
    ? sourceBankRows
    : rows;

  const weakConceptKeys = new Set(selectionRows
    .filter((row) => Number(row.attempt_count || 0) > 0 && Number(row.average_score) < 0.8)
    .map((row) => canonicalConceptKey(row)));
  const weakRoots = new Set(selectionRows
    .filter((row) => Number(row.attempt_count || 0) > 0 && Number(row.average_score) < 0.8)
    .map((row) => conceptRootKey(row))
    .filter(Boolean));
  const latestMissedRoots = new Set(selectionRows
    .filter((row) => latestMissedQuestionIds.has(row.id))
    .map((row) => conceptRootKey(row))
    .filter(Boolean));
  const weakLaneConceptGroups = selectionRows
    .filter((row) => latestMissedQuestionIds.has(row.id) || (Number(row.attempt_count || 0) > 0 && Number(row.average_score) < 0.8))
    .map((row) => adaptiveConceptKeys(row))
    .filter((keys) => keys.length > 0)
    .filter((keys, index, allKeys) => {
      return allKeys.findIndex((candidate) => conceptKeysMatch(candidate, keys)) === index;
    });
  const isWeakLaneConcept = (row) => {
    const root = conceptRootKey(row);
    return weakRoots.has(root) ||
      latestMissedRoots.has(root) ||
      weakLaneConceptGroups.some((keys) => conceptKeysMatch(adaptiveConceptKeys(row), keys));
  };

  const canAvoidRecentAssigned = selectionRows.length - recentAssignedQuestionIds.size >= quizSize;
  const pool = canAvoidRecentAssigned
    ? selectionRows.filter((row) => {
      return recentAssignedQuestionIds.has(row.id) === false;
    })
    : selectionRows.length - latestQuestionIds.size >= quizSize
      ? selectionRows.filter((row) => latestQuestionIds.has(row.id) === false)
    : selectionRows;
  const latestConceptKeys = new Set(selectionRows
    .filter((row) => latestQuestionIds.has(row.id))
    .map((row) => canonicalConceptKey(row)));
  const latestConceptRoots = new Set(selectionRows
    .filter((row) => latestQuestionIds.has(row.id))
    .map((row) => conceptRootKey(row))
    .filter(Boolean));
  const latestAnswerKeys = new Set(selectionRows
    .filter((row) => latestQuestionIds.has(row.id))
    .map((row) => answerMemoryKey(row))
    .filter(Boolean));
  const recentCorrectRows = selectionRows.filter((row) => recentCorrectQuestionIds.has(row.id));
  const recentCorrectConceptKeys = new Set(recentCorrectRows.map((row) => canonicalConceptKey(row)).filter(Boolean));
  const recentCorrectConceptRoots = new Set(recentCorrectRows.map((row) => conceptRootKey(row)).filter(Boolean));
  const recentCorrectAnswerKeys = new Set(recentCorrectRows.map((row) => answerMemoryKey(row)).filter(Boolean));
  const recentCorrectPromptKeys = new Set(recentCorrectRows.map((row) => promptFingerprint(row.variant_prompt || row.prompt)).filter(Boolean));
  const hasLargeCertificationBank = isCertificationNote(note) &&
    selectionRows.length >= Math.max(quizSize * 8, minimumQuestionBankFor(note) * 4);
  const suppressRecentlyCorrectConcepts = !isCertificationNote(note) || hasLargeCertificationBank;
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
  const viableFreshRows = selectionRows.filter((row) => {
    const conceptKey = canonicalConceptKey(row);
    const conceptRoot = conceptRootKey(row);
    if (!relaxed && suppressRecentlyCorrectConcepts && latestSessionScore >= 0.95 && wasRecentlyCorrect(row)) return false;
    return !wasRecentlyCorrect(row) ||
      weakConceptKeys.has(conceptKey) ||
      weakRoots.has(conceptRoot);
  });
  const canServeWithoutRecentCorrect = note
    ? viableFreshRows.length >= Math.min(minimumQuestionBankFor(note), quizSize)
    : viableFreshRows.length >= 3;
  const angleRankBonus = (row) => {
    if (!isCertificationNote(note)) return 0;
    const angle = normalizeText(row.assessment_angle || "scenario");
    if (angle.includes("scenario")) return 120;
    if (angle.includes("application")) return 105;
    if (angle.includes("exam practice")) return 95;
    if (angle.includes("tradeoff")) return 70;
    if (angle.includes("definition")) return 35;
    if (angle.includes("detail")) return -20;
    if (angle.includes("trap")) return -120;
    return 0;
  };
  const maxAngleCountForQuiz = (row) => {
    if (!isCertificationNote(note)) return Infinity;
    const angle = normalizeText(row.assessment_angle || "scenario");
    if (angle.includes("trap")) return 1;
    if (angle.includes("detail")) return 2;
    if (angle.includes("tradeoff")) return 3;
    return Infinity;
  };
  const isScenarioLikeRow = (row) => {
    if (!isCertificationNote(note)) return false;
    const prompt = String(row.variant_prompt || row.prompt || "");
    return [
      /\ba company\b/i,
      /\ban application\b/i,
      /\ba workload\b/i,
      /\ba team\b/i,
      /\bneeds?\b/i,
      /\brequires?\b/i,
      /\bwants?\b/i,
      /\bshould\b/i,
      /\bwhich (aws )?service\b/i,
      /\bwhich service should\b/i,
      /\bwhich (aws )?tool\b/i,
      /\bwhat is the benefit of using\b/i,
      /\bwhich option\b/i
    ].some((pattern) => pattern.test(prompt));
  };
  const minimumScenarioCount = () => {
    if (!isCertificationNote(note)) return 0;
    return /cloud practitioner/i.test(note?.title || "") ? 3 : Math.min(quizSize, 7);
  };

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
      const recentlyAssigned = recentAssignedQuestionIds.has(row.id);
      const latestMiss = latestMissedQuestionIds.has(row.id);
      const weakRoot = weakRoots.has(conceptRoot);
      const latestMissedRoot = latestMissedRoots.has(conceptRoot);
      const exactRecentRepeat = latestQuestionIds.has(row.id) || recentAssignedQuestionIds.has(row.id);
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
        ? (suppressRecentlyCorrectConcepts ? -700 : 0)
        : 0;
      const recentCorrectPenalty = !relaxed && suppressRecentlyCorrectConcepts && canServeWithoutRecentCorrect && recentlyCorrect
        ? -1200
        : 0;
      const recentAssignedPenalty = !relaxed && canAvoidRecentAssigned && recentlyAssigned
        ? (latestMissedRoot || weakRoot ? -250 : -900)
        : 0;
      return (
        (attempts === 0 ? 1000 : 0) +
        (latestMiss ? -2200 : 0) +
        (latestMissedRoot && !exactRecentRepeat ? 2600 : 0) +
        (weakRoot && !exactRecentRepeat ? 1400 : 0) +
        (average >= 0 && average < 0.8 ? 900 : 0) +
        (latestQuestionIds.has(row.id) ? -250 : 0) +
        justMasteredPenalty +
        recentCorrectPenalty +
        recentAssignedPenalty +
        questionSourcePriority(row, note) +
        angleRankBonus(row) +
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
  const selectedDomains = new Map();
  const selectedAngles = new Map();
  const selectedConceptKeyGroups = [];
  const domainTargets = !focus && isCertificationNote(note)
    ? certificationQuizDomainTargets(note, quizSize)
    : null;
  const subtopicLimit = isCertificationNote(note) ? 4 : 1;
  const weakLaneRoots = new Set([...latestMissedRoots, ...weakRoots].filter(Boolean));
  const weakLaneRows = [
    ...ranked,
    ...selectionRows.filter((row) => !ranked.some((candidate) => candidate.id === row.id))
  ];

  const trySelectRow = (row, options = {}) => {
    const {
      allowRecentAssigned = false,
      allowRecentCorrect = false,
      allowLatestMissExact = false,
      allowDomainOverflow = false
    } = options;
    const key = quizLegitimacyKey(row);
    const conceptRoot = conceptRootKey(row) || key;
    const conceptKeys = adaptiveConceptKeys(row);
    const answerKey = answerMemoryKey(row);
    const subtopicKey = normalizeText(row.subtopic || row.topic || "topic");
    const subtopicCount = selectedSubtopics.get(subtopicKey) || 0;
    const answerCount = selectedAnswers.get(answerKey) || 0;
    const domainTitle = row.topic || "";
    const domainCount = selectedDomains.get(domainTitle) || 0;
    const angleKey = normalizeText(row.assessment_angle || "scenario");
    const angleCount = selectedAngles.get(angleKey) || 0;
    const isWeak = weakConceptKeys.has(canonicalConceptKey(row));
    const isWeakRoot = isWeakLaneConcept(row);
    const recentlyMasteredConcept = latestConceptKeys.has(canonicalConceptKey(row)) ||
      latestConceptRoots.has(conceptRoot) ||
      conceptKeysMatch(conceptKeys, [...latestConceptRoots]);
    const recentlyMasteredAnswer = answerKey &&
      (latestAnswerKeys.has(answerKey) || answerKeyOverlapsAny(answerKey, latestAnswerKeys));
    const recentlyCorrect = wasRecentlyCorrect(row);
    const recentlyAssigned = recentAssignedQuestionIds.has(row.id);
    const latestMiss = latestMissedQuestionIds.has(row.id);

    if (selectedKeys.has(key)) return false;
    if (selectedConceptRoots.has(conceptRoot) || selectedConceptKeyGroups.some((keys) => conceptKeysMatch(keys, conceptKeys))) return false;
    if (!relaxed && latestMiss && !allowLatestMissExact && ranked.length - selected.length > 3) return false;
    if (!relaxed && recentCorrectQuestionIds.has(row.id) && !allowRecentCorrect && ranked.length - selected.length > 3) return false;
    if (!relaxed && canAvoidRecentAssigned && recentlyAssigned && !allowRecentAssigned) return false;
    if (!relaxed && suppressRecentlyCorrectConcepts && latestSessionScore >= 0.95 && recentlyCorrect && !allowRecentCorrect) return false;
    if (!relaxed && canServeWithoutRecentCorrect && recentlyCorrect && !isWeak && !isWeakRoot && !allowRecentCorrect) return false;
    if (
      !relaxed &&
      suppressRecentlyCorrectConcepts &&
      latestSessionScore >= 0.95 &&
      (recentlyMasteredConcept || recentlyMasteredAnswer) &&
      !isWeak &&
      !isWeakRoot &&
      !allowRecentCorrect
    ) return false;
    if (answerKey && answerCount >= 1 && ranked.length - selected.length > 3) return false;
    if (subtopicCount >= subtopicLimit && ranked.length - selected.length > 3) return false;
    if (!relaxed && angleCount >= maxAngleCountForQuiz(row) && ranked.length - selected.length > 3) return false;
    if (domainTargets && domainTargets.has(domainTitle)) {
      const target = domainTargets.get(domainTitle);
      if (domainCount >= target) {
        const adaptiveOverflowLimit = target + ((isWeak || isWeakRoot || allowDomainOverflow) ? 2 : 0);
        if (domainCount >= adaptiveOverflowLimit) return false;
        if (!allowDomainOverflow && !isWeak && !isWeakRoot) return false;
      }
    }

    selected.push(row);
    selectedKeys.add(key);
    selectedConceptRoots.add(conceptRoot);
    selectedConceptKeyGroups.push(conceptKeys);
    selectedSubtopics.set(subtopicKey, subtopicCount + 1);
    if (answerKey) selectedAnswers.set(answerKey, answerCount + 1);
    if (domainTargets) selectedDomains.set(domainTitle, domainCount + 1);
    selectedAngles.set(angleKey, angleCount + 1);
    return true;
  };

  const rebuildSelectionTracking = () => {
    selectedKeys.clear();
    selectedConceptRoots.clear();
    selectedSubtopics.clear();
    selectedAnswers.clear();
    selectedDomains.clear();
    selectedAngles.clear();
    selectedConceptKeyGroups.length = 0;
    for (const row of selected) {
      const key = quizLegitimacyKey(row);
      const conceptRoot = conceptRootKey(row) || key;
      const conceptKeys = adaptiveConceptKeys(row);
      const answerKey = answerMemoryKey(row);
      const subtopicKey = normalizeText(row.subtopic || row.topic || "topic");
      const domainTitle = row.topic || "";
      const angleKey = normalizeText(row.assessment_angle || "scenario");
      selectedKeys.add(key);
      selectedConceptRoots.add(conceptRoot);
      selectedConceptKeyGroups.push(conceptKeys);
      selectedSubtopics.set(subtopicKey, (selectedSubtopics.get(subtopicKey) || 0) + 1);
      if (answerKey) selectedAnswers.set(answerKey, (selectedAnswers.get(answerKey) || 0) + 1);
      if (domainTargets) selectedDomains.set(domainTitle, (selectedDomains.get(domainTitle) || 0) + 1);
      selectedAngles.set(angleKey, (selectedAngles.get(angleKey) || 0) + 1);
    }
  };

  const forceWeakLaneCoverage = () => {
    const weakGroups = weakLaneConceptGroups.length > 0
      ? weakLaneConceptGroups
      : [...weakLaneRoots].map((root) => [root]);
    for (const group of weakGroups) {
      if (!group.length || selected.some((row) => conceptKeysMatch(adaptiveConceptKeys(row), group))) continue;
      const replacement = weakLaneRows.find((row) => {
        return conceptKeysMatch(adaptiveConceptKeys(row), group) &&
          !latestMissedQuestionIds.has(row.id) &&
          !selected.some((candidate) => candidate.id === row.id);
      }) || weakLaneRows.find((row) => {
        return conceptKeysMatch(adaptiveConceptKeys(row), group) &&
          !selected.some((candidate) => candidate.id === row.id);
      });
      if (!replacement) continue;
      if (selected.length < quizSize) {
        selected.push(replacement);
      } else {
        const replaceIndex = selected.findIndex((row) => {
          return !weakGroups.some((keys) => conceptKeysMatch(adaptiveConceptKeys(row), keys));
        });
        if (replaceIndex >= 0) selected[replaceIndex] = replacement;
      }
    }
    rebuildSelectionTracking();
  };

  if (weakLaneRoots.size > 0 || weakLaneConceptGroups.length > 0) {
    const targetWeakLaneCount = Math.min(Math.ceil(quizSize * 0.35), Math.max(weakLaneRoots.size, weakLaneConceptGroups.length));
    for (const row of weakLaneRows) {
      if (selected.length >= targetWeakLaneCount) break;
      if (!isWeakLaneConcept(row)) continue;
      if (latestMissedQuestionIds.has(row.id)) continue;
      trySelectRow(row, {
        allowRecentAssigned: true,
        allowRecentCorrect: true,
        allowDomainOverflow: true
      });
    }
    for (const row of weakLaneRows) {
      if (selected.length >= targetWeakLaneCount) break;
      if (!isWeakLaneConcept(row)) continue;
      trySelectRow(row, {
        allowLatestMissExact: true,
        allowRecentAssigned: true,
        allowRecentCorrect: true,
        allowDomainOverflow: true
      });
    }
    forceWeakLaneCoverage();
  }

  for (const row of ranked) {
    trySelectRow(row);
    if (selected.length >= quizSize) break;
  }

  if (isCertificationNote(note) && selected.length >= Math.min(quizSize, 5)) {
    const countScenarioLike = () => selected.filter(isScenarioLikeRow).length;
    const conflictsWithSelected = (row, ignoreIndex) => {
      const key = quizLegitimacyKey(row);
      const conceptRoot = conceptRootKey(row) || key;
      const conceptKeys = adaptiveConceptKeys(row);
      const answerKey = answerMemoryKey(row);
      return selected.some((candidate, index) => {
        if (index === ignoreIndex) return false;
        const candidateAnswer = answerMemoryKey(candidate);
        return quizLegitimacyKey(candidate) === key ||
          (conceptRootKey(candidate) || quizLegitimacyKey(candidate)) === conceptRoot ||
          conceptKeysMatch(adaptiveConceptKeys(candidate), conceptKeys) ||
          (answerKey && (candidateAnswer === answerKey || answerKeysOverlap(candidateAnswer, answerKey)));
      });
    };
    const nonScenarioReplacementIndex = () => {
      const candidates = selected
        .map((row, index) => ({ row, index }))
        .filter((entry) => !isScenarioLikeRow(entry.row))
        .sort((left, right) => {
          const replacementWeight = (entry) => {
            const angle = normalizeText(entry.row.assessment_angle || "");
            if (angle.includes("detail")) return 0;
            if (angle.includes("definition")) return 1;
            if (angle.includes("trap")) return 2;
            return 3;
          };
          return replacementWeight(left) - replacementWeight(right);
        });
      return candidates[0]?.index ?? -1;
    };

    const targetScenarioCount = minimumScenarioCount();
    for (const row of ranked) {
      if (countScenarioLike() >= targetScenarioCount) break;
      if (!isScenarioLikeRow(row)) continue;
      if (selected.some((candidate) => candidate.id === row.id)) continue;
      const replaceIndex = nonScenarioReplacementIndex();
      if (replaceIndex < 0) break;
      if (conflictsWithSelected(row, replaceIndex)) continue;
      if (!relaxed && canAvoidRecentAssigned && recentAssignedQuestionIds.has(row.id)) continue;
      selected[replaceIndex] = row;
    }
  }

  const sorted = [...selected];
  if (sorted.length < Math.min(5, ranked.length)) {
    for (const row of ranked) {
      if (sorted.some((candidate) => candidate.id === row.id)) continue;
      const key = quizLegitimacyKey(row);
      const conceptRoot = conceptRootKey(row) || key;
      const conceptKeys = adaptiveConceptKeys(row);
      const answerKey = answerMemoryKey(row);
      const matchingKey = sorted.some((candidate) => quizLegitimacyKey(candidate) === key);
      const matchingConcept = sorted.some((candidate) => {
        return (conceptRootKey(candidate) || quizLegitimacyKey(candidate)) === conceptRoot ||
          conceptKeysMatch(adaptiveConceptKeys(candidate), conceptKeys);
      });
      const matchingAnswer = answerKey && sorted.some((candidate) => {
        const candidateAnswer = answerMemoryKey(candidate);
        return candidateAnswer === answerKey || answerKeysOverlap(candidateAnswer, answerKey);
      });
      if (matchingKey || matchingConcept || matchingAnswer) continue;
      const recentlyMasteredAnswer = answerKey &&
        (latestAnswerKeys.has(answerKey) || answerKeyOverlapsAny(answerKey, latestAnswerKeys));
      const recentlyCorrect = wasRecentlyCorrect(row);
      const recentlyAssigned = recentAssignedQuestionIds.has(row.id);
      if (!relaxed && canAvoidRecentAssigned && recentlyAssigned) continue;
      if (!relaxed && suppressRecentlyCorrectConcepts && latestSessionScore >= 0.95 && recentlyCorrect) continue;
      if (!relaxed && canServeWithoutRecentCorrect && recentlyCorrect) continue;
      if (
        !relaxed &&
        suppressRecentlyCorrectConcepts &&
        latestSessionScore >= 0.95 &&
        (latestConceptRoots.has(conceptRoot) || recentlyMasteredAnswer)
      ) continue;
      sorted.push(row);
      if (sorted.length >= quizSize) break;
    }
  }
  const minimumRows = note ? Math.min(minimumQuestionBankFor(note), ranked.length, quizSize) : Math.min(3, ranked.length);
  if (sorted.length < minimumRows) {
    for (const row of ranked) {
      if (sorted.some((candidate) => candidate.id === row.id)) continue;
      if (!relaxed && canAvoidRecentAssigned && recentAssignedQuestionIds.has(row.id)) continue;
      if (!relaxed && suppressRecentlyCorrectConcepts && latestSessionScore >= 0.95 && wasRecentlyCorrect(row)) continue;
      sorted.push(row);
      if (sorted.length >= minimumRows) break;
    }
  }
  const quiz = rowsToQuiz(sorted);

  const quizFingerprint = quizConceptSetFingerprint(quiz);
  const canMoveBeyondMasteredSet = selectionRows.length > (note ? minimumQuestionBankFor(note) + 1 : quiz.length);
  if (options.allowMasteredSuppression !== false && quiz.length > 0 && masteredQuizFingerprints.has(quizFingerprint) && canMoveBeyondMasteredSet) {
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
      feedback: "Mastered concept set suppressed. Generate harder adjacent questions.",
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

function quizMeetsCertificationDomainTargets(quiz, note) {
  if (!isCertificationNote(note) || !usesOfficialCertificationDomains(note)) return true;
  const targets = certificationQuizDomainTargets(note, quiz.length || quizSizeForNote(note));
  if (!targets || targets.size === 0) return true;
  const tolerance = quiz.length <= 10 ? 2 : 1;
  const counts = new Map();
  for (const question of quiz) {
    counts.set(question.topic, (counts.get(question.topic) || 0) + 1);
  }
  for (const [topic, target] of targets.entries()) {
    const actual = counts.get(topic) || 0;
    if (Math.abs(actual - target) > tolerance) return false;
  }
  return true;
}

function queuedQuizAdaptiveViolation(noteId, quiz, note) {
  if (!isCertificationNote(note) || !quiz?.length) return "";
  const latest = sqlite(`
    SELECT score, attempt_ids
    FROM quiz_sessions
    WHERE note_id = '${sqlEscape(noteId)}'
    ORDER BY created_at DESC
    LIMIT 1
  `, { json: true })[0];
  if (!latest) return "";

  const ids = String(latest.attempt_ids || "")
    .split(/\n+/)
    .map((id) => id.trim())
    .filter(Boolean);
  if (ids.length === 0) return "";

  const attempts = sqlite(`
    SELECT question_id, prompt_snapshot AS prompt, answer_snapshot AS answer, score
    FROM attempts
    WHERE id IN (${ids.map((id) => `'${sqlEscape(id)}'`).join(",")})
  `, { json: true });
  if (attempts.length === 0) return "";

  const latestScore = Number(latest.score || 0);
  const latestMissed = attempts.filter((attempt) => Number(attempt.score || 0) < 0.95);
  const latestCorrect = attempts.filter((attempt) => Number(attempt.score || 0) >= 0.95);
  const quizRoots = new Set(quiz.map((question) => conceptRootKey(question)).filter(Boolean));
  const quizConceptGroups = quiz.map((question) => adaptiveConceptKeys(question)).filter((keys) => keys.length > 0);
  const quizAnswerKeys = new Set(quiz.map((question) => answerMemoryKey(question)).filter(Boolean));
  const quizQuestionIds = new Set(quiz.map((question) => question.id).filter(Boolean));

  if (latestMissed.length > 0) {
    const missedGroups = latestMissed
      .map((attempt) => adaptiveConceptKeys(attempt))
      .filter((keys) => keys.length > 0);
    const availableRelatedRows = viableQuestionRows(noteId, note).filter((row) => {
      return missedGroups.some((keys) => conceptKeysMatch(adaptiveConceptKeys(row), keys));
    });
    const hasRelatedInQuiz = missedGroups.some((keys) => {
      return quizConceptGroups.some((quizKeys) => conceptKeysMatch(quizKeys, keys));
    });
    if (availableRelatedRows.length > 0 && !hasRelatedInQuiz) {
      return "Queued quiz did not revisit a recently missed concept.";
    }
  }

  const hasLargeBank = viableQuestionCount(noteId, note) >= Math.max(quizSizeForNote(note) * 8, minimumQuestionBankFor(note) * 4);
  if (latestScore >= 0.95 && hasLargeBank) {
    const correctQuestionIds = new Set(latestCorrect.map((attempt) => attempt.question_id).filter(Boolean));
    const correctRoots = new Set(latestCorrect.map((attempt) => conceptRootKey(attempt)).filter(Boolean));
    const correctConceptGroups = latestCorrect
      .map((attempt) => adaptiveConceptKeys(attempt))
      .filter((keys) => keys.length > 0);
    const correctAnswerKeys = new Set(latestCorrect.map((attempt) => answerMemoryKey(attempt)).filter(Boolean));
    const freshAlternatives = viableQuestionRows(noteId, note).filter((row) => {
      const answerKey = answerMemoryKey(row);
      const conceptKeys = adaptiveConceptKeys(row);
      return !correctQuestionIds.has(row.id) &&
        !correctRoots.has(conceptRootKey(row)) &&
        !correctConceptGroups.some((keys) => conceptKeysMatch(conceptKeys, keys)) &&
        !(answerKey && (correctAnswerKeys.has(answerKey) || answerKeyOverlapsAny(answerKey, correctAnswerKeys)));
    });
    const canAvoidMastered = freshAlternatives.length >= quizSizeForNote(note);
    if (canAvoidMastered) {
      const repeatsCorrectQuestion = [...correctQuestionIds].some((id) => quizQuestionIds.has(id));
      if (repeatsCorrectQuestion) {
        return "Queued quiz repeated a question just mastered on the previous quiz.";
      }
    }
  }

  return "";
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
    ? `Next quiz revisits ${missed.length} missed idea${missed.length === 1 ? "" : "s"} and adds related questions.`
    : Number(latest.score || 0) >= 0.95
      ? `Previous quiz was ${Math.round(Number(latest.score || 0) * 100)}%, so this quiz avoids mastered answers and looks for fresh concepts.`
      : `Next quiz uses your last score to rebalance weak and new concepts.`;
  return { summary, targetConcepts: concepts, avoidedConcepts, reason };
}

function repairRowsForLatestMisses(noteId, rows, note) {
  if (!isCertificationNote(note) || !rows?.length) return rows || [];
  const latest = sqlite(`
    SELECT attempt_ids
    FROM quiz_sessions
    WHERE note_id = '${sqlEscape(noteId)}'
    ORDER BY created_at DESC
    LIMIT 1
  `, { json: true })[0];
  const ids = String(latest?.attempt_ids || "")
    .split(/\n+/)
    .map((id) => id.trim())
    .filter(Boolean);
  if (ids.length === 0) return rows;
  const missed = sqlite(`
    SELECT question_id, prompt_snapshot AS prompt, answer_snapshot AS answer, topic_snapshot AS topic, subtopic_snapshot AS subtopic, score
    FROM attempts
    WHERE id IN (${ids.map((id) => `'${sqlEscape(id)}'`).join(",")})
      AND score < 0.95
  `, { json: true });
  if (missed.length === 0) return rows;

  const repaired = [...rows];
  const missedIds = new Set(missed.map((attempt) => attempt.question_id).filter(Boolean));
  const missedGroups = missed
    .map((attempt) => adaptiveConceptKeys(attempt))
    .filter((keys) => keys.length > 0)
    .filter((keys, index, allKeys) => {
      return allKeys.findIndex((candidate) => conceptKeysMatch(candidate, keys)) === index;
    });
  const availableRows = viableQuestionRows(noteId, note);
  for (const group of missedGroups) {
    if (repaired.some((row) => conceptKeysMatch(adaptiveConceptKeys(row), group))) continue;
    const replacement = availableRows.find((row) => {
      return conceptKeysMatch(adaptiveConceptKeys(row), group) &&
        !missedIds.has(row.id) &&
        !repaired.some((candidate) => candidate.id === row.id);
    }) || availableRows.find((row) => {
      return conceptKeysMatch(adaptiveConceptKeys(row), group) &&
        !repaired.some((candidate) => candidate.id === row.id);
    });
    if (!replacement) continue;
    if (repaired.length < quizSizeForNote(note)) {
      repaired.push(replacement);
      continue;
    }
    const replaceIndex = [...repaired]
      .reverse()
      .findIndex((row) => {
        return !missedGroups.some((keys) => conceptKeysMatch(adaptiveConceptKeys(row), keys));
      });
    if (replaceIndex >= 0) {
      repaired[repaired.length - 1 - replaceIndex] = replacement;
    }
  }
  return repaired.slice(0, quizSizeForNote(note));
}

function repairRowsForDomainTargets(noteId, rows, note) {
  if (!isCertificationNote(note) || !usesOfficialCertificationDomains(note) || !rows?.length) return rows || [];
  const quizSize = quizSizeForNote(note);
  const targets = certificationQuizDomainTargets(note, quizSize);
  if (!targets || targets.size === 0) return rows;

  const repaired = [...rows].slice(0, quizSize);
  const availableRows = viableQuestionRows(noteId, note);
  const recentAssignedQuestionIds = new Set(sqlite(`
    SELECT question_id
    FROM attempts
    WHERE note_id = '${sqlEscape(noteId)}'
      AND created_at >= ${(Date.now() / 1000) - (2 * 86400)}
    ORDER BY created_at DESC
    LIMIT ${Math.max(quizSize * 6, 60)}
  `, { json: true }).map((row) => row.question_id));
  const countDomains = () => {
    const counts = new Map();
    for (const row of repaired) {
      counts.set(row.topic, (counts.get(row.topic) || 0) + 1);
    }
    return counts;
  };
  const conflictsWithQuiz = (candidate, ignoreIndex, options = {}) => {
    const { allowConceptOverlap = false } = options;
    const candidateKey = quizLegitimacyKey(candidate);
    const candidateKeys = adaptiveConceptKeys(candidate);
    const candidateAnswer = answerMemoryKey(candidate);
    return repaired.some((row, index) => {
      if (index === ignoreIndex) return false;
      const rowAnswer = answerMemoryKey(row);
      return row.id === candidate.id ||
        quizLegitimacyKey(row) === candidateKey ||
        (!allowConceptOverlap && conceptKeysMatch(adaptiveConceptKeys(row), candidateKeys)) ||
        (candidateAnswer && (rowAnswer === candidateAnswer || answerKeysOverlap(rowAnswer, candidateAnswer)));
    });
  };

  for (let pass = 0; pass < quizSize; pass += 1) {
    const counts = countDomains();
    const overfull = [...targets.entries()]
      .map(([topic, target]) => ({ topic, target, count: counts.get(topic) || 0 }))
      .filter((entry) => entry.count > entry.target + 2)
      .sort((left, right) => (right.count - right.target) - (left.count - left.target))[0];
    if (!overfull) break;

    const underfullTopics = [...targets.entries()]
      .map(([topic, target]) => ({ topic, target, count: counts.get(topic) || 0 }))
      .filter((entry) => entry.topic !== overfull.topic && entry.count < entry.target)
      .sort((left, right) => (right.target - right.count) - (left.target - left.count));
    if (underfullTopics.length === 0) break;

    const replaceIndex = [...repaired]
      .reverse()
      .findIndex((row) => row.topic === overfull.topic);
    if (replaceIndex < 0) break;
    const actualReplaceIndex = repaired.length - 1 - replaceIndex;
    const candidateRows = availableRows
      .filter((row) => underfullTopics.some((entry) => entry.topic === row.topic))
      .sort((left, right) => {
        const shortage = (row) => {
          const target = underfullTopics.find((entry) => entry.topic === row.topic);
          return target ? target.target - target.count : 0;
        };
        return shortage(right) - shortage(left) ||
          questionSourcePriority(right, note) - questionSourcePriority(left, note) ||
          Math.random() - 0.5;
      });
    const replacement = candidateRows.find((row) => {
      return !recentAssignedQuestionIds.has(row.id) && !conflictsWithQuiz(row, actualReplaceIndex);
    }) || candidateRows.find((row) => {
      return !recentAssignedQuestionIds.has(row.id) && !conflictsWithQuiz(row, actualReplaceIndex, { allowConceptOverlap: true });
    });
    if (!replacement) break;
    repaired[actualReplaceIndex] = replacement;
  }

  return repaired;
}

function repairDuplicateAnswers(noteId, rows, note) {
  if (!rows?.length) return rows || [];
  const repaired = [...rows];
  const availableRows = viableQuestionRows(noteId, note);
  const recentAssignedQuestionIds = new Set(sqlite(`
    SELECT question_id
    FROM attempts
    WHERE note_id = '${sqlEscape(noteId)}'
      AND created_at >= ${(Date.now() / 1000) - (2 * 86400)}
    ORDER BY created_at DESC
    LIMIT ${Math.max(quizSizeForNote(note) * 6, 60)}
  `, { json: true }).map((row) => row.question_id));
  const conflictsWithQuiz = (candidate, ignoreIndex) => {
    const candidateKey = quizLegitimacyKey(candidate);
    const candidateAnswer = answerMemoryKey(candidate);
    return repaired.some((row, index) => {
      if (index === ignoreIndex) return false;
      const rowAnswer = answerMemoryKey(row);
      return row.id === candidate.id ||
        quizLegitimacyKey(row) === candidateKey ||
        (candidateAnswer && (rowAnswer === candidateAnswer || answerKeysOverlap(rowAnswer, candidateAnswer)));
    });
  };

  for (let index = 0; index < repaired.length; index += 1) {
    const answerKey = answerMemoryKey(repaired[index]);
    if (!answerKey) continue;
    const firstIndex = repaired.findIndex((row) => {
      const rowAnswer = answerMemoryKey(row);
      return rowAnswer === answerKey || answerKeysOverlap(rowAnswer, answerKey);
    });
    if (firstIndex === index) continue;
    const sameTopicReplacement = availableRows.find((row) => {
      return row.topic === repaired[index].topic &&
        !recentAssignedQuestionIds.has(row.id) &&
        !conflictsWithQuiz(row, index);
    });
    const anyReplacement = availableRows.find((row) => {
      return !recentAssignedQuestionIds.has(row.id) &&
        !conflictsWithQuiz(row, index);
    });
    const replacement = sameTopicReplacement || anyReplacement;
    if (replacement) repaired[index] = replacement;
  }

  return repaired;
}

function enqueueQuizForNote(noteId, reason = "prepared", options = {}) {
  if (queuedQuizCount(noteId) > 0) {
    return { status: "already_ready", saved: 0 };
  }
  const note = noteSummary(noteId);
  const selected = selectedQuizRows(noteId, options);
  if (selected.suppressed) return selected.nextQuiz || { status: "preparing", saved: 0 };
  let rows = selected.rows || [];
  rows = repairRowsForLatestMisses(noteId, rows, note);
  rows = repairRowsForDomainTargets(noteId, rows, note);
  rows = repairDuplicateAnswers(noteId, rows, note);
  rows = repairRowsForDomainTargets(noteId, rows, note);
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
    if (isCloudPractitionerNote(note) && Number(note.questionCount || 0) === 0) {
      const saved = insertQuestions(noteId, cloudPractitionerQuestionBank(), "cloud_practitioner_expanded_bank");
      sqlite(`
        UPDATE notes
        SET summary = 'A Cloud Practitioner readiness loop covering the four CLF-C02 domains: Cloud Concepts, Security and Compliance, Cloud Technology and Services, and Billing/Pricing/Support.'
        WHERE id = '${sqlEscape(noteId)}';
      `);
      enqueueQuizForNote(noteId, "cloud_practitioner_starter");
      sqlite(`UPDATE notes SET status = 'ready' WHERE id = '${sqlEscape(noteId)}';`);
      recordModelRun({
        noteId,
        task: "cloud_practitioner_starter_bank",
        promptVersion: "web.cloud_practitioner_seed.v1",
        status: "ok",
        detail: `Saved ${saved} starter questions for immediate exam practice.`
      });
      return { saved, status: "ready" };
    }
    if (isSolutionsArchitectNote(note) && Number(note.questionCount || 0) === 0) {
      const saved = insertQuestions(noteId, solutionsArchitectQuestionBank(), "solutions_architect_expanded_bank");
      sqlite(`
        UPDATE notes
        SET summary = 'A Solutions Architect Associate readiness loop covering secure, resilient, high-performing, and cost-optimized AWS architecture decisions.'
        WHERE id = '${sqlEscape(noteId)}';
      `);
      enqueueQuizForNote(noteId, "solutions_architect_starter");
      sqlite(`UPDATE notes SET status = 'ready' WHERE id = '${sqlEscape(noteId)}';`);
      recordModelRun({
        noteId,
        task: "solutions_architect_starter_bank",
        promptVersion: "web.solutions_architect_seed.v1",
        status: "ok",
        detail: `Saved ${saved} starter questions for immediate architecture practice.`
      });
      return { saved, status: "ready" };
    }
    const target = questionTargetFor(sourceTextForGeneration(note, 9000));
    let result;
    try {
      result = await gemmaJSON(quizPromptFor(note, target));
    } catch (error) {
      if (!isCertificationNote(note)) throw error;
      recordModelRun({
        noteId,
        task: "initial_quiz_build_retry",
        promptVersion: "web.initial_cert_retry.v1",
        status: "retrying",
        detail: error.message || "Certification build retrying with a smaller bank."
      });
      result = await gemmaJSON(quizPromptFor(note, 8), 90000);
    }
    let saved = saveQuestions(noteId, result.summary, result.questions || []);
    const minimum = minimumQuestionBankFor(note);
    if (isCloudPractitionerNote(note) && saved < minimum) {
      saved += insertQuestions(noteId, cloudPractitionerQuestionBank(), "cloud_practitioner_expanded_bank");
    }
    if (isSolutionsArchitectNote(note) && saved < minimum) {
      saved += insertQuestions(noteId, solutionsArchitectQuestionBank(), "solutions_architect_expanded_bank");
    }
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
    sqlite(`UPDATE notes SET status = 'error' WHERE id = '${sqlEscape(noteId)}';`);
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
  let note = noteSummary(noteId);
  if (!note) return { status: "missing_note", saved: 0 };
  const starterSaved = ensureCertificationStarterBank(noteId, note);
  if (starterSaved > 0) {
    note = noteSummary(noteId);
    recordModelRun({
      noteId,
      task: "certification_bank_sync",
      promptVersion: "web.certification_bank_sync.v1",
      status: "ok",
      detail: `Added ${starterSaved} certification starter questions.`
    });
  }
  if (note.questionCount > 0) {
    let queued = enqueueQuizForNote(noteId, "starter", { allowMasteredSuppression: false });
    if (queued.status === "insufficient_viable_questions" || queued.status === "empty") {
      queued = enqueueQuizForNote(noteId, "starter_review", {
        allowMasteredSuppression: false,
        relaxed: true
      });
    }
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

function visibleNextQuizState(noteId, queuedResult) {
  const note = noteSummary(noteId);
  if (Number(note?.queuedQuizCount || 0) > 0) {
    return { status: "ready", saved: Number(queuedResult?.saved || 0) };
  }
  return queuedResult || { status: "preparing", saved: 0 };
}

function consumeQueuedQuiz(noteId) {
  const queued = readyQueue(noteId);
  if (!queued) return null;
  const note = noteSummary(noteId);
  let ids = [];
  try {
    ids = JSON.parse(queued.question_ids || "[]");
  } catch {
    ids = [];
  }
  const quiz = rowsToQuiz(questionRowsByIds(noteId, ids).filter((row) => !isLowQualityQuestion(row, note)));
  const minimumRows = Math.min(quizSizeForNote(note), Math.max(2, minimumQuestionBankFor(note)));
  const invalidReason = quiz.length < minimumRows
    ? "Queued quiz had too few valid questions after quality filtering."
    : !quizMeetsCertificationDomainTargets(quiz, note)
      ? "Queued certification quiz drifted from the official domain mix."
      : queuedQuizAdaptiveViolation(noteId, quiz, note);
  if (invalidReason) {
    sqlite(`
      UPDATE quiz_queue
      SET state = 'invalid',
          consumed_at = ${Date.now() / 1000}
      WHERE id = '${sqlEscape(queued.id)}';
    `);
    recordUserAction({
      noteId,
      actionType: "quiz_queue.invalidated",
      objectType: "quiz_queue",
      objectId: queued.id,
      payload: {
        reason: invalidReason,
        expected: minimumRows,
        received: quiz.length,
        topics: quiz.reduce((counts, question) => {
          counts[question.topic] = (counts[question.topic] || 0) + 1;
          return counts;
        }, {})
      }
    });
    return null;
  }
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
  const hasEnoughExistingQuestions = Number(note.questionCount || 0) >= Math.min(minimumQuestionBankFor(note), quizSizeForNote(note));
  if (note.status === "building" && hasEnoughExistingQuestions) {
    sqlite(`UPDATE notes SET status = 'ready' WHERE id = '${sqlEscape(noteId)}';`);
    note = noteSummary(noteId);
  }
  let queuedQuiz = startableQueuedQuiz(noteId, isCertificationNote(note) ? 3 : 1);
  const buildInFlight = initialBuildInFlight.has(noteId) || expansionInFlight.has(noteId);
  if (!queuedQuiz && buildInFlight && !hasEnoughExistingQuestions) {
    return { questions: [], nextQuiz: { status: "preparing", saved: 0 } };
  }
  if (!queuedQuiz && note.questionCount > 0 && noteNeedsQuestionBackfill(note)) {
    sqlite(`DELETE FROM quiz_queue WHERE note_id = '${sqlEscape(noteId)}' AND state = 'ready';`);
    if (isCertificationNote(note)) {
      return {
        questions: [],
        nextQuiz: queueCertificationFromSourceBank(noteId, "source_low_bank_recovery") || { status: "insufficient_source_bank", saved: 0 }
      };
    }
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
      queuedQuiz = startableQueuedQuiz(noteId, isCertificationNote(note) ? 8 : 3);
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
  if (!queuedQuiz && note.questionCount > 0) {
    const queued = enqueueQuizForNote(noteId, "ready_queue_repair", {
      allowMasteredSuppression: false,
      relaxed: true
    });
    if (queued.status === "ready" || queued.status === "already_ready") {
      queuedQuiz = startableQueuedQuiz(noteId, isCertificationNote(note) ? 8 : 3);
    }
  }
  if (!queuedQuiz) {
    const recovery = queueNextQuiz(noteId, [], {
      force: true,
      reason: "empty_ready_queue_recovery"
    });
    if (recovery.status === "ready" || recovery.status === "already_ready") {
      queuedQuiz = startableQueuedQuiz(noteId, isCertificationNote(note) ? 8 : 3);
    }
  }
  if (!queuedQuiz) {
    return {
      questions: [],
      nextQuiz: { status: "preparing", saved: 0 }
    };
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
  const note = noteSummary(noteId);
  if (isCertificationNote(note)) {
    return certificationDomainsFor(note).map((domain) => ({
      type: "domain",
      value: domain.title,
      topic: domain.title,
      subtopic: `${Math.round(domain.weight * 100)}% of scored content`,
      questionCount: viableQuestionRows(noteId, note)
        .filter((row) => row.topic === domain.title)
        .length,
      averageScore: 0,
      weight: domain.weight
    }));
  }

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

function certificationReadiness(noteId) {
  const note = noteSummary(noteId);
  if (!note) return null;
  const rows = sqlite(`
    SELECT
      q.id,
      q.topic,
      q.subtopic,
      q.prompt,
      q.answer,
      q.understanding_score,
      v.id AS variant_id,
      v.delivery_type,
      v.prompt AS variant_prompt,
      v.answer AS variant_answer,
      v.choices AS variant_choices,
      COUNT(a.id) AS attempt_count,
      COALESCE(AVG(a.score), 0) AS attempt_score
    FROM questions q
    LEFT JOIN question_variants v ON v.question_id = q.id
    LEFT JOIN attempts a ON a.question_id = q.id
    WHERE q.note_id = '${sqlEscape(noteId)}'
    GROUP BY q.id
  `, { json: true }).filter((row) => !isLowQualityQuestion(row, note));

  const domains = certificationDomainsFor(note);
  const exam = certificationExamFor(note);
  const domainRows = domains.map((domain) => {
    const related = usesOfficialCertificationDomains(note)
      ? rows.filter((row) => row.topic === domain.title)
      : rows.filter((row) => {
        const guessed = certificationDomainFor(note, `${row.topic} ${row.subtopic} ${row.prompt} ${row.answer}`);
        return guessed.key === domain.key;
      });
    const attempted = related.filter((row) => Number(row.attempt_count || 0) > 0);
    const score = attempted.length > 0
      ? attempted.reduce((sum, row) => sum + Number(row.attempt_score || 0), 0) / attempted.length
      : related.length > 0
        ? related.reduce((sum, row) => sum + Number(row.understanding_score || 0), 0) / related.length
        : 0;
    return {
      key: domain.key,
      title: domain.title,
      weight: domain.weight,
      score,
      questionCount: related.length,
      attemptedCount: attempted.length
    };
  });
  const totalWeight = domainRows.reduce((sum, domain) => sum + domain.weight, 0) || 1;
  const readiness = domainRows.reduce((sum, domain) => sum + (domain.score * domain.weight), 0) / totalWeight;
  return {
    noteId,
    exam: exam.name,
    scoredQuestions: exam.scoredQuestions,
    unscoredQuestions: exam.unscoredQuestions,
    passingScore: exam.passingScore,
    readiness,
    scaledPracticeScore: Math.round(100 + readiness * 900),
    domains: domainRows
  };
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
You are QuizLoop's mastery-expansion agent.
Use ONLY the note text. Return valid JSON only.

The learner mastered the concepts below. Create ${target} harder or adjacent question objects from the same note.
Do not repeat any existing prompt. Do not ask the same fact in the same way.
Do not return a question whose correct answer is equivalent to an existing answer.
Do not turn a mastered answer into a new prompt. Move to a fresh adjacent concept from the note.
Prioritize the untapped note passages. They are the evidence SQLite found that is least covered by prior questions.
Prefer comparison, sequence, consequence, and application questions over basic recall.
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
You are QuizLoop's learning-object expansion agent.
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
- If expansion reason is mastered_repeat_suppressed, the learner already mastered the selected concepts. Generate harder, adjacent, or more integrative questions from the note. Do not return any question that tests the same answer in the same way.
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
You are QuizLoop's coverage backfill agent.
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
  if (isCertificationNote(note)) {
    const queued = queueCertificationFromSourceBank(noteId, options.force ? "source_mastery_unlock" : "source_follow_up");
    if (queued) {
      recordModelRun({
        noteId,
        task: "certification_source_first_next_quiz",
        promptVersion: "web.certification_source_first.v1",
        status: queued.status,
        detail: `Certification quiz queued from saved source-bank questions instead of generating new questions.`
      });
      return { saved: queued.saved || 0, status: queued.status };
    }
  }
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
    let queued = noteNeedsQuestionBackfill(refreshed)
      ? { status: "insufficient_bank", saved: 0 }
      : enqueueQuizForNote(noteId, options.force ? "mastery_expansion" : "follow_up", {
        focus: options.focus || "",
        allowMasteredSuppression: false
      });
    if (queued.status === "insufficient_bank" || queued.status === "insufficient_viable_questions") {
      sqlite(`DELETE FROM quiz_queue WHERE note_id = '${sqlEscape(noteId)}' AND state = 'ready';`);
      queued = enqueueQuizForNote(noteId, options.force ? "mastery_review" : "review", {
        focus: options.focus || "",
        allowMasteredSuppression: false,
        relaxed: true
      });
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

function compactSentence(value, limit = 220) {
  const text = String(value || "")
    .replace(/\s+/g, " ")
    .trim();
  if (text.length <= limit) return text;
  return `${text.slice(0, limit - 1).trim()}...`;
}

function awsServiceTeachingLine(answer) {
  const value = normalizeText(answer);
  const entries = [
    [/iam role|identity and access management role|temporary credential/, "IAM roles are the safer exam answer when AWS resources need temporary permissions without long-term access keys."],
    [/iam policy|least privilege/, "IAM policies should grant only the permissions required for the task being tested."],
    [/cloudfront/, "CloudFront is the edge caching/CDN choice for reducing latency and serving content closer to users."],
    [/s3 lifecycle|lifecycle policy/, "S3 Lifecycle policies automate moving or expiring objects, which is usually the cost-control answer for aging object data."],
    [/s3 intelligent tiering/, "S3 Intelligent-Tiering is useful when access patterns are unknown or changing."],
    [/amazon s3|simple storage service/, "Amazon S3 is object storage, not block storage or a shared file system."],
    [/sqs|simple queue service/, "SQS decouples producers and consumers so spikes can be buffered instead of overwhelming downstream services."],
    [/sns|simple notification service/, "SNS is publish-subscribe messaging for fan-out notifications to multiple subscribers."],
    [/eventbridge/, "EventBridge routes events from AWS services, SaaS apps, or custom apps to targets using rules."],
    [/step functions/, "Step Functions coordinates multi-step workflows, branching, retries, and state between services."],
    [/lambda/, "Lambda is the serverless compute choice when code should run without managing servers."],
    [/ec2 auto scaling|auto scaling group/, "Auto Scaling adds or removes EC2 capacity to match demand and improve availability."],
    [/elastic load balancing|application load balancer|network load balancer|alb|nlb/, "Elastic Load Balancing distributes traffic across healthy targets to improve availability and scale."],
    [/rds multi az|multi az/, "RDS Multi-AZ is for high availability and automatic failover, not read scaling."],
    [/read replica/, "Read replicas are mainly for read scaling and can also support some disaster recovery patterns."],
    [/point in time|pitr|automated backup/, "Automated backups and point-in-time recovery are the restore-path answer when recovering to a specific time."],
    [/efs|elastic file system/, "EFS is a regional shared file system for Linux workloads that need concurrent access across instances."],
    [/ebs|elastic block store/, "EBS is block storage attached to EC2 instances within an Availability Zone."],
    [/dynamodb dax/, "DAX is the managed in-memory cache for DynamoDB when microsecond read latency is needed."],
    [/dynamodb/, "DynamoDB is the managed NoSQL key-value/document database for high scale and low latency."],
    [/kinesis/, "Kinesis is used for real-time streaming data ingestion and processing."],
    [/glue/, "AWS Glue is commonly the managed ETL/data catalog choice in analytics workflows."],
    [/athena/, "Athena queries data in S3 using SQL without managing servers."],
    [/cloudtrail/, "CloudTrail records API activity for auditing who did what in an AWS account."],
    [/cloudwatch/, "CloudWatch is the monitoring and metrics/logs/alarm service for operational visibility."],
    [/config/, "AWS Config tracks resource configuration history and evaluates compliance against rules."],
    [/security hub/, "Security Hub aggregates and prioritizes security findings across AWS services and accounts."],
    [/guardduty/, "GuardDuty detects threats from account, network, and DNS activity."],
    [/macie/, "Macie discovers and protects sensitive data, especially in Amazon S3."],
    [/kms|key management service/, "KMS manages encryption keys used by AWS services and applications."],
    [/secrets manager/, "Secrets Manager stores and rotates secrets such as database passwords and API keys."],
    [/waf/, "AWS WAF filters HTTP/S requests at the application layer."],
    [/shield/, "AWS Shield protects against DDoS attacks."],
    [/acm|certificate manager/, "ACM provisions and manages TLS certificates for supported AWS services."],
    [/vpc endpoint|private link|privatelink/, "VPC endpoints keep supported AWS service traffic private without sending it over the public internet."],
    [/route 53/, "Route 53 is DNS and routing, including health-check-based routing policies."],
    [/trusted advisor/, "Trusted Advisor checks accounts for cost, performance, security, fault tolerance, and service limit recommendations."],
    [/compute optimizer/, "Compute Optimizer recommends better resource sizes based on utilization patterns."],
    [/cost anomaly detection/, "Cost Anomaly Detection alerts on unusual spend patterns."],
    [/budgets/, "AWS Budgets tracks cost or usage against thresholds and sends alerts."],
    [/pricing calculator/, "The AWS Pricing Calculator estimates cost before deployment."],
    [/artifact/, "AWS Artifact provides access to AWS compliance reports and agreements."],
    [/organizations|service control polic|scp/, "AWS Organizations and SCPs centrally govern accounts and set maximum allowed permissions."],
    [/control tower/, "Control Tower sets up and governs a multi-account AWS landing zone."],
    [/well architected/, "The Well-Architected Framework is the exam lens for evaluating architecture tradeoffs across operational excellence, security, reliability, performance, cost, and sustainability."]
  ];
  const match = entries.find(([pattern]) => pattern.test(value));
  return match ? match[1] : "";
}

function certificationDomainTeachingLine(topic) {
  const value = normalizeText(topic);
  if (value.includes("secure") || value.includes("security")) return "Exam lens: choose the option that reduces risk with least privilege, encryption, private connectivity, or managed detection.";
  if (value.includes("resilient") || value.includes("reliability")) return "Exam lens: prefer designs that survive failures across Availability Zones, recover data, and remove single points of failure.";
  if (value.includes("high performing") || value.includes("technology")) return "Exam lens: match the service to the workload's latency, throughput, scale, and operational constraints.";
  if (value.includes("cost") || value.includes("billing")) return "Exam lens: choose the option that meets the requirement while avoiding unnecessary fixed capacity or manual work.";
  if (value.includes("cloud concepts")) return "Exam lens: connect the scenario to the core cloud benefit being tested.";
  return "Exam lens: identify the requirement first, then choose the AWS service or design pattern that directly satisfies it.";
}

function certificationAttemptFeedback({ question, variant, response, expectedAnswer, score }) {
  const answer = compactSentence(expectedAnswer, 160);
  const prompt = variant?.prompt || question.prompt || "";
  const rubric = variant?.rubric || question.rubric || "";
  const source = question.source_excerpt || question.sourceExcerpt || "";
  const angle = normalizeText(question.assessment_angle || "");
  const serviceLine = awsServiceTeachingLine(expectedAnswer);
  const responseServiceLine = response && normalizeText(response) !== normalizeText(expectedAnswer)
    ? awsServiceTeachingLine(response)
    : "";
  const domainLine = certificationDomainTeachingLine(question.topic || "");
  const sourceLine = compactSentence(
    /^tests\s+/i.test(rubric) || /^quizloop\s+/i.test(source) ? "" : (rubric || source),
    180
  );
  const tested = compactSentence(question.subtopic || question.topic || "this concept", 120);
  const whyParts = [
    serviceLine,
    !serviceLine && sourceLine ? `The bank links this to ${sourceLine}` : "",
    !serviceLine && !sourceLine ? `The correct option is the one that directly satisfies ${tested}, not an adjacent AWS feature.` : "",
    angle.includes("trap") ? "This is a trap-style check, so the wrong-looking detail matters more than the broad service name." : "",
    domainLine
  ].filter(Boolean);
  const why = compactSentence(whyParts.join(" "), 360);
  if (Number(score) >= 1) {
    return `Correct. You recognized ${tested}. ${why}`;
  }
  const responseLine = response
    ? `Your answer was ${compactSentence(response, 100)}.`
    : "No answer was selected.";
  const responseWhy = responseServiceLine
    ? `That choice is usually about this: ${responseServiceLine} It does not best satisfy this requirement.`
    : "That choice does not best satisfy the requirement being tested.";
  return `Not yet. Correct answer: ${answer}. ${responseLine} ${responseWhy} This check is testing ${tested}. ${why}`;
}

async function submitQuiz(noteId, answers) {
  const attemptIds = [];
  let earned = 0;
  let possible = 0;
  const details = [];
  const note = noteSummary(noteId);
  const certMode = isCertificationNote(note);

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
    const feedback = certMode
      ? certificationAttemptFeedback({ question, variant, response: answer.response || "", expectedAnswer, score })
      : score === 1
        ? "Correct. Keep moving."
        : `Review this idea. Correct answer: ${expectedAnswer}`;
    const matchedIdeas = score === 1
      ? [question.subtopic || expectedAnswer, expectedAnswer].filter(Boolean)
      : [];
    const missingIdeas = score === 1
      ? []
      : [question.subtopic || expectedAnswer, expectedAnswer].filter(Boolean);
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
        '${sqlEscape(JSON.stringify(matchedIdeas))}',
        '${sqlEscape(JSON.stringify(missingIdeas))}',
        ${Date.now() / 1000}
      );
    `);
    saveAnswerEvaluation({
      attemptId: id,
      question,
      noteId,
      score,
      verdict: feedback,
      matchedIdeas,
      missingIdeas
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

  let nextQuiz = queueInitialQuiz(noteId);
  if (!["ready", "already_ready"].includes(nextQuiz.status)) {
    nextQuiz = queueNextQuiz(noteId, details, score >= 0.999
      ? { force: true, reason: "perfect_score_mastery_unlock" }
      : {});
  }
  const missed = details.filter((detail) => Number(detail.score || 0) < 1);
  const mastered = details.filter((detail) => Number(detail.score || 0) >= 1);
  const learningEvidence = {
    headline: certMode ? "Exam memory updated" : "Learning memory updated",
    summary: missed.length > 0
      ? certMode
        ? `QuizLoop saved ${missed.length} exam gap${missed.length === 1 ? "" : "s"} and will bring them back in certification-style questions.`
        : `QuizLoop saved ${missed.length} missed idea${missed.length === 1 ? "" : "s"} and will bring them back in a new form.`
      : certMode
        ? `QuizLoop saved ${mastered.length} mastered exam signal${mastered.length === 1 ? "" : "s"} and is preparing adjacent or harder certification questions.`
        : `QuizLoop saved ${mastered.length} mastered idea${mastered.length === 1 ? "" : "s"} and is preparing fresh or harder questions.`,
    nextAction: missed.length > 0
      ? "Next quiz prioritizes weak areas without repeating the same wording."
      : "Next quiz moves toward adjacent or harder material.",
    masteredCount: mastered.length,
    missedCount: missed.length,
    masteredConcepts: [...new Set(mastered.map((detail) => conceptRootKey(detail)).filter(Boolean))],
    missedConcepts: [...new Set(missed.map((detail) => conceptRootKey(detail)).filter(Boolean))]
  };
  return { id: sessionId, noteId, score, details, nextQuiz, learningEvidence };
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
    attemptCount: String(session.attempt_ids || "").split(/\n+/).filter(Boolean).length,
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
    attemptCount: String(session.attempt_ids || "").split(/\n+/).filter(Boolean).length,
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

function evidenceSnapshot() {
  const totals = sqlite(`
    SELECT
      (SELECT COUNT(*) FROM notes) AS notes,
      (SELECT COUNT(*) FROM questions) AS questions,
      (SELECT COUNT(*) FROM attempts) AS attempts,
      (SELECT COUNT(*) FROM quiz_sessions) AS quizzes,
      (SELECT COUNT(*) FROM leads) AS leads,
      (SELECT COUNT(*) FROM user_actions) AS user_actions,
      (SELECT COUNT(*) FROM model_runs) AS model_runs,
      (SELECT COUNT(*) FROM quiz_queue WHERE state = 'ready' AND consumed_at IS NULL) AS ready_quizzes
  `, { json: true })[0] || {};

  const noteEvidence = sqlite(`
    SELECT
      n.id,
      n.title,
      n.status,
      COUNT(DISTINCT q.id) AS question_count,
      COUNT(DISTINCT a.id) AS attempt_count,
      COUNT(DISTINCT s.id) AS quiz_count,
      AVG(a.score) AS average_score,
      MAX(s.created_at) AS latest_quiz_at
    FROM notes n
    LEFT JOIN questions q ON q.note_id = n.id
    LEFT JOIN attempts a ON a.note_id = n.id
    LEFT JOIN quiz_sessions s ON s.note_id = n.id
    GROUP BY n.id
    ORDER BY latest_quiz_at DESC, n.created_at DESC
    LIMIT 20
  `, { json: true }).map((row) => ({
    id: row.id,
    title: row.title || "Untitled Note",
    status: row.status || "new",
    questionCount: Number(row.question_count || 0),
    attemptCount: Number(row.attempt_count || 0),
    quizCount: Number(row.quiz_count || 0),
    averageScore: Number(row.average_score || 0),
    latestQuizAt: Number(row.latest_quiz_at || 0)
  }));

  const recentModelRuns = sqlite(`
    SELECT task, prompt_version, status, detail, created_at
    FROM model_runs
    ORDER BY created_at DESC
    LIMIT 30
  `, { json: true }).map((row) => ({
    task: row.task,
    promptVersion: row.prompt_version,
    status: row.status,
    detail: row.detail,
    createdAt: Number(row.created_at || 0)
  }));

  const recentActions = sqlite(`
    SELECT action_type, object_type, object_id, payload, created_at
    FROM user_actions
    ORDER BY created_at DESC
    LIMIT 30
  `, { json: true }).map((row) => ({
    actionType: row.action_type,
    objectType: row.object_type,
    objectId: row.object_id,
    payload: safeJSON(row.payload, {}),
    createdAt: Number(row.created_at || 0)
  }));

  const recentLeads = sqlite(`
    SELECT id, email, name, audience, goal, source, status, created_at
    FROM leads
    ORDER BY created_at DESC
    LIMIT 30
  `, { json: true }).map((row) => ({
    id: row.id,
    email: row.email,
    name: row.name,
    audience: row.audience,
    goal: row.goal,
    source: row.source,
    status: row.status,
    createdAt: Number(row.created_at || 0)
  }));

  return {
    generatedAt: new Date().toISOString(),
    totals: {
      notes: Number(totals.notes || 0),
      questions: Number(totals.questions || 0),
      attempts: Number(totals.attempts || 0),
      quizzes: Number(totals.quizzes || 0),
      leads: Number(totals.leads || 0),
      userActions: Number(totals.user_actions || 0),
      modelRuns: Number(totals.model_runs || 0),
      readyQuizzes: Number(totals.ready_quizzes || 0)
    },
    noteEvidence,
    recentLeads,
    recentModelRuns,
    recentActions
  };
}

function labSnapshot() {
  const certNotes = listNotes().filter((note) => isCertificationNote(note));
  const exams = certNotes.map((note) => {
    const readiness = certificationReadiness(note.id);
    const sourceBreakdown = sqlite(`
      SELECT provenance_kind, source_provider, COUNT(*) AS count
      FROM questions
      WHERE note_id = '${sqlEscape(note.id)}'
      GROUP BY provenance_kind, source_provider
      ORDER BY count DESC
    `, { json: true }).map((row) => ({
      provenanceKind: row.provenance_kind || "unknown",
      sourceProvider: row.source_provider || "unknown",
      count: Number(row.count || 0)
    }));

    const domainBreakdown = sqlite(`
      SELECT
        topic,
        COUNT(*) AS total,
        SUM(CASE WHEN provenance_kind IN ('curated_bank', 'licensed_bank') THEN 1 ELSE 0 END) AS source_bank,
        SUM(CASE WHEN assessment_angle = 'scenario' THEN 1 ELSE 0 END) AS scenario,
        SUM(CASE WHEN assessment_angle IN ('application', 'exam practice') THEN 1 ELSE 0 END) AS application,
        SUM(CASE WHEN assessment_angle = 'tradeoff' THEN 1 ELSE 0 END) AS tradeoff,
        SUM(CASE WHEN assessment_angle = 'detail' THEN 1 ELSE 0 END) AS detail,
        SUM(CASE WHEN assessment_angle = 'trap' THEN 1 ELSE 0 END) AS trap
      FROM questions
      WHERE note_id = '${sqlEscape(note.id)}'
      GROUP BY topic
      ORDER BY total DESC
    `, { json: true }).map((row) => ({
      topic: row.topic || "Untitled domain",
      total: Number(row.total || 0),
      sourceBank: Number(row.source_bank || 0),
      scenario: Number(row.scenario || 0),
      application: Number(row.application || 0),
      tradeoff: Number(row.tradeoff || 0),
      detail: Number(row.detail || 0),
      trap: Number(row.trap || 0)
    }));

    const latestMisses = sqlite(`
      SELECT
        a.topic_snapshot AS topic,
        a.subtopic_snapshot AS subtopic,
        a.prompt_snapshot AS prompt,
        a.answer_snapshot AS answer,
        a.response,
        a.score,
        a.created_at AS created_at
      FROM attempts a
      WHERE a.note_id = '${sqlEscape(note.id)}'
        AND a.score < 0.95
      ORDER BY a.created_at DESC
      LIMIT 12
    `, { json: true }).map((row) => ({
      topic: row.topic || "Unknown",
      subtopic: row.subtopic || "",
      prompt: row.prompt || "",
      answer: row.answer || "",
      response: row.response || "",
      score: Number(row.score || 0),
      createdAt: Number(row.created_at || 0)
    }));

    const weakQuestions = sqlite(`
      SELECT
        q.id,
        q.topic,
        q.subtopic,
        q.prompt,
        q.answer,
        q.assessment_angle,
        q.provenance_kind,
        q.source_provider,
        COUNT(a.id) AS attempts,
        AVG(a.score) AS average_score,
        MAX(a.created_at) AS last_seen
      FROM questions q
      JOIN attempts a ON a.question_id = q.id
      WHERE q.note_id = '${sqlEscape(note.id)}'
      GROUP BY q.id
      HAVING attempts > 0 AND average_score < 0.8
      ORDER BY average_score ASC, last_seen DESC
      LIMIT 12
    `, { json: true }).map((row) => ({
      id: row.id,
      topic: row.topic || "Unknown",
      subtopic: row.subtopic || "",
      prompt: row.prompt || "",
      answer: row.answer || "",
      angle: row.assessment_angle || "",
      provenanceKind: row.provenance_kind || "",
      sourceProvider: row.source_provider || "",
      attempts: Number(row.attempts || 0),
      averageScore: Number(row.average_score || 0),
      lastSeen: Number(row.last_seen || 0)
    }));

    const queueRows = sqlite(`
      SELECT id, reason, question_ids, summary, created_at
      FROM quiz_queue
      WHERE note_id = '${sqlEscape(note.id)}'
        AND state = 'ready'
      ORDER BY created_at DESC
      LIMIT 3
    `, { json: true });
    const readyQueue = queueRows.map((queue) => {
      const ids = safeJSON(queue.question_ids, []);
      const idList = ids.map((id) => `'${sqlEscape(id)}'`).join(",");
      const questions = idList
        ? sqlite(`
          SELECT id, topic, subtopic, prompt, answer, assessment_angle, provenance_kind, source_provider
          FROM questions
          WHERE id IN (${idList})
        `, { json: true })
        : [];
      const order = new Map(ids.map((id, index) => [id, index]));
      questions.sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));
      return {
        id: queue.id,
        reason: queue.reason || "",
        summary: queue.summary || "",
        createdAt: Number(queue.created_at || 0),
        questions: questions.map((question) => ({
          id: question.id,
          topic: question.topic || "Unknown",
          subtopic: question.subtopic || "",
          prompt: question.prompt || "",
          answer: question.answer || "",
          angle: question.assessment_angle || "",
          provenanceKind: question.provenance_kind || "",
          sourceProvider: question.source_provider || ""
        }))
      };
    });

    const recentSessions = history(note.id).slice(0, 8);

    return {
      note,
      readiness,
      sourceBreakdown,
      domainBreakdown,
      latestMisses,
      weakQuestions,
      readyQueue,
      recentSessions
    };
  });

  return {
    generatedAt: new Date().toISOString(),
    database: dbPath,
    exams
  };
}

function cleanLeadText(value, max = 600) {
  return String(value || "").trim().replace(/\s+/g, " ").slice(0, max);
}

function createLead({ email, name, audience, goal, source }) {
  const cleanEmail = cleanLeadText(email, 180).toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanEmail)) {
    throw new Error("Enter a valid email.");
  }

  const lead = {
    id: crypto.randomUUID(),
    email: cleanEmail,
    name: cleanLeadText(name, 120),
    audience: cleanLeadText(audience, 120),
    goal: cleanLeadText(goal, 600),
    source: cleanLeadText(source || "landing", 80),
    createdAt: Date.now() / 1000
  };

  sqlite(`
    INSERT INTO leads (id, email, name, audience, goal, source, status, created_at)
    VALUES (
      '${sqlEscape(lead.id)}',
      '${sqlEscape(lead.email)}',
      '${sqlEscape(lead.name)}',
      '${sqlEscape(lead.audience)}',
      '${sqlEscape(lead.goal)}',
      '${sqlEscape(lead.source)}',
      'new',
      ${lead.createdAt}
    );
  `);

  recordUserAction({
    actionType: "lead.created",
    objectType: "lead",
    objectId: lead.id,
    payload: {
      email: lead.email,
      audience: lead.audience,
      source: lead.source
    }
  });

  return lead;
}

function safeJSON(value, fallback) {
  try {
    return JSON.parse(value || "");
  } catch {
    return fallback;
  }
}

function learnerReportPrompt(note, noteHistory, context) {
  const latestSessions = noteHistory.slice(0, 5).map((session) => ({
    score: Math.round(Number(session.score || 0) * 100),
    createdAt: session.createdAt
  }));
  const weakConcepts = (context?.weakConcepts || context?.weak_questions || [])
    .slice(0, 8);
  const strongConcepts = (context?.strongConcepts || context?.mastered_questions || [])
    .slice(0, 8);

  return `
You are QuizLoop.ai's learner report writer.
Write a concise progress report for a student from stored quiz evidence.
Do not invent facts. If evidence is missing, say what needs more attempts.
Use plain language and no hype.
Use plain text section headings. Do not use Markdown bold, tables, or decorative formatting.

Return these sections:
1. Current state
2. What improved
3. What to practice next
4. Next quiz direction

NOTE:
${JSON.stringify(note, null, 2)}

RECENT QUIZZES:
${JSON.stringify(latestSessions, null, 2)}

WEAK CONCEPTS:
${JSON.stringify(weakConcepts, null, 2)}

STRONG CONCEPTS:
${JSON.stringify(strongConcepts, null, 2)}
`.trim();
}

function cleanLearnerReportText(report) {
  return String(report || "")
    .replace(/\*\*/g, "")
    .replace(/^\s*\*(\d+\.\s*)?/gm, "")
    .replace(/^\s*Here is.*?:\s*/i, "")
    .trim();
}

function learnerReportFromEvidence(note, noteHistory, context, reason = "") {
  const latestScores = noteHistory
    .slice(0, 5)
    .map((session) => `${Math.round(Number(session.score || 0) * 100)}%`);
  const weakConcepts = (context?.weakConcepts || [])
    .slice(0, 4)
    .map((concept) => concept.prompt || concept.key)
    .filter(Boolean);
  const masteredConcepts = (context?.masteredConcepts || [])
    .slice(0, 4)
    .filter(Boolean);
  const answered = Number(note.attemptCount || 0);
  const questionCount = Number(note.questionCount || 0);
  const understood = Math.round(Number(note.averageScore || 0) * 100);
  const evidenceNote = reason
    ? `\n\nModel note\nThe live report model was unavailable (${reason}), so this report was built from saved SQLite learning evidence.`
    : "";

  return [
    "Current state",
    `${note.title} is ${understood}% understood based on ${answered} saved answer${answered === 1 ? "" : "s"} across ${questionCount} generated check${questionCount === 1 ? "" : "s"}.`,
    "",
    "What improved",
    latestScores.length
      ? `Recent quiz scores: ${latestScores.join(", ")}. These scores are now part of the next quiz context.`
      : "There is not enough quiz history yet. Take one quiz so QuizLoop can measure a baseline.",
    "",
    "What to practice next",
    weakConcepts.length
      ? weakConcepts.map((item) => `- ${item}`).join("\n")
      : "No clear weak concept is visible yet. The next quiz should broaden coverage and gather more evidence.",
    "",
    "Next quiz direction",
    masteredConcepts.length
      ? `Avoid repeating mastered concepts too soon: ${masteredConcepts.join(", ")}. Mix in adjacent or harder checks.`
      : "Start with broad recall and one applied question, then personalize from the answers.",
    evidenceNote
  ].join("\n");
}

async function generateLearnerReport(noteId) {
  const note = noteSummary(noteId);
  if (!note) return null;

  const noteHistory = history(noteId);
  const context = learningContextForNote(noteId);
  const prompt = learnerReportPrompt(note, noteHistory, context);
  const preferredModel = geminiApiKey ? geminiModel : gemmaModel;
  const preferredProvider = geminiApiKey ? "gemini" : "gemma";

  recordModelRun({
    noteId,
    task: "learner_report",
    promptVersion: "xprize.learner_report.v1",
    status: "started",
    detail: preferredModel
  });

  try {
    const report = geminiApiKey
      ? await geminiText(prompt)
      : await gemmaText(prompt, 90000);
    recordModelRun({
      noteId,
      task: "learner_report",
      promptVersion: "xprize.learner_report.v1",
      status: "success",
      detail: preferredModel
    });
    recordUserAction({
      noteId,
      actionType: "learner_report.generated",
      objectType: "note",
      objectId: noteId,
      payload: { model: preferredModel, provider: preferredProvider, quizCount: noteHistory.length }
    });
    return { note, report: cleanLearnerReportText(report), model: preferredModel, provider: preferredProvider };
  } catch (error) {
    if (geminiApiKey) {
      try {
        const report = await gemmaText(prompt, 90000);
        recordModelRun({
          noteId,
          task: "learner_report",
          promptVersion: "xprize.learner_report.v1",
          status: "success",
          detail: `${gemmaModel} fallback after ${error.message}`
        });
        recordUserAction({
          noteId,
          actionType: "learner_report.generated",
          objectType: "note",
          objectId: noteId,
          payload: { model: gemmaModel, provider: "gemma", fallbackFrom: geminiModel, quizCount: noteHistory.length }
        });
        return { note, report: cleanLearnerReportText(report), model: gemmaModel, provider: "gemma" };
      } catch (gemmaError) {
        const report = learnerReportFromEvidence(note, noteHistory, context, gemmaError.message);
        recordModelRun({
          noteId,
          task: "learner_report",
          promptVersion: "xprize.learner_report.v1",
          status: "success",
          detail: `sqlite evidence fallback after ${gemmaError.message}`
        });
        recordUserAction({
          noteId,
          actionType: "learner_report.generated",
          objectType: "note",
          objectId: noteId,
          payload: { model: "sqlite-evidence", provider: "sqlite", fallbackFrom: gemmaModel, quizCount: noteHistory.length }
        });
        return { note, report, model: "SQLite evidence", provider: "sqlite" };
      }
    }

    const report = learnerReportFromEvidence(note, noteHistory, context, error.message);
    recordModelRun({
      noteId,
      task: "learner_report",
      promptVersion: "xprize.learner_report.v1",
      status: "success",
      detail: `sqlite evidence fallback after ${error.message}`
    });
    recordUserAction({
      noteId,
      actionType: "learner_report.generated",
      objectType: "note",
      objectId: noteId,
      payload: { model: "sqlite-evidence", provider: "sqlite", fallbackFrom: preferredModel, quizCount: noteHistory.length }
    });
    return { note, report, model: "SQLite evidence", provider: "sqlite" };
  }
}

async function handleAPI(request, response, url) {
  if ((request.method === "GET" || request.method === "HEAD") && url.pathname === "/api/health") {
    return writeJSON(response, 200, {
      ok: true,
      mode: "web",
      model: gemmaModel,
      gemini: {
        configured: Boolean(geminiApiKey),
        model: geminiModel
      },
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
      model: gemmaModel,
      gemini: {
        configured: Boolean(geminiApiKey),
        model: geminiModel
      }
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

  if (request.method === "GET" && url.pathname === "/api/evidence") {
    return writeJSON(response, 200, { evidence: evidenceSnapshot() });
  }

  if (request.method === "GET" && url.pathname === "/api/lab") {
    return writeJSON(response, 200, { lab: labSnapshot() });
  }

  if (request.method === "POST" && url.pathname === "/api/leads") {
    const body = await readJSON(request);
    const lead = createLead({
      email: body.email,
      name: body.name,
      audience: body.audience,
      goal: body.goal,
      source: body.source || "aws-cert-landing"
    });
    return writeJSON(response, 201, { lead });
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
    const queued = queueInitialQuiz(note.id);
    return writeJSON(response, 201, { note: noteSummary(note.id), nextQuiz: visibleNextQuizState(note.id, queued) });
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
    const queued = queueInitialQuiz(note.id);
    return writeJSON(response, 201, { note: noteSummary(note.id), nextQuiz: visibleNextQuizState(note.id, queued) });
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
    const queued = queueInitialQuiz(note.id);
    return writeJSON(response, 200, { note: noteSummary(note.id), nextQuiz: visibleNextQuizState(note.id, queued) });
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

  const readinessMatch = url.pathname.match(/^\/api\/notes\/([^/]+)\/cert-readiness$/);
  if (request.method === "GET" && readinessMatch) {
    const readiness = certificationReadiness(readinessMatch[1]);
    if (!readiness) return writeJSON(response, 404, { error: "Note not found." });
    return writeJSON(response, 200, { readiness });
  }

  const reportMatch = url.pathname.match(/^\/api\/notes\/([^/]+)\/learner-report$/);
  if (request.method === "POST" && reportMatch) {
    const report = await generateLearnerReport(reportMatch[1]);
    if (!report) return writeJSON(response, 404, { error: "Note not found." });
    return writeJSON(response, 200, report);
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
  console.log(`QuizLoop web running at http://${host}:${port}`);
  console.log(`Gemma endpoint: ${gemmaBaseURL} (${gemmaModel})`);
});
