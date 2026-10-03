# The devcontainer's shell defaults, baked into the image at
# /etc/zsh/devcontainer.zshrc and sourced from Debian's /etc/zsh/zshrc, so the
# packaged terminfo key bindings stay and ~/.zshrc runs after this and wins.
# System rc, not a home dotfile: the home volume shadows image content under
# /home/dev. See README.md ("Shell, editor and clipboard").

# PATH. The login shell's /etc/profile resets PATH for non-root users and drops
# /usr/local/sbin, where the fence and the volume repair live, and never knew
# about the home's bin, where the bootstrap installs claude, codex and herdr.
# typeset -U keeps each entry once however many shells nest.
typeset -U path
path=(~/.local/bin /usr/local/sbin $path)

HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
# SHARE_HISTORY writes each command as it runs and imports other panes'; zsh
# documents INC_APPEND_HISTORY as the one to leave off when it is on.
setopt SHARE_HISTORY

autoload -Uz compinit && compinit

# Unguarded on purpose: a Debian rename should fail loudly in every shell
# rather than silently drop the feature. Highlighting sources last, as it
# documents.
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# Prompt: user@host:cwd[branch]. The branch comes from zsh's own vcs_info, not
# a prompt framework or a `git branch` call in the prompt string — vcs_info is
# shipped with zsh, and as a precmd hook it queries git once per prompt rather
# than on every redraw. PROMPT_SUBST is what makes the ${...} re-expand each
# time; without it the branch would freeze at whatever it was when the shell
# started. Outside a repository vcs_info leaves the variable empty, so the
# brackets disappear rather than showing up blank.
autoload -Uz vcs_info add-zsh-hook
zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:git:*' formats '[%b]'
zstyle ':vcs_info:git:*' actionformats '[%b|%a]'
add-zsh-hook precmd vcs_info
setopt PROMPT_SUBST
PROMPT='%n@%m:%~${vcs_info_msg_0_}%# '

# yazi's documented cd-on-quit wrapper, verbatim from its quick-start docs: it
# passes yazi a --cwd-file to write the directory it exited in, then cds there.
# Copied rather than adapted so it stays diffable against upstream.
function y() {
	local tmp cwd; tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
	command yazi "$@" --cwd-file="$tmp"
	IFS= read -r -d '' cwd < "$tmp"
	[ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd" || builtin true
	command rm -f -- "$tmp"
}
