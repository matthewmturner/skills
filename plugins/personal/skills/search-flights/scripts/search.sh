#!/usr/bin/env bash
# search.sh - Search Google Flights via Playwright MCP server (pi-mcp-adapter)
#
# Usage: search.sh <from> <to> <departDate> [returnDate] [passengers] [class]
#
# Examples:
#   search.sh SFO LHR 2026-06-15
#   search.sh "New York" London 2026-06-15 2026-06-22 2 economy
#   search.sh JFK CDG 2026-06-15 2026-06-20 1 business
#
# This script prints the mcp() tool calls the agent should execute in order.
# The agent must be running with pi-mcp-adapter and @playwright/mcp configured.

set -euo pipefail

FROM="${1:?Usage: search.sh <from> <to> <departDate> [returnDate] [passengers] [class]}"
TO="${2:?Usage: search.sh <from> <to> <departDate> [returnDate] [passengers] [class]}"
DEPART_DATE="${3:?Usage: search.sh <from> <to> <departDate> [returnDate] [passengers] [class]}"
RETURN_DATE="${4:-}"
PASSENGERS="${5:-1}"
CLASS="${6:-economy}"

# Convert YYYY-MM-DD to "Month DD, YYYY" format for Google calendar aria-labels
format_date() {
    local date="$1"
    local month_num=$(echo "$date" | cut -d'-' -f2)
    local day=$(echo "$date" | cut -d'-' -f3 | sed 's/^0//')
    local year=$(echo "$date" | cut -d'-' -f1)
    local month_name

    case "$month_num" in
        01) month_name="January" ;; 02) month_name="February" ;; 03) month_name="March" ;;
        04) month_name="April" ;; 05) month_name="May" ;; 06) month_name="June" ;;
        07) month_name="July" ;; 08) month_name="August" ;; 09) month_name="September" ;;
        10) month_name="October" ;; 11) month_name="November" ;; 12) month_name="December" ;;
        *) echo "Invalid month: $month_num" >&2; exit 1 ;;
    esac

    echo "${month_name} ${day}, ${year}"
}

DEPART_LABEL=$(format_date "$DEPART_DATE")
RETURN_LABEL=""
if [[ -n "$RETURN_DATE" ]]; then
    RETURN_LABEL=$(format_date "$RETURN_DATE")
fi

echo "============================================="
echo "  Google Flights Search via Playwright MCP"
echo "============================================="
echo ""
echo "From:        $FROM"
echo "To:          $TO"
echo "Depart:      $DEPART_DATE ($DEPART_LABEL)"
[[ -n "$RETURN_LABEL" ]] && echo "Return:      $RETURN_DATE ($RETURN_LABEL)" || echo "Return:      (one-way)"
echo "Passengers:  $PASSENGERS"
echo "Class:       $CLASS"
echo ""
echo "============================================="
echo ""
echo "Execute these mcp() calls in order:"
echo ""

# Step 1: Navigate
echo "# Step 1: Navigate to Google Flights"
echo 'mcp({ tool: "playwright_playwright_navigate", args: '"'"'{"url": "https://www.google.com/travel/flights", "headless": true, "width": 1280, "height": 900}'"'"' })'
echo ""

# Step 2: Wait for page load
echo "# Step 2: Wait for page load"
echo 'mcp({ tool: "playwright_playwright_evaluate", args: '"'"'{"script": "() => new Promise(r => setTimeout(r, 3000))"}'"'"' })'
echo ""

# Step 3: Fill origin
echo "# Step 3: Fill origin ($FROM)"
echo "mcp({ tool: \"playwright_playwright_fill\", args: '{\"selector\": \"input[placeholder=\\\"From\\\"], input[aria-label=\\\"Origin\\\"], td[aria-label=\\\"Origin\\\"] input\", \"value\": \"$FROM\"}' })"
echo 'mcp({ tool: "playwright_playwright_press_key", args: '"'"'{"key": "Enter"}'"'"' })'
echo 'mcp({ tool: "playwright_playwright_evaluate", args: '"'"'{"script": "() => new Promise(r => setTimeout(r, 1000))"}'"'"' })'
echo 'mcp({ tool: "playwright_playwright_click", args: '"'"'{"selector": "div[role=\\"listbox\\"] li:first-child, ul li:first-child"}'"'"' })'
echo ""

# Step 4: Fill destination
echo "# Step 4: Fill destination ($TO)"
echo "mcp({ tool: \"playwright_playwright_fill\", args: '{\"selector\": \"input[placeholder=\\\"To\\\"], input[aria-label=\\\"Destination\\\"], td[aria-label=\\\"Destination\\\"] input\", \"value\": \"$TO\"}' })"
echo 'mcp({ tool: "playwright_playwright_press_key", args: '"'"'{"key": "Enter"}'"'"' })'
echo 'mcp({ tool: "playwright_playwright_evaluate", args: '"'"'{"script": "() => new Promise(r => setTimeout(r, 1000))"}'"'"' })'
echo 'mcp({ tool: "playwright_playwright_click", args: '"'"'{"selector": "div[role=\\"listbox\\"] li:first-child, ul li:first-child"}'"'"' })'
echo ""

# Step 5: Set dates
echo "# Step 5: Set departure date ($DEPART_LABEL)"
echo 'mcp({ tool: "playwright_playwright_click", args: '"'"'{"selector": "td[aria-label=\\"Depart\\"]"}'"'"' })'
echo 'mcp({ tool: "playwright_playwright_evaluate", args: '"'"'{"script": "() => new Promise(r => setTimeout(r, 1500))"}'"'"' })'
echo "mcp({ tool: \"playwright_playwright_click\", args: '{\"selector\": \"button[aria-label=\\\"$DEPART_LABEL\\\"]\"}' })"

if [[ -n "$RETURN_LABEL" ]]; then
    echo ""
    echo "# Step 6: Set return date ($RETURN_LABEL)"
    echo "mcp({ tool: \"playwright_playwright_click\", args: '{\"selector\": \"button[aria-label=\\\"$RETURN_LABEL\\\"]\"}' })"
fi

# Step 7: Passengers/class (if not defaults)
if [[ "$PASSENGERS" != "1" || "$CLASS" != "economy" ]]; then
    echo ""
    echo "# Step 6: Set passengers ($PASSENGERS) and class ($CLASS)"
    echo 'mcp({ tool: "playwright_playwright_click", args: '"'"'{"selector": "button[aria-label=\\"Passengers and Travel Class\\"]"}'"'"' })'
    echo 'mcp({ tool: "playwright_playwright_evaluate", args: '"'"'{"script": "() => new Promise(r => setTimeout(r, 1000))"}'"'"' })'
    echo "# Adjust passengers to $PASSENGERS using +/- buttons, select $CLASS class"
    echo 'mcp({ tool: "playwright_playwright_click", args: '"'"'{"selector": "[aria-label=\\"Close\\"]"}'"'"' })'
fi

echo ""
echo "# Step 7: Click Search"
echo 'mcp({ tool: "playwright_playwright_click", args: '"'"'{"selector": "button[aria-label=\\"Search Flights\\"]"}'"'"' })'
echo 'mcp({ tool: "playwright_playwright_evaluate", args: '"'"'{"script": "() => new Promise(r => setTimeout(r, 5000))"}'"'"' })'
echo ""

echo "# Step 8: Capture results"
echo 'mcp({ tool: "playwright_playwright_screenshot", args: '"'"'{"name": "flights-results", "fullPage": true, "savePng": true}'"'"' })'
echo 'mcp({ tool: "playwright_playwright_get_visible_text", args: '"'"'{"selector": "div[role=\\"main\\"]"}'"'"' })'
echo ""

echo "# Step 9: Close browser"
echo 'mcp({ tool: "playwright_playwright_close", args: '"'"'{}'"'"' })'
echo ""
echo "============================================="
echo "After Step 8, parse the visible text into a table:"
echo ""
echo "| Departure | Arrival | Duration | Stops | Airline | Price |"
echo "|-----------|---------|----------|-------|---------|-------|"
echo "| ...       | ...     | ...      | ...   | ...     | ...   |"
echo "============================================="
