import { existsSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const baseUrl = process.env.QUIZLOOP_BASE_URL || "http://127.0.0.1:4173";
const quizRuns = Number(process.env.QUIZLOOP_AUDIT_RUNS || 5);
const expectedQuizSize = 10;
const dbPath = process.env.ACCORDIAN_DB_PATH || join(process.cwd(), "data", "accordian.sqlite");
const officialTopicsByTitle = new Map([
  ["AWS Cloud Practitioner Prep", [
    ["Cloud Concepts", 3],
    ["Security and Compliance", 3],
    ["Cloud Technology and Services", 3],
    ["Billing, Pricing, and Support", 1]
  ]],
  ["AWS Solutions Architect Associate Prep", [
    ["Design Secure Architectures", 3],
    ["Design Resilient Architectures", 3],
    ["Design High-Performing Architectures", 2],
    ["Design Cost-Optimized Architectures", 2]
  ]]
]);
const ambiguousSingleSelectPatterns = [
  /\bwhich of the following\b[^?]*\bare\b/i,
  /\bwhich (aws )?(services|features|statements|options|benefits|advantages)\b[^?]*\bare\b/i,
  /\bwhat are the (advantages|benefits|components|services|features)\b/i
];
const scenarioSignals = [
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
  /\bwhich option\b/i,
  /\bwhy is this design\b/i
];

async function api(path, { method = "GET", body } = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined
  });
  if (!response.ok) {
    throw new Error(`${method} ${path} failed: ${response.status} ${await response.text()}`);
  }
  return response.json();
}

function compact(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function matchingNote(notes, title) {
  const normalizedTitle = title.toLowerCase();
  return notes.find((note) => String(note.title || "").toLowerCase().includes(normalizedTitle));
}

function assertClean(condition, message, errors) {
  if (!condition) errors.push(message);
}

function sqlite(sql) {
  if (!existsSync(dbPath)) return [];
  const result = spawnSync("sqlite3", ["-json", dbPath, sql], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024
  });
  if (result.status !== 0) {
    throw new Error(result.stderr || "SQLite audit query failed.");
  }
  return JSON.parse(result.stdout || "[]");
}

async function auditNote(note) {
  const errors = [];
  const seenPrompts = new Set();
  const seenQuestionIds = new Set();
  const topicCounts = new Map();
  const officialTopicTargets = officialTopicsByTitle.get(note.title) || [];
  const officialTopics = new Set(officialTopicTargets.map(([title]) => title));
  const provenanceRows = sqlite(`
    SELECT provenance_kind, source_provider, COUNT(*) AS count
    FROM questions
    WHERE note_id = '${String(note.id).replaceAll("'", "''")}'
    GROUP BY provenance_kind, source_provider
    ORDER BY count DESC;
  `);
  const sourceReady = provenanceRows.reduce((sum, row) => {
    const kind = String(row.provenance_kind || "");
    return sum + (kind === "licensed_bank" || kind === "curated_bank" ? Number(row.count || 0) : 0);
  }, 0);

  console.log(`\n== ${note.title} ==`);
  console.log(`${note.questionCount} questions banked, ${note.quizCount} prior quizzes`);
  console.log(`Source-bank questions: ${sourceReady}; provenance ${JSON.stringify(provenanceRows)}`);
  assertClean(sourceReady >= expectedQuizSize * quizRuns, `${note.title} does not have enough source-bank questions for ${quizRuns} fresh quizzes.`, errors);

  for (let run = 1; run <= quizRuns; run += 1) {
    const quiz = await api(`/api/notes/${note.id}/quiz`);
    const questions = quiz.questions || [];
    console.log(`\nQuiz ${run}: ${questions.length} questions`);
    assertClean(
      questions.length === expectedQuizSize,
      `Quiz ${run} served ${questions.length} questions instead of ${expectedQuizSize}.`,
      errors
    );

    const localPrompts = new Set();
    const localAnswers = new Set();
    const localTopicCounts = new Map();
    let scenarioLikeCount = 0;
    const answers = questions.map((question, index) => {
      const prompt = compact(question.prompt);
      const answer = compact(question.answer).toLowerCase();
      const choices = Array.isArray(question.choices) ? question.choices.map(compact).filter(Boolean) : [];
      const assessmentAngle = String(question.assessmentAngle || "").toLowerCase();
      if (scenarioSignals.some((pattern) => pattern.test(prompt))) scenarioLikeCount += 1;
      console.log(`  ${String(index + 1).padStart(2, "0")}. [${question.topic}] ${prompt}`);

      assertClean(!localPrompts.has(prompt), `Quiz ${run} repeated a prompt inside the same quiz: ${prompt}`, errors);
      assertClean(!seenPrompts.has(prompt), `Quiz ${run} repeated a prompt from an earlier quiz: ${prompt}`, errors);
      assertClean(!seenQuestionIds.has(question.id), `Quiz ${run} reused question id ${question.id}.`, errors);
      assertClean(prompt.length >= 32, `Quiz ${run} served a too-short prompt: ${prompt}`, errors);
      assertClean(choices.length === 4, `Quiz ${run} served ${choices.length} choices for: ${prompt}`, errors);
      assertClean(choices.map((choice) => choice.toLowerCase()).includes(answer), `Quiz ${run} answer is not one of the choices: ${prompt}`, errors);
      assertClean(new Set(choices.map((choice) => choice.toLowerCase())).size === choices.length, `Quiz ${run} has duplicate choices: ${prompt}`, errors);
      assertClean(officialTopics.has(question.topic), `Quiz ${run} used non-official topic "${question.topic}".`, errors);
      assertClean(
        question.provenanceKind !== "ai_supplemental",
        `Quiz ${run} served AI-supplemental certification question instead of source-bank question: ${prompt}`,
        errors
      );
      assertClean(
        !ambiguousSingleSelectPatterns.some((pattern) => pattern.test(prompt)),
        `Quiz ${run} used multi-select-sounding wording: ${prompt}`,
        errors
      );
      if (assessmentAngle.includes("trap")) {
        assertClean(
          /\bweakest fit\b|\bdoes not\b|\bnot\b/i.test(prompt),
          `Quiz ${run} trap question is not clearly worded as a weak-option task: ${prompt}`,
          errors
        );
      } else {
        assertClean(
          !/\bweakest fit\b/i.test(prompt),
          `Quiz ${run} non-trap question uses weakest-fit wording: ${prompt}`,
          errors
        );
      }
      if (answer.length > 8) {
        assertClean(!localAnswers.has(answer), `Quiz ${run} repeated answer "${question.answer}" inside the same quiz.`, errors);
      }

      localPrompts.add(prompt);
      localAnswers.add(answer);
      seenPrompts.add(prompt);
      seenQuestionIds.add(question.id);
      localTopicCounts.set(question.topic || "Unknown", (localTopicCounts.get(question.topic || "Unknown") || 0) + 1);
      topicCounts.set(question.topic || "Unknown", (topicCounts.get(question.topic || "Unknown") || 0) + 1);

      return {
        questionId: question.id,
        variantId: question.variantId || "",
        response: question.answer || ""
      };
    });

    for (const [topic, target] of officialTopicTargets) {
      const count = localTopicCounts.get(topic) || 0;
      assertClean(
        Math.abs(count - target) <= 2,
        `Quiz ${run} had ${count} "${topic}" questions; expected about ${target}.`,
        errors
      );
    }
    const minimumScenarioLike = /Cloud Practitioner/i.test(note.title) ? 3 : 7;
    assertClean(
      scenarioLikeCount >= Math.min(questions.length, minimumScenarioLike),
      `Quiz ${run} only had ${scenarioLikeCount} scenario-like questions.`,
      errors
    );

    if (answers.length > 0) {
      const result = await api(`/api/notes/${note.id}/quiz`, {
        method: "POST",
        body: { answers }
      });
      const score = Math.round(Number(result.score || 0) * 100);
      const nextStatus = result.nextQuiz?.status || "missing";
      console.log(`Score ${score}%, next quiz: ${nextStatus}`);
      assertClean(score === 100, `Quiz ${run} all-correct submission scored ${score}%.`, errors);
      assertClean(nextStatus === "ready", `Quiz ${run} did not prepare the next quiz. Status: ${nextStatus}`, errors);
    }
  }

  console.log(`Topics: ${JSON.stringify(Object.fromEntries(topicCounts))}`);
  if (errors.length) {
    throw new Error(`${note.title} audit failed:\n- ${errors.join("\n- ")}`);
  }
}

const { notes } = await api("/api/notes");
const cloudPractitioner = matchingNote(notes, "Cloud Practitioner");
const solutionsArchitect = matchingNote(notes, "Solutions Architect");

if (!cloudPractitioner || !solutionsArchitect) {
  throw new Error("Missing Cloud Practitioner or Solutions Architect certification notes.");
}

await auditNote(cloudPractitioner);
await auditNote(solutionsArchitect);
console.log("\nCertification quiz audit passed.");
