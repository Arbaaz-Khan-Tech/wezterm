-- Example WezTerm Configuration featuring Odoo Breakpoint & PDB Toolkit
-- Copy or include this into your ~/.config/wezterm/wezterm.lua

local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- Load Odoo Breakpoint toolkit
local odoo_breakpoint = require 'assets.odoo_breakpoint'

-- Configure Leader Key (Ctrl + A)
config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1000 }

-- Apply Odoo Breakpoint features & keybindings
odoo_breakpoint.apply_to_config(config)

-- Keybindings overview:
-- Ctrl+A then M -> Open Macro Picker (self.env[''], .search([]), .browse([]), .filtered(), etc.)
-- Ctrl+A then I -> Open PDB Introspection Menu (Model Registry, Recordset Fields, Variables)
-- Ctrl+A then S -> Open Multi-Line Snippet Executor (Base64 atomic execution)
-- Ctrl+A then D -> Open Domain Operator Picker

return config
