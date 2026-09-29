# Bash completion for the Aerys CLI.
#
# Install:
#   ./aerys install-completion           (optional step the installer offers)
#
# Or manually: add to ~/.bashrc:
#   source /path/to/aerys/installer/completions/aerys.bash
#
# (Zsh users: `autoload bashcompinit && bashcompinit` then source this file.)

_aerys_completions() {
  local cur prev words cword
  _init_completion 2>/dev/null || {
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    words=("${COMP_WORDS[@]}")
    cword="$COMP_CWORD"
  }

  local subcommands="install update upgrade-workflows health check credentials
                     compose config init-db verify-db install-community-nodes
                     install-discord-watchdog
                     start stop restart watch
                     rename set-webhook register-telegram
                     uninstall help"

  local global_flags="--deploy-dir --env-path --api-key --n8n-url --yes --quiet --help"

  # First arg: complete with subcommand names
  if [ "$cword" -eq 1 ]; then
    # shellcheck disable=SC2207
    COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
    return 0
  fi

  # Complete --deploy-dir / --env-path with paths
  case "$prev" in
    --deploy-dir|--env-path)
      # shellcheck disable=SC2207
      COMPREPLY=($(compgen -o filenames -A file -- "$cur"))
      return 0
      ;;
    --api-key|--n8n-url)
      # Can't meaningfully complete these
      return 0
      ;;
  esac

  # set-webhook expects a URL arg next, no completion
  # rename expects a name, no completion
  # Otherwise offer global flags
  # shellcheck disable=SC2207
  COMPREPLY=($(compgen -W "$global_flags" -- "$cur"))
}

complete -F _aerys_completions aerys
complete -F _aerys_completions ./aerys
