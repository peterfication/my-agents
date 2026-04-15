# List all commands
default:
  just --list

# Add a new source REPOSITORY=<user>/<repository>
sources-add REPOSITORY:
  git submodule add https://github.com/{{REPOSITORY}}.git sources/{{ replace(REPOSITORY, "/", "-") }}

# Update all sources
sources-update:
  git submodule update --remote --merge

# Sync skills/ symlinks from skills.yml
skills-link:
  ./scripts/skills_link.sh
