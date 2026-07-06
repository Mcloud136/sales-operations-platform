#!/usr/bin/env bash
# Sales Operations Platform — Generate Self-Signed SSL Certificate
# Usage: sudo ./generate-ssl.sh [domain_or_ip]
# Default: generates for localhost

set -euo pipefail

DOMAIN="${1:-localhost}"
SSL_DIR="/etc/ssl/sales-ops"
VALIDITY_DAYS=3650  # 10 years

echo "=== Generating Self-Signed SSL Certificate ==="
echo "Domain/IP: $DOMAIN"
echo "Output:    $SSL_DIR"
echo "Validity:  $VALIDITY_DAYS days"

# Create output directory
mkdir -p "$SSL_DIR"

# Generate private key + self-signed certificate
openssl req -x509 -nodes -days "$VALIDITY_DAYS" \
    -newkey rsa:2048 \
    -keyout "$SSL_DIR/server.key" \
    -out "$SSL_DIR/server.crt" \
    -subj "/C=CN/ST=Local/L=Local/O=SalesOps/CN=$DOMAIN" \
    -addext "subjectAltName=DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1,IP:::1"

# Set permissions
chmod 600 "$SSL_DIR/server.key"
chmod 644 "$SSL_DIR/server.crt"

echo "=== SSL Certificate Generated ==="
echo "Certificate: $SSL_DIR/server.crt"
echo "Private Key: $SSL_DIR/server.key"
echo ""
echo "Fingerprint:"
openssl x509 -in "$SSL_DIR/server.crt" -noout -fingerprint -sha256
