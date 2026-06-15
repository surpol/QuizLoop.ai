-- QuizLoop.ai production certification cleanup.
-- Run with:
-- npx wrangler d1 execute quizloop-ai --remote --file web/scripts/cleanup-production-cert-notes.sql
--
-- Keeps the strongest CLF-C02 and SAA-C03 records, removes old debug/import notes,
-- and renames the kept records with user-facing product titles.

UPDATE notes
SET title = 'AWS Cloud Practitioner'
WHERE id = 'c36e3e8f-2d2e-41e9-9efa-efcf2ca4ff8f';

UPDATE notes
SET title = 'AWS Solutions Architect Associate'
WHERE id = 'b0d8c102-989a-433e-b34b-dac5905f4aa3';

DELETE FROM attempts
WHERE note_id IN (
  'e4b281e1-9ec3-4199-8458-6fd519e2b180',
  '128fcc58-cf19-4c86-91c5-13a338584258',
  '29798182-20f3-44a5-8de3-5cab02ca1a3f',
  'a6cf4ae3-0b04-47e7-bd1d-6fcf4d42d5ab',
  '090773f5-6920-4a6d-84e6-05e99deec4ae'
);

DELETE FROM quiz_sessions
WHERE note_id IN (
  'e4b281e1-9ec3-4199-8458-6fd519e2b180',
  '128fcc58-cf19-4c86-91c5-13a338584258',
  '29798182-20f3-44a5-8de3-5cab02ca1a3f',
  'a6cf4ae3-0b04-47e7-bd1d-6fcf4d42d5ab',
  '090773f5-6920-4a6d-84e6-05e99deec4ae'
);

DELETE FROM quiz_queue
WHERE note_id IN (
  'e4b281e1-9ec3-4199-8458-6fd519e2b180',
  '128fcc58-cf19-4c86-91c5-13a338584258',
  '29798182-20f3-44a5-8de3-5cab02ca1a3f',
  'a6cf4ae3-0b04-47e7-bd1d-6fcf4d42d5ab',
  '090773f5-6920-4a6d-84e6-05e99deec4ae'
);

DELETE FROM questions
WHERE note_id IN (
  'e4b281e1-9ec3-4199-8458-6fd519e2b180',
  '128fcc58-cf19-4c86-91c5-13a338584258',
  '29798182-20f3-44a5-8de3-5cab02ca1a3f',
  'a6cf4ae3-0b04-47e7-bd1d-6fcf4d42d5ab',
  '090773f5-6920-4a6d-84e6-05e99deec4ae'
);

DELETE FROM notes
WHERE id IN (
  'e4b281e1-9ec3-4199-8458-6fd519e2b180',
  '128fcc58-cf19-4c86-91c5-13a338584258',
  '29798182-20f3-44a5-8de3-5cab02ca1a3f',
  'a6cf4ae3-0b04-47e7-bd1d-6fcf4d42d5ab',
  '090773f5-6920-4a6d-84e6-05e99deec4ae'
);
