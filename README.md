# Dungeon Critters Dex (GitHub Pages)

This repository now includes a static **Dungeon Critters Dex** site for GitHub Pages.

## Pages setup

1. Go to **Settings → Pages**.
2. Set **Source** to `Deploy from a branch`.
3. Select branch `main` and folder `/ (root)`.
4. Save.

The site URL is:

- `https://juanciscopackettracer.github.io/dungeon-critters/`

## Data source (no manual duplication)

The dex reads directly from existing repository data files:

- Critters: `Data/Studio/pokemon/*.json`
- Types / interactions: `Data/Studio/types/*.json`
- Triple type config: `scripts/00000 Plugins/00002 DMC_TripleTypes/00000 Config.rb`
- Sprites: `graphics/pokedex/pokefront/*.(gif|png)`

## Updating dex content

To update the dex, edit the existing game data files above. No extra dex-specific data files are required.

- Add/update critters in `Data/Studio/pokemon`
- Add/update type charts in `Data/Studio/types`
- Update third-type mappings in `DMC_TripleTypes` config
- Add sprites in `graphics/pokedex/pokefront`

The Pages site reads those files at runtime, so once changes are pushed, the dex reflects them.
