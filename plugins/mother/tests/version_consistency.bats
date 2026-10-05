#!/usr/bin/env bats
# A release must bump every version surface together, or `claude plugin update`
# keeps serving a stale cache.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
}

@test "plugin.json, marketplace.json and the newest CHANGELOG entry agree on the version" {
    p=$(jq -r .version "$ROOT/plugins/mother/.claude-plugin/plugin.json")
    m=$(jq -r '.plugins[] | select(.name == "mother") | .version' "$ROOT/.claude-plugin/marketplace.json")
    c=$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$ROOT/CHANGELOG.md" | tr -d '#[] ')
    [ -n "$p" ]
    [ "$p" = "$m" ]
    [ "$p" = "$c" ]
}
