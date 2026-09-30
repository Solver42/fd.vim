vim9script

const MAX_FILES = get(g:, 'fd_max_files', 500)           # cap on listed files
const PREVIEW_LINES = get(g:, 'fd_preview_lines', 200)   # lines shown in the preview
const MAX_SIZE = get(g:, 'fd_max_size', 2 * 1024 * 1024) # bytes; bigger files aren't previewed

const FD = executable('fd') ? 'fd' : executable('fdfind') ? 'fdfind' : ''

# ---------------------------------------------------------------------------
# State (one picker at a time)
# ---------------------------------------------------------------------------
var query = ''
var results: list<string> = []       # matching paths relative to root, sorted,
                                     # at most MAX_FILES of them
var total = 0                        # how many files matched (results is capped)
var selected = 0
var search_id = 0                    # bumped per search; late results from an
                                     # outdated search are discarded on arrival
var live_jobs: list<job> = []        # keeps every in-flight job referenced so
                                     # Vim can't drop it before close_cb fires
var root = ''                        # cwd captured once when the picker opens;
                                     # every path is resolved against this,
                                     # not the live cwd, which can change
                                     # under us (e.g. after OpenSelected())
var files_win = 0
var preview_win = 0
var cursor_hidden = false            # true while &t_ve is blanked (see Open())
var saved_t_ve = ''

# ---------------------------------------------------------------------------
# Highlight groups
# ---------------------------------------------------------------------------
def DefineHighlights()
  highlight default link FdSelected PmenuSel
  highlight default link FdInfo Comment
  highlight default link FdLineNr LineNr
  highlight default link FdSep Comment
  highlight default link FdPrompt Title
  highlight default link FdCursor Cursor
enddef

# ---------------------------------------------------------------------------
# Searching
# ---------------------------------------------------------------------------
def SearchCmd(): list<string>
  # Extra flags from the user's vimrc, e.g.
  #   g:fd_args = ['--hidden', '--exclude', '.git']
  var extra: list<string> = get(g:, 'fd_args', [])
  var cmd = [FD, '--type', 'f', '--color=never'] + extra
  if query != ''
    cmd += ['--fixed-strings']
    if stridx(query, '/') >= 0
      cmd += ['--full-path']
    endif
    cmd += ['--', query]
  endif
  return cmd
enddef

def StartSearch()
  search_id += 1
  var this_id = search_id
  var lines: list<string> = []
  var j = job_start(SearchCmd(), {
    out_cb: (_, line) => add(lines, line),
    # close_cb, not exit_cb: the process can exit while output is still
    # buffered in the pipe, whereas close_cb only fires once every line has
    # been handed to out_cb.
    close_cb: (_) => Finished(this_id, lines),
    out_mode: 'nl',
    in_io: 'null',
    err_io: 'null',
    cwd: root,
  })
  # Older searches are never stopped, just outdated: Finished() drops their
  # results via this_id. Keeping the job objects referenced is cheap insurance
  # against Vim collecting a job before its close_cb fires.
  add(live_jobs, j)
enddef

# Runs when a search job's output is complete. A superseded search still gets
# here, but this_id no longer matches search_id and its result is dropped.
def Finished(this_id: number, lines: list<string>)
  live_jobs = filter(live_jobs, (_, j) => job_status(j) ==# 'run')
  if this_id != search_id
    return
  endif
  sort(lines)
  total = len(lines)
  # Older fd prefixes paths with "./" when piped; newer doesn't.
  results = mapnew(lines[: MAX_FILES - 1], (_, l) => substitute(l, '^\./', '', ''))
  selected = min([selected, max([len(results) - 1, 0])])
  Render()
enddef

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
def Render()
  if files_win == 0
    return
  endif
  RenderFiles()
  RenderPreview()
enddef

def RenderFiles()
  var width = popup_getpos(files_win).core_width
  var text: list<any> = []

  # Line 1 is always the prompt: "> query█". The drawn block is the cursor;
  # the real terminal cursor is hidden while the picker is open (see Open()).
  var prompt = '> ' .. query
  var prompt_pad = repeat(' ', max([width - strwidth(prompt) - 1, 0]))
  add(text, {text: prompt .. '█' .. prompt_pad, props: [
    {col: 1, length: len(prompt), type: 'FdPrompt'},
    {col: len(prompt) + 1, length: len('█'), type: 'FdCursor'},
  ]})
  add(text, {text: repeat('─', width), props: [{col: 1, length: len(repeat('─', width)), type: 'FdSep'}]})

  for i in range(len(results))
    var name = results[i]
    # Clip on the left so the file name itself stays visible.
    if strwidth(name) > width
      name = '…' .. strcharpart(name, strchars(name) - width + 1)
    endif
    var line = name .. repeat(' ', max([width - strwidth(name), 0]))
    add(text, {text: line, props: i == selected ? [{col: 1, length: len(line), type: 'FdSelected'}] : []})
  endfor
  if empty(results)
    add(text, {text: ' no matches', props: [{col: 1, length: 11, type: 'FdInfo'}]})
  endif
  popup_settext(files_win, text)
  # Keep the selection scrolled into view. Selected file is at buffer line
  # (selected + 3): 2 header lines above it.
  win_execute(files_win, 'normal! ' .. (selected + 3) .. 'Gzz')
  popup_setoptions(files_win, {title: ' fd (' .. total .. ' files) '})
enddef

# rg's own rule: a file is binary if its first bytes contain a NUL.
def IsBinary(path: string): bool
  for byte in readblob(path, 0, 8192)
    if byte == 0
      return true
    endif
  endfor
  return false
enddef

def RenderPreview()
  if empty(results)
    popup_settext(preview_win, '')
    return
  endif
  var file = results[selected]
  # Resolve against the root captured at picker-open time, not the live cwd.
  var path = root .. '/' .. file

  # fd lists every kind of file, not just text: don't read binary or huge ones.
  var note = ''
  var file_lines: list<string> = []
  if !filereadable(path)
    note = ' cannot read file'
  elseif IsBinary(path)
    note = ' binary file'
  elseif getfsize(path) > MAX_SIZE
    note = ' file too large'
  else
    file_lines = readfile(path, '', PREVIEW_LINES)
  endif

  var text: list<any> = []
  var digits = len(string(len(file_lines)))
  var maxw = popup_getpos(preview_win).core_width
  for n in range(1, len(file_lines))
    var prefix = printf('%' .. digits .. 'd ', n)
    var line = substitute(file_lines[n - 1], '\t', '  ', 'g')
    line = substitute(line, '[[:cntrl:]]', '?', 'g')
    # Clip to the pane ourselves so the window never has to scroll
    # horizontally: long lines are cut on the right, starts always visible.
    line = strcharpart(line, 0, max([maxw - strwidth(prefix), 0]))
    add(text, {text: prefix .. line, props: [{col: 1, length: len(prefix), type: 'FdLineNr'}]})
  endfor
  if note != ''
    add(text, {text: note, props: [{col: 1, length: len(note), type: 'FdInfo'}]})
  endif

  popup_settext(preview_win, text)
  popup_setoptions(preview_win, {title: ' ' .. file .. ' '})
  win_execute(preview_win, 'normal! gg')
enddef

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------
def Move(delta: number)
  if empty(results)
    return
  endif
  selected = (selected + delta + len(results)) % len(results)
  Render()
enddef

def OpenSelected()
  if empty(results)
    return
  endif
  var path = root .. '/' .. results[selected]
  Close()
  execute 'edit ' .. fnameescape(path)
enddef

def Close()
  var wins = [files_win, preview_win]
  files_win = 0
  preview_win = 0
  for w in wins
    if w != 0
      popup_close(w)
    endif
  endfor
  if cursor_hidden
    &t_ve = saved_t_ve
    cursor_hidden = false
  endif
  # Any search job still running at this point will finish on its own and
  # call Finished(), but Render() bails out immediately once files_win is 0
  # (above), so a late result from a closed picker is harmlessly ignored.
enddef

def Filter(winid: number, key: string): bool
  if key == "\<Esc>" || key == "\<C-c>"
    Close()
  elseif key == "\<CR>"
    OpenSelected()
  elseif key == "\<C-n>" || key == "\<Down>" || key == "\<C-j>"
    Move(1)
  elseif key == "\<C-p>" || key == "\<Up>" || key == "\<C-k>"
    Move(-1)
  elseif key == "\<C-d>" || key == "\<C-f>"
    win_execute(preview_win, "normal! \<C-d>")
  elseif key == "\<C-b>" || key == "\<C-u>"
    win_execute(preview_win, "normal! \<C-u>")
  elseif key == "\<BS>" || key == "\<C-h>" || key == "\<Del>"
    query = strcharpart(query, 0, max([strchars(query) - 1, 0]))
    selected = 0
    RenderFiles()  # repaint the prompt line immediately; StartSearch()'s
                   # own completion will refresh the result rows shortly
    StartSearch()
  elseif strchars(key) == 1 && char2nr(key) >= 32
    query ..= key
    selected = 0
    RenderFiles()  # same: don't wait on the job to show what was typed
    StartSearch()
  endif
  return true  # swallow every key while the picker is open
enddef

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
export def Open(initial: string)
  if FD == ''
    echoerr 'fd.vim requires fd to be installed and on your PATH.'
    return
  endif
  Close()
  DefineHighlights()
  for name in ['FdSelected', 'FdInfo', 'FdLineNr', 'FdSep', 'FdPrompt', 'FdCursor']
    if empty(prop_type_get(name))
      prop_type_add(name, {highlight: name, combine: false})
    endif
  endfor

  query = initial
  selected = 0
  results = []
  total = 0
  root = getcwd()  # captured once, here, and used for every path from now on

  # Hide the real terminal cursor, which would otherwise sit in the window
  # behind the popups. Vim only shows the cursor by sending t_ve, so blanking
  # it keeps the cursor hidden; Close() puts it back.
  saved_t_ve = &t_ve
  &t_ve = ''
  cursor_hidden = true

  # Each popup has a 1-cell border on every side, so it occupies content + 2.
  # Two popups side by side must fill &columns exactly; height leaves room for
  # the cmdline (&cmdheight) so nothing is hidden behind it.
  var outer_h = &lines - &cmdheight
  var inner_h = outer_h - 2
  var left_outer = &columns * 2 / 5
  var right_outer = &columns - left_outer
  var left_w = left_outer - 2
  var right_w = right_outer - 2

  files_win = popup_create('', {
    line: 1, col: 1,
    minwidth: left_w, maxwidth: left_w,
    minheight: inner_h, maxheight: inner_h,
    border: [],
    borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    zindex: 200,
    wrap: false,
    scrollbar: false,
    filter: Filter,
    mapping: false,
    callback: (_, _) => Close(),
  })
  preview_win = popup_create('', {
    line: 1, col: left_outer + 1,
    minwidth: right_w, maxwidth: right_w,
    minheight: inner_h, maxheight: inner_h,
    border: [],
    borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    zindex: 200,
    wrap: false,
    scrollbar: false,
  })
  StartSearch()
enddef
