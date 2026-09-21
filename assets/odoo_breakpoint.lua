-- Odoo Breakpoint & PDB Toolkit for WezTerm
-- Features: Dynamic PDB Detection, Dynamic Autocomplete, Macros, Base64 Snippet Execution, Status Bar Badge.

local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

-- Base64 encoder helper for multi-line atomic snippet execution
local b64table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64_encode(data)
  return ((data:gsub('.', function(x)
    local r, b = '', x:byte()
    for i = 8, 1, -1 do r = r .. (b % 2^i - b % 2^(i-1) > 0 and '1' or '0') end
    return r
  end) .. '0000'):gsub('%d%d%d?%d?%d?', function(x)
    if #x < 6 then return '' end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i,i) == '1' and 2^(6-i) or 0) end
    return b64table:sub(c+1, c+1)
  end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

-- Sentinel Markers & Introspection Query Definitions
M.SENTINELS = {
  MODEL = "___IDE___MODEL___",
  ATTR = "___IDE___ATTR___",
}

-- Common Odoo Recordset Attributes & Fields for instant dropdown suggestions (e.g. self. / rec.)
M.RECORDSET_ATTRS = {
  { label = ".id (Record Primary Key)", id = ".id" },
  { label = ".name (Record Name)", id = ".name" },
  { label = ".display_name (Formatted Name)", id = ".display_name" },
  { label = ".state (Document State)", id = ".state" },
  { label = ".company_id (Active Company)", id = ".company_id" },
  { label = ".create_date (Creation Timestamp)", id = ".create_date" },
  { label = ".write_date (Modification Timestamp)", id = ".write_date" },
  { label = ".create_uid (Creating User)", id = ".create_uid" },
  { label = ".write_uid (Modifying User)", id = ".write_uid" },
  { label = ".env (Odoo Environment)", id = ".env" },
  { label = ".search([]) (ORM Search)", id = ".search([])" },
  { label = ".search_count([]) (ORM Search Count)", id = ".search_count([])" },
  { label = ".browse([]) (ORM Browse)", id = ".browse([])" },
  { label = ".filtered(lambda r: r.) (Lambda Filter)", id = ".filtered(lambda r: r.)" },
  { label = ".mapped('') (Field Mapper)", id = ".mapped('')" },
  { label = ".fields_get() (Schema Inspection)", id = ".fields_get()" },
  { label = ".read(['name']) (Dictionary Reader)", id = ".read(['name'])" },
  { label = ".read(max_length=20) (Truncated Read)", id = "[{k: (v[:20]+(b'...' if isinstance(v, bytes) else '...') if isinstance(v, (str, bytes)) and len(v)>20 else v) for k, v in d.items()} for d in .read()]" },
  { label = "🔍 Live Introspect Target in PDB...", id = "__introspect__" },
}

M.MACROS = {
  { label = "self.env[''] (Recordset Entry)", id = "self.env['']" },
  { label = ".search([]) (ORM Search)", id = ".search([])" },
  { label = ".browse([]) (ORM Browse)", id = ".browse([])" },
  { label = ".filtered(lambda r: r.) (Lambda Filter)", id = ".filtered(lambda r: r.)" },
  { label = ".fields_get() (Schema Inspection)", id = ".fields_get()" },
  { label = "self.env.cr.commit() (DB Commit)", id = "self.env.cr.commit()" },
  { label = ".mapped('') (Field Mapper)", id = ".mapped('')" },
  { label = ".read(['name']) (Dictionary Reader)", id = ".read(['name'])" },
  { label = ".read(max_length=20) (Truncated Read)", id = "[{k: (v[:20]+(b'...' if isinstance(v, bytes) else '...') if isinstance(v, (str, bytes)) and len(v)>20 else v) for k, v in d.items()} for d in .read()]" },
}

M.DOMAIN_OPERATORS = {
  { label = "= (Equals)", id = "'='" },
  { label = "!= (Not Equals)", id = "'!='" },
  { label = "in (Contains in List)", id = "'in'" },
  { label = "not in (Not in List)", id = "'not in'" },
  { label = "ilike (Case-Insensitive Substring)", id = "'ilike'" },
  { label = "like (Case-Sensitive Substring)", id = "'like'" },
  { label = ">= (Greater or Equal)", id = "'>='" },
  { label = "<= (Less or Equal)", id = "'<='" },
}

-- Detect if active pane scrollback contains PDB interactive prompt
function M.is_pdb_active(pane)
  local text = pane:get_lines_as_text(10)
  if not text then return false end
  return text:match("%(Pdb%)%s*$") ~= nil or text:match("%(ipdb%)%s*$") ~= nil or text:match("%n%(Pdb%)") ~= nil
end

-- Action: Execute silent introspection query in PDB
function M.send_silent_introspection(pane, py_code)
  if not pane then return end
  local cmd = "\x15!" .. py_code .. "\n"
  pane:send_text(cmd)
end

M.pending_autocomplete = nil

-- Action: Query Python in background and emit OSC 1337 user var with dynamic fields
function M.query_and_show_autocomplete(window, pane, prefix, var_name, had_dot)
  M.pending_autocomplete = {
    prefix = prefix or "",
    var_name = var_name,
    had_dot = had_dot,
  }

  local py_cmd = string.format(
    [[!import json, base64, sys; f = []; exec("try:\n v = eval('%s')\n f.extend(list(getattr(v, '_fields', {}).keys()) or [a for a in dir(v) if not a.startswith('_')])\nexcept: pass"); sys.stdout.write('\033]1337;SetUserVar=ODOO_AUTOCOMPLETE=' + base64.b64encode(json.dumps(f).encode()).decode() + '\007'); sys.stdout.flush()]],
    var_name:gsub("'", "\\'")
  )
  M.send_silent_introspection(pane, py_cmd)
end

-- Action: Open Dynamic Autocomplete Dropdown (inspects current line for 'picking', 'self', etc.)
function M.show_dynamic_autocomplete()
  return wezterm.action_callback(function(window, pane)
    local text = pane:get_lines_as_text(4) or ""
    local last_line = text:match("([^\r\n]+)%s*$") or ""

    -- Extract text after (Pdb) or >>> prompt
    local input_part = last_line:match("%(Pdb%)%s*(.*)$")
    if not input_part then
      input_part = last_line:match(">>>%s*(.*)$") or last_line:match("In%s*%[%d+%]:%s*(.*)$") or last_line
    end

    -- Match prefix, variable/recordset name, and trailing dot
    -- e.g. "picking." -> prefix="", var_name="picking", dot="."
    -- e.g. "print(picking." -> prefix="print(", var_name="picking", dot="."
    -- e.g. "self" -> prefix="", var_name="self", dot=""
    local prefix, var_name, dot = input_part:match("^(.-)([%w_%.%[%]'\"]+)(%.?)$")

    if not var_name or var_name == "" or var_name == "(Pdb)" then
      -- If nothing typed on prompt, prompt user for object name (defaulting to self)
      window:perform_action(
        act.PromptInputLine {
          description = "⚡ Autocomplete: Enter variable/recordset to inspect (e.g. self, picking, partner):",
          initial_value = "self",
          action = wezterm.action_callback(function(w, p, line)
            if line and line:gsub("%s+", "") ~= "" then
              M.query_and_show_autocomplete(w, p, "", line:gsub("%s+", ""), false)
            end
          end),
        },
        pane
      )
      return
    end

    M.query_and_show_autocomplete(window, pane, prefix or "", var_name, dot == ".")
  end)
end

-- Action: Open Smart Macro Expansion Picker
function M.show_macro_picker()
  return act.InputSelector {
    title = "⚡ Odoo PDB Macro Expansions",
    choices = M.MACROS,
    action = wezterm.action_callback(function(window, pane, id, label)
      if id then
        pane:send_text(id)
      end
    end),
  }
end

-- Action: Open Domain Operator Autocomplete Picker
function M.show_domain_picker()
  return act.InputSelector {
    title = "🔍 Odoo Domain Operator Picker",
    choices = M.DOMAIN_OPERATORS,
    action = wezterm.action_callback(function(window, pane, id, label)
      if id then
        pane:send_text(id)
      end
    end),
  }
end

-- Action: Open Introspection Autocomplete Menu (Models / Fields / Variables)
function M.show_introspection_picker()
  local choices = {
    { label = "Refresh Model Registry Cache", id = "refresh_models" },
    { label = "Inspect Recordset Fields (_fields)", id = "inspect_fields" },
    { label = "Inspect Variable Attributes (dir)", id = "inspect_dir" },
    { label = "Insert Domain Operator", id = "domain_ops" },
  }

  return act.InputSelector {
    title = "🐍 Odoo PDB Introspection & Autocomplete",
    choices = choices,
    action = wezterm.action_callback(function(window, pane, id, label)
      if not id then return end
      if id == "refresh_models" then
        local query = [[import json; print("___IDE___MODEL___" + json.dumps(list(self.env.registry.keys())) + "___IDE___MODEL___")]]
        M.send_silent_introspection(pane, query)
      elseif id == "inspect_fields" then
        window:perform_action(
          act.PromptInputLine {
            description = "Enter Model Name or Variable (e.g. account.move or self):",
            action = wezterm.action_callback(function(w, p, line)
              if line and line ~= "" then
                local target = line:match("^['\"](.*)['\"]$") or line
                local query = string.format(
                  [[import json; target = '%s'; print("___IDE___ATTR___" + json.dumps(list(self.env[target]._fields.keys() if target in self.env.registry else getattr(eval(target), '_fields', {}).keys())) + "___IDE___ATTR___")]],
                  target
                )
                M.send_silent_introspection(p, query)
              end
            end),
          },
          pane
        )
      elseif id == "inspect_dir" then
        window:perform_action(
          act.PromptInputLine {
            description = "Enter Variable Expression (e.g. self or partner):",
            action = wezterm.action_callback(function(w, p, line)
              if line and line ~= "" then
                local query = string.format(
                  [[import json; v = eval('%s'); print("___IDE___ATTR___" + json.dumps([a for a in dir(v) if not a.startswith('_')]) + "___IDE___ATTR___")]],
                  line
                )
                M.send_silent_introspection(p, query)
              end
            end),
          },
          pane
        )
      elseif id == "domain_ops" then
        window:perform_action(M.show_domain_picker(), pane)
      end
    end),
  }
end

-- Action: Multi-Line Atomic Snippet Execution (Base64 Payload Wrapper)
function M.show_snippet_executor()
  return act.PromptInputLine {
    description = "📝 Multi-Line Atomic Snippet Executor (Base64 Wrapped):\nEnter/Paste Python code (Use \\n for newlines, or paste block):",
    action = wezterm.action_callback(function(window, pane, raw_code)
      if raw_code and raw_code:gsub("%s+", "") ~= "" then
        local b64 = base64_encode(raw_code)
        local cmd = string.format(
          '\x15!import base64; exec(compile(base64.b64decode("%s").decode("utf-8"), "<snippet>", "single"))\n',
          b64
        )
        pane:send_text(cmd)
      end
    end),
  }
end

-- Action: Truncated .read(max_length=N) execution for Odoo recordsets
function M.show_truncated_read()
  return act.PromptInputLine {
    description = "✂️ Truncated .read() Inspector:\nEnter recordset expression (e.g. self.message_ids or self) and optional max_length [default 20]:",
    action = wezterm.action_callback(function(window, pane, line)
      if not line or line:gsub("%s+", "") == "" then return end
      local expr, max_len_str = line:match("^([^,]+)%s*,?%s*(%d*)$")
      expr = expr or line
      local max_len = tonumber(max_len_str) or 20

      -- Strip trailing .read() or .read(...) if user already typed it in the expression
      expr = expr:gsub("%.read%b()%s*$", ""):gsub("%s+$", "")

      local py_cmd = string.format(
        '[{k: (v[:%d] + (b"..." if isinstance(v, bytes) else "...")) if isinstance(v, (str, bytes)) and len(v) > %d else v for k, v in d.items()} for d in ((%s).read() if hasattr((%s), "read") else (%s))]\n',
        max_len, max_len, expr, expr, expr
      )
      pane:send_text("\x15" .. py_cmd)
    end),
  }
end

-- Action: Clear current line and restore terminal state (stty sane) in shell & PDB
function M.reset_terminal_sane()
  return wezterm.action_callback(function(window, pane)
    if not pane then return end
    -- 1. Clear current line buffer (Ctrl+U) and interrupt (Ctrl+C)
    pane:send_text("\x15\x03")
    -- 2. Try standard shell command 'stty sane'
    pane:send_text("stty sane\n")
    -- 3. Send Python PDB fallback import os; os.system('stty sane') if inside PDB
    pane:send_text('!import os; os.system("stty sane")\n')
  end)
end

-- Apply status bar listener and keybindings to WezTerm config
function M.apply_to_config(config)
  -- Leader key setting if not set
  if not config.leader then
    config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1000 }
  end

  config.keys = config.keys or {}

  -- Keybinding: Ctrl+Q Terminal Line Reset & stty sane
  table.insert(config.keys, {
    key = 'q',
    mods = 'CTRL',
    action = M.reset_terminal_sane(),
  })

  -- Keybinding: Ctrl+Space -> Dynamic Autocomplete (e.g. self. / picking.)
  table.insert(config.keys, {
    key = ' ',
    mods = 'CTRL',
    action = M.show_dynamic_autocomplete(),
  })

  -- Keybindings for Breakpoint Features
  table.insert(config.keys, {
    key = 'r',
    mods = 'LEADER',
    action = M.show_truncated_read(),
  })

  table.insert(config.keys, {
    key = 'a',
    mods = 'LEADER',
    action = M.show_dynamic_autocomplete(),
  })

  table.insert(config.keys, {
    key = 'm',
    mods = 'LEADER',
    action = M.show_macro_picker(),
  })

  table.insert(config.keys, {
    key = 'i',
    mods = 'LEADER',
    action = M.show_introspection_picker(),
  })

  table.insert(config.keys, {
    key = 's',
    mods = 'LEADER',
    action = M.show_snippet_executor(),
  })

  table.insert(config.keys, {
    key = 'd',
    mods = 'LEADER',
    action = M.show_domain_picker(),
  })

  -- Event: Receive dynamic fields from Python OSC 1337 and display autocomplete dropdown
  wezterm.on('user-var-changed', function(window, pane, name, value)
    if name == 'ODOO_AUTOCOMPLETE' then
      local pending = M.pending_autocomplete
      local prefix = pending and pending.prefix or ""
      local var_name = pending and pending.var_name or "self"

      local ok, fields = pcall(wezterm.json_parse, value)
      if not ok or type(fields) ~= 'table' or #fields == 0 then
        fields = { "id", "name", "display_name", "state", "origin", "partner_id", "create_date", "company_id", "env", "search", "browse", "filtered", "mapped" }
      end

      -- Sort fields with high-priority Odoo attributes at top
      table.sort(fields, function(a, b)
        local prio = { id = 1, name = 2, display_name = 3, state = 4, origin = 5, partner_id = 6 }
        local pa = prio[a] or 100
        local pb = prio[b] or 100
        if pa ~= pb then return pa < pb end
        return a < b
      end)

      local choices = {}
      for _, f in ipairs(fields) do
        table.insert(choices, {
          id = f,
          label = string.format(".%-24s (field/attr)", f),
        })
      end

      window:perform_action(
        act.InputSelector {
          title = "⚡ Odoo Autocomplete: " .. var_name,
          choices = choices,
          fuzzy = true,
          description = "Select field/attribute for '" .. var_name .. "' (Type to fuzzy filter, Enter=Insert, Esc=Cancel):",
          action = wezterm.action_callback(function(w, p, id, label)
            if id then
              p:send_text(prefix .. var_name .. "." .. id)
            end
          end),
        },
        pane
      )
    end
  end)

  -- Event: Update status bar with active PDB indicator
  wezterm.on('update-right-status', function(window, pane)
    local is_pdb = M.is_pdb_active(pane)
    if is_pdb then
      window:set_right_status(wezterm.format {
        { Background = { Color = '#b81414' } },
        { Foreground = { Color = '#ffffff' } },
        { Attribute = { Intensity = 'Bold' } },
        { Text = ' 🔴 PDB BREAKPOINT ACTIVE ' },
      })
    end
  end)
end

return M
