function! reply#repl#ipython#new() abort
    return reply#repl#base('ipython', {
        \   'prompt_start' : '^In \[\d+\]:',
        \   'prompt_continue' : '...',
        \ })
endfunction

