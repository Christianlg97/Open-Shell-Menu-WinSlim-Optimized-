<a href="#"><img src="Src/Setup/OpenShell.ico" width="80" align="left" alt="Open-Shell"/></a>

# Open-Shell para WinSlim 11

**Adaptación, mejoras y mantenimiento por [Christianlg97](https://github.com/Christianlg97), para el proyecto WinSlim.**

Esta edición de Open-Shell adapta el menú Inicio clásico a WinSlim 11 e incorpora cambios en el motor de búsqueda, las cachés, la interacción con Windows y el instalador. El objetivo es reducir trabajo innecesario, mejorar la respuesta del menú y conservar la personalización visual de WinSlim.

El proyecto parte de **[Open-Shell](https://github.com/Open-Shell/Open-Shell-Menu)**, continuación de **[Classic Shell](http://www.classicshell.net)**, creado por **[Ivo Beltchev](https://sourceforge.net/u/ibeltchev/profile/)**. Las contribuciones propias de esta edición se detallan a continuación.

## Contribuciones de Christianlg97

### Rendimiento y optimización del motor

- **Migración parcial a Rust:** biblioteca estática para validar tamaños de caché y estructuras del Shell, procesar texto UTF-16 y realizar coincidencias de búsqueda. Conserva las reglas de Windows para mayúsculas y acentos y elimina el límite anterior de 99 caracteres por token. La interfaz, los hooks y la integración con el Shell continúan en C++.
- **Búsquedas con menos trabajo en la interfaz:** catálogos compartidos e inmutables, ordenación y resolución de identificadores de aplicaciones en segundo plano, y deduplicación de programas y ajustes sin los recorridos cuadráticos anteriores.
- **Hilos creados a demanda:** los trabajadores de búsqueda se crean cuando hacen falta y se reutilizan. Borrar la consulta cancela el trabajo pendiente sin crear trabajadores adicionales.
- **Menos consultas repetidas a Windows:** índice de ajustes por nombre, reutilización de la geometría de la barra de tareas y apertura del indexador de Windows solo cuando hay ámbitos de búsqueda que consultar.
- **Vigilancia de carpetas más selectiva:** agrupación de notificaciones, espera cancelable y seguimiento de subcarpetas solo donde el menú necesita recorrerlas.
- **Seguimiento del puntero por eventos:** uso de eventos de entrada y salida del ratón en el botón Inicio para evitar su sondeo periódico cuando el seguimiento está disponible, conservando las animaciones y el mecanismo de respaldo.

### Correcciones de estabilidad y respuesta

- **«Abrir ubicación del archivo» sin bloquear el menú:** resolución del destino de los accesos directos en un hilo independiente, con sus propios datos y objetos COM. El menú deja de esperar a que el Explorador termine la operación.
- **Iconos y cachés:** corrección de iconos invertidos al recuperar bitmaps, validación de tamaños y datos antes de leerlos, y descarte de cachés incompatibles o dañadas.
- **Lectura y guardado de caché optimizados:** operaciones agrupadas en búferes, escritura a disco fuera de los bloqueos de datos y conservación de la última caché completa si falla el guardado.
- **Gestión de recursos:** cierre de identificadores de hilos y eventos, comprobación de fallos al crear recursos y correcciones de sincronización en las animaciones de fundido.
- **Botón Inicio en Windows 11:** correcciones de coordenadas y mensajes del ratón, dibujo del botón y secuencia de activación y foco, dirigidas a los problemas de la primera apertura y la convivencia con la barra nativa.
- **CMD y PowerShell como administrador:** soporte de `RUN_AS_ADMIN` y migración una sola vez por usuario de esos dos accesos en configuraciones anteriores. Windows mantiene su solicitud UAC y el resto de preferencias se conserva.

### Integración específica con WinSlim 11

- **Perfil predeterminado de WinSlim:** configuración base editable con Fluent-Metro, botón personalizado, accesos y opciones de búsqueda. Se conservan las animaciones, las preferencias existentes y la prioridad de las directivas.
- **Distribución centrada en el menú Inicio:** retirada de Classic Explorer, Classic IE y Open-Shell Update de los proyectos y del instalador. El canal de actualización de la edición WinSlim queda bajo el mantenimiento de WinSlim.
- **Regeneración de cachés al instalar, actualizar o reparar:** limpieza de archivos regenerables por usuario, con reintento si están bloqueados y conservación de preferencias, accesos anclados y recursos visuales.
- **Integración con el mantenimiento de WinSlim:** etapa del limpiador que programa la regeneración de cachés para el siguiente inicio del menú, con un intervalo predeterminado de 30 días.

### Instalador, compilación y verificación

- **Reinicio controlado del Explorador:** el instalador cierra el Explorador de la sesión al sustituir componentes y vuelve a abrirlo al terminar, también mediante recuperación si la instalación falla. Solo reabre el Explorador que él mismo cerró.
- **Paquetes MSI separados:** generación para x86 y x64 con sus CAB integrados; el modo completo incluye también ARM64 y el instalador EXE.
- **Preparación de herramientas de compilación:** detección de requisitos, instalación de los que falten y comprobación de las descargas mediante SHA-256 o firma digital.
- **Comprobaciones y diagnóstico:** pruebas del núcleo C++/Rust, del perfil y del instalador; verificación de recursos reales de los MSI; herramientas de trazas de interacción y medición de CPU y memoria.

Estas aportaciones describen cambios implementados en el código. Las pruebas pendientes del primer clic y del comportamiento en una sesión nueva, así como las mediciones comparativas necesarias para cuantificar CPU, memoria y latencia del binario resultante, se documentan en [AUDIT_WINSLIM.md](AUDIT_WINSLIM.md) y [PERFORMANCE_WINSLIM.md](PERFORMANCE_WINSLIM.md). No se atribuyen porcentajes de mejora sin una comparación medida.

## Compatibilidad

- La compilación predeterminada con el núcleo Rust está orientada a **Windows 10 y Windows 11**, con integración específica para WinSlim 11.
- El modo `-Legacy` conserva las implementaciones C++ para la compatibilidad con Windows 7/8. ARM64EC utiliza también el núcleo C++.
- Los accesos y utilidades del perfil que apuntan a `%SystemDrive%\WSCore` requieren los componentes correspondientes de WinSlim. El instalador del menú incluye el perfil y sus recursos visuales.

## Compilación y paquetes de WinSlim

La versión predeterminada de las fuentes es **4.4.1008**. Desde la raíz del repositorio:

```bat
build.cmd -Version 4.4.1008 -Language Spanish -MsiOnly
```

Para generar también el instalador EXE y los paquetes ARM64, omitir `-MsiOnly`. Los resultados de una compilación completada se publican en `../Release/` por defecto. `-CheckOnly` permite comprobar requisitos y `-NoInstall` impide la instalación automática de herramientas.

Los requisitos, opciones y pasos de verificación están en [WINSLIM_CHANGES.md](WINSLIM_CHANGES.md). Las [releases del proyecto original](https://github.com/Open-Shell/Open-Shell-Menu/releases) corresponden a Open-Shell upstream y tienen su propio conjunto de componentes y cambios.

## Documentación

- [Cambios de WinSlim e instrucciones de compilación](WINSLIM_CHANGES.md).
- [Revisión de correcciones y validaciones pendientes](AUDIT_WINSLIM.md).
- [Análisis de rendimiento y mediciones](PERFORMANCE_WINSLIM.md).
- [Perfil, skins y botón de WinSlim](Src/Setup/WinSlim/README.md).
- [Mantenimiento de cachés](tools/maintenance/README.md).

## Créditos y licencia

- **Classic Shell:** Ivo Beltchev, creador del proyecto original.
- **Open-Shell:** sus mantenedores y colaboradores, responsables de la base sobre la que se desarrolla esta edición.
- **Edición WinSlim:** Christianlg97, responsable de las adaptaciones, correcciones, optimizaciones e integración descritas en este README.
- **Skins y recursos visuales:** se conservan los metadatos y créditos de sus autores originales; su inclusión en el perfil se documenta en [el perfil de WinSlim](Src/Setup/WinSlim/README.md).

Licencia del repositorio: [MIT](LICENSE). Se conservan los avisos de licencia de los componentes y recursos incluidos.

Recursos del proyecto original: [web de Open-Shell](https://open-shell.github.io/Open-Shell-Menu), [archivo de Classic Shell](https://coddec.github.io/Classic-Shell/www.classicshell.net/), [creación de skins](https://coddec.github.io/Classic-Shell/www.classicshell.net/tutorials/skintutorial.html) y [botones personalizados](https://coddec.github.io/Classic-Shell/www.classicshell.net/tutorials/buttontutorial.html).
