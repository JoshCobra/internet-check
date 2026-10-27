# 🌐 Internet Check

Herramienta nativa y ultraligera para **macOS** (y terminal en macOS/Linux) que diagnostica en tiempo real la calidad de tu conexión a Internet sin depender de librerías externas.

Creado por **[JoshCobra](https://github.com/JoshCobra)**.

---

##  Características

- **Aplicación nativa para macOS (`InternetCheck.app`)**: Interfaz gráfica fluida con medidores en tiempo real, gráfica de velocidad en vivo, modo claro/oscuro y diagnóstico detallado.
- **Sin dependencias externas**: Funciona con herramientas nativas del sistema (`curl`, `ping`, `awk`).
- **Métricas completas**:
  -  **Señal Wi-Fi (RSSI)**, nivel de ruido y relación señal/ruido (SNR).
  -  **Tiempo de resolución DNS**.
  -  **Latencia (Ping)**, **Jitter** (estabilidad) y **Pérdida de paquetes**.
  -  **Velocidad de Descarga (Download)** en vivo vía Cloudflare Speedtest.
  -  **Velocidad de Subida (Upload)** en vivo vía Cloudflare Speedtest.
  -  **Calificación global (0–100)** y recomendaciones según el uso (Gaming, Videollamadas, Streaming 4K).

---

##  Instalación y Uso

### Opción 1: Aplicación nativa de macOS (`InternetCheck.app`)
1. Descarga `InternetCheck.app.zip` desde la sección de **[Releases](https://github.com/JoshCobra/internet-check/releases)** o clona este repositorio.
2. Abre `InternetCheck.app` y haz clic en **Iniciar Prueba**.
   > **Nota en macOS:** Al estar firmada con certificado de autor independiente (`JoshCobra`), si macOS muestra un aviso la primera vez que la abres, haz **clic derecho (o Control + clic) sobre `InternetCheck.app` → Abrir**, o ejecuta en Terminal:
   > ```bash
   > xattr -cr InternetCheck.app
   > ```

### Opción 2: Desde la Terminal (Bash / Doble clic)
Puedes ejecutar el diagnóstico interactivo con colores directamente en tu terminal o haciendo doble clic en `internet_check.command`:

```bash
chmod +x internet_check.sh
./internet_check.sh
```

### Opción 3: Script en Python (`internet_check.py`)
También se incluye una versión en Python 3 estándar (sin `pip install`):

```bash
python3 internet_check.py
```

---

##  Estructura del Proyecto

- `InternetCheck.app`: Aplicación nativa de macOS (Universal Binary: Apple Silicon `arm64` + Intel `x86_64`), firmada por **JoshCobra** (`com.joshcobra.internetcheck`).
- `internet_check.sh`: Motor principal en Bash para diagnóstico en terminal y emisión de telemetría en tiempo real (`--gui-stream`).
- `internet_check.command`: Lanzador rápido de doble clic para Terminal en macOS.
- `internet_check.py`: Alternativa multiplataforma escrita en Python 3 estándar.

---

## 📄 Licencia y Autoría

Desarrollado y firmado por **JoshCobra** (© 2026).
