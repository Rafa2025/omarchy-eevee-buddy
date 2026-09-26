# Eevee desktop buddy: tell me when a long command finishes.
#
# Sourced from ~/.bashrc (the settings window adds or removes that line, or
# `eevee-brain cmdhook on|off`). Costs nothing per command: the start time is
# stamped from PS0 with an arithmetic expansion (no subshell, no DEBUG trap,
# so it layers with Starship and friends), and the brain is only called for
# commands that ran 10 s or more. It decides from there, using the
# threshold in the settings.

[[ $- == *i* ]] || return 0
[[ -n ${__eevee_hooked-} ]] && return 0
__eevee_hooked=1
__eevee_brain="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/bin/eevee-brain"
__eevee_t=""

# Expands to nothing; sets __eevee_t as the command starts.
PS0='${__eevee_t:$((__eevee_t=EPOCHSECONDS,0)):0}'"${PS0-}"

__eevee_precmd() {
  local status=$? d cmd
  if [[ -n $__eevee_t ]]; then
    d=$((EPOCHSECONDS - __eevee_t))
    __eevee_t=""
    if ((d >= 10)); then
      cmd=$(HISTTIMEFORMAT='' history 1 | sed 's/^ *[0-9]*[* ] *//')
      (bash "$__eevee_brain" cmd-done "$d" "$status" "$$" "$cmd" >/dev/null 2>&1 &)
    fi
  fi
  return $status # keep $? intact for the prompt that runs after us
}

# Run first, so we see the command's real exit status.
if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
  PROMPT_COMMAND=(__eevee_precmd "${PROMPT_COMMAND[@]}")
else
  PROMPT_COMMAND="__eevee_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
