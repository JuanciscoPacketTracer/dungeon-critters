(() => {
  // ── i18n ─────────────────────────────────────────────────
  const STRINGS = {
    en: {
      title:              'Dungeon Critters Bestiary',
      subtitle:           'Browse critters from the game data.',
      tab_bestiary:       'Bestiary',
      tab_types:          'Type Info',
      search_placeholder: 'Search critter name…',
      any_type:           'Any type',
      any_type2:          'Any second type',
      loading:            'Loading critters…',
      loading_detail:     'Loading critter…',
      loading_types:      'Loading type info…',
      back:               '← Back to Bestiary',
      types_title:        'Type Information',
      types_subtitle:     'Browse type totals, matchups, and critters by typing.',
      total_critters:     'Total critters',
      critters_per_type:  'Critters per type',
      available_types:    'Available types',
      select_type:        'Select a type',
      selected_type:      'Selected type',
      type_tabs:          'Type tabs',
      type_matchups:      'Type interactions',
      critters_with_type: 'Critters with this type',
      type_total:         'Type total',
      description:        'Description',
      abilities:          'Abilities',
      stats:              'Stats',
      base_stat_total:    'Base Stat Total',
      evolutions:         'Evolutions',
      no_evolutions:      'This critter does not evolve.',
      method_level:       'Level',
      method_stone:       'Use',
      method_move:        'Knows',
      method_maps:        'Map',
      method_gender:      'Gender',
      method_time:        'Time',
      gender_male:        'Male',
      gender_female:      'Female',
      gender_unknown:     'Unknown',
      time_day:           'Day',
      time_night:         'Night',
      time_slot:          'Slot',
      matchups:           'Type Matchups (Triple-Type Logic)',
      weaknesses:         'Weaknesses',
      resistances:        'Resistances',
      immunities:         'Immunities',
      none:               'None',
      not_found:          'Critter not found.',
      load_error:         'Failed to load bestiary data',
    },
    es: {
      title:              'Bestiario de Dungeon Critters',
      subtitle:           'Explora criaturas del juego.',
      tab_bestiary:       'Bestiario',
      tab_types:          'Tipos',
      search_placeholder: 'Buscar nombre de criatura…',
      any_type:           'Cualquier tipo',
      any_type2:          'Cualquier segundo tipo',
      loading:            'Cargando criaturas…',
      loading_detail:     'Cargando criatura…',
      loading_types:      'Cargando información de tipos…',
      back:               '← Volver al Bestiario',
      types_title:        'Información de tipos',
      types_subtitle:     'Revisa totales de tipos, interacciones y criaturas por tipo.',
      total_critters:     'Criaturas totales',
      critters_per_type:  'Criaturas por tipo',
      available_types:    'Tipos disponibles',
      select_type:        'Selecciona un tipo',
      selected_type:      'Tipo seleccionado',
      type_tabs:          'Pestañas de tipo',
      type_matchups:      'Interacciones de tipo',
      critters_with_type: 'Criaturas con este tipo',
      type_total:         'Total de tipo',
      description:        'Descripción',
      abilities:          'Habilidades',
      stats:              'Estadísticas',
      base_stat_total:    'Total de stats base',
      evolutions:         'Evoluciones',
      no_evolutions:      'Esta criatura no evoluciona.',
      method_level:       'Nivel',
      method_stone:       'Usar',
      method_move:        'Conoce',
      method_maps:        'Mapa',
      method_gender:      'Género',
      method_time:        'Tiempo',
      gender_male:        'Macho',
      gender_female:      'Hembra',
      gender_unknown:     'Desconocido',
      time_day:           'Día',
      time_night:         'Noche',
      time_slot:          'Franja',
      matchups:           'Efectividades de tipo (Triple tipo)',
      weaknesses:         'Debilidades',
      resistances:        'Resistencias',
      immunities:         'Inmunidades',
      none:               'Ninguna',
      not_found:          'Criatura no encontrada.',
      load_error:         'Error al cargar el bestiario',
    },
  };

  let lang = localStorage.getItem('dmc-lang') || 'en';
  if (!STRINGS[lang]) lang = 'en';
  const LANG_COLUMN = { en: 0, es: 4 };

  /** Translate a key for the current language. */
  function t(key) {
    return (STRINGS[lang] && STRINGS[lang][key]) ?? STRINGS.en[key] ?? key;
  }

  /** "{n} critter(s)" with locale awareness. */
  function nCritters(n) {
    return lang === 'es' ? `${n} criatura(s)` : `${n} critter(s)`;
  }

  /** Apply current lang to all data-i18n / data-i18n-placeholder elements. */
  function applyLang() {
    document.documentElement.lang = lang;

    document.querySelectorAll('[data-i18n]').forEach((el) => {
      const str = STRINGS[lang]?.[el.dataset.i18n];
      if (str !== undefined) el.textContent = str;
    });

    document.querySelectorAll('[data-i18n-placeholder]').forEach((el) => {
      const str = STRINGS[lang]?.[el.dataset.i18nPlaceholder];
      if (str !== undefined) el.placeholder = str;
    });

    document.querySelectorAll('.lang-btn').forEach((btn) => {
      const active = btn.dataset.lang === lang;
      btn.classList.toggle('active', active);
      btn.setAttribute('aria-pressed', String(active));
    });
  }

  /** Wire up the EN / ES toggle buttons. Re-renders the page on switch. */
  function initLangToggle(renderFn, renderArgs) {
    document.querySelectorAll('.lang-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        if (btn.dataset.lang === lang) return;
        lang = btn.dataset.lang;
        localStorage.setItem('dmc-lang', lang);
        applyLang();
        if (renderFn && renderArgs) renderFn(renderArgs);
      });
    });
  }

  // ── GitHub API setup ──────────────────────────────────────
  const pathParts = window.location.pathname.split('/').filter(Boolean);
  const OWNER = 'JuanciscoPacketTracer';
  const REPO = pathParts[0] || 'dungeon-critters';
  const BRANCH = 'main';
  const API_BASE = `https://api.github.com/repos/${OWNER}/${REPO}/contents`;
  const RAW_BASE = `https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/`;

  const TYPE3_CONFIG_PATH = 'scripts/00000 Plugins/00002 DMC_TripleTypes/00000 Config.rb';
  const TYPE_KEY = ['type1', 'type2', 'type3'];
  const MODIFIER_FROM_SCORE = new Map([
    [4, 4], [3, 3], [2, 2], [1, 2], [0, 1], [-1, 0.5], [-2, 0.5], [-3, 0.33],
  ]);

  const page = document.body.dataset.page;

  // Will be set from the Type3 config (MAINTYPE flag)
  let TRIPLE_MAIN_TYPE = true;

  // ── Helpers ───────────────────────────────────────────────
  const toTitle = (value) =>
    (value || '').toString().replaceAll('_', ' ').replace(/\b\w/g, (c) => c.toUpperCase());

  const escapeHtml = (value) =>
    (value || '')
      .toString()
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  const sanitizeColor = (value) =>
    /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(value || '') ? value : '#607d8b';

  function parseCsv(csvText) {
    const rows = [];
    let row = [];
    let cell = '';
    let inQuotes = false;

    for (let i = 0; i < csvText.length; i += 1) {
      const ch = csvText[i];
      const next = csvText[i + 1];

      if (ch === '"') {
        if (inQuotes && next === '"') {
          cell += '"';
          i += 1;
        } else {
          inQuotes = !inQuotes;
        }
        continue;
      }

      if (!inQuotes && ch === ',') {
        row.push(cell);
        cell = '';
        continue;
      }

      if (!inQuotes && (ch === '\n' || ch === '\r')) {
        if (ch === '\r' && next === '\n') i += 1;
        row.push(cell);
        rows.push(row);
        row = [];
        cell = '';
        continue;
      }

      cell += ch;
    }

    row.push(cell);
    rows.push(row);
    return rows;
  }

  function parseLocalizedTable(csvText) {
    const rows = parseCsv(csvText);
    return rows.slice(1);
  }

  function getLocalizedCell(rows, id, fallback = '') {
    const row = rows[id];
    if (!row) return fallback;
    const column = LANG_COLUMN[lang] ?? 0;
    return row[column] || row[0] || fallback;
  }

  // ── Data fetching ─────────────────────────────────────────
  async function fetchJson(path) {
    const response = await fetch(path);
    if (!response.ok) throw new Error(`Fetch failed: ${path}`);
    return response.json();
  }

  async function spriteExists(url) {
    try {
      const response = await fetch(url, { method: 'HEAD' });
      return response.ok;
    } catch (_error) {
      return false;
    }
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
    if (!rbText) return { map: mappings, maintype: true };

    // Extract MAINTYPE flag (true/false)
    const maintypeMatch = rbText.match(/MAINTYPE\s*=\s*(true|false)/);
    const maintype = maintypeMatch ? maintypeMatch[1] === 'true' : true;

    const matcher = /\[:([A-Za-z0-9_]+)\s*,\s*(\d+)\]\s*=>\s*:([A-Za-z0-9_]+)/g;
    let match;
    while ((match = matcher.exec(rbText)) !== null) {
      mappings.set(`${match[1]}#${match[2]}`, match[3]);
    }
    return { map: mappings, maintype };
  }

  async function loadData() {
    const [pokemonEntries, typeEntries, abilityEntries, pokemonNamesText, descriptionsText, typeNamesText, abilityNamesText, type3ConfigText, personalDexText] = await Promise.all([
      fetchJson(`${API_BASE}/Data/Studio/pokemon?ref=${BRANCH}`),
      fetchJson(`${API_BASE}/Data/Studio/types?ref=${BRANCH}`),
      fetchJson(`${API_BASE}/Data/Studio/abilities?ref=${BRANCH}`),
      fetchTextWithFallback('Data/Text/Dialogs/100000.csv'),
      fetchTextWithFallback('Data/Text/Dialogs/100002.csv'),
      fetchTextWithFallback('Data/Text/Dialogs/100003.csv'),
      fetchTextWithFallback('Data/Text/Dialogs/100004.csv'),
      fetchTextWithFallback(TYPE3_CONFIG_PATH),
      fetchTextWithFallback('Data/Studio/dex/personal_bestiary.json'),
    ]);

    const [pokemonData, typeData, abilityData] = await Promise.all([
      Promise.all(
        pokemonEntries.filter((f) => f.name.endsWith('.json')).map((f) => fetchJson(f.download_url)),
      ),
      Promise.all(
        typeEntries.filter((f) => f.name.endsWith('.json')).map((f) => fetchJson(f.download_url)),
      ),
      Promise.all(
        abilityEntries.filter((f) => f.name.endsWith('.json')).map((f) => fetchJson(f.download_url)),
      ),
    ]);

    const parsedType3 = parseType3Config(type3ConfigText);
    return {
      pokemonData,
      typeData,
      abilityData,
      pokemonNamesText,
      descriptionsText,
      typeNamesText,
      abilityNamesText,
      type3Map: parsedType3.map,
      maintypeFlag: parsedType3.maintype,
      personalDex: personalDexText ? JSON.parse(personalDexText) : null,
    };
  }

  async function getCritters(data) {
    // Build a lookup from dbSymbol#form -> pokedex number using the Personal Bestiary (dex id 1)
    const pokedexMap = new Map();
    try {
      const pd = data.personalDex;
      if (pd && Array.isArray(pd.creatures)) {
        const start = Number(pd.startId) || 1;
        pd.creatures.forEach((c, idx) => {
          const key = `${c.dbSymbol}#${c.form ?? 0}`;
          pokedexMap.set(key, start + idx);
          // also map bare symbol for backward compatibility
          if (!pokedexMap.has(c.dbSymbol)) pokedexMap.set(c.dbSymbol, start + idx);
        });
      }
    } catch (err) {
      console.warn('Failed to build pokedex map:', err);
    }
    const critters = data.pokemonData
      .map((entry) => {
        const form = entry.forms?.[0];
        if (!form) return null;
        const key = `${entry.dbSymbol}#${form.form ?? 0}`;
        const type3 = data.type3Map.get(key);
        const front = form.resources?.front || String(entry.id).padStart(3, '0');
        const types = [...new Set(
          [form.type1, form.type2, type3].filter((v) => Boolean(v) && v !== 'undefined' && v !== '__undef__' && v !== 'none'),
        )];
        return {
          id: entry.id,
          dbSymbol: entry.dbSymbol,
          fallbackName: toTitle(entry.dbSymbol),
          types,
          evolutions: form.evolutions || [],
          abilitySymbols: (form.abilities || [])
            .filter((a) => Boolean(a) && a !== '__undef__' && a !== 'none'),
          stats: {
            HP:   form.baseHp,
            ATK:  form.baseAtk,
            DEF:  form.baseDfe,
            SPD:  form.baseSpd,
            SATK: form.baseAts,
            SDEF: form.baseDfs,
          },
          spriteGif: `${RAW_BASE}graphics/pokedex/pokefront/${front}.gif`,
          spritePng: `${RAW_BASE}graphics/pokedex/pokefront/${front}.png`,
          pokedexNumber: pokedexMap.get(`${entry.dbSymbol}#${form.form ?? 0}`) || pokedexMap.get(entry.dbSymbol) || null,
        };
      })
      .filter(Boolean)
      .sort((a, b) => {
        const pa = a.pokedexNumber ?? Number.MAX_SAFE_INTEGER;
        const pb = b.pokedexNumber ?? Number.MAX_SAFE_INTEGER;
        if (pa !== pb) return pa - pb;
        return a.id - b.id;
      });

    await Promise.all(critters.map(async (critter) => {
      critter.spriteAvailable = await spriteExists(critter.spriteGif) || await spriteExists(critter.spritePng);
    }));

    return critters;
  }

  function getTypeData(typeData) {
    const bySymbol = new Map();
    typeData.forEach((type) => {
      const offensive = new Map();
      (type.damageTo || []).forEach((row) => offensive.set(row.defensiveType, row.factor));
      bySymbol.set(type.dbSymbol, {
        symbol: type.dbSymbol,
        textId: type.textId,
        fallbackName: toTitle(type.dbSymbol),
        color: type.color || '#607d8b',
        offensive,
      });
    });
    return bySymbol;
  }

  function getAbilityData(abilityData) {
    const bySymbol = new Map();
    abilityData.forEach((ability) => {
      bySymbol.set(ability.dbSymbol, {
        textId: ability.textId,
        fallbackName: toTitle(ability.dbSymbol),
      });
    });
    return bySymbol;
  }

  function getCritterName(critter, textTables) {
    return getLocalizedCell(textTables.pokemonNames, critter.id, critter.fallbackName);
  }

  function getCritterDescription(critter, textTables) {
    return getLocalizedCell(textTables.descriptions, critter.id, '');
  }

  function getTypeName(typeSymbol, typeMap, textTables) {
    const type = typeMap.get(typeSymbol);
    if (!type) return toTitle(typeSymbol);
    return getLocalizedCell(textTables.typeNames, type.textId, type.fallbackName);
  }

  function getAbilityName(abilitySymbol, abilityMap, textTables) {
    const ability = abilityMap.get(abilitySymbol);
    if (!ability) return toTitle(abilitySymbol);
    return getLocalizedCell(textTables.abilityNames, ability.textId, ability.fallbackName);
  }

  function calculateModifier(attackType, defenderTypes, typeMap) {
    let score = 0;
    for (let i = 0; i < TYPE_KEY.length; i += 1) {
      const defensiveType = defenderTypes[i];
      if (!defensiveType) continue;
      const weight = TRIPLE_MAIN_TYPE ? (i === 0 ? 2 : 1) : 1;
      const offensiveMap = typeMap.get(attackType)?.offensive;
      const factor = offensiveMap?.get(defensiveType) ?? 1;
      if (factor === 0) return 0;
      if (factor > 1) score += weight;
      if (factor < 1) score -= weight;
    }
    return MODIFIER_FROM_SCORE.get(score) ?? 0.25;
  }

  // ── Render helpers ────────────────────────────────────────
  function spriteTag(critter, name, size = 96) {
    return `<img width="${size}" height="${size}" src="${critter.spriteGif}" data-fallback-src="${critter.spritePng}" alt="${escapeHtml(name)} sprite"/>`;
  }

  function badge(type, typeMap, textTables) {
    const t2 = typeMap.get(type);
    const name = escapeHtml(getTypeName(type, typeMap, textTables));
    const color = sanitizeColor(t2?.color);
    return `<span class="badge" style="background:${color}">${name}</span>`;
  }

  function countCrittersByType(critters) {
    const counts = new Map();
    critters.forEach((critter) => {
      critter.types.forEach((type) => {
        counts.set(type, (counts.get(type) || 0) + 1);
      });
    });
    return counts;
  }

  function critterCardHtml(critter, typeMap, textTables) {
    const localizedName = getCritterName(critter, textTables);
    return `
      <a class="card" href="critter.html?id=${encodeURIComponent(critter.dbSymbol)}">
        ${spriteTag(critter, localizedName)}
        <h2>${escapeHtml(localizedName)}</h2>
        <div class="badges">${critter.types.map((type) => badge(type, typeMap, textTables)).join('')}</div>
      </a>`;
  }

  function multiplierClass(multiplier) {
    if (multiplier === 4) return 'm4';
    if (multiplier === 3) return 'm3';
    if (multiplier === 2) return 'm2';
    if (multiplier === 1) return 'm1';
    if (multiplier === 0.5) return 'm05';
    if (multiplier === 0.33) return 'm033';
    if (multiplier === 0.25) return 'm025';
    if (multiplier === 0) return 'm0';
    return 'm1';
  }

  function matchupRow(typeSymbol, multiplier, typeMap, textTables) {
    const displayMultiplier = Number.isInteger(multiplier) ? String(multiplier) : String(multiplier);
    return `<li class="matchup-row">${badge(typeSymbol, typeMap, textTables)}<span class="mult-chip ${multiplierClass(multiplier)}">x${displayMultiplier}</span></li>`;
  }

  function typeMatchupBuckets(attackType, typeMap) {
    const weak = [];
    const resist = [];
    const immune = [];

    for (const [defenseType] of typeMap.entries()) {
      const multiplier = calculateModifier(attackType, [defenseType], typeMap);
      if (multiplier === 0) immune.push({ attackType: defenseType, multiplier });
      else if (multiplier > 1) weak.push({ attackType: defenseType, multiplier });
      else if (multiplier < 1) resist.push({ attackType: defenseType, multiplier });
    }

    return { weak, resist, immune };
  }

  function formatGender(value) {
    if (value === 1) return t('gender_male');
    if (value === 2) return t('gender_female');
    return t('gender_unknown');
  }

  function formatTime(value) {
    if (value === 0) return t('time_day');
    if (value === 3) return t('time_night');
    return `${t('time_slot')} ${value}`;
  }

  function formatEvolutionCondition(condition) {
    const value = condition?.value;
    switch (condition?.type) {
      case 'minLevel':
        return `${t('method_level')} ${value}`;
      case 'stone':
        return `${t('method_stone')} ${toTitle(value)}`;
      case 'skill1':
        return `${t('method_move')} ${toTitle(value)}`;
      case 'maps': {
        const maps = Array.isArray(value) ? value.map((mapId) => `${t('method_maps')} ${mapId}`).join(', ') : `${t('method_maps')} ${value}`;
        return maps;
      }
      case 'gender':
        return `${t('method_gender')} ${formatGender(value)}`;
      case 'dayNight':
        return `${t('method_time')} ${formatTime(value)}`;
      default:
        return `${toTitle(condition?.type || 'condition')} ${Array.isArray(value) ? value.join(', ') : value}`.trim();
    }
  }

  function evolutionRow(evo, critterBySymbol, textTables) {
    const target = critterBySymbol.get(evo.dbSymbol);
    const targetName = target ? getCritterName(target, textTables) : toTitle(evo.dbSymbol);
    const methodText = (evo.conditions || []).map((condition) => formatEvolutionCondition(condition)).join(' · ');
    const sprite = target
      ? `<img width="64" height="64" src="${target.spriteGif}" data-fallback-src="${target.spritePng}" alt="${escapeHtml(targetName)} sprite"/>`
      : '';
    return `<li class="evo-row">${sprite}<div class="evo-content"><a class="evo-name" href="critter.html?id=${encodeURIComponent(evo.dbSymbol)}">${escapeHtml(targetName)}</a><div class="evo-method">${escapeHtml(methodText || t('none'))}</div></div></li>`;
  }

  function emptyList(el) {
    el.innerHTML = `<li>${escapeHtml(t('none'))}</li>`;
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

  /** Render a visual stat bar. Max base stat treated as 255. */
  function statBarHtml(name, value) {
    const num = Number(value) || 0;
    const pct = Math.min(100, Math.round((num / 255) * 100));
    const tier = num < 60 ? 'low' : num < 90 ? 'mid' : num < 130 ? 'high' : 'max';
    return `
      <div class="stat-row">
        <span class="stat-name">${escapeHtml(name)}</span>
        <div class="stat-bar-wrap">
          <div class="stat-bar" data-tier="${tier}" style="width:${pct}%"></div>
        </div>
        <span class="stat-value">${escapeHtml(String(num))}</span>
      </div>`;
  }

  // ── Index page ────────────────────────────────────────────
  function renderIndex({ critters, typeMap, textTables }) {
    const status     = document.getElementById('status');
    const grid       = document.getElementById('critterGrid');
    const search     = document.getElementById('search');
    const typeFilterA = document.getElementById('typeFilterA');
    const typeFilterB = document.getElementById('typeFilterB');

    const visibleCritters = critters.filter((critter) => critter.spriteAvailable !== false);

    const selectedA = typeFilterA.value;
    const selectedB = typeFilterB.value;
    const typeOptions = [...typeMap.entries()]
      .map(([symbol, type]) => ({ symbol, label: getLocalizedCell(textTables.typeNames, type.textId, type.fallbackName) }))
      .sort((a, b) => a.label.localeCompare(b.label));

    typeFilterA.innerHTML = `<option value="">${escapeHtml(t('any_type'))}</option>`;
    typeFilterB.innerHTML = `<option value="">${escapeHtml(t('any_type2'))}</option>`;
    typeOptions.forEach((type) => {
      typeFilterA.insertAdjacentHTML(
        'beforeend',
        `<option value="${type.symbol}">${escapeHtml(type.label)}</option>`,
      );
      typeFilterB.insertAdjacentHTML(
        'beforeend',
        `<option value="${type.symbol}">${escapeHtml(type.label)}</option>`,
      );
    });
    typeFilterA.value = selectedA;
    typeFilterB.value = selectedB;

    const applyFilters = () => {
      const text = search.value.trim().toLowerCase();
      const a    = typeFilterA.value;
      const b    = typeFilterB.value;

      const filtered = visibleCritters.filter((critter) => {
        const localizedName = getCritterName(critter, textTables);
        if (text && !localizedName.toLowerCase().includes(text)) return false;
        if (a && !critter.types.includes(a)) return false;
        if (b && !critter.types.includes(b)) return false;
        return true;
      });

      status.textContent = nCritters(filtered.length);
      grid.hidden = false;
      grid.innerHTML = filtered
        .map(
          (critter) => {
            const localizedName = getCritterName(critter, textTables);
            return `
          <a class="card" href="critter.html?id=${encodeURIComponent(critter.dbSymbol)}">
            ${spriteTag(critter, localizedName)}
            <h2>${escapeHtml(localizedName)}</h2>
            <div class="badges">${critter.types.map((type) => badge(type, typeMap, textTables)).join('')}</div>
          </a>`;
          },
        )
        .join('');
      attachFallbackHandlers(grid);
    };

    if (!search.dataset.boundFilters) {
      search.addEventListener('input', applyFilters);
      typeFilterA.addEventListener('change', applyFilters);
      typeFilterB.addEventListener('change', applyFilters);
      search.dataset.boundFilters = '1';
    }
    applyFilters();
  }

  // ── Detail page ───────────────────────────────────────────
  function renderDetail({ critters, typeMap, abilityMap, textTables, critterBySymbol }) {
    const params  = new URLSearchParams(window.location.search);
    const id      = params.get('id');
    const critter = critters.find((c) => c.dbSymbol === id);
    const status  = document.getElementById('status');

    if (!critter) {
      status.textContent = t('not_found');
      return;
    }

    const localizedName = getCritterName(critter, textTables);
    const localizedDescription = getCritterDescription(critter, textTables);

    document.title = `${localizedName} · Dungeon Critters Bestiary`;
    document.getElementById('critterName').textContent = localizedName;

    const sprite = document.getElementById('critterSprite');
    sprite.src = critter.spriteGif;
    sprite.alt = `${localizedName} sprite`;
    sprite.onerror = () => {
      if (sprite.dataset.fallback) return;
      sprite.dataset.fallback = '1';
      sprite.src = critter.spritePng;
    };

    document.getElementById('typeBadges').innerHTML = critter.types
      .map((type) => badge(type, typeMap, textTables))
      .join('');

    document.getElementById('critterDescription').textContent = localizedDescription || t('none');

    const abilities = document.getElementById('abilities');
    if (!critter.abilitySymbols.length) {
      emptyList(abilities);
    } else {
      abilities.innerHTML = critter.abilitySymbols
        .map((abilitySymbol) => getAbilityName(abilitySymbol, abilityMap, textTables))
        .map((name) => `<li>${escapeHtml(name)}</li>`)
        .join('');
    }

    const bst = Object.values(critter.stats).reduce((acc, value) => acc + (Number(value) || 0), 0);
    document.getElementById('stats').innerHTML = Object.entries(critter.stats)
      .map(([name, value]) => statBarHtml(name, value))
      .join('') + `<div class="bst-total">${escapeHtml(t('base_stat_total'))}: <strong>${bst}</strong></div>`;

    const evolutionsEl = document.getElementById('evolutions');
    const noEvolutionsEl = document.getElementById('noEvolutions');
    if (!critter.evolutions.length) {
      evolutionsEl.innerHTML = '';
      noEvolutionsEl.hidden = false;
      noEvolutionsEl.textContent = t('no_evolutions');
    } else {
      noEvolutionsEl.hidden = true;
      evolutionsEl.innerHTML = critter.evolutions
        .map((evo) => evolutionRow(evo, critterBySymbol, textTables))
        .join('');
    }

    // Type matchups
    const weak   = [];
    const resist = [];
    const immune = [];

    for (const [attackType] of typeMap.entries()) {
      const m     = calculateModifier(attackType, critter.types, typeMap);
      if (m === 0)      immune.push({ attackType, multiplier: m });
      else if (m > 1)   weak.push({ attackType, multiplier: m });
      else if (m < 1)   resist.push({ attackType, multiplier: m });
    }

    const noneHtml = `<li>${escapeHtml(t('none'))}</li>`;

    document.getElementById('weaknesses').innerHTML  = weak.length
      ? weak.map((v) => matchupRow(v.attackType, v.multiplier, typeMap, textTables)).join('') : noneHtml;
    document.getElementById('resistances').innerHTML = resist.length
      ? resist.map((v) => matchupRow(v.attackType, v.multiplier, typeMap, textTables)).join('') : noneHtml;
    document.getElementById('immunities').innerHTML  = immune.length
      ? immune.map((v) => matchupRow(v.attackType, v.multiplier, typeMap, textTables)).join('') : noneHtml;

    status.hidden = true;
    document.getElementById('detail').hidden = false;
    attachFallbackHandlers(document);
  }

  // ── Types page ────────────────────────────────────────────
  function renderTypes({ critters, typeMap, textTables }) {
    const status = document.getElementById('status');
    const main = document.getElementById('types');
    const typeTabstrip = document.getElementById('typeTabstrip');
    const typeSummaryGrid = document.getElementById('typeSummaryGrid');
    const totalCrittersEl = document.getElementById('totalCrittersCount');
    const totalTypesEl = document.getElementById('totalTypesCount');
    const selectedTypeBadge = document.getElementById('selectedTypeBadge');
    const selectedTypeName = document.getElementById('selectedTypeName');
    const selectedTypeCount = document.getElementById('selectedTypeCount');
    const selectedTypeMatchups = document.getElementById('selectedTypeMatchups');
    const selectedTypeCritters = document.getElementById('selectedTypeCritters');

    const typeCounts = countCrittersByType(critters);
    const typeOptions = [...typeMap.entries()]
      .map(([symbol, type]) => ({
        symbol,
        label: getTypeName(symbol, typeMap, textTables),
        count: typeCounts.get(symbol) || 0,
        color: type.color,
      }))
      .sort((a, b) => a.label.localeCompare(b.label));

    const currentTypeFallback = typeOptions[0]?.symbol || '';

    totalCrittersEl.textContent = nCritters(critters.length);
    totalTypesEl.textContent = `${typeOptions.length}`;

    typeTabstrip.innerHTML = typeOptions
      .map((type) => `
        <button class="type-tab" type="button" role="tab" aria-selected="false" data-type-symbol="${type.symbol}">
          ${badge(type.symbol, typeMap, textTables)}
          <span>${nCritters(type.count)}</span>
        </button>`)
      .join('');

    typeSummaryGrid.innerHTML = typeOptions
      .map((type) => `
        <button class="type-card" type="button" data-type-symbol="${type.symbol}">
          ${badge(type.symbol, typeMap, textTables)}
          <strong>${escapeHtml(type.label)}</strong>
          <span>${nCritters(type.count)}</span>
        </button>`)
      .join('');

    function renderSelected(typeSymbol) {
      const type = typeMap.get(typeSymbol);
      if (!type) return;

      const label = getTypeName(typeSymbol, typeMap, textTables);
      const crittersWithType = critters.filter((critter) => critter.types.includes(typeSymbol));
      const { weak, resist, immune } = typeMatchupBuckets(typeSymbol, typeMap);
      const noneHtml = `<li>${escapeHtml(t('none'))}</li>`;

      selectedTypeBadge.innerHTML = badge(typeSymbol, typeMap, textTables);
      selectedTypeName.textContent = label;
      selectedTypeCount.textContent = nCritters(typeCounts.get(typeSymbol) || 0);

      selectedTypeMatchups.innerHTML = `
        <div class="matchup-group weak">
          <h3>${escapeHtml(t('weaknesses'))}</h3>
          <ul>${weak.length ? weak.map((value) => matchupRow(value.attackType, value.multiplier, typeMap, textTables)).join('') : noneHtml}</ul>
        </div>
        <div class="matchup-group resist">
          <h3>${escapeHtml(t('resistances'))}</h3>
          <ul>${resist.length ? resist.map((value) => matchupRow(value.attackType, value.multiplier, typeMap, textTables)).join('') : noneHtml}</ul>
        </div>
        <div class="matchup-group immune">
          <h3>${escapeHtml(t('immunities'))}</h3>
          <ul>${immune.length ? immune.map((value) => matchupRow(value.attackType, value.multiplier, typeMap, textTables)).join('') : noneHtml}</ul>
        </div>`;

      selectedTypeCritters.innerHTML = crittersWithType.length
        ? crittersWithType.map((critter) => critterCardHtml(critter, typeMap, textTables)).join('')
        : `<p class="small">${escapeHtml(t('none'))}</p>`;

      typeSummaryGrid.querySelectorAll('.type-card').forEach((button) => {
        button.classList.toggle('active', button.dataset.typeSymbol === typeSymbol);
      });

      document.title = `${label} · ${t('types_title')} · Dungeon Critters Bestiary`;
    }

    function activateType(typeSymbol) {
      renderSelected(typeSymbol);
      typeTabstrip.querySelectorAll('.type-tab').forEach((button) => {
        const active = button.dataset.typeSymbol === typeSymbol;
        button.classList.toggle('active', active);
        button.setAttribute('aria-selected', String(active));
      });
    }

    typeSummaryGrid.onclick = (event) => {
      const button = event.target.closest('[data-type-symbol]');
      if (!button) return;
      activateType(button.dataset.typeSymbol);
    };

    typeTabstrip.onclick = (event) => {
      const button = event.target.closest('[data-type-symbol]');
      if (!button) return;
      activateType(button.dataset.typeSymbol);
    };

    activateType(currentTypeFallback);

    status.hidden = true;
    main.hidden = false;
    attachFallbackHandlers(document);
  }

  // ── Boot ──────────────────────────────────────────────────
  async function init() {
    // Apply saved language before data loads
    applyLang();

    try {
      const data     = await loadData();
      TRIPLE_MAIN_TYPE = Boolean(data.maintypeFlag);
      const critters = await getCritters(data);
      const critterBySymbol = new Map(critters.map((critter) => [critter.dbSymbol, critter]));
      const typeMap  = getTypeData(data.typeData);
      const abilityMap = getAbilityData(data.abilityData);
      const textTables = {
        pokemonNames: parseLocalizedTable(data.pokemonNamesText),
        descriptions: parseLocalizedTable(data.descriptionsText),
        typeNames: parseLocalizedTable(data.typeNamesText),
        abilityNames: parseLocalizedTable(data.abilityNamesText),
      };
      const renderArgs = { critters, typeMap, abilityMap, textTables, critterBySymbol };

      if (page === 'index') {
        initLangToggle(renderIndex, renderArgs);
        renderIndex(renderArgs);
      }

      if (page === 'detail') {
        initLangToggle(renderDetail, renderArgs);
        renderDetail(renderArgs);
      }

      if (page === 'types') {
        initLangToggle(renderTypes, renderArgs);
        renderTypes(renderArgs);
      }
    } catch (error) {
      const status = document.getElementById('status');
      if (status) status.textContent = `${t('load_error')}: ${error.message}`;
    }
  }

  init();
})();
