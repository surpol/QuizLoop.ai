import crypto from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const webDir = dirname(__dirname);
const tmpDir = join(webDir, ".tmp");
const cloudCertPrepBaseURL = "https://raw.githubusercontent.com/nastaso/cloudcertprep/main/src/data";
const certCode = (process.argv[2] || "clf-c02").toLowerCase();
const databaseName = process.env.D1_DATABASE || "quizloop-ai";

const certs = {
  "clf-c02": {
    code: "clf-c02",
    noteTitle: "AWS Cloud Practitioner",
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
    noteTitle: "AWS Solutions Architect Associate",
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
if (!cert) throw new Error(`Unsupported certification: ${certCode}`);

mkdirSync(tmpDir, { recursive: true });

function runWrangler(args) {
  const result = spawnSync("npx", ["wrangler", "d1", "execute", databaseName, "--remote", ...args], {
    cwd: webDir,
    encoding: "utf8",
    maxBuffer: 128 * 1024 * 1024
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "wrangler failed");
  }
  return result.stdout;
}

function wranglerJSON(args) {
  const output = runWrangler(["--json", ...args]);
  const payload = JSON.parse(output.match(/\[[\s\S]*\]\s*$/)?.[0] || "[]");
  return payload[0]?.results || [];
}

function sqlEscape(value) {
  return String(value ?? "").replaceAll("'", "''");
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

function shuffled(values) {
  const copy = [...values];
  for (let index = copy.length - 1; index > 0; index -= 1) {
    const next = crypto.randomInt(index + 1);
    [copy[index], copy[next]] = [copy[next], copy[index]];
  }
  return copy;
}

async function loadDomain(domain) {
  const response = await fetch(`${cloudCertPrepBaseURL}/${cert.code}/${domain.file}`);
  if (!response.ok) throw new Error(`Could not download ${cert.code}/${domain.file}: ${response.status}`);
  const data = await response.json();
  return Array.isArray(data) ? data : [];
}

function noteIdSelect() {
  const clauses = cert.titleMatchers.map((matcher) => {
    const escaped = sqlEscape(`%${matcher}%`);
    return `title LIKE '${escaped}' OR body LIKE '${escaped}'`;
  }).join(" OR ");
  return `(SELECT id FROM notes WHERE source_type = 'certs' AND (${clauses}) ORDER BY created_at ASC LIMIT 1)`;
}

function sourceFor(domain, item) {
  return `cloudcertprep:${cert.code}:${domain.id}:${item.id}`;
}

async function main() {
  const noteIdSQL = noteIdSelect();
  const existingColumns = new Set(wranglerJSON(["--command", "PRAGMA table_info(questions);"]).map((column) => column.name));
  const statements = [];
  for (const [name, definition] of [
    ["source_provider", "TEXT NOT NULL DEFAULT ''"],
    ["source_url", "TEXT NOT NULL DEFAULT ''"],
    ["source_license", "TEXT NOT NULL DEFAULT ''"],
    ["provenance_kind", "TEXT NOT NULL DEFAULT 'quizloop_seed'"],
    ["generation_source", "TEXT NOT NULL DEFAULT ''"]
  ]) {
    if (!existingColumns.has(name)) {
      statements.push(`ALTER TABLE questions ADD COLUMN ${name} ${definition};`);
    }
  }
  let downloaded = 0;
  let insertedCandidates = 0;
  let skippedMulti = 0;
  let skippedInvalid = 0;

  for (const domain of cert.domains) {
    const questions = await loadDomain(domain);
    downloaded += questions.length;
    for (const item of questions) {
      if (Array.isArray(item.answer)) {
        skippedMulti += 1;
        continue;
      }
      const correctLetter = String(item.answer || "").trim();
      const correctAnswer = item.options?.[correctLetter];
      const choices = Object.values(item.options || {}).map(String).filter(Boolean);
      const prompt = String(item.question || "").trim();
      if (!prompt || !correctAnswer || choices.length !== 4) {
        skippedInvalid += 1;
        continue;
      }
      const id = crypto.randomUUID();
      const choicesJSON = JSON.stringify(shuffled(choices));
      const source = sourceFor(domain, item);
      const fingerprint = promptFingerprint(prompt);
      statements.push(`
        INSERT INTO questions (
          id, note_id, topic, subtopic, prompt, answer, choices,
          source_provider, source_url, source_license, provenance_kind, generation_source,
          created_at
        )
        SELECT
          '${id}',
          ${noteIdSQL},
          '${sqlEscape(domain.title)}',
          '${sqlEscape(`${domain.title} practice`)}',
          '${sqlEscape(prompt)}',
          '${sqlEscape(correctAnswer)}',
          '${sqlEscape(choicesJSON)}',
          'CloudCertPrep',
          'https://github.com/nastaso/cloudcertprep',
          'MIT',
          'licensed_bank',
          '${sqlEscape(source)}',
          ${Date.now() / 1000}
        WHERE ${noteIdSQL} IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM questions
            WHERE note_id = ${noteIdSQL}
              AND (
                generation_source = '${sqlEscape(source)}'
                OR lower(prompt) = lower('${sqlEscape(prompt)}')
                OR lower(replace(replace(replace(prompt, '?', ''), '.', ''), ',', '')) = lower('${sqlEscape(fingerprint)}')
              )
          );
      `);
      insertedCandidates += 1;
    }
  }

  statements.push(`
    UPDATE questions
    SET source_provider = 'QuizLoop', provenance_kind = 'quizloop_seed'
    WHERE note_id = ${noteIdSQL}
      AND (source_provider IS NULL OR source_provider = '');
    DELETE FROM quiz_queue WHERE note_id = ${noteIdSQL} AND state = 'ready';
  `);

  const filePath = join(tmpDir, `cloudcertprep-${cert.code}-d1.sql`);
  writeFileSync(filePath, statements.join("\n"), "utf8");
  const output = runWrangler(["--file", filePath]);
  console.log(output);
  console.log(JSON.stringify({
    cert: cert.code.toUpperCase(),
    downloaded,
    insertedCandidates,
    skippedMulti,
    skippedInvalid,
    sqlFile: filePath,
    source: "CloudCertPrep MIT-licensed practice bank"
  }, null, 2));
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
