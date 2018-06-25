let s:base = {}

function! s:base_get_var(name, default) dict abort
    let v = 'reply_repl_' . self.path_name . '_' . a:name
    return get(b:, v, get(g:, v, a:default))
endfunction
let s:base.get_var = function('s:base_get_var')

function! s:base_executable() dict abort
    return self.get_var('executable', self.name)
endfunction
let s:base.executable = function('s:base_executable')

function! s:base_is_available() dict abort
    return executable(self.executable())
endfunction
let s:base.is_available = function('s:base_is_available')

function! s:base_get_command() dict abort
    return [self.executable()] +
         \ self.get_var('command_options', [])
endfunction
let s:base.get_command = function('s:base_get_command')

function! s:base__on_exit(channel, exitval) dict abort
    call reply#log('exit_cb callback with status', a:exitval, 'for', self.name)

    if has_key(self.context, 'on_close')
        call self.context.on_close(self, a:exitval)
    endif

    if has_key(self, 'hooks') && has_key(self.hooks, 'on_close')
        for F in self.hooks.on_close
            call F(self, a:exitval)
        endfor
    endif

    if a:exitval == -1
        " https://github.com/vim/vim/blob/f9c3883b11b33f0c548df5e949ba59fde74d3e7b/src/os_unix.c#L5759
        call reply#log(self.name, 'terminated by signal')
    elseif a:exitval != 0
        call reply#error("REPL '%s' exited with status %d", self.name, a:exitval)
    endif

    if self.running
        call self.stop()
    endif

    unlet self.term_bufnr
endfunction
let s:base._on_exit = function('s:base__on_exit')

" context {
"   source?: string;
"   bufname?: string;
"   cmdopts?: string[];
" }
function! s:base_start(context) dict abort
    let self.context = a:context
    let self.running = v:false
    if has_key(self.context, 'cmdopts') && has_key(self.context, 'source')
        let src = self.context.source
        call map(self.context.cmdopts, {_, o -> o ==# '%' ? src : o})
    endif
    let cmd = self.get_command() + get(self.context, 'cmdopts', [])
    if type(cmd) != v:t_list
        let cmd = [cmd]
    endif
    let bufnr = term_start(cmd, {
        \   'term_name' : 'reply: ' . self.name,
        \   'vertical' : 1,
        \   'term_finish' : 'open',
        \   'exit_cb' : self._on_exit,
        \ })
    call reply#log('Start terminal at', bufnr, 'with command', cmd)
    let self.term_bufnr = bufnr
    let self.running = v:true
endfunction
let s:base.start = function('s:base_start')

function! s:base_into_terminal_job_mode() dict abort
    if bufnr('%') ==# self.term_bufnr
        if mode() ==# 't'
            return
        endif
        " Start Terminal-Job mode if job is alive
        if self.running
            normal! i
        endif
        return
    endif

    let winnr = bufwinnr(self.term_bufnr)
    if winnr != -1
        execute winnr . 'wincmd w'
    else
        execute 'vertical sbuffer' self.term_bufnr
    endif

    if mode() ==# 'n' && self.running
        " Start Terminal-Job mode if job is alive
        normal! i
    endif
endfunction
let s:base.into_terminal_job_mode = function('s:base_into_terminal_job_mode')

" Note: Precondition: Terminal window must exists
function! s:base_send_string(str) dict abort
    if !self.running
        throw reply#error("REPL '%s' is no longer running", self.name)
    endif

    let str = a:str
    if str[-1] !=# "\n"
        let str .= "\n"
    endif
    " Note: Zsh distinguishes <NL> and <CR> and regards <NL> as <C-j>.
    " We always use <CR> as newline character.
    let str = substitute(str, "\n", "\<CR>", 'g')

    " Note: Need to enter Terminal-Job mode for updating the terminal window

    let prev_winnr = winnr()
    call self.into_terminal_job_mode()

    call term_sendkeys(self.term_bufnr, str)
    call reply#log('String was sent to', self.name, ':', str)

    if winnr() != prev_winnr
        execute prev_winnr . 'wincmd w'
    endif
endfunction
let s:base.send_string = function('s:base_send_string')

function! s:base_extract_input_from_terminal_buf(lines) dict abort
    if !has_key(self, 'prompt_start') || self.prompt_start is v:null || !has_key(self, 'prompt_continue')
        throw reply#error("REPL '%s' does not support :ReplRecv", self.name)
    endif

    let exprs = []
    let continuing = v:false
    for idx in range(len(a:lines))
        let line = a:lines[idx]

        let s = matchstr(line, self.prompt_start)
        if s !=# ''
            let line = substitute(line[len(s) :], '\s\+$', '', '')
            if has_key(self, 'ignore_input_pattern') && line =~# self.ignore_input_pattern
                continue
            endif
            if line !=# ''
                let exprs += [line]
            endif
            let continuing = v:true
            continue
        endif

        let s = matchstr(line, self.prompt_continue isnot v:null ? self.prompt_continue : self.prompt_start)
        if s !=# ''
            let exprs += [substitute(line[len(s) :], '\s\+$', '', '')]
            continue
        endif

        let continuing = v:false
    endfor

    return exprs
endfunction
let s:base.extract_input_from_terminal_buf = function('s:base_extract_input_from_terminal_buf')

function! s:base_extract_user_input() dict abort
    if !bufexists(self.term_bufnr)
        throw reply#error("Terminal buffer #d for REPL '%s' is no longer existing", self.term_bufnr, self.name)
    endif

    let lines = getbufline(self.term_bufnr, 1, '$')
    if lines == [] || lines == ['']
        throw reply#error("Terminal buffer #d for REPL '%s' is empty", self.term_bufnr, self.name)
    endif

    let exprs = self.extract_input_from_terminal_buf(lines)
    call reply#log('Extracted lines from terminal #', self.term_bufnr, exprs)

    return exprs
endfunction
let s:base.extract_user_input = function('s:base_extract_user_input')

function! s:base_stop() dict abort
    if !self.running
        return
    endif

    let self.running = v:false

    " Maybe needed: call term_setkill(a:repl.term_bufnr, 'term')
    if bufexists(self.term_bufnr)
        try
            execute 'bdelete!' self.term_bufnr
        catch /^Vim\%((\a\+)\)\=:E516/
            " When the buffer is already deleted, skip deleting it
        endtry
        call reply#log('Stopped terminal', self.name, 'at', self.term_bufnr)
    else
        call reply#log('Terminal buffer to close is not found for ', self.name, 'at', self.term_bufnr)
    endif
endfunction
let s:base.stop = function('s:base_stop')

function! s:base_add_hook(hook, funcref) dict abort
    if !has_key(self, 'hooks')
        let self.hooks = {}
    endif
    if !has_key(self.hooks, a:hook)
        let self.hooks[a:hook] = [a:funcref]
    else
        let self.hooks[a:hook] += [a:funcref]
    endif
    call reply#log('Hook', a:hook, 'added:', self.hooks[a:hook])
endfunction
let s:base.add_hook = function('s:base_add_hook')

" config {
"   name: string;
" }
function! reply#repl#base(name, ...) abort
    let config = get(a:, 1, {})
    let r = deepcopy(s:base)
    let r.name = a:name
    if has_key(config, 'prompt_start')
        let r.prompt_start = config.prompt_start
    endif
    if has_key(config, 'prompt_continue')
        let r.prompt_continue = config.prompt_continue
    endif
    if has_key(config, 'ignore_input_pattern')
        let r.ignore_input_pattern = config.ignore_input_pattern
    endif
    let r.path_name = substitute(a:name, '-', '_', 'g')
    return r
endfunction
