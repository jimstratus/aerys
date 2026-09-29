\c aerys

-- Extensible platform identity store
-- Authoritative store for all platform->person mappings from Phase 3 forward.
-- The existing persons.discord_id and persons.telegram_id columns are kept for
-- backward compat but platform_identities is the canonical reference.
CREATE TABLE IF NOT EXISTS platform_identities (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id        UUID NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
    platform         TEXT NOT NULL,           -- 'discord', 'telegram'
    platform_user_id TEXT NOT NULL,           -- raw platform ID (string always)
    username         TEXT,                    -- display name from platform at link time
    linked_at        TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (platform, platform_user_id)       -- one account per platform per person
);

CREATE INDEX IF NOT EXISTS idx_platform_identities_person
    ON platform_identities(person_id);

CREATE INDEX IF NOT EXISTS idx_platform_identities_lookup
    ON platform_identities(platform, platform_user_id);

-- Short-lived verification code store for user-initiated cross-platform linking
CREATE TABLE IF NOT EXISTS pending_links (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code       TEXT NOT NULL UNIQUE,
    person_id  UUID NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
    platform   TEXT NOT NULL,                -- platform where code was issued
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pending_links_code
    ON pending_links(code);

CREATE INDEX IF NOT EXISTS idx_pending_links_expires
    ON pending_links(expires_at);
