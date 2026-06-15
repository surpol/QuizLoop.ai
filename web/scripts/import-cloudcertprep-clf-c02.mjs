import crypto from "node:crypto";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const webDir = dirname(__dirname);
const dataDir = join(webDir, "data");
const dbPath = process.env.ACCORDIAN_DB_PATH || join(dataDir, "accordian.sqlite");
const cloudCertPrepBaseURL = "https://raw.githubusercontent.com/nastaso/cloudcertprep/main/src/data";
const certCode = (process.argv[2] || "clf-c02").toLowerCase();

const certs = {
  "clf-c02": {
    code: "clf-c02",
    titleMatchers: ["Cloud Practitioner", "CLF-C02"],
    domains: [
      { id: 1, title: "Cloud Concepts", file: "domain1.json" },
      { id: 2, title: "Security and Compliance", file: "domain2.json" },
      { id: 3, title: "Cloud Technology and Services", file: "domain3.json" },
      { id: 4, title: "Billing, Pricing, and Support", file: "domain4.json" }
    ]
  },
  "saa-c03": {
    code: "saa-c03",
    titleMatchers: ["Solutions Architect", "SAA-C03"],
    domains: [
      { id: 1, title: "Design Secure Architectures", file: "domain1.json" },
      { id: 2, title: "Design Resilient Architectures", file: "domain2.json" },
      { id: 3, title: "Design High-Performing Architectures", file: "domain3.json" },
      { id: 4, title: "Design Cost-Optimized Architectures", file: "domain4.json" }
    ]
  }
};

const cert = certs[certCode];
if (!cert) {
  throw new Error(`Unsupported CloudCertPrep certification: ${certCode}`);
}

mkdirSync(dataDir, { recursive: true });

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
    throw new Error(result.stderr || "SQLite query failed");
  }
  return json ? JSON.parse(result.stdout || "[]") : result.stdout;
}

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

function ensureSourceSchema() {
  sqlite(`
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
  `);
  ensureColumns("questions", [
    ["source_id", "TEXT NOT NULL DEFAULT ''"],
    ["source_provider", "TEXT NOT NULL DEFAULT ''"],
    ["source_url", "TEXT NOT NULL DEFAULT ''"],
    ["source_license", "TEXT NOT NULL DEFAULT ''"],
    ["source_license_url", "TEXT NOT NULL DEFAULT ''"],
    ["provenance_kind", "TEXT NOT NULL DEFAULT 'ai_generated'"]
  ]);
}

function cloudCertPrepSourceMetadata(sourceKey) {
  const code = cert.code.toUpperCase();
  return {
    id: deterministicId("question-source", `cloudcertprep:${code}`),
    provider: "CloudCertPrep",
    sourceKey,
    sourceUrl: "https://github.com/nastaso/cloudcertprep",
    licenseName: "MIT",
    licenseUrl: "https://github.com/nastaso/cloudcertprep/blob/main/LICENSE",
    citation: `CloudCertPrep ${code} MIT-licensed practice question bank`,
    certificationCode: code,
    provenanceKind: "licensed_bank"
  };
}

function registerQuestionSource(metadata) {
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
      '${sqlEscape(metadata.provenanceKind || "licensed_bank")}',
      ${Date.now() / 1000}
    );
  `);
}

function normalizeText(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function promptFingerprint(prompt) {
  return normalizeText(prompt).slice(0, 260);
}

function answerKey(answer) {
  return normalizeText(answer).slice(0, 180);
}

function shuffled(values) {
  return [...values].sort(() => Math.random() - 0.5);
}

async function loadDomain(domain) {
  const response = await fetch(`${cloudCertPrepBaseURL}/${cert.code}/${domain.file}`);
  if (!response.ok) throw new Error(`Could not download ${domain.file}: ${response.status}`);
  return response.json();
}

function certificationNoteId() {
  const clauses = cert.titleMatchers.map((matcher) => {
    const escaped = sqlEscape(`%${matcher}%`);
    return `title LIKE '${escaped}' OR body LIKE '${escaped}'`;
  }).join(" OR ");
  const row = sqlite(`
    SELECT id FROM notes
    WHERE source_type = 'certs'
      AND (${clauses})
    ORDER BY created_at ASC
    LIMIT 1;
  `, { json: true })[0];
  if (!row?.id) {
    throw new Error(`No ${cert.code.toUpperCase()} certification note found. Add it in the app first.`);
  }
  return row.id;
}

function existingFingerprints(noteId) {
  return new Set(sqlite(`
    SELECT prompt FROM questions
    WHERE note_id = '${sqlEscape(noteId)}';
  `, { json: true }).map((row) => promptFingerprint(row.prompt)));
}

function existingQuestionIds(noteId) {
  return new Set(sqlite(`
    SELECT generation_source FROM questions
    WHERE note_id = '${sqlEscape(noteId)}'
      AND generation_source LIKE 'cloudcertprep:${sqlEscape(cert.code)}:%';
  `, { json: true }).map((row) => row.generation_source));
}

function insertQuestion(noteId, domain, item) {
  if (Array.isArray(item.answer)) return false;
  const correctLetter = String(item.answer || "").trim();
  const correctAnswer = item.options?.[correctLetter];
  if (!correctAnswer) return false;
  const choices = Object.values(item.options || {}).map(String).filter(Boolean);
  if (choices.length !== 4) return false;
  const questionId = crypto.randomUUID();
  const variantId = crypto.randomUUID();
  const prompt = String(item.question || "").trim();
  const explanation = String(item.explanation || "").trim();
  const source = `cloudcertprep:${cert.code}:${domain.id}:${item.id}`;
  const sourceMetadata = cloudCertPrepSourceMetadata(source);
  registerQuestionSource(sourceMetadata);
  const subtopic = `${domain.title} practice`;
  const conceptSignature = `${domain.title}:${promptFingerprint(prompt)}:${answerKey(correctAnswer)}`.slice(0, 260);
  const now = Date.now() / 1000;

  sqlite(`
    INSERT INTO questions (
      id, note_id, topic_id, segment_id, concept_id, topic, subtopic,
      assessment_angle, concept_signature, generation_source, prompt, answer,
      choices, importance, difficulty, understanding_score, mastery_state,
      source_id, source_provider, source_url, source_license, source_license_url,
      provenance_kind, created_at
    ) VALUES (
      '${questionId}',
      '${sqlEscape(noteId)}',
      NULL,
      NULL,
      NULL,
      '${sqlEscape(domain.title)}',
      '${sqlEscape(subtopic)}',
      'exam_practice',
      '${sqlEscape(conceptSignature)}',
      '${sqlEscape(source)}',
      '${sqlEscape(prompt)}',
      '${sqlEscape(correctAnswer)}',
      '${sqlEscape(JSON.stringify(shuffled(choices)))}',
      1,
      1,
      0,
      'new',
      '${sqlEscape(sourceMetadata.id)}',
      '${sqlEscape(sourceMetadata.provider)}',
      '${sqlEscape(sourceMetadata.sourceUrl)}',
      '${sqlEscape(sourceMetadata.licenseName)}',
      '${sqlEscape(sourceMetadata.licenseUrl)}',
      '${sqlEscape(sourceMetadata.provenanceKind)}',
      ${now}
    );
    INSERT INTO question_variants (
      id, question_id, note_id, delivery_type, prompt, answer, choices, rubric, created_at
    ) VALUES (
      '${variantId}',
      '${questionId}',
      '${sqlEscape(noteId)}',
      'multiple_choice',
      '${sqlEscape(prompt)}',
      '${sqlEscape(correctAnswer)}',
      '${sqlEscape(JSON.stringify(shuffled(choices)))}',
      '${sqlEscape(explanation)}',
      ${now}
    );
  `);
  return true;
}

async function main() {
  if (!existsSync(dbPath)) throw new Error(`SQLite database not found: ${dbPath}`);
  ensureSourceSchema();
  const noteId = certificationNoteId();
  const fingerprints = existingFingerprints(noteId);
  const sources = existingQuestionIds(noteId);
  let downloaded = 0;
  let skippedMulti = 0;
  let skippedDuplicate = 0;
  let inserted = 0;

  for (const domain of cert.domains) {
    const questions = await loadDomain(domain);
    downloaded += questions.length;
    for (const item of questions) {
      if (Array.isArray(item.answer)) {
        skippedMulti += 1;
        continue;
      }
      const source = `cloudcertprep:${cert.code}:${domain.id}:${item.id}`;
      const fingerprint = promptFingerprint(item.question);
      if (sources.has(source) || fingerprints.has(fingerprint)) {
        skippedDuplicate += 1;
        continue;
      }
      if (insertQuestion(noteId, domain, item)) {
        inserted += 1;
        sources.add(source);
        fingerprints.add(fingerprint);
      }
    }
  }

  sqlite(`DELETE FROM quiz_queue WHERE note_id = '${sqlEscape(noteId)}' AND state = 'ready';`);
  sqlite(`UPDATE notes SET status = 'ready' WHERE id = '${sqlEscape(noteId)}';`);

  console.log(JSON.stringify({
    dbPath,
    noteId,
    downloaded,
    inserted,
    skippedMulti,
    skippedDuplicate,
    source: `CloudCertPrep MIT-licensed ${cert.code.toUpperCase()} question bank`
  }, null, 2));
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
