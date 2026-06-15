# QuizLoop.ai Certification Quiz Audit

Date: June 1, 2026
Target: AWS Solutions Architect Associate Prep
Run type: five back-to-back quizzes with a mix of correct and intentionally wrong answers.

## Summary

The core loop is promising: quizzes are generated from a large certification bank, answers are saved, missed concepts influence the next quiz, and History now shows better explanation text. The biggest product risk is not question volume anymore. It is trust: the learner must feel that every quiz is valid, every repeat is intentional, and every review teaches an exam decision rule.

During this run, the app completed four quiz attempts, then exposed a critical bug: the next quiz was marked ready but returned zero questions. I fixed the root cause by relaxing the certification domain validation gate for short adaptive quizzes. The app was rejecting a valid weakness-focused quiz because its domain mix was not proportional enough.

## Attempts

### Quiz 1

Score: 100%

Experience:
- Served 10 questions across secure, resilient, high-performing, and cost-optimized domains.
- No repeated prompts inside the quiz.
- After 100%, the system correctly stated that it would prepare adjacent or harder material.

Weakness:
- Some correct-answer feedback still reads a little generic when the answer is a phrase instead of a named AWS service.

### Quiz 2

Score: 49%

Intentionally missed:
- Compute Savings Plans
- CloudFront cost reduction
- KMS encryption trap
- S3 Object Lock
- RDS Multi-AZ failover

Experience:
- The next quiz memory correctly saved five gaps.
- The feedback was much better after the coaching update. It explained the correct answer and the exam lens.

Weakness:
- Trap questions can be confusing because the user is choosing the "weakest fit." The UI should visually mark these as "Find the bad option" so the learner does not read them as ordinary best-answer questions.

### Quiz 3

Score: 60%

Observed adaptation:
- Compute Savings Plans returned in a new form.
- CloudFront cost returned in a related form.
- S3 Object Lock returned as a trap-style check.
- New related concepts appeared: cross-account IAM role, RDS point-in-time restore, EFS regional design.

Weakness:
- This was the best personalization moment, but the app does not explain why the next quiz changed. The system knows it is revisiting misses, but the learner only sees another quiz.

### Quiz 4

Score: 70%

Observed adaptation:
- Cost-Optimized was overweighted because the previous misses were cost-heavy.
- Some previously missed questions returned exactly:
  - S3 Object Lock
  - RDS Multi-AZ automatic failover

Weakness:
- Exact repeats should be rare. Repeating a missed concept is good, but repeating the same prompt too soon can feel like memorization instead of learning.

### Quiz 5

Initial result: failed to start.

Observed bug:
- The note showed a ready quiz.
- `GET /quiz` returned `questions: []`.
- Rebuilding also said `status: ready`, but starting still returned empty.

Root cause:
- The queued quiz had 10 valid questions, but the validation layer rejected it because its domain distribution was too far from the official exam mix.
- Example rejected mix: Cost-Optimized 4, Secure 2, High-Performing 2, Resilient 2.
- For an adaptive quiz after cost-heavy misses, that mix is acceptable.

Fix applied:
- Short certification quizzes now allow a wider domain tolerance so weakness-focused quizzes can start.
- After the fix, Quiz 5 started correctly with 10 questions and scored 70%.

Follow-up fixes:
- `startQuiz` now has a repair path for stale or invalid ready queues. If an old ready queue fails validation, the app invalidates it, queues another candidate, and tries again before showing the learner an empty state.
- The quiz screen now shows the queue rationale, for example: "Next quiz revisits 2 missed ideas and adds related questions."
- Trap questions now receive a visible "Find the weak option" treatment so the learner understands the task.
- Exact prompt repeats from the recent assignment window are avoided when the bank has enough alternatives. Missed concepts can still return, but the system should prefer a new prompt shape.
- Shallow certification prompts are filtered before selection, so weak checks like "What is Amazon CloudWatch?" do not qualify for the certification loop.
- Active quiz questions now show a source label so the learner can distinguish curated bank material from any future AI supplement.
- Certification quiz selection now enforces an applied-question floor. Ranking alone was not enough; the selector now reserves enough scenario/service-decision prompts so Cloud Practitioner does not drift into pure definition practice.

## What Works

- Large enough question bank for both AWS exams.
- SQLite stores quiz sessions, attempts, scores, prompts, answers, and feedback.
- Missed concepts influence the next quiz.
- The History page now provides useful "Why this matters" feedback.
- The Lab page exposes enough database state to debug question sources, queue state, misses, and readiness.
- The automated cert audit now runs five consecutive quizzes per exam and validates official domains, question structure, source quality, trap wording, and scenario density.
- The audit caught a real Cloud Practitioner weakness where a later quiz had only two applied questions. The fix was made in the selector, not by lowering the audit standard.

## Main Weaknesses

1. Ready state must be absolute.

If the UI says a quiz is ready, `Start Quiz` must never return an empty quiz. Queue validation should happen before the UI sees ready status.

2. Repeats need a reason.

The app should repeat concepts, not necessarily exact prompts. When an exact repeat happens, the UI should say why: "You missed this last time, so QuizLoop is checking it once more."

3. Trap questions need clearer presentation.

"Which choice is the weakest fit?" is valid exam practice, but it needs a distinct label. Otherwise learners may answer the best service instead of the bad service.

4. Feedback should become more specific.

The new feedback is much better, but service-specific explanations should cover more AWS services and patterns. Phrase answers still sometimes fall back to generic coaching.

5. The learner needs a next-quiz rationale.

After finishing a quiz, the result screen should show one sentence like: "Next quiz will revisit Cost Optimization and RDS recovery because those were missed." This makes the adaptation visible.

6. Product trust needs source badges.

For a paid cert product, every question should show whether it came from the curated bank, licensed bank, or AI supplement. This is now visible during the quiz and in Lab. It should eventually be added to review cards too.

## Priority Fix List

1. Guarantee startable queues.
   - Status: partially fixed.
   - The start path now repairs invalid ready queues instead of returning an empty quiz.
   - Remaining improvement: validate queue contents before setting `state = ready`.

2. Add repeat rationale.
   - Status: partially fixed.
   - Exact prompt repeats are avoided across a wider recent-assignment window.
   - Remaining improvement: store a clear `selection_reason` per queued question and show it in History and Lab.
   - Store `repeat_reason` or `selection_reason` per queued question.
   - Show it in History and Lab.

3. Add trap UI treatment.
   - Status: fixed for the active quiz screen.
   - Trap questions now show "Find the weak option" and a short instruction above choices.

4. Improve review explanations.
   - Add service and pattern explanation mappings for common SAA and CLF answers.
   - Include "why your selected answer is wrong" when the selected distractor is recognizable.

5. Add quiz rationale banner.
   - Status: fixed for the active quiz screen.
   - The first question now shows why the quiz was chosen.
   - After grading: "Next up: IAM trust, point-in-time restore, and cost planning."

6. Expand automated tests.
   - Status: improved.
   - `npm run audit:certs` now runs five consecutive quizzes for Cloud Practitioner and Solutions Architect.
   - It fails on empty quizzes, duplicate choices, unofficial domains, AI-supplemented cert questions, ambiguous trap wording, and too-few scenario questions.
   - Remaining improvement: add a deterministic test that intentionally misses one concept and confirms the next quiz revisits the concept in a new form.

## Product Verdict

QuizLoop is close to a credible certification prep loop. The value is not "AI makes quizzes"; the value is "every answer becomes memory, and the next quiz responds to that memory." To make someone pay, the app needs to make that intelligence visible and trustworthy. The next product milestone should be a smoother review-and-next-quiz experience, not more features.
