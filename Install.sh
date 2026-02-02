#!/bin/bash
# =========================================================
# Sing-Box Gateway Manager Installer
# =========================================================

INSTALL_DIR="/opt/sing-box-gateway-manager"
BIN_DIR="$INSTALL_DIR/bin"
CONF_DIR="$INSTALL_DIR/conf"
SCRIPT_DIR="$INSTALL_DIR/scripts"
RUN_DIR="$INSTALL_DIR/run"
SRC_DIR="$INSTALL_DIR/src"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Root privileges required.${NC}"
  exit 1
fi

echo -e "${GREEN}>>> Installing Sing-Box Gateway Manager...${NC}"

# 1. Directory Setup
mkdir -p "$BIN_DIR" "$CONF_DIR" "$SCRIPT_DIR" "$SRC_DIR" "$RUN_DIR/ids"

# 2. File Installation
echo ">>> Copying scripts and sources..."
cp scripts/core.sh "$SCRIPT_DIR/"
cp scripts/cli.sh "$SCRIPT_DIR/"
chmod +x "$SCRIPT_DIR/core.sh" "$SCRIPT_DIR/cli.sh"
cp src/icmp_responder.c "$SRC_DIR/"

# Install config template only if it doesn't exist
if [ ! -f "$CONF_DIR/sample.conf" ]; then
    cp conf/sample.conf "$CONF_DIR/"
fi

# 3. ICMP Responder Setup
echo ">>> Setting up ICMP Responder..."
if [ -f "bin/icmp_responder" ]; then
    # Use pre-compiled binary if available in repo
    cp bin/icmp_responder "$BIN_DIR/"
    chmod +x "$BIN_DIR/icmp_responder"
else
    # Compile from source
    if command -v gcc &> /dev/null; then
        echo "    Compiling from source..."
        gcc -pthread -o "$BIN_DIR/icmp_responder" src/icmp_responder.c -lcurl
        if [ $? -eq 0 ]; then 
            echo "    Compilation successful."
        else 
            echo -e "${RED}    Compilation failed. Install 'gcc' and 'libcurl4-openssl-dev'.${NC}"
        fi
    else
        echo -e "${YELLOW}    Warning: Pre-compiled binary missing and GCC not found.${NC}"
        echo "    Please install gcc or place 'icmp_responder' in $BIN_DIR manually."
    fi
fi

# 4. Sing-Box Binary (Auto-Download)
echo ">>> Checking Sing-Box binary..."
if [ -f "bin/sing-box" ]; then
    echo "    Using local binary provided in repository."
    cp bin/sing-box "$BIN_DIR/"
    chmod +x "$BIN_DIR/sing-box"
elif [ -f "$BIN_DIR/sing-box" ]; then
    echo "    Sing-Box already exists in target directory."
else
    echo "    Binary not found. Attempting auto-download from GitHub..."
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) SB_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64" ;;
        *) SB_ARCH="" ;;
    esac

    if [ -z "$SB_ARCH" ]; then
        echo -e "${RED}    Unsupported architecture: $ARCH. Please install Sing-Box manually.${NC}"
    else
        # Fetch latest version tag
        LATEST_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/SagerNet/sing-box/releases/latest)
        VERSION=$(echo "$LATEST_URL" | grep -oE "v[0-9]+\.[0-9]+\.[0-9]+" | head -1)
        REAL_VER="${VERSION#v}" # Remove 'v' prefix

        if [ -z "$VERSION" ]; then
            echo -e "${RED}    Failed to detect version. Check internet connection.${NC}"
        else
            DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${REAL_VER}-linux-${SB_ARCH}.tar.gz"
            echo "    Downloading ${VERSION} for ${SB_ARCH}..."
            curl -L -o /tmp/sing-box.tar.gz "$DOWNLOAD_URL"
            
            if [ $? -eq 0 ]; then
                echo "    Extracting..."
                tar -xzf /tmp/sing-box.tar.gz -C /tmp
                # Find the binary inside the extracted folder (folder name varies)
                mv /tmp/sing-box-*/sing-box "$BIN_DIR/" 2>/dev/null
                chmod +x "$BIN_DIR/sing-box"
                rm -rf /tmp/sing-box*
                echo -e "${GREEN}    Sing-Box installed successfully.${NC}"
            else
                echo -e "${RED}    Download failed.${NC}"
            fi
        fi
    fi
fi

# 5. Systemd Service
echo ">>> Installing Systemd Service..."
if [ -f "systemd/sbg@.service" ]; then
    cp systemd/sbg@.service /etc/systemd/system/
    systemctl daemon-reload
else
    echo -e "${RED}Error: systemd/sbg@.service not found in source folder.${NC}"
fi

# 6. CLI Alias
echo ">>> Installing 'sbg' command..."
ln -sf "$SCRIPT_DIR/cli.sh" /usr/local/bin/sbg

# 7. Bash Completion
echo ">>> Installing Bash Completion..."
if [ -d "/usr/share/bash-completion/completions" ]; then
    cp scripts/sbg_completion /usr/share/bash-completion/completions/sbg
elif [ -d "/etc/bash_completion.d" ]; then
    cp scripts/sbg_completion /etc/bash_completion.d/sbg
fi
# Source it immediately for the current session if possible
if [ -f /etc/bash_completion ]; then source /etc/bash_completion; fi

echo -e "${GREEN}>>> Installation Complete!${NC}"
echo ""
echo "Usage:"
echo "  1. Edit config:  cp $CONF_DIR/sample.conf $CONF_DIR/my-tunnel.conf"
echo "  2. Start tunnel: sbg start my-tunnel"
echo "  3. Check status: sbg status"