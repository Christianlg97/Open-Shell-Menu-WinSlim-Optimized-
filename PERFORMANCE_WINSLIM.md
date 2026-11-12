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
coinciden con el XML salvo `RUN_AS_ADMIN` de CMD y PowerShell: el perfil lo incluye
y la cuenta actual conserva ambos accesos sin ese flag. Se conserva la decisión
ya documentada en `WINSLIM_CHANGES.md`; no se han cambiado los ajustes de la cuenta.

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

## Optimizaciones posibles

Hay margen, sobre todo durante búsquedas, actualización de accesos y sesiones
largas. Son oportunidades basadas en el código, todavía sin ahorro cuantificado.
No se ha cambiado el motor en esta revisión de empaquetado y diagnóstico.

| Prioridad | Evidencia en el código | Cambio a evaluar | Validación necesaria |
|---|---|---|---|
| 1: búsqueda | `CSearchManager::GetSearchResults` copia las listas de programas/ajustes y ordena los programas en cada llamada, en el hilo de interfaz. Los nombres duplicados pueden resolver AppID mediante el Shell. | Publicar listas inmutables por generación, reutilizar el orden mientras no cambien catálogo/rangos y resolver AppID fuera de la interfaz. | Comparar resultados, orden y latencia con catálogos grandes, escritura rápida y enlaces lentos. Conservar la propiedad de los datos al cerrar/cancelar. |
| 2: avisos de carpetas | `CItemManager::PreloadItemsThread` procesa una carpeta notificada y duerme 1000 ms antes de recorrerla; varios avisos pueden ocasionar pasadas consecutivas. | Agrupar las carpetas señaladas en una pasada y hacer la espera cancelable con el evento de cierre. | Ráfagas de altas/bajas en varias carpetas: mismos resultados, menos recorridos, cierre sin esa espera fija. El Sleep actual no consume CPU activamente. |
| 3: hilos de búsqueda | `CSearchManager::Init` crea los ocho hilos de `m_SearchThreads` al iniciar; esperan eventos mientras no hay trabajo. | Evaluar creación gradual y un límite adaptado a la concurrencia real. | Medir memoria comprometida y primera búsqueda. Mantener capacidad de respuesta cuando un proveedor Shell se bloquea; reducir a uno puede empeorarla. |
| 4: caché de iconos | `ItemInfo`/`IconInfo` se prestan a menús y trabajadores. `ClearCache` conserva objetos vivos para no invalidar referencias. | Introducir propiedad explícita y generaciones antes de implantar un presupuesto de memoria o expulsión de entradas. | Sesiones largas, varios DPI, muchas apps, limpieza durante búsqueda y menús abiertos; medir bytes y objetos GDI. No liberar punteros aún prestados. |
| 5: seguimiento del botón | `CStartButton::OnTimer` comprueba la salida del puntero cada 30 ms mientras está sobre el botón/zona ampliada. | Evaluar seguimiento por eventos y reservar sondeo para la zona de compatibilidad de la barra. | Medir CPU con puntero quieto sobre el botón, varios monitores y barra autooculta; conservar hover, clic y animación. El temporizador ya se cancela al salir. |

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

Verificación realizada: 5 pruebas del perfil, 25 comprobaciones generales,
12 variantes de fuente del instalador con XSD y extracción/hash de los cuatro
recursos en los tres MSI existentes. El verificador rechaza un XML de referencia
distinto y un botón de referencia ausente. Falta una instalación de prueba con
usuario nuevo para validar visualmente el primer inicio sin preferencias previas.
