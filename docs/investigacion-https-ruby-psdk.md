# Investigación: HTTPS desde Ruby PSDK (ticket #21)

**Estado: BORRADOR para revisión. La campaña 20261118-013809 terminó completa; persiste una anomalía TLS aislada y falta repetirla para determinar su reproducibilidad.**

## Alcance y límites

- Ruby probado: `C:\Users\JUAN2\AppData\Local\Programs\pokemon-studio\resources\psdk-binaries\ruby.exe` (3.0.6p216, i386-mingw32, OpenSSL 3.2.1), en esta máquina Windows.
- Solo URLs públicas (`example.com`, `expired.badssl.com`), sin credenciales ni tokens. Sin instalar gemas. `VERIFY_PEER` en todas las peticiones; nunca `VERIFY_NONE`.
- El diagnóstico de repetición se carga como plugin dentro de PSDK y mide las entradas reales a `Graphics.update`; las mediciones aisladas con un hilo "latido" de 16 ms se conservan como evidencia separada.
- **NO VERIFICADO**: otras máquinas, redes, proxys o antivirus; otras versiones de PSDK; POST/subidas grandes; HTTP/2; redirecciones; comportamiento con el CA bundle de otras fuentes distinto del usado; Windows 32 vs 64 bits del sistema; la fase exacta que causa una pausa de `Graphics.update`.

## Protocolo de repetición autorizado

El plugin `scripts/00000 Plugins/00012 HTTPS Loop Diagnostic/00000 HTTPS Loop Diagnostic.rb` ejecuta la campaña en una sesión PSDK con `Graphics.update` real:

1. Tres ejecuciones `baseline` de 10 segundos sin petición.
2. Una petición HTTPS válida de calentamiento, excluida de las métricas de frames.
3. Tres ejecuciones `https_valid` de 10 segundos contra `https://example.com/`.
4. Una ejecución `https_delayed` usando exactamente `https://httpbin.org/delay/5`, que produjo previamente una petición de aproximadamente 5.54 segundos.
5. Una ejecución `https_connection_failure` contra `https://127.0.0.1:1/`, sin servidor local ni dependencia adicional.

La campaña completa es el comportamiento predeterminado. Para repetir sólo la anomalía de HTTPS válido, se puede establecer `PSDK_HTTPS_LOOP_DIAGNOSTIC_MODE=directed_valid`; ese modo ejecuta tres baseline, un calentamiento HTTPS fuera de métricas y cinco ejecuciones consecutivas `https_valid`. No ejecuta la petición demorada ni la prueba de conexión fallida. Cualquier otro valor conserva el modo completo.

Todas las peticiones usan `VERIFY_PEER` y el archivo indicado por `PSDK_HTTPS_CA_FILE`. El calentamiento no demuestra reutilización de una conexión TLS: sólo precede a las ejecuciones medidas en el mismo proceso.

Cada informe registra frames, duración, media, p95, máximo, pausas superiores a 100 ms, duración de la petición, estado HTTP, clase de excepción y clasificación. También registra tiempos monotónicos de inicio/fin de la petición, solicitud de parada y confirmación de `Graphics.update`, para separar una pausa del bucle de la duración de HTTPS. El fallo de conexión sólo se clasifica como `connection_error` para errores de conexión distinguibles (`ECONNREFUSED`, `ETIMEDOUT`, `EHOSTUNREACH`, `ENETUNREACH` o `Net::OpenTimeout`). Otros fallos se registran como `inconclusive`.

Los informes se escriben en el directorio temporal de Windows (`TEMP` o `TMP`) como `dungeon-critters-https-loop-diagnostic-*.txt`. Se genera además un informe `campaign-summary` con las ejecuciones completadas. No se atribuyen pausas a DNS, TLS, GVL, GC u otra fase sin mediciones específicas.

### Repetición dirigida en Windows

1. Cierra cualquier sesión previa de PSDK/Pokémon Studio.
2. En PowerShell, configura el diagnóstico y el CA bundle:

```powershell
$env:PSDK_HTTPS_LOOP_DIAGNOSTIC = '1'
$env:PSDK_HTTPS_CA_FILE = 'C:\ruta\al\cacert.pem'
$env:PSDK_HTTPS_LOOP_DIAGNOSTIC_MODE = 'directed_valid'
```

3. Inicia el juego con el procedimiento habitual del proyecto y deja que el plugin termine.
4. Copia todos los informes cuyo nombre contenga el identificador de campaña generado, incluido `campaign-summary`.
5. Para volver al comportamiento completo, elimina o cambia la variable:

```powershell
Remove-Item Env:PSDK_HTTPS_LOOP_DIAGNOSTIC_MODE
```

El resumen dirigido debe contener tres `baseline`, un `https_warmup` y cinco `https_valid`. Cada ejecución `https_valid` registra `request_started_at_monotonic`, `request_ended_at_monotonic`, `stop_requested_at_monotonic`, `completion_wait_expired`, `max_interval_ms`, `p95_interval_ms` y `pauses_over_100ms`. Esos valores permiten comparar temporalmente cada petición con las pausas de `Graphics.update`.

### Campaña dirigida 20261118-020224

La campaña ejecutada con Ruby PSDK `3.0.6p216 [i386-mingw32]`, `VERIFY_PEER` y CA bundle explícito completó todos sus escenarios:

- 3/3 `baseline`: p95 de `26.11`, `26.52` y `26.66 ms`.
- `https_warmup`: HTTP 200 en `539.49 ms`, excluido de las métricas.
- 5/5 `https_valid`: HTTP 200, sin excepciones TLS ni peticiones activas al finalizar.
- Duración de las peticiones válidas: `446.73--515.32 ms`.
- p95 de `Graphics.update` durante HTTPS: `26.51--26.91 ms`.
- Ningún escenario quedó incompleto ni expiró esperando la confirmación de `Graphics.update`.

Las pausas superiores a 100 ms no fueron exclusivas de HTTPS: `baseline-1` registró 2 y `baseline-2`/`baseline-3` registraron 0; las cinco ejecuciones HTTPS registraron 1 cada una. Los máximos HTTPS estuvieron entre `193.86` y `205.23 ms`, sin reproducir el máximo aislado de `7170 ms` de la campaña anterior. La correlación temporal registrada muestra que cada petición terminó dentro de los primeros `446--516 ms` del escenario, mientras que la ventana medida continuó normalmente durante 10 segundos.

Conclusión para el entorno probado: `Net::HTTP` con `VERIFY_PEER`, CA bundle explícito y una petición en hilo secundario es viable para HTTPS válido en Ruby PSDK dentro de este escenario. La campaña no demuestra que todas las operaciones TLS sean libres de pausas ni descarta fallos transitorios de red, proxy, OpenSSL o Windows; tampoco mide por separado DNS, handshake, verificación de certificados o GVL. El `bad record mac` anterior no se reprodujo y no puede atribuirse causalmente a la pausa de `Graphics.update`.

### Criterios de aceptación de #21

| Criterio | Estado | Evidencia y límite |
|---|---|---|
| Usar el Ruby PSDK indicado y certificados válidos | Satisfecho | Ruby `3.0.6p216 i386`, `VERIFY_PEER`, CA bundle explícito; 5/5 respuestas HTTP 200. |
| Medir o demostrar el impacto sobre el bucle del juego | Satisfecho para el escenario probado | 3 baseline frente a 5 HTTPS dentro de PSDK, con p95 comparable y sin escenarios incompletos. No cubre todas las redes, cargas o fases TLS. |
| Documentar la decisión y sus límites | Satisfecho | Se documenta la viabilidad de HTTPS en hilo secundario, la ausencia de causalidad demostrada para el incidente anterior y las limitaciones de instrumentación. |
| Aislar completamente cualquier pausa TLS rara | No verificable en #21 | Requeriría instrumentación específica de OpenSSL/GVL o proceso separado; no es necesario para demostrar la capacidad HTTPS básica. |

### Campaña 20261118-013809

Los tres baseline tuvieron p95 de 26.20--26.80 ms; dos presentaron pausas superiores a 100 ms, con máximos de 422.75 ms y 147.80 ms. `https_valid-1` y `https_valid-2` respondieron HTTP 200 y mantuvieron p95 de 26.62--26.51 ms.

`https_valid-3` terminó la petición en 761.05 ms con `OpenSSL::SSL::SSLError: SSL_read: ssl/tls alert bad record mac (SSL alert number 20)`, clasificado como `tls_error`. La petición ya no estaba activa al deadline y su hilo terminó correctamente. El escenario registró una duración de 16.24 s, media de 45.94 ms y un máximo de 7170.14 ms, con p95 de 26.69 ms. Esto demuestra una pausa extrema de `Graphics.update`, pero no demuestra que la causara el error TLS: la petición terminó mucho antes y la petición demorada posterior tardó 6690.24 ms sin producir una pausa comparable.

No hay reutilización de `Net::HTTP`, sockets ni objetos OpenSSL entre escenarios: cada petición crea su propio objeto dentro de un hilo nuevo y las ejecuciones son secuenciales. Las causas externas plausibles del `bad record mac` incluyen una condición transitoria del servidor, proxy o inspección TLS, transporte, o una interacción específica de la build de OpenSSL/Windows; ninguna queda demostrada por esta campaña. La pausa extrema también puede ser una suspensión o bloqueo externo del proceso, GVL u otra actividad del juego. La siguiente prueba debe repetir varias solicitudes `https_valid` y conservar las marcas monotónicas nuevas; si el error no reaparece, debe tratarse como incidente aislado, no como prueba de causalidad.

## Repetir la prueba

```powershell
# (opcional, tras descargar un archivo de CA; ver "Alternativas")
$env:PROBE_CA_FILE = "$env:TEMP\cacert.pem"
& 'C:\Users\JUAN2\AppData\Local\Programs\pokemon-studio\resources\psdk-binaries\ruby.exe' tools\windows\https_probe.rb
```

Sin `PROBE_CA_FILE` se usa el almacén por defecto de ese Ruby. Tarda ~50 s (por los casos de timeout).

## Resultados reales

### 1. Almacén de certificados y VERIFY_PEER

```
DEFAULT_CERT_FILE=.../psdk-binaries/etc/ssl/cert.pem   existe=false
DEFAULT_CERT_DIR =.../psdk-binaries/etc/ssl/certs      existe=false
SSL_CERT_FILE=nil SSL_CERT_DIR=nil
```

Ninguno existe en disco. **Sin configuración, `VERIFY_PEER` falla** también con un certificado válido:

```
OpenSSL::SSL::SSLError: ... certificate verify failed (unable to get local issuer certificate)
```

Con un archivo de CA propio (`http.ca_file`, `PROBE_CA_FILE`) funciona:

```
https://example.com/ -> HTTP 200, 577 bytes
```

(Archivo usado: `cacert.pem` de https://curl.se/ca/cacert.pem, 200116 bytes, SHA-256 `427C0642...C8497285`, descargado el día de la prueba; no incluido en el repo.)

### 2. Certificado inválido

Con el bundle: `https://expired.badssl.com/` lanza `OpenSSL::SSL::SSLError ... certificate verify failed (certificate has expired)`, capturable con `rescue OpenSSL::SSL::SSLError`. Sin bundle también falla, pero por la causa equivocada (emisor desconocido): **un fallo de verificación no distingue "caducado" de "sin almacén"**; hay que comprobar el almacén al arrancar.

### 3. Hilo en segundo plano y latido de 16 ms

Latido: `sleep 0.016` y mide la mayor separación entre ticks. Petición en otro hilo con `open_timeout=5`, `read_timeout=5`. DNS con `Addrinfo.getaddrinfo`: 1–6 ms (cacheado/rápido en esta red).

| Caso | Máx. pausa del latido (4 ejecuciones) |
|---|---|
| Sin petición (línea base) | 32.6–53.3 ms (timer de Windows ~15.6 ms) |
| GET HTTPS válido (~670 ms) | **369.7, 447.8, 382.2, 378.8 ms** |
| Conexión a destino no enrutable (21 s) | 40.2–47.2 ms |

Conclusión: la petición en un hilo **sí congela al resto de hilos Ruby ~370–450 ms de forma reproducible** durante una petición TLS válida (en 670 ms solo hubo 9–13 ticks frente a ~40 esperados). La fase exacta (carga del CA file, handshake o verificación de cadena) **NO se midió**. En cambio, esperar una conexión que no responde no bloquea el latido. A 60 FPS, 400 ms son ~24 fotogramas perdidos si el bucle gráfico comparte proceso/GVL. Esta medición aislada no representa el bucle real de PSDK; la campaña dentro de PSDK se documenta por separado.

La campaña dentro de PSDK debe interpretarse por separado: una pausa máxima no demuestra que todo el bucle se congele ni identifica la fase responsable. La decisión entre hilo y proceso se tomará después de comparar la variabilidad del baseline con la reproducibilidad de las pausas HTTPS.

### 4. Sin red / servidor sin respuesta

| Caso | Resultado |
|---|---|
| DNS inexistente (`no-existe.invalid`) | `SocketError` (getaddrinfo) a los ~60 ms |
| `127.0.0.1:1` (puerto cerrado) | `Net::OpenTimeout` a los ~2.0 s |
| `10.255.255.1` (no enrutable), `open_timeout=2` | `Net::OpenTimeout` a los **~21 s**, no 2 s |

Los errores son capturables (`SocketError`, `Net::OpenTimeout`, `Timeout::Error`), pero **`open_timeout` no acota el tiempo real en este Ruby/Windows** (21 s medidos con 2 s configurados). No se investigó la causa (probablemente reintentos del `connect` bloqueante). Hay que acotar con un plazo propio (el hilo se abandona y se ignora su resultado) y no depender de `open_timeout`.

### Otros hallazgos

- `require 'resolv'` **falla** en este Ruby (`NoMethodError: undefined method 'win32_last_socket_error=' for Fiddle:Module`, `win32/registry` incompatible con la `fiddle` empaquetada). `net/http` y `OpenSSL` cargan bien, pero no se debe usar `Resolv`; usar `Addrinfo`/`Socket`.

## Decisión provisional

1. HTTPS con `net/http` + `VERIFY_PEER` es **viable**, pero **solo con un archivo de CA propio** distribuido junto al juego (p. ej. `Data/cacert.pem`, `http.ca_file`) porque el almacén por defecto del Ruby de PSDK no existe. No usar `VERIFY_NONE`. Detectar al arrancar que el archivo existe y avisar claramente si no.
2. El bundle debe actualizarse con el juego (las CA caducan) y descargarse/verificarse por una vía de confianza; riesgo de cadena de suministro a decidir.
3. Hacerlo en un hilo evita bloquear en red (DNS/conexión colgada), pero **el handshake TLS bloqueó ~400 ms a los demás hilos** en la prueba aislada. Alternativas a evaluar (**NO VERIFICADAS**): proceso hijo separado (`Process.spawn`/`curl.exe` del sistema con salida a archivo, sondeado desde el juego) para aislar el stall; reutilizar conexión/lanzar la petición en una pantalla de carga donde un tirón sea aceptable.
4. Antes de adoptar nada, repetir la medición **dentro de PSDK** con `Graphics.update` real.
