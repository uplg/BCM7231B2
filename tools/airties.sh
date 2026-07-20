#!/bin/bash
# UART console for the AirTies AIR 7310T (115200 8N1, logged to logs/).
# Used by `make connect`. Interrupt CFE with Ctrl+C during boot; quit picocom
# with Ctrl+A Ctrl+X.
set -e

BAUD_RATE="${BAUD_RATE:-115200}"
SERIAL_PORT="${SERIAL_PORT:-}"

if [ -z "$SERIAL_PORT" ]; then
    SERIAL_PORT=$(ls /dev/cu.usbserial-* 2>/dev/null | head -1)
fi

case "${1:-connect}" in
connect)
    command -v picocom >/dev/null || { echo "picocom not found (brew install picocom)"; exit 1; }
    if [ -z "$SERIAL_PORT" ] || [ ! -e "$SERIAL_PORT" ]; then
        echo "No serial port found. Available USB-serial devices:"
        ls /dev/cu.usb* 2>/dev/null || echo "  (none)"
        echo "Override with: SERIAL_PORT=/dev/cu.xxx $0 connect"
        exit 1
    fi
    mkdir -p logs
    LOGFILE="logs/uart_$(date +%Y%m%d_%H%M%S).log"
    echo "Connecting to $SERIAL_PORT @ $BAUD_RATE (log: $LOGFILE)"
    echo "Ctrl+C during boot for CFE prompt — Ctrl+A Ctrl+X to quit."
    picocom -b "$BAUD_RATE" --logfile "$LOGFILE" "$SERIAL_PORT"
    ;;
*)
    echo "Usage: $0 [connect]"
    exit 1
    ;;
esac
