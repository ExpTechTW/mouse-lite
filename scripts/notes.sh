#!/usr/bin/env bash
# Writes a release's notes from the changelog lines its commits carry (see commit.md):
#
#   New(zh-Hant): 可以從 GitHub Releases 自動更新
#
# A snapshot lists what changed since the previous published build. A release lists everything since the previous
# release: someone going from 0.1.0 to 0.2.0 never saw the snapshots in between.
#
#   scripts/notes.sh <label> <code> [--release] > NOTES.md
set -euo pipefail

label="${1:?usage: scripts/notes.sh <label> <code> [--release]}"
code="${2:?usage: scripts/notes.sh <label> <code> [--release]}"
kind="${3:-}"
repo="${GITHUB_REPOSITORY:-ExpTechTW/mouse-lite}"

# A release tag is a version or an RC (1.1.0, v1.1.0, rc0.1.0, v0.1.0-rc.1); snapshot tags (26w43a) are not releases.
is_release_tag() {
  local tag=${1#v}
  [[ $tag =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?|rc[0-9]+\.[0-9]+(\.[0-9]+)?|[0-9]+\.[0-9]+\.[0-9]+-(rc|beta|alpha)\.?[0-9]*)$ ]]
}

if [ "$kind" = "--release" ]; then
  # The previous release reachable from this commit, so a release covers everything since the last one.
  since=""
  while IFS= read -r tag; do
    [ "$tag" = "${GITHUB_REF_NAME:-}" ] && continue
    [ "$tag" = "$label" ] && continue
    [ "$tag" = "v$label" ] && continue
    is_release_tag "$tag" || continue
    [ "$(git rev-parse -q --verify "$tag^{commit}")" = "$(git rev-parse HEAD)" ] && continue
    if git merge-base --is-ancestor "$tag" HEAD 2>/dev/null; then
      since=$tag
      break
    fi
  done < <(git tag --list --sort=-creatordate)
else
  since="$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)"
fi
range="${since:+$since..}HEAD"

heading() { # <category> <locale>
  case "$2::$1" in
  zh-Hant::New) printf '🌟 新功能' ;;
  zh-Hant::Optimization) printf '🔌 最佳化' ;;
  zh-Hant::Fix) printf '🐞 錯誤修正' ;;
  *::New) printf '🌟 New features' ;;
  *::Optimization) printf '🔌 Improvements' ;;
  *::Fix) printf '🐞 Bug fixes' ;;
  esac
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

has_en=0
for sha in $(git rev-list --no-merges --reverse "$range"); do
  body="$(git log -1 --format=%b "$sha")"
  printf '%s\n' "$body" | grep -Eq '^(New|Optimization|Fix)\((zh-Hant|en-US)\):' || continue
  author="$(git log -1 --format=%an "$sha")"
  short="$(git rev-parse --short "$sha")"
  while IFS= read -r line; do
    if [[ $line =~ ^(New|Optimization|Fix)\((zh-Hant|en-US)\):[[:space:]]*(.+)$ ]]; then
      category="${BASH_REMATCH[1]}"
      locale="${BASH_REMATCH[2]}"
      text="${BASH_REMATCH[3]}"
      [ "$locale" = en-US ] && has_en=1
      printf -- '- %s — %s ([`%s`](https://github.com/%s/commit/%s))\n' \
        "$text" "$author" "$short" "$repo" "$sha" >>"$work/$category.$locale"
    fi
  done <<EOF
$body
EOF
done

section() { # <locale>
  local any=0 category
  for category in New Optimization Fix; do
    [ -s "$work/$category.$1" ] || continue
    any=1
    printf '### %s\n\n' "$(heading "$category" "$1")"
    cat "$work/$category.$1"
    printf '\n'
  done
  if [ "$any" = 0 ]; then
    [ "$1" = zh-Hant ] && printf '_沒有使用者可見的變更。_\n\n' || printf '_No user-facing changes._\n\n'
  fi
}

{
  # No heading: GitHub already shows the release's title above its notes.
  if [ "$kind" = "--release" ]; then
    if [ -n "$since" ]; then printf '_自 %s 以來的全部變更。_\n\n' "$since"; fi
  else
    printf '_快照，取自 main 的 `%s`。未經審查，可能有問題。_\n\n' "$(git rev-parse --short HEAD)"
  fi

  section zh-Hant
  if [ "$has_en" = 1 ]; then
    printf '<details>\n<summary>English</summary>\n\n'
    section en-US
    printf '</details>\n\n'
  fi

  if [ "$kind" = "--release" ] && [ -n "$since" ]; then
    printf -- '---\n\n**完整差異 / Full changelog**: https://github.com/%s/compare/%s...%s\n\n' \
      "$repo" "$since" "${GITHUB_REF_NAME:-$label}"
  fi

  # Invisible on the page. The updater compares it with the build that's running (Release.code in Update.swift), and
  # the release workflow checks a new build is above it.
  printf '<!-- mouselite-build: %s -->\n' "$code"
}
