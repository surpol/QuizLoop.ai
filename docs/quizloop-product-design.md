# QuizLoop.ai Product Design

## Product In One Sentence

QuizLoop.ai is a simple certification practice app: pick an exam, take short quizzes, review mistakes, and keep looping until the score improves.

## The Product We Are Building

QuizLoop should not feel like a research demo, chatbot, dashboard, or generic study app.

It should feel like a focused exam-prep tool for people who want to pass a certification and do not want to design their own study system.

The first product wedge is:

- AWS Certified Cloud Practitioner
- AWS Certified Solutions Architect Associate

The app can support more certifications later, but every design decision should first make these two exam paths feel trustworthy and easy.

## Core User

The first user is a certification learner who:

- wants a better alternative to static practice tests
- is willing to pay if the product clearly improves readiness
- wants immediate practice, not setup
- does not want to prompt an AI chatbot
- wants to know what they missed and what to practice next

This user does not care about our architecture until the product feels useful.

## Core Promise

Free mode:

- Practice with a large question bank.
- Questions appear in random order.
- Scores and history are saved.
- No AI is required.
- No adaptive claims are made.

Paid mode:

- AI Coach uses quiz history to adapt future quizzes.
- Missed concepts come back.
- Strong concepts appear less often.
- Reports explain weak areas and next steps.
- The app can generate remediation from saved context.

The free product should be useful by itself. The paid product should feel obviously smarter.

## Product Loop

The core loop is:

1. Choose an exam.
2. Start quiz.
3. Answer 10 questions.
4. See score.
5. Review every missed question.
6. Start another quiz.

That is the product.

Everything else is secondary.

## What The App Should Look Like

The app should be minimal, calm, and exam-focused.

Visual direction:

- clean dark and light modes
- one main content column on mobile
- no nested boxes unless they separate a real task
- large readable question text
- clear answer buttons
- plain labels
- no technical language in the learner view
- no dashboard clutter

The product should feel closer to a polished practice-test app than an AI experiment.

## Navigation

The app needs three main tabs:

- `Train`
- `Exams`
- `History`

Optional debug views must be hidden behind a debug flag.

### Train

Purpose:

Help the learner take the next quiz.

Train should show:

- selected exam
- practice mode
- optional focus
- question bank size
- latest score
- one primary button

The primary button should usually be:

- `Start Quiz`

Train should not show:

- database jargon
- AI model status
- internal queue language
- too many readiness metrics
- long explanations

### Exams

Purpose:

Let the learner choose and manage exam paths.

Exams should show:

- available certification paths
- question count
- latest score
- simple readiness state

Exams should not be a note editor-first screen. Editing and custom imports are secondary.

### History

Purpose:

Let the learner review past quiz attempts.

History should show:

- quiz date
- exam
- score
- number of questions

When a quiz is opened, it should show:

- each question
- learner answer
- correct answer
- concise feedback

History should not open details below a long list where the user has to scroll.

## Free Mode Design

Free mode is the default.

Free mode behavior:

- uses saved bank questions only
- selects questions randomly
- can filter by focus if the user chooses one
- saves quiz sessions and attempts
- never calls AI to adapt the next quiz
- never says the quiz is personalized

Free mode UI language:

- `Free practice`
- `Random quiz from the bank`
- `Score saved`
- `Review mistakes`

Free mode should answer:

Can this app help me practice right now?

## Paid Mode Design

Paid mode is called:

- `AI Coach`

Paid mode behavior:

- uses history, misses, stale questions, and focus areas
- adapts the next quiz
- can generate reports
- can recommend weak domains
- can create additional question variants when source coverage is insufficient

Paid mode UI language:

- `AI Coach`
- `Adaptive quiz`
- `Weak areas`
- `Next focus`
- `Report`

Paid mode should answer:

Why is this better than a random practice test?

## Question Bank Standards

The question bank is the product foundation.

Rules:

- No leaked exam dumps.
- No copied proprietary practice exams.
- Use licensed or original questions.
- Store provenance for each question.
- Map questions to certification domains.
- Avoid duplicate prompts.
- Avoid repeated answer patterns.
- Do not show weak AI-generated questions when bank questions are available.

For certification prep, trusted questions matter more than novelty.

## AI Usage

AI should not be the whole product.

AI should be used where it creates paid value:

- adaptive quiz selection
- weak-area summaries
- remediation explanations
- learner reports
- generating supplemental questions only when source bank coverage is weak

AI should not be required for:

- taking a free quiz
- grading multiple choice
- viewing history
- choosing an exam
- using the app at all

If AI fails, the product must still work as a practice app.

## Data Model

The learner-facing model should be simple:

- Exam
- Question
- Quiz
- Attempt
- Score
- Review

The internal model can be richer:

- source provider
- license
- domain
- subtopic
- last seen time
- understanding score
- attempt history
- queue state

But internal objects should not leak into the UI unless they help the learner act.

## Success Metrics

The product is improving when:

- users start a quiz within 10 seconds of landing
- users take multiple quizzes in one session
- users review missed questions
- repeat quiz scores improve
- users trust the questions
- users understand the difference between free and paid
- users would pay for AI Coach

## What To Remove Or Hide

Remove from normal product surfaces:

- model setup language
- Gemma/Ollama implementation details
- "journey" language if it is not concrete
- database/debug screens
- verbose readiness dashboards
- generic AI copy
- note-stream UI for certification users

Keep debug tools only behind `?debug=1`.

## Design Principles

1. One screen, one job.
2. One primary action per screen.
3. Random practice is free.
4. Adaptive coaching is paid.
5. The bank must be trustworthy.
6. AI should improve the loop, not define the product.
7. The learner should never wonder what to do next.

## Near-Term Product Target

The next build should make the app feel like this:

1. Open QuizLoop.
2. See two exam cards.
3. Pick Cloud Practitioner or Solutions Architect.
4. See question count and latest score.
5. Press `Start Quiz`.
6. Answer 10 clean multiple-choice questions.
7. See score.
8. Review missed questions.
9. Press `Next Quiz`.

If that loop feels excellent, the product has a foundation.
