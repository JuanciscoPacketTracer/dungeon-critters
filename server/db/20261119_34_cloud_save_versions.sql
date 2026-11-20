CREATE TABLE IF NOT EXISTS cloud_slots (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL,
  local_slot_id text NOT NULL,
  current_version_id uuid,
  next_sequence bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cloud_slots_user_local_slot_key UNIQUE (user_id, local_slot_id),
  CONSTRAINT cloud_slots_user_id_key UNIQUE (user_id, id)
);

CREATE TABLE IF NOT EXISTS save_versions (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL,
  cloud_slot_id uuid NOT NULL,
  upload_id text NOT NULL,
  parent_version_id uuid,
  sequence bigint NOT NULL,
  status text NOT NULL CHECK (status IN ('accepted', 'conflict')),
  payload bytea NOT NULL,
  payload_sha256 text NOT NULL CHECK (payload_sha256 ~ '^[0-9a-f]{64}$'),
  payload_length integer NOT NULL CHECK (payload_length >= 0),
  codec_schema_version integer NOT NULL,
  game_version text NOT NULL,
  psdk_version text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT save_versions_user_upload_key UNIQUE (user_id, upload_id),
  CONSTRAINT save_versions_user_slot_id_key UNIQUE (id, user_id, cloud_slot_id)
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint AS c
      JOIN pg_class AS t ON t.oid = c.conrelid
      JOIN pg_namespace AS n ON n.oid = t.relnamespace
     WHERE n.nspname = current_schema()
       AND t.relname = 'cloud_slots'
       AND c.conname = 'cloud_slots_user_fkey'
  ) THEN
    ALTER TABLE cloud_slots
      ADD CONSTRAINT cloud_slots_user_fkey
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint AS c
      JOIN pg_class AS t ON t.oid = c.conrelid
      JOIN pg_namespace AS n ON n.oid = t.relnamespace
     WHERE n.nspname = current_schema()
       AND t.relname = 'save_versions'
       AND c.conname = 'save_versions_user_fkey'
  ) THEN
    ALTER TABLE save_versions
      ADD CONSTRAINT save_versions_user_fkey
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint AS c
      JOIN pg_class AS t ON t.oid = c.conrelid
      JOIN pg_namespace AS n ON n.oid = t.relnamespace
     WHERE n.nspname = current_schema()
       AND t.relname = 'save_versions'
       AND c.conname = 'save_versions_cloud_slot_owner_fkey'
  ) THEN
    ALTER TABLE save_versions
      ADD CONSTRAINT save_versions_cloud_slot_owner_fkey
      FOREIGN KEY (user_id, cloud_slot_id)
      REFERENCES cloud_slots(user_id, id)
      DEFERRABLE INITIALLY DEFERRED;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint AS c
      JOIN pg_class AS t ON t.oid = c.conrelid
      JOIN pg_namespace AS n ON n.oid = t.relnamespace
     WHERE n.nspname = current_schema()
       AND t.relname = 'save_versions'
       AND c.conname = 'save_versions_parent_owner_fkey'
  ) THEN
    ALTER TABLE save_versions
      ADD CONSTRAINT save_versions_parent_owner_fkey
      FOREIGN KEY (parent_version_id, user_id, cloud_slot_id)
      REFERENCES save_versions(id, user_id, cloud_slot_id)
      DEFERRABLE INITIALLY DEFERRED;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint AS c
      JOIN pg_class AS t ON t.oid = c.conrelid
      JOIN pg_namespace AS n ON n.oid = t.relnamespace
     WHERE n.nspname = current_schema()
       AND t.relname = 'cloud_slots'
       AND c.conname = 'cloud_slots_current_version_owner_fkey'
  ) THEN
    ALTER TABLE cloud_slots
      ADD CONSTRAINT cloud_slots_current_version_owner_fkey
      FOREIGN KEY (current_version_id, user_id, id)
      REFERENCES save_versions(id, user_id, cloud_slot_id)
      DEFERRABLE INITIALLY DEFERRED;
  END IF;
END
$$;
