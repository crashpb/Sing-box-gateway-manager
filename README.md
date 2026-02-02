# Sing-Box Gateway Manager (SBG)

An automated tool to deploy Sing-Box transparent gateways on Linux. 

**Features:**
* **Latency Simulation:** Includes a C-based ICMP Responder for accurate ping tests through the tunnel.
* **Auto-Healing:** Detects and removes stale routing/firewall rules on startup.
* **Traffic Optimization:** Auto-applies TCP MSS clamping to fix SSL hangs (`ERR_CONNECTION_CLOSED`).
* **Live Dashboard:** View real-time traffic and latency via CLI.

### Quick Install

Paste this into your terminal to clone and install everything automatically:

```bash
git clone [https://github.com/crashpb/sing-box-gateway-manager.git](https://github.com/crashpb/sing-box-gateway-manager.git) /opt/sbg-repo && \
cd /opt/sbg-repo && \
chmod +x install.sh && \
sudo ./install.sh


(Note: The installer attempts to download the latest Sing-Box binary automatically. If it fails, you will need to place the binary in /opt/sing-box-gateway-manager/bin/ manually.)
```
### Usage

  1. Create a Configuration:

```Bash
    cd /opt/sing-box-gateway-manager/conf
    cp sample.conf my-tunnel.conf
    nano my-tunnel.conf
```

  2. Start the Gateway:

```Bash
    sbg start my-tunnel
```

  3. Check Status:

```Bash
    sbg status
    # Or for details:
    sbg status my-tunnel
````

  4. Stop:

```Bash
    sbg stop my-tunnel
```

  5. Verification:

```bash  
    You can ping the Virtual IP (displayed in sbg status) from any client connected to the gateway.
    It will report the real-time latency to the upstream proxy.
```

##  Requirements
*    Linux (Ubuntu/Debian recommended)
*    curl, tar
*    Root privileges
