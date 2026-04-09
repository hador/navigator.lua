-- Native vim.treesitter replacements for guihua.ts_obsolete
-- Eliminates dependency on guihua's ts_obsolete module which crashes on nvim 0.12+
local api = vim.api
local ts = vim.treesitter

local M = {}

-- ── ts_utils replacements ──────────────────────────────────────────

function M.get_node_at_cursor(winnr)
  winnr = winnr or 0
  local buf = api.nvim_win_get_buf(winnr)
  local cursor = api.nvim_win_get_cursor(winnr)
  return ts.get_node({ bufnr = buf, pos = { cursor[1] - 1, cursor[2] } })
end

function M.get_root_for_position(line, col, parser)
  if not parser then return nil end
  local trees = parser:trees()
  for _, tree in ipairs(trees) do
    local root = tree:root()
    if root and ts.is_in_node_range(root, line, col) then
      return root
    end
  end
  -- try injected languages
  if parser.children then
    for _, child in pairs(parser:children()) do
      local r = M.get_root_for_position(line, col, child)
      if r then return r end
    end
  end
  return trees[1] and trees[1]:root() or nil
end

function M.get_root_for_node(node)
  local parent = node
  local result = node
  while parent ~= nil do
    result = parent
    parent = result:parent()
  end
  return result
end

function M.goto_node(node, goto_end)
  if not node then return end
  vim.cmd("normal! m'") -- set jump mark
  local sr, sc, er, ec = node:range()
  local row, col
  if goto_end then
    row, col = er + 1, ec
  else
    row, col = sr + 1, sc
  end
  api.nvim_win_set_cursor(0, { row, col })
end

function M.is_parent(dest, source)
  if not (dest and source) then return false end
  return ts.is_ancestor(dest, source)
end

function M.node_to_lsp_range(node)
  local sr, sc, er, ec = ts.get_node_range(node)
  return { start = { line = sr, character = sc }, ['end'] = { line = er, character = ec } }
end

function M.get_next_node(node)
  if not node then return nil end
  local parent = node:parent()
  if not parent then return nil end
  local found = false
  for i = 0, parent:named_child_count() - 1 do
    if found then return parent:named_child(i) end
    if parent:named_child(i) == node then found = true end
  end
  return nil
end

function M._get_line_for_node(node, type_patterns, transform_fn, bufnr)
  local node_type = node:type()
  for _, rgx in ipairs(type_patterns) do
    if node_type:find(rgx) then
      local text = ts.get_node_text(node, bufnr)
      local line = vim.split(text, '\n')[1] or ''
      line = transform_fn(vim.trim(line), node)
      return line:gsub('%%', '%%%%')
    end
  end
  return ''
end

function M.highlight_node(node, buf, hl_namespace, hl_group)
  if not node then return end
  local sr, sc, er, ec = node:range()
  vim.highlight.range(buf, hl_namespace, hl_group, { sr, sc }, { er, ec })
end

-- ── ts_locals replacements ─────────────────────────────────────────

local locals = {}
M.locals = locals

local function get_query(bufnr, query_name)
  local lang = ts.language.get_lang(vim.bo[bufnr].filetype) or vim.bo[bufnr].filetype
  local ok, query = pcall(ts.query.get, lang, query_name)
  if not ok or not query then return nil end
  return query
end

local function get_root(bufnr)
  local parser = ts.get_parser(bufnr)
  if not parser then return nil end
  local tree = parser:trees()[1]
  return tree and tree:root() or nil
end

--- Run locals query and return structured matches
function locals.get_locals(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local query = get_query(bufnr, 'locals')
  local root = get_root(bufnr)
  if not query or not root then return {} end

  local results = {}
  for _, match, _ in query:iter_matches(root, bufnr, 0, -1, { all = true }) do
    local local_entry = {}
    for id, nodes in pairs(match) do
      local name = query.captures[id]
      -- name is like "definition.function", "scope", "reference"
      local parts = vim.split(name, '.', { plain = true })
      local tbl = local_entry
      for i = 1, #parts - 1 do
        tbl[parts[i]] = tbl[parts[i]] or {}
        tbl = tbl[parts[i]]
      end
      local node = type(nodes) == 'table' and nodes[1] or nodes
      if tbl[parts[#parts]] and type(tbl[parts[#parts]]) == 'table' and not tbl[parts[#parts]].node then
        tbl[parts[#parts]].node = node
      else
        tbl[parts[#parts]] = { node = node }
      end
    end
    table.insert(results, { ['local'] = local_entry })
  end
  return results
end

function locals.get_scopes(bufnr)
  local locs = locals.get_locals(bufnr)
  local scopes = {}
  for _, loc in ipairs(locs) do
    if loc['local']['scope'] and loc['local']['scope'].node then
      table.insert(scopes, loc['local']['scope'].node)
    end
  end
  return scopes
end

function locals.get_references(bufnr)
  local locs = locals.get_locals(bufnr)
  local refs = {}
  for _, loc in ipairs(locs) do
    if loc['local']['reference'] and loc['local']['reference'].node then
      table.insert(refs, loc['local']['reference'].node)
    end
  end
  return refs
end

function locals.recurse_local_nodes(local_def, accumulator, full_match, last_match)
  if type(local_def) ~= 'table' then return end
  if local_def.node then
    accumulator(local_def, local_def.node, full_match, last_match)
  else
    for match_key, def in pairs(local_def) do
      locals.recurse_local_nodes(
        def, accumulator,
        full_match and (full_match .. '.' .. match_key) or match_key,
        match_key
      )
    end
  end
end

--- Safe scope traversal — the core fix for the nvim 0.12 crash
local function containing_scope(node, bufnr, allow_scope)
  allow_scope = allow_scope == nil or allow_scope == true
  local scopes = locals.get_scopes(bufnr)
  if not node or not scopes then return nil end

  local iter_node = node
  while iter_node ~= nil and not vim.tbl_contains(scopes, iter_node) do
    local ok_p, parent = pcall(function() return iter_node:parent() end)
    if not ok_p then break end
    iter_node = parent
  end
  return iter_node or (allow_scope and node or nil)
end

local function iter_scope_tree(node, bufnr)
  local last_node = node
  return function()
    if not last_node then return end
    local scope = containing_scope(last_node, bufnr, false) or M.get_root_for_node(node)
    if not scope then return end
    local ok_p, parent = pcall(function() return scope:parent() end)
    last_node = ok_p and parent or nil
    return scope
  end
end

local function get_definition_id(scope, node_text)
  return table.concat({ 'k', node_text or '', scope:range() }, '_')
end

local def_cache = {}

local function get_definitions_lookup(bufnr)
  local tick = api.nvim_buf_get_changedtick(bufnr)
  if def_cache[bufnr] and def_cache[bufnr].tick == tick then
    return def_cache[bufnr].result
  end

  local locs = locals.get_locals(bufnr)
  local defs = {}
  for _, loc in ipairs(locs) do
    if loc['local']['definition'] then
      table.insert(defs, loc['local']['definition'])
    end
  end

  local result = {}
  for _, definition in ipairs(defs) do
    local nodes = {}
    locals.recurse_local_nodes(definition, function(def, node, kind)
      table.insert(nodes, vim.tbl_extend('keep', { kind = kind }, def))
    end)
    for _, entry in ipairs(nodes) do
      local scopes_list = {}
      for scope in iter_scope_tree(entry.node, bufnr) do
        table.insert(scopes_list, scope)
        if entry.scope ~= 'global' and entry.scope ~= 'parent' then break end
        if entry.scope == 'parent' and #scopes_list >= 2 then break end
      end
      local scope = scopes_list[#scopes_list]
      if scope then
        local text = ts.get_node_text(entry.node, bufnr)
        result[get_definition_id(scope, text)] = entry
      end
    end
  end

  def_cache[bufnr] = { tick = tick, result = result }
  return result
end

function locals.find_definition(node, bufnr)
  local lookup = get_definitions_lookup(bufnr)
  local node_text = ts.get_node_text(node, bufnr)

  for scope in iter_scope_tree(node, bufnr) do
    local id = get_definition_id(scope, node_text)
    if lookup[id] then
      return lookup[id].node, scope, lookup[id].kind
    end
  end
  return node, M.get_root_for_node(node), nil
end

function locals.find_usages(node, scope_node, bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local node_text = ts.get_node_text(node, bufnr)
  if not node_text or #node_text < 1 then return {} end

  scope_node = scope_node or M.get_root_for_node(node)
  local query = get_query(bufnr, 'locals')
  local root = scope_node
  if not query or not root then return {} end

  local usages = {}
  for _, match, _ in query:iter_matches(root, bufnr, 0, -1, { all = true }) do
    for id, nodes in pairs(match) do
      local name = query.captures[id]
      if name == 'reference' then
        local ref_node = type(nodes) == 'table' and nodes[1] or nodes
        if ts.get_node_text(ref_node, bufnr) == node_text then
          local def, _, kind = locals.find_definition(ref_node, bufnr)
          if kind == nil or def == node then
            table.insert(usages, ref_node)
          end
        end
      end
    end
  end
  return usages
end

-- Expose iter_locals for compatibility
function locals.iter_locals(bufnr, root)
  local query = get_query(bufnr, 'locals')
  if not query or not root then
    return function() end
  end
  local iter = query:iter_matches(root, bufnr, 0, -1, { all = true })
  return function()
    local _, match, _ = iter()
    if not match then return nil end
    local local_entry = {}
    for id, nodes in pairs(match) do
      local name = query.captures[id]
      local parts = vim.split(name, '.', { plain = true })
      local tbl = local_entry
      for i = 1, #parts - 1 do
        tbl[parts[i]] = tbl[parts[i]] or {}
        tbl = tbl[parts[i]]
      end
      local node = type(nodes) == 'table' and nodes[1] or nodes
      tbl[parts[#parts]] = { node = node }
    end
    return { ['local'] = local_entry }
  end
end

-- ── query compat (for foldts.lua) ──────────────────────────────────

local query_compat = {}
M.query = query_compat

function query_compat.has_folds(lang)
  local ok_q, _ = pcall(ts.query.get, lang, 'folds')
  return ok_q and _ ~= nil
end

function query_compat.has_locals(lang)
  local ok_q, _ = pcall(ts.query.get, lang, 'locals')
  return ok_q and _ ~= nil
end

function query_compat.get_capture_matches_recursively(bufnr, capture_or_fn)
  local parser = ts.get_parser(bufnr)
  if not parser then return {} end

  local matches = {}
  parser:for_each_tree(function(tree, lang_tree)
    local lang = lang_tree:lang()
    local capture, query_type
    if type(capture_or_fn) == 'function' then
      capture, query_type = capture_or_fn(lang, tree, lang_tree)
    else
      capture, query_type = capture_or_fn, nil
    end
    if not capture then return end

    -- strip leading @
    local cap_name = capture:sub(1, 1) == '@' and capture:sub(2) or capture
    local q = ts.query.get(lang, query_type or 'folds')
    if not q then return end

    for _, match, metadata in q:iter_matches(tree:root(), bufnr, 0, -1, { all = true }) do
      for id, nodes in pairs(match) do
        local name = q.captures[id]
        if name == cap_name then
          local node = type(nodes) == 'table' and nodes[1] or nodes
          table.insert(matches, { node = node, metadata = metadata })
        end
      end
    end
  end)
  return matches
end

-- ── memoize_by_buf_tick (for foldts.lua) ───────────────────────────

function M.memoize_by_buf_tick(fn)
  local cache = {}
  return function(bufnr, ...)
    bufnr = bufnr or api.nvim_get_current_buf()
    local tick = api.nvim_buf_get_changedtick(bufnr)
    if cache[bufnr] and cache[bufnr].tick == tick then
      return cache[bufnr].result
    end
    local result = fn(bufnr, ...)
    cache[bufnr] = { tick = tick, result = result }
    return result
  end
end

return M
