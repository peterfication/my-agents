#!/usr/bin/env bash

set -euo pipefail

# Sync the `skills/` directory from `skills.yml`.
#
# `skills.yml` should look like this:
#
# ```yaml
# skills:
#   - path: sources/obra-superpowers/skills/writing-plans
#   - path: sources/obra-superpowers/skills/executing-plans
#     name: plan-execution
# ```
#
# Rules:
# - `path` is required and must point to an existing directory.
# - `name` is optional. If omitted, the link name defaults to `basename(path)`.
# - Relative paths are resolved from the repository root.
# - Duplicate final link names fail before any filesystem changes are made.
# - Each run removes all existing symlinks in `skills/` before recreating the configured set.

script_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P
)
repo_root=$(
  cd -- "$script_dir/.." && pwd -P
)
config_file="$repo_root/skills.yml"
skills_dir="$repo_root/skills"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

[[ -f "$config_file" ]] || fail "Missing config file: $config_file"
mkdir -p -- "$skills_dir"

declare -a link_names=()
declare -a raw_paths=()
declare -a target_paths=()
declare -A seen_names=()

while IFS= read -r -d '' link_name && IFS= read -r -d '' raw_path; do
  if [[ -v "seen_names[$link_name]" ]]; then
    fail "Duplicate final link name: $link_name"
  fi

  seen_names["$link_name"]=1
  link_names+=("$link_name")
  raw_paths+=("$raw_path")
done < <(
  ruby - "$config_file" <<'RUBY'
require "yaml"

config_path = ARGV.fetch(0)

begin
  data = YAML.load_file(config_path)
rescue Psych::SyntaxError => e
  warn "Invalid YAML in #{config_path}: #{e.message}"
  exit 1
end

unless data.is_a?(Hash)
  warn "Expected top-level mapping in #{config_path}"
  exit 1
end

skills = data["skills"]
unless skills.is_a?(Array)
  warn "Expected `skills` to be an array in #{config_path}"
  exit 1
end

skills.each_with_index do |entry, index|
  unless entry.is_a?(Hash)
    warn "Expected skills[#{index}] to be an object"
    exit 1
  end

  path = entry["path"]
  unless path.is_a?(String) && !path.empty?
    warn "Expected skills[#{index}].path to be a non-empty string"
    exit 1
  end

  name = entry["name"]
  unless name.nil? || (name.is_a?(String) && !name.empty?)
    warn "Expected skills[#{index}].name to be a non-empty string when present"
    exit 1
  end

  final_name = name || File.basename(path)
  if final_name.empty? || final_name == "." || final_name == ".." || final_name.include?("/")
    warn "Invalid final link name for skills[#{index}]"
    exit 1
  end

  print final_name, "\0", path, "\0"
end
RUBY
)

for i in "${!link_names[@]}"; do
  raw_path=${raw_paths[$i]}

  if [[ "$raw_path" = /* ]]; then
    resolved_path=$raw_path
  else
    resolved_path=$repo_root/$raw_path
  fi

  [[ -e "$resolved_path" ]] || fail "Configured skill path does not exist: $raw_path"
  [[ -d "$resolved_path" ]] || fail "Configured skill path is not a directory: $raw_path"

  destination=$skills_dir/${link_names[$i]}
  if [[ -e "$destination" && ! -L "$destination" ]]; then
    fail "Cannot replace non-symlink path: $destination"
  fi

  target_paths+=("$resolved_path")
done

for existing_path in "$skills_dir"/*; do
  [[ -e "$existing_path" || -L "$existing_path" ]] || continue
  if [[ -L "$existing_path" ]]; then
    rm -- "$existing_path"
  fi
done

for i in "${!link_names[@]}"; do
  destination="$skills_dir/${link_names[$i]}"
  printf 'Linking %s -> %s\n' "$destination" "${target_paths[$i]}"
  ln -s -- "${target_paths[$i]}" "$destination"
done
