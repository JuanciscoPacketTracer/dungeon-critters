CREATE TABLE IF NOT EXISTS public_profiles (
  user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  public_alias text NOT NULL,
  alias_normalized text NOT NULL UNIQUE,
  alias_changed_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public_alias_reservations (
  alias_normalized text PRIMARY KEY,
  user_id uuid NOT NULL,
  released_at timestamptz NOT NULL
);
