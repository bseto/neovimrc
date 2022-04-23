set -o vi
export VISUAL=nvim
export EDITOR="$VISUAL"

#Alias ---------------------------------------------------
alias gtree='git log --oneline --graph --decorate --all'
alias vim='nvim'
#Alias ---------------------------------------------------


[ -f ~/.fzf.bash ] && source ~/.fzf.bash
