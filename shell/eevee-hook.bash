# Eevee desktop buddy: tell me when a long command finishes, and remember
# how fast the things you benchmark ran.
#
# Sourced from ~/.bashrc (the settings window adds or removes that line, or
# `eevee-brain cmdhook on|off`). Costs nothing per command: the start time is
# stamped from PS0 with an arithmetic expansion (no subshell, no DEBUG trap,
# so it layers with Starship and friends), and the brain is only called when
# the command was slow enough to be worth a word, or was the kind of command
# you run to time it.
#
# It also defines `why`, which re-runs the command that just failed with its
# output captured and asks Eevee what went wrong.

[[ $- == *i* ]] || return 0
[[ -n ${__eevee_hooked-} ]] && return 0
__eevee_hooked=1
__eevee_brain="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/bin/eevee-brain"
__eevee_t=""
__eevee_last=""      # the last command that failed, for `why`
__eevee_last_dir=""

# Expands to nothing; stamps __eevee_t in microseconds as the command starts.
# EPOCHREALTIME carries the locale's decimal separator, so both are stripped.
PS0='${__eevee_t:$((__eevee_t=${EPOCHREALTIME/[.,]/},0)):0}'"${PS0-}"

# Commands you run to see how long they take. Kept in step with bench_shape
# in the brain; tested here first so nothing else pays for a process.
__eevee_bench_shape() {
  case "$1" in
    ./*) return 0 ;;
    make|make\ *|mvn|mvn\ *|cargo\ *|go\ run*|go\ test*|gradle*|ctest*|cmake\ --build*) return 0 ;;
    npm\ run*|npm\ test*|pnpm\ *|yarn\ *|pytest*|python\ *.py*|python3\ *.py*) return 0 ;;
    cc\ *|gcc\ *|g++\ *|clang\ *|clang++\ *|javac\ *|java\ *|rustc\ *|zig\ *|gfortran\ *) return 0 ;;
  esac
  return 1
}

__eevee_precmd() {
  local status=$? us cmd
  if [[ -n $__eevee_t ]]; then
    us=$((${EPOCHREALTIME/[.,]/} - __eevee_t))
    __eevee_t=""
    cmd=$(HISTTIMEFORMAT='' history 1 | sed 's/^ *[0-9]*[* ] *//')

    # Remember a failure so `why` has something to work with.
    if ((status != 0)); then
      __eevee_last=$cmd
      __eevee_last_dir=$PWD
    fi

    # A timed run reports straight into the terminal, where you are looking.
    # The brain applies the real floor (benchmarkMs); 50 ms here only keeps
    # instant commands from paying for a process.
    if ((us >= 50000)) && __eevee_bench_shape "$cmd"; then
      bash "$__eevee_brain" bench "$us" "$status" "$PWD" "$cmd" 2>/dev/null
    fi

    # Anything slow enough to have walked away from still gets a notification.
    if ((us >= 10000000)); then
      (bash "$__eevee_brain" cmd-done --us "$us" --dir "$PWD" \
        "$((us / 1000000))" "$status" "$$" "$cmd" >/dev/null 2>&1 &)
    fi
  fi
  return $status # keep $? intact for the prompt that runs after us
}

# why [command...] — explain the last failure, or one you name.
why() {
  local cmd="$*" dir=$PWD
  if [[ -z $cmd ]]; then
    cmd=$__eevee_last; dir=${__eevee_last_dir:-$PWD}
    [[ -n $cmd ]] || { echo "Nothing has failed yet." >&2; return 1; }
  fi
  bash "$__eevee_brain" explain-fail "$dir" "$cmd"
}

# Run first, so we see the command's real exit status.
if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
  PROMPT_COMMAND=(__eevee_precmd "${PROMPT_COMMAND[@]}")
else
  PROMPT_COMMAND="__eevee_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
