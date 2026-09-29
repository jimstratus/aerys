\c aerys

-- 006_sub_agents.sql
-- Phase 5: Sub-agent tool registry + email draft staging
-- Note: numbered 006 because 005_fix_core_claim_visibility.sql exists

CREATE TABLE IF NOT EXISTS sub_agents (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  description TEXT NOT NULL,
  workflow_id TEXT NOT NULL,
  trigger_hints TEXT,
  capability_id TEXT NOT NULL,  -- dot-notation stable ID e.g. 'media', 'research.web', 'email'
  enabled BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Placeholder rows with stub workflow IDs -- 05-01/02/03 will UPDATE these
-- capability_id uses dot-notation stable IDs (e.g. 'media', 'research.web', 'email')
-- These are machine-readable identifiers for deterministic routing; trigger_hints are for LLM fuzzy matching
-- Installer seeds only the sub-agents whose workflows ship with the
-- installer. Email agent is intentionally excluded (per D-11 — email
-- tool is in active rebuild and is not imported by the installer).
-- Users who manually import the email sub-agent can add this row
-- themselves post-install.
INSERT INTO sub_agents (name, description, workflow_id, trigger_hints, capability_id, enabled) VALUES
  ('media_agent',
   'Processes images, PDFs, DOCX, TXT files, and YouTube video links. Use when user sends an attachment or YouTube URL.',
   'PENDING-05-01',
   'image attachment, document attachment, YouTube link, video link, summarize this video, what is in this file',
   'media',
   true),
  ('research_agent',
   'Performs web research using Tavily. Use when user asks about current events, requests a lookup, or needs information Aerys may not know from her training.',
   'PENDING-05-02',
   'look up, search for, what is happening now, current news, latest, find out, recent developments',
   'research.web',
   true)
ON CONFLICT (name) DO NOTHING;

-- Email draft staging table for draft-then-confirm flow
CREATE TABLE IF NOT EXISTS pending_emails (
  id SERIAL PRIMARY KEY,
  person_id UUID NOT NULL,
  to_address TEXT NOT NULL,
  subject TEXT NOT NULL,
  body TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',  -- pending, sent, cancelled
  created_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ DEFAULT NOW() + INTERVAL '30 minutes'
);

CREATE INDEX IF NOT EXISTS idx_pending_emails_person_id ON pending_emails(person_id);
CREATE INDEX IF NOT EXISTS idx_pending_emails_status ON pending_emails(status);

-- LAYER 1 OF 2 -- DO NOT SKIP -- Foundation for V2 adaptive routing (see todo: v2-trigger-hints-feedback-loop)
-- Every sub-agent call in Phase 5 logs here. outcome starts NULL.
-- Layer 2 (V2) reads this table to detect poor routing decisions and refine trigger_hints.
-- Without this data accumulating from Phase 5 go-live, V2 has nothing to learn from.
CREATE TABLE IF NOT EXISTS sub_agent_invocations (
  id SERIAL PRIMARY KEY,
  person_id UUID,
  capability_id TEXT NOT NULL,    -- e.g. 'research.web', 'media', 'email'
  agent_name TEXT NOT NULL,       -- e.g. 'research_agent'
  user_message TEXT,              -- first 300 chars of message that triggered the call
  result_summary TEXT,            -- first 300 chars of result returned
  outcome TEXT,                   -- NULL here; V2 writes 'good'/'poor' from user follow-up signals
  invoked_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sub_agent_invocations_capability ON sub_agent_invocations(capability_id);
CREATE INDEX IF NOT EXISTS idx_sub_agent_invocations_outcome ON sub_agent_invocations(outcome);
CREATE INDEX IF NOT EXISTS idx_sub_agent_invocations_person ON sub_agent_invocations(person_id);
