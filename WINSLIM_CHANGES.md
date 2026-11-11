# Open-Shell para WinSlim: cambios y compilación

## Compilar los MSI separados

Desde PowerShell en la carpeta del proyecto:

```powershell
.\build.cmd
.\build.cmd -Version 4.4.1000 -Language Spanish
```

Se reutiliza el flujo original de binarios, idioma, MSI, bootstrapper EXE y
archivos de distribución. Los resultados se publican directamente en
`Src/Setup/Final/`:

- `OpenShellSetup_4_4_1000_Spanish_x86.msi`
- `OpenShellSetup_4_4_1000_Spanish_x64.msi`
- El instalador EXE original, el MSI ARM64 y los paquetes de distribución.
- Un archivo de comprobaciones SHA-256.

Cada MSI incluye sus CAB; no necesita ejecutar `Setup.exe extract`. El MSI x86
mantiene la restricción original de instalación en Windows de 32 bits.

Para generar únicamente los MSI x86 y x64, sin bootstrapper ni paquetes ARM64:

```powershell
.\build.cmd -Version 4.4.1000 -Language Spanish -MsiOnly
```

El modo `-MsiOnly` no requiere las herramientas C++ de ARM64 ni 7-Zip.
El modo completo es el predeterminado; `-Full` permite indicarlo explícitamente.
Los scripts originales siguen funcionando independientemente.

Requisitos: Visual Studio 2022 con Desktop C++, ATL y Windows SDK, WiX **3.x**
(la receta original usa 3.14), HTML Help Workshop, Rust MSVC mediante rustup,
y Python 3.11 o posterior para las comprobaciones. El modo completo requiere
además 7-Zip, el toolchain C++ de ARM64 y Debugging Tools for Windows (symstore).
Las herramientas pueden estar en PATH. El script prepara los targets Rust
x86/x64, y ARM64 en el modo completo.

```powershell
.\build.cmd -CheckOnly
```

Comprueba requisitos sin compilar, instalar targets ni borrar salidas. Los fallos
detienen el build y devuelven un código distinto de cero. `-SkipTests` permite
omitir explícitamente las pruebas; no se recomienda para distribuir.

## Migración a Rust y compatibilidad

El build nuevo activa una biblioteca estática Rust sin dependencias de terceros.
Contiene validación de tamaños de caché y PIDLs, el escáner de líneas UTF-16 y el
algoritmo de coincidencia de búsqueda. La búsqueda conserva las reglas Windows
de mayúsculas y acentos mediante `FindNLSStringEx`; elimina el límite anterior
de 99 caracteres por token. El escáner recorre el texto linealmente y admite
CRLF/LF, comentarios y espacios finales.

La interfaz C presta buffers durante cada llamada; la memoria continúa bajo el
control de C++. No pasan `CString`, objetos COM, recursos GDI ni asignaciones
Rust entre lenguajes. Las funciones exportadas capturan panics con unwind.
El CRT Rust es estático; el enlace Debug usa el CRT de depuración del anfitrión.

Los targets Rust MSVC actuales requieren Windows 10/11. El MSI lo comprueba
leyendo `CurrentBuildNumber`; `VersionNT` no sirve para distinguir Windows 8.1
de Windows 10/11. Para conservar Windows 7/8 con las implementaciones C++ del
mismo contrato:

```powershell
.\build.cmd -Legacy -MsiOnly
```

Los scripts originales utilizan ese modo C++ por defecto. También puede elegirse
en Visual Studio con `WinSlimUseRustCore=false`, o activarse Rust con
`WinSlimUseRustCore=true`. El puente Rust cubre Win32, x64 y ARM64; ARM64EC
conserva el modo C++.

Los hooks, ventanas, menús COM, GDI, carga de skins y resolución de accesos
directos siguen en C++. Esta es una migración parcial funcional. No se ha
reescrito la aplicación completa ni se ha añadido un proceso Shell separado.
La skin externa Fluent-Metro, el perfil XML y las rutas WSCore se conservan;
los recursos externos del usuario no se incorporan automáticamente al instalador.

## Correcciones y optimizaciones

- Resultado booleano de `SHGetPathFromIDList` y `SHGetFileInfo` comprobado como
  booleano, sin `SUCCEEDED`.
- Conversión ANSI con la misma página de códigos al medir y convertir; límites
  y comprobaciones de tamaño antes de leer BOMs y reservar texto.
- Cierre de `m_ExitEvent` y de cada hilo válido del buscador.
- Caché con longitudes, dimensiones, PIDLs, flags y terminación comprobados.
  Las excepciones de lectura descartan la caché; los fallos de escritura no
  reemplazan la última base completa.
- Instantáneas propias de píxeles y metadatos; escritura de caché y del registro
  de diagnóstico fuera de los bloqueos de items/iconos. Se conserva
  `DataCache.txt` cuando está activado `LOG_CACHE`.
- Encolado de iconos con pertenencia O(1), manteniendo las dos prioridades.
- Resultados de búsqueda calculados desde una instantánea; resolución Shell
  fuera de `LOCK_DATA` y deduplicación agrupada por nombre y AppID.
- “Limpiar caché” elimina la base persistida e impide volver a publicarla en esa
  sesión. Los objetos en memoria permanecen hasta reiniciar Open-Shell para no
  invalidar referencias de menús, búsqueda o trabajadores. Esto incluye la
  carrera con un guardado que ya estuviera en curso.
- “Abrir ubicación del archivo” usa una copia propia del PIDL y resuelve el
  destino del `.lnk` en un hilo STA. El menú no espera a Explorer. El hilo mantiene
  cargada la DLL hasta terminar y libera COM antes de cerrar su apartment.
  “Explorar” conserva su significado de abrir la ubicación del propio elemento.
- Los handlers `IContextMenu` permanecen en el hilo donde fueron creados;
  corregido también el tamaño en caracteres del buffer Unicode de verbos.
- Mensajes del botón reenviados con coordenadas locales y estado de botones y
  modificadores; ruedas y botones X conservan sus datos. En Windows 11, la apertura
  por ratón se difiere a un mensaje propio para completar antes la activación del
  clic. El primer dibujo usa el tamaño del frame y registra fallos GDI.
- El actualizador exige una firma Authenticode de confianza aunque los metadatos
  no indiquen editor, y lo comprueba si se indica. Rechaza errores HTTP y descargas
  excesivas. Un instalador local sin firma no es aceptado por el actualizador.

## Diagnóstico del primer clic

```powershell
.\tools\interaction-trace.cmd on
# Reiniciar Open-Shell y reproducir tras iniciar sesión.
# Registro: %LOCALAPPDATA%\OpenShell\InteractionTrace.log
.\tools\interaction-trace.cmd off
```

El cambio de activación se aplica al reiniciar Open-Shell. La captura guarda en
memoria hasta 256 eventos; un trabajador escribe el archivo, limitado a unos
4 MB. Los hooks no escriben en disco. El registro incluye tiempo, hilo, HWND,
clases de ventana, foco, mensajes, argumentos y etapas de apertura de ubicación.
Los eventos 1–10 corresponden al enum `TInteractionTrace` de `LogManager.h`.
Está desactivado por defecto.

La causa exacta del cuadrado del primer clic necesita comprobarse con el binario
nuevo y una sesión recién iniciada; las correcciones de mensajes y dibujo no
sustituyen esa prueba. No se ignoran indiscriminadamente pérdidas de foco.

## Verificación

Sin compilar:

```powershell
python .\tools\verify.py
rustfmt --edition 2021 --check .\Src\RustCore\src\lib.rs
```

El build ejecuta, salvo `-SkipTests`: comprobaciones de fuente/XML y regresiones
Win32 aisladas, tests unitarios Rust en x86/x64, tests nativos del puente C++/Rust
en ambas arquitecturas, y lectura del MSI generado para comprobar arquitectura,
versión y CABs incrustados. `-Legacy` ejecuta los tests nativos del núcleo C++.

La verificación de escritorio pendiente debe realizarse sobre instalaciones de
prueba, después de compilar:

1. Instalar cada MSI en su arquitectura; comprobar la versión efectivamente
   cargada por Explorer y conservar el perfil WinSlim.
2. En sesiones distintas, probar primero clic custom y primero tecla Windows;
   repetir con DPI 100/150/200 %, varios monitores y barra autooculta.
3. Abrir ubicación de un anclado y de un documento reciente: debe seleccionarse
   el destino correcto. Probar también un enlace roto y uno de red inaccesible;
   el menú debe seguir respondiendo mientras termina el trabajador.
4. Limpiar caché durante precarga/búsqueda, abrir de nuevo el menú y reiniciar
   Open-Shell: no deben aparecer cierres ni referencias inválidas; la base no
   se vuelve a guardar hasta ese reinicio.
5. Comparar latencia de clic, apertura de Explorer, CPU, memoria privada y número
   de objetos GDI con la versión anterior. No se atribuye una mejora porcentual
   al cambio de lenguaje sin esas mediciones.

La regla local `AI_MAP.md` reserva todas las compilaciones para el usuario. Durante
la implementación se ejecutan comprobaciones sin compilación; no se instala ni
reemplaza la DLL que está usando Explorer.
