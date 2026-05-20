(() => {
  // Minimal but functional dex script with form support, MAINTYPE flag, and pokedex ordering

  const STRINGS = {
    en: {
      title: 'Dungeon Critters Bestiary',
      search_placeholder: 'Search critter name…',
      any_type: 'Any type',
      any_type2: 'Any second type',
      loading: 'Loading critters…',
      loading_detail: 'Loading critter…',
      back: '← Back to Bestiary',
      description: 'Description',
      abilities: 'Abilities',
      stats: 'Stats',
      base_stat_total: 'Base Stat Total',
      evolutions: 'Evolutions',
      no_evolutions: 'This critter does not evolve.',
      method_level: 'Level',
      method_stone: 'Use',
      method_move: 'Knows',
      matchups: 'Type Matchups',
      weaknesses: 'Weaknesses',
      resistances: 'Resistances',
      immunities: 'Immunities',
      none: 'None',
      not_found: 'Critter not found.',
      load_error: 'Failed to load bestiary data',
    },
    es: {
      title: 'Bestiario de Dungeon Critters',
      search_placeholder: 'Buscar nombre de criatura…',
      any_type: 'Cualquier tipo',
      any_type2: 'Cualquier segundo tipo',
      loading: 'Cargando criaturas…',
      loading_detail: 'Cargando criatura…',
      back: '← Volver al Bestiario',
      description: 'Descripción',
      abilities: 'Habilidades',
      stats: 'Estadísticas',
      base_stat_total: 'Total de stats base',
      evolutions: 'Evoluciones',
      no_evolutions: 'Esta criatura no evoluciona.',
      method_level: 'Nivel',
      method_stone: 'Usar',
      method_move: 'Conoce',
      matchups: 'Efectividades',
      weaknesses: 'Debilidades',
      resistances: 'Resistencias',
      immunities: 'Inmunidades',
      none: 'Ninguna',
      not_found: 'Criatura no encontrada.',
      load_error: 'Error al cargar el bestiario',
    },
  };

  let lang = localStorage.getItem('dmc-lang') || 'en';
  if (!STRINGS[lang]) lang = 'en';
  const LANG_COLUMN = { en: 0, es: 4 };
  function t(key) { return (STRINGS[lang] && STRINGS[lang][key]) ?? STRINGS.en[key] ?? key; }

  const OWNER = 'JuanciscoPacketTracer';
  const REPO = 'dungeon-critters';
  const BRANCH = 'main';
  const API_BASE = `https://api.github.com/repos/${OWNER}/${REPO}/contents`;
  const RAW_BASE = `https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/`;

  const TYPE3_CONFIG_PATH = 'scripts/00000 Plugins/00002 DMC_TripleTypes/00000 Config.rb';
  const TYPE_KEY = ['type1','type2','type3'];
  const MODIFIER_FROM_SCORE = new Map([[4,4],[3,3],[2,2],[1,2],[0,1],[-1,0.5],[-2,0.5],[-3,0.33]]);
  let TRIPLE_MAIN_TYPE = true;

  // --- CSV parser ---
  function parseCsv(csvText) {
    const rows = [];
    let row = [], cell = '', inQuotes = false;
    for (let i=0;i<csvText.length;i++) {
      const ch = csvText[i], next = csvText[i+1];
      if (ch === '"') { if (inQuotes && next === '"') { cell += '"'; i++; } else inQuotes = !inQuotes; continue; }
      if (!inQuotes && ch === ',') { row.push(cell); cell=''; continue; }
      if (!inQuotes && (ch === '\n' || ch === '\r')) { if (ch === '\r' && next === '\n') i++; row.push(cell); rows.push(row); row=[]; cell=''; continue; }
      cell += ch;
    }
    row.push(cell); rows.push(row); return rows;
  }
  function parseLocalizedTable(csvText) { const rows = parseCsv(csvText); return rows.slice(1); }
  function getLocalizedCell(rows, id, fallback='') { const row = rows[id]; if (!row) return fallback; const col = LANG_COLUMN[lang] ?? 0; return row[col] || row[0] || fallback; }

  async function fetchJson(path) { const r = await fetch(path); if (!r.ok) throw new Error(path); return r.json(); }
  async function fetchTextWithFallback(localPath) { try { const local = await fetch(localPath); if (local.ok) return local.text(); } catch (_){} const remote = await fetch(`${RAW_BASE}${localPath}`); if (!remote.ok) throw new Error(localPath); return remote.text(); }

  function parseType3Config(rbText) {
    const mappings = new Map();
    if (!rbText) return { map: mappings, maintype: true };
    const maintypeMatch = rbText.match(/MAINTYPE\s*=\s*(true|false)/);
    const maintype = maintypeMatch ? maintypeMatch[1] === 'true' : true;
    const matcher = /\[:([A-Za-z0-9_]+)\s*,\s*(\d+)\]\s*=>\s*:([A-Za-z0-9_]+)/g;
    let m; while ((m = matcher.exec(rbText)) !== null) mappings.set(`${m[1]}#${m[2]}`, m[3]);
    return { map: mappings, maintype };
  }

  async function loadData() {
    const [pokemonEntries, typeEntries, abilityEntries, spriteEntries, namesText, descText, typeNamesText, abilityNamesText, type3ConfigText, personalDexText] = await Promise.all([
      fetchJson(`${API_BASE}/Data/Studio/pokemon?ref=${BRANCH}`),
      fetchJson(`${API_BASE}/Data/Studio/types?ref=${BRANCH}`),
      fetchJson(`${API_BASE}/Data/Studio/abilities?ref=${BRANCH}`),
      fetchJson(`${API_BASE}/graphics/pokedex/pokefront?ref=${BRANCH}`),
      fetchTextWithFallback('Data/Text/Dialogs/100000.csv'),
      fetchTextWithFallback('Data/Text/Dialogs/100002.csv'),
      fetchTextWithFallback('Data/Text/Dialogs/100003.csv'),
      fetchTextWithFallback('Data/Text/Dialogs/100004.csv'),
      fetchTextWithFallback(TYPE3_CONFIG_PATH),
      fetchTextWithFallback('Data/Studio/dex/personal_bestiary.json'),
    ]);

    const [pokemonData, typeData, abilityData] = await Promise.all([
      Promise.all(pokemonEntries.filter(f=>f.name.endsWith('.json')).map(f=>fetchJson(f.download_url))),
      Promise.all(typeEntries.filter(f=>f.name.endsWith('.json')).map(f=>fetchJson(f.download_url))),
      Promise.all(abilityEntries.filter(f=>f.name.endsWith('.json')).map(f=>fetchJson(f.download_url))),
    ]);

    const parsedType3 = parseType3Config(type3ConfigText);
    return {
      pokemonData, typeData, abilityData,
      spriteEntries,
      pokemonNamesText: namesText, descriptionsText: descText, typeNamesText, abilityNamesText,
      type3Map: parsedType3.map, maintypeFlag: parsedType3.maintype,
      personalDex: personalDexText ? JSON.parse(personalDexText) : null,
    };
  }

  function getTypeData(typeData) {
    const by = new Map();
    typeData.forEach((type) => {
      const off = new Map(); (type.damageTo||[]).forEach(r=>off.set(r.defensiveType, r.factor));
      by.set(type.dbSymbol, { symbol: type.dbSymbol, textId: type.textId, fallbackName: toTitle(type.dbSymbol), color: type.color||'#607d8b', offensive: off });
    });
    return by;
  }
  function getAbilityData(abilityData) { const by = new Map(); abilityData.forEach(a=>by.set(a.dbSymbol, { textId: a.textId, fallbackName: toTitle(a.dbSymbol) })); return by; }

  function getCritterName(critter, tables) { return getLocalizedCell(tables.pokemonNames, critter.id, critter.fallbackName); }
  function getCritterDescription(critter, tables) { return getLocalizedCell(tables.descriptions, critter.id, ''); }
  function getTypeName(sym, typeMap, tables) { const t = typeMap.get(sym); if (!t) return toTitle(sym); return getLocalizedCell(tables.typeNames, t.textId, t.fallbackName); }
  function getAbilityName(sym, abilityMap, tables) { const a = abilityMap.get(sym); if (!a) return toTitle(sym); return getLocalizedCell(tables.abilityNames, a.textId, a.fallbackName); }

  function calculateModifier(attackType, defenderTypes, typeMap) {
    let score = 0;
    for (let i=0;i<TYPE_KEY.length;i++){
      const defensiveType = defenderTypes[i]; if (!defensiveType) continue;
      const weight = TRIPLE_MAIN_TYPE ? (i===0?2:1) : 1;
      const offensiveMap = typeMap.get(attackType)?.offensive;
      const factor = offensiveMap?.get(defensiveType) ?? 1;
      if (factor === 0) return 0;
      if (factor > 1) score += weight; if (factor < 1) score -= weight;
    }
    return MODIFIER_FROM_SCORE.get(score) ?? 0.25;
  }

  async function getCritters(data) {
    const pokedexMap = new Map();
    const spriteFiles = new Set();
    try {
      const pd = data.personalDex; if (pd && Array.isArray(pd.creatures)) { const start = Number(pd.startId)||1; pd.creatures.forEach((c,idx)=>{ pokedexMap.set(`${c.dbSymbol}#${c.form??0}`, start+idx); if (!pokedexMap.has(c.dbSymbol)) pokedexMap.set(c.dbSymbol, start+idx); }); }
    } catch (e) { console.warn('pokedex parse', e); }

    try {
      (data.spriteEntries || []).forEach((file) => {
        if (file?.name) spriteFiles.add(file.name.toLowerCase());
      });
    } catch (e) { console.warn('sprite list parse', e); }

    const list = [];
    data.pokemonData.forEach((entry) => {
      const forms = Array.isArray(entry.forms) ? entry.forms : [];
      forms.forEach((form, fi) => {
        const key = `${entry.dbSymbol}#${form.form ?? fi}`;
        const type3 = data.type3Map.get(key);
        const front = form.resources?.front || String(entry.id).padStart(3,'0');
        const types = [...new Set([form.type1, form.type2, type3].filter(Boolean))];
        const routeId = (form.form||fi) ? `${entry.dbSymbol}:${form.form ?? fi}` : entry.dbSymbol;
        const spriteGifName = `${front}.gif`.toLowerCase();
        const spritePngName = `${front}.png`.toLowerCase();
        const spriteAvailable = spriteFiles.has(spriteGifName) || spriteFiles.has(spritePngName);
        list.push({ id: entry.id, dbSymbol: entry.dbSymbol, formIndex: form.form ?? fi, routeId, fallbackName: toTitle(entry.dbSymbol), types, evolutions: form.evolutions||[], abilitySymbols: (form.abilities||[]).filter(a=>a && a!=='__undef__' && a!=='none'), stats: { HP: form.baseHp, ATK: form.baseAtk, DEF: form.baseDfe, SPD: form.baseSpd, SATK: form.baseAts, SDEF: form.baseDfs }, spriteGif: `${RAW_BASE}graphics/pokedex/pokefront/${front}.gif`, spritePng: `${RAW_BASE}graphics/pokedex/pokefront/${front}.png`, spriteAvailable, pokedexNumber: pokedexMap.get(key) || pokedexMap.get(entry.dbSymbol) || null });
          // attach a human-friendly form name if provided by the data
          const last = list[list.length-1];
          const fName = form.name || form.formName || form.label || form.formSymbol || (form.form ? `Form ${form.form}` : (fi ? `Form ${fi}` : ''));
          if (last) last.formName = fName;
      });
    });

    return list.sort((a,b)=>{ const pa = a.pokedexNumber ?? Number.MAX_SAFE_INTEGER; const pb = b.pokedexNumber ?? Number.MAX_SAFE_INTEGER; if (pa!==pb) return pa-pb; if (a.id!==b.id) return a.id-b.id; return (a.formIndex||0)-(b.formIndex||0); });
  }

  // Render helpers
  function spriteTag(critter, name, size=96) { return `<img width="${size}" height="${size}" src="${critter.spriteGif}" data-fallback-src="${critter.spritePng}" alt="${escapeHtml(name)} sprite"/>`; }
  function badge(type, typeMap, tables) { const t = typeMap.get(type); const name = escapeHtml(getTypeName(type, typeMap, tables)); const color = sanitizeColor(t?.color); return `<span class="badge" style="background:${color}">${name}</span>`; }
  function multiplierClass(m){ if (m===4) return 'm4'; if (m===3) return 'm3'; if (m===2) return 'm2'; if (m===1) return 'm1'; if (m===0.5) return 'm05'; if (m===0.33) return 'm033'; if (m===0.25) return 'm025'; if (m===0) return 'm0'; return 'm1'; }
  function matchupRow(typeSymbol, multiplier, typeMap, tables) { const display = Number.isInteger(multiplier)?String(multiplier):String(multiplier); return `<li class="matchup-row">${badge(typeSymbol, typeMap, tables)}<span class="mult-chip ${multiplierClass(multiplier)}">x${display}</span></li>`; }

  function formatGender(v){ if (v===1) return t('gender_male'); if (v===2) return t('gender_female'); return t('gender_unknown'); }
  function formatTime(v){ if (v===0) return t('time_day'); if (v===3) return t('time_night'); return `${t('time_slot')} ${v}`; }
  function formatEvolutionCondition(cond){ const v = cond?.value; switch(cond?.type){ case 'minLevel': return `${t('method_level')} ${v}`; case 'stone': return `${t('method_stone')} ${toTitle(v)}`; case 'skill1': return `${t('method_move')} ${toTitle(v)}`; case 'maps': return Array.isArray(v)? v.map(mid=>`${t('method_maps')} ${mid}`).join(', '): `${t('method_maps')} ${v}`; case 'gender': return `${t('method_gender')} ${formatGender(v)}`; case 'dayNight': return `${t('method_time')} ${formatTime(v)}`; default: return `${toTitle(cond?.type||'condition')} ${Array.isArray(v)?v.join(', '):v}`.trim(); } }

  function evolutionRow(evo, critterBySymbol, tables){ const key = evo.form ? `${evo.dbSymbol}#${evo.form}` : evo.dbSymbol; const target = critterBySymbol.get(key) || critterBySymbol.get(evo.dbSymbol); const targetName = target ? getCritterName(target, tables) : toTitle(evo.dbSymbol); const methodText = (evo.conditions||[]).map(c=>formatEvolutionCondition(c)).join(' · '); const sprite = target?`<img width="64" height="64" src="${target.spriteGif}" data-fallback-src="${target.spritePng}" alt="${escapeHtml(targetName)} sprite"/>`:''; const linkId = evo.form ? `${evo.dbSymbol}:${evo.form}`: evo.dbSymbol; return `<li class="evo-row">${sprite}<div class="evo-content"><a class="evo-name" href="critter.html?id=${encodeURIComponent(linkId)}">${escapeHtml(targetName)}</a><div class="evo-method">${escapeHtml(methodText||t('none'))}</div></div></li>`; }

  function emptyList(el){ el.innerHTML = `<li>${escapeHtml(t('none'))}</li>`; }
  function attachFallbackHandlers(scope){ scope.querySelectorAll('img[data-fallback-src]').forEach(img=>{ img.onerror = ()=>{ if (img.dataset.fallback) return; img.dataset.fallback='1'; img.src = img.dataset.fallbackSrc; }; }); }

  function statBarHtml(name, value){ const num = Number(value)||0; const pct = Math.min(100, Math.round((num/255)*100)); const tier = num<60?'low':num<90?'mid':num<130?'high':'max'; return `\n      <div class="stat-row">\n        <span class="stat-name">${escapeHtml(name)}</span>\n        <div class="stat-bar-wrap">\n          <div class="stat-bar" data-tier="${tier}" style="width:${pct}%"></div>\n        </div>\n        <span class="stat-value">${escapeHtml(String(num))}</span>\n      </div>`; }

  // Index
  function renderIndex({ critters, typeMap, tables }){
    const status = document.getElementById('status'); const grid = document.getElementById('critterGrid'); const search = document.getElementById('search'); const typeFilterA = document.getElementById('typeFilterA'); const typeFilterB = document.getElementById('typeFilterB');
    const visible = critters.filter(c=>c.spriteAvailable !== false);
    const selectedA = typeFilterA.value; const selectedB = typeFilterB.value;
    const typeOptions = [...typeMap.entries()].map(([sym,t])=>({symbol:sym,label:getLocalizedCell(tables.typeNames, t.textId, t.fallbackName)})).sort((a,b)=>a.label.localeCompare(b.label));
    typeFilterA.innerHTML = `<option value="">${escapeHtml(t('any_type'))}</option>`; 
    typeFilterB.innerHTML = `<option value="">${escapeHtml(t('any_type2'))}</option>`;
    typeOptions.forEach(tp=>{ typeFilterA.insertAdjacentHTML('beforeend', `<option value="${tp.symbol}">${escapeHtml(tp.label)}</option>`); typeFilterB.insertAdjacentHTML('beforeend', `<option value="${tp.symbol}">${escapeHtml(tp.label)}</option>`); });
    typeFilterA.value=selectedA; typeFilterB.value=selectedB;
      const applyFilters = ()=>{
        const text = search.value.trim().toLowerCase(); const a=typeFilterA.value; const b=typeFilterB.value;
        const filtered = visible.filter(cr=>{ const name = getCritterName(cr,tables); if (text && !name.toLowerCase().includes(text)) return false; if (a && !cr.types.includes(a)) return false; if (b && !cr.types.includes(b)) return false; return true; });
        status.textContent = `${filtered.length} critter(s)`;
        grid.hidden = false;
        grid.innerHTML = filtered.map(cr=>{
          const name = getCritterName(cr,tables);
          const bestiaryNumber = `No. ${String(cr.pokedexNumber ?? cr.id).padStart(3, '0')}`;
          const formLabel = cr.formName ? ` · ${escapeHtml(cr.formName)}` : '';
          const metaBadge = `<span class="badge meta-badge">${escapeHtml(bestiaryNumber)}${formLabel}</span>`;
          return `
              <a class="card" href="critter.html?id=${encodeURIComponent(cr.routeId)}">
                  ${metaBadge}
                ${spriteTag(cr,name)}
                <h2>${escapeHtml(name)}</h2>
                    <div class="badges">${cr.types.map(type=>badge(type,typeMap,tables)).join('')}</div>
              </a>`;
        }).join('');
        attachFallbackHandlers(grid);
      };
    if (!search.dataset.boundFilters){ search.addEventListener('input', applyFilters); typeFilterA.addEventListener('change', applyFilters); typeFilterB.addEventListener('change', applyFilters); search.dataset.boundFilters='1'; }
    applyFilters();
  }

  // Detail
  function renderDetail({ critters, typeMap, abilityMap, tables, critterBySymbol }){
    const params = new URLSearchParams(window.location.search); const idParam = params.get('id')||''; let base=idParam; let formIndex=0; if (idParam.includes(':')){ const p=idParam.split(':'); base=p[0]; formIndex=Number(p[1])||0; }
    const critter = critterBySymbol.get(`${base}#${formIndex}`) || critterBySymbol.get(base);
    const status = document.getElementById('status'); if (!critter){ if (status) status.textContent = t('not_found'); return; }
    // Form selector: show when multiple forms exist for this species
    const forms = critters.filter(c=>c.dbSymbol===base).sort((a,b)=>(a.formIndex||0)-(b.formIndex||0));
    const formContainer = document.getElementById('formSelectContainer');
    if (formContainer) {
      if (forms.length > 1) {
        formContainer.innerHTML = `<select id="formSelect">${forms.map(f=>`<option value="${encodeURIComponent(f.routeId)}"${(f.formIndex===formIndex)?' selected':''}>${escapeHtml(f.formName||`Form ${f.formIndex}`)}</option>`).join('')}</select>`;
        const select = formContainer.querySelector('#formSelect');
        select.addEventListener('change', () => {
          const val = decodeURIComponent(select.value);
          params.set('id', val);
          history.replaceState(null, '', `${location.pathname}?${params.toString()}`);
          // re-render detail for the selected form
          renderDetail({ critters, typeMap, abilityMap, tables, critterBySymbol });
        });
      } else {
        formContainer.innerHTML = '';
      }
    }
    const name = getCritterName(critter,tables); const description = getCritterDescription(critter,tables);
    const bestiaryNumber = `No. ${String(critter.pokedexNumber ?? critter.id).padStart(3, '0')}`;
    const formLabel = critter.formName ? ` · ${critter.formName}` : '';
    document.title = `${name} · Dungeon Critters Bestiary`; document.getElementById('critterName').textContent = name;
    const detailMeta = document.getElementById('detailMeta');
    if (detailMeta) detailMeta.textContent = `${bestiaryNumber}${formLabel}`;
    const heroMeta = document.getElementById('heroMeta');
    if (heroMeta) heroMeta.textContent = `${bestiaryNumber}${formLabel}`;
    const sprite = document.getElementById('critterSprite'); sprite.src = critter.spriteGif; sprite.alt = `${name} sprite`; sprite.onerror = ()=>{ if (sprite.dataset.fallback) return; sprite.dataset.fallback='1'; sprite.src = critter.spritePng; };
    document.getElementById('typeBadges').innerHTML = critter.types.map(t=>badge(t,typeMap,tables)).join('');
    document.getElementById('critterDescription').textContent = description || t('none');
    const abilities = document.getElementById('abilities'); if (!critter.abilitySymbols.length) emptyList(abilities); else abilities.innerHTML = critter.abilitySymbols.map(sym=>getAbilityName(sym, abilityMap, tables)).map(n=>`<li>${escapeHtml(n)}</li>`).join('');
    const bst = Object.values(critter.stats).reduce((a,v)=>a+(Number(v)||0),0);
    document.getElementById('stats').innerHTML = Object.entries(critter.stats).map(([k,v])=>statBarHtml(k,v)).join('') + `<div class="bst-total">${escapeHtml(t('base_stat_total'))}: <strong>${bst}</strong></div>`;

    const evolutionsEl = document.getElementById('evolutions'); const noEvolutionsEl = document.getElementById('noEvolutions'); if (!critter.evolutions || !critter.evolutions.length){ evolutionsEl.innerHTML=''; noEvolutionsEl.hidden=false; noEvolutionsEl.textContent = t('no_evolutions'); } else { noEvolutionsEl.hidden=true; evolutionsEl.innerHTML = critter.evolutions.map(e=>evolutionRow(e,critterBySymbol,tables)).join(''); }

    const weak=[]; const resist=[]; const immune=[]; for (const [attackType] of typeMap.entries()){ const m = calculateModifier(attackType, critter.types, typeMap); if (m===0) immune.push({attackType,multiplier:m}); else if (m>1) weak.push({attackType,multiplier:m}); else if (m<1) resist.push({attackType,multiplier:m}); }
    const noneHtml = `<li>${escapeHtml(t('none'))}</li>`;
    document.getElementById('weaknesses').innerHTML = weak.length ? weak.map(v=>matchupRow(v.attackType,v.multiplier,typeMap,tables)).join('') : noneHtml;
    document.getElementById('resistances').innerHTML = resist.length ? resist.map(v=>matchupRow(v.attackType,v.multiplier,typeMap,tables)).join('') : noneHtml;
    document.getElementById('immunities').innerHTML = immune.length ? immune.map(v=>matchupRow(v.attackType,v.multiplier,typeMap,tables)).join('') : noneHtml;
    if (status) status.hidden = true; document.getElementById('detail').hidden = false; attachFallbackHandlers(document);
  }

  // --- Utilities reused in file ---
  function toTitle(value){ return (value||'').toString().replaceAll('_',' ').replace(/\b\w/g,c=>c.toUpperCase()); }
  function escapeHtml(s){ return (s||'').toString().replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'","&#39;"); }
  function sanitizeColor(v){ return /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(v||'')?v:'#607d8b'; }

  // --- Boot ---
  async function init(){
    applyLang();
    try {
      const data = await loadData();
      TRIPLE_MAIN_TYPE = Boolean(data.maintypeFlag);
      const critters = await getCritters(data);
      const critterBySymbol = new Map();
      critters.forEach(cr=>{ const key = `${cr.dbSymbol}#${cr.formIndex||0}`; critterBySymbol.set(key, cr); if ((cr.formIndex||0)===0 && !critterBySymbol.has(cr.dbSymbol)) critterBySymbol.set(cr.dbSymbol, cr); });
      const typeMap = getTypeData(data.typeData);
      const abilityMap = getAbilityData(data.abilityData);
      const textTables = { pokemonNames: parseLocalizedTable(data.pokemonNamesText), descriptions: parseLocalizedTable(data.descriptionsText), typeNames: parseLocalizedTable(data.typeNamesText), abilityNames: parseLocalizedTable(data.abilityNamesText) };
      const renderArgs = { critters, typeMap, abilityMap, tables: textTables, critterBySymbol };
      const page = document.body.dataset.page;
      if (page==='index'){ initLangToggle(renderIndex, renderArgs); renderIndex(renderArgs); }
      if (page==='detail'){ initLangToggle(renderDetail, renderArgs); renderDetail(renderArgs); }
    } catch (err) { const status = document.getElementById('status'); if (status) status.textContent = `${t('load_error')}: ${err.message}`; }
  }

  // lang toggle wiring
  function applyLang(){ document.documentElement.lang = lang; document.querySelectorAll('[data-i18n]').forEach(el=>{ const s = STRINGS[lang]?.[el.dataset.i18n]; if (s!==undefined) el.textContent = s; }); document.querySelectorAll('[data-i18n-placeholder]').forEach(el=>{ const s = STRINGS[lang]?.[el.dataset.i18nPlaceholder]; if (s!==undefined) el.placeholder = s; }); document.querySelectorAll('.lang-btn').forEach(btn=>{ const active = btn.dataset.lang===lang; btn.classList.toggle('active', active); btn.setAttribute('aria-pressed', String(active)); }); }
  function initLangToggle(renderFn, renderArgs){ document.querySelectorAll('.lang-btn').forEach(btn=>{ btn.addEventListener('click', ()=>{ if (btn.dataset.lang===lang) return; lang = btn.dataset.lang; localStorage.setItem('dmc-lang', lang); applyLang(); if (renderFn && renderArgs) renderFn(renderArgs); }); }); }

  init();
})();
