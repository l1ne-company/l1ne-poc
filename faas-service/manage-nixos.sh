#!/usr/bin/env bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SERVICE_NAME="faas.service"
BINARY_NAME="faas-service"
USER_BIN_PATH="$HOME/.local/bin"
USER_SYSTEMD_PATH="$HOME/.config/systemd/user"

print_status() {
    echo -e "${GREEN}[*]${NC} $1"
}

print_error() {
    echo -e "${RED}[!]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

build() {
    print_status "Building dummy service..."
    cd "$(dirname "$0")"
    
    if ! command -v cargo &> /dev/null; then
        print_error "Cargo not found. Please install Rust."
        exit 1
    fi
    
    cargo build --release
    if [ $? -eq 0 ]; then
        print_status "Build successful!"
    else
        print_error "Build failed!"
        exit 1
    fi
}

install() {
    print_status "Installing dummy service for user..."
    
    # Build first
    build
    
    # Create directories if they don't exist
    mkdir -p "$USER_BIN_PATH"
    mkdir -p "$USER_SYSTEMD_PATH"
    
    # Copy binary
    print_status "Installing binary to $USER_BIN_PATH..."
    cp target/release/$BINARY_NAME "$USER_BIN_PATH/"
    chmod +x "$USER_BIN_PATH/$BINARY_NAME"
    
    # Create user systemd service file
    print_status "Creating user systemd service..."
    cat > "$USER_SYSTEMD_PATH/$SERVICE_NAME" << EOF
[Unit]
Description=Dummy Test Service for Development (User)
After=default.target

[Service]
Type=simple
ExecStart=$USER_BIN_PATH/$BINARY_NAME
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# Resource limits (optional)
MemoryMax=50M
CPUQuota=10%

# Security settings
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF
    
    # Reload user systemd
    systemctl --user daemon-reload
    
    print_status "Installation complete!"
    print_status "You can now use: systemctl --user start $SERVICE_NAME"
    print_status "To enable on login: systemctl --user enable $SERVICE_NAME"
}

uninstall() {
    print_status "Uninstalling dummy service..."
    
    # Stop service if running
    systemctl --user stop $SERVICE_NAME 2>/dev/null
    systemctl --user disable $SERVICE_NAME 2>/dev/null
    
    # Remove files
    rm -f "$USER_SYSTEMD_PATH/$SERVICE_NAME"
    rm -f "$USER_BIN_PATH/$BINARY_NAME"
    
    # Reload user systemd
    systemctl --user daemon-reload
    
    print_status "Uninstallation complete!"
}

start() {
    print_status "Starting dummy service..."
    systemctl --user start $SERVICE_NAME
    status
}

stop() {
    print_status "Stopping dummy service..."
    systemctl --user stop $SERVICE_NAME
    status
}

restart() {
    print_status "Restarting dummy service..."
    systemctl --user restart $SERVICE_NAME
    status
}

status() {
    systemctl --user status $SERVICE_NAME --no-pager
}

logs() {
    print_status "Showing logs (Ctrl+C to exit)..."
    journalctl --user -u $SERVICE_NAME -f
}

metrics() {
    print_status "Service metrics:"
    
    # Get PID
    PID=$(systemctl --user show -p MainPID --value $SERVICE_NAME)
    
    if [ "$PID" -eq 0 ]; then
        print_warning "Service is not running"
        return
    fi
    
    print_status "PID: $PID"
    
    # CPU and Memory from ps
    ps -p $PID -o pid,ppid,%cpu,%mem,rss,vsz,comm --no-headers
    
    # Detailed memory info
    if [ -f /proc/$PID/status ]; then
        echo ""
        print_status "Memory details:"
        grep -E "VmRSS|VmSize|VmPeak" /proc/$PID/status
    fi
    
    # systemd resource info
    echo ""
    print_status "Systemd resource control:"
    systemctl --user show $SERVICE_NAME | grep -E "Memory|CPU|Tasks"
}

test_local() {
    print_status "Testing dummy service locally (Ctrl+C to stop)..."
    
    # Build first
    build
    
    # Run locally
    ./target/release/$BINARY_NAME
}

usage() {
    echo "Usage: $0 {build|install|uninstall|start|stop|restart|status|logs|metrics|test}"
    echo ""
    echo "Commands:"
    echo "  build      - Build the dummy service"
    echo "  install    - Build and install as user systemd service"
    echo "  uninstall  - Remove the user systemd service"
    echo "  start      - Start the service"
    echo "  stop       - Stop the service"
    echo "  restart    - Restart the service"
    echo "  status     - Show service status"
    echo "  logs       - Follow service logs"
    echo "  metrics    - Show CPU and memory usage"
    echo "  test       - Run locally for testing"
    echo ""
    echo "This script uses user systemd services (no sudo required)."
    echo "Services are installed to ~/.config/systemd/user/"
}

case "$1" in
    build)
        build
        ;;
    install)
        install
        ;;
    uninstall)
        uninstall
        ;;
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    logs)
        logs
        ;;
    metrics)
        metrics
        ;;
    test)
        test_local
        ;;
    *)
        usage
        exit 1
        ;;
esac