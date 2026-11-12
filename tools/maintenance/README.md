# Mantenimiento de las cachés de Open-Shell

Disponible a partir de **4.4.1004**. Los cachés se regeneran automáticamente:

| Archivo en `%LOCALAPPDATA%\OpenShell` | Uso |
|---|---|
| `DataCache.db` | Iconos y metadatos del menú |
| `DataCache.tmp` | Escritura temporal de la caché anterior |
| `ModernSettings.dat` | Índice de páginas de Configuración |
| `DataCache.txt` | Volcado de diagnóstico, si existe |

Se conservan los ajustes, historial/orden del registro, accesos anclados, skins,
botón, XML y registros de diagnóstico. No se elimina la carpeta OpenShell ni se
recorren otros perfiles. No se modifica la caché global de iconos de Windows.
La primera apertura después de una purga puede tardar más mientras se reconstruye.

## Instalación, actualización y reparación

El MSI solicita la limpieza del usuario que instala, después del cierre del menú
y Explorer y antes de validar/sustituir los archivos. Si un archivo sigue en uso,
se conserva `CacheCleanup.pending`: se reintenta al siguiente inicio del menú,
antes de abrir las cachés. No se fuerzan cierres adicionales ni borrados al reiniciar
Windows. Una purga parcial no se considera terminada.

Cada instalación escribe `CacheGeneration` bajo
`HKLM\Software\OpenShell\OpenShell`, con `[ProductCode]|[Date]|[Time]`.
Las reparaciones normales reescriben HKLM mediante la opción `m` del
[REINSTALLMODE de Windows Installer](https://learn.microsoft.com/en-us/windows/win32/msi/reinstallmode).
Los otros usuarios limpian sus propias cachés cuando vuelven a iniciar Open-Shell.
Si una reparación personalizada excluye `m`, solo se fuerza directamente la
limpieza de la cuenta que instala.

`CacheMaintenance.state` confirma la generación atendida; su fecha sirve al VBS
para espaciar el mantenimiento. `CacheMaintenance.lock` evita purgas simultáneas;
es un archivo vacío, no un proceso o servicio. No hay temporizador residente.

## WinSlim_Ultra_CacheCleaner.vbs

Se ha actualizado el archivo de `C:\WSCore\Components\Hooks\WinSlimToolbox`
y se conserva aquí una copia idéntica en UTF-16 LE. La copia previa está en
`WinSlim Profile\Backups` en la raíz del workspace. No se añade el limpiador
del sistema al MSI del menú.

La nueva etapa programa la regeneración para el próximo inicio de Open-Shell;
no interrumpe el menú abierto. No se contabilizan bytes liberados antes de
realizar la purga. Solo se toca la cuenta que ejecuta el script, también cuando
se eleva con credenciales de otro usuario.

- `CLEAN_OPENSHELL_CACHES = True`: activa esta etapa.
- `OPENSHELL_CACHE_DAYS = 30`: como máximo una vez al mes; `0` la programa en cada
  mantenimiento. Evita reconstruir repetidamente las cachés durante el uso diario.
- `/dryrun`: muestra lo que se programaría sin crear la solicitud.
- No se sobrescriben solicitudes pendientes ni se siguen uniones/enlaces.

`OpenShellCacheStep.vbs.inc` contiene el bloque nuevo para revisarlo sin leer el
VBS completo. `Test-OpenShellCaches.py` comprueba que ambas copias coinciden y
ejecuta solo esa etapa en directorios temporales. **Nunca llama a `Main()`**.
Los casos nativos de `tools/CoreTests.cpp` cubren la purga real, archivos bloqueados,
reintento, cambio de generación y conservación de los datos; se ejecutarán cuando
el usuario compile. No se ha ejecutado el mantenimiento real sobre el sistema.
