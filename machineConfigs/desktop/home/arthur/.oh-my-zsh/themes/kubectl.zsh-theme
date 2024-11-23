PROMPT='%{$fg_bold[green]%}$USER@%{$fg_bold[green]%}%M%{$fg_bold[white]%}:'
PROMPT+='%{$fg_bold[blue]%}%~%{$reset_color%}'
PROMPT+="%(?:%{$fg[green]%}$ :%{$fg[red]%}$ )"
PROMPT+='$(git_prompt_info)'
PROMPT+='%{$fg[blue]%}($ZSH_KUBECTL_USER)%{$reset_color%}'

ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg_bold[blue]%}git:(%{$fg[red]%}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%{$reset_color%} "
ZSH_THEME_GIT_PROMPT_DIRTY="%{$fg[blue]%}) %{$fg[yellow]%}✗"
ZSH_THEME_GIT_PROMPT_CLEAN="%{$fg[blue]%})"

NEWLINE=$'\n'
PROMPT+="${NEWLINE}%(?:%{$fg_bold[green]%}➜ :%{$fg_bold[red]%}➜ )%{$reset_color%}"
