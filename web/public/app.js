const STORAGE_KEY = "accordian.web.state.v1";

function loadStoredState() {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
  } catch {
    return {};
  }
}

const storedState = loadStoredState();

const state = {
  tab: storedState.tab || "learn",
  notes: [],
  activeNoteId: storedState.activeNoteId || null,
  quiz: Array.isArray(storedState.quiz) ? storedState.quiz : [],
  quizNoteId: storedState.quizNoteId || storedState.activeNoteId || null,
  quizStartedAt: Number(storedState.quizStartedAt || 0),
  answers: new Map(Object.entries(storedState.answers || {})),
  index: Number(storedState.index || 0),
  sessions: [],
  selectedSession: null,
  wikiResults: [],
  noteDraft: storedState.noteDraft || { title: "", body: "" },
  editorMode: storedState.editorMode || "edit",
  waitingForNextQuizNoteId: storedState.waitingForNextQuizNoteId || null,
  journeyCompleteNoteId: storedState.journeyCompleteNoteId || null,
  prepState: storedState.prepState || null,
  lastResult: storedState.lastResult || null
};

const $ = (id) => document.getElementById(id);

function saveLocalState() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify({
    tab: state.tab,
    activeNoteId: state.activeNoteId,
    quiz: state.quiz,
    quizNoteId: state.quizNoteId,
    quizStartedAt: state.quizStartedAt,
    answers: Object.fromEntries(state.answers),
    index: state.index,
    noteDraft: state.noteDraft,
    editorMode: state.editorMode,
    waitingForNextQuizNoteId: state.waitingForNextQuizNoteId,
    journeyCompleteNoteId: state.journeyCompleteNoteId,
    prepState: state.prepState,
    lastResult: state.lastResult
  }));
}

function clearStoredQuiz() {
  state.quiz = [];
  state.quizNoteId = null;
  state.quizStartedAt = 0;
  state.answers.clear();
  state.index = 0;
  saveLocalState();
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

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "content-type": "application/json" },
    ...options
  });
  const payload = await response.json();
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

function activeNote() {
  return state.notes.find((note) => note.id === state.activeNoteId) || state.notes[0] || null;
}

function setTab(tab) {
  state.tab = tab;
  document.querySelectorAll(".tab").forEach((button) => {
    button.classList.toggle("active", button.dataset.tab === tab);
  });
  document.querySelectorAll(".view").forEach((view) => {
    view.classList.toggle("active", view.id === `${tab}View`);
  });
  if (tab === "quizzes") loadSessions();
  saveLocalState();
  logAction("ui.tab.selected", { tab });
}

function selectNote(noteId) {
  state.activeNoteId = noteId;
  state.editorMode = "edit";
  if (state.quizNoteId !== noteId) {
    clearStoredQuiz();
  }
  populateNoteEditor();
  render();
  logAction("ui.note.selected", { noteId, objectType: "note", objectId: noteId });
}

function populateNoteEditor() {
  const note = state.editorMode === "new" ? null : activeNote();
  if (!$("noteTitle") || !$("noteBody")) return;
  if (!note) {
    if ($("editorTitle")) $("editorTitle").textContent = "New Note";
    if ($("editorSubtitle")) $("editorSubtitle").textContent = "Paste text. Accordian will prepare a quiz automatically.";
    if ($("deleteNoteButton")) $("deleteNoteButton").hidden = true;
    $("noteTitle").value = state.noteDraft.title || "";
    $("noteBody").value = state.noteDraft.body || "";
    $("saveNoteButton").textContent = "Save Note";
    return;
  }
  if ($("editorTitle")) $("editorTitle").textContent = "Edit Note";
  if ($("editorSubtitle")) $("editorSubtitle").textContent = "Review the source text or delete this note.";
  if ($("deleteNoteButton")) $("deleteNoteButton").hidden = false;
  $("noteTitle").value = note.title || "";
  $("noteBody").value = note.body || "";
  $("saveNoteButton").textContent = "Save as New Note";
}

function clearNoteEditor() {
  state.editorMode = "new";
  state.noteDraft = { title: "", body: "" };
  $("noteTitle").value = "";
  $("noteBody").value = "";
  $("saveNoteButton").textContent = "Save Note";
  saveLocalState();
  render();
}

function renderNoteButtons(containerId) {
  const container = $(containerId);
  if (!container) return;

  if (state.notes.length === 0) {
    container.innerHTML = `<div class="empty">No journeys yet. Add text in Library.</div>`;
    return;
  }

  container.innerHTML = state.notes.map((note) => {
    const isActive = note.id === state.activeNoteId;
    const status = note.queuedQuizCount > 0
      ? "1 quiz ready"
      : note.status === "ready"
      ? `${note.questionCount} checks ready`
      : note.status === "building"
        ? "Reading note"
        : "Ready to build";
    return `
      <div class="note-row ${isActive ? "active" : ""}">
        <button class="note-card" data-note-id="${escapeHTML(note.id)}">
          <strong>${escapeHTML(note.title)}</strong>
          <span>${escapeHTML(status)} · ${percent(note.averageScore)} understood</span>
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
    $("activeTitle").textContent = "Choose a note";
    $("activeSummary").textContent = "Add text in Library. Accordian prepares the next quiz automatically.";
    $("questionCount").textContent = "0 checks ready";
    $("attemptCount").textContent = "0";
    $("understandingScore").textContent = "0%";
    $("understandingBar").style.width = "0%";
    $("startQuizButton").disabled = true;
    $("quizArea").innerHTML = `<div class="empty">Your learning session will appear here.</div>`;
    return;
  }

  $("activeTitle").textContent = note.title;
  $("activeSummary").textContent = note.summary || "Accordian prepares quizzes automatically from this note.";
  $("questionCount").textContent = note.queuedQuizCount > 0
    ? "1 quiz ready"
    : note.status === "building"
      ? "preparing quiz"
      : `${note.questionCount} checks saved`;
  $("attemptCount").textContent = note.attemptCount;
  $("understandingScore").textContent = percent(note.averageScore);
  $("understandingBar").style.width = percent(note.averageScore);

  const journeyComplete = state.journeyCompleteNoteId === note.id;
  const hasReadyQuiz = note.queuedQuizCount > 0;
  $("startQuizButton").disabled = !hasReadyQuiz || state.waitingForNextQuizNoteId === note.id || journeyComplete;
  $("startQuizButton").textContent = journeyComplete
    ? "Journey Complete"
    : !hasReadyQuiz && (note.status === "building" || state.waitingForNextQuizNoteId === note.id)
    ? "Preparing Quiz"
    : "Start Quiz";
}

function renderQuiz() {
  const area = $("quizArea");
  const note = activeNote();
  if (state.quiz.length > 0 && state.quizNoteId && note && state.quizNoteId !== note.id) {
    clearStoredQuiz();
  }
  if (state.quiz.length === 0) {
    if (!note) return;
    if (state.lastResult?.noteId === note.id) {
      renderQuizResult(state.lastResult, { fromCache: true });
      return;
    }
    if (state.journeyCompleteNoteId === note.id) {
      area.innerHTML = `<div class="empty"><strong>Journey complete.</strong><br>Accordian has no fresh quiz set to serve from this note right now. Add more notes or rebuild the journey for harder checks.</div>`;
      return;
    }
    if (note.queuedQuizCount > 0) {
      area.innerHTML = `<div class="empty">A quiz is ready. Start when you are ready.</div>`;
      return;
    }
    if (note.status === "building" || state.waitingForNextQuizNoteId === note.id || state.prepState?.noteId === note.id) {
      const message = state.prepState?.noteId === note.id
        ? state.prepState.message
        : "Accordian is using your last answers to unlock fresh or harder checks.";
      const elapsed = state.prepState?.noteId === note.id ? prepElapsedText() : "";
      area.innerHTML = `
        <div class="empty quiz-prep">
          <div class="spinner" aria-hidden="true"></div>
          <strong>Preparing your next quiz.</strong>
          <span>${escapeHTML(message)}</span>
          ${elapsed ? `<small>${escapeHTML(elapsed)} elapsed. You can review History while this finishes.</small>` : ""}
        </div>
      `;
      return;
    }
    area.innerHTML = note.questionCount > 0
      ? `<div class="empty">Your next quiz is being prepared automatically.</div>`
      : `<div class="empty">Accordian is preparing your first quiz automatically.</div>`;
    return;
  }

  const question = state.quiz[state.index];
  const answeredCount = state.answers.size;
  const selected = state.answers.get(question.id) || "";
  area.innerHTML = `
    <article class="question-card">
      ${state.quizStartedAt ? `<p class="resume-note">Saved in this browser · ${answeredCount}/${state.quiz.length} answered</p>` : ""}
      <div class="question-topline">
        <span>Check ${state.index + 1} of ${state.quiz.length}</span>
        <span>${escapeHTML(question.topic)}</span>
      </div>
      <p class="hierarchy">${escapeHTML(question.subtopic)}</p>
      <h3 class="prompt">${escapeHTML(question.prompt)}</h3>
      <div class="choices">
        ${question.choices.map((choice) => `
          <button class="choice ${choice === selected ? "selected" : ""}" data-choice="${escapeHTML(choice)}">
            ${escapeHTML(choice)}
          </button>
        `).join("")}
      </div>
      <div class="quiz-nav">
        <span class="muted">${selected ? "Answer saved" : "Choose one answer"}</span>
        <button id="nextQuestionButton" ${selected ? "" : "disabled"}>
          ${state.index === state.quiz.length - 1 ? "Grade" : "Next"}
        </button>
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

  $("nextQuestionButton").addEventListener("click", () => {
    if (state.index === state.quiz.length - 1) {
      submitQuiz();
      return;
    }
    state.index += 1;
    saveLocalState();
    renderQuiz();
  });
}

function renderQuizResult(result, options = {}) {
  const note = activeNote();
  const stillPreparing = state.prepState?.noteId === result.noteId ||
    state.waitingForNextQuizNoteId === result.noteId ||
    ((result.nextQuiz?.status === "preparing" || result.nextQuiz?.status === "already_preparing") && note?.id === result.noteId && note.status === "building");
  const nextQuizText = stillPreparing
    ? result.score >= 0.999
      ? "Perfect score. Accordian is unlocking harder checks in the background."
      : "Accordian is preparing fresh follow-up checks in the background."
    : result.nextQuiz?.status === "preparing" || result.nextQuiz?.status === "already_preparing"
      ? "Your next quiz is ready."
      : "Your results were saved for the next quiz.";
  $("quizArea").innerHTML = `
    <article class="result-card">
      <p class="eyebrow">${options.fromCache ? "Last quiz" : "Quiz graded"}</p>
      <h2>${percent(result.score)}</h2>
      <p class="muted">Saved to quiz history. ${escapeHTML(nextQuizText)}</p>
      ${result.learningEvidence?.summary ? `
        <div class="memory-evidence">
          <strong>Memory updated</strong>
          <span>${escapeHTML(result.learningEvidence.summary)}</span>
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
  $("takeAnotherButton").disabled = stillPreparing;
  $("takeAnotherButton").textContent = $("takeAnotherButton").disabled ? "Preparing..." : "Next Quiz";
  $("takeAnotherButton").addEventListener("click", startQuiz);
}

function renderNotes() {
  renderNoteButtons("learnNotesList");
  renderNoteButtons("notesList");
  renderWikiResults();
}

function renderSessions() {
  const list = $("historyList");
  if (state.sessions.length === 0) {
    list.innerHTML = `<div class="empty">No quiz history yet.</div>`;
  } else {
    list.innerHTML = state.sessions.map((session) => `
      <button class="history-row" data-session-id="${escapeHTML(session.id)}">
        <span>
          <strong>${escapeHTML(session.noteTitle)}</strong>
          <small>${escapeHTML(shortDate(session.createdAt))}</small>
        </span>
        <b>${percent(session.score)}</b>
      </button>
    `).join("");
    list.querySelectorAll("[data-session-id]").forEach((button) => {
      button.addEventListener("click", () => loadSessionDetail(button.dataset.sessionId));
    });
  }

  if (!state.selectedSession) {
    $("sessionDetail").innerHTML = `
      <h2>Select a quiz</h2>
      <p class="muted">Tap any quiz to view your answers, correct answers, and feedback.</p>
    `;
  }
}

function renderSessionDetail() {
  const session = state.selectedSession;
  if (!session) {
    renderSessions();
    return;
  }

  $("sessionDetail").innerHTML = `
    <div class="session-heading">
      <div>
        <p class="eyebrow">${escapeHTML(session.noteTitle)}</p>
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
              <dt>Feedback</dt>
              <dd>${escapeHTML(attempt.feedback || "Saved.")}</dd>
            </div>
          </dl>
        </article>
      `).join("")}
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
  if (!state.activeNoteId && state.notes.length > 0) {
    state.activeNoteId = state.notes[0].id;
  }
  if (state.index >= state.quiz.length) {
    state.index = Math.max(0, state.quiz.length - 1);
  }
  renderNotes();
  renderActiveNote();
  renderQuiz();
  renderSessions();
  saveLocalState();
}

async function loadNotes() {
  const payload = await api("/api/notes");
  state.notes = payload.notes || [];
  if (!state.notes.some((note) => note.id === state.activeNoteId)) {
    state.activeNoteId = state.notes[0]?.id || null;
    if (!state.activeNoteId) state.editorMode = "new";
  }
  const waitingNote = state.notes.find((note) => note.id === state.waitingForNextQuizNoteId);
  if (waitingNote && waitingNote.status !== "building") {
    state.waitingForNextQuizNoteId = null;
  }
  const prepNote = state.notes.find((note) => note.id === state.prepState?.noteId);
  if (prepNote && prepNote.status !== "building") {
    state.prepState = null;
  }
  const active = activeNote();
  if (active?.status === "building" && !state.prepState && state.waitingForNextQuizNoteId === active.id) {
    state.prepState = {
      noteId: active.id,
      status: "preparing",
      message: "Accordian is preparing your next quiz.",
      startedAt: Date.now()
    };
  }
  populateNoteEditor();
  render();
}

async function loadSessions() {
  const payload = await api("/api/quizzes");
  state.sessions = payload.sessions || [];
  renderSessions();
}

async function loadSessionDetail(sessionId) {
  const payload = await api(`/api/quiz-sessions/${encodeURIComponent(sessionId)}`);
  state.selectedSession = payload.session;
  renderSessionDetail();
}

async function saveNote(event) {
  event.preventDefault();
  const title = $("noteTitle").value.trim() || "Untitled Note";
  const body = $("noteBody").value.trim();
  if (!body) return;

  const button = event.submitter;
  button.disabled = true;
  button.textContent = "Saving...";
  try {
    const payload = await api("/api/notes", {
      method: "POST",
      body: JSON.stringify({ title, body })
    });
    state.activeNoteId = payload.note.id;
    state.editorMode = "edit";
    setPrepState(payload.note.id, "Accordian is preparing your first quiz.");
    state.noteDraft = { title: "", body: "" };
    $("noteTitle").value = "";
    $("noteBody").value = "";
    await loadNotes();
    setTab("learn");
  } finally {
    button.disabled = false;
    button.textContent = "Save Note";
  }
}

async function deleteNoteById(noteId) {
  const note = state.notes.find((candidate) => candidate.id === noteId);
  if (!note) return;
  const confirmed = window.confirm(`Delete "${note.title}" and its quiz history?`);
  if (!confirmed) return;
  await api(`/api/notes/${encodeURIComponent(noteId)}`, { method: "DELETE" });
  logAction("ui.note.deleted", { noteId, objectType: "note", objectId: noteId });
  if (state.activeNoteId === noteId) {
    clearStoredQuiz();
    state.activeNoteId = null;
    state.editorMode = "new";
    state.lastResult = null;
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
    setPrepState(payload.note.id, "Accordian is preparing your first quiz.");
    state.wikiResults = [];
    $("wikiQuery").value = "";
    await loadNotes();
    setTab("learn");
  } catch (error) {
    $("wikiResults").innerHTML = `<div class="error">${escapeHTML(error.message)}</div>`;
  }
}

async function startQuiz() {
  const note = activeNote();
  if (!note) return;
  logAction("ui.quiz.start_requested", { noteId: note.id, objectType: "note", objectId: note.id });
  $("startQuizButton").disabled = true;
  $("quizArea").innerHTML = `<div class="empty">Preparing quiz...</div>`;
  try {
    const payload = await api(`/api/notes/${encodeURIComponent(note.id)}/quiz`);
    state.quiz = payload.questions || [];
    state.quizNoteId = state.quiz.length > 0 ? note.id : null;
    state.quizStartedAt = state.quiz.length > 0 ? Date.now() : 0;
    state.answers.clear();
    state.index = 0;
    if (state.quiz.length === 0 && (payload.nextQuiz?.status === "preparing" || payload.nextQuiz?.status === "already_preparing")) {
      setPrepState(note.id, "Accordian is unlocking fresh checks from your learning history.");
      state.journeyCompleteNoteId = null;
    } else {
      clearPrepState(note.id);
      state.journeyCompleteNoteId = state.quiz.length === 0 ? note.id : null;
      if (state.quiz.length > 0) state.lastResult = null;
    }
    saveLocalState();
    renderQuiz();
  } finally {
    renderActiveNote();
  }
}

async function submitQuiz() {
  const note = activeNote();
  if (!note) return;
  $("quizArea").innerHTML = `<div class="empty">Grading quiz...</div>`;
  const answers = state.quiz.map((question) => ({
    questionId: question.id,
    variantId: question.variantId || "",
    response: state.answers.get(question.id) || ""
  }));
  const result = await api(`/api/notes/${encodeURIComponent(note.id)}/quiz`, {
    method: "POST",
    body: JSON.stringify({ answers })
  });
  clearStoredQuiz();
  state.lastResult = { ...result, noteId: note.id, savedAt: Date.now() };
  if (result.nextQuiz?.status === "preparing" || result.nextQuiz?.status === "already_preparing") {
    setPrepState(note.id, result.score >= 0.999
      ? "Perfect score. Accordian is unlocking harder checks."
      : "Accordian is preparing follow-up checks from your last answers.");
  } else {
    clearPrepState(note.id);
  }
  saveLocalState();
  await loadNotes();
  await loadSessions();
  renderQuizResult(result);
}

async function checkModel() {
  try {
    const model = await api("/api/model");
    $("modelStatus").textContent = `${model.model} via ${model.mode}`;
  } catch {
    $("modelStatus").textContent = "Model status unavailable";
  }
}

document.querySelectorAll(".tab").forEach((button) => {
  button.addEventListener("click", () => setTab(button.dataset.tab));
});
$("noteForm").addEventListener("submit", saveNote);
$("startQuizButton").addEventListener("click", startQuiz);
$("refreshButton").addEventListener("click", loadNotes);
$("clearNoteButton").addEventListener("click", clearNoteEditor);
$("newNoteTopButton").addEventListener("click", clearNoteEditor);
$("deleteNoteButton").addEventListener("click", deleteActiveNote);
$("noteTitle").addEventListener("input", () => {
  if (state.editorMode !== "new") return;
  state.noteDraft.title = $("noteTitle").value;
  saveLocalState();
});
$("noteBody").addEventListener("input", () => {
  if (state.editorMode !== "new") return;
  state.noteDraft.body = $("noteBody").value;
  saveLocalState();
});
$("wikiSearchButton").addEventListener("click", searchWikipedia);
$("wikiQuery").addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    searchWikipedia();
  }
});

checkModel();
setTab(state.tab);
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
