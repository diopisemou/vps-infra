#!/usr/bin/env python3
"""
Put the backup recovery kit somewhere that survives every server being gone. Run it yourself, once
(it needs YOUR Infisical login — `infisical login` first):

    python3 -I dr/escrow.py              # copy the kit into the Infisical project `bidew-dr`, then verify it
    python3 -I dr/escrow.py --show-kit   # print the 5 values once, to save in your password manager

Why: the restic passphrase and R2 keys that open EVERY backup lived only in /etc/vps-infra/r2.env on the
servers (and, since 2026-10-24, ~/.config/bidew/backup.env on this Mac). With the servers gone and the Mac
lost, the backups in R2 would be intact and unopenable. The kit must exist in two places you control that
are neither: Infisical (project `bidew-dr`, which the fleet's read-only identity is NOT a member of, so no
agent can read it) and your password manager.

No value is ever put on a command line or in an environment variable; the source is the local kit file.
"""
import hashlib, json, os, subprocess, sys, urllib.error, urllib.request

HOME = os.path.expanduser("~")
KIT_FILE = os.environ.get("BIDEW_BACKUP_CREDS", f"{HOME}/.config/bidew/backup.env")
KEYS = ["R2_ACCOUNT_ID", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "RESTIC_PASSWORD"]
PROJECT = "bidew-dr"
FLEET_IDENTITY = "bidew-fleet"


def read_kit():
    out = {}
    with open(KIT_FILE) as f:
        for line in f:
            k, _, v = line.strip().partition("=")
            if k in KEYS:
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                    v = v[1:-1]
                out[k] = v
    missing = [k for k in KEYS if not out.get(k)]
    if missing:
        sys.exit(f"!! {KIT_FILE} lacks {', '.join(missing)}")
    return out


def domain():
    try:
        with open(f"{HOME}/.config/bidew/infisical.env") as f:
            for line in f:
                if line.startswith("INFISICAL_DOMAIN="):
                    return line.split("=", 1)[1].strip().strip("'\"").rstrip("/")
    except OSError:
        pass
    return "https://app.infisical.com"


def main():
    kit = read_kit()
    if "--show-kit" in sys.argv:
        acct, bucket = kit["R2_ACCOUNT_ID"], kit["R2_BUCKET"]
        print("Save ALL of this as one secure note, e.g. 'Bidew backup recovery kit':\n")
        for k in KEYS:
            print(f"{k}={kit[k]}")
        print(f"\nrestic repository for host H: s3:https://{acct}.r2.cloudflarestorage.com/{bucket}/H")
        print("hosts: mac-main spare-01 main-host monitoring neobank meet-sso-misc xaalis-prod")
        print("restore guide: github.com/diopisemou/vps-infra -> dr/DISASTER-RECOVERY.md")
        return

    D = domain()
    try:
        tok = subprocess.run(["infisical", "user", "get", "token", "--plain", "--domain", f"{D}/api"],
                             capture_output=True, text=True, check=True).stdout.strip().splitlines()[-1].strip()
    except (subprocess.CalledProcessError, IndexError, FileNotFoundError):
        sys.exit("!! not logged in to Infisical — run `infisical login` first, then re-run this.")
    if tok.count(".") != 2:
        sys.exit("!! `infisical user get token` did not return a session token — run `infisical login`.")

    def api(method, path, body=None):
        req = urllib.request.Request(D + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"authorization": f"Bearer {tok}", "content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            sys.exit(f"!! Infisical {method} {path.split('?')[0]} -> HTTP {e.code}: {e.read().decode(errors='replace')[:300]}")

    projects = api("GET", "/api/v1/projects?type=secret-manager").get("projects", [])
    proj = next((p for p in projects if p.get("name") == PROJECT or p.get("slug") == PROJECT), None)
    if not proj:
        proj = api("POST", "/api/v1/projects", {"projectName": PROJECT, "slug": PROJECT, "type": "secret-manager",
                                               "projectDescription": "Backup recovery kit (restic passphrase + R2 keys). Owner only — no machine identity.",
                                               "shouldCreateDefaultEnvs": True})["project"]
        print(f"+ created Infisical project {PROJECT}")
    pid = proj["id"]

    api("PATCH", "/api/v4/secrets/batch", {"projectId": pid, "environment": "prod", "secretPath": "/", "mode": "upsert",
                                          "secrets": [{"secretKey": k, "secretValue": kit[k]} for k in KEYS]})
    back = api("GET", f"/api/v3/secrets/raw?workspaceId={pid}&environment=prod&secretPath=/")["secrets"]
    got = {s["secretKey"]: s.get("secretValue", "") for s in back}
    h = lambda v: hashlib.sha256(v.encode()).hexdigest()
    bad = [k for k in KEYS if h(got.get(k, "")) != h(kit[k])]
    if bad:
        sys.exit(f"!! read-back mismatch for {', '.join(bad)} — the kit is NOT safely stored")
    print(f"ok  all 5 recovery values stored in Infisical {PROJECT}/prod and read back identical")

    members = api("GET", f"/api/v1/projects/{pid}/identity-memberships").get("identityMemberships", [])
    names = [m.get("identity", {}).get("name") for m in members]
    if FLEET_IDENTITY in names:
        print(f"!! {FLEET_IDENTITY} is a member of {PROJECT}: remove it in the Infisical UI — agents must not read the kit")
    else:
        print(f"ok  no machine identity can read {PROJECT} ({len(names)} identity member(s))")
    print("\nLast step, by you: `python3 -I dr/escrow.py --show-kit` and save the output in your password manager.")


if __name__ == "__main__":
    main()
