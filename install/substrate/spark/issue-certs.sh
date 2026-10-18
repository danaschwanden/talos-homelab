#!/bin/sh
# Run as root on the Spark. Creates the Spark CA once, then (re)issues the
# server certificates for Postgres and the image registry. The CA key never
# leaves /srv/spark-ca; copy only ca.crt and trusted-roots.yaml back to the repo.
set -eu

CA_DIR=/srv/spark-ca
CERT_DIR=/srv/substrate/certs
SPARK_IP=10.0.2.160
OUT="$(pwd)/out"

umask 077
mkdir -p "$CA_DIR" "$CERT_DIR" "$OUT"

if [ ! -f "$CA_DIR/ca.key" ]; then
  openssl req -x509 -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" \
    -days 3650 -subj "/CN=Spark CA (talos-homelab)" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  echo "created CA in $CA_DIR"
fi

issue() {
  name="$1"
  openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$CERT_DIR/$name.key" -out "$CERT_DIR/$name.csr" \
    -subj "/CN=$name.spark"
  openssl x509 -req -in "$CERT_DIR/$name.csr" \
    -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAcreateserial \
    -out "$CERT_DIR/$name.crt" -days 825 \
    -extfile /dev/stdin <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=IP:$SPARK_IP
EOF
  rm -f "$CERT_DIR/$name.csr"
  echo "issued $CERT_DIR/$name.crt"
}

issue postgres
issue registry

# postgres:18-alpine runs as uid/gid 70 and refuses a key readable by others.
chown 70:70 "$CERT_DIR/postgres.key" "$CERT_DIR/postgres.crt"
chmod 0600 "$CERT_DIR/postgres.key"

# Public artefacts for the repo: the CA certificate, and the Talos document
# that makes every Node trust it.
cp "$CA_DIR/ca.crt" "$OUT/ca.crt"
# Starts with a document separator so it can be appended to a generated
# machine config with `cat >>`.
{
  echo "---"
  echo "apiVersion: v1alpha1"
  echo "kind: TrustedRootsConfig"
  echo "name: spark-ca"
  echo "certificates: |"
  sed 's/^/  /' "$CA_DIR/ca.crt"
} > "$OUT/trusted-roots.yaml"
chmod 0644 "$OUT/ca.crt" "$OUT/trusted-roots.yaml"

echo
echo "copy to the repo:"
echo "  $OUT/ca.crt             -> install/substrate/spark/ca.crt"
echo "  $OUT/trusted-roots.yaml -> install/patches/trusted-roots.yaml"
