-- Odoo Breakpoint & PDB Toolkit for WezTerm
-- Features: Dynamic PDB Detection, Dynamic Autocomplete, Macros, Base64 Snippet Execution, Status Bar Badge.

local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

-- Base64 encoder helper for multi-line atomic snippet execution and introspection
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64_encode(data)
  local result = {}
  local len = #data
  local pad = 3 - (len % 3)
  if pad == 3 then pad = 0 end
  for i = 1, len, 3 do
    local b1 = data:byte(i)
    local b2 = data:byte(i + 1) or 0
    local b3 = data:byte(i + 2) or 0
    local n = b1 * 65536 + b2 * 256 + b3
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64
    table.insert(result, b64chars:sub(c1 + 1, c1 + 1))
    table.insert(result, b64chars:sub(c2 + 1, c2 + 1))
    table.insert(result, b64chars:sub(c3 + 1, c3 + 1))
    table.insert(result, b64chars:sub(c4 + 1, c4 + 1))
  end
  if pad == 1 then
    result[#result] = '='
  elseif pad == 2 then
    result[#result] = '='
    result[#result - 1] = '='
  end
  return table.concat(result)
end

-- Sentinel Markers & Introspection Query Definitions
M.SENTINELS = {
  MODEL = "___IDE___MODEL___",
  ATTR = "___IDE___ATTR___",
}

-- Common Odoo Recordset Attributes & Fields for instant dropdown suggestions (e.g. self. / rec.)
M.RECORDSET_ATTRS = {
  { label = ".id                                🏷️  [FIELD]", id = ".id" },
  { label = ".name                              🏷️  [FIELD]", id = ".name" },
  { label = ".display_name                      🏷️  [FIELD]", id = ".display_name" },
  { label = ".state                             🏷️  [FIELD]", id = ".state" },
  { label = ".origin                            🏷️  [FIELD]", id = ".origin" },
  { label = ".partner_id                        🏷️  [FIELD]", id = ".partner_id" },
  { label = ".company_id                        🏷️  [FIELD]", id = ".company_id" },
  { label = ".create_date                       🏷️  [FIELD]", id = ".create_date" },
  { label = ".write_date                        🏷️  [FIELD]", id = ".write_date" },
  { label = ".search([])                        ⚡ [METHOD]", id = ".search([])" },
  { label = ".search_count([])                  ⚡ [METHOD]", id = ".search_count([])" },
  { label = ".browse()                          ⚡ [METHOD]", id = ".browse()" },
  { label = ".filtered(lambda r: r.)            ⚡ [METHOD]", id = ".filtered(lambda r: r.)" },
  { label = ".mapped('')                        ⚡ [METHOD]", id = ".mapped('')" },
  { label = ".fields_get()                      ⚡ [METHOD]", id = ".fields_get()" },
  { label = ".read(['name'])                    ⚡ [METHOD]", id = ".read(['name'])" },
  { label = ".read(max_length=20)               ⚡ [METHOD]", id = "[{k: (v[:20]+(b'...' if isinstance(v, bytes) else '...') if isinstance(v, (str, bytes)) and len(v)>20 else v) for k, v in d.items()} for d in .read()]" },
  { label = ".env                               📦 [ATTR]", id = ".env" },
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

-- Action: Execute silent introspection query in PDB or Python Shell
function M.send_silent_introspection(pane, py_code)
  if not pane then return end
  local text = pane:get_lines_as_text(5) or ""
  local last_line = text:match("([^\r\n]+)%s*$") or ""
  local is_pdb = last_line:match("%(Pdb%)") ~= nil or last_line:match("%(ipdb%)") ~= nil
  if not is_pdb and (text:match("%(Pdb%)%s*$") ~= nil or text:match("%(ipdb%)%s*$") ~= nil) then
    is_pdb = true
  end
  -- In PDB, statements must be prefixed with '!', in standard Python shell (>>>) no '!' prefix
  local prefix = is_pdb and "\x15!" or "\x15"
  local cmd = prefix .. py_code .. "\n"
  pane:send_text(cmd)
end

M.pending_autocomplete = nil

-- Action: Query Python in background and emit OSC 1337 user var with dynamic fields, methods, and attributes
function M.query_and_show_autocomplete(window, pane, prefix, var_name, had_dot)
  -- Strip trailing dots and spaces to avoid syntax error in eval: e.g. "self.env['res.users']." -> "self.env['res.users']"
  local clean_var = var_name:gsub("%.+$", ""):gsub("%s+$", "")
  if clean_var == "" then clean_var = "self" end

  M.pending_autocomplete = {
    prefix = prefix or "",
    var_name = clean_var,
    had_dot = had_dot,
  }

  -- Use Base64 encoding of clean_var to prevent any quote or syntax escaping issues
  local var_b64 = base64_encode(clean_var)
  local py_template = string.format([=[
import sys, json, base64
__res = {"f": [], "m": [], "a": []}
try:
    __expr = base64.b64decode("%s").decode("utf-8")
    __v = eval(__expr)
    
    __fset = set()
    if hasattr(__v, "_fields") and isinstance(__v._fields, dict):
        __fset.update(__v._fields.keys())
    elif hasattr(__v, "fields_get") and callable(__v.fields_get):
        try:
            __fset.update(__v.fields_get().keys())
        except Exception:
            pass
            
    __res["f"] = sorted(__fset)
    
    for __attr in sorted(dir(__v)):
        if not __attr.startswith("_") and __attr not in __fset:
            try:
                __val = getattr(__v, __attr, None)
                if callable(__val):
                    __res["m"].append(__attr)
                else:
                    __res["a"].append(__attr)
            except Exception:
                __res["a"].append(__attr)
except Exception:
    pass

sys.stdout.write("\033]1337;SetUserVar=ODOO_AUTOCOMPLETE=" + base64.b64encode(json.dumps(__res).encode()).decode() + "\007")
sys.stdout.flush()
]=], var_b64)

  local inner_b64 = base64_encode(py_template)
  local py_cmd = string.format(
    'import base64; exec(base64.b64decode("%s").decode("utf-8"), globals(), locals())',
    inner_b64
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
    input_part = input_part:gsub("%s+$", "")

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
        local py_code = string.format(
          'import base64, textwrap; exec(textwrap.dedent(base64.b64decode("%s").decode("utf-8")), globals(), locals())',
          b64
        )
        M.send_silent_introspection(pane, py_code)
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

      local ok, res = pcall(wezterm.json_parse, value)
      local fields = {}
      local methods = {}
      local attrs = {}

      if ok and type(res) == 'table' then
        if type(res.f) == 'table' then fields = res.f end
        if type(res.m) == 'table' then methods = res.m end
        if type(res.a) == 'table' then attrs = res.a end

        -- Backwards compatibility if res was a flat array or list of objects
        if #fields == 0 and #methods == 0 and #attrs == 0 and #res > 0 then
          for _, item in ipairs(res) do
            if type(item) == 'table' and item.name then
              if item.type == 'method' then
                table.insert(methods, item.name)
              elseif item.type == 'attr' then
                table.insert(attrs, item.name)
              else
                table.insert(fields, item.name)
              end
            elseif type(item) == 'string' then
              table.insert(fields, item)
            end
          end
        end
      end

      -- If dynamic introspection returned empty (e.g. invalid target or offline fallback)
      if #fields == 0 and #methods == 0 and #attrs == 0 then
        fields = { "id", "name", "display_name", "state", "origin", "partner_id", "company_id", "create_date", "write_date", "l10n_gstr" }
        methods = { "search", "search_count", "browse", "filtered", "mapped", "read", "fields_get", "action_confirm", "write", "create", "unlink" }
        attrs = { "env", "ids", "_name", "_description" }
      end

      -- Sort fields with high-priority Odoo fields at top
      local field_prio = {
        id = 1,
        name = 2,
        display_name = 3,
        state = 4,
        origin = 5,
        partner_id = 6,
        company_id = 7,
        create_date = 8,
        write_date = 9,
      }
      table.sort(fields, function(a, b)
        local pa = field_prio[a] or 100
        local pb = field_prio[b] or 100
        if pa ~= pb then return pa < pb end
        return a < b
      end)

      -- Sort common Odoo ORM methods at top
      local method_prio = {
        search = 1,
        search_count = 2,
        browse = 3,
        filtered = 4,
        mapped = 5,
        read = 6,
        fields_get = 7,
        write = 8,
        create = 9,
        unlink = 10,
      }
      table.sort(methods, function(a, b)
        local pa = method_prio[a] or 100
        local pb = method_prio[b] or 100
        if pa ~= pb then return pa < pb end
        return a < b
      end)

      -- Sort common attributes at top
      local attr_prio = {
        env = 1,
        ids = 2,
        _name = 3,
        _description = 4,
        cr = 5,
        context = 6,
      }
      table.sort(attrs, function(a, b)
        local pa = attr_prio[a] or 100
        local pb = attr_prio[b] or 100
        if pa ~= pb then return pa < pb end
        return a < b
      end)

      local choices = {}

      -- 1. FIELDS SECTION (e.g. .l10n_gstr, .name, .partner_id)
      for _, f in ipairs(fields) do
        table.insert(choices, {
          id = f,
          label = string.format(".%-32s 🏷️  [FIELD]", f),
        })
      end

      -- 2. METHODS SECTION (e.g. .search([]), .action_confirm(), .browse())
      for _, m in ipairs(methods) do
        local call_repr = m .. "()"
        local insert_id = m .. "()"
        if m == "search" or m == "search_count" then
          call_repr = m .. "([])"
          insert_id = m .. "([])"
        elseif m == "filtered" then
          call_repr = m .. "(lambda r: ...)"
          insert_id = m .. "(lambda r: r.)"
        elseif m == "mapped" then
          call_repr = m .. "('...')"
          insert_id = m .. "('')"
        end
        table.insert(choices, {
          id = insert_id,
          label = string.format(".%-32s ⚡ [METHOD]", call_repr),
        })
      end

      -- 3. ATTRIBUTES SECTION (e.g. .env, .ids)
      for _, a in ipairs(attrs) do
        table.insert(choices, {
          id = a,
          label = string.format(".%-32s 📦 [ATTR]", a),
        })
      end

      window:perform_action(
        act.InputSelector {
          title = "⚡ Odoo Autocomplete: " .. var_name,
          choices = choices,
          fuzzy = true,
          description = "Select field, method or attribute for '" .. var_name .. "' (Type to fuzzy filter, Enter=Insert, Esc=Cancel):",
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
