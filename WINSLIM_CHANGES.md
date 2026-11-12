# Open-Shell para WinSlim: cambios y compilación

La versión actual por defecto es **4.4.1008**. Classic Explorer, Classic IE y
Open-Shell Update se han retirado de los proyectos y del instalador. Se conserva
el menú, sus skins, idiomas y extensiones necesarias. El módulo Dark Mode se ha
retirado completamente. El [perfil de WinSlim](Src/Setup/WinSlim/README.md) se
instala como configuración base editable, con su skin y botón incluidos.
Conserva las animaciones, el diseño, las funciones y los ajustes de rendimiento
del perfil original. Consultar [la revisión actual](AUDIT_WINSLIM.md) para
los fallos corregidos y las validaciones pendientes. Las secciones históricas
de este documento sobre el actualizador describen código ya retirado.

La [revisión de empaquetado y rendimiento](PERFORMANCE_WINSLIM.md) verifica los
MSI 4.4.1006 ya generados: XML, botón y Fluent-Metro coinciden con las fuentes.
`Verify-Msi.ps1` comprueba ahora también el contenido SHA-256 de los CAB,
carpetas de destino y pertenencia incondicional al menú instalado por defecto.
`Measure-MenuPerformance.ps1` permite registrar CPU y memoria sin modificar
la sesión. Esa revisión de empaquetado no necesitó un nuevo binario.

La revisión **4.4.1007** sí cambia el motor: catálogos de búsqueda compartidos
e inmutables, ordenación/AppID fuera de la interfaz, deduplicación de ajustes
por conjunto, trabajadores creados a demanda, avisos de carpetas agrupados con
espera cancelable y seguimiento del botón por eventos. Conserva el perfil y
sus recursos visuales. Las comprobaciones estáticas pasan; las pruebas nativas
añadidas a `CoreTests` se ejecutarán al compilar. Falta medir el ahorro con el
binario nuevo. Los paquetes existentes siguen siendo 4.4.1006.

Las instalaciones y reparaciones regeneran las cachés del menú sin restablecer
preferencias ni accesos anclados. El VBS de WinSlim puede programar también esa
limpieza, como máximo cada 30 días y sin cerrar el menú durante el mantenimiento.
Consultar [los archivos afectados y la validación](tools/maintenance/README.md).

Los elementos personalizados aceptan `RUN_AS_ADMIN` en `ItemN.Settings`: al
hacer clic se ejecutan elevados, por la misma vía que Ctrl+Mayús+clic (verbo
`runas` del elemento). Windows sigue mostrando UAC. El perfil lo aplica a
Símbolo del sistema y PowerShell. No tiene casilla en el editor, pero el editor
lo conserva al guardar. Desde **4.4.1008**, el primer inicio del menú tras
instalar añade el flag a esos dos accesos en las configuraciones guardadas antes.
Se hace una vez por usuario y no cambia nada más.

## Compilar los MSI separados

Desde CMD en la carpeta del proyecto:

```bat
.\build.cmd
.\build.cmd -Version 4.4.1008 -Language Spanish
```

Al abrir `build.cmd` con doble clic, la ventana espera una tecla al terminar,
tanto si el build finaliza correctamente como si falla. Esto permite leer los
errores de dependencias. La pausa también se aplica al ejecutarlo sin argumentos
desde una consola; con argumentos devuelve el control directamente.

El lanzador solo pide UAC cuando falta algún requisito que haya que instalar, o
cuando quedan MSI de un build elevado anterior: `light.exe` elevado los marca con
integridad alta y un build normal no puede borrarlos («Acceso denegado» en
`Src\Setup\Temp`). Un build elevado baja después esa marca a Medio, de modo que el
siguiente vuelve a compilar sin elevar. Si todo está presente, compila con el token
normal del usuario. Al elevarse
conserva los argumentos y muestra la salida en una consola CMD elevada. Los scripts
PowerShell se usan como auxiliares internos y no abren una consola PowerShell. Si ya
es administrador no vuelve a elevarse; `-CheckOnly` y `-NoInstall` nunca elevan.
La pausa corresponde únicamente a
la consola que realiza el trabajo. Si el título de CMD muestra «Seleccionar»,
pulsa Esc para salir de ese modo de selección y permitir que continúe la consola.

Se reutiliza el flujo original de binarios, idioma, MSI, bootstrapper EXE y
archivos de distribución. Los resultados se publican directamente en
`Release/`, junto al `build.cmd` de la raíz del workspace:

- `OpenShellSetup_4_4_1001_Spanish_x86.msi`
- `OpenShellSetup_4_4_1001_Spanish_x64.msi`
- El instalador EXE original, el MSI ARM64 y los paquetes de distribución.
- Un archivo de comprobaciones SHA-256.

En este proyecto la ruta es `OpenShell Rework for WinSlim/Release/`. Solo se
publican los resultados de una compilación completada. Los scripts originales
conservan sus salidas internas en `Src/Setup/Final`. Puede elegirse otra carpeta
con `-OutputDirectory "C:\ruta\Release"`; el lanzador elevado conserva esa ruta.

Cada MSI incluye sus CAB; no necesita ejecutar `Setup.exe extract`. El MSI x86
mantiene la restricción original de instalación en Windows de 32 bits.

### Reinicio automático del Explorador al instalar

Los MSI y el instalador EXE cierran el Explorador antes de sustituir archivos y lo
vuelven a abrir al terminar, como el comando "Reiniciar Explorador de archivos" de
WinSlim Toolbox (`taskkill /f /im explorer.exe & start explorer.exe`). Así las DLL
cargadas por Explorer no quedan en uso y se evita el error 1603 o el reinicio
pendiente. Se aplica al instalar, actualizar y desinstalar:

1. Tras cerrar `StartMenu.exe` y antes de `InstallValidate`, `SetupHelper exitExplorer`
   pide al Explorador que salga limpiamente (la orden "Salir del Explorador" de la
   barra de tareas) y termina a la fuerza lo que quede en 3 s. Solo actúa sobre los
   `explorer.exe` de la sesión del usuario que instala, no sobre otras sesiones.
2. Tras `InstallFinalize`, `SetupHelper startExplorer` lo vuelve a abrir y espera a
   que exista la barra de tareas (hasta 15 s); después se inicia `StartMenu.exe`.
   Si la instalación falla durante la transacción, la acción de rollback lo reabre.
   El EXE, además, lo reabre si `msiexec` termina con error o cancelación.
3. El Explorador se abre sin elevar aunque el instalador corra como administrador:
   se usa el token limitado de la sesión (`sihost.exe`). Sin UAC dividido, se abre
   igual que `start explorer.exe`.

Solo se reabre un Explorador que el propio instalador cerró (marca volátil
`HKCU\Software\OpenShellSetupStoppedExplorer`). Si se mata antes, como hace un
script que ejecuta `taskkill` previamente, el instalador no abre otro y el script
conserva el control. La desinstalación anidada de una actualización no lo toca.
Para desactivarlo: `msiexec /i OpenShellSetup_...msi RESTARTEXPLORER=0`.

Para generar únicamente los MSI x86 y x64, sin bootstrapper ni paquetes ARM64:

```bat
.\build.cmd -Version 4.4.1001 -Language Spanish -MsiOnly
```

El modo `-MsiOnly` no requiere las herramientas C++ de ARM64 ni 7-Zip.
El modo completo es el predeterminado; `-Full` permite indicarlo explícitamente.
Los scripts originales siguen funcionando independientemente.

Para iterar en local sin recompilar todo, `-Incremental` usa `/t:Build` en lugar
de `/t:Rebuild` (binarios, Setup y tests nativos). MSBuild sigue recompilando lo
que cambie, incluidas las opciones de compilación. Para distribuir, compila sin
`-Incremental`:

```bat
.\build.cmd -MsiOnly -Incremental
```

Requisitos: Visual Studio 2022 con Desktop C++, ATL y Windows SDK, WiX **3.x**
(la receta original usa 3.14), HTML Help Workshop, Rust MSVC mediante rustup,
y Python 3.11 o posterior para las comprobaciones. El modo completo requiere
además 7-Zip, el toolchain C++ de ARM64 y Debugging Tools for Windows (symstore).
Las herramientas pueden estar en PATH. El script prepara los targets Rust
x86/x64, y ARM64 en el modo completo.

`build.cmd` detecta e instala automáticamente los requisitos ausentes antes de
compilar. Reutiliza Visual Studio 2022 y añade los componentes necesarios; WiX
se guarda en `%LOCALAPPDATA%\OpenShellBuild\Tools`. Las descargas se conservan en
`%LOCALAPPDATA%\OpenShellBuild\Downloads` y se verifican mediante SHA-256 o firma
digital. La consola actual recibe las rutas nuevas sin tener que volver a abrirla.
Windows puede solicitar permisos UAC para Visual Studio, SDK, 7-Zip y HTML Help.
No se reinicia el equipo automáticamente: si un instalador requiere reinicio,
el build se detiene con instrucciones para reiniciar y volver a ejecutarlo.

Se usan descargas directas verificadas, sin exigir `winget`. La instalación de
7-Zip escribe un registro en `%LOCALAPPDATA%\OpenShellBuild\Logs`, muestra el PID
y tiempo de espera cada 15 segundos y se deja de esperar a los cinco minutos.
El proceso no se termina automáticamente al agotar ese plazo. Un fallo o espera
agotada impide continuar con la compilación. Los modificadores de `msiexec`
se pasan sin comillas; solo se entrecomillan los valores que lo necesitan.

HTML Help Workshop utiliza los bytes originales de Microsoft conservados en
Archive.org, con SHA-256 fijado; su enlace original ya no está disponible.
Se instala su compilador y se desactiva el actualizador antiguo `hhupd`.

Para preparar las herramientas sin compilar, o impedir instalaciones automáticas:

```bat
.\build.cmd -InstallOnly
.\build.cmd -NoInstall
```

```bat
.\build.cmd -CheckOnly
```

Comprueba requisitos sin compilar, instalar targets ni borrar salidas. Los fallos
detienen el build y devuelven un código distinto de cero. `-SkipTests` permite
omitir explícitamente las pruebas; no se recomienda para distribuir.
`-CheckOnly` tampoco descarga ni instala herramientas.

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

```bat
.\build.cmd -Legacy -MsiOnly
```

Los scripts originales utilizan ese modo C++ por defecto. También puede elegirse
en Visual Studio con `WinSlimUseRustCore=false`, o activarse Rust con
`WinSlimUseRustCore=true`. El puente Rust cubre Win32, x64 y ARM64; ARM64EC
conserva automáticamente el modo C++, incluso cuando está activado Rust para
el build completo. Esto incluye la compilación secundaria ARM64EC que genera
Visual Studio al producir los binarios híbridos ARM64X originales.

Los hooks, ventanas, menús COM, GDI, carga de skins y resolución de accesos
directos siguen en C++. Esta es una migración parcial funcional. No se ha
reescrito la aplicación completa ni se ha añadido un proceso Shell separado.
La skin externa Fluent-Metro, el perfil XML y las rutas WSCore se conservan;
los recursos externos del usuario no se incorporan automáticamente al instalador.

## Correcciones y optimizaciones

- Corregida la inversión vertical de iconos anclados, carpetas y vistas previas
  al recuperar la caché. `GetObject` puede informar una altura positiva para un
  DIB creado de arriba abajo; la copia directa anterior interpretaba sus filas
  al revés. Ahora GDI normaliza una copia propia no seleccionada, conservando
  los píxeles y el canal alfa. La versión 3 de la caché rechaza automáticamente
  las bases de versión 2, incluidas las que ya contienen iconos invertidos.
  El build predeterminado pasa a 4.4.1001 para actualizar la instalación 4.4.1000;
  el MSI original considera una instalación con la misma versión como existente.

- El exportador `Utility.exe extract` devuelve cero tras completar la exportación;
  antes devolvía uno incluso al generar correctamente el CSV y detenía el build.
  Corregidos también un `delete` de array y la liberación de la DLL en un fallo
  de apertura del segundo archivo de recursos.

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
- La comprobación automática semanal de versiones (`Update`) viene desactivada por
  defecto: el canal de versiones es el de Open-Shell original y podría ofrecer
  sustituir WinSlim. Puede activarse en la configuración o por directiva; la
  comprobación manual sigue disponible.
- La búsqueda vuelve a admitir frases entre comillas (`"visual studio"`), como el
  `GetToken` original, tanto en el núcleo Rust como en la implementación C++.
- Al buscar, cada ajuste se compara una sola vez con el texto (antes dos veces en
  cada refresco del hilo de interfaz).
- “Explorar” y “Abrir ubicación del archivo” también cierran el menú Win7 superior
  oculto cuando se usan desde «Todos los programas».
- La caché se lee con un único búfer de 256 KB y se escribe acumulando en memoria:
  sin consultas de tamaño/posición por campo ni escrituras pequeñas por elemento.
  Cada elemento se serializa directamente bajo el bloqueo de lectura, sin copiar
  `ItemInfo` ni clonar PIDLs, y la escritura a disco ocurre fuera del bloqueo.
  El formato del archivo (versión 3) no cambia.
- Un icono que no puede capturarse (por ejemplo, si falla `CopyImage`) se omite
  de la caché en lugar de cancelar todo el guardado; los elementos que lo usan
  cargan el icono predeterminado y lo refrescan. Un guardado fallido se reintenta
  al cabo de un minuto, no en cada cierre del menú.

## Diagnóstico del primer clic

### Acceso de Microsoft Store en el equipo WinSlim

El acceso `Tienda de aplicaciones.lnk` apuntaba como icono a
`C:\WSCore\Components\Visuals\icons\icons8-tienda-microsoft-100.ico`, que no
existe en el equipo. Se ha retirado únicamente esa referencia para que el Shell
use el icono nativo de Store. El PIDL del destino se ha verificado sin cambios
y el acceso original está respaldado en `WinSlim Profile/Backups`.
`tools/Inspect-StoreShortcut.ps1`, `tools/Repair-StoreShortcut.ps1` y
`tools/Verify-StoreShortcut.py` permiten inspeccionar, preparar/aplicar y verificar
esa reparación; no se ejecutan como parte del build ni cambian otros accesos.

### Traza de interacción

```bat
.\tools\interaction-trace.cmd on
REM Reiniciar Open-Shell y reproducir tras iniciar sesión.
REM Registro: %LOCALAPPDATA%\OpenShell\InteractionTrace.log
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

```bat
python .\tools\verify.py
python .\tools\Test-BitmapCache.py
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-Prerequisites.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-BuildLauncher.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-CmdHost.ps1
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
