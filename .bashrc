set -o vi
export PATH="$PATH:$HOME/.rvm/bin" # Add RVM to PATH for scripting
export VISUAL=nvim
export EDITOR="$VISUAL"

#Alias ---------------------------------------------------
alias grepp='perl ~/Documents/tools/grepp/grepp'
alias ls='ls --color'
alias hadoop='ssh bseto@136.159.79.112'
alias seng521='ssh seng521@104.236.242.123'
alias enel500='cd /home/byron/go/src/github.com/ENEL500'
alias seng533='echo 54.202.37.175 54.244.107.138'
alias solar='cd /home/byron/go/src/github.com/Epsilon-Telemetry-Server'
alias cc='CXX="cc_args.py g++" cmake ..'
alias cmake3='cmake'
alias sshreport42='ssh report42@192.168.71.26'
alias gtree='git log --oneline --graph --decorate --all'
#Alias ---------------------------------------------------

export GOROOT=/usr/local/go
export GOPATH=$HOME/go
#export GOPATH=/mnt/c/CVI_Workspace/Report42Workspace/report42/go 
#export PATH=$PATH:usr/local/go/bin
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin
export PATH=$PATH:/opt/bin

if [ "$TERM" == "xterm" ]; then
    # No it isn't, it's gnome-terminal
    export TERM=xterm-256color
fi

export TERMCAP=$(echo $TERMCAP | sed -e 's/Co#8/Co#256/g')
export LS_COLORS="ow=01;36;40"

#PS1="\e[1;32m[\u@\h\e[m \e[1;34m\W]\$ \e[m"
PS1="\[\033[01;32m\]\u@\h\[\033[01;34m\] \W \$\[\033[00m\]"
#PS1="[\u@\h:\W]"


PATH="/home/byron/perl5/bin${PATH+:}${PATH}"; export PATH;
PERL5LIB="/home/byron/perl5/lib/perl5${PERL5LIB+:}${PERL5LIB}"; export PERL5LIB;
PERL_LOCAL_LIB_ROOT="/home/byron/perl5${PERL_LOCAL_LIB_ROOT+:}${PERL_LOCAL_LIB_ROOT}"; export PERL_LOCAL_LIB_ROOT;
PERL_MB_OPT="--install_base \"/home/byron/perl5\""; export PERL_MB_OPT;
PERL_MM_OPT="INSTALL_BASE=/home/byron/perl5"; export PERL_MM_OPT;

# enable bash completion in interactive shells
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

export HISTFILESIZE=
export HISTSIZE=

export CSCOPE_EDITOR=`which nvim`

#fzf
[ -f ~/.fzf.bash ] && source ~/.fzf.bash

# fd - cd to selected directory
fd() {
    local dir
    dir=$(find ${1:-.} -path '*/\.*' -prune \
        -o -type d -print 2> /dev/null | fzf +m) &&
    cd "$dir"
}

#rtags
export PATH=$PATH:/home/bseto/Documents/rtags/build/bin 
