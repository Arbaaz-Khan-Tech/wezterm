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

-- Action: Open Dynamic Autocomplete Dropdown (for self. / rec. / variable)
function M.show_dynamic_autocomplete()
  return act.InputSelector {
    title = "⚡ Odoo Autocomplete Dropdown (e.g. self.id, self.name)",
    choices = M.RECORDSET_ATTRS,
    action = wezterm.action_callback(function(window, pane, id, label)
      if not id then return end
      if id == "__introspect__" then
        window:perform_action(
          act.PromptInputLine {
            description = "Enter Object/Variable to introspect in live PDB (e.g. self, rec, partner):",
            action = wezterm.action_callback(function(w, p, var_name)
              if var_name and var_name ~= "" then
                local query = string.format(
                  [[import json; v = eval('%s'); print("___IDE___ATTR___" + json.dumps(list(getattr(v, '_fields', {}).keys()) or [a for a in dir(v) if not a.startswith('_')]) + "___IDE___ATTR___")]],
                  var_name
                )
                M.send_silent_introspection(p, query)
              end
            end),
          },
          pane
        )
      else
        pane:send_text(id)
      end
    end),
  }
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

  -- Keybindings for Breakpoint Features
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
