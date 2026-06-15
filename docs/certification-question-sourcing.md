# Certification Question Sourcing

QuizLoop's certification product should not behave like a random AI worksheet generator. For AWS certification prep, question creation follows a source-first rule:

1. Use licensed practice questions when available.
2. Use QuizLoop-original curated questions mapped to official exam guide domains.
3. Use Gemma/Gemini for sequencing, grading, explanations, reports, and remediation.
4. Do not use exam dumps or scrape copyrighted practice exams.
5. Do not serve AI-supplemental certification questions while the saved source bank has enough viable questions.

## SQLite Objects

`question_sources` records provider-level provenance:

- `provider`
- `source_url`
- `license_name`
- `license_url`
- `certification_code`
- `provenance_kind`

`questions` stores question-level provenance:

- `source_id`
- `source_provider`
- `source_url`
- `source_license`
- `source_license_url`
- `provenance_kind`

Valid provenance kinds:

- `licensed_bank`: imported from a permissively licensed external bank.
- `curated_bank`: QuizLoop-original content mapped to official certification domains.
- `ai_supplemental`: AI-generated from notes/history, allowed for non-certification notes and only fallback/supplemental cert behavior.

## Current AWS Sources

Cloud Practitioner uses CloudCertPrep's MIT-licensed CLF-C02 bank plus QuizLoop-curated questions.

Solutions Architect currently has a smaller licensed SAA-C03 bank from CloudCertPrep plus QuizLoop-curated architecture questions mapped to the official SAA-C03 domains. The next product step is to add more legally usable SAA-C03 source banks and multi-response UI support.

## Audit

Run:

```sh
cd web
npm run audit:certs
```

The audit takes three back-to-back quizzes for Cloud Practitioner and Solutions Architect. It fails when a quiz:

- has fewer than 10 questions
- repeats a prompt or question id across the audit loop
- drifts from official domain balance
- serves AI-supplemental certification questions while source-bank questions exist
- grades an all-correct quiz below 100%
- fails to prepare the next quiz
