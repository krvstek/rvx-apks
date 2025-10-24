#!/usr/bin/env bash
set -euo pipefail

# Extras script for build workflows
# Usage: ./extras.sh <command> [args...]

command="${1:-}"

case "$command" in
  separate-config)
    # Extract a section from TOML config file
    # Usage: ./extras.sh separate-config <config_file> <key_to_match> <output_file>
    
    if [[ $# -ne 4 ]]; then
      echo "Usage: $0 separate-config <config_file> <key_to_match> <output_file>"
      exit 1
    fi
    
    config_file="$2"
    key_to_match="$3"
    output_file="$4"
    
    section_content=$(awk -v key="$key_to_match" '
      BEGIN { print "[" key "]" }
      /^\[/ && tolower($1) == "[" tolower(key) "]" { in_section = 1; next }
      /^\[/ { in_section = 0 }
      in_section == 1
    ' "$config_file")
    
    if [[ -z "$section_content" ]]; then
      echo "Key '$key_to_match' not found in the config file."
      exit 1
    fi
    
    echo "$section_content" > "$output_file"
    echo "Section for '$key_to_match' written to $output_file"
    ;;

  combine-logs)
    # Combine build logs from multiple matrix jobs
    # Usage: ./extras.sh combine-logs <build-logs-dir>
    
    build_logs_dir="${2:-build-logs}"

    for log in "$build_logs_dir"/build-log-*/build.md; do
      if [ -f "$log" ]; then
        grep "^🟢" "$log" 2>/dev/null || true
      fi
    done
    echo ""

    for log in "$build_logs_dir"/build-log-*/build.md; do
      if [ -f "$log" ]; then
        if grep -q "MicroG" "$log"; then
          grep -A 1 "^-.*MicroG" "$log" 2>/dev/null || true
          echo ""
          break
        fi
      fi
    done

    temp_file=$(mktemp)
    trap 'rm -f "$temp_file"' EXIT
    
    for log in "$build_logs_dir"/build-log-*/build.md; do
      if [ -f "$log" ]; then
        awk '/^>.*CLI:/{p=1} p{print} /^\[.*Changelog\]/{print ""; p=0}' "$log" >> "$temp_file" 2>/dev/null || true
      fi
    done

    awk '!seen[$0]++' "$temp_file"
    ;;

  *)
    echo "Unknown command: $command"
    echo ""
    echo "Available commands:"
    echo "  separate-config <config_file> <key_to_match> <output_file>"
    echo "  combine-logs [build-logs-dir]"
    exit 1
    ;;
esac