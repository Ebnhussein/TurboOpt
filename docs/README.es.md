# Turbo Optimizer: optimizador, limpiador y reparador gratuito de Windows 10/11

[English](../README.md) | [العربية](README.ar.md) | **Español** | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt.md) | [Русский](README.ru.md) | [简体中文](README.zh.md) | [हिन्दी](README.hi.md) | [Türkçe](README.tr.md)

Herramienta de código abierto en PowerShell para **optimizar, limpiar y reparar Windows**. Analiza tu PC, explica qué falla y arregla solo lo que elijas: arranque lento, disco C: lleno, errores de Windows Update, archivos DLL que faltan, problemas de controladores, Wi-Fi y Bluetooth que se cortan. Cada cambio queda registrado y puedes **deshacerlo**.

Sin instalador, sin anuncios, sin telemetría. Pega una línea en PowerShell: descarga la herramienta, la abre en una ventana moderna del navegador y te pregunta qué quieres.

![Resultados del Doctor](ui-doctor-ar.png)

## Funciones

- **Doctor:** revisa actualizaciones, controladores, DLL, salud del disco, seguridad y registro de eventos, y arregla lo que elijas.
- **Limpiador de PC:** temporales, caché de actualizaciones y navegadores, analizador de espacio, TRIM para SSD, eliminación de apps preinstaladas.
- **Quitar programas por completo:** ejecuta el desinstalador de cada programa, busca lo que deja (carpetas, claves del registro, tareas) y lo borra solo con tu permiso. Los archivos van a la papelera y todo se puede deshacer.
- **Monitor y resumen del equipo:** uso de procesador, memoria, disco y red en vivo, una puntuación de salud con consejos y alertas, cerrar programas pesados y un historial de rendimiento que muestra por qué el equipo iba lento.
- **Acelerar Windows:** plan de energía de rendimiento, gestor de inicio, servicios opcionales.
- **Actualizar y reparar:** apps con winget, SFC y DISM, copia y restauración de controladores.
- **Red:** arreglos de Wi-Fi y Bluetooth, prueba de DNS, revisión del archivo hosts y del canal Wi-Fi.
- **Seguridad:** firewall, SMBv1, Escritorio remoto, UAC y Defender desactivable y reversible.
- **Seguridad primero:** modo de prueba, punto de restauración y registro para deshacer.

## Problemas frecuentes

- **Bluetooth conectado pero sin sonido** en Windows 10: arreglo de Bluetooth sin sonido.
- **El Wi-Fi se desconecta o se cuelga:** reinicio rápido de Wi-Fi y desactivar el ahorro de energía.
- **Disco C: lleno y PC lenta:** limpiar archivos, liberar espacio y programas de inicio.
- **Windows Update atascado** o **falta un DLL** (d3dx9, etc.): el Doctor lo arregla.
- **Quitar bloatware** y activar o desactivar Windows Defender de forma reversible.

## Inicio rápido

```powershell
irm https://ebnhussein.github.io/TurboOpt/i.txt | iex
```

Abre PowerShell y pega esta línea. Descarga la herramienta, la abre en el navegador y te pregunta qué quieres (incluido el cuidado automático: limpieza semanal o vigilancia diaria).
