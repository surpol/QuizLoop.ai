# QuizLoop.ai XPRIZE Business Plan

## Competition Frame

Build with Gemini XPRIZE is not a normal app demo. The entry must show a business that operates with AI. QuizLoop.ai should therefore be submitted as an AI tutoring business, not only a learning app.

Category: Education & Human Potential

Business thesis: students already collect learning material from class notes, Wikipedia, books, PDFs, and assignments, but they do not know how to turn that material into reliable practice. QuizLoop.ai sells a guided learning loop that turns any source text into quizzes, feedback, and measurable understanding.

## Product Promise

QuizLoop.ai helps a learner move from raw material to mastery:

1. Add a note, article, chapter, or math template.
2. The system reads it and creates a quiz bank.
3. The learner takes one focused quiz at a time.
4. Every answer becomes memory.
5. The next quiz adapts to weak concepts, stale concepts, and adjacent harder concepts.
6. The learner sees simple evidence of progress, not a confusing chatbot transcript.

The product is strongest when we avoid open-ended chat. The interface should feel like the app always knows the next learning action.

## Required XPRIZE Alignment

### Google Cloud

We need at least one Google Cloud product in the deployed business. Best fit:

- Cloud Run for the web API and evidence export service.
- Cloud SQL or Firestore for hosted business/user evidence.
- Cloud Storage for anonymized demo artifacts and generated reports.

The current local-first SQLite app remains valuable, but XPRIZE needs a production business surface with Google Cloud in the loop.

### Gemini API

If the deployed product includes LLM functionality, it must make at least one Gemini API call. Best fit:

- Use Gemini to generate learner-facing progress reports from saved quiz evidence.
- Use Gemini to summarize class/cohort performance for an educator dashboard.
- Use Gemini to create onboarding recommendations after a new user adds their first note.

Gemma can remain the local/offline learning engine. Gemini should power the cloud business layer and evidence/reporting layer.

### Business Evidence

The submission needs more than product screenshots. We need:

- Real users: students, parents, teachers, or tutoring clients.
- Usage evidence: note count, quiz count, completion rate, repeat quiz loops, average score changes.
- Revenue evidence: even small paid pilots are useful if they are arms-length.
- Cost evidence: hosting, model/API usage, app store costs, and any marketing spend.
- Agent/product logs: model runs, quiz generation, report generation, and user actions.

## Business Model

Initial wedge: AWS certification prep for learners who already pay for courses, practice exams, labs, and exam vouchers.

Offer:

- Free: local notes, limited quiz loops, manual model setup.
- Student Plus: unlimited notes, generated progress reports, backup/export, guided study plans.
- Teacher Pilot: small cohort dashboard, topic-level evidence, assignment exports.

First customer target:

- AWS Certified Cloud Practitioner learners.
- AWS Certified Solutions Architect - Associate learners.
- Tutors, bootcamps, or training groups helping students prepare for cloud certifications.

Suggested pilot price:

- $5 to $10 per student per month for early users.
- $29 one-time AWS Cloud Practitioner prep pack.
- $49 one-time AWS Solutions Architect Associate prep pack.
- $50 to $150 per month for a small tutor/bootcamp cohort.

## AI Operating System

QuizLoop should use AI in two connected ways:

### Learning Intelligence

Gemma/Gemini turns notes into durable learning objects:

- Note
- Topic
- Concept
- Question
- Question variant
- Quiz session
- Attempt
- Feedback
- Understanding state

The important product detail is that questions are not disposable text. They are objects with memory.

### Business Operations

Gemini helps operate the business:

- Creates weekly learner reports from quiz evidence.
- Summarizes user feedback into product tasks.
- Writes teacher-facing cohort summaries.
- Generates onboarding emails and support responses.
- Creates sales/demo material from real usage data.

This satisfies the XPRIZE expectation that the business itself operates with AI.

## Product Changes Needed

### Must Have

- Add Gemini API integration to the deployed web/business backend.
- Add an evidence export endpoint for usage, model runs, quiz sessions, and score movement.
- Add a learner report generated from saved quiz history.
- Add a simple landing/pricing page.
- Add onboarding that explains one job: add material, take quizzes, watch understanding improve.
- Add a pilot workflow for collecting testimonials and consent.

### Should Have

- Teacher/cohort dashboard with anonymized learner progress.
- File upload for PDFs/text.
- Canvas/Blackboard integration plan.
- Backup/import for local learning memory.
- Better cost logging for model calls and hosting.

### Avoid

- Generic AI chat.
- Overbuilt gamification.
- Showing internal jargon like segments, embeddings, or model runs to students.
- Depending on a MacBook tunnel for public judging.

## Evidence Plan

Create a weekly evidence packet during the hackathon:

- Number of active learners.
- Number of notes created.
- Number of quizzes completed.
- Average quizzes per note.
- Percentage of notes with repeated quiz loops.
- Example before/after score movement.
- Screenshots of product logs.
- Gemini API usage records.
- Google Cloud deployment screenshots.
- User quotes with permission.
- Revenue and cost spreadsheet.

## Demo Story

Three-minute video structure:

1. Problem: AI chat asks students to be prompt engineers. Weak prompts create weak learning.
2. Product: QuizLoop turns raw material into one next quiz.
3. Intelligence: saved attempts shape the next quiz.
4. Business: a tutor/teacher can see learning evidence and send reports.
5. Proof: real user logs, revenue/pilot evidence, Google Cloud + Gemini usage.

## Next Build Order

1. Add Gemini report generation endpoint.
2. Add product/evidence export endpoint.
3. Add a simple learner report UI.
4. Add a landing/pricing page.
5. Add event logging for report generation and onboarding.
6. Create a pilot tracking spreadsheet.
7. Recruit 5 to 10 early learners.
8. Record weekly evidence snapshots.
