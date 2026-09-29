\c aerys

-- Add provenance columns to existing memories table (Phase 4 MEM-08)
ALTER TABLE memories
  ADD COLUMN IF NOT EXISTS source_platform TEXT,
  ADD COLUMN IF NOT EXISTS privacy_level   TEXT NOT NULL DEFAULT 'public',
  ADD COLUMN IF NOT EXISTS batch_job_id    UUID,
  ADD COLUMN IF NOT EXISTS processed_at    TIMESTAMPTZ;

-- Raw extracted observations (every mention of a fact, before promotion)
CREATE TABLE IF NOT EXISTS userinfo (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  speaker_id     UUID NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  key_label      TEXT NOT NULL,
  value_text     TEXT NOT NULL,
  value_norm     JSONB DEFAULT '{}',
  sensitivity    TEXT DEFAULT 'P2',
  asserted_by    TEXT DEFAULT 'third_party',
  source_gist_id UUID,
  model_conf     NUMERIC(4,3),
  first_seen     TIMESTAMPTZ DEFAULT NOW(),
  last_seen      TIMESTAMPTZ DEFAULT NOW()
);

-- Promoted confirmed facts (injected into prompts)
CREATE TABLE IF NOT EXISTS core_claim (
  core_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  speaker_id  UUID NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  key_label   TEXT NOT NULL,
  claim_text  TEXT NOT NULL,
  value_norm  JSONB DEFAULT '{}',
  sensitivity TEXT DEFAULT 'P2',
  status      TEXT NOT NULL DEFAULT 'proposed',
  locked      BOOLEAN DEFAULT FALSE,
  confidence  NUMERIC(4,3),
  ttl_ts      TIMESTAMPTZ,
  visibility  TEXT DEFAULT 'server',
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  last_seen   TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (speaker_id, key_label)
);

-- Audit log for Guardian promotions and user overrides
CREATE TABLE IF NOT EXISTS audit_log (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  who        TEXT NOT NULL,
  action     TEXT NOT NULL,
  details    JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_userinfo_speaker   ON userinfo(speaker_id);
CREATE INDEX IF NOT EXISTS idx_userinfo_key       ON userinfo(speaker_id, key_label);
CREATE INDEX IF NOT EXISTS idx_userinfo_last_seen ON userinfo(last_seen DESC);
CREATE INDEX IF NOT EXISTS idx_core_claim_speaker ON core_claim(speaker_id);
CREATE INDEX IF NOT EXISTS idx_core_claim_status  ON core_claim(status) WHERE status != 'proposed';
CREATE INDEX IF NOT EXISTS idx_memories_privacy   ON memories(person_id, privacy_level) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_memories_processed ON memories(processed_at) WHERE processed_at IS NULL;

-- NOTE: The live migration 004 on the original Aerys instance included a
-- historical data-cleanup UPDATE against `n8n_chat_histories` to rename
-- `dm_{person_id}` session keys to bare `person_id`. That cleanup was
-- one-time and specific to a Phase 3→4 transition on the original deploy.
-- On a fresh install:
--   1. n8n_chat_histories is in the `n8n` DB, not `aerys` (this file runs
--      against `aerys` via the `\c aerys` at the top), so the query is
--      cross-database incorrect for the installer context.
--   2. The table is created by n8n itself on first write, so it does not
--      exist at init time — the UPDATE fails, Postgres init crashes, and
--      subsequent migrations never run.
-- Conclusion: removed for fresh installs. No action needed.
