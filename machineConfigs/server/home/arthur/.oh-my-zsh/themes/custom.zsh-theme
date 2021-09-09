#PROMPT="%(?:%{$fg_bold[green]%}➜ :%{$fg_bold[red]%}➜ )"
PROMPT='%{$fg_bold[green]%}$USER@%{$fg_bold[green]%}%M%{$fg_bold[white]%}:'
PROMPT+='%{$fg_bold[blue]%}%~%{$reset_color%}'
PROMPT+="%(?:%{$fg[green]%}$ :%{$fg[red]%}$ )"
PROMPT+='$(git_prompt_info)'


ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg_bold[cyan]%}git:(%{$fg[red]%}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%{$reset_color%} "
ZSH_THEME_GIT_PROMPT_DIRTY="%{$fg[cyan]%}) %{$fg[yellow]%}✗"
ZSH_THEME_GIT_PROMPT_CLEAN="%{$fg[cyan]%})"


