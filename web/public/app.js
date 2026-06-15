const STORAGE_KEY = "quizloop.web.state.v1";
const URL_PARAMS = new URLSearchParams(window.location.search);
const DEBUG_BANK = URL_PARAMS.get("debug") === "1";

function loadStoredState() {
  try {
    const stored = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
    if (URL_PARAMS.get("resetQuiz") === "1") {
      delete stored.quiz;
      delete stored.quizNoteId;
      delete stored.quizStartedAt;
      delete stored.answers;
      delete stored.index;
      localStorage.setItem(STORAGE_KEY, JSON.stringify(stored));
    }
    return stored;
  } catch {
    return {};
  }
}

const storedState = loadStoredState();

const state = {
  tab: !DEBUG_BANK && storedState.tab === "lab" ? "learn" : storedState.tab || "learn",
  debugBank: DEBUG_BANK,
  theme: storedState.theme || (window.matchMedia?.("(prefers-color-scheme: dark)")?.matches ? "dark" : "light"),
  planMode: storedState.planMode === "adaptive" ? "adaptive" : "free",
  notes: [],
  activeNoteId: storedState.activeNoteId || null,
  quiz: Array.isArray(storedState.quiz) ? storedState.quiz : [],
  quizNoteId: storedState.quizNoteId || storedState.activeNoteId || null,
  quizQueue: storedState.quizQueue || null,
  quizStartedAt: Number(storedState.quizStartedAt || 0),
  quizFocusByNote: storedState.quizFocusByNote || {},
  focusOptionsByNote: {},
  answers: new Map(Object.entries(storedState.answers || {})),
  index: Number(storedState.index || 0),
  sessions: [],
  selectedSession: null,
  wikiResults: [],
  noteDraft: storedState.noteDraft || { title: "", body: "" },
  noteSourceMode: "certs",
  mathTemplateApplied: Boolean(storedState.mathTemplateApplied),
  mathTemplateKey: storedState.mathTemplateKey || "blank",
  bookTemplateApplied: Boolean(storedState.bookTemplateApplied),
  bookTemplateKey: storedState.bookTemplateKey || "blank",
  certTemplateApplied: Boolean(storedState.certTemplateApplied),
  certTemplateKey: storedState.certTemplateKey || "blank",
  editorMode: storedState.editorMode || "edit",
  editingNoteId: storedState.editingNoteId || null,
  libraryMode: storedState.libraryMode || "list",
  historyMode: storedState.historyMode || "list",
  waitingForNextQuizNoteId: storedState.waitingForNextQuizNoteId || null,
  journeyCompleteNoteId: storedState.journeyCompleteNoteId || null,
  prepState: storedState.prepState || null,
  intelligence: storedState.intelligence || null,
  reportsByNote: storedState.reportsByNote || {},
  reportLoadingNoteId: null,
  certReadinessByNote: {},
  labSnapshot: null,
  labLoading: false,
  submittingQuiz: false,
  latestQuizResult: null
};

const $ = (id) => document.getElementById(id);

function saveLocalState() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      tab: state.tab,
      theme: state.theme,
      planMode: state.planMode,
      activeNoteId: state.activeNoteId,
      quiz: state.quiz,
      quizNoteId: state.quizNoteId,
      quizQueue: state.quizQueue,
      quizStartedAt: state.quizStartedAt,
      quizFocusByNote: state.quizFocusByNote,
      answers: Object.fromEntries(state.answers),
      index: state.index,
      noteDraft: state.noteDraft,
      noteSourceMode: state.noteSourceMode,
      mathTemplateApplied: state.mathTemplateApplied,
      mathTemplateKey: state.mathTemplateKey,
      bookTemplateApplied: state.bookTemplateApplied,
      bookTemplateKey: state.bookTemplateKey,
      certTemplateApplied: state.certTemplateApplied,
      certTemplateKey: state.certTemplateKey,
      editorMode: state.editorMode,
      editingNoteId: state.editingNoteId,
      libraryMode: state.libraryMode,
      historyMode: state.historyMode,
      waitingForNextQuizNoteId: state.waitingForNextQuizNoteId,
      journeyCompleteNoteId: state.journeyCompleteNoteId,
      prepState: state.prepState,
      intelligence: state.intelligence,
      reportsByNote: state.reportsByNote
    }));
  } catch {
    // The app should still load and quiz if browser storage is unavailable.
  }
}

function clearStoredQuiz() {
  state.quiz = [];
  state.quizNoteId = null;
  state.quizQueue = null;
  state.quizStartedAt = 0;
  state.answers.clear();
  state.index = 0;
  saveLocalState();
}

function applyTheme(theme = state.theme) {
  const nextTheme = theme === "dark" ? "dark" : "light";
  state.theme = nextTheme;
  document.documentElement.dataset.theme = nextTheme;
  document.body.dataset.theme = nextTheme;
  const label = $("themeToggleLabel");
  const toggle = $("themeToggleButton");
  if (label) label.textContent = nextTheme === "dark" ? "Light" : "Dark";
  if (toggle) {
    toggle.setAttribute("aria-label", nextTheme === "dark" ? "Switch to light mode" : "Switch to dark mode");
  }
  document.querySelector('meta[name="theme-color"]')?.setAttribute(
    "content",
    nextTheme === "dark" ? "#0d1117" : "#f6f7fb"
  );
}

function toggleTheme() {
  applyTheme(state.theme === "dark" ? "light" : "dark");
  saveLocalState();
  logAction("ui.theme.changed", { theme: state.theme });
}

function setPrepState(noteId, message) {
  state.waitingForNextQuizNoteId = noteId;
  state.prepState = {
    noteId,
    status: "preparing",
    message,
    startedAt: Date.now()
  };
  saveLocalState();
}

function clearPrepState(noteId = null) {
  if (!noteId || state.prepState?.noteId === noteId) {
    state.prepState = null;
  }
  if (!noteId || state.waitingForNextQuizNoteId === noteId) {
    state.waitingForNextQuizNoteId = null;
  }
  saveLocalState();
}

function prepElapsedText() {
  const startedAt = Number(state.prepState?.startedAt || 0);
  if (!startedAt) return "";
  const seconds = Math.max(0, Math.round((Date.now() - startedAt) / 1000));
  if (seconds < 60) return `${seconds}s`;
  return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, "0")}s`;
}

function prepProgressPercent(note = activeNote()) {
  const startedAt = Number(state.prepState?.startedAt || 0);
  if (!startedAt) return 8;
  const seconds = Math.max(0, (Date.now() - startedAt) / 1000);
  const expectedSeconds = Number(note?.questionCount || 0) > 0 ? 45 : 75;
  const eased = 1 - Math.exp(-seconds / Math.max(8, expectedSeconds / 3));
  return Math.max(8, Math.min(94, Math.round(8 + eased * 86)));
}

function prepProgressHTML(note = activeNote()) {
  const progress = prepProgressPercent(note);
  return `
    <div class="prep-progress" aria-label="Quiz preparation progress">
      <div>
        <span>${progress}%</span>
        <span>estimated</span>
      </div>
      <div class="prep-progress-track" aria-hidden="true">
        <span style="width: ${progress}%"></span>
      </div>
    </div>
  `;
}

function quizSkeletonHTML(title, detail = "") {
  return `
    <div class="skeleton-card" aria-busy="true">
      <div class="skeleton-header">
        <span class="skeleton-line tiny"></span>
        <span class="skeleton-pill"></span>
      </div>
      <span class="skeleton-line title"></span>
      <span class="skeleton-line wide"></span>
      <div class="skeleton-options">
        <span class="skeleton-option"></span>
        <span class="skeleton-option"></span>
        <span class="skeleton-option"></span>
        <span class="skeleton-option"></span>
      </div>
      <div class="skeleton-footer">
        <strong>${escapeHTML(title)}</strong>
        ${detail ? `<span>${escapeHTML(detail)}</span>` : ""}
      </div>
    </div>
  `;
}

function compactPrepHTML(title, detail = "") {
  return `
    <div class="prep-line" aria-busy="true">
      <span class="status-dot" aria-hidden="true"></span>
      <div>
        <strong>${escapeHTML(title)}</strong>
        ${detail ? `<p>${escapeHTML(detail)}</p>` : ""}
        ${prepProgressHTML()}
      </div>
    </div>
  `;
}

function gradingStateHTML() {
  return `
    <div class="grading-state" aria-busy="true">
      <span class="status-dot" aria-hidden="true"></span>
      <div>
        <strong>Grading quiz</strong>
        <p>Saving your answers and preparing your review.</p>
      </div>
    </div>
  `;
}

function reportHTML(report) {
  if (!report) return "";
  return String(report)
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const clean = line.replace(/^\d+\.\s*/, "").replace(/^[-*]\s*/, "");
      return `<p>${escapeHTML(clean)}</p>`;
    })
    .join("");
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "content-type": "application/json" },
    ...options
  });
  const text = await response.text();
  let payload = {};
  try {
    payload = text ? JSON.parse(text) : {};
  } catch {
    payload = { error: text || "Request failed" };
  }
  if (!response.ok) throw new Error(payload.error || "Request failed");
  return payload;
}

function logAction(actionType, payload = {}) {
  fetch("/api/actions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      noteId: payload.noteId || state.activeNoteId || null,
      actionType,
      objectType: payload.objectType || "",
      objectId: payload.objectId || "",
      payload
    })
  }).catch(() => {});
}

function percent(value) {
  return `${Math.round(Number(value || 0) * 100)}%`;
}

function shortDate(timestamp) {
  if (!timestamp) return "";
  return new Date(timestamp * 1000).toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit"
  });
}

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function evidenceDisplayLabel(value) {
  const text = String(value || "")
    .replace(/[_-]+/g, " ")
    .replace(/\bit\s+enforces\s+/i, "")
    .replace(/\b(every|key|value|request|question|answer)\b/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
  const compact = text.length > 44 ? `${text.slice(0, 41).trim()}...` : text;
  return compact
    .split(" ")
    .filter(Boolean)
    .map((word) => {
      const lower = word.toLowerCase();
      const acronyms = new Set(["aws", "iam", "ec2", "s3", "rds", "vpc", "ebs", "efs", "fsx", "kms", "sns", "sqs", "waf", "az"]);
      if (acronyms.has(lower)) return lower.toUpperCase();
      return lower === "amazon" ? "Amazon" : `${lower.charAt(0).toUpperCase()}${lower.slice(1)}`;
    })
    .join(" ");
}

function evidencePillsHTML(evidence = {}) {
  const missed = [...new Set(evidence.missedConcepts || [])].slice(0, 3);
  const mastered = [...new Set(evidence.masteredConcepts || [])].slice(0, 3);
  const pills = [
    ...missed.map((label) => ({ label: evidenceDisplayLabel(label), type: "missed" })),
    ...mastered.map((label) => ({ label: evidenceDisplayLabel(label), type: "mastered" }))
  ];
  if (pills.length === 0) return "";
  return `
    <div class="evidence-pills">
      <small>Review next</small>
      ${pills.map((pill) => `<span class="${pill.type}">${escapeHTML(pill.label)}</span>`).join("")}
    </div>
  `;
}

function isCertificationNote(note) {
  return note?.sourceType === "certs" || /^##\s*Certification:/i.test(String(note?.body || ""));
}

function certificationDisplayTitle(title) {
  const clean = String(title || "Certification").trim();
  if (/Cloud Practitioner|CLF-C02/i.test(clean)) return "AWS Cloud Practitioner";
  if (/Solutions Architect|SAA-C03/i.test(clean)) return "AWS Solutions Architect Associate";
  if (/Developer|DVA-C02/i.test(clean)) return "AWS Developer Associate";
  if (/SysOps|SOA-C02/i.test(clean)) return "AWS SysOps Administrator";
  if (/Azure Fundamentals|AZ-900/i.test(clean)) return "Azure Fundamentals";
  if (/Azure Administrator|AZ-104/i.test(clean)) return "Azure Administrator";
  if (/Google Associate Cloud Engineer|GCP Associate|ACE/i.test(clean)) return "Google Associate Cloud Engineer";
  if (/Security\+|SY0-701/i.test(clean)) return "CompTIA Security+";
  if (/CCNA/i.test(clean)) return "CCNA";
  if (/Kubernetes|CKA/i.test(clean)) return "Certified Kubernetes Administrator";
  return clean
    .replace(/\s+(Smoke Test|Seed Bank Test\s*\d*|API Test)$/i, "")
    .replace(/\s+Prep$/i, "")
    .replace(/^AWS Certified\s+/i, "AWS ")
    .trim();
}

function certificationCode(title) {
  const clean = String(title || "");
  if (/Solutions Architect|SAA-C03/i.test(clean)) return "SAA-C03";
  if (/Cloud Practitioner|CLF-C02/i.test(clean)) return "CLF-C02";
  if (/Developer/i.test(clean)) return "DVA-C02";
  if (/SysOps/i.test(clean)) return "SOA-C02";
  if (/Azure Fundamentals|AZ-900/i.test(clean)) return "AZ-900";
  if (/Azure Administrator|AZ-104/i.test(clean)) return "AZ-104";
  if (/Security\+/i.test(clean)) return "SY0-701";
  if (/CCNA/i.test(clean)) return "CCNA";
  if (/Kubernetes|CKA/i.test(clean)) return "CKA";
  return "Practice";
}

function questionSourceLabel(question) {
  const provider = String(question?.sourceProvider || "").trim();
  const provenance = String(question?.provenanceKind || "").trim();
  if (/cloudcertprep/i.test(provider)) return "CloudCertPrep";
  if (/quizloop/i.test(provider) || provenance === "curated_bank") return "QuizLoop bank";
  if (provenance === "ai_supplemental") return "AI supplement";
  return provider || provenance || "Saved bank";
}

function certificationNotes() {
  return state.notes.filter(isCertificationNote);
}

function visibleCertificationNotes() {
  const byExam = new Map();
  for (const note of certificationNotes()) {
    const code = certificationCode(note.title);
    const existing = byExam.get(code);
    const noteScore = (note.id === state.activeNoteId ? 1_000_000 : 0)
      + (Number(note.queuedQuizCount || 0) > 0 ? 100_000 : 0)
      + (note.status === "ready" ? 25_000 : 0)
      + Number(note.quizCount || 0) * 10_000
      + Number(note.attemptCount || 0) * 100
      + Number(note.questionCount || 0);
    const existingScore = existing
      ? (existing.id === state.activeNoteId ? 1_000_000 : 0)
        + (Number(existing.queuedQuizCount || 0) > 0 ? 100_000 : 0)
        + (existing.status === "ready" ? 25_000 : 0)
        + Number(existing.quizCount || 0) * 10_000
        + Number(existing.attemptCount || 0) * 100
        + Number(existing.questionCount || 0)
      : -1;
    if (!existing || noteScore > existingScore) {
      byExam.set(code, note);
    }
  }
  return [...byExam.values()];
}

function certReadinessHTML(readiness, note = activeNote()) {
  if (!readiness) return "";
  const domains = [...(readiness.domains || [])].sort((left, right) => Number(left.score || 0) - Number(right.score || 0));
  const weakest = domains[0];
  const attempted = domains.reduce((sum, domain) => sum + Number(domain.attemptedCount || 0), 0);
  const nextAction = Number(note?.queuedQuizCount || 0) > 0
    ? "Quiz ready"
    : note?.status === "building"
      ? "Preparing next quiz"
      : "Ready to train";
  return `
    <div class="readiness-strip">
      <div>
        <span>Next focus</span>
        <strong>${escapeHTML(weakest?.title || "Any domain")}</strong>
      </div>
      <p>${escapeHTML(nextAction)}${attempted > 0 ? ` · ${attempted} checks scored` : ""}</p>
    </div>
  `;
}

function scoreClass(value) {
  const number = Number(value || 0);
  if (number >= 0.85) return "good";
  if (number >= 0.65) return "warn";
  return "bad";
}

function labQueueHTML(queue = []) {
  if (!queue.length) {
    return `<div class="lab-empty">No ready quiz in queue.</div>`;
  }
  const latest = queue[0];
  return `
    <div class="lab-queue-head">
      <span>${escapeHTML(latest.reason || "ready")}</span>
      <b>${latest.questions.length} questions ready</b>
    </div>
    <ol class="lab-question-list">
      ${latest.questions.map((question) => `
        <li>
          <div>
            <strong>${escapeHTML(question.topic)}</strong>
            <span>${escapeHTML(question.subtopic || question.angle || "Question")}</span>
          </div>
          <p>${escapeHTML(question.prompt)}</p>
          <small>Answer: ${escapeHTML(question.answer)} · ${escapeHTML(question.provenanceKind || "unknown")}</small>
        </li>
      `).join("")}
    </ol>
  `;
}

function labExamHTML(exam) {
  const note = exam.note || {};
  const readiness = exam.readiness || {};
  const domains = exam.domainBreakdown || [];
  const sources = exam.sourceBreakdown || [];
  const misses = exam.latestMisses || [];
  const weak = exam.weakQuestions || [];
  const sessions = exam.recentSessions || [];
  return `
    <article class="lab-exam-card">
      <div class="lab-exam-head">
        <div>
          <p class="eyebrow">${escapeHTML(certificationCode(note.title))}</p>
          <h3>${escapeHTML(certificationDisplayTitle(note.title))}</h3>
          <span>${Number(note.questionCount || 0)} viable questions · ${Number(note.quizCount || 0)} quizzes · ${Number(note.attemptCount || 0)} answers</span>
        </div>
        <div class="lab-score ${scoreClass(note.recentScore)}">
          <b>${percent(note.recentScore || note.latestScore || 0)}</b>
          <span>recent</span>
        </div>
      </div>

      <div class="lab-metrics">
        <div><b>${Number(note.queuedQuizCount || 0)}</b><span>ready quiz</span></div>
        <div><b>${percent(readiness.readiness || 0)}</b><span>readiness</span></div>
        <div><b>${Number(sources.reduce((sum, row) => sum + Number(row.count || 0), 0))}</b><span>stored questions</span></div>
      </div>

      <div class="lab-columns">
        <section>
          <h4>Domain bank</h4>
          <div class="lab-domain-list">
            ${domains.map((domain) => `
              <div class="lab-domain-row">
                <span>${escapeHTML(domain.topic)}</span>
                <b>${Number(domain.total || 0)}</b>
                <small>${Number(domain.scenario || 0)} scenario · ${Number(domain.application || 0)} application · ${Number(domain.trap || 0)} trap</small>
              </div>
            `).join("")}
          </div>
        </section>

        <section>
          <h4>Sources</h4>
          <div class="lab-pill-list">
            ${sources.map((source) => `
              <span>${escapeHTML(source.sourceProvider)} <b>${Number(source.count || 0)}</b></span>
            `).join("")}
          </div>
          <h4>Recent scores</h4>
          <div class="lab-score-strip">
            ${sessions.map((session) => `<span class="${scoreClass(session.score)}">${percent(session.score)}</span>`).join("") || "<em>No quizzes yet</em>"}
          </div>
        </section>
      </div>

      <details class="lab-details" open>
        <summary>Ready quiz queue</summary>
        ${labQueueHTML(exam.readyQueue || [])}
      </details>

      <details class="lab-details">
        <summary>Latest misses</summary>
        ${misses.length ? `
          <ol class="lab-question-list compact">
            ${misses.map((miss) => `
              <li>
                <div><strong>${escapeHTML(miss.topic)}</strong><span>${escapeHTML(miss.subtopic)}</span></div>
                <p>${escapeHTML(miss.prompt)}</p>
                <small>You: ${escapeHTML(miss.response)} · Answer: ${escapeHTML(miss.answer)}</small>
              </li>
            `).join("")}
          </ol>
        ` : `<div class="lab-empty">No misses saved yet.</div>`}
      </details>

      <details class="lab-details">
        <summary>Weak questions</summary>
        ${weak.length ? `
          <ol class="lab-question-list compact">
            ${weak.map((item) => `
              <li>
                <div>
                  <strong>${escapeHTML(item.topic)}</strong>
                  <span>${Math.round(Number(item.averageScore || 0) * 100)}% across ${Number(item.attempts || 0)} attempts</span>
                </div>
                <p>${escapeHTML(item.prompt)}</p>
                <small>${escapeHTML(item.subtopic)} · ${escapeHTML(item.sourceProvider || item.provenanceKind)}</small>
              </li>
            `).join("")}
          </ol>
        ` : `<div class="lab-empty">No weak questions below threshold.</div>`}
      </details>
    </article>
  `;
}

function activeNote() {
  const certs = visibleCertificationNotes();
  return certs.find((note) => note.id === state.activeNoteId) || certs[0] || null;
}

function isAdaptivePlan() {
  return state.planMode === "adaptive";
}

function planLabel() {
  return isAdaptivePlan() ? "AI coach" : "Free practice";
}

function reconcileJourneyState() {
  if (!state.journeyCompleteNoteId) return;
  const completedNote = state.notes.find((note) => note.id === state.journeyCompleteNoteId);
  if (!completedNote || completedNote.queuedQuizCount > 0 || completedNote.status === "building") {
    state.journeyCompleteNoteId = null;
  }
}

function setTab(tab) {
  if (tab === "lab" && !state.debugBank) tab = "learn";
  state.tab = tab;
  syncBodyModes();
  document.querySelectorAll(".tab").forEach((button) => {
    button.classList.toggle("active", button.dataset.tab === tab);
  });
  document.querySelectorAll(".view").forEach((view) => {
    view.classList.toggle("active", view.id === `${tab}View`);
  });
  if (tab === "quizzes") loadSessions();
  if (tab === "lab") loadLab();
  saveLocalState();
  logAction("ui.tab.selected", { tab });
}

function syncBodyModes() {
  document.body.classList.toggle("debug-bank", Boolean(state.debugBank));
  document.body.classList.toggle("library-editor", state.tab === "notes" && state.libraryMode === "editor");
  document.body.classList.toggle("note-editor-new", state.tab === "notes" && state.editorMode === "new");
  document.body.classList.toggle("history-detail", state.tab === "quizzes" && state.historyMode === "detail");
}

function selectNote(noteId) {
  if (!noteId) return;
  const isSelected = state.tab === "notes"
    && state.libraryMode === "editor"
    && state.editorMode === "edit"
    && state.editingNoteId === noteId;
  if (isSelected) {
    deselectNote(noteId);
    return;
  }
  state.activeNoteId = noteId;
  state.editorMode = "edit";
  state.editingNoteId = noteId;
  state.libraryMode = "editor";
  if (state.quizNoteId !== noteId) {
    clearStoredQuiz();
  }
  populateNoteEditor();
  render();
  loadFocusOptions(noteId);
  loadCertReadiness(noteId);
  logAction("ui.note.selected", { noteId, objectType: "note", objectId: noteId });
}

function activateJourney(noteId) {
  if (!noteId || activeNote()?.id === noteId) return;
  state.activeNoteId = noteId;
  if (state.quizNoteId !== noteId) {
    clearStoredQuiz();
  }
  render();
  loadFocusOptions(noteId);
  loadCertReadiness(noteId);
  saveLocalState();
  logAction("ui.journey.selected", { noteId, objectType: "note", objectId: noteId });
}

function deselectNote(noteId) {
  state.editorMode = "new";
  state.editingNoteId = null;
  state.libraryMode = "list";
  state.noteDraft = { title: "", body: "" };
  state.noteSourceMode = "certs";
  state.wikiResults = [];
  state.bookTemplateApplied = false;
  state.bookTemplateKey = "blank";
  state.certTemplateApplied = false;
  state.certTemplateKey = "blank";
  populateNoteEditor();
  renderWikiResults();
  renderNotes();
  syncBodyModes();
  saveLocalState();
  logAction("ui.note.deselected", { noteId, objectType: "note", objectId: noteId });
}

function renderJourneySelect() {
  const select = $("journeySelect");
  if (!select) return;
  const certs = visibleCertificationNotes();

  if (certs.length === 0) {
    select.innerHTML = `<option value="">No certifications yet</option>`;
    select.disabled = true;
    return;
  }

  select.disabled = false;
  select.innerHTML = certs.map((note) => {
    const suffix = note.queuedQuizCount > 0 ? "quiz ready" : note.status === "building" ? "preparing" : "saved";
    return `<option value="${escapeHTML(note.id)}">${escapeHTML(certificationCode(note.title))} · ${escapeHTML(suffix)}</option>`;
  }).join("");
  select.value = activeNote()?.id || certs[0]?.id || "";
}

function renderFocusSelect() {
  const wrapper = $("focusSwitcher");
  const select = $("quizFocusSelect");
  const note = activeNote();
  if (!wrapper || !select || !note) return;
  const options = state.focusOptionsByNote[note.id] || [];
  wrapper.hidden = false;
  select.disabled = options.length === 0;
  if (options.length === 0) {
    const label = note.status === "building" || Number(note.questionCount || 0) === 0
      ? "Building focus areas"
      : "Any focus";
    select.innerHTML = `<option value="">${escapeHTML(label)}</option>`;
    state.quizFocusByNote[note.id] = "";
    return;
  }
  select.innerHTML = `<option value="">Any focus</option>` + options.map((option) => {
    const label = option.type === "domain"
      ? option.topic
      : option.type === "topic"
      ? `Topic: ${option.topic}`
      : option.topic === option.subtopic
        ? option.topic
        : `${option.topic}: ${option.subtopic}`;
    return `<option value="${escapeHTML(option.value)}">${escapeHTML(label)}</option>`;
  }).join("");
  const savedFocus = state.quizFocusByNote[note.id] || "";
  if (options.some((option) => option.value === savedFocus)) {
    select.value = savedFocus;
  } else {
    state.quizFocusByNote[note.id] = "";
    select.value = "";
  }
}

function renderPlanSelect() {
  const select = $("planModeSelect");
  if (!select) return;
  select.value = isAdaptivePlan() ? "adaptive" : "free";
}

async function loadFocusOptions(noteId = activeNote()?.id) {
  if (!noteId) return;
  try {
    const payload = await api(`/api/notes/${encodeURIComponent(noteId)}/focus-options`);
    state.focusOptionsByNote[noteId] = payload.options || [];
    renderFocusSelect();
  } catch {
    state.focusOptionsByNote[noteId] = [];
    renderFocusSelect();
  }
}

async function loadCertReadiness(noteId = activeNote()?.id) {
  const note = state.notes.find((candidate) => candidate.id === noteId);
  if (!noteId || !isCertificationNote(note)) return;
  try {
    const payload = await api(`/api/notes/${encodeURIComponent(noteId)}/cert-readiness`);
    state.certReadinessByNote[noteId] = payload.readiness || null;
  } catch {
    state.certReadinessByNote[noteId] = null;
  }
  renderActiveNote();
}

function populateNoteEditor() {
  const note = state.editorMode === "new"
    ? null
    : state.notes.find((candidate) => candidate.id === state.editingNoteId) || activeNote();
  if (!$("noteTitle") || !$("noteBody")) return;
  if (!note) {
    state.noteSourceMode = "certs";
    if ($("editorTitle")) $("editorTitle").textContent = "Add Exam";
    if ($("editorSubtitle")) $("editorSubtitle").textContent = "Choose a ready exam path or paste official objectives.";
    if ($("noteMenu")) $("noteMenu").hidden = true;
    $("noteSummaryBox").hidden = true;
    if ($("sourceChooser")) $("sourceChooser").hidden = true;
    updateSourceModeUI();
    $("noteTitle").value = state.noteDraft.title || "";
    $("noteBody").value = state.noteDraft.body || "";
    $("saveNoteButton").textContent = "Save Exam";
    hideNoteCoach();
    $("clearNoteButton").hidden = true;
    return;
  }
  if ($("editorTitle")) $("editorTitle").textContent = note.title || "Exam";
  if ($("editorSubtitle")) $("editorSubtitle").textContent = "Exam outline";
  state.noteSourceMode = note.sourceType || "certs";
  if ($("noteMenu")) $("noteMenu").hidden = false;
  if ($("sourceChooser")) $("sourceChooser").hidden = true;
  if ($("mathBox")) $("mathBox").hidden = true;
  if ($("bookBox")) $("bookBox").hidden = true;
  if ($("certBox")) $("certBox").hidden = true;
  if ($("manualNoteFields")) $("manualNoteFields").hidden = false;
  if ($("saveNoteButton")) $("saveNoteButton").hidden = false;
  if ($("shapeNoteButton")) $("shapeNoteButton").hidden = false;
  $("noteSummaryBox").hidden = false;
  $("noteSummaryText").textContent = note.summary || (note.status === "building"
    ? "QuizLoop is reading this certification outline now."
    : "No summary yet. Save or rebuild this certification path to generate one.");
  const wikiBox = document.querySelector(".wiki-box");
  if (wikiBox) {
    wikiBox.removeAttribute("open");
    wikiBox.hidden = true;
  }
  $("noteTitle").value = note.title || "";
  $("noteBody").value = note.body || "";
  $("saveNoteButton").textContent = "Save Exam";
  hideNoteCoach();
  $("clearNoteButton").hidden = true;
}

function hideNoteCoach() {
  const box = $("noteCoachBox");
  if (!box) return;
  box.hidden = true;
  box.innerHTML = "";
}

function showNoteCoach(message, feedback = []) {
  const box = $("noteCoachBox");
  if (!box) return;
  const feedbackItems = feedback.length
    ? `<ul>${feedback.map((item) => `<li>${escapeHTML(item)}</li>`).join("")}</ul>`
    : "";
  box.innerHTML = `<strong>${escapeHTML(message)}</strong>${feedbackItems}`;
  box.hidden = false;
}

function clearNoteEditor() {
  state.editorMode = "new";
  state.editingNoteId = null;
  state.libraryMode = "editor";
  state.noteDraft = { title: "", body: "" };
  state.noteSourceMode = "certs";
  state.mathTemplateApplied = false;
  state.mathTemplateKey = "blank";
  state.bookTemplateApplied = false;
  state.bookTemplateKey = "blank";
  state.certTemplateApplied = false;
  state.certTemplateKey = "blank";
  state.wikiResults = [];
  hideNoteCoach();
  populateNoteEditor();
  renderWikiResults();
  renderNotes();
  syncBodyModes();
  saveLocalState();
}

function updateSourceModeUI() {
  const mode = "certs";
  state.noteSourceMode = mode;
  const copy = {
    subtitle: "Choose a certification path or paste exam objectives.",
    title: "Certification path",
    body: "Paste exam objectives, study notes, service notes, or practice explanations."
  };

  if ($("editorSubtitle")) $("editorSubtitle").textContent = copy.subtitle;
  if ($("shapeNoteButton")) {
    const hasGemma = Boolean(state.intelligence?.available);
    $("shapeNoteButton").textContent = hasGemma ? "Improve Outline" : "Clean Outline";
    $("shapeNoteButton").title = hasGemma
      ? "Use Gemma to reshape this certification outline for quizzes."
      : "Gemma is not connected on this hosted domain, so QuizLoop keeps the note structured for source-grounded questions.";
  }
  if ($("noteTitle")) $("noteTitle").placeholder = copy.title;
  if ($("noteBody")) $("noteBody").placeholder = copy.body;
  if ($("sourceChooser")) $("sourceChooser").hidden = true;
  if ($("mathBox")) $("mathBox").hidden = true;
  if ($("bookBox")) $("bookBox").hidden = true;
  if ($("certBox")) $("certBox").hidden = false;
  if ($("manualNoteFields")) $("manualNoteFields").hidden = false;
  if ($("saveNoteButton")) $("saveNoteButton").hidden = false;
  if ($("shapeNoteButton")) $("shapeNoteButton").hidden = false;

  const wikiBox = document.querySelector(".wiki-box");
  if (wikiBox) {
    wikiBox.hidden = true;
    wikiBox.removeAttribute("open");
  }

  document.querySelectorAll("[data-source-mode]").forEach((button) => {
    button.classList.toggle("active", button.dataset.sourceMode === mode);
  });
  syncCertTemplateSelection();
}

function setSourceMode(mode) {
  mode = "certs";
  if (state.noteSourceMode === "math" && mode !== "math") {
    clearMathTemplateIfUnchanged();
  }
  if (state.noteSourceMode === "books" && mode !== "books") {
    clearBookTemplateIfUnchanged();
  }
  if (state.noteSourceMode === "certs" && mode !== "certs") {
    clearCertTemplateIfUnchanged();
  }
  state.noteSourceMode = mode;
  updateSourceModeUI();
  saveLocalState();
}

function mathTemplateTitle() {
  return mathTemplateTitleFor(state.mathTemplateKey || "blank");
}

function mathTemplateBody() {
  return mathTemplateBodyFor(state.mathTemplateKey || "blank");
}

function mathTemplateTitleFor(key) {
  const titles = {
    "clock-hands": "Finding the Angle Between Clock Hands",
    "linear-equations": "Solving Linear Equations",
    quadratics: "Solving Quadratic Equations",
    "percent-change": "Finding Percent Change",
    pythagorean: "Using the Pythagorean Theorem"
  };
  return titles[key] || "Math practice";
}

function mathTemplateBodyFor(key) {
  if (key === "clock-hands") {
    return [
      "## Math Topic: Finding the Angle Between Clock Hands",
      "",
      "### Concept:",
      "",
      "An analog clock is constantly moving.",
      "The minute hand moves faster than the hour hand, so the angle between them changes every minute.",
      "",
      "The goal is to calculate the smallest angle between the two hands at any given time.",
      "",
      "### Rules or formulas:",
      "",
      "The minute hand moves 360 degrees in 60 minutes.",
      "",
      "Minute Angle = 6 x minutes",
      "",
      "The hour hand moves 360 degrees in 12 hours, which is 30 degrees per hour.",
      "It also moves gradually as minutes pass.",
      "",
      "Hour Angle = 30 x hour + 0.5 x minutes",
      "",
      "Angle = absolute value of (Hour Angle - Minute Angle)",
      "",
      "Smallest Angle = min(Angle, 360 - Angle)",
      "",
      "Smallest Angle = min(|(30h + 0.5m) - 6m|, 360 - |(30h + 0.5m) - 6m|)",
      "",
      "### Worked example:",
      "",
      "Find the angle at 3:30.",
      "",
      "Minute hand:",
      "6 x 30 = 180 degrees",
      "",
      "Hour hand:",
      "30 x 3 + 0.5 x 30 = 90 + 15 = 105 degrees",
      "",
      "Difference:",
      "|180 - 105| = 75 degrees",
      "",
      "Final answer:",
      "75 degrees",
      "",
      "### Where I get stuck:",
      "",
      "- Remembering that the hour hand also moves during the hour",
      "- Forgetting to take the smaller angle",
      "- Mixing up which formula belongs to which hand",
      "- Using military time without converting to 12-hour format",
      "",
      "### What I want to practice:",
      "",
      "- Finding angles for random times like 7:45, 9:20, and 11:59",
      "- Writing a function to automate the calculation",
      "- Visualizing why the hour hand moves slowly",
      "- Solving the problem mentally without formulas"
    ].join("\n");
  }

  if (key === "linear-equations") {
    return [
      "## Math Topic: Solving Linear Equations",
      "",
      "### Concept:",
      "",
      "A linear equation has a variable, usually x, raised only to the first power.",
      "The goal is to isolate the variable so the equation tells us the value that makes both sides equal.",
      "",
      "### Rules or formulas:",
      "",
      "Whatever you do to one side of the equation, you must do to the other side.",
      "",
      "Use inverse operations:",
      "- Addition undoes subtraction",
      "- Subtraction undoes addition",
      "- Multiplication undoes division",
      "- Division undoes multiplication",
      "",
      "General goal:",
      "ax + b = c",
      "ax = c - b",
      "x = (c - b) / a",
      "",
      "### Worked example:",
      "",
      "Solve 3x + 5 = 20.",
      "",
      "Subtract 5 from both sides:",
      "3x = 15",
      "",
      "Divide both sides by 3:",
      "x = 5",
      "",
      "Check:",
      "3(5) + 5 = 20",
      "",
      "### Where I get stuck:",
      "",
      "- Forgetting to do the same operation to both sides",
      "- Mixing up inverse operations",
      "- Losing negative signs",
      "- Dividing before moving constants",
      "",
      "### What I want to practice:",
      "",
      "- One-step equations",
      "- Two-step equations like 4x - 7 = 21",
      "- Equations with negatives",
      "- Checking my answer by substituting it back in"
    ].join("\n");
  }

  if (key === "quadratics") {
    return [
      "## Math Topic: Solving Quadratic Equations",
      "",
      "### Concept:",
      "",
      "A quadratic equation has a squared variable, usually x^2.",
      "Quadratics can have two solutions, one solution, or no real solutions.",
      "",
      "### Rules or formulas:",
      "",
      "Standard form:",
      "ax^2 + bx + c = 0",
      "",
      "Factoring method:",
      "Find two numbers that multiply to c and add to b.",
      "",
      "Zero product property:",
      "If (x - r)(x - s) = 0, then x = r or x = s.",
      "",
      "Quadratic formula:",
      "x = (-b +/- sqrt(b^2 - 4ac)) / 2a",
      "",
      "Discriminant:",
      "b^2 - 4ac tells how many real solutions there are.",
      "",
      "### Worked example:",
      "",
      "Solve x^2 - 5x + 6 = 0.",
      "",
      "Factor:",
      "(x - 2)(x - 3) = 0",
      "",
      "Set each factor equal to zero:",
      "x - 2 = 0, so x = 2",
      "x - 3 = 0, so x = 3",
      "",
      "Final answer:",
      "x = 2 or x = 3",
      "",
      "### Where I get stuck:",
      "",
      "- Forgetting to set the equation equal to zero",
      "- Mixing up signs while factoring",
      "- Not knowing when to use the quadratic formula",
      "- Forgetting that there can be two answers",
      "",
      "### What I want to practice:",
      "",
      "- Factoring simple quadratics",
      "- Using the quadratic formula",
      "- Finding the discriminant",
      "- Checking both solutions"
    ].join("\n");
  }

  if (key === "percent-change") {
    return [
      "## Math Topic: Finding Percent Change",
      "",
      "### Concept:",
      "",
      "Percent change measures how much a value increases or decreases compared with the original value.",
      "It is useful for prices, grades, populations, statistics, and sports data.",
      "",
      "### Rules or formulas:",
      "",
      "Change = New Value - Original Value",
      "",
      "Percent Change = (Change / Original Value) x 100",
      "",
      "If the result is positive, it is a percent increase.",
      "If the result is negative, it is a percent decrease.",
      "",
      "### Worked example:",
      "",
      "A price goes from 80 dollars to 100 dollars.",
      "",
      "Change:",
      "100 - 80 = 20",
      "",
      "Percent change:",
      "(20 / 80) x 100 = 25%",
      "",
      "Final answer:",
      "25% increase",
      "",
      "### Where I get stuck:",
      "",
      "- Dividing by the new value instead of the original value",
      "- Forgetting to multiply by 100",
      "- Mixing up increase and decrease",
      "- Ignoring negative signs",
      "",
      "### What I want to practice:",
      "",
      "- Price increases",
      "- Price discounts",
      "- Grade improvements",
      "- Word problems where I must identify the original value"
    ].join("\n");
  }

  if (key === "pythagorean") {
    return [
      "## Math Topic: Using the Pythagorean Theorem",
      "",
      "### Concept:",
      "",
      "The Pythagorean theorem works only for right triangles.",
      "It relates the two legs of the triangle to the hypotenuse.",
      "",
      "### Rules or formulas:",
      "",
      "a^2 + b^2 = c^2",
      "",
      "a and b are the legs.",
      "c is the hypotenuse, which is always across from the right angle.",
      "",
      "To find the hypotenuse:",
      "c = sqrt(a^2 + b^2)",
      "",
      "To find a missing leg:",
      "a = sqrt(c^2 - b^2)",
      "",
      "### Worked example:",
      "",
      "A right triangle has legs 3 and 4. Find the hypotenuse.",
      "",
      "Use the formula:",
      "3^2 + 4^2 = c^2",
      "",
      "Calculate:",
      "9 + 16 = c^2",
      "25 = c^2",
      "c = 5",
      "",
      "Final answer:",
      "5",
      "",
      "### Where I get stuck:",
      "",
      "- Forgetting that c must be the hypotenuse",
      "- Using the formula on triangles that are not right triangles",
      "- Forgetting to take the square root",
      "- Adding when I should subtract to find a missing leg",
      "",
      "### What I want to practice:",
      "",
      "- Finding the hypotenuse",
      "- Finding a missing leg",
      "- Identifying the hypotenuse in diagrams",
      "- Recognizing common triples like 3-4-5 and 5-12-13"
    ].join("\n");
  }

  return [
    "Concept:",
    "",
    "Rules or formulas:",
    "",
    "Worked example:",
    "",
    "Where I get stuck:",
    "",
    "What I want to practice:"
  ].join("\n");
}

function applyMathTemplateByKey(key) {
  const previousTitle = mathTemplateTitle();
  const previousBody = mathTemplateBody();
  const canReplace = state.mathTemplateApplied
    && ($("noteTitle")?.value || "") === previousTitle
    && ($("noteBody")?.value || "") === previousBody;
  state.mathTemplateKey = key;
  applyMathTemplate({ replace: canReplace });
}

function clearMathTemplateIfUnchanged() {
  if (!state.mathTemplateApplied) return;
  if ($("noteTitle")?.value === mathTemplateTitle()) {
    $("noteTitle").value = "";
    state.noteDraft.title = "";
  }
  if ($("noteBody")?.value === mathTemplateBody()) {
    $("noteBody").value = "";
    state.noteDraft.body = "";
  }
  state.mathTemplateApplied = false;
}

function applyMathTemplate({ replace = false } = {}) {
  if ($("noteTitle") && (replace || !$("noteTitle").value.trim())) {
    $("noteTitle").value = mathTemplateTitle();
    state.noteDraft.title = $("noteTitle").value;
  }
  if ($("noteBody") && (replace || !$("noteBody").value.trim())) {
    $("noteBody").value = mathTemplateBody();
    state.noteDraft.body = $("noteBody").value;
  }
  state.mathTemplateApplied = true;
  $("noteBody")?.focus();
  saveLocalState();
}

function bookTemplateTitle() {
  return bookTemplateTitleFor(state.bookTemplateKey || "blank");
}

function bookTemplateBody() {
  return bookTemplateBodyFor(state.bookTemplateKey || "blank");
}

function bookTemplateTitleFor(key) {
  const titles = {
    "whole-book": "Full Book Study",
    chapter: "Book Chapter Notes",
    "character-theme": "Literature Character and Theme Study",
    nonfiction: "Nonfiction Argument Study",
    "primary-source": "Primary Source Reading"
  };
  return titles[key] || "Book notes";
}

function bookTemplateBodyFor(key) {
  if (key === "whole-book") {
    return [
      "## Book Reading: Full Book Study",
      "",
      "### Book:",
      "",
      "### Author:",
      "",
      "### Source text:",
      "",
      "Paste the full book text here. QuizLoop will split it into study sections automatically.",
      "",
      "### Study goal:",
      "",
      "- Understand the main ideas across the full book",
      "- Build chapter-by-chapter recall",
      "- Connect characters, events, claims, evidence, or themes",
      "- Quiz progressively instead of all at once"
    ].join("\n");
  }

  if (key === "chapter") {
    return [
      "## Book Reading: Chapter Notes",
      "",
      "### Book:",
      "",
      "### Chapter or passage:",
      "",
      "### Source text:",
      "",
      "Paste the chapter excerpt or reading notes here.",
      "",
      "### Key events or ideas:",
      "",
      "-",
      "",
      "### Important quotes or evidence:",
      "",
      "-",
      "",
      "### What I want to understand:",
      "",
      "- What happened?",
      "- Why did it matter?",
      "- How does this connect to the larger book?"
    ].join("\n");
  }

  if (key === "character-theme") {
    return [
      "## Book Reading: Character and Theme Study",
      "",
      "### Book:",
      "",
      "### Characters:",
      "",
      "-",
      "",
      "### Themes:",
      "",
      "-",
      "",
      "### Source text:",
      "",
      "Paste the passage or scene here.",
      "",
      "### Evidence:",
      "",
      "- Quote or moment:",
      "- What it reveals:",
      "",
      "### What I want to understand:",
      "",
      "- Character motivation",
      "- Theme development",
      "- Symbolism or conflict"
    ].join("\n");
  }

  if (key === "nonfiction") {
    return [
      "## Book Reading: Nonfiction Argument Study",
      "",
      "### Book or essay:",
      "",
      "### Main claim:",
      "",
      "### Source text:",
      "",
      "Paste the excerpt here.",
      "",
      "### Evidence used by the author:",
      "",
      "-",
      "",
      "### Important terms:",
      "",
      "-",
      "",
      "### What I want to understand:",
      "",
      "- The author's claim",
      "- The evidence supporting it",
      "- Assumptions, counterarguments, and implications"
    ].join("\n");
  }

  if (key === "primary-source") {
    return [
      "## Book Reading: Primary Source Study",
      "",
      "### Source:",
      "",
      "### Historical or cultural context:",
      "",
      "### Source text:",
      "",
      "Paste the primary-source passage here.",
      "",
      "### Key claims or observations:",
      "",
      "-",
      "",
      "### Important vocabulary:",
      "",
      "-",
      "",
      "### What I want to understand:",
      "",
      "- What the source says",
      "- Why it was written",
      "- What evidence it gives about its time period"
    ].join("\n");
  }

  return [
    "## Book Reading:",
    "",
    "### Book or source:",
    "",
    "### Passage or chapter:",
    "",
    "### Source text:",
    "",
    "Paste a focused excerpt here.",
    "",
    "### What I want to understand:",
    "",
    "-"
  ].join("\n");
}

function applyBookTemplateByKey(key) {
  const previousTitle = bookTemplateTitle();
  const previousBody = bookTemplateBody();
  const canReplace = state.bookTemplateApplied
    && ($("noteTitle")?.value || "") === previousTitle
    && ($("noteBody")?.value || "") === previousBody;
  state.bookTemplateKey = key;
  applyBookTemplate({ replace: canReplace });
}

function clearBookTemplateIfUnchanged() {
  if (!state.bookTemplateApplied) return;
  if ($("noteTitle")?.value === bookTemplateTitle()) {
    $("noteTitle").value = "";
    state.noteDraft.title = "";
  }
  if ($("noteBody")?.value === bookTemplateBody()) {
    $("noteBody").value = "";
    state.noteDraft.body = "";
  }
  state.bookTemplateApplied = false;
}

function applyBookTemplate({ replace = false } = {}) {
  if ($("noteTitle") && (replace || !$("noteTitle").value.trim())) {
    $("noteTitle").value = bookTemplateTitle();
    state.noteDraft.title = $("noteTitle").value;
  }
  if ($("noteBody") && (replace || !$("noteBody").value.trim())) {
    $("noteBody").value = bookTemplateBody();
    state.noteDraft.body = $("noteBody").value;
  }
  state.bookTemplateApplied = true;
  $("noteBody")?.focus();
  saveLocalState();
}

function certTemplateTitle() {
  return certTemplateTitleFor(state.certTemplateKey || "blank");
}

function certTemplateBody() {
  return certTemplateBodyFor(state.certTemplateKey || "blank");
}

function certTemplateTitleFor(key) {
  const titles = {
    "aws-cloud-practitioner": "AWS Cloud Practitioner Prep",
    "aws-solutions-architect": "AWS Solutions Architect Associate Prep",
    "aws-developer-associate": "AWS Developer Associate Prep",
    "aws-sysops-admin": "AWS SysOps Administrator Prep",
    "azure-fundamentals": "Azure Fundamentals Prep",
    "azure-administrator": "Azure Administrator Prep",
    "gcp-associate-cloud-engineer": "Google Associate Cloud Engineer Prep",
    "comptia-security-plus": "CompTIA Security+ Prep",
    ccna: "Cisco CCNA Prep",
    cka: "Kubernetes CKA Prep"
  };
  return titles[key] || "Certification prep";
}

function genericCertificationTemplate({ name, exam, domains, practice }) {
  return [
    `## Certification: ${name}`,
    "",
    "### Exam goal:",
    "",
    `Build readiness for ${name}${exam ? ` (${exam})` : ""}.`,
    "",
    "### Domains to master:",
    "",
    ...domains.map((domain) => `- ${domain}`),
    "",
    "### Source material:",
    "",
    "Paste official exam objectives, course notes, service notes, diagrams explained in text, or practice explanations here.",
    "",
    "### High-yield practice:",
    "",
    ...practice.map((item) => `- ${item}`),
    "",
    "### QuizLoop should test:",
    "",
    "- Scenario-based decisions",
    "- Similar concepts that are easy to confuse",
    "- Definitions only when they unlock a practical decision",
    "- Weak areas from previous quiz attempts"
  ].join("\n");
}

function certTemplateBodyFor(key) {
  if (key === "aws-cloud-practitioner") {
    return [
      "## Certification: AWS Certified Cloud Practitioner",
      "",
      "### Exam goal:",
      "",
      "Build readiness for AWS Certified Cloud Practitioner CLF-C02. The real exam has 65 questions total, 50 scored questions, 15 unscored questions, and a 700 passing score.",
      "",
      "### Official domain weights:",
      "",
      "- Domain 1: Cloud Concepts — 24%",
      "- Domain 2: Security and Compliance — 30%",
      "- Domain 3: Cloud Technology and Services — 34%",
      "- Domain 4: Billing, Pricing, and Support — 12%",
      "",
      "### Starter study map:",
      "",
      "Cloud Concepts: AWS helps teams trade upfront capital expense for variable expense, scale elastically, improve agility, and use a global infrastructure of Regions, Availability Zones, and edge locations. Core value propositions include high availability, fault tolerance, elasticity, cost optimization, and operational excellence.",
      "",
      "Security and Compliance: AWS uses the shared responsibility model. AWS is responsible for security of the cloud, including physical facilities and managed infrastructure. Customers are responsible for security in the cloud, including data, identity access, and configuration. IAM controls users, groups, roles, and permissions. MFA strengthens account protection. AWS Artifact provides compliance reports. AWS Shield, AWS WAF, GuardDuty, Inspector, and KMS support security, threat detection, and encryption use cases.",
      "",
      "Cloud Technology and Services: Amazon EC2 provides virtual servers. AWS Lambda runs code without provisioning servers. Elastic Load Balancing distributes traffic. Auto Scaling adjusts capacity. Amazon S3 stores objects. EBS provides block storage for EC2. EFS provides shared file storage. Amazon RDS is managed relational database. DynamoDB is managed NoSQL database. VPC isolates networking resources. Route 53 provides DNS. CloudFront is a CDN. CloudWatch supports monitoring and alarms.",
      "",
      "Billing, Pricing, and Support: AWS Free Tier, On-Demand pricing, Reserved Instances, Savings Plans, and Spot Instances affect cost. AWS Budgets and Cost Explorer help track spend. AWS Pricing Calculator estimates workloads. Trusted Advisor gives recommendations across cost optimization, security, fault tolerance, performance, and service limits. Support plans provide different response times and access levels.",
      "",
      "### Source material:",
      "",
      "Paste your AWS study notes, official exam guide excerpts, service notes, or course transcript here to personalize the question bank further.",
      "",
      "### High-yield areas to practice:",
      "",
      "- Telling similar AWS services apart",
      "- Shared responsibility, IAM, encryption, and compliance tools",
      "- Matching a customer scenario to the correct AWS service",
      "- Pricing, billing, budgets, support plans, and cost tools",
      "- Global infrastructure, deployment benefits, and AWS value proposition",
      "",
      "### QuizLoop should test:",
      "",
      "- Scenario-based service selection",
      "- Service tradeoffs and common exam traps",
      "- Security/compliance responsibility boundaries",
      "- Weighted domain readiness",
      "- Weak areas from previous quiz attempts"
    ].join("\n");
  }

  if (key === "aws-solutions-architect") {
    return [
      "## Certification: AWS Certified Solutions Architect - Associate",
      "",
      "### Exam goal:",
      "",
      "Build readiness for AWS Certified Solutions Architect - Associate SAA-C03. The real exam has 65 questions total, 50 scored questions, 15 unscored questions, and a 720 passing score.",
      "",
      "### Official domain weights:",
      "",
      "- Domain 1: Design Secure Architectures — 30%",
      "- Domain 2: Design Resilient Architectures — 26%",
      "- Domain 3: Design High-Performing Architectures — 24%",
      "- Domain 4: Design Cost-Optimized Architectures — 20%",
      "",
      "### Source material:",
      "",
      "Paste your AWS architecture notes, official exam guide excerpts, whitepaper notes, diagrams explained in text, or course transcript here.",
      "",
      "### Starter study map:",
      "",
      "Design Secure Architectures: Use IAM roles and policies, least privilege, encryption with KMS, secrets management, VPC security controls, private/public subnet boundaries, and logging. Know when to use security groups, network ACLs, IAM roles, bucket policies, and managed encryption.",
      "",
      "Design Resilient Architectures: Use multiple Availability Zones, Elastic Load Balancing, Auto Scaling, decoupling with SQS/SNS, backups, recovery objectives, failover, and managed services. Know how to keep workloads available when components fail.",
      "",
      "Design High-Performing Architectures: Match compute, storage, database, caching, CDN, and messaging services to performance needs. Know read replicas, CloudFront, ElastiCache, Lambda, SQS, and scaling choices.",
      "",
      "Design Cost-Optimized Architectures: Right-size resources, choose purchase options, use storage classes and lifecycle policies, reduce idle capacity, and monitor spending with AWS cost tools.",
      "",
      "### Domains to master:",
      "",
      "- Secure architectures",
      "- Resilient architectures",
      "- High-performing architectures",
      "- Cost-optimized architectures",
      "",
      "### Architecture patterns to practice:",
      "",
      "- VPC, subnet, routing, NAT, security group, and network ACL reasoning",
      "- Load balancing, Auto Scaling, and multi-AZ design",
      "- S3, EBS, EFS, RDS, DynamoDB, and caching tradeoffs",
      "- IAM, encryption, logging, monitoring, and least privilege",
      "- Migration, disaster recovery, and cost optimization scenarios",
      "",
      "### Where I get stuck:",
      "",
      "- Choosing between similar storage/database services",
      "- Understanding network paths and private/public access",
      "- Knowing which design is most cost-effective",
      "- Separating highly available from fault tolerant",
      "",
      "### QuizLoop should test:",
      "",
      "- Scenario-based architecture choices",
      "- Why one AWS service is better than another",
      "- Tradeoff reasoning",
      "- Repeated weak concepts until they are mastered"
    ].join("\n");
  }

  const templates = {
    "aws-developer-associate": {
      name: "AWS Certified Developer - Associate",
      exam: "DVA-C02",
      domains: ["Development with AWS services", "Security", "Deployment", "Troubleshooting and optimization"],
      practice: ["Choosing serverless services for application requirements", "IAM roles, policies, secrets, and encryption choices", "Lambda, API Gateway, DynamoDB, SQS, SNS, EventBridge, and CI/CD scenarios", "Debugging performance, permissions, retries, and observability"]
    },
    "aws-sysops-admin": {
      name: "AWS Certified SysOps Administrator - Associate",
      exam: "SOA-C02",
      domains: ["Monitoring, logging, and remediation", "Reliability and business continuity", "Deployment, provisioning, and automation", "Security and compliance", "Networking and content delivery", "Cost and performance optimization"],
      practice: ["Operational troubleshooting", "CloudWatch, CloudTrail, Systems Manager, Config, and Trusted Advisor", "Backup, scaling, patching, and deployment workflows", "Network paths, DNS, load balancing, and access control"]
    },
    "azure-fundamentals": {
      name: "Microsoft Azure Fundamentals",
      exam: "AZ-900",
      domains: ["Cloud concepts", "Azure architecture and services", "Azure management and governance"],
      practice: ["Cloud benefits and responsibility models", "Compute, networking, storage, identity, and database services", "Cost management, governance, monitoring, and support scenarios"]
    },
    "azure-administrator": {
      name: "Microsoft Azure Administrator",
      exam: "AZ-104",
      domains: ["Manage Azure identities and governance", "Implement and manage storage", "Deploy and manage compute resources", "Implement and manage virtual networking", "Monitor and maintain Azure resources"],
      practice: ["Identity, RBAC, and policy decisions", "Storage account, VM, app service, and networking tasks", "Monitoring, backup, scaling, and troubleshooting scenarios"]
    },
    "gcp-associate-cloud-engineer": {
      name: "Google Cloud Associate Cloud Engineer",
      exam: "ACE",
      domains: ["Planning and configuring cloud solutions", "Deploying and implementing cloud solutions", "Operating and maintaining cloud solutions", "Configuring access and security"],
      practice: ["IAM, projects, billing, networking, compute, storage, and database choices", "CLI and console workflows", "Operational monitoring and troubleshooting"]
    },
    "comptia-security-plus": {
      name: "CompTIA Security+",
      exam: "SY0-701",
      domains: ["General security concepts", "Threats, vulnerabilities, and mitigations", "Security architecture", "Security operations", "Security program management and oversight"],
      practice: ["Threat identification and mitigation choices", "Authentication, authorization, cryptography, network security, and incident response", "Scenario questions that separate similar controls"]
    },
    ccna: {
      name: "Cisco Certified Network Associate",
      exam: "200-301",
      domains: ["Network fundamentals", "Network access", "IP connectivity", "IP services", "Security fundamentals", "Automation and programmability"],
      practice: ["Subnetting, routing, switching, VLANs, ACLs, NAT, DNS, DHCP, and wireless basics", "Troubleshooting network behavior from symptoms", "Configuration and protocol decision questions"]
    },
    cka: {
      name: "Certified Kubernetes Administrator",
      exam: "CKA",
      domains: ["Cluster architecture, installation, and configuration", "Workloads and scheduling", "Services and networking", "Storage", "Troubleshooting"],
      practice: ["kubectl-driven operational scenarios", "Pods, deployments, services, ingress, storage, RBAC, and cluster maintenance", "Troubleshooting based on symptoms and resource state"]
    }
  };

  if (templates[key]) {
    return genericCertificationTemplate(templates[key]);
  }

  return [
    "## Certification:",
    "",
    "### Exam goal:",
    "",
    "### Source material:",
    "",
    "Paste exam objectives, study notes, or course notes here.",
    "",
    "### Domains to master:",
    "",
    "-",
    "",
    "### Where I get stuck:",
    "",
    "-",
    "",
    "### QuizLoop should test:",
    "",
    "- Scenario questions",
    "- Definitions",
    "- Common traps",
    "- Weak areas from previous attempts"
  ].join("\n");
}

function applyCertTemplateByKey(key) {
  const previousTitle = certTemplateTitle();
  const previousBody = certTemplateBody();
  const canReplace = state.certTemplateApplied
    && ($("noteTitle")?.value || "") === previousTitle
    && ($("noteBody")?.value || "") === previousBody;
  state.certTemplateKey = key;
  applyCertTemplate({ replace: canReplace });
}

function clearCertTemplateIfUnchanged() {
  if (!state.certTemplateApplied) return;
  if ($("noteTitle")?.value === certTemplateTitle()) {
    $("noteTitle").value = "";
    state.noteDraft.title = "";
  }
  if ($("noteBody")?.value === certTemplateBody()) {
    $("noteBody").value = "";
    state.noteDraft.body = "";
  }
  state.certTemplateApplied = false;
  syncCertTemplateSelection();
}

function syncCertTemplateSelection() {
  document.querySelectorAll("[data-cert-template]").forEach((button) => {
    button.classList.toggle("active", state.certTemplateApplied && button.dataset.certTemplate === state.certTemplateKey);
  });
}

function applyCertTemplate({ replace = false } = {}) {
  if ($("noteTitle") && (replace || !$("noteTitle").value.trim())) {
    $("noteTitle").value = certTemplateTitle();
    state.noteDraft.title = $("noteTitle").value;
  }
  if ($("noteBody") && (replace || !$("noteBody").value.trim())) {
    $("noteBody").value = certTemplateBody();
    state.noteDraft.body = $("noteBody").value;
  }
  state.certTemplateApplied = true;
  syncCertTemplateSelection();
  $("noteBody")?.focus();
  saveLocalState();
}

function showNotesList() {
  state.libraryMode = "list";
  state.editingNoteId = null;
  syncBodyModes();
  renderNotes();
  saveLocalState();
}

function showHistoryList() {
  state.historyMode = "list";
  state.selectedSession = null;
  renderSessions();
  syncBodyModes();
  saveLocalState();
}

function renderNoteButtons(containerId) {
  const container = $(containerId);
  if (!container) return;
  const certs = visibleCertificationNotes();

  if (certs.length === 0) {
    container.innerHTML = `<div class="empty">No exams yet. Add a certification path to begin training.</div>`;
    return;
  }

  container.innerHTML = certs.map((note) => {
    const isActive = state.editorMode === "edit" && state.libraryMode === "editor" && note.id === state.editingNoteId;
    const statusType = note.queuedQuizCount > 0
      ? "ready"
      : note.status === "building"
        ? "pending"
        : note.status === "error"
          ? "error"
        : note.status === "ready"
          ? "saved"
          : "idle";
    const status = note.queuedQuizCount > 0
      ? "Ready"
      : note.status === "ready"
      ? `${note.questionCount} questions`
      : note.status === "building"
        ? "Building quiz"
        : note.status === "error"
          ? "Needs rebuild"
        : "Saved";
    const answerMeta = note.attemptCount === 1 ? "1 answered" : `${note.attemptCount} answered`;
    const meta = Number(note.attemptCount || 0) > 0 ? answerMeta : "";
    const quizMeta = Number(note.quizCount || 0) === 1 ? "1 quiz taken" : `${Number(note.quizCount || 0)} quizzes taken`;
    const subline = [status, Number(note.quizCount || 0) > 0 ? quizMeta : meta].filter(Boolean).join(" / ");
    const scoreText = Number(note.quizCount || 0) > 0
      ? percent(note.latestScore ?? note.averageScore)
      : `${Number(note.questionCount || 0)}q`;
    return `
      <div class="note-row ${isActive ? "active" : ""}">
        <button class="note-card" data-note-id="${escapeHTML(note.id)}">
          <span class="note-status-dot ${escapeHTML(statusType)}" aria-hidden="true"></span>
          <span class="note-card-copy">
            <strong>${escapeHTML(certificationDisplayTitle(note.title))}</strong>
            <span>${escapeHTML(subline)}</span>
          </span>
          <b class="note-understanding">${escapeHTML(scoreText)}</b>
        </button>
      </div>
    `;
  }).join("");

  container.querySelectorAll("[data-note-id]").forEach((button) => {
    button.addEventListener("click", () => selectNote(button.dataset.noteId));
  });
}

function renderActiveNote() {
  const note = activeNote();
  if (!note) {
    $("activeTitle").textContent = "Choose an exam";
    $("activeSummary").textContent = "Choose an exam and start a focused 10-question practice set.";
    $("questionCount").textContent = "Choose exam";
    $("noteStatusBanner").hidden = true;
    $("attemptCount").textContent = "0";
    $("attemptLabel").textContent = "answered";
    $("understandingScore").textContent = "0%";
    $("scoreLabel").textContent = "last score";
    $("startQuizButton").disabled = false;
    $("startQuizButton").textContent = "Add Exam";
    $("startQuizButton").onclick = () => {
      clearNoteEditor();
      setTab("notes");
    };
    $("startQuizButton").hidden = false;
    $("learnerReportButton").hidden = true;
    $("learnerReportBox").hidden = true;
    $("certReadinessBox").hidden = true;
    $("quizArea").innerHTML = "";
    return;
  }

  $("startQuizButton").onclick = null;
  renderFocusSelect();
  renderPlanSelect();

  $("activeTitle").textContent = certificationDisplayTitle(note.title);
  $("activeSummary").textContent = isAdaptivePlan()
    ? `${certificationCode(note.title)} practice path · AI Coach`
    : `${certificationCode(note.title)} practice path`;
  $("questionCount").textContent = `${Number(note.questionCount || 0)}-question bank`;
  const completedQuizCount = Number(note.quizCount || 0);
  $("attemptCount").textContent = completedQuizCount > 0
    ? completedQuizCount
    : Number(note.questionCount || 0);
  $("attemptLabel").textContent = completedQuizCount > 0
    ? (completedQuizCount === 1 ? "quiz taken" : "quizzes taken")
    : "questions banked";
  $("understandingScore").textContent = Number(note.quizCount || 0) > 0
    ? percent(note.latestScore ?? note.averageScore)
    : `${Number(note.questionCount || 0)}`;
  $("scoreLabel").textContent = Number(note.quizCount || 0) > 0 ? "last score" : "bank size";

  const isPreparingQuiz = note.status === "building" ||
    state.waitingForNextQuizNoteId === note.id ||
    state.prepState?.noteId === note.id;
  const hasRunnableQuiz = note.queuedQuizCount > 0 || (note.questionCount > 0 && !isPreparingQuiz);
  const canRetryBuild = note.status === "error";
  const isReading = !hasRunnableQuiz && (
    note.status === "building" ||
    state.waitingForNextQuizNoteId === note.id ||
    state.prepState?.noteId === note.id
  );
  $("noteStatusBanner").hidden = !isReading;
  if (isReading) {
    const progress = prepProgressPercent(note);
    $("noteStatusTitle").textContent = note.questionCount > 0 ? "Preparing quiz" : "Reading exam";
    $("noteStatusDetail").textContent = note.questionCount > 0
      ? isAdaptivePlan()
        ? `Choosing a fresh set from your history. ${progress}% estimated.`
        : `Shuffling the saved question bank. ${progress}% estimated.`
      : `Preparing the first question bank. ${progress}% estimated.`;
  }

  const journeyComplete = state.journeyCompleteNoteId === note.id;
  const hasReadyQuiz = note.queuedQuizCount > 0 || (note.questionCount > 0 && !isPreparingQuiz);
  const showJourneyComplete = journeyComplete && !hasReadyQuiz && note.status !== "building";
  const showingQuiz = state.quiz.length > 0 && state.quizNoteId === note.id;
  $("startQuizButton").hidden = showingQuiz;
  $("startQuizButton").disabled = isPreparingQuiz || (!hasReadyQuiz && !canRetryBuild) || showJourneyComplete;
  $("startQuizButton").textContent = showJourneyComplete
    ? "Journey Complete"
    : isPreparingQuiz
      ? "Building Quiz"
    : canRetryBuild && !hasReadyQuiz
      ? "Try Again"
    : "Start Quiz";

  const certBox = $("certReadinessBox");
  certBox.hidden = true;
  certBox.innerHTML = "";

  const reportButton = $("learnerReportButton");
  const reportBox = $("learnerReportBox");
  const savedReport = state.reportsByNote[note.id];
  const isReportLoading = state.reportLoadingNoteId === note.id;
  reportButton.hidden = !isAdaptivePlan();
  reportButton.disabled = isReportLoading || Number(note.attemptCount || 0) === 0;
  reportButton.textContent = isReportLoading ? "Writing..." : savedReport ? "Refresh Report" : "Report";
  reportBox.hidden = !isAdaptivePlan() || (!savedReport && !isReportLoading);
  reportBox.innerHTML = isReportLoading
    ? `<div class="grading-state"><span class="status-dot" aria-hidden="true"></span><div><strong>Writing report</strong><p>QuizLoop is turning quiz history into a short progress note.</p></div></div>`
    : savedReport
      ? `<strong>Progress report</strong>${reportHTML(savedReport.report)}`
      : "";
}

function renderQuiz() {
  const area = $("quizArea");
  const note = activeNote();
  if (state.quiz.length > 0 && state.quizNoteId && note && state.quizNoteId !== note.id) {
    clearStoredQuiz();
  }
  const quizInProgress = state.quiz.length > 0;
  const resultInFocus = !quizInProgress && Boolean(state.latestQuizResult?.noteId && note?.id === state.latestQuizResult.noteId);
  document.body.classList.toggle("quiz-active", quizInProgress);
  document.body.classList.toggle("quiz-result-active", resultInFocus);
  if (state.quiz.length === 0) {
    if (resultInFocus) {
      renderQuizResult(state.latestQuizResult);
      return;
    }
    if (!note) return;
    if (state.journeyCompleteNoteId === note.id && note.queuedQuizCount === 0 && note.questionCount === 0 && note.status !== "building") {
      area.innerHTML = `<div class="empty"><strong>Training complete.</strong><br>QuizLoop has no fresh quiz ready for this exam right now.</div>`;
      return;
    }
    if (note.queuedQuizCount > 0 || note.questionCount > 0) {
      area.innerHTML = "";
      return;
    }
    if (note.status === "building" || state.waitingForNextQuizNoteId === note.id || state.prepState?.noteId === note.id) {
      const message = state.prepState?.noteId === note.id
        ? state.prepState.message
        : isAdaptivePlan()
          ? "QuizLoop is choosing from your quiz history."
          : "QuizLoop is shuffling the saved question bank.";
      const elapsed = state.prepState?.noteId === note.id ? prepElapsedText() : "";
      area.innerHTML = compactPrepHTML(
        isAdaptivePlan() ? "Preparing coach quiz" : "Preparing practice quiz",
        elapsed ? `${message} · ${elapsed} elapsed` : message
      );
      return;
    }
    area.innerHTML = note.questionCount > 0
      ? compactPrepHTML(isAdaptivePlan() ? "Preparing coach quiz" : "Preparing practice quiz")
      : compactPrepHTML("Preparing question bank");
    return;
  }

  const question = state.quiz[state.index];
  const selected = state.answers.get(question.id) || "";
  const isTrap = String(question.assessmentAngle || "").toLowerCase().includes("trap");
  area.innerHTML = `
    <article class="question-card">
      <div class="question-topline">
        <span>${state.index + 1} / ${state.quiz.length}</span>
        <span>${escapeHTML(isTrap ? "Find the weak option" : question.topic)}</span>
      </div>
      <div class="question-meta-line">
        <span>${escapeHTML(question.subtopic || "Practice")}</span>
      </div>
      ${isTrap ? `<p class="trap-callout">This is a trap check. Choose the option that does <strong>not</strong> fit the requirement.</p>` : ""}
      <h3 class="prompt">${escapeHTML(question.prompt)}</h3>
      <div class="choices">
        ${question.choices.map((choice) => `
          <button class="choice ${choice === selected ? "selected" : ""}" data-choice="${escapeHTML(choice)}">
            ${escapeHTML(choice)}
          </button>
        `).join("")}
      </div>
      <div class="quiz-nav">
        <span class="muted">${selected
          ? state.index === state.quiz.length - 1
            ? "Grading..."
            : "Answer saved"
          : state.index === state.quiz.length - 1
            ? "Choose one answer to grade"
            : "Choose one answer"}</span>
        <span class="auto-advance-label">${state.index === state.quiz.length - 1 ? "Final check" : "Auto next"}</span>
      </div>
    </article>
  `;

  area.querySelectorAll("[data-choice]").forEach((button) => {
    button.addEventListener("click", () => {
      state.answers.set(question.id, button.dataset.choice);
      saveLocalState();
      logAction("ui.answer.selected", {
        noteId: activeNote()?.id || null,
        objectType: "question",
        objectId: question.id,
        questionId: question.id,
        variantId: question.variantId || "",
        prompt: question.prompt,
        response: button.dataset.choice
      });
      renderQuiz();
      window.setTimeout(() => {
        if (state.index === state.quiz.length - 1) {
          submitQuiz();
          return;
        }
        state.index += 1;
        saveLocalState();
        renderQuiz();
      }, 220);
    });
  });
}

function renderQuizResult(result, options = {}) {
  document.body.classList.add("quiz-result-active");
  document.body.classList.remove("quiz-active");
  const note = activeNote();
  const evidence = result.learningEvidence || {};
  const nextQuizStatus = result.nextQuiz?.status || "";
  const hasQueuedQuizNow = note?.id === result.noteId && Number(note.queuedQuizCount || 0) > 0;
  const stillPreparing = !hasQueuedQuizNow && (
    state.prepState?.noteId === result.noteId ||
    state.waitingForNextQuizNoteId === result.noteId ||
    ((nextQuizStatus === "preparing" || nextQuizStatus === "already_preparing") && note?.id === result.noteId && note.status === "building")
  );
  const nextQuizPreparing = !hasQueuedQuizNow && (stillPreparing || nextQuizStatus === "preparing" || nextQuizStatus === "already_preparing");
  const nextQuizReady = hasQueuedQuizNow || nextQuizStatus === "ready" || nextQuizStatus === "already_ready";
  const nextQuizText = nextQuizPreparing
    ? result.score >= 0.999
      ? isAdaptivePlan()
        ? "Perfect score. The next quiz is moving to harder material."
        : "Perfect score. The next quiz is a fresh random set."
      : isAdaptivePlan()
        ? "The next quiz is being shaped from these answers."
        : "The next quiz is being selected randomly from the bank."
    : nextQuizReady
      ? isAdaptivePlan()
        ? "Progress saved. The next quiz is ready."
        : "Score saved. Another random quiz is ready."
      : "Your results were saved for the next quiz.";
  $("quizArea").innerHTML = `
    <article class="result-card">
      <p class="eyebrow">${options.fromCache ? "Last quiz" : "Quiz complete"}</p>
      <h2>${percent(result.score)}</h2>
      <p class="muted">${escapeHTML(nextQuizText)}</p>
      <div class="next-quiz-status ${nextQuizReady ? "ready" : nextQuizPreparing ? "preparing" : "saved"}">
        <span class="status-dot" aria-hidden="true"></span>
        <div>
        <strong>${nextQuizReady ? "Next quiz ready" : nextQuizPreparing ? "Building next quiz" : "Results saved"}</strong>
          <p>${nextQuizReady
            ? isAdaptivePlan()
              ? "Continue now with different questions from your saved learning memory."
              : "Continue now with a random set from the saved question bank."
            : nextQuizPreparing
              ? isAdaptivePlan()
                ? "QuizLoop is selecting a fresh question set from your memory."
                : "QuizLoop is shuffling the saved question bank."
              : isAdaptivePlan()
                ? "QuizLoop will use this attempt when the next quiz is built."
                : "Your score is saved; free mode does not use AI adaptation."}</p>
        </div>
      </div>
      ${evidence.summary ? `
        <div class="memory-evidence">
          <strong>${escapeHTML(evidence.headline || "Learning memory updated")}</strong>
          <span>${escapeHTML(evidence.summary)}</span>
          ${evidence.nextAction ? `<em>${escapeHTML(evidence.nextAction)}</em>` : ""}
          ${evidencePillsHTML(evidence)}
        </div>
      ` : ""}
      <div class="result-actions">
        <button id="reviewLatestButton">View Results</button>
        <button id="takeAnotherButton" class="secondary">Next Quiz</button>
      </div>
    </article>
  `;

  $("reviewLatestButton").addEventListener("click", async () => {
    setTab("quizzes");
    await loadSessions();
    await loadSessionDetail(result.id);
  });
  $("takeAnotherButton").disabled = nextQuizPreparing;
  $("takeAnotherButton").classList.toggle("secondary", !nextQuizReady);
  $("takeAnotherButton").textContent = $("takeAnotherButton").disabled
    ? "Preparing..."
    : nextQuizReady
      ? "Start Next Quiz"
      : "Next Quiz";
  $("takeAnotherButton").addEventListener("click", startQuiz);
}

function renderNotes() {
  renderJourneySelect();
  renderNoteButtons("notesList");
  renderWikiResults();
}

function renderSessions() {
  const list = $("historyList");
  const certTitles = new Set(certificationNotes().map((note) => note.title));
  const visibleSessions = state.sessions.filter((session) => certTitles.has(session.noteTitle));
  const visibleLimit = 12;
  const recentSessions = visibleSessions.slice(0, visibleLimit);
  if (visibleSessions.length === 0) {
    list.innerHTML = `<div class="empty">No quiz history yet.</div>`;
  } else {
    list.innerHTML = `
      ${recentSessions.map((session) => `
        <button class="history-row" data-session-id="${escapeHTML(session.id)}">
          <span>
            <strong>${escapeHTML(certificationCode(session.noteTitle))} quiz</strong>
            <small>${escapeHTML(shortDate(session.createdAt))} · ${Number(session.attemptCount || 0) || 0} questions</small>
          </span>
          <b>${percent(session.score)}</b>
        </button>
      `).join("")}
      ${visibleSessions.length > visibleLimit ? `<p class="history-limit">Showing latest ${visibleLimit} quizzes.</p>` : ""}
    `;
    list.querySelectorAll("[data-session-id]").forEach((button) => {
      button.addEventListener("click", () => loadSessionDetail(button.dataset.sessionId));
    });
  }

  if (!state.selectedSession) {
    state.historyMode = "list";
    const latestSession = recentSessions[0];
    $("sessionDetail").innerHTML = `
      <div class="history-empty-state">
        <span>Review mode</span>
        <h2>${latestSession ? "Pick a quiz" : "No quizzes yet"}</h2>
        <p class="muted">
          ${latestSession
            ? "Open an attempt to see what you answered, the correct answer, and the feedback QuizLoop saved for your next quiz."
            : "Complete a certification quiz and your answers will appear here as study evidence."}
        </p>
        ${latestSession ? `
          <button type="button" id="openLatestHistoryButton" class="secondary">
            Review latest quiz
          </button>
        ` : ""}
      </div>
    `;
    const openLatestButton = $("openLatestHistoryButton");
    if (openLatestButton && latestSession) {
      openLatestButton.addEventListener("click", () => loadSessionDetail(latestSession.id));
    }
  }
  syncBodyModes();
}

function renderSessionDetail() {
  const session = state.selectedSession;
  if (!session) {
    renderSessions();
    return;
  }

  $("sessionDetail").innerHTML = `
    <button type="button" id="backToHistoryButton" class="back-button">← History</button>
    <div class="session-heading">
      <div>
        <p class="eyebrow">${escapeHTML(certificationCode(session.noteTitle))} quiz</p>
        <h2>${percent(session.score)}</h2>
        <p class="muted">${escapeHTML(shortDate(session.createdAt))}</p>
      </div>
    </div>
    <div class="attempt-list">
      ${session.attempts.map((attempt, index) => `
        <article class="attempt-card ${attempt.score >= 1 ? "correct" : "missed"}">
          <div class="question-topline">
            <span>${index + 1}. ${escapeHTML(attempt.topic)}</span>
            <span>${attempt.score >= 1 ? "Correct" : "Review"}</span>
          </div>
          <p class="hierarchy">${escapeHTML(attempt.subtopic)}</p>
          <h3>${escapeHTML(attempt.prompt)}</h3>
          <dl>
            <div>
              <dt>You</dt>
              <dd>${escapeHTML(attempt.response || "No answer")}</dd>
            </div>
            <div>
              <dt>Answer</dt>
              <dd>${escapeHTML(attempt.answer)}</dd>
            </div>
            <div>
              <dt>Why this matters</dt>
              <dd>${escapeHTML(attempt.feedback || "Saved.")}</dd>
            </div>
          </dl>
        </article>
      `).join("")}
    </div>
  `;
  $("backToHistoryButton").addEventListener("click", showHistoryList);
}

function renderLab() {
  const container = $("labContent");
  if (!container) return;
  if (state.labLoading) {
    container.innerHTML = `
      <div class="grading-state" aria-busy="true">
        <span class="status-dot" aria-hidden="true"></span>
        <div>
          <strong>Reading SQLite memory</strong>
          <p>Loading question banks, queue state, misses, and recent quizzes.</p>
        </div>
      </div>
    `;
    return;
  }
  const lab = state.labSnapshot;
  if (!lab) {
    container.innerHTML = `<div class="empty">Refresh to inspect quiz memory.</div>`;
    return;
  }
  container.innerHTML = `
    <div class="lab-meta">
      <span>Generated ${escapeHTML(new Date(lab.generatedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }))}</span>
      <span>${escapeHTML(lab.database || "SQLite")}</span>
    </div>
    <div class="lab-exams">
      ${(lab.exams || []).map(labExamHTML).join("") || `<div class="empty">No certification exams found.</div>`}
    </div>
  `;
}

function renderWikiResults() {
  const container = $("wikiResults");
  if (!container) return;

  if (state.wikiResults.length === 0) {
    container.innerHTML = "";
    return;
  }

  container.innerHTML = state.wikiResults.map((result) => `
    <article class="wiki-result">
      <div>
        <h3>${escapeHTML(result.title)}</h3>
        <p>${escapeHTML(result.snippet || "Wikipedia article")}</p>
      </div>
      <button type="button" data-wiki-title="${escapeHTML(result.title)}">Import</button>
    </article>
  `).join("");

  container.querySelectorAll("[data-wiki-title]").forEach((button) => {
    button.addEventListener("click", () => importWikipedia(button.dataset.wikiTitle));
  });
}

function render() {
  const certs = visibleCertificationNotes();
  if ((!state.activeNoteId || !certs.some((note) => note.id === state.activeNoteId)) && certs.length > 0) {
    state.activeNoteId = certs[0].id;
  }
  if (state.index >= state.quiz.length) {
    state.index = Math.max(0, state.quiz.length - 1);
  }
  renderNotes();
  renderPlanSelect();
  renderActiveNote();
  renderQuiz();
  renderSessions();
  renderLab();
  syncBodyModes();
  saveLocalState();
}

async function loadNotes() {
  const payload = await api("/api/notes");
  state.notes = payload.notes || [];
  const certs = visibleCertificationNotes();
  reconcileJourneyState();
  if (state.editingNoteId && !state.notes.some((note) => note.id === state.editingNoteId)) {
    state.editingNoteId = null;
    state.editorMode = "new";
  }
  if (!certs.some((note) => note.id === state.activeNoteId)) {
    state.activeNoteId = certs[0]?.id || null;
    if (!state.activeNoteId) {
      state.editorMode = "new";
      state.editingNoteId = null;
    }
    if (!state.activeNoteId) state.libraryMode = "editor";
  }
  const waitingNote = state.notes.find((note) => note.id === state.waitingForNextQuizNoteId);
  if (state.waitingForNextQuizNoteId && (!waitingNote || waitingNote.status !== "building" || waitingNote.queuedQuizCount > 0)) {
    state.waitingForNextQuizNoteId = null;
  }
  const prepNote = state.notes.find((note) => note.id === state.prepState?.noteId);
  if (state.prepState && (!prepNote || prepNote.status !== "building" || prepNote.queuedQuizCount > 0)) {
    state.prepState = null;
  }
  const active = activeNote();
  if (active?.status === "building" && !state.prepState && state.waitingForNextQuizNoteId === active.id) {
    state.prepState = {
      noteId: active.id,
      status: "preparing",
      message: "QuizLoop is preparing your next quiz.",
      startedAt: Date.now()
    };
  }
  populateNoteEditor();
  render();
  loadFocusOptions(activeNote()?.id);
  loadCertReadiness(activeNote()?.id);
}

async function loadHealth() {
  try {
    const payload = await api("/api/health");
    state.intelligence = payload.intelligence || null;
    saveLocalState();
    updateSourceModeUI();
    renderActiveNote();
  } catch {
    state.intelligence = null;
  }
}

async function loadSessions() {
  const payload = await api("/api/quizzes");
  state.sessions = payload.sessions || [];
  renderSessions();
}

async function loadLab() {
  state.labLoading = true;
  renderLab();
  try {
    const payload = await api("/api/lab");
    state.labSnapshot = payload.lab || null;
  } finally {
    state.labLoading = false;
    renderLab();
  }
}

async function loadSessionDetail(sessionId) {
  const payload = await api(`/api/quiz-sessions/${encodeURIComponent(sessionId)}`);
  state.selectedSession = payload.session;
  state.historyMode = "detail";
  renderSessionDetail();
  syncBodyModes();
  saveLocalState();
  $("sessionDetail")?.scrollIntoView({ behavior: "smooth", block: "start" });
}

async function saveNote(event) {
  event.preventDefault();
  if (state.editorMode === "new" && state.noteSourceMode === "wikipedia") return;
  const title = $("noteTitle").value.trim() || "Untitled Note";
  const body = $("noteBody").value.trim();
  if (!body) return;

  const button = event.submitter;
  button.disabled = true;
  button.textContent = "Saving...";
  try {
    const existingNote = state.editorMode === "new"
      ? null
      : state.notes.find((candidate) => candidate.id === state.editingNoteId) || activeNote();
    const path = existingNote ? `/api/notes/${encodeURIComponent(existingNote.id)}` : "/api/notes";
    const payload = await api(path, {
      method: existingNote ? "PUT" : "POST",
      body: JSON.stringify({ title, body, sourceType: state.noteSourceMode })
    });
    state.activeNoteId = payload.note.id;
    state.editorMode = "edit";
    state.editingNoteId = payload.note.id;
    setPrepState(payload.note.id, existingNote
      ? "QuizLoop is rebuilding this certification path."
      : "QuizLoop is preparing your first quiz.");
    state.noteDraft = { title: "", body: "" };
    $("noteTitle").value = "";
    $("noteBody").value = "";
    await loadNotes();
    setTab("learn");
  } finally {
    button.disabled = false;
    button.textContent = "Save Exam";
  }
}

async function shapeNote() {
  if (state.noteSourceMode === "wikipedia") return;
  const title = $("noteTitle").value.trim() || "Untitled Note";
  const body = $("noteBody").value.trim();
  if (!body) {
    showNoteCoach("Paste text first.");
    return;
  }

  const button = $("shapeNoteButton");
  button.disabled = true;
  button.textContent = state.intelligence?.available ? "Shaping..." : "Organizing...";
  showNoteCoach(state.intelligence?.available ? "Gemma is shaping this certification outline for quizzes." : "Organizing this certification outline for source-grounded quizzes.");
  try {
    const payload = await api("/api/notes/shape", {
      method: "POST",
      body: JSON.stringify({ title, body, sourceType: state.noteSourceMode })
    });
    const shaped = payload.note || {};
    $("noteTitle").value = shaped.title || title;
    $("noteBody").value = shaped.body || body;
    if (state.editorMode === "new") {
      state.noteDraft.title = $("noteTitle").value;
      state.noteDraft.body = $("noteBody").value;
    }
    state.mathTemplateApplied = false;
    state.bookTemplateApplied = false;
    showNoteCoach("Ready to save.", shaped.feedback || []);
    saveLocalState();
    logAction("ui.note.shaped", {
      objectType: "note_draft",
      objectId: state.editingNoteId || "new",
      sourceType: state.noteSourceMode,
      bodyLength: $("noteBody").value.length
    });
  } catch (error) {
    showNoteCoach(error.message || "This note could not be organized yet.");
  } finally {
    button.disabled = false;
    button.textContent = state.intelligence?.available ? "Improve Outline" : "Clean Outline";
  }
}

async function deleteNoteById(noteId) {
  const note = state.notes.find((candidate) => candidate.id === noteId);
  if (!note) return;
  const confirmed = window.confirm(`Delete "${note.title}" and its quiz history?`);
  if (!confirmed) return;
  await api(`/api/notes/${encodeURIComponent(noteId)}`, { method: "DELETE" });
  $("noteMenu")?.removeAttribute("open");
  logAction("ui.note.deleted", { noteId, objectType: "note", objectId: noteId });
  if (state.activeNoteId === noteId) {
    clearStoredQuiz();
    state.activeNoteId = null;
    state.editorMode = "new";
    state.editingNoteId = null;
    state.journeyCompleteNoteId = null;
  }
  await loadNotes();
}

async function deleteActiveNote() {
  const note = activeNote();
  if (!note || state.editorMode === "new") return;
  await deleteNoteById(note.id);
}

async function searchWikipedia() {
  const query = $("wikiQuery").value.trim();
  if (query.length < 2) return;

  $("wikiSearchButton").disabled = true;
  $("wikiSearchButton").textContent = "Searching...";
  $("wikiResults").innerHTML = `<div class="empty">Searching Wikipedia...</div>`;
  try {
    const payload = await api(`/api/wiki/search?q=${encodeURIComponent(query)}`);
    state.wikiResults = payload.results || [];
    if (state.wikiResults.length === 0) {
      $("wikiResults").innerHTML = `<div class="empty">No articles found.</div>`;
    } else {
      renderWikiResults();
    }
  } catch (error) {
    $("wikiResults").innerHTML = `<div class="error">${escapeHTML(error.message)}</div>`;
  } finally {
    $("wikiSearchButton").disabled = false;
    $("wikiSearchButton").textContent = "Search";
  }
}

async function importWikipedia(title) {
  $("wikiResults").innerHTML = `<div class="empty">Importing ${escapeHTML(title)}...</div>`;
  try {
    const payload = await api("/api/wiki/import", {
      method: "POST",
      body: JSON.stringify({ title })
    });
    state.activeNoteId = payload.note.id;
    state.editorMode = "edit";
    state.editingNoteId = payload.note.id;
    setPrepState(payload.note.id, "QuizLoop is preparing your first quiz.");
    state.wikiResults = [];
    $("wikiQuery").value = "";
    await loadNotes();
    setTab("learn");
  } catch (error) {
    $("wikiResults").innerHTML = `<div class="error">${escapeHTML(error.message)}</div>`;
  }
}

async function exportBackup() {
  const button = $("exportBackupButton");
  button.disabled = true;
  button.textContent = "Exporting...";
  try {
    const response = await fetch("/api/backup");
    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: "Export failed." }));
      throw new Error(error.error || "Export failed.");
    }
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    const stamp = new Date().toISOString().slice(0, 10);
    link.href = url;
    link.download = `quizloop-backup-${stamp}.sqlite`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  } catch (error) {
    alert(error.message || "Export failed.");
  } finally {
    button.disabled = false;
    button.textContent = "Export";
  }
}

async function restoreBackup(file) {
  if (!file) return;
  const confirmed = window.confirm("Restore this backup? It will replace the current learning memory on this device.");
  if (!confirmed) {
    $("backupFileInput").value = "";
    return;
  }

  const button = $("importBackupButton");
  button.disabled = true;
  button.textContent = "Importing...";
  try {
    const response = await fetch("/api/backup/restore", {
      method: "POST",
      headers: { "content-type": "application/octet-stream" },
      body: file
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload.error || "Import failed.");
    clearStoredQuiz();
    state.notes = payload.notes || [];
    state.activeNoteId = state.notes[0]?.id || null;
    state.editorMode = "new";
    state.editingNoteId = null;
    state.libraryMode = "list";
    await loadNotes();
    await loadSessions();
    render();
  } catch (error) {
    alert(error.message || "Import failed.");
  } finally {
    button.disabled = false;
    button.textContent = "Import";
    $("backupFileInput").value = "";
  }
}

async function startQuiz() {
  const note = activeNote();
  if (!note) return;
  const focus = state.quizFocusByNote[note.id] || "";
  logAction("ui.quiz.start_requested", { noteId: note.id, objectType: "note", objectId: note.id, focus, plan: state.planMode });
  state.latestQuizResult = null;
  document.body.classList.remove("quiz-result-active");
  $("startQuizButton").disabled = true;
  $("startQuizButton").hidden = false;
  $("quizArea").innerHTML = quizSkeletonHTML("Opening quiz");
  try {
    const query = new URLSearchParams({ plan: state.planMode });
    if (focus) query.set("focus", focus);
    const payload = await api(`/api/notes/${encodeURIComponent(note.id)}/quiz?${query.toString()}`);
    state.quiz = payload.questions || [];
    state.quizNoteId = state.quiz.length > 0 ? note.id : null;
    state.quizQueue = state.quiz.length > 0 ? payload.queue || null : null;
    state.quizStartedAt = state.quiz.length > 0 ? Date.now() : 0;
    state.answers.clear();
    state.index = 0;
    if (state.quiz.length === 0 && (payload.nextQuiz?.status === "preparing" || payload.nextQuiz?.status === "already_preparing")) {
      setPrepState(note.id, isAdaptivePlan()
        ? "QuizLoop is unlocking fresh questions from your learning history."
        : "QuizLoop is shuffling the question bank.");
      state.journeyCompleteNoteId = null;
    } else {
      clearPrepState(note.id);
      state.journeyCompleteNoteId = state.quiz.length === 0 ? note.id : null;
    }
    saveLocalState();
    renderQuiz();
  } finally {
    renderActiveNote();
  }
}

async function submitQuiz() {
  if (state.submittingQuiz) return;
  const note = activeNote();
  if (!note) return;
  state.submittingQuiz = true;
  $("quizArea").innerHTML = gradingStateHTML();
  const answers = state.quiz.map((question) => ({
    questionId: question.id,
    variantId: question.variantId || "",
    response: state.answers.get(question.id) || ""
  }));
  try {
    const result = await api(`/api/notes/${encodeURIComponent(note.id)}/quiz`, {
      method: "POST",
      body: JSON.stringify({ answers, plan: state.planMode })
    });
    state.latestQuizResult = result;
    clearStoredQuiz();
    if (result.nextQuiz?.status === "preparing" || result.nextQuiz?.status === "already_preparing") {
      setPrepState(note.id, result.score >= 0.999
        ? isAdaptivePlan()
          ? "Perfect score. QuizLoop is unlocking harder questions."
          : "Perfect score. QuizLoop is shuffling another random quiz."
        : isAdaptivePlan()
          ? "QuizLoop is preparing follow-up questions from your last answers."
          : "QuizLoop is shuffling another random quiz.");
    } else {
      clearPrepState(note.id);
    }
    saveLocalState();
    await loadNotes();
    await loadSessions();
    renderActiveNote();
    renderQuizResult(result);
  } finally {
    state.submittingQuiz = false;
  }
}

async function generateLearnerReport() {
  const note = activeNote();
  if (!note || Number(note.attemptCount || 0) === 0) return;
  state.reportLoadingNoteId = note.id;
  renderActiveNote();
  logAction("ui.learner_report.requested", { noteId: note.id, objectType: "note", objectId: note.id });
  try {
    const payload = await api(`/api/notes/${encodeURIComponent(note.id)}/learner-report`, {
      method: "POST",
      body: JSON.stringify({})
    });
    state.reportsByNote[note.id] = {
      report: payload.report || "",
      model: payload.model || "",
      createdAt: Date.now()
    };
    saveLocalState();
  } catch (error) {
    state.reportsByNote[note.id] = {
      report: `Report could not be generated yet. ${error.message || "Check the local model connection."}`,
      model: "",
      createdAt: Date.now()
    };
  } finally {
    state.reportLoadingNoteId = null;
    renderActiveNote();
  }
}

document.querySelectorAll(".tab").forEach((button) => {
  button.addEventListener("click", () => {
    if (button.dataset.tab === "notes") state.libraryMode = "list";
    if (button.dataset.tab === "quizzes") state.historyMode = "list";
    setTab(button.dataset.tab);
  });
});
$("journeySelect")?.addEventListener("change", (event) => activateJourney(event.target.value));
$("journeySelect")?.addEventListener("input", (event) => activateJourney(event.target.value));
$("planModeSelect")?.addEventListener("change", (event) => {
  state.planMode = event.target.value === "adaptive" ? "adaptive" : "free";
  clearStoredQuiz();
  render();
  logAction("ui.plan_mode.changed", {
    plan: state.planMode,
    objectType: "practice_mode",
    objectId: state.planMode
  });
});
$("quizFocusSelect")?.addEventListener("change", (event) => {
  const note = activeNote();
  if (!note) return;
  state.quizFocusByNote[note.id] = event.target.value;
  saveLocalState();
  logAction("ui.quiz.focus_selected", {
    noteId: note.id,
    objectType: "note",
    objectId: note.id,
    focus: event.target.value || "any"
  });
});
$("noteForm").addEventListener("submit", saveNote);
$("shapeNoteButton")?.addEventListener("click", shapeNote);
$("startQuizButton").addEventListener("click", startQuiz);
$("learnerReportButton")?.addEventListener("click", generateLearnerReport);
$("themeToggleButton")?.addEventListener("click", toggleTheme);
$("refreshLabButton")?.addEventListener("click", loadLab);
$("refreshButton")?.addEventListener("click", loadNotes);
$("clearNoteButton").addEventListener("click", clearNoteEditor);
$("newNoteTopButton").addEventListener("click", clearNoteEditor);
$("backToNotesButton").addEventListener("click", showNotesList);
$("deleteNoteButton").addEventListener("click", deleteActiveNote);
document.querySelectorAll("[data-source-mode]").forEach((button) => {
  button.addEventListener("click", () => setSourceMode(button.dataset.sourceMode));
});
document.querySelectorAll("[data-math-template]").forEach((button) => {
  button.addEventListener("click", () => applyMathTemplateByKey(button.dataset.mathTemplate));
});
document.querySelectorAll("[data-book-template]").forEach((button) => {
  button.addEventListener("click", () => applyBookTemplateByKey(button.dataset.bookTemplate));
});
document.querySelectorAll("[data-cert-template]").forEach((button) => {
  button.addEventListener("click", () => applyCertTemplateByKey(button.dataset.certTemplate));
});
$("noteTitle").addEventListener("input", () => {
  if (state.editorMode !== "new") return;
  if ($("noteTitle").value !== mathTemplateTitle()) state.mathTemplateApplied = false;
  if ($("noteTitle").value !== bookTemplateTitle()) state.bookTemplateApplied = false;
  if ($("noteTitle").value !== certTemplateTitle()) state.certTemplateApplied = false;
  state.noteDraft.title = $("noteTitle").value;
  saveLocalState();
});
$("noteBody").addEventListener("input", () => {
  if (state.editorMode !== "new") return;
  if ($("noteBody").value !== mathTemplateBody()) state.mathTemplateApplied = false;
  if ($("noteBody").value !== bookTemplateBody()) state.bookTemplateApplied = false;
  if ($("noteBody").value !== certTemplateBody()) state.certTemplateApplied = false;
  state.noteDraft.body = $("noteBody").value;
  saveLocalState();
});
$("wikiSearchButton")?.addEventListener("click", searchWikipedia);
$("wikiQuery")?.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    searchWikipedia();
  }
});
$("exportBackupButton")?.addEventListener("click", exportBackup);
$("importBackupButton")?.addEventListener("click", () => $("backupFileInput")?.click());
$("backupFileInput")?.addEventListener("change", (event) => restoreBackup(event.target.files?.[0]));

applyTheme(state.theme);
setTab(state.tab);
loadHealth();
loadNotes();
loadSessions();
window.setInterval(() => {
  if (state.waitingForNextQuizNoteId || state.prepState) loadNotes();
}, 3000);

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service-worker.js").catch(() => {});
  });
}
