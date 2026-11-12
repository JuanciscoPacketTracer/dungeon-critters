# Dungeon Critters

Terms for the game state and its cloud-save and casual-ranking features.

## Cloud saves

**Cloud slot**:
The account-scoped remote counterpart of one local save slot, with a stable one-to-one binding.
_Avoid_: shared slot, automatic slot mapping

**Save version**:
An immutable, server-identified snapshot in a cloud slot, with a parent version that records its lineage.
_Avoid_: overwrite, mutable save

**Conflict branch**:
A non-current save version preserved when a snapshot was based on an outdated current version.
_Avoid_: discarded conflict, automatic merge

**Pending snapshot**:
The latest immutable local snapshot awaiting upload for a cloud slot.
_Avoid_: cloud save, queued overwrite

## Casual ranking

**Leaderboard entry**:
The public, account-level record of that account's best historical accepted game summary.
_Avoid_: player profile, save slot, current save

**Best historical result**:
The highest-ranked game summary an account has achieved across its accepted save versions.
_Avoid_: current progress, latest save
