# Instalación y rendimiento de WinSlim — 12 de noviembre de 2026

## Resultado de la revisión

Los MSI **4.4.1006 x86, x64 y ARM64** de `../Release` ya contienen el XML de
WinSlim, el botón personalizado y las dos skins Fluent-Metro. Esta revisión
comprobó los recursos reales de los CAB incrustados, sus SHA-256, la inclusión
en StartMenu por defecto y sus carpetas de instalación. No se han compilado,
instalado ni sustituido binarios durante esta revisión.

| Archivo | Destino relativo a la carpeta de instalación |
|---|---|
| MenuSettings.xml | WinSlim/MenuSettings.xml |
| StartButton.bmp | WinSlim/StartButton.bmp |
| Fluent-Metro.skin | Skins/Fluent-Metro.skin |
| Fluent-Metro.skin7 | Skins/Fluent-Metro.skin7 |

El motor carga el XML una vez al inicializar los ajustes, antes del registro.
Un usuario nuevo recibe el perfil de WinSlim y el BMP del propio MSI, también
con una carpeta de instalación personalizada. Las preferencias existentes y
las políticas mantienen prioridad. La carga no requiere importar XML manualmente
ni mantener otro proceso residente. Véase [el perfil](Src/Setup/WinSlim/README.md).

Los recursos visuales del paquete coinciden con los instalados en este equipo;
el botón de WSCore tiene también el mismo hash. Los valores explícitos actuales
coinciden con el XML. Hasta 4.4.1007, CMD y PowerShell se guardaban sin
`RUN_AS_ADMIN`. La cuenta actual se corrigió a mano y su copia previa está en
`WinSlim Profile/Backups`. Desde 4.4.1008, el menú migra esos dos accesos una vez
por usuario. Ver `Lib/SettingsMigration.h` y [la revisión](AUDIT_WINSLIM.md).

Los anclados de `PinnedItemsPath` y los accesos a Seguridad y Sonido siguen
apuntando a WSCore. El MSI incluye el menú y sus recursos visuales; no distribuye
el resto de las utilidades de WinSlim. Un Windows sin WSCore no tendrá esos
accesos y programas solo por instalar este MSI.

## Muestra del build instalado

Se tomaron 31 muestras durante unos 30 segundos, sin interacción automatizada
con el menú ni reiniciar Explorer. La DLL cargada informa **4.4.1006** en ambos
procesos. El equipo expone 16 procesadores lógicos. Es una observación de la
sesión actual, no una comparación antes/después ni una prueba de apertura.

| Proceso | CPU media del equipo | Working set medio | Memoria privada comprometida media | Handles, inicio → fin |
|---|---:|---:|---:|---:|
| StartMenu.exe | 0,0000 % | 17,121 MiB | 3,207 MiB | 211 → 211 |
| explorer.exe completo | 0,0033 % | 273,586 MiB | 191,535 MiB | 4278 → 4278 |

StartMenu.exe tuvo un hilo y Explorer 148 durante la muestra. La memoria privada
varió 0 MiB y +0,004 MiB, respectivamente. No se aprecia actividad continua
elevada en este intervalo; 30 segundos no permiten descartar fugas prolongadas.

El motor se ejecuta dentro de Explorer: sus cifras incluyen Windows y las otras
extensiones, y no pueden atribuirse al menú. El working set incluye páginas
compartidas; los bytes privados representan memoria comprometida y no equivalen
a RAM residente. Véanse las definiciones de
[Microsoft sobre memoria de procesos](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/memory-footprint-optimization).

La caché `DataCache.db` observada ocupa unos 1,22 MiB en disco. Ese tamaño no mide su
coste en RAM: los bitmaps, cadenas, PIDLs y estructuras se expanden al cargarse.
El límite de 512 MiB de `MAX_CACHE_FILE_SIZE` es una defensa de lectura/escritura,
no un presupuesto de memoria de la caché viva.

## Optimizaciones implementadas en las fuentes 4.4.1007

La revisión posterior implementa cuatro de las cinco propuestas. Los MSI de
`Release` siguen siendo 4.4.1006 hasta que el usuario compile. No hay todavía
una medición de ahorro ni una validación de ejecución del motor modificado.

| Área | Cambio implementado | Efecto previsto |
|---|---|---|
| Catálogos de búsqueda | `SearchCatalog.h` ordena programas y agrupa nombres/AppID en el trabajador. `GetSearchResults` toma referencias compartidas a listas inmutables y ordena solo referencias a los ajustes que coinciden. | Evita copiar las listas completas de programas/ajustes, ordenar programas y consultar AppID desde la interfaz en cada actualización. La coincidencia se comprueba antes de suprimir duplicados, para conservar enlaces con palabras clave distintas. |
| Recogida de ajustes | Un conjunto de nombres sustituye el recorrido de todos los ajustes previos por cada entrada. La consulta Shell del nombre usado para el rango se hace fuera de los bloqueos de datos y rangos. | Elimina la deduplicación cuadrática de ajustes y reduce el tiempo durante el que una consulta Shell puede bloquear al lector. |
| Hilos de búsqueda | Cero trabajadores al inicializar; se crea el primero al buscar y se añaden otros cuando todos están ocupados, hasta el límite existente de ocho. Borrar la consulta cancela el trabajo indexado sin crear ni despertar un hilo. | Menos pilas y apartamentos COM antes de buscar; se mantiene la concurrencia frente a proveedores lentos. Los hilos creados se reutilizan hasta cerrar el motor, sin retirada en reposo. |
| Avisos de carpetas | `DirectoryChangeBatch.h` reúne las carpetas señaladas durante la espera de 1000 ms y las rearma antes de recorrerlas. El evento de cierre interrumpe la espera y tiene prioridad. | Una pasada por ráfaga de avisos simultáneos y cierre sin aguardar ese segundo fijo. Los cambios posteriores al rearme quedan pendientes para la siguiente pasada. |
| Botón de Inicio | `TrackMouseEvent`/`WM_MOUSELEAVE` sustituyen el temporizador de salida mientras el puntero está sobre la ventana. | Evita el sondeo de 30 ms sobre el botón. Se mantiene como respaldo si falla el seguimiento o el puntero pasa a la zona ampliada de la barra. Las animaciones conservan su temporizador. |

El catálogo anterior sigue disponible mientras se enumera el siguiente. La
publicación comprueba la generación antes y después de preparar los datos, y
los lectores conservan una referencia propia. El catálogo retirado se libera
fuera del bloqueo de datos cuando ya no tiene lectores. Cerrar el menú invalida
la recogida pendiente; los cambios de consulta reutilizan la recogida en curso.
Los AppID se consultan solo para nombres repetidos. Una primera búsqueda puede
tardar en publicar si uno de esos proveedores Shell es lento; falta medir ese
caso, aunque la llamada ya no se hace en el hilo de interfaz.

El trabajador crea y libera su propio resolvedor de AppID; el resolvedor global
queda reservado a la interfaz. Así se respeta la pertenencia de los objetos a su
[apartamento COM](https://learn.microsoft.com/en-us/windows/win32/com/single-threaded-apartments)
sin trasladar un puntero entre hilos. Los AppID obtenidos se guardan en `ItemInfo`.

La quinta propuesta, **limitar la memoria de iconos expulsando entradas**, queda
pendiente. `ItemInfo`/`IconInfo` se prestan mediante punteros a menús y trabajadores;
requieren propiedad explícita antes de poder liberarse durante la sesión.
`ClearCache` conserva esos objetos vivos. No se introduce una expulsión que
pueda invalidar referencias ni se promete una reducción de RAM en MiB.

### Validación de esta revisión

Sin compilar: las 31 comprobaciones de `tools/verify.py` incluyen publicación por generación, selección
sin Shell en la interfaz, creación gradual de hilos, bloqueo de rangos, agrupación
de avisos, propiedad del resolvedor COM y seguimiento del botón. Las cinco
pruebas del perfil y las doce variantes del instalador con validación XSD
comprueban que los recursos y la integración continúan intactos.

`tools/MenuPerformanceTests.h`, integrado en `CoreTests`, usa los mismos
algoritmos C++ de producción: compara orden, rangos y duplicados con la selección
anterior; incluye palabras clave distintas, AppID vacíos y cancelación. También
comprueba avisos simultáneos en dos carpetas temporales, rearme y cancelación de
la espera. Estas pruebas x86/x64 **se ejecutarán con el próximo build manual**.

Después de compilar, probar primera búsqueda y búsquedas repetidas, escritura
rápida, borrar la consulta, cerrar/reabrir durante la búsqueda, duplicados y
autocompletado de rutas. Probar también hover, clic, varios monitores/DPI y barra
autooculta. Comparar recursos con el mismo catálogo y los mismos escenarios;
las cifras de 4.4.1006 de arriba no cuantifican estas mejoras.

El proyecto ya incorpora búsquedas sin deduplicación cuadrática, índice de
ajustes, guardado de caché con buffers, menos consultas de geometría desde los
hooks y vigilancia no recursiva de carpetas de un nivel. El XML desactiva
historiales, recientes, búsquedas de archivos/contenidos y Windows Update.
Se conserva la precarga/carga diferida de iconos, Fluent-Metro y las animaciones.
Cambiar más opciones visuales no es necesario para estudiar estas mejoras.

## Repetir y comparar

Desde la raíz de `Open-Shell-Menu`, con el build que se quiera medir instalado:

```powershell
.\tools\Measure-MenuPerformance.ps1 -DurationSeconds 60 -Scenario reposo -OutputPath .\build\static-checks\reposo.json
.\tools\Measure-MenuPerformance.ps1 -DurationSeconds 60 -Scenario busquedas -OutputPath .\build\static-checks\busquedas.json
```

En la segunda captura, abrir/cerrar el menú y repetir las mismas búsquedas
manualmente. El script solo lee procesos de la sesión actual y escribe el JSON:
incluye CPU de un núcleo y del equipo, working set, memoria privada, handles,
hilos, versión de la DLL y las muestras originales. No mide latencia de apertura.
La primera muestra se conserva en `build/static-checks/performance-4.4.1006.json`.

Para atribuir CPU/memoria a funciones concretas dentro de Explorer se necesita
una traza con símbolos. Usar los perfiles de CPU y memoria de
[WPR/WPA](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/recording-for-resource-based-analysis)
y repetir los mismos escenarios antes/después, separando la primera apertura
con caché fría de las aperturas posteriores. Para latencia, comparar mediana y
percentil 95 de varias aperturas; no inferirlos del muestreo de procesos.

Verificación anterior de empaquetado: 5 pruebas del perfil, 25 comprobaciones generales,
12 variantes de fuente del instalador con XSD y extracción/hash de los cuatro
recursos en los tres MSI existentes. El verificador rechaza un XML de referencia
distinto y un botón de referencia ausente. Falta una instalación de prueba con
usuario nuevo para validar visualmente el primer inicio sin preferencias previas.
