#!/bin/sh
# SSL Certificate Validator
# Validates SSL certificates before nginx starts
# Checks: file existence, PEM format, expiration, and cert/key match
#
# Usage: Set environment variables before running:
#   CERT_DIR - Directory containing certificates
#   CERT_FILE - Certificate filename
#   KEY_FILE - Private key filename

echo "[*] Validating SSL certificates..."
apk add --no-cache openssl > /dev/null 2>&1

# Read from environment or use defaults
CERT_DIR="${CERT_DIR:-/etc/letsencrypt/live/l-a.site}"
CERT_FILE="${CERT_FILE:-fullchain.pem}"
KEY_FILE="${KEY_FILE:-privkey.pem}"

CERT_PATH="$CERT_DIR/$CERT_FILE"
KEY_PATH="$CERT_DIR/$KEY_FILE"

ERRORS=0
WARNINGS=0

# Check certificate file exists
if [ ! -f "$CERT_PATH" ]; then
  echo "[ERROR] Certificate not found at $CERT_PATH"
  ERRORS=$((ERRORS + 1))
else
  echo "[OK] Certificate found: $CERT_PATH"

  # Validate certificate PEM format
  if ! openssl x509 -in "$CERT_PATH" -noout 2>/dev/null; then
    echo "[ERROR] Certificate is not valid PEM format"
    echo "   Hint: Check if certificate and key are reversed"
    ERRORS=$((ERRORS + 1))
  else
    echo "[OK] Certificate PEM format valid"

    # Check certificate expiration
    if ! openssl x509 -in "$CERT_PATH" -noout -checkend 0 2>/dev/null; then
      echo "[ERROR] Certificate has EXPIRED"
      ERRORS=$((ERRORS + 1))
    else
      EXPIRATION=$(openssl x509 -in "$CERT_PATH" -noout -dates 2>/dev/null | grep notAfter | cut -d= -f2)
      echo "[OK] Certificate valid until: $EXPIRATION"

      # Check if expiring soon (within 30 days)
      if ! openssl x509 -in "$CERT_PATH" -noout -checkend 2592000 2>/dev/null; then
        echo "[WARN] Certificate expires within 30 days"
        WARNINGS=$((WARNINGS + 1))
      fi
    fi
  fi
fi

# Check private key file exists
if [ ! -f "$KEY_PATH" ]; then
  echo "[ERROR] Private key not found at $KEY_PATH"
  ERRORS=$((ERRORS + 1))
else
  echo "[OK] Private key found: $KEY_PATH"

  # Check file permissions (should be readable)
  if [ ! -r "$KEY_PATH" ]; then
    echo "[ERROR] Private key is not readable - check permissions"
    ERRORS=$((ERRORS + 1))
  else
    echo "[OK] Private key is readable"
  fi

  # Validate private key PEM format
  if ! openssl pkey -in "$KEY_PATH" -noout 2>/dev/null; then
    echo "[ERROR] Private key is not valid PEM format"
    echo "   LIKELY CAUSE: Certificate and Private Key are reversed!"
    echo "   Solution: Swap the values of ssl_cert_file and ssl_key_file in inventory"
    ERRORS=$((ERRORS + 1))
  else
    echo "[OK] Private key PEM format valid"
  fi
fi

# Verify certificate and private key match
if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
  CERT_MOD=$(openssl x509 -noout -modulus -in "$CERT_PATH" 2>/dev/null | openssl md5)
  KEY_MOD=$(openssl rsa -noout -modulus -in "$KEY_PATH" 2>/dev/null | openssl md5)

  if [ "$CERT_MOD" != "$KEY_MOD" ]; then
    echo "[ERROR] Certificate and Private Key do NOT match"
    ERRORS=$((ERRORS + 1))
  else
    echo "[OK] Certificate and Private Key match correctly"
  fi
fi

echo ""
echo "================================"
if [ $ERRORS -eq 0 ]; then
  if [ $WARNINGS -gt 0 ]; then
    echo "[SUCCESS] SSL Certificate validation PASSED ($WARNINGS warning(s))"
  else
    echo "[SUCCESS] SSL Certificate validation PASSED"
  fi
  exit 0
else
  echo "[FAILED] SSL Certificate validation FAILED ($ERRORS error(s))"
  if [ $WARNINGS -gt 0 ]; then
    echo "   Plus $WARNINGS warning(s)"
  fi
  echo ""
  echo "SOLUTIONS:"
  echo "1. Check certificate and key files exist and are readable"
  echo "2. Verify certificate is valid PEM format"
  echo "3. Check if certificate and key are reversed (swap ssl_cert_file and ssl_key_file)"
  echo "4. Verify certificate has not expired"
  echo "5. Regenerate certificate pair if needed"
  echo ""
  exit 1
fi
