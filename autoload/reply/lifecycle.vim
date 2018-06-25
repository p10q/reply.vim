" Note: utop does not work on Vim 8.1.26
" Note: gore does not work at all
let s:default_repls = {
\   'ruby': ['pry', 'irb'],
\   'python': ['ptpython', 'python'],
\   'ocaml': ['ocaml'],
\   'javascript': ['node', 'd8', 'electron'],
\   'typescript': ['ts_node'],
\   'haskell': ['ghci'],
\   'swift': ['swift'],
\   'lua': ['lua'],
\   'scheme': ['gauche', 'chibi_scheme', 'mit_scheme'],
\   'go': ['go_pry'],
\   'lisp': ['sbcl', 'clisp'],
\   'c': ['cling_c'],
\   'cpp': ['cling'],
\   'objc': ['cling_objc'],
\   'sh': ['bash', 'sh'],
\   'zsh': ['zsh'],
\   'julia': ['julia'],
\   'crystal': ['icr'],
\   'scala': ['scala'],
\   'kotlin': ['kotlinc'],
\   'clojure': ['clojure'],
\   'java': ['jshell'],
\   'csharp': ['csi'],
\   'fsharp': ['fsi'],
\   'php': ['psysh', 'php'],
\   'sml': ['sml'],
\   'groovy': ['groovysh'],
\   'erlang': ['erl'],
\   'elixir': ['iex'],
\   'r': ['R'],
\   'elm': ['elm_repl'],
\ }
" TODO: Add Devel::REPL support for Perl

" All REPLs running and started by reply.vim
let s:repls = []

function! s:did_repl_start(repl) abort
    let s:repls += [a:repl]
    call reply#log(a:repl.name, 'started. current state:', s:repls)
endfunction

function! s:did_repl_end(repl, exitstatus) abort
    for i in range(len(s:repls))
        if s:repls[i].term_bufnr == a:repl.term_bufnr
            call remove(s:repls, i)
            call reply#log(a:repl.name, 'closed with exit status', a:exitstatus, '. current state:', s:repls)
            return
        endif
    endfor
    throw reply#error('BUG: REPL instance is not managed: %s', string(a:repl))
endfunction

function! s:new_repl(name) abort
    let name = substitute(a:name, '-', '_', 'g')
    try
        let repl = reply#repl#{name}#new()
    catch /^Vim\%((\a\+)\)\=:E117/
        return v:null
    endtry
    if !repl.is_available()
        call reply#log(name, 'is not available')
        return v:null
    endif
    call reply#log('Created new REPL instance for', repl.name)
    return repl
endfunction

function! s:new_repl_for_filetype(filetype) abort
    let names = get(reply#var('repls', {}), a:filetype, get(s:default_repls, a:filetype, []))
    if empty(names)
        throw reply#error("No REPL is selectable for filetype '%s'. Please read `:help g:reply_repls`", a:filetype)
    endif

    for name in names
        let repl = s:new_repl(name)
        if repl isnot v:null
            return repl
        endif
    endfor

    throw reply#error("No REPL is available for filetype '%s'. Candidates are %s", a:filetype, names)
endfunction

function! reply#lifecycle#new(bufnr, name, cmdopts) abort
    let source = bufname(a:bufnr)
    if filereadable(source)
        let source = fnamemodify(source, ':p')
    else
        let source = ''
    endif

    if a:name ==# ''
        let filetype = getbufvar(a:bufnr, '&filetype')
        if filetype ==# ''
            throw reply#error('No filetype is set for buffer %d', a:bufnr)
        endif
        let repl = s:new_repl_for_filetype(filetype)
        call reply#log('REPL', repl.name, 'was selected based on filetype', filetype)
    else
        let repl = s:new_repl(a:name)
        if repl is v:null
            throw reply#error("REPL '%s' is not defined or not installed. Please check :ReplList", a:name)
        endif
        call reply#log('REPL', repl.name, 'was selected based on specified name')
    endif

    call repl.start({
        \   'source' : source,
        \   'source_bufnr' : a:bufnr,
        \   'on_close' : function('s:did_repl_end'),
        \   'cmdopts' : a:cmdopts,
        \ })
    call s:did_repl_start(repl)

    return repl
endfunction

function! reply#lifecycle#running_repls() abort
    return filter(copy(s:repls), {_, r -> r.running})
endfunction

function! reply#lifecycle#repl_for_buf(bufnr) abort
    for r in s:repls
        if has_key(r.context, 'source_bufnr') && r.context.source_bufnr == a:bufnr ||
         \ has_key(r, 'term_bufnr') && r.term_bufnr == a:bufnr
            return r
        endif
    endfor
    return v:null
endfunction

function! reply#lifecycle#default_repl_names() abort
    return s:default_repls
endfunction
