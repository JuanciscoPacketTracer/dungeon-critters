# Investigación #4: formato seguro de intercambio de partidas

Ticket: #4 (mapa #2). Pregunta: ¿qué esquema estructurado, versionado y validable puede representar de forma segura el estado persistente RMXP/PSDK y sus plugins, sin aceptar ni deserializar `Marshal` no confiable, y qué límites de compatibilidad e importación local debe declarar la v1?

Fuente primaria del mapa: `docs/analisis-tecnico-nube-clasificacion.md` (en adelante, «el análisis»). Código revisado en el commit base `725e6de`. Revisión estática: no se ejecutó el juego ni se abrió ninguna partida real.

Convención: **[Hecho]** = verificado en código o documentación citada. **[Recomendación]** = propuesta de esta investigación, pendiente de aprobación del responsable.

## 1. Resumen

- [Hecho] La partida local es `cabecera "DUNCR"` + `Marshal.dump(PFM.game_state)`; la carga usa `Marshal.load`. La documentación oficial de Ruby dice que `Marshal.load` no debe usarse con datos no confiables y recomienda JSON u otro formato de tipos primitivos.
- [Hecho] El estado no es un árbol de datos simple: son objetos Ruby (`PFM::GameState` con decenas de objetos enlazados), claves compuestas (arrays) y dos tipos con serialización propia (`_dump`/`_load`). Un volcado genérico a JSON no basta.
- [Recomendación] La v1 acepta en el servidor solo un **documento JSON versionado con esquema cerrado** («sobre» `dcsave`) construido por un exportador del cliente, nunca bytes `Marshal`. El servidor lo valida (tamaño, profundidad, esquema, versión) y lo trata como datos opacos validados; no ejecuta nada del contenido.
- [Recomendación] El cliente reconstruye el estado con **adaptadores explícitos y una lista cerrada de tipos**, sin llamar a `Marshal.load` sobre nada que provenga de la red. La importación de partidas `Marshal` locales existentes solo puede hacerse en el cliente, sobre un archivo del propio jugador, dentro de un límite local de confianza/aislamiento (sección 6).
- [Recomendación] Es un paso de alta incertidumbre: la v1 solo debe declararse viable para el subconjunto de estado inventariado y probado con la prueba de ida y vuelta (sección 7). Lo no inventariado se rechaza visiblemente.

## 2. Hechos verificados en el repositorio

| # | Hecho | Fuente |
|---|---|---|
| H1 | `Save.save` hace `clear_states`, `update_save_info`, ejecuta hooks previos, y escribe `save_header` + `encrypt(Marshal.dump(PFM.game_state))`; luego `save_file` y hooks posteriores. | `scripts/psdk_scripts/4_Systems_106_Save_Load.rb:666-676` |
| H2 | `Save.load` comprueba que los primeros bytes coincidan con la cabecera y ejecuta `Marshal.load(encrypt(datos))` sobre el resto; ante error registra «Corrupted save» y devuelve `nil`. No hay comprobación de versión ni de integridad. | `…4_Systems_106_Save_Load.rb:682-693` |
| H3 | `encrypt` es XOR de palabras de 32 bits con `save_key`; si la clave es 0 devuelve los datos tal cual. No es protección criptográfica. | `…4_Systems_106_Save_Load.rb:712-717` |
| H4 | Configuración actual: cabecera `DUNCR`, `saveKey` 0, base `Saves/Critter_Party`, `maximumSave` 0. | `Data/configs/save_config.json:1-7` |
| H5 | `update_save_info` guarda `PSDK_VERSION` y `Configs.infos.game_version` en el entrenador (`$trainer`) y suma `save_count`; son la única información de versión dentro de la partida. | `…4_Systems_106_Save_Load.rb:726-731`; campos en `scripts/psdk_scripts/4_Systems_104_Trainer.rb:162-184` |
| H6 | `save_file` renombra el anterior a `.bak`, escribe y relee; captura `Exception` y solo muestra un mensaje (sin resultado explícito). | `…4_Systems_106_Save_Load.rb:735-745` |
| H7 | Los hooks `BEFORE_SAVE_HOOKS`/`AFTER_SAVE_HOOKS` (`game_map.begin_save/end_save`, `wild_battle.begin_save/end_save`) modifican el estado vivo alrededor del volcado. | `…4_Systems_106_Save_Load.rb:655-659` |
| H8 | `PFM::GameState` se compone mediante tablas de procs registrables (`on_initialize`, `on_player_initialize`, `on_expand_global_variables`); cualquier plugin puede añadir variables de instancia al estado. | `scripts/psdk_scripts/4_Systems_000_General_3_GameState.rb:6-34`, `208-214` |
| H9 | Campos de `GameState` relevantes: `actors`, `game_variables`, `game_switches`, `game_self_switches`, `game_self_variables`, `game_system`, `game_screen`, `game_actors`, `game_party`, `game_map`, `game_player`, `game_temp`, `nuzlocke`, `pathfinding_requests`, `user_data`, `berries`, etc. | `…4_Systems_000_General_3_GameState.rb:35-172` |
| H10 | `Game_Switches` es un `Array` de booleanos con `_dump`/`_load` propios que empaquetan 8 switches por byte. `_load` recibe un string y **no valida** su longitud contra el límite. | `scripts/psdk_scripts/1_RMXP_Scripts.rb:2-46` |
| H11 | `Game_Variables` es un `Array` que solo admite `Integer` (lanza `TypeError` en caso contrario) y devuelve 0 fuera de rango. | `…1_RMXP_Scripts.rb:48-75` |
| H12 | `Game_SelfSwitches` guarda un `Hash` cuyas claves son `Array` (mapa, evento, letra) y valores booleanos. | `…1_RMXP_Scripts.rb:77-96` |
| H13 | `Game_SelfVariables` (marcada `@deprecated` en su comentario pero presente en `GameState`) guarda un `Hash` con claves `Array` y valores arbitrarios (`Object`); `do` admite operaciones aritméticas sobre ellos. | `…1_RMXP_Scripts.rb:2155-2200` |
| H14 | Plugin Crafting añade `@crafting_data = {}` al estado vía `on_player_initialize`/`on_expand_global_variables`. | `scripts/00000 Plugins/00001 Crafting/000_PFM.rb:15-30` |
| H15 | Plugin OverworldEncounters guarda en `$user_data[:scheduled_for_cleanup]` arrays `[event_id, map_id]`; `user_data` es un `Hash` libre accesible a cualquier plugin. | `scripts/00000 Plugins/00006 OverworldEncounters/00000 PokemonNPC.rb:81-95`; `…4_Systems_000_General_3_GameState.rb:155-164` |
| H16 | El proyecto ya usa `Marshal` en otros puntos (caché en `0_Dependencies.rb:784,796,822`; GTS `Marshal.dump`/`Marshal.restore` sobre texto base64 en `4_Systems_901_GTS.rb:792,801`). Estos puntos están fuera del alcance de #4, pero confirman que no debe asumirse que el único `Marshal` expuesto sea el de la partida. | archivos citados |
| H17 | Existen 12 plugins en `scripts/00000 Plugins/` (BattleTypes, Crafting, DMC_TripleTypes, DMC_SummaryRevamp, FogFix, HabitatList, Idle_Animations, OverworldEncounters, Sizes_and_Alpha_Pokemon, Undertale-like Message Sound, ZVBattleMessages, ZVHealingAnimation, summary_nature_arrows). Solo se verificaron en el código los datos persistentes de H14 y H15; **no se inventariaron los demás** (p. ej. plugins con `Data/configs/plugins_*.rxdata` son configuración, no necesariamente estado). | listado de directorio |

## 3. Hechos de fuentes externas

- **Ruby `Marshal`** (documentación oficial, «Security considerations»): `Marshal.load` puede deserializar casi cualquier clase cargada en el proceso, lo que puede dar ejecución remota de código con datos no confiables; no es adecuado como formato general; «nunca deserializar entrada de usuario»; para datos no confiables usar JSON u otro formato de tipos primitivos y nunca dejar que la entrada elija el tipo destino. También documenta que `_dump/_load` y `marshal_dump/marshal_load` permiten lógica de serialización propia. <https://docs.ruby-lang.org/en/3.3/Marshal.html>
- **OWASP Deserialization Cheat Sheet**: los formatos nativos de serialización pueden derivar en DoS, control de acceso o RCE; recomienda un formato de intercambio estándar como JSON para datos no confiables. <https://cheatsheetseries.owasp.org/cheatsheets/Deserialization_Cheat_Sheet.html>
- **RFC 8259 (JSON)**: los nombres de objeto son cadenas (no admite claves tipo array), y para interoperabilidad los números deben mantenerse dentro de la precisión de IEEE 754 doble (enteros seguros hasta 2^53−1); los nombres de miembro duplicados dan comportamiento impredecible. <https://www.rfc-editor.org/rfc/rfc8259> (secciones 4 y 6)
- Nota de versión: la doc de Ruby consultada es la 3.3; RMXP/RGSS104E y PSDK usan una versión de Ruby distinta y antigua. No se verificó la versión exacta de Ruby de este proyecto ni diferencias en el comportamiento de `Marshal`; la advertencia general se mantiene para cualquier versión.

## 4. Análisis: por qué no basta «convertir a JSON»

[Hecho, derivado de H8-H15] Obstáculos concretos:

1. **Claves compuestas**: `Game_SelfSwitches`/`Game_SelfVariables` usan arrays como claves; JSON solo permite cadenas (RFC 8259).
2. **Valores arbitrarios**: `game_self_variables`, `user_data` y `crafting_data` son `Hash` libres; no hay un inventario de tipos reales.
3. **Objetos enlazados**: `GameState` expone mediante `expand_global_var` referencias compartidas (`$actors`, `$user_data`…); `Game_Map.begin_save` retira datos reconstruibles.
4. **Extensibilidad**: cualquier plugin puede añadir estado (H8) sin registro de esquema; `Marshal` lo capturaba automáticamente, un esquema cerrado no.
5. **Tipos con `_dump/_load` propios** (H10): el formato intermedio debe sustituirlos por listas de booleanos, no copiar los bytes.

## 5. Recomendación: esquema v1

Todo lo de esta sección es **[Recomendación]**.

### 5.1 Sobre del documento

```jsonc
{
  "format": "dungeon-critters.save",   // constante
  "format_version": 1,                  // entero; solo se acepta un conjunto cerrado
  "game_version": "<Configs.infos.game_version>",   // exacta, ver §6
  "psdk_version": "<PSDK_VERSION>",
  "slot": 1,
  "save_count": 42,                     // de game_system.save_count
  "plugins": { "crafting": 1, "overworld_encounters": 1 },  // id de adaptador -> versión de esquema
  "summary": { /* §5.3, derivado y validado por separado */ },
  "state": { /* §5.2 */ }
}
```

Reglas del sobre: UTF-8, objeto raíz, **claves desconocidas = rechazo** (`additionalProperties: false`), sin claves duplicadas, enteros dentro de ±(2^53−1), tamaño máximo y profundidad máxima declarados. Validación con JSON Schema (draft 2020-12) o validador equivalente propio, con el esquema versionado junto al juego. El esquema es la fuente de verdad del formato; el servidor y el cliente lo comparten.

### 5.2 Representación del estado (adaptadores explícitos)

| Subsistema | Representación propuesta |
|---|---|
| `game_switches` | Lista de booleanos o de IDs activos más tamaño total; longitud ≤ límite declarado. |
| `game_variables` | Lista de enteros (H11 garantiza `Integer`), longitud acotada. |
| `game_self_switches` | Lista de objetos `{map, event, switch, value}` con enteros y letra A-D; reversible a la clave array (H12). No usar objetos JSON con claves de texto compuestas. |
| `game_self_variables` | Lista `{map, event, var, value}` con `value` restringido a un unión cerrada `{int, string, bool, null}` **solo tras inventariar los tipos reales**; todo otro tipo = rechazo. |
| Entrenador, dinero, medallas, tiempo | Objetos con campos escalares tipados y rangos. |
| Critters, bestiario, inventario, misiones | Un adaptador por clase PFM con campos explícitos; IDs de base de datos validados contra el rango y versión del juego. |
| Mapa/jugador/seguidores | Mapa, x, y, dirección y datos que el flujo local conserva; el resto se reconstruye del juego instalado (el análisis §2.4/§6.1 lo exige distinguir). |
| `user_data`, plugins | **Lista blanca** por clave conocida, cada una con su adaptador y versión; claves desconocidas = rechazo, nunca descarte silencioso (coherente con el análisis §5.3). |
| Intérpretes/fibras, `game_temp`, procs | **Fuera del formato**: no se serializan (temporal/no reanudable; H1 ya los limpia con `clear_states`). |

### 5.3 Resumen separado

Objeto pequeño (nombre público, medallas, hitos, especies capturadas, tiempo, ubicación, versión). Es un dato declarado por el cliente: el servidor valida rango y coherencia pero no lo considera verificado (análisis §7.3, clasificación casual).

### 5.4 Seguridad del servidor y del cliente

- El servidor solo analiza JSON con límite de tamaño, y no ejecuta código ni carga clases. Si guarda el documento como blob, es opaco.
- Integridad (hash/firma) es **adicional** y no sustituye la validación (el análisis §5.2 punto 4 lo afirma para `Marshal`; aquí además evita tratar un blob firmado como confiable).
- El cliente que descarga: valida esquema → valida versión → construye un `PFM::GameState` nuevo mediante adaptadores (constructores y asignaciones explícitas de tipos permitidos) → solo entonces reemplaza el estado, conservando la copia local (análisis §6.3).
- Prohibido: `Marshal.load`, `YAML.load` con objetos, `eval`, `JSON.create_additions`/`object_class` personalizado sobre datos de la red.

## 6. Límites de compatibilidad e importación que debe declarar la v1

**[Recomendación]**, alineado con las notas del mapa #2 (Windows, RMXP/PSDK, misma versión del juego, local primero):

1. **Plataforma**: solo instalaciones Windows RMXP/PSDK de este proyecto.
2. **Versión**: la restauración remota exige `game_version` y `psdk_version` **idénticas** a las del documento; si no coinciden, se rechaza visiblemente con aviso. Sin migraciones entre versiones en v1 (queda abierto en el mapa, «Not yet specified»).
3. **Formato**: solo `format_version` 1; versiones desconocidas se rechazan, sin interpretar parcialmente.
4. **Plugins**: se soportan solo los plugins con adaptador y prueba declarados; la lista efectiva se calcula tras el inventario de H17. Un plugin con estado sin adaptador bloquea la subida (visible), no se omite.
5. **No soportado**: partidas de otros proyectos RMXP, `Data/*.rxdata` (no son partidas; análisis §2.3), reanudación a mitad de evento/intérprete, partidas creadas con otra clave `saveKey` o cabecera.
6. **Límites**: tamaño máximo del documento, profundidad máxima, tamaño máximo de listas (switches/variables acotados por `$data_system`), enteros ≤ 2^53−1. Los valores concretos están **sin determinar**: deben medirse con partidas reales (ninguna se leyó aquí).
7. **Importación de partidas `Marshal` locales existentes**: [Recomendación firme] solo puede ocurrir **en el cliente, en una operación local explícita, sobre un archivo del propio jugador dentro de un límite de confianza/aislamiento local** (proceso aislado o conversión mediante el mismo juego/versión). Nunca en el servidor, nunca sobre bytes descargados o recibidos, nunca como sustituto de la descarga. El archivo local solo es de confianza si lo escribió el propio juego en el equipo del jugador; un archivo obtenido de terceros es tan no confiable como uno de la red. La conversión no elimina el riesgo durante la lectura inicial (análisis §5.3). El exportador debe validar su salida contra el esquema antes de subirla, y el proceso debe conservar el archivo original (`.bak` incluido) sin modificarlo.
8. **Estado de captura**: la instantánea la toma un único punto que reutiliza el guardado confirmado (análisis §6.2); H6 muestra que hoy no hay resultado explícito, lo cual es precondición de implementación, no parte del formato.

## 7. Verificación requerida antes de afirmar viabilidad

No realizada en esta investigación (solo lectura estática):

1. Inventariar tipos reales en `game_self_variables`, `user_data`, `crafting_data` y los demás plugins (H13, H15, H17).
2. Prueba de ida y vuelta con partidas de prueba controladas (matriz 11.1 del análisis): exportar → validar → reconstruir → comparar valores y comportamiento.
3. Medir tamaños para fijar los límites del punto 6.
4. Confirmar la versión de Ruby del entorno y que el parser JSON disponible rechaza claves duplicadas/profundidad excesiva o, si no, añadir esas comprobaciones.
5. Pruebas con documentos hostiles (campos extra, tipos erróneos, listas enormes, enteros fuera de rango, versión falsa).

## 8. Brechas e incertidumbres

- No se encontró documentación del formato de `Marshal` de RGSS104E específica del proyecto; la advertencia se toma del manual de Ruby (3.3).
- No se localizó ningún inventario formal del estado persistente; la tabla de §5.2 es una propuesta basada en la lectura de los archivos citados.
- No se analizaron los puntos `Marshal` de GTS y caché (H16) más allá de su existencia.
- No se evaluaron alternativas binarias (MessagePack, CBOR, Protobuf); JSON se elige por la recomendación oficial de Ruby y OWASP y por estar disponible en el cliente (el cliente HTTP ya usa JSON, análisis §2.1). Cualquier alternativa necesitaría el mismo esquema cerrado.
