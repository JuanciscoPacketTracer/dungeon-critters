# Contrato de subida de guardados v1

## Alcance

Este contrato cubre `POST /v1/saves/:slot/versions` para aceptar una primera
version de guardado y reintentos seguros. La autenticacion se resuelve fuera
de este componente; el endpoint recibe una identidad de cuenta ya autenticada.

`pending_snapshot` sigue siendo una instantanea local del cliente. No es una
tabla ni un recurso remoto de este contrato. El servidor recibe una instantanea
confirmada y crea una `save_version` inmutable.

## Transporte aprobado

El cuerpo HTTP es exactamente el JSON UTF-8 producido por el codec. Los
metadatos se transportan en cabeceras:

La unica operacion permitida es `POST`. Las demas responden `405` con
`Allow: POST` sin autenticar ni leer el cuerpo. El servidor rechaza un
`Content-Length` superior a 10 MiB y, para cuerpos sin longitud declarada,
lee como maximo 10 MiB + 1 byte antes de rechazar.

| Cabecera | Significado |
| --- | --- |
| `Upload-Id` | Identificador opaco persistente del intento |
| `Parent-Version-Id` | Version vigente que el cliente cree tener; ausente para la primera version |
| `Payload-SHA256` | SHA-256 hexadecimal calculado sobre los bytes raw del cuerpo |
| `Codec-Schema-Version` | Version del esquema del codec |
| `Game-Version` | Version del juego |
| `PSDK-Version` | Version del PSDK |

El servidor lee el cuerpo una vez, conserva los bytes raw, verifica que sean
UTF-8, calcula SHA-256 y solo despues parsea una copia para validar el esquema.
No se calcula el hash sobre las cabeceras, un envelope, `jsonb` o JSON
re-serializado.

## Idempotencia

La identidad de una repeticion es `(account_id, upload_id)`. Para devolver el
resultado original deben coincidir el cloud slot, `parent_version_id`, las
versiones de codec/juego/PSDK, la longitud, el SHA-256 recalculado y los bytes
exactos. `Authorization`, `request_id`, `User-Agent` y variaciones
incidentales de `Content-Type` no forman parte de esa identidad.

El servidor no confia en el hash enviado: lo recalcula. El primer intento
invalido no crea registro de idempotencia, version, slot ni cambio de version
vigente. Un `upload_id` repetido con bytes o metadatos distintos falla sin
crear una segunda version.

## Persistencia y concurrencia

PostgreSQL conserva el payload en `bytea`, junto con longitud, hash, metadatos y
la version de esquema. `cloud_slots` es la vinculacion estable entre cuenta y
ranura local. `save_versions` es inmutable y conserva el estado `accepted` o
`conflict`; la version vigente solo cambia
cuando `parent_version_id` coincide con la version actual, o es nulo cuando la
ranura aun no tiene version.

La transaccion bloquea la ranura con `FOR UPDATE` y serializa tambien el par
`(account_id, upload_id)` con un advisory lock. La identidad de cuenta procede
de `SessionService#current` y nunca del cuerpo o de una cabecera enviada por
el cliente.

La aplicacion Rack real monta el handler dentro de Roda junto al `App` de #23.
`SessionAuthenticator` reutiliza su `SessionService#current`, y
`PostgresSaveStore` usa el mismo `DATABASE_URL` del servidor. El arranque
requiere `SAVE_REFERENCE_CATALOG_JSON` cuando se quieran aceptar payloads:
ese JSON configura el catalogo que usa el codec y no forma parte del envelope
de upload. Las pruebas unitarias del handler se conservan junto a pruebas
HTTP con `Rack::MockRequest`; no se usan partidas reales.

Las pruebas con `InMemorySaveStore` son dobles: cubren validacion, bytes
exactos, idempotencia, aislamiento, conflictos y limites sin PostgreSQL.
Las pruebas de `server_rack_save_upload_test.rb` ejercitan Roda/Rack y el
catalogo real del codec, pero sustituyen los stores y la sesion para aislar
el transporte. Las pruebas PostgreSQL deben ejecutarse con `DATABASE_URL` y
aplican primero las migraciones de #23 y #34; el guard de arranque solo
comprueba que `cloud_slots` y `save_versions` existan y nunca aplica una
migracion automaticamente. Esta rama no tiene una prueba PostgreSQL
ejecutable sin `DATABASE_URL`; por tanto, ninguna prueba automatica afirma
haber validado la migracion o la concurrencia contra PostgreSQL real.

`server_postgres_bytea_test.rb` incluye pruebas unitarias con la codificacion
textual de `pg` y una prueba PostgreSQL real condicionada a un
`DATABASE_URL` local cuyo nombre contiene `test`. La prueba real crea un
schema temporal, aplica las migraciones y comprueba lectura exacta e
idempotencia; se omite de forma segura cuando no existe esa base.

El bundle canonico de despliegue es el `Gemfile` de la raiz: contiene tanto
la aplicacion real de #23 como el endpoint de guardados, y el workflow de
PostgreSQL ejecuta sus pruebas desde la raiz con ese bundle. No se usa un
`server/Gemfile` alternativo.

El guard de `PostgresSaveStore` limita sus consultas de catalogo a
`current_schema()` y a `users`, `cloud_slots` y `save_versions`. Comprueba
las columnas del modelo de guardados y las restricciones unicas y
referenciales que atan cuenta, cloud slot, padre y version actual. No
considera suficiente que existan las tablas.

Un padre obsoleto no sobrescribe la version vigente. La escritura puede
registrarse como rama de conflicto inmutable, pero la exploracion, comparacion,
retencion y resolucion de ramas quedan fuera de la primera entrega de #34.

## Alternativas descartadas para este contrato

- **Envelope JSON con `payload_base64`:** preserva los bytes, pero añade
  codificacion y complejidad al contrato.
- **Blob externo:** reduce el tamano de PostgreSQL, pero requiere otro sistema
  de durabilidad, referencias y pruebas operativas.
- **`text` UTF-8:** puede conservar el contenido textual, pero exige demostrar
  round-trip exacto y no ofrece la garantia directa de bytes de `bytea`.
