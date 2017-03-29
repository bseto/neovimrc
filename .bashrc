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
#Alias ---------------------------------------------------

export GOROOT=/usr/local/go
export GOPATH=$HOME/go
#export PATH=$PATH:usr/local/go/bin
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin

if [ "$TERM" == "xterm" ]; then
    # No it isn't, it's gnome-terminal
    export TERM=xterm-256color
fi

export TERMCAP=$(echo $TERMCAP | sed -e 's/Co#8/Co#256/g')

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
