#!/usr/bin/env bash
# The one place a build's version is decided; scripts/build-app.sh and the release workflow read it from here.
#
#            release          snapshot
#   label    rc0.1.0          26w43a       the name people see: the GitHub release's title, shown in the app
#   train    0.1.0            0.1.0        CFBundleShortVersionString; a snapshot carries the release it leads to
#   code     126000001        126000002    CFBundleVersion, the only thing that says which build is newer
#   date     26-10-28         26-10-28     the day of the commit, Taipei time
#
# A release tag is a version, optionally a release candidate, with or without the usual `v`:
#   1.1.0, v1.1.0, rc0.1.0, vrc0.1.0, 0.1.0-rc.1, v1.0.0-beta.2
# An RC is published as a pre-release; its train is the version it is a candidate for (rc0.1.0 → 0.1.0). Snapshots
# are tagged with their bare label (26w43a), which has no dots, so the two never collide.
#
# Names can't be compared: a snapshot named after a later week can come before the release it became. The code only
# ever rises, so that's what the updater compares.
#
#   eval "$(scripts/version.sh)"      MOUSELITE_LABEL, _TRAIN, _CODE, _DATE and _PRERELEASE
#   scripts/version.sh --json
#   scripts/version.sh --snapshot     a snapshot even if HEAD carries a release tag, as for a push to main
#
# Needs the full history: actions/checkout with fetch-depth: 0.
set -euo pipefail

# code = <generation><yy><commits this year>: 126000042 is generation 1, 2026, the 42nd commit of 2026. A new year
# adds 1,000,000 while the count starts over, so the code still rises. The generation only changes if the scheme does.
readonly SCHEME=1

# Taipei time: the week in a label is the week of the people reading it.
readonly TZONE='Asia/Taipei'

snapshot_only=0
json=0
for arg in "$@"; do
  case "$arg" in
  --snapshot) snapshot_only=1 ;;
  --json) json=1 ;;
  *)
    echo "usage: $0 [--snapshot] [--json]" >&2
    exit 2
    ;;
  esac
done

commit_ts="$(git log -1 --format=%ct HEAD)"
stamp() { # <format>
  TZ="$TZONE" date -r "$commit_ts" "+$1" 2>/dev/null || TZ="$TZONE" date -d "@$commit_ts" "+$1"
}

year="$(stamp %y)"
commits="$(git rev-list --count HEAD --since="$(stamp %Y)-01-01T00:00:00+08:00")"
code=$((SCHEME * 100000000 + 10#$year * 1000000 + commits))
date="$(stamp %y-%m-%d)"

# 0 → a, 25 → z, 26 → aa
letters() { # <n>
  local i="$1" out=""
  while :; do
    out="$(printf "\\$(printf '%03o' $((97 + i % 26)))")$out"
    i=$((i / 26 - 1))
    [ "$i" -lt 0 ] && break
  done
  printf '%s' "$out"
}

# A release tag is a version, optionally a release candidate. `release_tag_info` prints
# "<base> <prerelease 0|1> <label>" or returns 1:
#   1.1.0  v1.1.0  rc0.1.0  vrc0.1.0  0.1.0-rc.1  v1.0.0-beta.2
# The base is what goes into CFBundleShortVersionString; the label is what people see.
release_tag_info() { # <tag>
  local raw=${1#v} base="" prerelease=1
  case "$raw" in
  rc[0-9]*) base=${raw#rc} ;;
  *-rc*) base=${raw%%-rc*} ;;
  *-beta*) base=${raw%%-beta*} ;;
  *-alpha*) base=${raw%%-alpha*} ;;
  *)
    [[ $raw =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
    base=$raw
    prerelease=0
    ;;
  esac
  [[ $base =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
  printf '%s %s %s\n' "$base" "$prerelease" "$raw"
}

# Highest release tag at HEAD, and overall. A plain release outranks its RCs at the same base version.
release_info_at_head() {
  git tag --points-at HEAD | while IFS= read -r tag; do
    release_tag_info "$tag" || continue
  done | sort -k1,1V -k2,2nr | tail -n 1
}
release_info_latest() {
  git tag --list | while IFS= read -r tag; do
    release_tag_info "$tag" || continue
  done | sort -k1,1V -k2,2nr | tail -n 1
}

head_info=""
if [ "$snapshot_only" = 0 ]; then
  head_info="$(release_info_at_head)"
fi

last_info="$(release_info_latest)"
last_version=""
last_prerelease=""
if [ -n "$last_info" ]; then
  read -r last_version last_prerelease _ <<<"$last_info"
fi

if [ -n "$head_info" ]; then
  read -r base pre label <<<"$head_info"
  train="$base"
  if [ "$pre" = 1 ]; then prerelease=true; else prerelease=false; fi
else
  prerelease=true
  # A commit that's already out keeps its name.
  label="$(git tag --points-at HEAD --list '[0-9][0-9]w[0-9][0-9]*' | awk 'NR == 1')"
  if [ -z "$label" ]; then
    # The letter counts the snapshots already published this week, so this build is the next one. Published, not
    # committed: a push carries several commits but makes one build.
    prefix="${year}w$(stamp %V)"
    n="$(git tag --list "${prefix}*" | wc -l | tr -d ' ')"
    label="${prefix}$(letters "$n")"
    # A tag the count missed (a run that failed after tagging, a tag deleted by hand): walk past it.
    while git rev-parse -q --verify "refs/tags/$label" >/dev/null; do
      n=$((n + 1))
      label="${prefix}$(letters "$n")"
    done
  fi
  # The release this snapshot leads to: while an RC is still being stabilised it leads to that same base version;
  # otherwise the next patch (the next minor for a two-part version). Names never decide an update, the code does,
  # so this is only what the app shows.
  train="0.1.0"
  if [ -n "$last_version" ]; then
    if [ "$last_prerelease" = 1 ]; then
      train="$last_version"
    else
      IFS=. read -r major minor patch <<<"$last_version"
      if [ -n "${patch:-}" ]; then
        train="$major.$minor.$((patch + 1))"
      else
        train="$major.$((minor + 1))"
      fi
    fi
  fi
fi

if [ "$json" = 1 ]; then
  printf '{"label":"%s","train":"%s","code":%s,"date":"%s","prerelease":%s}\n' \
    "$label" "$train" "$code" "$date" "$prerelease"
else
  printf 'MOUSELITE_LABEL=%s\nMOUSELITE_TRAIN=%s\nMOUSELITE_CODE=%s\nMOUSELITE_DATE=%s\nMOUSELITE_PRERELEASE=%s\n' \
    "$label" "$train" "$code" "$date" "$prerelease"
fi
