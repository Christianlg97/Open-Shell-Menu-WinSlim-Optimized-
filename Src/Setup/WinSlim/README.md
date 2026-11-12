# Perfil predeterminado de WinSlim

`MenuSettings.xml` es el perfil que instala esta distribución. Procede de
`WinSlim Profile/Menu Settings.xml` del workspace. Se han conservado sus valores,
incluidas las animaciones, por petición del usuario. Para modificar los valores
de futuras instalaciones, editar el XML de esta carpeta y ejecutar las pruebas.
La copia externa original se conserva como referencia.

El perfil ya incluye ajustes de rendimiento respecto a la configuración de
fábrica de Open-Shell: historiales y recientes desactivados, búsquedas de archivos
y contenidos desactivadas, comprobación de Windows Update desactivada y sonidos
vacíos. Conserva búsquedas de programas, comandos PATH, apps y ajustes, junto con
los accesos, menús contextuales y utilidades definidos en WinSlim. No se han
desactivado más funciones para atribuirles una mejora de rendimiento sin medir.

Se conservan `PreCacheIcons=1` y `DelayIcons=1`: la precarga en segundo plano y la
carga diferida ayudan a mostrar los iconos con fluidez. También se mantienen
Fluent-Metro, transparencias, sombras, opciones del skin, suavizado, tamaños,
posición y botón personalizado. Las animaciones siguen usando los valores del
perfil original; una velocidad 0 selecciona la velocidad interna predeterminada.

Cuando el Shell ya proporciona los ajustes modernos y no hay búsqueda de
archivos, el motor evita abrir una conexión vacía al indexador de Windows.
Conserva esa conexión como alternativa si el Shell no proporciona los ajustes,
y cuando el usuario activa la búsqueda de archivos.

## Comportamiento instalado

El MSI instala el XML y `StartButton.bmp` en `WinSlim` dentro de la carpeta de
Open-Shell, y ambos skins Fluent-Metro en `Skins`. El motor lee el XML una sola
vez durante su inicialización y lo aplica como valores predeterminados editables.
No ejecuta una importación en HKCU ni añade controladores o procesos residentes.

Los ajustes y políticas del registro conservan su prioridad. Los usuarios con
configuración previa mantienen sus elecciones. «Restablecer valores
predeterminados» recupera los ajustes base; Open-Shell conserva el estilo elegido
por el usuario al restablecer. Si se cambió, seleccionar también «Windows 7 style».
No se muestra el asistente de elección de estilo al primer clic de un usuario nuevo,
puesto que el perfil ya define el estilo.

Al aplicar los valores base, el botón usa el BMP incluido en la instalación.
Esto funciona también si se cambia la carpeta de destino. Una ruta de botón ya
guardada por el usuario tiene prioridad. El XML conserva la referencia original
de WSCore para las importaciones manuales del perfil.

Los accesos y utilidades que apuntan a `%SystemDrive%\WSCore` siguen dependiendo
de esa instalación de WinSlim. Este paquete incluye el menú y sus recursos
visuales; no incorpora los programas externos que ejecutan esos accesos.

## Recursos y comprobaciones

Los dos skins y el botón se copiaron sin modificar desde el WSCore del usuario.
`Assets.json` registra sus SHA-256. Los recursos se distribuyen con sus metadatos
y créditos originales.

```cmd
python tools\Test-WinSlimProfile.py
python tools\verify.py
python tools\Test-InstallerSource.py
```

Las pruebas verifican tipos y opciones del XML, conservación del perfil original,
hashes, los tres estados del botón, recursos cargables de las skins y los textos
Unicode leídos con MSXML. No compilan el proyecto ni modifican el registro.

`tools/Verify-Msi.ps1`, ejecutado por el build para cada MSI, también extrae
únicamente estos cuatro recursos de los CAB incrustados a una carpeta temporal
y compara su SHA-256 con las fuentes. Comprueba que pertenecen a la característica
StartMenu instalada por defecto, sin condiciones, y que las carpetas de destino
dependen de APPLICATIONFOLDER. Una referencia en la tabla File ya no basta para
dar el paquete por válido: se comprueban los bytes que se distribuirán. No usa
`msiexec`, no instala y no ejecuta acciones personalizadas.

El 12 de noviembre se verificaron los MSI **4.4.1006 x86, x64 y ARM64** existentes
en `Release`: los cuatro recursos coinciden byte por byte con las fuentes.
El BMP y las skins también coinciden con la instalación actual del equipo.
El [análisis de rendimiento](../../../PERFORMANCE_WINSLIM.md) incluye una muestra
del build instalado y las oportunidades de mejora pendientes de medir.

Tras compilar e instalar, comprobar con un usuario nuevo y otro ya configurado:
primer clic, elección y restauración de ajustes, iconos, animaciones, búsquedas y
accesos. La validación del nuevo código C++ en ejecución corresponde a ese build.
