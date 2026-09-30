vim9script

if exists('g:loaded_fd_vim')
  finish
endif
g:loaded_fd_vim = 1

command! -nargs=? -bar Fd call find#Open(<q-args>)
