# Investigación: protección de tokens con el usuario de Windows

> **Estado:** prueba local ejecutada el 2026-11-12 con Ruby de PSDK. Las afirmaciones marcadas como **NO VERIFICADO** no se probaron.

## Decisión

Para un token de sesión persistente del cliente de cuenta, usar DPAPI de Windows mediante `CryptProtectData` y `CryptUnprotectData`, invocadas con la biblioteca estándar `Fiddle`. La protección se debe solicitar sin `CRYPTPROTECT_LOCAL_MACHINE`; así se usa el contexto del usuario de Windows que ejecuta el juego. Usar `CRYPTPROTECT_UI_FORBIDDEN` para que un fallo no abra una interfaz inesperada.

La implementación debe tratar todo error de lectura o descifrado como un token no recuperable: eliminar o poner en cuarentena el archivo protegido y solicitar autenticación de nuevo. Nunca almacenar el token en la partida, en `Saves/` ni en texto plano.

## Entorno y evidencia ejecutada

Se ejecutó este comando, sin instalar gemas:

```powershell
& 'C:\Users\JUAN2\AppData\Local\Programs\pokemon-studio\resources\psdk-binaries\ruby.exe' 'C:\Users\JUAN2\Documents\Dungeon Critters\tools\windows\dpapi_token_proof.rb'
```

Salida real:

```text
Ruby: ruby 3.0.6p216 (2023-03-30 revision 23a532679b) [i386-mingw32]
Fiddle pointer bytes: 4
protect/write/read/current-user round trip: PASS
missing file: PASS (MissingProtectedToken)
corrupt file: PASS (DpapiError)
incorrect entropy: PASS (DpapiError)
invalid magic header: PASS (InvalidTokenHeader)
invalid version header: PASS (InvalidTokenHeader)
invalid length header: PASS (InvalidTokenHeader)
different Windows user or computer: NOT VERIFIED (not executed)
```

El script generó un token falso y una entropía aleatoria en tiempo de ejecución. No imprimió ni escribió en el repositorio un token real. Creó sus archivos de datos únicamente bajo el directorio temporal de Windows y los eliminó al terminar.

## Opciones evaluadas

| Opción | Dependencias | Resultado observado | Decisión |
| --- | --- | --- | --- |
| Fiddle + DPAPI | Biblioteca estándar de Ruby; `crypt32.dll` y `kernel32.dll` de Windows | `require 'fiddle'` funcionó; `Fiddle::SIZEOF_VOIDP` devolvió `4`; el flujo DPAPI pasó las cuatro comprobaciones ejecutadas. | Elegida |
| `win32api` | Biblioteca o gema adicional, según distribución | `require 'win32api'` falló con `cannot load such file -- win32api`. | Descartada en este Ruby |
| FFI u otra gema nativa | Gema adicional y binarios compatibles | **NO VERIFICADO:** no se instaló ni ejecutó, por lo que no se recomienda para este ticket. | No necesaria |

En esta distribución de Ruby, las llamadas Fiddle a Win32 necesitaron dos medidas observadas en la prueba:

1. Crear las funciones `CryptProtectData`, `CryptUnprotectData` y `LocalFree` con `Fiddle::Function::STDCALL`.
2. Añadir un accesor de compatibilidad para `Fiddle.win32_last_socket_error=`. Sin él, la primera llamada Fiddle falló con `NoMethodError` antes de invocar DPAPI. Usar `STDCALL` sin el accesor también falló igual.

Esto debe comprobarse al inicializar el adaptador de Windows. Si falta esa capacidad, el cliente debe desactivar el inicio de sesión persistente y pedir autenticación; no debe usar una alternativa de texto plano.

## Formato de almacenamiento propuesto

El script de prueba escribió un archivo binario:

| Bytes | Campo |
| --- | --- |
| 0-3 | Magia ASCII `DCTK` |
| 4-7 | Versión `1`, entero sin signo little-endian de 32 bits |
| 8-11 | Longitud del texto cifrado, entero sin signo little-endian de 32 bits |
| 12-fin | Salida opaca de `CryptProtectData` |

La entropía no se guarda en ese archivo. En la prueba se generó aleatoriamente y se mantuvo solo en memoria; al usar una entropía distinta, `CryptUnprotectData` falló. Una implementación de producto debe definir cómo obtiene una entropía estable antes de adoptar este formato. No debe confundir una entropía incluida en el binario cliente con un secreto resistente frente a un atacante que controla el equipo.

## Recuperación ante fallo

| Condición | Resultado ejecutado | Comportamiento de producto |
| --- | --- | --- |
| Archivo ausente | `MissingProtectedToken` | No hay sesión persistente; pedir inicio de sesión. |
| Último byte del texto cifrado alterado | `DpapiError` | Considerar el token no recuperable; eliminar o poner en cuarentena el archivo y pedir inicio de sesión. |
| Entropía incorrecta | `DpapiError` | Tratar como token no recuperable; no reintentar con datos relajados. |
| Magia, versión o longitud inválidas | `InvalidTokenHeader` | Rechazar el archivo antes de llamar a DPAPI. |
| Otro usuario de Windows | **NO VERIFICADO:** no se ejecutó. | Tratar el fallo de descifrado como token no recuperable. |
| Otro equipo | **NO VERIFICADO:** no se ejecutó. | Tratar el fallo de descifrado como token no recuperable. |

## Límites

La prueba demuestra una llamada local de ida y vuelta bajo el usuario actual, no propiedades de seguridad entre perfiles, equipos, restauraciones de perfil, cambios de contraseña ni versiones de Windows. Esas situaciones permanecen **NO VERIFICADAS** y requieren pruebas separadas con cuentas y equipos de ensayo.

El script `tools/windows/dpapi_token_proof.rb` solo es válido con el Ruby de 32 bits de PSDK, porque empaqueta los punteros con 4 bytes; no se ha probado con Ruby de 64 bits.
