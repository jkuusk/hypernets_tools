#!/usr/bin/bash

set -o nounset
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root, use sudo $0 instead" 1>&2
	exit 1
fi

###### additional packages
packman -Syu --noconfirm geeqie mlocate firefox
runuser -u joel -- yay -S --noconfirm cutecom

####### vim configuration
cat > ~root/.vimrc << EOF
" load default config
unlet! skip_defaults_vim
source $VIMRUNTIME/defaults.vim

" disable mouse
set mouse=

EOF
cp -f ~root/.vimrc ~joel/.vimrc
chown joel.joel ~joel/.vimrc

## bash configuration
cat > ~root/.bash_profile << EOF
#
# ~/.bash_profile
#

[[ -f ~/.bashrc ]] && . ~/.bashrc

export VISUAL="vim"
export EDITOR="vim"

EOF
cp -f ~root/.bash_profile ~joel/.bash_profile
chown joel.joel ~joel/.bash_profile
