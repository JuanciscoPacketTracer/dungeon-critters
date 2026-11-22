# Decisión técnica: servidor de la nube y ranking

**Estado:** borrador para revisión. Esta investigación no crea el servidor; el responsable decidió que su código vive en este repositorio, bajo `server/`.

## Alcance y restricciones

El lenguaje del servidor queda decidido: **Ruby**. Esta versión es independiente del Ruby de PSDK: el cliente usa Ruby 3.0.6 de 32 bits, mientras que el servidor debe fijar su propia versión y no puede condicionar la del juego.

La prueba prevista usa Render Free. Render documenta para el plan gratuito `0.1 CPU / 512 MB RAM`, suspensión tras 15 minutos sin tráfico y un arranque posterior de aproximadamente un minuto. También documenta que el sistema de archivos es efímero y que los servicios nativos usan Debian 12 (Bookworm) con compiladores y `make` disponibles durante la construcción ([Render: Free](https://render.com/docs/free), [Render: Native Runtimes](https://render.com/docs/native-runtimes)).

## Marco web de Ruby

### Criterios

- Memoria dentro de 512 MB, especialmente durante un arranque en frío.
- Tiempo y complejidad de arranque.
- Número y peso de dependencias.
- JSON y respuestas `application/problem+json`.
- Facilidad de probar el contrato HTTP versionado en un contenedor.

Los valores comparativos de memoria y tiempo de arranque que no proceden de una medición en Render están marcados como **NO VERIFICADO**. No se debe convertir esta tabla en una promesa de rendimiento.

| Opción | Memoria y arranque en Render Free | Dependencias | JSON y `application/problem+json` | Pruebas del contrato |
| --- | --- | --- | --- | --- |
| **Roda** | **NO VERIFICADO:** su enfoque basado en Rack y su superficie pequeña son favorables a 512 MB y a un arranque corto, pero no se midieron RSS ni cold start en Render. | Pequeña; deja la selección de middleware y persistencia explícita. | JSON mediante una gema de serialización y un helper de respuesta; `application/problem+json` se implementa como una respuesta Rack normal con tipo y cuerpo explícitos. | Muy favorable: las rutas pueden probarse contra Rack y el mismo contrato puede ejecutarse en un contenedor sin navegador. |
| **Sinatra** | **NO VERIFICADO:** adecuado para un servicio pequeño, pero no se midieron RSS ni cold start en Render. | Pequeña y familiar; añade convenciones de microframework sin imponer ORM. | Tiene soporte práctico para devolver JSON, pero el formato problem details y su política de errores deben definirse explícitamente. | Favorable con Rack::Test o solicitudes HTTP reales; requiere fijar cuidadosamente middleware y manejo de errores. |
| **Rails API-only** | **NO VERIFICADO:** el modo API reduce middleware, pero su boot y superficie son mayores; no se midieron RSS ni cold start en Render Free. | Mayor: framework, middleware, Active Support y convenciones de aplicación. | JSON, routing, logging, middleware y manejo de errores tienen soporte amplio; `application/problem+json` aún requiere una política y renderizador explícitos. | Excelente para una suite HTTP madura, pero introduce más estructura y tiempo de arranque del necesario para esta API inicial. |

Fuentes: [Roda](https://roda.jeremyevans.net/), [Sinatra](https://sinatrarb.com/), [Rails API-only](https://guides.rubyonrails.org/api_app.html). La guía de Rails confirma el modo `--api`, el parsing JSON, routing, logging y middleware reducidos; no constituye una medición de memoria o arranque.

### Recomendación

Recomiendo **Roda sobre Rack**, con JSON explícito y un renderizador propio para `application/problem+json` que siempre incluya el código estable y `request_id` definidos por la spec. La decisión prioriza una superficie pequeña en el plan gratuito y un contrato HTTP fácil de ejercitar sin UI. Sinatra queda como alternativa conservadora si el equipo prefiere mayor familiaridad; Rails API-only no se recomienda para la primera versión por su coste estructural y de arranque.

La recomendación de memoria y cold start es una hipótesis de diseño, no una medición: debe verificarse después en un servicio Render antes de ajustar límites o aceptar una latencia objetivo.

## Versión de Ruby del servidor

La versión propuesta para el servidor es **Ruby 3.3.x**, fijada a un parche concreto en el manifiesto y en la imagen de despliegue. Esta elección es independiente de Ruby 3.0.6 de 32 bits del PSDK; no se comparte runtime ni se exige actualizar el cliente.

Render confirma que ofrece un runtime nativo de Ruby y que sus runtimes nativos se ejecutan sobre Debian 12, pero la disponibilidad exacta de cada parche de Ruby 3.3 en el servicio concreto queda **NO VERIFICADA**. Antes del despliegue se debe fijar el parche que Render exponga o usar una imagen Docker con el parche aprobado.

## Argon2id nativo

La gema propuesta es **`argon2id`**, no la gema `argon2`. Su API acepta directamente `m_cost` en KiB, `t_cost` y `parallelism`, evitando la ambigüedad observada en la gema `argon2`, cuya API usa un exponente para `m_cost`. La gema `argon2id` declara una extensión nativa y expone por defecto `m_cost: 19456`, `t_cost: 2` y `parallelism: 1` ([RubyGems: argon2id](https://rubygems.org/gems/argon2id)).

### Verificación ejecutada

Se ejecutó con Podman usando la imagen local `docker.io/library/ruby:3.0.6`, que corresponde al entorno Ruby Debian disponible localmente. La prueba instaló `build-essential`, compiló `argon2id` 0.8.0 y calculó/verificó un hash con 19 MiB = 19.456 KiB:

```text
+ gem install argon2id --no-document
Building native extensions. This could take a while...
Successfully installed argon2id-0.8.0
1 gem installed
{:ruby=>"3.0.6", :gem=>"0.8.0", :defaults=>[19456, 2, 1]}
$argon2id$v=19$m=19456,t=2,p=1$j1fwqFfPP2LRS8KCaV2UcQ$9CWfg2/bcPJ47gVvF2nsiCB0sG0uHDilG77OlF4MpcY
{:m_cost=>19456, :t_cost=>2, :parallelism=>1, :valid=>true}
```

La ejecución confirma compilación nativa, parámetros PHC y verificación del password en el contenedor local. **NO VERIFICADO:** no es una ejecución dentro de Render; todavía debe confirmarse en un deploy o build de Render que la misma gema y versión de Ruby compilan allí. Render sí documenta Debian 12, `gcc`, `g++` y `make` en sus runtimes nativos ([Render: Native Runtimes](https://render.com/docs/native-runtimes)).

## PostgreSQL de Supabase desde Render

La documentación de Supabase distingue:

- conexión directa en `5432`, recomendada para backends persistentes cuando hay IPv6 o el complemento IPv4;
- pooler compartido en **session mode**, también en `5432`, recomendado para un backend persistente en una red solo IPv4;
- pooler compartido en transaction mode en `6543`, pensado para funciones serverless o edge de conexiones cortas y con limitaciones de estado de sesión y prepared statements.

La recomendación inicial es **pooler compartido en session mode**, porque el servicio Render Free debe tratarse como IPv4-only hasta verificar la conectividad IPv6 del servicio y porque la API es un backend persistente que necesita semántica de sesión. Debe usarse el host y usuario entregados por el diálogo Connect de Supabase, no construirlos a partir de la región. No se recomienda transaction mode para la API principal.

Fuente: [Supabase: Connect to your database](https://supabase.com/docs/guides/database/connecting-to-postgres). **NO VERIFICADO:** no se probó una conexión real desde Render a Supabase; hay que confirmar IPv4/IPv6, TLS, límite de conexiones y compatibilidad del driver Ruby antes del despliegue. Las migraciones, `pg_dump` y restauraciones deben usar la conexión directa cuando el entorno de operación lo permita, conforme a la misma documentación.

## Correo transaccional con Resend

Render Free no permite tráfico saliente SMTP en los puertos 25, 465 y 587, por lo que la API debe usar HTTPS. La documentación de Resend para Ruby requiere una clave de API y un dominio verificado, y muestra la gema oficial `resend` y `Resend::Emails.send`; la cuenta y la clave deben permanecer fuera del repositorio ([Resend: Send emails with Ruby](https://resend.com/docs/send-with-ruby), [Resend Ruby SDK](https://github.com/resend/resend-ruby)).

La implementación recomendada es:

- usar la gema oficial `resend` para formar y enviar el correo;
- usar **HTTParty**, que es la biblioteca HTTP declarada por el SDK Ruby de Resend, para el transporte HTTPS del SDK;
- usar su transporte HTTPS documentado, no SMTP;
- mantener la clave en el secreto del servicio;
- probar el adaptador con un transporte controlado en tests y reservar una prueba real para el entorno humano con dominio verificado.

La dependencia de HTTParty está documentada en el gemspec y en `lib/resend.rb` del SDK ([Resend gemspec](https://raw.githubusercontent.com/resend/resend-ruby/main/resend.gemspec), [Resend Ruby client](https://raw.githubusercontent.com/resend/resend-ruby/main/lib/resend.rb)). La gema actual del SDK requiere Ruby `>= 3.2`, compatible con la propuesta Ruby 3.3.x del servidor.

**NO VERIFICADO:** no se hizo una llamada real a Resend porque no se deben usar ni solicitar secretos en este trabajo. Tampoco se verificó en Render la cadena completa `resend` → HTTParty → TLS.

## Pruebas del contrato HTTP versionado

El marco propuesto es **Minitest** con solicitudes HTTP reales contra una aplicación Rack en contenedor, manteniendo una capa de pruebas que pueda sustituir el transporte externo. El arnés actual ya usa Minitest y `DungeonCritters::Online::ControlledTransport`, que registra método, ruta, cabeceras y cuerpo y devuelve respuestas encoladas (`test/support/controlled_transport.rb:3-27`). El cliente versionado actual ejercita el contrato mediante ese transporte (`test/support/versioned_api_client.rb:3-17`).

La suite se compone de una tabla de casos compartidos que se ejecuta en dos niveles (transporte controlado y HTTP real):

1. **Casos compartidos:** cada operación versionada se define una vez como una tabla de solicitud esperada, respuesta válida y respuestas de error. La tabla incluye método, ruta `/v1/...`, cabeceras, cuerpo JSON, código HTTP, tipo de contenido, código estable y `request_id`.
2. **Transporte controlado:** los casos compartidos se ejecutan con `ControlledTransport` para el cliente, sin red ni credenciales. El adaptador encola la respuesta declarada y compara que la solicitud observada coincida con el caso.
3. **HTTP real:** los mismos casos compartidos se ejecutan contra una aplicación Roda/Rack levantada en un contenedor, usando un cliente HTTP de test. Las aserciones se aplican a la respuesta real, no a detalles internos del framework.

Ambos niveles deben comprobar respuestas JSON y `application/problem+json`, códigos estables, `request_id`, validación y aislamiento entre cuentas. El comando existente del cliente es `ruby -Itest test/run.rb`; el contenedor Ruby 3.0.6 ya definido por el repositorio (`Dockerfile.ruby-3.0`) es el punto de partida para esas pruebas, aunque el servidor deberá tener su propia imagen y versión de Ruby.

La frontera de versión es el prefijo de ruta y el contrato asociado: los casos de `/v1/...` se mantienen compatibles dentro de v1; una versión posterior tendrá su propia tabla y prefijo. **NO VERIFICADO:** todavía no existe aplicación Roda ni un contenedor de servidor que ejecute las pruebas HTTP reales. Esta sección define el marco, no lo implementa.

## Dónde vive el código del servidor: decidido

La decisión del responsable es que el código del servidor vive en este repositorio, bajo `server/`.

### Este repositorio, por ejemplo `server/`

**Ventajas:** una revisión coordinada del contrato y cliente; reutilización directa de fixtures y `ControlledTransport`; una sola referencia de issues y documentación; cambios de contrato visibles junto a sus consumidores.

**Costes:** mezcla un backend desplegable con el árbol grande del juego; puede complicar dependencias, builds y permisos; aumenta el riesgo de que comandos del servidor toquen archivos locales del juego.

### Repositorio separado

**Ventajas:** ciclo de despliegue, dependencias, secretos y permisos aislados; imagen y CI del servidor más simples; menor riesgo de empaquetar recursos del juego.

**Costes:** el contrato y sus fixtures se sincronizan entre repositorios; las revisiones cruzadas son menos inmediatas; el arnés de cliente necesitaría consumir una versión publicada o una copia controlada del contrato.

**NO VERIFICADO:** Render permite fijar un directorio raíz para el servicio y filtrar qué cambios disparan un despliegue. Esto debe comprobarse en la documentación de Render y en el ticket de despliegue antes de configurar nada.

## Fuentes y estado de verificación

- Render, [Free web services](https://render.com/docs/free): plan `0.1 CPU / 512 MB RAM`, suspensión y arranque en frío, filesystem efímero y bloqueo SMTP.
- Render, [Native Runtimes](https://render.com/docs/native-runtimes): Ruby, Debian 12 y herramientas nativas de compilación.
- Supabase, [Connect to your database](https://supabase.com/docs/guides/database/connecting-to-postgres): conexión directa, pooler session mode y transaction mode.
- Resend, [Send emails with Ruby](https://resend.com/docs/send-with-ruby): gema oficial, API key, dominio verificado y envío HTTPS.
- Resend Ruby SDK, [gemspec](https://raw.githubusercontent.com/resend/resend-ruby/main/resend.gemspec) y [cliente](https://raw.githubusercontent.com/resend/resend-ruby/main/lib/resend.rb): dependencia HTTParty y uso del transporte HTTP.
- Rails, [Using Rails for API-only Applications](https://guides.rubyonrails.org/api_app.html): modo API, JSON, routing, middleware y pruebas.
- Sinatra, [Sinatra](https://sinatrarb.com/): referencia del microframework.
- Roda, [Roda](https://roda.jeremyevans.net/): referencia del framework Rack.
- Repositorio local, `test/support/controlled_transport.rb:3-27` y `test/support/versioned_api_client.rb:3-17`: seam de transporte controlado existente.
- Issue #10, resolución del responsable: Render Free, Argon2id, Supabase PostgreSQL y Resend por HTTPS.

## Pendiente para el ticket de sesiones y autenticación

- Repetir la verificación de Argon2id con la versión de Ruby que se use realmente en el servidor, no con Ruby 3.0.6.
- Verificar que `argon2id` y la gema `resend` conviven en esa versión; el SDK exige Ruby 3.2 o superior.
- Medir en Render el tiempo de cálculo de un hash con `m=19456`, `t=2`, `p=1` y registrarlo.
- Confirmar el parche exacto de Ruby 3.3 disponible en Render, o justificar otra versión.


## Concurrencia de `PostgresStore`

`PostgresStore#read` y `PostgresStore#transaction` abren una transacción PostgreSQL y
adquieren el mismo `pg_advisory_xact_lock(23)` antes de leer o persistir el estado.
Esto es necesario porque `load_rows` ejecuta varias consultas: el mutex Ruby solo
coordina llamadas dentro de una instancia y no evita que otra conexión confirme una
escritura entre dos `SELECT`. El advisory lock transaccional mantiene la lectura
completa frente a una escritura de otra instancia.

El orden de adquisición es fijo: mutex Ruby, transacción PostgreSQL y luego el
advisory lock. La aplicación no toma otros locks PostgreSQL mientras espera ese
advisory lock, por lo que las rutas de lectura y escritura no forman un ciclo de
interbloqueo. El lock se libera automáticamente al terminar la transacción.
