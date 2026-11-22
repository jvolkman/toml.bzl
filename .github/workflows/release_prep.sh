#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

# Argument provided by reusable workflow caller
TAG=$1
VERSION="${TAG#v}"
# The prefix is chosen to match what GitHub generates for source archives
PREFIX="toml.bzl-${VERSION}"
ARCHIVE="toml.bzl-$TAG.tar.gz"

# NB: configuration for 'git archive' is in /.gitattributes
git archive --format=tar --prefix=${PREFIX}/ ${TAG} | gzip > $ARCHIVE
SHA=$(shasum -a 256 $ARCHIVE | awk '{print $1}')

# Add generated API docs
docs="$(mktemp -d)"; targets="$(mktemp)"
bazel --output_base="$docs" query --output=label --output_file="$targets" 'kind("starlark_doc_extract rule", //...)'
bazel --output_base="$docs" build --target_pattern_file="$targets"
tar --create --auto-compress \
    --directory "$(bazel --output_base="$docs" info bazel-bin)" \
    --file "$GITHUB_WORKSPACE/${ARCHIVE%.tar.gz}.docs.tar.gz" .

REPO="${GITHUB_REPOSITORY:-jvolkman/toml.bzl}"
CHANGELOG_URL="https://github.com/${REPO}/blob/${TAG}/CHANGELOG.md"
CHANGELOG_HEADING=""
CHANGELOG_SECTION=""

if git cat-file -e "${TAG}:CHANGELOG.md" 2>/dev/null; then
    CHANGELOG_FILE="$(mktemp)"
    git show "${TAG}:CHANGELOG.md" > "${CHANGELOG_FILE}"
    CHANGELOG_HEADING=$(
        awk -v ver="${VERSION}" '
            /^## / {
                if ($0 == "## [" ver "]" || index($0, "## [" ver "] ") == 1 || $0 == "## " ver || index($0, "## " ver " ") == 1) {
                    print substr($0, 4)
                    exit
                }
            }
        ' "${CHANGELOG_FILE}"
    )
    CHANGELOG_SECTION=$(
        awk -v ver="${VERSION}" '
            /^## / || /^\[[^]]+\]: / {
                if (found) exit
                if ($0 == "## [" ver "]" || index($0, "## [" ver "] ") == 1 || $0 == "## " ver || index($0, "## " ver " ") == 1) {
                    found = 1
                    next
                }
            }
            found {
                if (!started && $0 == "") next
                started = 1
                lines[++n] = $0
            }
            END {
                while (n > 0 && lines[n] == "") n--
                for (i = 1; i <= n; i++) print lines[i]
            }
        ' "${CHANGELOG_FILE}"
    )
    rm -f "${CHANGELOG_FILE}"

    if [[ -n "${CHANGELOG_HEADING}" ]]; then
        ANCHOR=$(printf '%s' "${CHANGELOG_HEADING}" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9_-')
        CHANGELOG_URL="${CHANGELOG_URL}#${ANCHOR}"
    fi

    echo "See the [CHANGELOG](${CHANGELOG_URL})."
    echo ""
    if [[ -n "${CHANGELOG_SECTION}" ]]; then
        echo "## Release Notes"
        echo ""
        printf '%s\n\n' "${CHANGELOG_SECTION}"
    fi
fi

cat << EOF
## Using Bzlmod with Bazel 6 or greater

Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "toml.bzl", version = "${VERSION}")
\`\`\`

## Using WORKSPACE

Paste this snippet into your \`WORKSPACE.bazel\` file:

\`\`\`starlark
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
http_archive(
    name = "toml.bzl",
    sha256 = "${SHA}",
    strip_prefix = "${PREFIX}",
    url = "https://github.com/${REPO}/releases/download/${TAG}/${ARCHIVE}",
)
\`\`\`
EOF
