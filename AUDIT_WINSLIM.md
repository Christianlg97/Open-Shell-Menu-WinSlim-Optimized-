# Revisión del código — 12 de noviembre de 2026

## Migración de accesos de consola (fuentes 4.4.1008)

Las configuraciones guardadas hasta 4.4.1007 conservan Símbolo del sistema y
PowerShell sin `RUN_AS_ADMIN`, aunque el perfil nuevo lo incluye: los valores
de `HKCU` tienen prioridad sobre el XML. `Lib/SettingsMigration.h` añade el flag
solo a los elementos de `MenuItems7` cuyo `Link` efectivo es `cmd.exe` o
`WindowsPowerShell\v1.0\powershell.exe` del directorio de sistema. Se aplica en
`DllInitThread`, antes de `InitSettings`, una vez por usuario
(`WinSlimSettingsMigration=1` en `HKCU\Software\OpenShell\StartMenu`). Así, el
MSI corrige a cada cuenta en su primer inicio del menú y respeta los cambios
posteriores del usuario. No borra ajustes, anclados, skins ni XML. El resto del
valor se reescribe idéntico, byte a byte. Los usuarios sin ajustes guardados no
reciben claves nuevas.

Simulada sobre la copia previa de la cuenta actual, produce exactamente la
corrección manual: cambian dos líneas y una segunda pasada no cambia nada.
`CoreTests` la prueba con una clave volátil temporal; `verify.py` fija el orden de
arranque. La versión sube a 4.4.1008 para que el MSI actualice al 4.4.1007. No se
ha compilado.

## Optimizaciones del motor (fuentes 4.4.1007)

Se implementan cuatro propuestas del [análisis de rendimiento](PERFORMANCE_WINSLIM.md):
catálogos inmutables de búsqueda con AppID y ordenación en el trabajador, hilos
creados a demanda, avisos de carpetas agrupados y cancelables, y seguimiento de
salida del ratón por eventos. También se sustituye la comparación repetida de
nombres de ajustes por un conjunto y se saca la consulta Shell de los bloqueos
de datos/rangos. Se conserva el perfil visual completo.

La publicación valida la generación antes y después de resolver duplicados;
cerrar el menú cancela la recogida y los lectores mantienen su propia referencia.
La selección elimina duplicados después de filtrar, conservando coincidencias
por palabras clave distintas. Vaciar una consulta cancela el trabajo indexado
sin añadir trabajadores. Los avisos se rearman antes de escanear, de modo que
los cambios durante el escaneo quedan pendientes para otra pasada.

La versión por defecto sube a 4.4.1007 para permitir actualizar el MSI instalado.
No se ha compilado, instalado ni cambiado la sesión. Se añaden comprobaciones
estáticas y pruebas nativas de los algoritmos de catálogo y avisos al build manual.
Pendiente: ejecutar esas pruebas x86/x64, validar el menú real y comparar consumo
y latencia. La expulsión de iconos requiere antes resolver la propiedad de los
objetos prestados; no forma parte de este cambio. Los MSI actuales son 4.4.1006.

## Verificación de los paquetes 4.4.1006 y consumo observado

Se han verificado los MSI x86/x64/ARM64 existentes en `Release` mediante
extracción de sus recursos, sin instalar: contienen el XML actual, el BMP
personalizado y ambas skins Fluent-Metro, idénticos a las fuentes. La DLL
cargada en la sesión actual informa 4.4.1006. Esto actualiza el estado de los
binarios indicado en las secciones históricas siguientes.

El [análisis de rendimiento](PERFORMANCE_WINSLIM.md) documenta una muestra de
30 segundos, las dependencias de WSCore y cinco oportunidades de mejora.
El verificador del build comprueba ahora hashes y destinos reales del perfil.
No se ha compilado ni cambiado el motor en esta revisión; el comportamiento
de primer inicio con usuario nuevo sigue necesitando una prueba de instalación.

## Primer clic después de instalar (4.4.1006)

El vídeo `VideoBugPrueba_OpenShell_4.4.1005.mp4` muestra un borde blanco curvo
a la derecha del botón personalizado y un menú que llega a abrirse y se cierra.
El usuario confirma que ocurre solo en el primer clic. El BMP instalado contiene
los tres estados previstos y no incluye ese borde lateral. La inspección del
equipo muestra un botón de OpenShell de 48 píxeles y un área nativa de Inicio de
55, por lo que el contorno nativo puede sobresalir a la derecha.

Se ha corregido una activación intermedia innecesaria en
`CMenuContainer::ToggleStartMenu`: después de activar el botón de OpenShell,
se activaba también `Shell_TrayWnd` antes de mostrar el menú. Esto permite que
la inicialización del foco de la barra XAML compita con el menú recién abierto;
su manejador `WM_ACTIVATE/WA_INACTIVE` lo cierra al perder la activación.
La secuencia es compatible con el síntoma, aunque el vídeo no sustituye una
traza de los mensajes del primer clic.

En Windows 11, con un botón de reemplazo visible, se conserva la activación en
ese botón, que pertenece al mismo hilo que el menú. El cambio incluye la ruta
de `SetActiveWindow` para la barra con ocultación automática. Para botones
nativos, botones ocultos y sistemas anteriores se conserva la ruta de la barra.
No se cambia el BMP, su tamaño, la skin, las animaciones ni el cierre normal del
menú cuando el usuario pasa a otra aplicación.

Validación: 25 comprobaciones de `tools/verify.py`, 12 variantes del instalador
y su XSD con `tools/Test-InstallerSource.py`. Una prueba Win32 con ventanas propias
en un escritorio separado confirma que activar el popup del botón y luego el
menú no activa a su propietario, mientras que la secuencia anterior sí lo hace.
Esa prueba verifica el comportamiento de Win32, no ejecuta la DLL modificada.

Pendiente de compilación manual y prueba real: instalar **4.4.1006** sobre
4.4.1005, hacer el primer clic tras el reinicio de Explorer del instalador,
mover el puntero a la búsqueda y comprobar que el menú sigue abierto y no
aparece el contorno nativo. Comprobar también el segundo clic para cerrar,
clic fuera, teclado, otro monitor y barra con ocultación automática. Los
binarios existentes en `Release/` siguen siendo 4.4.1005 hasta recompilar.

## Segunda revisión (mismo día)

Se compararon todos los cambios de WinSlim con Open-Shell original y se revisaron
las rutas que se ejecutan en cada movimiento del ratón. Los cambios de WinSlim
estaban bien; los fallos corregidos vienen del código heredado:

| Problema | Cambio |
|---|---|
| `PointAroundStartButton` llamaba a `SHAppBarMessage` en cada movimiento del ratón sobre la barra (hook de ratón, subclase de la barra y temporizador de 30 ms del botón) | El borde se guarda por barra en `TaskbarInfo` y solo se vuelve a consultar si cambia el rectángulo de la barra. |
| La lectura de ajustes recorría unos 380 elementos comparando nombres en cada llamada | Índice hash por tipo, creado una vez en `CSettingsManager::Init`; conserva el mismo resultado y el recorrido lineal como respaldo. |
| El Escritorio y las carpetas de un nivel se vigilaban con todo su subárbol | Solo se vigila el subárbol donde se recorre en profundidad (menú Inicio y apps modernas). Escribir en subcarpetas del Escritorio ya no despierta el hilo ni vuelve a recorrer el Escritorio. |
| `GetStartScreenIcon` (Windows 8) esperaba 100 ms y el otro hilo podía escribir después en su pila | Petición en memoria dinámica con dos referencias; la última libera el bitmap y el evento. También comprueba el fallo de `CreateDIBSection`. |
| Cinco `CreateThread` descartaban el identificador del hilo; el fundido lo hacía en cada lanzamiento | Se cierran los identificadores; si falla la creación se liberan los parámetros. |
| `CMenuFader::s_Faders` se modificaba desde varios hilos sin bloqueo, un fundido sin ventana dejaba su hilo esperando para siempre y `ClearAll` podía repetir sin fin `SendMessage` a un `HWND` nulo | `SRWLOCK` para la lista, limpieza si no se crea la ventana y la región se libera si `SetWindowRgn` falla. |

`tools/verify.py` añade una regresión por cada punto. No se ha compilado ni
ejecutado el binario nuevo. La versión por defecto pasa a **4.4.1005**: el MSI
rechaza instalar la misma versión que ya está instalada.

## Primera revisión

El menú tiene ahora mejores límites de caché, menos trabajo del Shell dentro de
bloqueos y búsquedas sin la deduplicación cuadrática anterior. Eso es una mejora
de implementación; faltan mediciones del ejecutable final para afirmar un ahorro
concreto de RAM, CPU o tiempo de apertura. Migrar más código a Rust no elimina
las esperas de COM, disco, extensiones del Shell o GDI.

En esta revisión se han corregido estos problemas:

| Problema | Cambio |
|---|---|
| Fallo de carga de un bitmap de una app moderna tratado como icono resuelto | `LoadMetroIcon` conserva la petición pendiente para que continúe la alternativa del Shell; tampoco calcula un hash con un nombre no obtenido. |
| Ruta del menú sin comillas al cerrarlo desde el instalador | `SetupHelper` usa la ruta explícita del ejecutable, argumentos entre comillas, sin heredar handles y comprueba el valor del registro. |
| Fallo al crear eventos de búsqueda | No se crean hilos con identificadores inválidos; se evita el posible bucle de `WAIT_FAILED`, manteniendo seguros los bloqueos y el cierre. |
| Localización dependiente de cuatro módulos y actualizaciones de recursos sin comprobar | `makeEN` recibe solo el menú, comprueba cada escritura y libera los módulos. El código antiguo también perdía la referencia del módulo del menú al sustituirla por la del actualizador. |
| Componentes no deseados todavía compilados y empaquetados | Retirados Classic Explorer, Classic IE y Update: proyectos, fuentes, copia de binarios, características MSI, accesos y políticas. La utilidad de desinstalación conserva nombres antiguos para limpiar instalaciones anteriores. |

La versión por defecto pasa a **4.4.1004** para permitir actualizar los MSI
anteriores. Los MSI x86/x64 separados siguen publicándose en `Release` en la raíz
del workspace. `Verify-Msi.ps1` comprueba también que no reaparezcan módulos
retirados en el paquete final.

La [limpieza de cachés](tools/maintenance/README.md) se integra en el MSI y en el
VBS de mantenimiento. Solo afecta a cuatro archivos regenerables; las cuentas
adicionales la aplican al iniciar el menú, sin recorrer otros perfiles. Los
archivos bloqueados quedan pendientes. El VBS evita purgas diarias innecesarias
y su etapa se valida de forma aislada, sin ejecutar el mantenimiento del sistema.
La purga nativa y la instalación real quedan pendientes de la compilación manual.

El módulo Dark Mode se ha retirado por petición del usuario, al no funcionar en
sus pruebas. No forma parte de la solución, de los nuevos instaladores ni de sus
procesos de inicio. Al actualizar, la desinstalación del MSI anterior retira sus
componentes.

El [perfil de WinSlim](Src/Setup/WinSlim/README.md) se instala con Fluent-Metro y
el BMP del botón, ambos copiados sin cambios. El lector XML existente se reutiliza
para cargar valores base editables una vez durante el inicio. Se conservan los
ajustes de usuario y las políticas, y «Restablecer» vuelve a la base de WinSlim.
No se introduce un importador residente ni se escribe el perfil sobre HKCU.

El perfil ya desactiva historiales, consultas de Windows Update y búsqueda de
archivos/contenidos. Se conservan las búsquedas de programas, apps, PATH y ajustes,
la precarga y carga diferida de iconos, así como todas las animaciones y el diseño
solicitados. No se ha medido un ahorro adicional ni se atribuye una mejora a
cambiar ajustes que ya estaban optimizados.

Se ha eliminado una conexión redundante al proveedor de Windows Search: cuando
la búsqueda de archivos está desactivada y los ajustes modernos ya se obtuvieron
del Shell, la lista de ámbitos del índice estaba vacía, pero se abría igualmente
la conexión OLE DB. Ahora se comprueba si hay algún ámbito necesario antes de
abrirla, conservando la alternativa del índice y las búsquedas de archivos.

Quedan estos puntos de trabajo:

- **Validación real del primer clic tras iniciar sesión.** Los cambios de eventos
  y geometría del botón necesitan probarse en el build instalado con la imagen
  personalizada y la barra nativa de Windows 11.
- **Latencia externa del Shell.** «Abrir ubicación» ya no espera en el hilo del
  menú, pero una extensión o llamada del Shell puede seguir tardando. Los workers
  por solicitud no tienen un límite global; conviene medir solicitudes simultáneas
  antes de introducir una cola que pueda bloquear todas detrás de una operación
  colgada.
- **Cierre de workers.** Las esperas de cierre siguen pudiendo depender de una
  llamada del Shell que no regrese. Terminar esos hilos a la fuerza dañaría el
  estado de Explorer; la mejora requiere aislar operaciones que puedan bloquear.
- **Perfil de memoria de la caché.** Los objetos prestados a menús abiertos se
  conservan al limpiar la caché para evitar uso después de liberar. Reducir su
  memoria de forma segura requiere referencias compartidas/generaciones, no
  borrar los objetos activos.
- **Pruebas del perfil instalado.** Verificar con un usuario nuevo y otro con
  preferencias existentes la primera apertura, personalización, restauración,
  botón, skins, búsquedas, animaciones y accesos. El código C++ nuevo necesita
  validación en el build instalado.

Se han usado comprobaciones estáticas y pruebas Win32 sin compilación. El agente
no ha compilado, instalado ni ejecutado los nuevos binarios, respetando `AI_MAP.md`.
