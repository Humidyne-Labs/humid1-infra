# Humid1 Infrastructure  
Current production IOT server stack for `humid1.com`.  

---

### Inbound Ports Required in Your VPS Firewall

| Port | Protocol | Purpose | Destination / Service |
| :--- | :--- | :--- | :--- |
| **80** | **TCP** | HTTP (Let's Encrypt HTTP-01 challenges & 301 HTTPS redirects) | `bunkerweb:8080` |
| **443** | **TCP** | HTTPS (All web traffic, APIs, WebSockets, Admin UIs) | `bunkerweb:8443` |
| **443** | **UDP** | HTTP/3 / QUIC (High-speed web transport) | `bunkerweb:8443` |
| **8883** | **TCP** | MQTTS (Encrypted IoT device telemetry) | `bunkerweb:8883` |
| **22** *(or custom)* | **TCP** | SSH Server Access | VPS Host (or restrict to Tailscale) |
| *41641* *(optional)* | *UDP* | Tailscale direct WireGuard peer-to-peer connection | Tailscale daemon |

---

### Ports That Must Remain **CLOSED** to the Public

Never open any of these in your VPS or cloud firewall:
* **5432** (PostgreSQL) — Internal only
* **9092 / 9093** (Kafka) — Internal only
* **4222** (NATS) — Internal only
* **6379** (Valkey) — Internal only
* **1883** (Plain MQTT) — Devices must connect via `8883`
* **5000** (BunkerWeb API) — Internal to `proxy-net` only
* **7000** (BunkerWeb UI) — Routed through `https://bw.humid1.com` over port 443

---

[![Donate to Humid1](https://custom-icon-badges.demolab.com/badge/Donate-Humid1.com-4A154B?style=plastic&logo=signupgenius&logoColor=white)](https://tools.signupgenius.com/c/support-humid1-project)

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## 👥 Contributors

[![none](https://wsrv.nl/?url=github.com/Humiditron.png&w=32&h=32&fit=cover&mask=circle&filt=greyscale "@Humiditron")](https://github.com/Humiditron/)
[![none](https://wsrv.nl/?url=github.com/google-gemini.png&w=32&h=32&fit=cover&mask=circle&filt=greyscale "@google-gemini")](https://github.com/google-gemini/)

© 2026 **Humidyne-Labs**
