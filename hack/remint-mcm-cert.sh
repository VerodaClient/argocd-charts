#!/usr/bin/env bash
# Re-mint the MCM managed-cluster client cert off the existing tigera-voltron CA.
# CN must stay my-managed-cluster, Voltron identifies the cluster by client-cert CN.
set -euo pipefail
cd "$(dirname "$0")/.."

CA_SRC=charts/calico-enterprise-configs/templates/tigera-operator-mgmt-cluster-secret.yaml
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

grep 'tls.crt:' "$CA_SRC" | awk '{print $2}' | base64 -d > "$T/ca.crt"
grep 'tls.key:' "$CA_SRC" | awk '{print $2}' | base64 -d > "$T/ca.key"

echo "CA in use:"
openssl x509 -in "$T/ca.crt" -noout -subject -dates | sed 's/^/  /'

openssl genrsa -out "$T/new.key" 2048 2>/dev/null
openssl req -new -key "$T/new.key" -subj "/CN=my-managed-cluster" -out "$T/new.csr" 2>/dev/null
openssl x509 -req -in "$T/new.csr" -CA "$T/ca.crt" -CAkey "$T/ca.key" \
  -CAcreateserial -days 730 -out "$T/new.crt" 2>/dev/null

echo "New leaf:"
openssl x509 -in "$T/new.crt" -noout -subject -issuer -dates | sed 's/^/  /'
openssl verify -CAfile "$T/ca.crt" "$T/new.crt" | sed 's/^/  /'

NEWCRT=$(base64 < "$T/new.crt" | tr -d '\n')
NEWKEY=$(base64 < "$T/new.key" | tr -d '\n')

NEWCRT="$NEWCRT" NEWKEY="$NEWKEY" python3 - <<'PY'
import os, re
crt, key = os.environ["NEWCRT"], os.environ["NEWKEY"]

def patch_mgmt(path):
    out, inblk, n = [], False, 0
    for line in open(path):
        if re.match(r'^\s*managedClusters:', line): inblk = True
        elif re.match(r'^  \S', line) and not re.match(r'^\s*managedClusters:', line): inblk = False
        m = re.match(r'^(\s*certificate:\s*)(\S+)\s*$', line)
        if inblk and m and not line.lstrip().startswith('#'):
            line = f"{m.group(1)}{crt}\n"; n += 1
        out.append(line)
    open(path, 'w').writelines(out)
    print(f"  {path}: {n} certificate field(s) updated")

def patch_mngd(path):
    out, sect, n = [], None, 0
    for line in open(path):
        if re.match(r'^\s*management:\s*$', line):  sect = 'management'
        elif re.match(r'^\s*managed:\s*$', line):   sect = 'managed'
        elif re.match(r'^  \S', line):              sect = None
        if sect == 'managed' and not line.lstrip().startswith('#'):
            m = re.match(r'^(\s*crt:\s*)(\S+)\s*$', line)
            if m: line = f"{m.group(1)}{crt}\n"; n += 1
            m = re.match(r'^(\s*key:\s*)(\S+)\s*$', line)
            if m: line = f"{m.group(1)}{key}\n"; n += 1
        out.append(line)
    open(path, 'w').writelines(out)
    print(f"  {path}: {n} field(s) updated (expect 2)")

print("Patching:")
for p in ["charts/calico-enterprise/values.mgmt.yaml",
          "charts/calico-enterprise-split/values.mgmt.yaml"]:
    if os.path.exists(p): patch_mgmt(p)
for p in ["charts/calico-enterprise/values.mngd.yaml",
          "charts/calico-enterprise-split/values.mngd.yaml"]:
    if os.path.exists(p): patch_mngd(p)
PY
echo "Done. Review with: git diff --stat"
