-- Apply explicitly to databases created from an earlier 001_sessions.sql.
-- The startup guard refuses incomplete schemas; this migration does not rewrite
-- existing messages or infer delivery history.
ALTER TABLE email_outbox
  ADD COLUMN IF NOT EXISTS attempts integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS next_attempt_at timestamptz,
  ADD COLUMN IF NOT EXISTS terminal_at timestamptz,
  ADD COLUMN IF NOT EXISTS claim_token uuid;
