#!/usr/bin/env python3
"""Inventory of what this fork carries on top of AtlasOfLivingAustralia/ala-install.

Classifies every commit in <upstream>/master..<fork branch> as: already upstream, in an
open upstream PR, prepared on a fork branch (PR not opened yet), not queued, or fork-only
by design. Commits are matched by `git patch-id`, falling back to the subject (a PR
branch that was amended after the cherry-pick). Writes Markdown to stdout.

Usage (from the repo root, with `gh` logged in):
    git fetch upstream && git fetch --prune origin
    utils/upstream-inventory.py > UPSTREAM-INVENTORY.md
"""
import argparse
import datetime
import json
import subprocess
import sys

UPSTREAM_REPO = "AtlasOfLivingAustralia/ala-install"
FORK_OWNER = "vjrj"
# Commits that are not meant to go upstream: the subject says so, or they are the
# container adaptation itself.
FORK_ONLY_MARKERS = ("kept out of the upstream", "container adaptation for the application roles")
SKIP_BRANCHES = ("HEAD", "master", "docker-compose-min-pr")
SKIP_BRANCH_PREFIXES = ("bak-",)


def git(*args, inp=None):
    return subprocess.run(["git", *args], capture_output=True, text=True, input=inp, check=False).stdout


def patch_id(commit):
    out = git("patch-id", "--stable", inp=git("show", commit))
    return out.split()[0] if out.strip() else None


def subject(commit):
    return git("log", "-1", "--format=%s", commit).strip()


def commits_ahead(base, head):
    mb = git("merge-base", base, head).strip()
    return git("rev-list", "--reverse", f"{mb}..{head}").split() if mb else []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", default="upstream")
    ap.add_argument("--origin", default="origin")
    ap.add_argument("--branch", default="docker-compose-min-pr")
    a = ap.parse_args()
    up, fork = f"{a.upstream}/master", f"{a.origin}/{a.branch}"

    rows = [line.split("\t", 2) for line in
            git("log", "--reverse", "--format=%H\t%ad\t%s", "--date=short", f"{up}..{fork}").strip().split("\n") if line]
    by_pid = {patch_id(h): h for h, _, _ in rows}
    by_subj = {s: h for h, _, s in rows}
    upstreamed = {line[2:42] for line in git("cherry", up, fork).splitlines() if line.startswith("-")}

    def match(commit):
        h = by_pid.get(patch_id(commit))
        return h or by_subj.get(subject(commit))

    prs = json.loads(subprocess.run(
        ["gh", "pr", "list", "-R", UPSTREAM_REPO, "--author", FORK_OWNER, "--state", "all", "-L", "200",
         "--json", "number,state,title,headRefName,mergedAt"],
        capture_output=True, text=True, check=True).stdout)
    in_pr, pr_heads = {}, set()
    for p in prs:
        pr_heads.add(p["headRefName"])
        # A PR merged before the oldest fork commit cannot carry any of them.
        if p["state"] == "CLOSED" or (p["mergedAt"] or "9999") < rows[0][1]:
            continue
        ref = f"refs/upstream-pr/{p['number']}"
        git("fetch", "-q", a.upstream, f"+pull/{p['number']}/head:{ref}")
        for c in commits_ahead(up, ref):
            h = match(c)
            if h:
                in_pr.setdefault(h, []).append(p)

    prepared, unmatched = {}, []
    for b in git("for-each-ref", "--format=%(refname:short)", f"refs/remotes/{a.origin}/").split():
        name = b.split("/", 1)[1]
        if name in SKIP_BRANCHES or name in pr_heads or name.startswith(SKIP_BRANCH_PREFIXES):
            continue
        ahead = commits_ahead(up, b)
        if not ahead or len(ahead) > 15:
            continue
        hits = [h for h in map(match, ahead) if h]
        for h in hits:
            prepared.setdefault(h, set()).add(name)
        if not hits and name.startswith("pr/"):
            unmatched.append((name, git("log", "-1", "--format=%ad %s", "--date=short", b).strip()))

    groups = {k: [] for k in ("upstream", "open", "prepared", "fork-only", "not-queued")}
    for h, date, s in rows:
        merged = [p for p in in_pr.get(h, []) if p["state"] == "MERGED"]
        opened = [p for p in in_pr.get(h, []) if p["state"] == "OPEN"]
        if h in upstreamed or merged:
            groups["upstream"].append((h, date, s, ", ".join(f"#{p['number']}" for p in merged) or "patch in master"))
        elif opened:
            groups["open"].append((h, date, s, ", ".join(f"#{p['number']} `{p['headRefName']}`" for p in opened)))
        elif any(m in s for m in FORK_ONLY_MARKERS):
            groups["fork-only"].append((h, date, s, ""))
        elif h in prepared:
            groups["prepared"].append((h, date, s, ", ".join(f"`{b}`" for b in sorted(prepared[h]))))
        else:
            groups["not-queued"].append((h, date, s, ""))

    titles = {
        "upstream": ("Already upstream", "Merged upstream (or the same patch is in master): drop on the next rebase."),
        "open": ("In an open upstream PR", "Waiting for review. The PR branch is cut from upstream master."),
        "prepared": ("Prepared on a fork branch, PR not opened", "Branch pushed to the fork, cut from upstream master; open the PR when the queue moves."),
        "not-queued": ("Not queued", "No PR and no PR branch yet: decide whether it goes upstream."),
        "fork-only": ("Fork-only by design", "Container deployment bits kept out of the upstream queue."),
    }
    out = sys.stdout
    out.write("# Upstream inventory\n\n")
    out.write(f"What `{fork}` carries on top of `{up}` ({UPSTREAM_REPO}), generated by "
              f"`utils/upstream-inventory.py` on {datetime.date.today()}: {len(rows)} commits. "
              "Regenerate it after a rebase or when a PR moves; hashes are those of the fork branch at that time.\n\n")
    for k in ("upstream", "open", "prepared", "not-queued", "fork-only"):
        title, desc = titles[k]
        out.write(f"## {title} ({len(groups[k])})\n\n{desc}\n\n")
        if not groups[k]:
            out.write("None.\n\n")
            continue
        extra = k in ("upstream", "open", "prepared")
        out.write("| Commit | Date | Subject |" + (" Where |" if extra else "") + "\n")
        out.write("|---|---|---|" + ("---|" if extra else "") + "\n")
        for h, date, s, where in groups[k]:
            s = s.replace("|", "\\|")
            out.write(f"| {h[:8]} | {date} | {s} |" + (f" {where} |" if extra else "") + "\n")
        out.write("\n")
    if unmatched:
        out.write(f"## PR branches that match no fork commit ({len(unmatched)})\n\n"
                  "Pushed `pr/*` branches with no PR whose commits differ from every fork commit "
                  "(reworded or reworked after the cherry-pick): compare by hand.\n\n")
        for name, last in sorted(unmatched):
            out.write(f"- `{name}`: {last}\n")
        out.write("\n")


if __name__ == "__main__":
    main()
