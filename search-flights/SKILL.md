---
name: search-flights
description: Search Google Flights for airfares using browser automation via the Playwright MCP server (pi-mcp-adapter). Accepts origin, destination, and date range, then returns results formatted as a markdown table. Use when the user asks to search for flights, compare airfares, or find cheap flights.
---

# Search Flights

Search Google Flights using headless browser automation through the Playwright MCP server, accessed via the pi-mcp-adapter `mcp()` tool.

## Prerequisites

### 1. Configure the MCP Server

Add the official Playwright MCP server to your MCP config. Use one of these files:

- **User-global:** `~/.config/mcp/mcp.json` (shared across tools)
- **Pi global:** `~/.pi/agent/mcp.json` (Pi-specific)
- **Project-local:** `.mcp.json` (project-specific)

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest"]
    }
  }
}
```

The default `lifecycle: "lazy"` means the server starts on first tool call and idles after 10 minutes.

### 2. Install Playwright Browsers

The MCP server needs browser binaries. Install Chromium (default):

```bash
npx playwright install chromium
```

System dependencies may be required on Linux:

```bash
npx playwright install-deps chromium
```

## Core Concepts

### Tool Naming

All Playwright MCP tools use the `playwright_browser_*` prefix:

| Old Name (wrong) | Correct Name |
|---|---|
| `playwright_playwright_navigate` | `playwright_browser_navigate` |
| `playwright_playwright_click` | `playwright_browser_click` |
| `playwright_playwright_fill` | `playwright_browser_type` |
| `playwright_playwright_press_key` | `playwright_browser_press_key` |
| `playwright_playwright_evaluate` | `playwright_browser_evaluate` |
| `playwright_playwright_screenshot` | `playwright_browser_take_screenshot` |
| `playwright_playwright_get_visible_text` | `playwright_browser_snapshot` |
| `playwright_playwright_close` | `playwright_browser_close` |

### The Snapshot-Ref Workflow (Critical)

The Playwright MCP does **not** use CSS selectors. Instead it uses an **accessibility snapshot** with **element refs**:

1. **Always take a snapshot first**: `mcp({ tool: "playwright_browser_snapshot", args: '{}' })`
2. **Read the snapshot** — every interactive element has a `ref=eXXX` identifier (e.g., `ref=e92`)
3. **Use that ref number as the `target`** in subsequent actions (e.g., `target: "e92"`)
4. **After every interaction, take a new snapshot** — refs are reassigned on every page change

### Key Tool Signatures

**Navigate:**
```
mcp({ tool: "playwright_browser_navigate", args: '{"url": "https://www.google.com/travel/flights"}' })
```

**Click (uses snapshot refs, NOT CSS selectors):**
```
mcp({ tool: "playwright_browser_click", args: '{"element": "human-readable description", "target": "e123"}' })
```

**Type text (use `slowly: true` for autocomplete fields):**
```
mcp({ tool: "playwright_browser_type", args: '{"element": "description", "target": "e123", "text": "Rome", "slowly": true}' })
```

**Press a key:**
```
mcp({ tool: "playwright_browser_press_key", args: '{"key": "Enter"}' })
```

**Take a screenshot:**
```
mcp({ tool: "playwright_browser_take_screenshot", args: '{"name": "results", "fullPage": true, "savePng": true}' })
```

**Close browser:**
```
mcp({ tool: "playwright_browser_close", args: '{}' })
```

**Evaluate JS (requires `function` param, NOT `script`):**
```
mcp({ tool: "playwright_browser_evaluate", args: '{"function": "() => document.title"}' })
```

## Usage

Call via the `/skill:search-flights` command, or load this skill and follow the steps below.

### Input Parameters

| Parameter | Required | Example | Description |
|-----------|----------|---------|-------------|
| `from` | Yes | `SFO`, `Newark`, `LHR` | Airport code or city name |
| `to` | Yes | `JFK`, `Rome`, `CDG` | Airport code or city name |
| `departDate` | Yes | `2026-06-15` | Departure date (YYYY-MM-DD) |
| `returnDate` | No | `2026-06-22` | Return date (YYYY-MM-DD). Omit for one-way |
| `passengers` | No | `2` | Number of passengers (default: 1) |
| `class` | No | `economy`, `premium`, `business`, `first` | Cabin class (default: economy) |

### Step-by-Step Procedure

#### Step 1: Navigate to Google Flights

```
mcp({ tool: "playwright_browser_navigate", args: '{"url": "https://www.google.com/travel/flights"}' })
```

Wait for the page to load, then take a snapshot:

```
mcp({ tool: "playwright_browser_snapshot", args: '{}' })
```

#### Step 2: Fill in Origin (From)

1. **Snapshot** the page to find the origin combobox ref. Look for `combobox` with name containing "Where from?" or the default city.
2. **Click** the origin combobox — this opens a dialog with airport options:

```
mcp({ tool: "playwright_browser_click", args: '{"element": "Where from? origin combobox", "target": "eXXX"}' })
```

3. **Snapshot** again — the dialog now shows a search combobox and listbox of suggestions.
4. **Type** the city/airport into the search combobox (use `slowly: true`):

```
mcp({ tool: "playwright_browser_type", args: '{"element": "origin search combobox", "target": "eXXX", "text": "Newark", "slowly": true}' })
```

5. **Snapshot** again — the listbox now shows filtered results.
6. **Click** the correct airport option (look for the `option` element with the airport name):

```
mcp({ tool: "playwright_browser_click", args: '{"element": "Newark Liberty International Airport EWR option", "target": "eXXX"}' })
```

#### Step 3: Fill in Destination (To)

1. **Snapshot** the page to find the destination combobox ref. Look for `combobox` with name "Where to?".
2. **Click** the destination combobox:

```
mcp({ tool: "playwright_browser_click", args: '{"element": "Where to? destination combobox", "target": "eXXX"}' })
```

3. **Snapshot** again — dialog opens with a search combobox.
4. **Type** the destination (use `slowly: true`):

```
mcp({ tool: "playwright_browser_type", args: '{"element": "destination search combobox", "target": "eXXX", "text": "Rome", "slowly": true}' })
```

5. **Snapshot** again — filtered results appear in the listbox.
6. **Click** the correct option (e.g., "Rome, Italy"):

```
mcp({ tool: "playwright_browser_click", args: '{"element": "Rome, Italy destination option", "target": "eXXX"}' })
```

#### Step 4: Set Departure Date

1. **Snapshot** to find the departure textbox. Look for `textbox` with placeholder "Departure".
2. **Click** it to open the calendar dialog:

```
mcp({ tool: "playwright_browser_click", args: '{"element": "Departure date textbox", "target": "eXXX"}' })
```

3. **Snapshot** again — the calendar dialog shows multiple months as `rowgroup` sections.
4. **Find** the target month section, then locate the specific date button. Date buttons are labeled with full names like `"Wednesday, July 15, 2026"`.
5. **Click** the date button:

```
mcp({ tool: "playwright_browser_click", args: '{"element": "Wednesday, July 15, 2026", "target": "eXXX"}' })
```

**Date label format:** Convert `YYYY-MM-DD` to calendar button labels:

| Input | Button label |
|-------|-------------|
| `2026-06-15` | "Monday, June 15, 2026" |
| `2026-01-01` | "Thursday, January 1, 2026" |

Month names: January, February, March, April, May, June, July, August, September, October, November, December.

#### Step 5: Set Return Date (Round-trip only)

If a return date was provided, the calendar is still open. **Snapshot** to find the return date button, then click it:

```
mcp({ tool: "playwright_browser_click", args: '{"element": "Monday, June 22, 2026", "target": "eXXX"}' })
```

After selecting, click the "Done" button (look for button with text "Done") to close the calendar, or click outside the dialog.

#### Step 6: Set Passengers and Class (Optional)

1. **Snapshot** to find the passenger button (shows "1 passenger") and class combobox (shows "Economy").
2. Click, adjust, and close as needed using snapshot refs.

#### Step 7: Click Search

1. **Snapshot** to find the search button (labeled "Search").
2. **Click** it:

```
mcp({ tool: "playwright_browser_click", args: '{"element": "Search flights button", "target": "eXXX"}' })
```

3. Wait for results to load (3-8 seconds). You can use evaluate for a delay:

```
mcp({ tool: "playwright_browser_evaluate", args: '{"function": "() => new Promise(r => setTimeout(r, 5000))"}' })
```

#### Step 8: Capture Results

1. **Snapshot** the results page — this gives you the full accessibility tree of flight results:

```
mcp({ tool: "playwright_browser_snapshot", args: '{}' })
```

2. Optionally take a screenshot for visual debugging:

```
mcp({ tool: "playwright_browser_take_screenshot", args: '{"name": "flights-results", "fullPage": true, "savePng": true}' })
```

3. Parse the snapshot output — flight results appear as structured elements with times, airlines, durations, stops, and prices.

#### Step 9: Parse and Format Results

Parse the snapshot into a structured markdown table. Google Flights results typically include:

- Departure/arrival times
- Duration (including layovers)
- Airline name
- Price
- Number of stops

Format as:

```markdown
| Departure | Arrival | Duration | Stops | Airline | Price |
|-----------|---------|----------|-------|---------|-------|
| 08:30     | 17:45   | 11h 15m  | Nonstop | United | $452 |
| 14:20     | 23:55   | 11h 35m  | 1 stop  | Delta  | $389 |
```

#### Step 10: Close Browser

```
mcp({ tool: "playwright_browser_close", args: '{}' })
```

## Handling Edge Cases

### Google Paywall / Captcha

If Google blocks automated access:
1. Retry without headless mode (the browser defaults to visible)
2. If a captcha appears, take a screenshot and ask the user to solve it
3. Consider adding longer delays between interactions

### Date Not Visible in Calendar

The calendar shows multiple months at once. If the target month isn't visible:
1. **Snapshot** the calendar dialog
2. Look for a "Next" button at the bottom of the calendar
3. Click it to advance months, then snapshot again

### Refs Not Found After Interaction

If you get "Ref eXXX not found" errors:
- You need a fresh snapshot — refs change after every navigation or DOM update
- Always snapshot before clicking/typing

### Origin Already Set to Wrong City

If the default origin isn't what you need:
1. Click the origin combobox (opens dialog)
2. The search combobox in the dialog will show the current text
3. Type your desired city (it replaces the existing text)
4. Select the correct option from the filtered listbox

### Multiple Result Pages

Google Flights shows ~10-15 flights per page. If more results are needed:
1. Scroll down: `mcp({ tool: "playwright_browser_evaluate", args: '{"function": "() => window.scrollBy(0, document.body.scrollHeight)"}' })`
2. Wait briefly, then snapshot again for new results

## Example Session

**User:** Find flights from Newark to Rome July 15-22, 2026

**Agent workflow:**

1. Load this skill (`read` the SKILL.md)
2. Navigate to Google Flights + snapshot
3. Click origin combobox → snapshot → type "Newark" → snapshot → click EWR option
4. Click destination combobox → snapshot → type "Rome" → snapshot → click "Rome, Italy" option
5. Click departure textbox → snapshot → find July in calendar → click "Wednesday, July 15, 2026"
6. Click "Wednesday, July 22, 2026" for return
7. Click "Done" button to close calendar
8. Snapshot → click "Search" button
9. Wait for results (evaluate delay)
10. Snapshot results → parse into table → present to user
11. Close browser

**Key pattern: snapshot → find ref → act → snapshot → repeat.**
