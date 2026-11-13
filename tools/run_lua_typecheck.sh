#!/usr/bin/env sh
# Run LuaLS diagnostics over the hand-written Lua sources. The pinned release is
# installed under build/ on first use; set LUALS_BIN to use an existing install.
set -eu

# Keep test and check runs from reporting pyexasol usage if they invoke host tools.
export EXASOL_TELEMETRY_DISABLE=true

base_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
setup_luals() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to format LuaLS diagnostics." >&2
    exit 2
  fi

  if [ -n "${LUALS_BIN:-}" ]; then
    luals_bin=$LUALS_BIN
  else
    version=3.19.2
    case "$(uname -s)-$(uname -m)" in
      Linux-x86_64)
        platform=linux-x64
        checksum=93ad326b10f6c00911dd8c450fa098332dbd8f9f45d1052f5636a2d54479b947
        ;;
      Linux-aarch64|Linux-arm64)
        platform=linux-arm64
        checksum=17b8e401a874440adeb649e5024c364f2bb9d15156c74a40e56d1ae9a1b2e4f2
        ;;
      Darwin-x86_64)
        platform=darwin-x64
        checksum=6f2174ece5ec63bcd9d5b22b2c902445c1cd9045fafe48c62602448ebf4c09cc
        ;;
      Darwin-arm64)
        platform=darwin-arm64
        checksum=79149584320a23bd5fcd5bc31f47a1975acd8a4560a0e89036bb1016fa61687f
        ;;
      *)
        echo "Unsupported platform; set LUALS_BIN to a LuaLS executable." >&2
        exit 2
        ;;
    esac

    install_dir="$base_dir/build/luals-$version-$platform"
    luals_bin="$install_dir/bin/lua-language-server"
    if [ ! -x "$luals_bin" ]; then
      archive="$base_dir/build/lua-language-server-$version-$platform.tar.gz"
      mkdir -p "$base_dir/build" "$install_dir"
      if [ ! -f "$archive" ]; then
        curl -fsSL --output "$archive.part" \
          "https://github.com/LuaLS/lua-language-server/releases/download/$version/lua-language-server-$version-$platform.tar.gz"
        mv "$archive.part" "$archive"
      fi
      if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$archive")
      else
        actual=$(shasum -a 256 "$archive")
      fi
      if [ "${actual%% *}" != "$checksum" ]; then
        echo "LuaLS archive checksum mismatch: $archive" >&2
        exit 1
      fi
      tar -xzf "$archive" -C "$install_dir"
    fi
  fi

  # Exasol supplies these names at runtime. Script parameters come from the
  # same @param declarations that the package builder uses for CREATE SCRIPT.
  # Listing known names preserves undefined-global checks for unknown names.
  config_path="$base_dir/build/luals.luarc.json"
  mkdir -p "$base_dir/build"
  {
    printf '%s\n' query null exit import exa sqlparsing
    printf '%s\n' agent compiler fusion materializations script_support \
      semantic_definition validator
    sed -n 's/^-- @param \([A-Z][A-Z0-9_]*\).*/\1/p' \
      "$base_dir"/lua/semantic_layer/scripts/*.lua
  } | sort -u | jq -R -s '
    split("\n") | map(select(length > 0)) | {"diagnostics.globals": .}
  ' > "$config_path"
}

setup_luals

report_path="$base_dir/build/luals-check.json"
# Remove the previous report so a failed LuaLS run cannot leave stale results.
rm -f -- "$report_path"
if "$luals_bin" --check "$base_dir/lua" --checklevel=Warning --quiet \
  --configpath="$config_path" --check_format=json \
  --check_out_path="$report_path" "$@"; then
  luals_status=0
else
  luals_status=$?
fi

if [ ! -s "$report_path" ]; then
  echo "LuaLS did not write a JSON report: $report_path" >&2
  exit 1
fi

count_diagnostics() {
  jq '[.[][]] | length' "$report_path"
}

# Based on https://github.com/LuaLS/lua-language-server/issues/2830#issuecomment-2315627616
format_github_actions() {
  jq -r --arg root "$base_dir/" '
    to_entries | sort_by(.key)[] |
    (.key | ltrimstr("file://") | ltrimstr($root)) as $file |
    .value | sort_by(.range.start.line, .range.start.character)[] |
    (if .severity == 1 then "error" else "warning" end) as $level |
    .code as $code |
    (.range.start.line + 1) as $line |
    (.range.start.character + 1) as $col |
    (.message | gsub("[\r\n]+"; " ")) as $message |
    ($message | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A")) as $escaped |
    "\($file):\($line):\($col) \($level) \($code): \($message)\n" +
    "::\($level) file=\($file),line=\($line),col=\($col),title=\($code)::\($escaped)"
  ' "$report_path"
}

format_human_readable() {
  jq -r --arg root "$base_dir/" '
    to_entries | sort_by(.key)[] |
    (.key | ltrimstr("file://") | ltrimstr($root)) as $file |
    .value | sort_by(.range.start.line, .range.start.character)[] |
    (if .severity == 1 then "error" else "warning" end) as $level |
    "\($file):\(.range.start.line + 1):\(.range.start.character + 1) \($level) \(.code): \(.message | gsub("[\r\n]+"; " "))"
  ' "$report_path"
}

diagnostic_count=$(count_diagnostics)
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  format_github_actions
else
  format_human_readable
fi

echo "LuaLS: $diagnostic_count diagnostics (JSON: $report_path)"
if [ "$diagnostic_count" -gt 0 ] || [ "$luals_status" -ne 0 ]; then
  exit 1
fi
