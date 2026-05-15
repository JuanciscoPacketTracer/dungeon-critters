(() => {
  const pathParts = window.location.pathname.split('/').filter(Boolean);
  const OWNER = 'JuanciscoPacketTracer';
  const REPO = pathParts[0] || 'dungeon-critters';
  const BRANCH = 'main';
  const API_BASE = `https://api.github.com/repos/${OWNER}/${REPO}/contents`;
  const RAW_BASE = `https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/`;

  const TYPE3_CONFIG_PATH = 'scripts/00000 Plugins/00002 DMC_TripleTypes/00000 Config.rb';
  const TYPE_KEY = ['type1', 'type2', 'type3'];
  const MODIFIER_FROM_SCORE = new Map([
    [4, 4], [3, 3], [2, 2], [1, 2], [0, 1], [-1, 0.5], [-2, 0.5], [-3, 0.33]
  ]);

  const page = document.body.dataset.page;

  const toTitle = (value) => (value || '')
    .toString()
    .replaceAll('_', ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase());
  const escapeHtml = (value) => (value || '')
    .toString()
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
  const sanitizeColor = (value) => (/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(value || '') ? value : '#607d8b');

  async function fetchJson(path) {
    const response = await fetch(path);
    if (!response.ok) throw new Error(`Fetch failed: ${path}`);
    return response.json();
  }

  async function fetchTextWithFallback(localPath) {
    try {
      const local = await fetch(localPath);
      if (local.ok) return local.text();
    } catch (_error) {
      console.warn('Local config fetch failed, using raw fallback:', _error);
    }
    const remote = await fetch(`${RAW_BASE}${localPath}`);
    if (!remote.ok) throw new Error(`Fetch failed: ${localPath}`);
    return remote.text();
  }

  function parseType3Config(rbText) {
    const mappings = new Map();
    const matcher = /\[:([A-Za-z0-9_]+)\s*,\s*(\d+)\]\s*=>\s*:([A-Za-z0-9_]+)/g;
    let match;
    while ((match = matcher.exec(rbText)) !== null) {
      mappings.set(`${match[1]}#${match[2]}`, match[3]);
    }
    return mappings;
  }

  async function loadData() {
    const [pokemonEntries, typeEntries, typeNamesText, type3ConfigText] = await Promise.all([
      fetchJson(`${API_BASE}/Data/Studio/pokemon?ref=${BRANCH}`),
      fetchJson(`${API_BASE}/Data/Studio/types?ref=${BRANCH}`),
      fetchTextWithFallback('Data/Text/Dialogs/100003.csv'),
      fetchTextWithFallback(TYPE3_CONFIG_PATH)
    ]);

    const [pokemonData, typeData] = await Promise.all([
      Promise.all(pokemonEntries.filter((f) => f.name.endsWith('.json')).map((f) => fetchJson(f.download_url))),
      Promise.all(typeEntries.filter((f) => f.name.endsWith('.json')).map((f) => fetchJson(f.download_url)))
    ]);

    return {
      pokemonData,
      typeData,
      typeNamesText,
      type3Map: parseType3Config(type3ConfigText)
    };
  }

  function parseTypeNames(csvText) {
    const lines = csvText.split(/\r?\n/).filter(Boolean);
    return lines.slice(1).map((line) => line.split(',')[0]);
  }

  function getCritters(data) {
    return data.pokemonData
      .map((entry) => {
        const form = entry.forms?.[0];
        if (!form) return null;
        const key = `${entry.dbSymbol}#${form.form ?? 0}`;
        const type3 = data.type3Map.get(key);
        const front = form.resources?.front || String(entry.id).padStart(3, '0');
        const types = [...new Set([form.type1, form.type2, type3].filter(Boolean))];
        return {
          id: entry.id,
          dbSymbol: entry.dbSymbol,
          name: toTitle(entry.dbSymbol),
          types,
          abilities: (form.abilities || []).filter(Boolean).map(toTitle),
          stats: {
            HP: form.baseHp,
            ATK: form.baseAtk,
            DEF: form.baseDfe,
            SPD: form.baseSpd,
            SATK: form.baseAts,
            SDEF: form.baseDfs
          },
          spriteGif: `${RAW_BASE}graphics/pokedex/pokefront/${front}.gif`,
          spritePng: `${RAW_BASE}graphics/pokedex/pokefront/${front}.png`
        };
      })
      .filter(Boolean)
      .sort((a, b) => a.id - b.id);
  }

  function getTypeData(typeData, typeNames) {
    const bySymbol = new Map();
    typeData.forEach((type) => {
      const offensive = new Map();
      (type.damageTo || []).forEach((row) => offensive.set(row.defensiveType, row.factor));
      bySymbol.set(type.dbSymbol, {
        symbol: type.dbSymbol,
        name: typeNames[type.textId] || toTitle(type.dbSymbol),
        color: type.color || '#607d8b',
        offensive
      });
    });
    return bySymbol;
  }

  function calculateModifier(attackType, defenderTypes, typeMap) {
    let score = 0;
    for (let i = 0; i < TYPE_KEY.length; i += 1) {
      const defensiveType = defenderTypes[i];
      if (!defensiveType) continue;
      const weight = i === 0 ? 2 : 1;
      const offensiveMap = typeMap.get(attackType)?.offensive;
      const factor = offensiveMap?.get(defensiveType) ?? 1;
      if (factor === 0) return 0;
      if (factor > 1) score += weight;
      if (factor < 1) score -= weight;
    }
    return MODIFIER_FROM_SCORE.get(score) ?? 0.25;
  }

  function spriteTag(critter, size = 96) {
    return `<img width="${size}" height="${size}" src="${critter.spriteGif}" data-fallback-src="${critter.spritePng}" alt="${escapeHtml(critter.name)} sprite"/>`;
  }

  function badge(type, typeMap) {
    const t = typeMap.get(type);
    const name = escapeHtml(t?.name || toTitle(type));
    const color = sanitizeColor(t?.color);
    return `<span class="badge" style="background:${color}">${name}</span>`;
  }

  function emptyList(el, label = 'None') {
    el.innerHTML = `<li>${escapeHtml(label)}</li>`;
  }

  function attachFallbackHandlers(scope) {
    scope.querySelectorAll('img[data-fallback-src]').forEach((img) => {
      img.onerror = () => {
        if (img.dataset.fallback) return;
        img.dataset.fallback = '1';
        img.src = img.dataset.fallbackSrc;
      };
    });
  }

  function renderIndex({ critters, typeMap }) {
    const status = document.getElementById('status');
    const grid = document.getElementById('critterGrid');
    const search = document.getElementById('search');
    const typeFilterA = document.getElementById('typeFilterA');
    const typeFilterB = document.getElementById('typeFilterB');

    const typeOptions = [...typeMap.values()].sort((a, b) => a.name.localeCompare(b.name));
    typeOptions.forEach((type) => {
      typeFilterA.insertAdjacentHTML('beforeend', `<option value="${type.symbol}">${type.name}</option>`);
      typeFilterB.insertAdjacentHTML('beforeend', `<option value="${type.symbol}">${type.name}</option>`);
    });

    const applyFilters = () => {
      const text = search.value.trim().toLowerCase();
      const a = typeFilterA.value;
      const b = typeFilterB.value;

      const filtered = critters.filter((critter) => {
        if (text && !critter.name.toLowerCase().includes(text)) return false;
        if (a && !critter.types.includes(a)) return false;
        if (b && !critter.types.includes(b)) return false;
        return true;
      });

      status.textContent = `${filtered.length} critter(s)`;
      grid.hidden = false;
      grid.innerHTML = filtered.map((critter) => `
        <a class="card" href="critter.html?id=${encodeURIComponent(critter.dbSymbol)}">
          ${spriteTag(critter)}
          <h2>${escapeHtml(critter.name)}</h2>
          <div class="badges">${critter.types.map((type) => badge(type, typeMap)).join('')}</div>
        </a>
      `).join('');
      attachFallbackHandlers(grid);
    };

    search.addEventListener('input', applyFilters);
    typeFilterA.addEventListener('change', applyFilters);
    typeFilterB.addEventListener('change', applyFilters);
    applyFilters();
  }

  function renderDetail({ critters, typeMap }) {
    const params = new URLSearchParams(window.location.search);
    const id = params.get('id');
    const critter = critters.find((c) => c.dbSymbol === id);

    const status = document.getElementById('status');
    if (!critter) {
      status.textContent = 'Critter not found.';
      return;
    }

    document.title = `${critter.name} · Dungeon Critters Dex`;
    document.getElementById('critterName').textContent = critter.name;

    const sprite = document.getElementById('critterSprite');
    sprite.src = critter.spriteGif;
    sprite.alt = `${critter.name} sprite`;
    sprite.onerror = () => {
      if (sprite.dataset.fallback) return;
      sprite.dataset.fallback = '1';
      sprite.src = critter.spritePng;
    };

    document.getElementById('typeBadges').innerHTML = critter.types.map((type) => badge(type, typeMap)).join('');

    const abilities = document.getElementById('abilities');
    if (!critter.abilities.length) {
      emptyList(abilities);
    } else {
      abilities.innerHTML = critter.abilities.map((a) => `<li>${escapeHtml(a)}</li>`).join('');
    }

    const stats = document.getElementById('stats');
    stats.innerHTML = Object.entries(critter.stats)
      .map(([name, value]) => `<div><strong>${escapeHtml(name)}</strong><br/>${escapeHtml(value)}</div>`)
      .join('');

    const weak = [];
    const resist = [];
    const immune = [];
    for (const [attackType, type] of typeMap.entries()) {
      const m = calculateModifier(attackType, critter.types, typeMap);
      const label = `${type.name} ×${m}`;
      if (m === 0) immune.push(label);
      else if (m > 1) weak.push(label);
      else if (m < 1) resist.push(label);
    }

    const weakEl = document.getElementById('weaknesses');
    const resistEl = document.getElementById('resistances');
    const immuneEl = document.getElementById('immunities');

    weakEl.innerHTML = weak.length ? weak.map((v) => `<li>${escapeHtml(v)}</li>`).join('') : '<li>None</li>';
    resistEl.innerHTML = resist.length ? resist.map((v) => `<li>${escapeHtml(v)}</li>`).join('') : '<li>None</li>';
    immuneEl.innerHTML = immune.length ? immune.map((v) => `<li>${escapeHtml(v)}</li>`).join('') : '<li>None</li>';

    status.hidden = true;
    document.getElementById('detail').hidden = false;
    attachFallbackHandlers(document);
  }

  async function init() {
    try {
      const data = await loadData();
      const critters = getCritters(data);
      const typeNames = parseTypeNames(data.typeNamesText);
      const typeMap = getTypeData(data.typeData, typeNames);

      if (page === 'index') renderIndex({ critters, typeMap });
      if (page === 'detail') renderDetail({ critters, typeMap });
    } catch (error) {
      const status = document.getElementById('status');
      if (status) status.textContent = `Failed to load dex data: ${error.message}`;
    }
  }

  init();
})();
