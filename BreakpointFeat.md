# Complete Breakpoint Features & Implementation Specification

This document details every feature implemented in the Breakpoint Panel/Terminal system, along with the exact algorithmic and architectural mechanics used to build them. This specification is designed to guide implementation in custom terminal emulators (such as WezTerm via Lua/Rust plugins).

---

## 1. Dynamic Breakpoint Detection & UX Mechanics

### 1.1 Prompt Pattern Detection & State Switching
- **Goal**: Automatically distinguish between normal process stdout (logs, stack traces) and active PDB interactive prompts.
- **Implementation**:
  - The process output stream (stdout/stderr) is processed by a stream parser.
  - A regex pattern matches the terminal prompt signature: `/^\s*\(Pdb\)\s*/m` or `/\n\(Pdb\)\s*$/`.
  - When the signature is detected at the end of an incoming chunk, the system transitions to **Breakpoint Active State**.
  - Visual indicator (e.g., status pill, distinct input prompt background) signals to the user that execution is paused and PDB is ready for input.

### 1.2 Command History Stack
- **Goal**: Allow users to scroll through previously entered commands using `UpArrow` and `DownArrow`.
- **Implementation**:
  - Maintains an array of string commands: `historyStack = []`.
  - Maintains a pointer: `historyIndex = -1`.
  - On `Enter`:
    - If input is non-empty and different from `historyStack[historyStack.length - 1]`, push to `historyStack`.
    - Reset `historyIndex` to `-1`.
  - On `UpArrow`:
    - Increment index backwards from end: `historyIndex = min(historyIndex + 1, historyStack.length - 1)`.
    - Replace input text buffer with `historyStack[historyStack.length - 1 - historyIndex]`.
  - On `DownArrow`:
    - Decrement index: `historyIndex = max(historyIndex - 1, -1)`.
    - If `historyIndex === -1`, clear or restore original un-submitted draft text; otherwise display target history item.

### 1.3 Auto-Scroll Lock Engine
- **Goal**: Ensure the log output automatically pins to the bottom on new output unless the user has manually scrolled up to inspect past logs.
- **Implementation**:
  - Tracks scroll position: `isAtBottom = (scrollHeight - scrollTop - clientHeight) < threshold (e.g., 50px)`.
  - On user scroll: updates `isAtBottom` state.
  - On new stdout chunk or command execution: if `isAtBottom` is true, programmatically scroll container to `scrollTop = scrollHeight`.

---

## 2. Silent Background Introspection Mechanism

### 2.1 The Problem
Standard PDB prints whatever is written to `stdin` directly into visible stdout logs. If the UI sends autocomplete queries like `dir(self)` to PDB, it would clutter the terminal with invisible query code and output garbage.

### 2.2 The Solution: Marker Injection & Stream Stripping
- **Implementation**:
  1. Define unique sentinel boundaries, for example: `___IDE___MODEL___` and `___IDE___ATTR___`.
  2. When an autocomplete trigger fires, construct a silent PDB payload prefixed with Python `!` (which forces PDB to execute statement without evaluation printing) and wrapped with print markers:
     ```python
     !import json; print("___IDE___MODEL___" + json.dumps(list(self.env.registry.keys())) + "___IDE___MODEL___")
     ```
  3. Send payload directly to standard input (`stdin`).
  4. Intercept incoming stdout chunks before rendering to UI logs:
     - Check if chunk contains `___IDE___MODEL___<DATA>___IDE___MODEL___`.
     - Extract `<DATA>`, parse JSON payload asynchronously.
     - **Strip the entire matched string (and surrounding prompt remnants)** from the chunk so it is never displayed in the terminal UI log stream.
     - Pass clean remaining text (if any) to log renderer.

### 2.3 Timeout & Fallback Guard
- If standard PDB is busy evaluating a heavy user command, background introspection requests might hang.
- A timer (e.g., 600ms) cancels pending autocomplete promises and suppresses dropdown rendering to keep typing smooth and un-blocked.

---

## 3. Context-Aware Autocomplete Rules & Triggers

### 3.1 Model Registry Autocomplete (`self.env['...']`)
- **Trigger Condition**: Cursor positioned right after `self.env[` or inside `self.env['...']`.
- **Regex Match**: `/\bself\.env\[(['"]?)([\w.]*)$/`
- **Query Executed**:
  ```python
  !import json; print("___IDE___MODEL___" + json.dumps(list(self.env.registry.keys())) + "___IDE___MODEL___")
  ```
- **Parsing & Filtering**:
  - Filter returned model string list against user prefix (e.g., typing `acc` filters `account.move`, `account.journal`, `account.tax`).
  - Cache result locally per breakpoint session so subsequent keystrokes don't re-query PDB unnecessarily.

### 3.2 Model Field Autocomplete (`self.env['model.name']....`)
- **Trigger Condition**: Typing `.` after a model string accessor `self.env['account.move'].`.
- **Regex Match**: `/\bself\.env\[['"]([\w.]+)['"]\]\.([\w_]*)$/`
- **Query Executed**:
  ```python
  !import json; print("___IDE___ATTR___" + json.dumps(list(self.env['<model_name>']._fields.keys())) + "___IDE___ATTR___")
  ```
- **Result**: Displays all schema field names (`name`, `state`, `line_ids`, `amount_total`, etc.).

### 3.3 Variable Attribute / Recordset Autocomplete (`<object>.`)
- **Trigger Condition**: Typing `.` after any Python identifier (e.g., `record.`, `partner.`, `user.`).
- **Regex Match**: `/(\b[\w_]+)\.([\w_]*)$/`
- **Query Executed**:
  ```python
  !import json; print("___IDE___ATTR___" + json.dumps(list(getattr(<var>, '_fields', {}).keys()) or [a for a in dir(<var>) if not a.startswith('_')]) + "___IDE___ATTR___")
  ```
- **Logic**: Intelligently tries Odoo `_fields` first (for recordsets). If empty, falls back to Python standard `dir()` attributes while filtering out private methods starting with `_`.

### 3.4 Domain Operator & Value Autocomplete
- **Trigger Condition**: Inside Odoo domain tuples `[('field_name', '...')]`.
- **Suggestions Provided**:
  - Field names when at tuple index 0.
  - Operators (`=`, `!=`, `in`, `not in`, `ilike`, `>=`, `<=`, `like`) when at tuple index 1.
  - Booleans (`True`, `False`) or common values at tuple index 2.

---

## 4. Smart Macro Expansions & Cursor Placement Math

### 4.1 Completion Item Data Structure
Each completion candidate contains:
- `label`: Display text in menu (e.g., `self.env`).
- `insertText`: String inserted into input buffer (e.g., `self.env['']`).
- `cursorOffset`: Relative offset integer applied to cursor position after replacement (e.g., `-2`).
- `type`: Category (`macro`, `model`, `field`, `method`).

### 4.2 Replacement & Cursor Shift Calculation
When a macro candidate is accepted:
1. Identify replacement range `[startPos, endPos]` based on the active trigger word boundary.
2. Spliced String: `newText = currentText[0..startPos] + candidate.insertText + currentText[endPos..len]`.
3. Target Cursor Index: `newCursorPos = startPos + len(candidate.insertText) + candidate.cursorOffset`.
4. Apply `newText` to input buffer and programmatically set input element cursor selection to `(newCursorPos, newCursorPos)`.

### 4.3 Key Macro Specifications

| Keyword Trigger | Expanded `insertText` | `cursorOffset` | Final Cursor Position |
|---|---|---|---|
| `self.env` | `self.env['']` | `-2` | Inside quotes: `self.env['|']` |
| `search(` | `search([])` | `-2` | Inside brackets: `search([|])` |
| `browse(` | `browse([])` | `-2` | Inside brackets: `browse([|])` |
| `filtered(` | `filtered(lambda r: r.)` | `0` | After dot: `filtered(lambda r: r.|)` |

---

## 5. Multi-Line Atomic Execution Engine (Snippet Mode)

### 5.1 The Problem
Standard Python PDB reads commands line-by-line. If a user pastes or types a multi-line block (such as a `for` loop, `if/else`, or `try/except`), PDB processes line 1, sees incomplete syntax, and throws immediate errors (`SyntaxError: '(' was never closed`, `unmatched ']'`, or `NameError`).

### 5.2 The Solution: Base64 Payload Wrapper
- **Implementation**:
  1. Open a multi-line text editing area (Snippet Modal).
  2. Allow full multi-line typing with `Tab` key mapping to 4 spaces (`"    "`).
  3. On "Execute" click:
     - Take the raw multi-line code string `rawCode`.
     - Encode `rawCode` into a Base64 string payload:
       `b64Payload = base64_encode(utf8_bytes(rawCode))`
     - Construct a single-line PDB command:
       ```python
       !import base64; exec(compile(base64.b64decode("b64Payload").decode("utf-8"), "<snippet>", "single"))
       ```
  4. Send this command to PDB `stdin`.
  5. **Result**: PDB compiles and executes the payload as an atomic single code block within the active breakpoint context. Multi-line loops, variable assignments, and complex ORM queries execute cleanly without syntax fragmentation.

---

## 6. Live Log Data Structure Syntax Highlighting

### 6.1 Pattern Detection
- PDB stdout dumps large dictionaries, lists, and tuples as raw unformatted text (e.g. output from `read()` or `search_read()`).
- The log line parser inspects output strings using regex matching signatures of JSON/Python data structures:
  - Pattern: `/^\s*(\{|\[|\().*(\}|\]|\))\s*$/` or dictionary key-value pair pattern `/'[\w_]+':\s*/`.

### 6.2 Tokenization Rules & Color Palette
Matching lines are passed through a lightweight syntax colorizer that tokenizes tokens into HTML/terminal ANSI escape sequences:

- **Keys** (`'name':`, `"amount":`): Colored **Vibrant Blue** (`#61afef`).
- **Strings** (`'draft'`, `"account.move"`): Colored **Emerald Green** (`#98c379`).
- **Numbers / Floats** (`125.50`, `42`): Colored **Dark Orange** (`#d19a66`).
- **Booleans / Nulls** (`True`, `False`, `None`): Colored **Purple / Magenta** (`#c678dd`).
- **Punctuation / Brackets** (`{`, `}`, `[`, `]`, `,`): Colored **Muted Gray** (`#abb2bf`).

---

## 7. UI State Synchronization & Reliability

### 7.1 Shared Autocomplete State
- Autocomplete logic, registry caches, and trigger rules are unified into a single engine shared between:
  - Standard single-line terminal prompt input.
  - Multi-line Snippet Modal editor.
- Shared toggle state (`enabled` vs `disabled`) persisted in storage (`localStorage` / config file).

### 7.2 Safety & Error Boundaries
- **Temporal Dead Zone Prevention**: Ensure suggestion updater references position state via mutable references (`ref` / pointers) so async callback returns don't attempt to render onto unmounted or outdated elements.
- **Quote Cleanup Logic**: When accepting model completions like `'account.move'`, regex cleans up trailing duplicate quotes (e.g., preventing `self.env['account.move']']`).

---

## Summary Checklist for Terminal Emulator Porting (e.g., WezTerm Lua/Rust)

1. **PTY stdout filter**: Intercept stream for prompt detection `(Pdb)` and marker extraction `___IDE___...___IDE___`.
2. **PTY stdin sender**: Prefix silent background requests with `!`.
3. **Completion popup**: Bind trigger key combinations (`Tab`, `Ctrl+Space`, or typing `.`, `[`).
4. **Text splice & cursor offset**: Support relative cursor displacement post-completion.
5. **Base64 execution helper**: Convert multiline buffer into `!import base64; exec(...)` payload before sending to child process stdin.
6. **Log colorizer plugin**: Apply regex regex string highlight matching to output lines.
