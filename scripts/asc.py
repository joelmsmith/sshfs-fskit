#!/usr/bin/env python3
"""Minimal App Store Connect API client (stdlib + openssl, no pip installs).

  scripts/asc.py GET  /v1/bundleIds
  scripts/asc.py POST /v1/profiles '{"data": ...}'

Credentials come from the environment (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH)
or from ~/sshfs-signing/asc.env. Keep the .p8 key out of git.
"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error

def load_env():
    path = os.path.expanduser("~/sshfs-signing/asc.env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k, os.path.expandvars(v))

def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b"=")

def der_to_raw(der):
    # ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER } -> r||s, 32 bytes each
    def read_len(b, i):
        n = b[i]; i += 1
        if n & 0x80:
            k = n & 0x7f; n = int.from_bytes(b[i:i+k], "big"); i += k
        return n, i
    assert der[0] == 0x30
    _, i = read_len(der, 1)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        n, i = read_len(der, i + 1)
        out += der[i:i+n].lstrip(b"\0").rjust(32, b"\0"); i += n
    return out

def token():
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    claims = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200,
              "aud": "appstoreconnect-v1"}
    signing_input = b64url(json.dumps(header).encode()) + b"." + b64url(json.dumps(claims).encode())
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.path.expanduser(os.environ["ASC_KEY_PATH"])],
                         input=signing_input, capture_output=True, check=True).stdout
    return (signing_input + b"." + b64url(der_to_raw(der))).decode()

def call(method, path, body=None):
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    data = json.dumps(body).encode() if isinstance(body, (dict, list)) else (body.encode() if body else None)
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": "Bearer " + token(),
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, raw.decode(errors="replace")

if __name__ == "__main__":
    load_env()
    method, path = sys.argv[1], sys.argv[2]
    body = sys.argv[3] if len(sys.argv) > 3 else None
    status, out = call(method, path, body)
    print(json.dumps(out, indent=1) if not isinstance(out, str) else out)
    sys.exit(0 if 200 <= status < 300 else 1)
