
export PATH="$PATH:$HOME/.rvm/bin" # Add RVM to PATH for scripting
alias grepp='perl ~/Documents/tools/grepp/grepp'

export GOROOT=/usr/local/go
export PATH=$PATH:usr/local/go/bin
export GOPATH=~/golib

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
