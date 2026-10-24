#!/usr/bin/env bash
# Nightly off-site backup of mac-main -> Cloudflare R2 (restic repo <bucket>/mac-main, same bucket and
# passphrase as every server's backup.sh). Installed as a LaunchAgent by dr/install-mac-backup.sh.
#
# WHY THIS EXISTS. Every server already backs up nightly, but the Mac is where the work actually lives:
# on 2026-10-24 ~900 commits existed ONLY here (never pushed), plus stashes, uncommitted edits, the
# Paperclip board, agent memory and the SSH keys that reach every server. None of it left the machine.
#
# WHAT IS CAPTURED, and why it is small: for every git repo under ~/Developer, the whole .git directory
# (every branch, tag, stash, reflog, unpushed commit) plus only the files git does NOT already hold —
# modified and untracked files, and ignored files that look like secrets (.env*, keys, keystores). A
# tracked, unmodified file is restored from .git, so copying it again would be 20+ GB of build trees.
#
#   dr/mac-backup.sh               normal nightly run
#   HIBERNATE=1 dr/mac-backup.sh   extra tag `hibernate`: forget never prunes it (see dr/hibernate.sh)
#
# Exit: 0 ok, 1 config error, 2 restic failed. Credentials: ~/.config/bidew/backup.env (0600, same five
# values as /etc/vps-infra/r2.env). Nothing secret is put in an environment variable or on a command line.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
DEV="${BIDEW_BACKUP_ROOT:-$HOME/Developer}"
HOST_TAG="mac-main"
dr_repo "$HOST_TAG" || exit 1
STAGE="$DR_TMP"
umask 077

LIST="$STAGE/files"; : > "$LIST"
add() { [[ -e "$1" ]] && printf '%s\n' "$1" >> "$LIST"; }
SECRETISH='(^|/)\.env([.-][^/]*)?$|\.(pem|p8|p12|pfx|jks|keystore|key|mobileprovision)$|(^|/)(secrets?|credentials)(/|$)|google-services\.json$|GoogleService-Info\.plist$'

echo "-- repos under $DEV --"
nrepo=0
while IFS= read -r gitdir; do
  repo="${gitdir%/.git}"
  add "$gitdir"                                            # all history, refs, stashes, hooks, config
  # modified + untracked-but-not-ignored, then ignored files that look like credentials
  git -C "$repo" ls-files -z -m -o --exclude-standard 2>/dev/null | tr '\0' '\n' | sed "s#^#$repo/#" >> "$LIST"
  git -C "$repo" ls-files -z -o -i --exclude-standard 2>/dev/null | tr '\0' '\n' \
    | grep -E "$SECRETISH" | grep -vE '(^|/)node_modules/' | sed "s#^#$repo/#" >> "$LIST"
  # linked worktrees keep their own uncommitted state outside the main checkout
  git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r wt; do
    [[ "$wt" == "$repo" || ! -d "$wt" ]] && continue
    git -C "$wt" ls-files -z -m -o --exclude-standard 2>/dev/null | tr '\0' '\n' | sed "s#^#$wt/#" >> "$LIST"
  done
  nrepo=$((nrepo+1))
done < <(find "$DEV" -maxdepth 5 \( -name node_modules -o -name .cache -o -name Pods -o -name DerivedData \) -prune -o -type d -name .git -print 2>/dev/null)
echo "   $nrepo repositories"

echo "-- non-repo folders under $DEV (whole, minus build output) --"
for d in "$DEV"/*/; do
  d="${d%/}"
  [[ -d "$d/.git" ]] && continue
  find "$d" -maxdepth 4 -type d -name .git -print -quit 2>/dev/null | grep -q . && continue   # holds repos: covered above
  add "$d"
done

echo "-- machine state --"
P="$HOME/.paperclip/instances/default"
latest_dump=$(ls -t "$P"/data/backups/*.sql.gz 2>/dev/null | head -1)
[[ -n "$latest_dump" ]] && add "$latest_dump"             # Paperclip writes an hourly pg dump; the newest is enough
for p in "$P/companies" "$P/skills" "$P/projects" "$P/secrets" "$P/config.json" \
         "$HOME/.agentmemory" "$HOME/.ssh" "$HOME/.config/bidew" "$HOME/.local/bidew" "$HOME/.openclaw" \
         "$HOME/.claude/CLAUDE.md" "$HOME/.claude/settings.json" "$HOME/.claude/skills" "$HOME/.claude/agents" "$HOME/.claude/commands" \
         "$HOME/.hermes/config.yaml" "$HOME/.hermes/skills" "$HOME/.gitconfig" "$HOME/.zshrc" "$HOME/.zprofile"; do
  add "$p"
done
for m in "$HOME"/.claude/projects/*/memory; do add "$m"; done
# Git-ignored but irreplaceable inside the fleet repo: the CEO's park list and other worker state in data/,
# and the Owner-approved fleet skills in .claude/skills (approveSkill's only copy — see src/core/skills.ts).
BA="$DEV/bidew-ltd/bidew-ai"
for f in "$BA"/data/*.json; do add "$f"; done
add "$BA/.claude"
for f in "$HOME"/Library/LaunchAgents/io.bidew.*.plist; do add "$f"; done
# Things restic cannot back up as files: record them so a rebuild knows what to reinstall.
{ brew bundle dump --file=- 2>/dev/null; } > "$STAGE/Brewfile" && add "$STAGE/Brewfile"
crontab -l > "$STAGE/crontab" 2>/dev/null && add "$STAGE/crontab"
sort -u -o "$LIST" "$LIST"
echo "   $(wc -l < "$LIST" | tr -d ' ') paths"

restic cat config >/dev/null 2>&1 || restic init || { echo "!! cannot open or create $RESTIC_REPOSITORY" >&2; exit 2; }
restic unlock >/dev/null 2>&1 || true

TAGS=(--tag "$HOST_TAG"); [[ "${HIBERNATE:-}" == 1 ]] && TAGS+=(--tag hibernate)
[[ "${DRY_RUN:-}" == 1 ]] && TAGS+=(--dry-run -v)
echo "-- restic backup --"
restic backup --files-from-verbatim "$LIST" --host "$HOST_TAG" "${TAGS[@]}" \
  --exclude-caches --exclude-larger-than 200M \
  --exclude node_modules --exclude .next --exclude .turbo --exclude dist --exclude build --exclude target \
  --exclude .venv --exclude venv --exclude __pycache__ --exclude .gradle --exclude Pods --exclude DerivedData \
  --exclude .expo --exclude coverage --exclude .codegraph --exclude '*.sqlite-shm' --exclude .DS_Store 2>&1 | tail -6
rc=${PIPESTATUS[0]}
# 3 = "some files could not be read" (an iCloud-evicted file, a socket): the snapshot exists and is usable.
if (( rc != 0 && rc != 3 )); then echo "!! restic backup failed (rc=$rc)" >&2; exit 2; fi
[[ "${DRY_RUN:-}" == 1 ]] && { echo "-- dry run: nothing uploaded, nothing pruned --"; exit 0; }

echo "-- prune: 14 daily, 8 weekly, 24 monthly, every 'hibernate' snapshot forever --"
restic forget --host "$HOST_TAG" --group-by host --keep-daily 14 --keep-weekly 8 --keep-monthly 24 --keep-tag hibernate --prune 2>&1 | tail -2

date -u +%FT%TZ > "$HOME/.local/bidew/last-dr-backup"
echo "-- done (rc=$rc) --"
exit 0
