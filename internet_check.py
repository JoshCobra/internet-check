#!/usr/bin/env python3
"""
Script para medir la calidad de la conexión a Internet sin dependencias externas.
Mide:
1. Resolución DNS
2. Latencia (Ping), Jitter y Pérdida de paquetes
3. Velocidad de Descarga (Download) via Cloudflare Speedtest
4. Velocidad de Subida (Upload) via Cloudflare Speedtest
5. Diagnóstico y calificación general
"""

import os
import re
import socket
import ssl
import statistics
import subprocess
import sys
import time
import urllib.request
from typing import Dict, Optional, Tuple


def get_ssl_context() -> ssl.SSLContext:
    """Crea un contexto SSL compatible con macOS incluso si Python no tiene certifi instalado."""
    ctx = ssl.create_default_context()
    # En macOS, el instalador oficial de Python a veces no vincula /etc/ssl/cert.pem por defecto
    macos_cert = "/etc/ssl/cert.pem"
    if os.path.exists(macos_cert):
        try:
            ctx.load_verify_locations(cafile=macos_cert)
            return ctx
        except Exception:
            pass
    # Fallback en caso de que el entorno local no tenga certificados raíz configurados
    return ssl._create_unverified_context()


# Colores ANSI para la terminal
class Colors:
    HEADER = "\033[95m"
    BLUE = "\033[94m"
    CYAN = "\033[96m"
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    RED = "\033[91m"
    BOLD = "\033[1m"
    END = "\033[0m"


USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"


def check_dns(domains=("cloudflare.com", "google.com", "github.com")) -> Optional[float]:
    """Mide el tiempo promedio de resolución DNS en milisegundos."""
    times = []
    for domain in domains:
        start = time.perf_counter()
        try:
            socket.gethostbyname(domain)
            elapsed = (time.perf_counter() - start) * 1000
            times.append(elapsed)
        except socket.gaierror:
            pass
    return statistics.mean(times) if times else None


def check_ping(host: str = "1.1.1.1", count: int = 10) -> Dict[str, Optional[float]]:
    """
    Ejecuta ping hacia un host y devuelve latencia promedio, mínima, máxima,
    jitter (desviación estándar) y porcentaje de pérdida de paquetes.
    """
    cmd = ["ping", "-c", str(count), "-i", "0.2", host]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        output = proc.stdout

        # Extraer tiempos individuales: time=14.2 ms
        rtts = [float(x) for x in re.findall(r"time=([\d.]+)\s*ms", output)]

        # Extraer pérdida de paquetes: 0.0% packet loss
        loss_match = re.search(r"([\d.]+)%\s+packet loss", output)
        packet_loss = float(loss_match.group(1)) if loss_match else 100.0

        if not rtts:
            return {
                "avg": None,
                "min": None,
                "max": None,
                "jitter": None,
                "loss": packet_loss,
            }

        return {
            "avg": statistics.mean(rtts),
            "min": min(rtts),
            "max": max(rtts),
            "jitter": statistics.stdev(rtts) if len(rtts) > 1 else 0.0,
            "loss": packet_loss,
        }
    except Exception:
        # Fallback a ping TCP si ICMP falla
        return check_tcp_latency(host, 443, count)


def check_tcp_latency(host: str = "1.1.1.1", port: int = 443, count: int = 5) -> Dict[str, Optional[float]]:
    """Fallback para medir latencia vía conexiones TCP."""
    rtts = []
    failed = 0
    for _ in range(count):
        start = time.perf_counter()
        try:
            with socket.create_connection((host, port), timeout=3):
                rtts.append((time.perf_counter() - start) * 1000)
        except OSError:
            failed += 1
        time.sleep(0.1)

    loss = (failed / count) * 100.0
    if not rtts:
        return {"avg": None, "min": None, "max": None, "jitter": None, "loss": loss}

    return {
        "avg": statistics.mean(rtts),
        "min": min(rtts),
        "max": max(rtts),
        "jitter": statistics.stdev(rtts) if len(rtts) > 1 else 0.0,
        "loss": loss,
    }


def check_download_speed(num_bytes: int = 25_000_000) -> Optional[float]:
    """
    Mide la velocidad de descarga en Mbps descargando datos desde el CDN de Cloudflare.
    Por defecto descarga ~25 MB.
    """
    url = f"https://speed.cloudflare.com/__down?bytes={num_bytes}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    ctx = get_ssl_context()

    try:
        total_read = 0
        chunk_size = 64 * 1024
        start = time.perf_counter()
        with urllib.request.urlopen(req, context=ctx, timeout=30) as response:
            while True:
                chunk = response.read(chunk_size)
                if not chunk:
                    break
                total_read += len(chunk)
                elapsed = time.perf_counter() - start
                if elapsed > 0:
                    current_mbps = (total_read * 8) / (elapsed * 1_000_000)
                    pct = min(100, int((total_read / num_bytes) * 100))
                    sys.stdout.write(
                        f"\r  -> Descargando: {pct:3d}% ({current_mbps:6.2f} Mbps)"
                    )
                    sys.stdout.flush()
                # Si ya pasaron más de 8 segundos, tenemos una muestra suficiente
                if elapsed >= 8.0:
                    break

        elapsed = time.perf_counter() - start
        sys.stdout.write("\r" + " " * 55 + "\r")
        sys.stdout.flush()
        if elapsed <= 0 or total_read == 0:
            return None
        return (total_read * 8) / (elapsed * 1_000_000)
    except Exception as e:
        sys.stdout.write("\r" + " " * 55 + "\r")
        print(f"  {Colors.RED}Error en prueba de descarga: {e}{Colors.END}")
        return None


def check_upload_speed(num_bytes: int = 10_000_000) -> Optional[float]:
    """
    Mide la velocidad de subida en Mbps enviando un payload hacia Cloudflare Speedtest.
    Por defecto sube ~10 MB.
    """
    url = "https://speed.cloudflare.com/__up"
    payload = b"0" * num_bytes
    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "User-Agent": USER_AGENT,
            "Content-Type": "application/octet-stream",
        },
        method="POST",
    )
    ctx = get_ssl_context()

    try:
        sys.stdout.write(f"\r  -> Subiendo {num_bytes / 1_000_000:.0f} MB...")
        sys.stdout.flush()
        start = time.perf_counter()
        with urllib.request.urlopen(req, context=ctx, timeout=30) as response:
            response.read()
        elapsed = time.perf_counter() - start
        sys.stdout.write("\r" + " " * 55 + "\r")
        sys.stdout.flush()
        if elapsed <= 0:
            return None
        return (num_bytes * 8) / (elapsed * 1_000_000)
    except Exception as e:
        sys.stdout.write("\r" + " " * 55 + "\r")
        print(f"  {Colors.RED}Error en prueba de subida: {e}{Colors.END}")
        return None


def evaluate_connection(
    ping_stats: Dict[str, Optional[float]],
    download_mbps: Optional[float],
    upload_mbps: Optional[float],
) -> Tuple[str, str, Dict[str, str]]:
    """Evalúa qué tan buena es la conexión según los resultados."""
    avg_ping = ping_stats.get("avg")
    jitter = ping_stats.get("jitter") or 0.0
    loss = ping_stats.get("loss") or 0.0

    if avg_ping is None and download_mbps is None:
        return "SIN CONEXIÓN", Colors.RED, {}

    score = 100

    # Penalización por latencia
    if avg_ping is not None:
        if avg_ping > 150:
            score -= 35
        elif avg_ping > 80:
            score -= 20
        elif avg_ping > 40:
            score -= 8

    # Penalización por jitter
    if jitter > 30:
        score -= 20
    elif jitter > 10:
        score -= 10

    # Penalización por pérdida de paquetes
    if loss > 5:
        score -= 40
    elif loss > 1:
        score -= 20
    elif loss > 0:
        score -= 10

    # Penalización por velocidad de descarga
    if download_mbps is not None:
        if download_mbps < 5:
            score -= 40
        elif download_mbps < 20:
            score -= 20
        elif download_mbps < 50:
            score -= 10

    # Penalización por velocidad de subida
    if upload_mbps is not None:
        if upload_mbps < 2:
            score -= 20
        elif upload_mbps < 10:
            score -= 10

    score = max(0, min(100, score))

    if score >= 85:
        rating, color = f"EXCELENTE ({score}/100)", Colors.GREEN
    elif score >= 65:
        rating, color = f"BUENA ({score}/100)", Colors.CYAN
    elif score >= 40:
        rating, color = f"REGULAR ({score}/100)", Colors.YELLOW
    else:
        rating, color = f"DEFICIENTE ({score}/100)", Colors.RED

    dl = download_mbps or 0.0
    ul = upload_mbps or 0.0
    p = avg_ping or 999.0

    usos = {
        "Navegación y Redes Sociales": "Óptimo" if dl >= 3 else "Lento",
        "Streaming 4K (Netflix/YouTube)": "Óptimo" if dl >= 25 and loss <= 1 else ("Posible HD (1080p)" if dl >= 8 else "Limitado"),
        "Videollamadas (Zoom/Meet)": "Óptimo" if dl >= 10 and ul >= 5 and p < 100 and jitter < 20 else "Inestable / Calidad media",
        "Gaming Online Competitivo": "Óptimo" if p < 45 and jitter < 10 and loss == 0 else ("Jugable" if p < 90 and loss < 1 else "Con Lag / No recomendado"),
    }

    return rating, color, usos


def format_metric(value: Optional[float], unit: str, good_threshold: float, warn_threshold: float, lower_is_better: bool = True) -> str:
    if value is None:
        return f"{Colors.RED}No disponible{Colors.END}"
    if lower_is_better:
        if value <= good_threshold:
            color = Colors.GREEN
        elif value <= warn_threshold:
            color = Colors.YELLOW
        else:
            color = Colors.RED
    else:
        if value >= good_threshold:
            color = Colors.GREEN
        elif value >= warn_threshold:
            color = Colors.YELLOW
        else:
            color = Colors.RED
    return f"{color}{Colors.BOLD}{value:.2f} {unit}{Colors.END}"


def main():
    print(f"\n{Colors.BOLD}{Colors.HEADER}==================================================={Colors.END}")
    print(f"{Colors.BOLD}{Colors.HEADER}     DIAGNÓSTICO DE CALIDAD DE INTERNET (PYTHON)   {Colors.END}")
    print(f"{Colors.BOLD}{Colors.HEADER}==================================================={Colors.END}\n")

    # 1. Prueba DNS
    print(f"{Colors.BOLD}[1/4] Midiendo resolución DNS...{Colors.END}")
    dns_ms = check_dns()
    print(f"  Tiempo promedio DNS : {format_metric(dns_ms, 'ms', 35, 90, lower_is_better=True)}\n")

    # 2. Prueba de Ping y Estabilidad
    print(f"{Colors.BOLD}[2/4] Midiendo latencia, jitter y pérdida de paquetes (1.1.1.1)...{Colors.END}")
    ping_stats = check_ping("1.1.1.1", count=10)
    print(f"  Latencia promedio   : {format_metric(ping_stats['avg'], 'ms', 40, 90, lower_is_better=True)}")
    if ping_stats["min"] is not None and ping_stats["max"] is not None:
        print(f"  Mínima / Máxima     : {ping_stats['min']:.2f} ms / {ping_stats['max']:.2f} ms")
    print(f"  Jitter (Variación)  : {format_metric(ping_stats['jitter'], 'ms', 8, 20, lower_is_better=True)}")
    print(f"  Pérdida de paquetes : {format_metric(ping_stats['loss'], '%', 0.0, 1.0, lower_is_better=True)}\n")

    # 3. Prueba de Descarga
    print(f"{Colors.BOLD}[3/4] Midiendo velocidad de descarga (Download)...{Colors.END}")
    download_mbps = check_download_speed()
    print(f"  Velocidad Descarga  : {format_metric(download_mbps, 'Mbps', 50, 15, lower_is_better=False)}\n")

    # 4. Prueba de Subida
    print(f"{Colors.BOLD}[4/4] Midiendo velocidad de subida (Upload)...{Colors.END}")
    upload_mbps = check_upload_speed()
    print(f"  Velocidad Subida    : {format_metric(upload_mbps, 'Mbps', 20, 5, lower_is_better=False)}\n")

    # 5. Resumen y Calificación
    rating, color, usos = evaluate_connection(ping_stats, download_mbps, upload_mbps)
    print(f"{Colors.BOLD}---------------------------------------------------{Colors.END}")
    print(f"{Colors.BOLD}CALIFICACIÓN GENERAL: {color}{rating}{Colors.END}")
    print(f"{Colors.BOLD}---------------------------------------------------{Colors.END}")
    if usos:
        print(f"\n{Colors.BOLD}Rendimiento esperado por actividad:{Colors.END}")
        for actividad, estado in usos.items():
            icon = "✅" if "Óptimo" in estado else ("⚠️" if "Posible" in estado or "Jugable" in estado else "❌")
            print(f"  {icon} {actividad:<32}: {Colors.BOLD}{estado}{Colors.END}")
    print()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n{Colors.YELLOW}Prueba cancelada por el usuario.{Colors.END}")
        sys.exit(0)
