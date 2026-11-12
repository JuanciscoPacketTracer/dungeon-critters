# Análisis técnico y plan de implementación: guardado en la nube y clasificación

> **Estado:** propuesta de diseño basada en una revisión estática del repositorio. No se ha comprobado el funcionamiento de un servidor externo ni se han realizado pruebas de integración.

## 1. Objetivo

Permitir que cada jugador:

- Cree una cuenta e inicie sesión desde otro dispositivo.
- Guarde y recupere su partida completa desde la nube.
- Consulte una clasificación que priorice las medallas y considere el progreso de la aventura y el Bestiario.

El sistema debe conservar la posibilidad de jugar y guardar localmente cuando no haya conexión.

## 2. Estado actual del proyecto

### 2.1 Capacidades reutilizables

- [Online::HttpClient](../scripts/psdk_scripts/0_Dependencies.rb) proporciona solicitudes HTTP con JSON, tiempos de espera y soporte HTTPS.
- [GamePlay::Save](../scripts/psdk_scripts/4_Systems_106_Save_Load.rb) serializa el estado de la partida y puede devolver los datos sin escribir un archivo.
- [PFM::GameState](../scripts/psdk_scripts/4_Systems_000_General_3_GameState.rb) contiene el estado necesario para restaurar el juego: equipo, mapa, jugador, variables, interruptores y otros sistemas.
- [PFM::Trainer](../scripts/psdk_scripts/4_Systems_104_Trainer.rb) dispone de nombre, tiempo jugado y medallas.
- [PFM::Pokedex](../scripts/psdk_scripts/4_Systems_101_Dex.rb) registra criaturas vistas y capturadas.
- [PFM::Quests](../scripts/psdk_scripts/4_Systems_800_Quest.rb) conserva misiones activas, terminadas y fallidas.

### 2.2 Funcionalidades que faltan

No se identificaron en el código revisado:

- Autenticación de cuentas mediante credenciales recuperables.
- Subida o descarga de partidas en la nube.
- Resolución de conflictos entre partidas locales y remotas.
- Almacenamiento y consulta de clasificaciones.
- Interfaces de cuenta, sincronización o clasificación.

El cliente online está configurado actualmente para conectarse a `localhost` en [Online::Config](../scripts/psdk_scripts/0_Dependencies.rb). Antes de la implementación debe confirmarse si existe un servidor compatible fuera del repositorio y qué funcionalidades ofrece.

**Incidencia a investigar:** `PlayerManager#register` llama a `set_player_id` en [0_Dependencies.rb](../scripts/psdk_scripts/0_Dependencies.rb), pero no se encontró su definición en los scripts revisados. No debe asumirse que el registro actual funciona de extremo a extremo.

### 2.3 Motor RPG Maker XP y formato de partida usado aquí

El proyecto contiene configuración de RPG Maker XP: [Game.ini](../Game.ini) referencia `RGSS104E.dll` y `Data/Scripts.rxdata`. El arranque Ruby de [Game.rb](../Game.rb), sin embargo, carga PSDK; las clases compatibles con RMXP y las extensiones del motor están en [1_RMXP_Scripts.rb](../scripts/psdk_scripts/1_RMXP_Scripts.rb) y [4_Systems_003_Map_Engine.rb](../scripts/psdk_scripts/4_Systems_003_Map_Engine.rb). El diseño debe seguir el comportamiento de **esta combinación de RMXP y PSDK**, no asumir que es un guardado estándar de una instalación genérica de RPG Maker XP.

El formato local observado es propio del flujo PSDK:

- [save_config.json](../Data/configs/save_config.json) configura cabecera `DUNCR`, `saveKey: 0`, nombre base `Saves/Critter_Party` y `maximumSave: 0`; en [GamePlay::Save](../scripts/psdk_scripts/4_Systems_106_Save_Load.rb) ese cero significa ranuras ilimitadas.
- Para varias ranuras, el nombre se construye con el patrón `base-número`; el código elige la primera raíz disponible y escribible entre el directorio actual, `APPDATA` o la carpeta personal, por lo que la ruta efectiva depende del entorno. Hay un archivo `.bak` asociado a la escritura local.
- `Save.save` genera la cabecera seguida de `Marshal.dump(PFM.game_state)`, aplicando la transformación configurada por `saveKey`. En la configuración actual esa clave es cero, por lo que no se aplica dicha transformación. Si se configura una clave distinta, la operación implementada es XOR, no una protección criptográfica adecuada.
- Los archivos `.rxdata` de `Data`, como `Scripts.rxdata`, son datos y scripts del proyecto; **no deben confundirse con las partidas PSDK ni subirse en lugar de ellas**. La compatibilidad con partidas estándar de otros proyectos RMXP no está demostrada.
- La carga comprueba la cabecera y deserializa el estado. Las versiones del juego y de PSDK se registran en el entrenador al guardar, pero debe investigarse y probarse la compatibilidad efectiva entre versiones y cambios de plugins.

### 2.4 Estado persistente, switches y eventos

El objeto raíz `PFM::GameState` no solo contiene el equipo y los datos del jugador. Sus inicializadores y `expand_global_var` enlazan numerosos objetos con las variables globales que usan los eventos. Las extensiones también pueden registrar sus propios datos, como hace [Crafting](../scripts/00000%20Plugins/00001%20Crafting/000_PFM.rb).

| Estado | Comportamiento observado y requisito para la nube |
|---|---|
| Switches globales | `game_switches` se expone como `$game_switches`; `Game_Switches` implementa serialización compacta propia. Conservar los valores por ID, incluidos `false`, y restaurarlos antes de reconstruir páginas de eventos. |
| Variables globales | `game_variables` se expone como `$game_variables`; en esta implementación `Game_Variables` admite números enteros. Conservar IDs, valores, valores por defecto y semántica de acceso fuera de rango. |
| Switches locales | `game_self_switches` se expone como `$game_self_switches`, con claves de evento. Preservar la identidad completa de mapa, evento y switch, también entre mapas; no convertir claves de arrays a cadenas sin una representación reversible. |
| Variables locales | `game_self_variables` es una extensión del proyecto con claves de mapa, evento y variable; sus valores pueden ser objetos. Inventariar tipos reales y definir adaptadores validados que preserven claves y tipos, en vez de asumir que todas son enteros o cadenas. |
| Sistema y jugador | `game_system`, `game_player`, `game_map`, `game_actors`, `game_party`, `game_screen` y `game_temp` forman parte del estado. Identificar qué datos son persistentes, derivados o temporales; preservar temporizador, restricciones, posición y dirección cuando corresponda. |
| Eventos y mapa | Las páginas de `Game_Event` se seleccionan según sus condiciones. `Game_Map.begin_save` guarda información seleccionada de eventos del mapa actual y seguidores, y retira datos reconstruibles del mapa; `setup` vuelve a cargar las definiciones y recrear eventos. No equivale a serializar íntegramente cada evento vivo. |
| Eventos eliminados | `Game_Event#erase` modifica el evento vivo; el sistema de entorno también dispone de estados de eliminación por mapa y evento. Verificar por separado los casos temporales y persistentes; no asumir que todo evento borrado permanece borrado tras cargar. |
| Intérpretes y procesos | `Game_System` mantiene intérpretes de mapa y combate; los eventos paralelos pueden tener intérpretes propios. El intérprete mantiene índices, ramas, esperas, hijos y puede usar fibras. Qué se reanuda o reinicia depende del flujo de guardado y carga; no prometer continuidad arbitraria a mitad de una secuencia sin pruebas. |

La evidencia de las estructuras y del intérprete está en [1_RMXP_Scripts.rb](../scripts/psdk_scripts/1_RMXP_Scripts.rb), la agregación en [4_Systems_000_General_3_GameState.rb](../scripts/psdk_scripts/4_Systems_000_General_3_GameState.rb), el ciclo de eventos en [4_Systems_003_Map_Engine.rb](../scripts/psdk_scripts/4_Systems_003_Map_Engine.rb) y el estado de eliminación persistente en [4_Systems_202_Environment.rb](../scripts/psdk_scripts/4_Systems_202_Environment.rb).

## 3. Alcance y decisiones propuestas

| Aspecto | Propuesta inicial |
|---|---|
| Modalidad | Juego local con sincronización opcional. |
| Identidad | Cuenta independiente del ID del entrenador y de la partida. |
| Guardado | Partida completa, con resumen separado para mostrar información y alimentar la clasificación. |
| Ranuras | Mantener la compatibilidad con las ranuras locales existentes; asociar cada copia remota a una cuenta y una ranura. |
| Conflictos | Preguntar al jugador cuando existan cambios incompatibles; nunca sobrescribir automáticamente una versión divergente. |
| Clasificación | Casual inicialmente, con medallas como criterio principal. |
| Disponibilidad | Si falla la red, conservar la partida local y señalar que la copia está pendiente. |

Estas decisiones son una base para el diseño; deben confirmarse antes de cerrar los contratos y la interfaz.

## 4. Arquitectura propuesta

```text
                    JUEGO
  ┌──────────────────────────────────────────┐
  │ Cuenta y sesión                          │
  │ Guardado/carga local                     │
  │ Sincronización de partidas               │
  │ Pantalla de clasificación                │
  └───────────────────┬──────────────────────┘
                      │ HTTPS
  ┌───────────────────▼──────────────────────┐
  │ API del servidor                         │
  │ - Autenticación y autorización           │
  │ - Versiones de partidas                  │
  │ - Validación de resúmenes                │
  │ - Consulta de clasificación              │
  └───────────┬──────────────────┬───────────┘
              │                  │
  ┌───────────▼────────┐  ┌──────▼─────────────┐
  │ Base de datos      │  │ Almacenamiento de  │
  │ cuentas, metadatos │  │ versiones de saves │
  │ y clasificación    │  │                    │
  └────────────────────┘  └────────────────────┘
```

La API debe controlar el acceso a cada partida por cuenta autenticada. La base de datos puede almacenar los archivos de partida para una primera versión si su tamaño y volumen lo permiten; el almacenamiento de objetos es una alternativa cuando se necesite escalar.

## 5. Identidad, cuentas y seguridad

### 5.1 Cuenta de jugador

Desarrollar:

- Registro e inicio de sesión.
- Emisión y renovación de sesiones.
- Cierre de sesión.
- Recuperación de acceso mediante un mecanismo apropiado para el servicio elegido.
- Vinculación explícita entre una cuenta y una o varias ranuras de partida.

El ID del entrenador no debe utilizarse como prueba de identidad: se genera dentro de la partida y es modificable. Una clave compartida incluida en el juego tampoco es un secreto ni sustituye la autenticación individual.

Las contraseñas, si se utilizan, deben almacenarse en el servidor mediante un algoritmo de hash para contraseñas adecuado, nunca en texto plano. Las sesiones deben tener vencimiento y el cliente debe almacenarlas mediante un mecanismo apropiado para cada plataforma.

### 5.2 Seguridad de las partidas

El guardado actual utiliza `Marshal.load` en [GamePlay::Save.load](../scripts/psdk_scripts/4_Systems_106_Save_Load.rb). **No es seguro deserializar datos `Marshal` no confiables**. En particular, una copia subida por un cliente puede estar manipulada; que el servidor la almacene, firme o devuelva no la convierte automáticamente en segura.

Se propone:

1. Investigar un **formato de intercambio estructurado y versionado**, con validación estricta, que permita reconstruir el estado necesario sin deserializar objetos arbitrarios.
2. Mantener el formato local existente mientras se desarrolla y verifica la conversión.
3. Tratar los archivos recibidos como datos no confiables, limitar su tamaño y validar su esquema y versión.
4. Si se considera reutilizar el archivo `Marshal` como copia binaria en una primera etapa, documentar expresamente el riesgo y resolver el modelo de confianza antes de habilitar su descarga y carga automática. **Autenticación e integridad por sí solas no eliminan ese riesgo.**

La conversión completa del estado es una de las tareas de mayor incertidumbre del proyecto, especialmente por los datos de plugins y eventos.

### 5.3 Estrategia de compatibilidad para RMXP y PSDK

Un formato seguro no puede limitarse a convertir el objeto raíz a JSON: el estado contiene instancias Ruby, referencias entre objetos, claves compuestas y valores específicos de extensiones. Diseñar un esquema versionado con adaptadores explícitos para cada subsistema y plugin, tipos permitidos, referencias reconstruibles y migraciones; rechazar datos o versiones no compatibles de manera visible, sin descartar campos silenciosamente. Antes de asumir que esto es viable para todos los casos, construir una prueba de ida y vuelta con partidas representativas y comparar su comportamiento.

La importación de una partida local existente también debe tratarse como una operación sensible: el formato local usa `Marshal.load`. La conversión no debe deserializar archivos arbitrarios en el servidor. Investigar un proceso de importación confiable o aislado, con límites y advertencias, y no afirmar que la conversión por sí sola elimina el riesgo durante la lectura inicial.

## 6. Diseño del guardado en la nube

### 6.1 Contenido

La copia debe permitir restaurar el estado completo, no únicamente los datos visibles en la propuesta. Como mínimo debe preservar:

- Nombre, ubicación, tiempo jugado, dinero y medallas.
- Equipo de Critters, atributos, movimientos y objetos asociados.
- Bestiario y registros de captura.
- Inventario y Critters almacenados.
- Misiones, variables, interruptores y estado de eventos.
- Datos requeridos por los plugins activos.
- Versión del juego, versión del formato y ranura.

Por separado se almacenará un **resumen de partida** para mostrar información sin cargar toda la copia.

El inventario detallado debe incluir los elementos de la sección 2.4, datos de entorno, seguidores, rutas y posiciones de eventos que el flujo local conserva, además de los datos agregados por plugins. Debe distinguir datos guardados de datos que el motor reconstruye desde la versión instalada de mapas, eventos y recursos.

### 6.2 Flujo de guardado

1. El jugador guarda mediante el flujo local existente.
2. El juego confirma el resultado del guardado local.
3. Si hay una sesión activa y la ranura está vinculada, prepara una instantánea de esa misma versión y la envía en segundo plano.
4. El servidor valida autenticación, tamaño, formato y versión esperada de la copia remota.
5. El servidor guarda una nueva versión y confirma su identificador.
6. El juego muestra uno de estos estados: **sincronizado**, **pendiente**, **conflicto** o **error**.

No debe mostrarse un mensaje de éxito en la nube antes de recibir confirmación del servidor. El guardado local y el remoto deben comunicar sus resultados por separado.

**Integración concreta:** `Save.save` limpia estados temporales, incrementa el contador de guardados, actualiza el tiempo y ejecuta hooks antes y después de serializar. `Game_Map.begin_save` retira temporalmente datos del mapa y `end_save` los repone. Por tanto, no llamar de nuevo a `Save.save(..., true)` solo para obtener bytes tras otro guardado: repetiría esos efectos. Diseñar un único punto de captura que reutilice la instantánea del guardado confirmado, sin acceder en segundo plano a objetos vivos del mapa y garantizando la restauración de los hooks incluso si ocurre un error.

El método actual `save_file` captura excepciones y muestra un mensaje, mientras `Save.save` devuelve los datos y la escena marca el guardado como realizado. **No existe en ese flujo una confirmación fiable de éxito que deba suponerse disponible**: el trabajo de implementación debe introducir o exponer un resultado explícito y probado antes de programar la subida. También debe cubrir las llamadas directas a `GamePlay::Save.save`, como las de [2_PSDK_Event_Interpreter.rb](../scripts/psdk_scripts/2_PSDK_Event_Interpreter.rb) y [GTS](../scripts/psdk_scripts/4_Systems_901_GTS.rb), no solo el botón del menú. Respetar las restricciones de guardado y definir puntos seguros para no interrumpir eventos o escenas.

### 6.3 Flujo de recuperación

1. Desde el menú de carga, el jugador inicia sesión.
2. El juego consulta las ranuras remotas y muestra sus resúmenes.
3. Al seleccionar una, descarga una versión concreta.
4. Valida formato, integridad y compatibilidad antes de reemplazar ningún archivo local.
5. Si existe una partida local divergente, solicita confirmación y conserva una copia recuperable.
6. Restaura la partida utilizando un flujo compatible con la inicialización de mapa, variables y sistemas de [GamePlay::Load](../scripts/psdk_scripts/4_Systems_106_Save_Load.rb).

En particular, la carga existente expande las variables globales, carga parámetros, reconstruye el mapa y la posición del jugador, refresca la party, restaura audio, tiempo y pathfinding, y actualiza otros sistemas. La integración debe reutilizar o reproducir esta secuencia de manera controlada y comprobar que las condiciones de páginas se evalúan con el estado restaurado. No basta con asignar coordenadas o escribir valores en `$game_switches`.

### 6.4 Conflictos y versiones

Cada ranura remota debe tener un identificador de versión. Al sincronizar, el cliente enviará la versión remota de la que partió:

- Si coincide con la versión vigente, el servidor acepta la nueva copia.
- Si no coincide, devuelve un conflicto sin sobrescribir datos.
- El jugador puede elegir conservar la versión local o recuperar una versión remota, tras ver fecha y resumen de cada una.

Las fechas son informativas; el control de conflictos debe basarse en versiones, no en el reloj del dispositivo. El servidor debe conservar un número configurable de versiones anteriores y aplicar una política de retención documentada.

## 7. Diseño de la clasificación

### 7.1 Criterios propuestos

Para asegurar que las medallas siempre tengan prioridad, se propone una **clasificación por orden de criterios**, en lugar de una fórmula ponderada cuyos valores podrían permitir que otros factores superen a una medalla:

1. Número de medallas obtenidas.
2. Número de hitos principales de aventura completados.
3. Número de especies capturadas registradas en el Bestiario.
4. Desempate estable definido por el servidor.

Este orden es una propuesta. Antes de implementarlo deben acordarse los hitos válidos y si se consideran especies vistas o capturadas. El código ya distingue ambos contadores en [PFM::Pokedex](../scripts/psdk_scripts/4_Systems_101_Dex.rb).

Si se desea mostrar una puntuación numérica, se deberá definir su fórmula y sus límites explícitamente; la tabla no necesita una cifra única para poder ordenar a los jugadores.

### 7.2 Actualización

Tras aceptar una versión de partida, el servidor:

1. Recibe o deriva los datos de clasificación asociados a esa versión.
2. Valida rangos y coherencia conocidos.
3. Actualiza el registro de clasificación conforme a la política elegida.
4. Expone la tabla de forma paginada.

Debe decidirse si la clasificación representa **el estado de la última partida sincronizada** o **el mejor resultado histórico**. La diferencia es importante cuando un jugador restaura una versión anterior.

### 7.3 Integridad competitiva

Una clasificación alimentada por datos de un cliente modificable **no puede garantizar que el progreso sea legítimo**. Validar rangos y calcular el orden en el servidor dificulta errores y manipulaciones evidentes, pero no demuestra que las medallas o capturas se hayan obtenido jugando.

Para una versión competitiva sería necesario diseñar verificación adicional, por ejemplo registrar hitos mediante eventos validados por el servidor y definir un modelo de autoridad sobre el progreso. La primera versión debe presentarse como clasificación casual si no cuenta con esas garantías.

## 8. API y modelo de datos propuestos

Los nombres definitivos pueden adaptarse al servidor existente, si se identifica uno.

### 8.1 Operaciones de API

| Operación | Finalidad |
|---|---|
| `POST /auth/register` | Crear una cuenta. |
| `POST /auth/login` | Iniciar sesión. |
| `POST /auth/logout` | Cerrar o invalidar una sesión. |
| `GET /saves` | Listar ranuras y metadatos de la cuenta. |
| `GET /saves/:slot` | Obtener una versión concreta de una partida. |
| `POST /saves/:slot/versions` | Crear una nueva versión con control de concurrencia. |
| `GET /leaderboard` | Consultar la clasificación paginada. |

Las operaciones de recuperación de cuenta, renovación de sesión y consulta de versiones históricas deberán detallarse al seleccionar el mecanismo de identidad y la política de retención.

### 8.2 Entidades principales

- **Cuenta:** identificador estable, credenciales o vínculo con proveedor de identidad, estado y fechas.
- **Sesión:** cuenta, vencimiento y datos necesarios para su revocación.
- **Ranura:** cuenta propietaria, identificador de ranura y versión vigente.
- **Versión de partida:** formato, versión del juego, fecha del servidor, tamaño, comprobación de integridad, referencia a los datos y resumen.
- **Clasificación:** cuenta o perfil público, criterios, versión de partida asociada y fecha de actualización.

La aceptación de una partida y la actualización de su resumen de clasificación deben diseñarse para evitar inconsistencias ante fallos parciales. Las peticiones repetidas por reintentos deben ser idempotentes o utilizar una clave de idempotencia.

## 9. Cambios previstos en el cliente

| Área | Trabajo propuesto |
|---|---|
| Red | Extender el cliente HTTP con sesión, cabeceras de autorización y manejo explícito de errores. Usar HTTPS en el despliegue. |
| Cuenta | Añadir pantallas de registro, inicio y cierre de sesión y recuperación de acceso. |
| Guardado | Integrar la preparación y subida de una instantánea tras un guardado local confirmado. |
| Carga | Añadir listado, descarga, validación y restauración de copias remotas. |
| Sincronización | Gestionar estados, reintentos y conflictos por ranura. |
| Clasificación | Añadir pantalla con posiciones, nombre público, medallas, progreso y Bestiario. |
| Experiencia | Ejecutar la red sin bloquear el bucle principal, mostrar actividad y permitir cancelar cuando corresponda. |
| Motor y eventos | Conservar el ciclo de hooks de guardado, restaurar globales antes de reconstruir el mapa y respetar las restricciones y los puntos seguros del motor. |
| Adaptadores | Versionar y validar switches, variables locales, referencias y estado de plugins; mantener migraciones para cambios de IDs y esquemas. |

El cliente HTTP actual es síncrono. Existen ejemplos de llamadas en hilos en [Mystery Gift](../scripts/psdk_scripts/4_Systems_960_MysteryGift.rb), pero deberá diseñarse cuidadosamente el paso de resultados al hilo principal y evitar modificar el estado del juego concurrentemente mientras se construye una instantánea.

## 10. Plan por fases

### Fase 1. Descubrimiento y decisiones

- Confirmar si existe un servidor online externo y revisar sus contratos y despliegue.
- Inventariar el contenido real de las partidas y los datos de plugins.
- Documentar el contrato real de `GameState`, hooks, intérpretes, eventos, estados de entorno y datos reconstruidos desde los mapas; inventariar IDs y tipos usados por switches y variables.
- Identificar todos los puntos de guardado, restricciones y efectos secundarios; comprobar cómo informar de errores locales antes de sincronizar.
- Reproducir e investigar el flujo actual de registro, incluida la llamada a `set_player_id`.
- Definir plataforma objetivo, política de cuentas, ranuras y clasificación.
- Evaluar formatos de intercambio seguros y migración de partidas existentes.

**Resultado:** contratos y decisiones de seguridad aprobados; riesgos y compatibilidad documentados.

### Fase 2. Identidad e infraestructura

- Implementar o integrar el servicio de cuentas y sesiones.
- Configurar HTTPS, base de datos y almacenamiento persistente.
- Implementar autorización por cuenta, límites de tamaño y registro de errores.
- Crear interfaces de inicio y cierre de sesión.

**Resultado:** un usuario puede acceder a su cuenta desde dos dispositivos sin depender del ID de una partida local.

### Fase 3. Guardado y recuperación

- Implementar el formato de intercambio o la solución de seguridad aprobada.
- Implementar adaptadores y migraciones probados para el estado RMXP/PSDK y plugins; no publicar la recuperación si no se preserva el comportamiento de eventos soportado.
- Crear API de ranuras y versiones.
- Integrar subida, descarga y restauración con el sistema local.
- Añadir indicadores de estado, reintentos, copias anteriores y resolución de conflictos.

**Resultado:** una partida se guarda, se recupera en otro dispositivo y continúa sin pérdida de estado.

### Fase 4. Clasificación

- Definir el catálogo de hitos y la regla de orden.
- Generar y validar el resumen vinculado a cada versión.
- Implementar almacenamiento y consulta paginada.
- Añadir pantalla de clasificación y gestión de errores.

**Resultado:** la tabla refleja la política acordada y ordena siempre primero por medallas.

### Fase 5. Pruebas y despliegue

- Probar el recorrido completo en los dispositivos y versiones soportados.
- Ejecutar la matriz de continuidad de eventos y compatibilidad de partidas de la sección 11.1.
- Ejecutar pruebas de seguridad, recuperación, fallos de red y carga concurrente.
- Preparar monitorización, copias de seguridad del servidor y procedimientos de recuperación.
- Desplegar inicialmente a un grupo reducido antes de habilitarlo para todos.

## 11. Criterios de aceptación

La implementación se considerará lista cuando, como mínimo:

1. Una cuenta pueda iniciar sesión en un segundo dispositivo y recuperar una partida.
2. Una prueba de ida y vuelta conserve ubicación, tiempo, dinero, medallas, Bestiario, equipo, inventario, misiones y datos relevantes de plugins.
3. Un fallo de red no destruya el guardado local ni se muestre como sincronización exitosa.
4. Dos dispositivos con cambios divergentes produzcan un conflicto sin pérdida silenciosa de datos.
5. Una cuenta no pueda consultar ni descargar partidas de otra.
6. Una partida dañada, incompatible o de formato no permitido no se cargue ni sobrescriba silenciosamente una copia válida.
7. La clasificación respete el orden definido, incluidos los empates y la paginación.
8. Se haya verificado el comportamiento al restaurar versiones anteriores y al repetir solicitudes por fallos de red.
9. Exista un procedimiento probado de respaldo y recuperación del servicio.

### 11.1 Matriz de pruebas específica de RPG Maker XP y PSDK

Para cada caso, comparar una carga local de referencia con una restauración en la nube de la misma instantánea, en una instalación limpia y con la misma versión del juego. Comprobar tanto los valores como el comportamiento posterior:

| Caso | Verificación |
|---|---|
| Switches y variables globales | Activar y desactivar switches, usar valores enteros distintos y verificar que las condiciones, puertas y diálogos se comportan igual al volver a cargar. |
| Switches locales | Modificar switches locales de varios eventos, incluidos eventos con el mismo ID en mapas diferentes; comprobar páginas, cofres y diálogos sin contaminación entre claves. |
| Variables locales | Guardar valores y tipos realmente usados por los eventos y plugins; verificar identidad de mapa/evento/variable y operaciones posteriores. |
| Mapa y jugador | Confirmar mapa, posición, dirección, altura cuando aplique, tránsito y reconstrucción de recursos; verificar mapas enlazados con MapLinker. |
| Eventos y seguidores | Mover eventos y seguidores, guardar y comprobar posición, dirección, ruta y comportamiento conservado por el flujo local. Probar también eventos borrados temporalmente y eliminaciones persistentes del entorno. |
| Procesos y secuencias | Probar eventos comunes, automáticos y paralelos, diálogos, esperas, rutas y transiciones en los puntos donde el juego permite guardar. Comparar reinicio o reanudación con la carga local y verificar ausencia de duplicaciones, bloqueos y recompensas repetidas. No exigir reanudación a mitad de evento si el guardado local no la ofrece. |
| Sistema y plugins | Verificar temporizadores, prohibición de guardar cuando corresponda, audio, pathfinding, misiones, inventario, equipo y desbloqueos de crafting y otros plugins activos. |
| Partidas y migraciones | Probar múltiples ranuras, `.bak`, partida ausente o dañada, cabecera incorrecta y versiones antiguas o incompatibles. Validar cambios de IDs de mapas, eventos, switches, variables y datos de plugins; rechazar o migrar según la política aprobada. |
| Fallos de guardado | Simular fallos de escritura y de serialización; comprobar restauración de hooks, estado del mapa y mensajes, y que no se publique una versión como guardada cuando falló la copia local. |

Complementar la matriz con pruebas de red interrumpida, reintentos, concurrencia entre dispositivos y restauración en otro entorno compatible. Los tests deben usar partidas y eventos de prueba controlados, sin modificar ni sobrescribir partidas reales.

## 12. Riesgos principales

| Riesgo | Consecuencia | Tratamiento |
|---|---|---|
| Formato `Marshal` | Carga insegura de datos manipulados. | Diseñar un formato de intercambio validable y resolver explícitamente el modelo de confianza. |
| Estado incompleto | Partida recuperada con misiones, eventos o plugins rotos. | Inventario de estado y pruebas de restauración completas. |
| Conflictos entre dispositivos | Pérdida de progreso. | Versiones, control de concurrencia, confirmación y copias anteriores. |
| Cliente modificable | Clasificación manipulable. | Clasificación casual inicial; validación y eventual autoridad del servidor. |
| Caída del servicio | Imposibilidad de sincronizar o recuperar. | Juego local, reintentos, monitorización y respaldos. |
| Compatibilidad entre versiones | Partidas antiguas que no cargan. | Versionar formato y juego; desarrollar y probar migraciones. |
| Eventos y datos RMXP | Páginas incorrectas, eventos reiniciados, recompensas duplicadas o progreso bloqueado. | Preservar switches y variables por identidad, respetar el ciclo del motor y probar eventos y puntos seguros frente a la carga local. |
| Hooks y fallos locales | Mapa temporalmente incompleto o copia remota no correspondiente a un guardado válido. | Garantizar restauración de hooks, resultado local explícito y captura única de la versión confirmada. |
