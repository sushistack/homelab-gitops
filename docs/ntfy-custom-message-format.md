# Message Rendering Format — Structured Cards

> **Status:** canonical contract. Web implements this in `src/components/message/StructuredCard.jsx`
> + `CardBody.jsx`. **Android must parse and render identically** so the same ntfy message
> looks the same on both platforms.

ntfy's wire format has **no structured-data field** — the message body is always a plain text
string. To render rich content (key-value tables, charts, mixed sections) we **smuggle JSON
inside the body** and flag it with a reserved **tag**. The client parses the body and renders
real components. Anything that isn't a valid flagged payload falls back to markdown/plain text.

This document is the single source of truth for that protocol.

---

## 1. How a message becomes a structured card

A notification is rendered as a **structured card** if and only if **both**:

1. its `tags` array contains the literal marker tag **`card`**, **and**
2. its `message` body parses as JSON to an object whose `type` is one of:
   `kv` · `list` · `chart` · `sections`.

If the tag is present but the body is not valid JSON, or `type` is missing/unknown →
**fall back** to the normal text path (see §6). The marker tag `card` is **never displayed**
as a tag chip (it is filtered out of the tag row).

### Sender side (HTTP publish)

```bash
# Tag marks it; body is the JSON spec. Title/priority via headers as usual.
curl -H "Tags: card" \
     -H "Title: build #482" \
     -H "Priority: 5" \
     -d '{"type":"kv","rows":[{"key":"Branch","value":"main"}]}' \
     https://${SECRET:DOMAIN_NTFY_WEB}/test
```

The marker may be combined with other tags: `X-Tags: card,service:github,deploy`.
Order does not matter. (`service:` and general tags still render in the tag row — see
[components.md → CardTags](components.md).)

### Parser (pseudocode — implement on Android verbatim)

```
fun parseCardSpec(notification): CardSpec? {
    val tags = notification.tags ?: emptyList()
    if (!tags.contains("card")) return null
    val spec = runCatching { Json.parseToJsonElement(notification.message).jsonObject }
                  .getOrNull() ?: return null
    val type = spec["type"]?.jsonPrimitive?.contentOrNull ?: return null
    if (type !in setOf("kv","list","chart","sections")) return null
    return spec
}
```

---

## 2. Block types

A spec is either a **single block** (`type` = `kv`/`list`/`chart`) or a **`sections`**
wrapper holding an ordered list of blocks. The four block types:

### 2.1 `kv` — key-value table (the "monitor" card)

```json
{
  "type": "kv",
  "columns": 2,
  "rows": [
    { "key": "CPU",     "value": "4.86%", "meter": 4.86 },
    { "key": "Memory",  "value": "30.9%", "status": "warn", "meter": 30.9 },
    { "key": "Disk",    "value": "95%",   "status": "error", "meter": 95 },
    { "key": "Load",    "value": "0.11 0.12 0.18", "status": "ok" },
    { "key": "Agent",   "value": "0.18.7", "icon": "agent" }
  ]
}
```

**Row fields:**

| field    | type    | meaning |
|----------|---------|---------|
| `key`    | string  | left label (muted). |
| `value`  | string  | right value. Rendered as text. |
| `status` | string? | `ok` \| `warn` \| `error`. Drives the status dot / value color (see below). |
| `meter`  | number? | 0–100. If a finite number, an **inline meter bar** is drawn to the right of the value. |
| `icon`   | string? | overrides the leading icon lookup (else derived from `key`). |

**Row rendering (left → right):** `[leading icon] [key (muted)] [value] [meter bar?]`

- **Leading icon:** monospace glyph. Look up `icon ?? key` (lowercased) in the icon map (§4);
  if no exact hit, try the first word; else `·`.
- **Value color:** default = primary text. `status:"error"` → **coral** (`priority_urgent`).
  (`ok`/`warn` do **not** recolor the value.)
- **Status dot:** when `status` is set **and there is no meter**, a small filled dot precedes
  the value — `ok`→`accent_ui` (emerald), `warn`→`priority_high` (amber), `error`→`priority_max` (coral).
- **Meter bar:** present only when `meter` is a finite number. Fills the remaining row width.
  Threshold colors: `<65` emerald (`meter_ok`), `≥65` amber (`meter_warning`), `≥90` coral
  (`meter_critical`). Value is clamped to 0–100. (Same component as the standalone Meter.)

**`columns` (optional, default 1):**
- `1` (or absent) → single column, each row full width (meter bar spans the row).
- `2` → **two columns on tablet/desktop width (≥ sm / 640px), one column on mobile.** Each
  row (including meter rows) lives inside its grid cell — the meter bar is **half width**, not
  full-width spanning. Mobile always collapses to 1 column regardless of `columns`.

> Android: `columns:2` → use a 2-column grid only when the available width ≥ ~600dp; otherwise 1.

### 2.2 `list` — bullet / numbered list

```json
{ "type": "list", "ordered": false, "items": ["배포 시작", "이미지 빌드", "테스트 통과"] }
```

- `ordered:true` → numbered (`1.`), else bulleted (`•`).
- All items render (no truncation). `items` are coerced to strings.
- Style: `body_sm`, muted text.

### 2.3 `chart` — dependency-free chart

```json
{
  "type": "chart",
  "kind": "bar",
  "unit": "%",
  "data": [ { "label": "Mon", "value": 12 }, { "label": "Tue", "value": 34 } ]
}
```

| field   | type   | meaning |
|---------|--------|---------|
| `kind`  | string | `bar` (default) or `line`. |
| `unit`  | string? | appended to axis labels when a point has no `label`. |
| `data`  | array  | `{label, value}`. `value` coerced to number; non-finite points are **dropped**. Capped at **60 points**. |

**Rendering:**
- Single accent-colored chart, fixed height **120 (dp/px)**, full available width.
- `bar`: vertical bars (emerald fill). `line`: emerald polyline (2px stroke, crisp).
- Y-axis auto-scales to `[min(0,…), max]`.
- **Axis labels** (a row of small muted text under the chart) are shown **only when ≤ 12 points**;
  otherwise omitted to avoid crowding. Each label = `label` or `value+unit`.
- Empty/all-invalid data → render nothing.

> Web draws this as an SVG (`<rect>` bars / `<polyline>`). Android: Canvas / Compose `Canvas`.
> Color = `accent_text`/`accent_ui` emerald. There is **no external chart library** — keep it
> a thin hand-drawn chart to stay in parity and avoid heavy deps.

### 2.4 `sections` — mixed, ordered blocks

```json
{
  "type": "sections",
  "blocks": [
    { "type": "markdown", "text": "## 배포 완료 ✅\n**prod** v1.4.2 롤아웃 성공." },
    { "type": "kv", "rows": [ { "key": "CPU", "value": "23%", "meter": 23 } ] },
    { "type": "list", "items": ["A", "B"] },
    { "type": "chart", "kind": "line", "data": [ {"label":"1m","value":120} ] }
  ]
}
```

- Renders every block **in order**, vertically, with a gap (`spacing-3` / 12 between blocks).
- A block may be `markdown` | `kv` | `list` | `chart`. A **`markdown` block** is only valid
  inside `sections` (there is no top-level `markdown` type — top-level free text just goes in
  the body untagged; see §6).
- **Nested `sections` are ignored** (no recursion).
- Unknown block `type` → that block renders nothing (skipped), siblings still render.

`markdown` block: `{ "type": "markdown", "text": "<markdown string>" }` — rendered with the
full markdown renderer (§5).

---

## 3. Worked examples

**Beszel-style monitor (single kv, meters + status dot):**
```json
{"type":"kv","rows":[
 {"key":"CPU","value":"4.86%","meter":4.86},
 {"key":"Memory","value":"30.9%","meter":30.9},
 {"key":"Disk","value":"17.1%","meter":17.1},
 {"key":"Load Avg","value":"0.11 0.12 0.18","status":"ok"},
 {"key":"Net","value":"574.7 KB/s"},
 {"key":"Uptime","value":"22 hours"},
 {"key":"Agent","value":"0.18.7","status":"ok","icon":"agent"}]}
```

**CI failure report (mixed sections — markdown + kv + list + chart):**
```json
{"type":"sections","blocks":[
 {"type":"markdown","text":"## 빌드 실패 ❌\n`main` nightly 파이프라인이 **test** 단계에서 중단."},
 {"type":"kv","columns":2,"rows":[
   {"key":"Branch","value":"main"},
   {"key":"Stage","value":"test","status":"error"},
   {"key":"Coverage","value":"81%","meter":81},
   {"key":"Failed","value":"3 tests","status":"error"}]},
 {"type":"list","items":["auth/login — timeout","api/orders — 500","ui/cart — flaky"]},
 {"type":"chart","kind":"bar","data":[
   {"label":"lint","value":12},{"label":"build","value":48},
   {"label":"test","value":252},{"label":"deploy","value":0}]}]}
```

---

## 4. Key → icon map (kv leading icons)

Lowercase the lookup key (`icon` field if present, else `key`). Exact match first, then the
**first whitespace-delimited word**, then fallback `·`.

| keys | glyph |  | keys | glyph |
|------|-------|--|------|-------|
| `cpu` | ⚙ | | `version` | # |
| `disk` | 💾 | | `exit` | ⏎ |
| `memory` `mem` `ram` | 🧠 | | `net` `network` | ⇅ |
| `load` | 📈 | | `services` `service` | ❏ |
| `uptime` | ⏱ | | `agent` | ▶ |
| `status` `name` | ● | | `host` | 🖥 |
| `error` | ✕ | | `ping` | ◎ |
| `warning` | ⚠ | | `speed` | ▶ |
| `temp` `temperature` | 🌡 | | _(fallback)_ | · |

> Example: `"Load Avg"` → no exact `load avg`, first word `load` → 📈.

---

## 5. Markdown rendering rules

Used by: `markdown` blocks, and the untagged "paragraph" fallback (§6). The web renderer
(`MarkdownContent.jsx`, via `react-remark`) maps elements to these styles — Android's markdown
renderer must match the intent:

- **Paragraph** `p`: `body_sm`, muted.
- **Links** `a`: only `http://` `https://` `mailto:` are linkified (accent, underline, open in
  new tab); any other scheme renders as inert accent-colored text (**security: no `javascript:`/data URLs**).
- **Images** `img`: only safe-scheme `src` rendered; else dropped. `max-width:100%`, rounded.
- **Inline code** `code`: mono, `surface_2` background, rounded.
- **Code block** `pre`: mono, `surface_2` bg, padded, horizontal scroll.
- **Bold** `strong`: semibold, primary text. **Italic** `em`: italic, muted.
- **Lists** `ul`/`ol`: disc/decimal, inside, muted, `body_sm`.
- **Blockquote**: left border (`border`), padded, muted.
- **Headings** `h1`=`subtitle` semibold, `h2` semibold, `h3` medium. (No huge display sizes inside cards.)

Render must be **fault-tolerant**: a malformed payload must never crash the card — fall back to
raw text (web wraps the body in an error boundary; Android should `try/catch` and show the raw
message string).

---

## 6. Fallback path (no `card` tag, or invalid payload)

When `parseCardSpec` returns null, the body is rendered by shape detection (`CardBody.detectShape`):

1. **Empty / single non-empty line** → **paragraph** (markdown).
2. **Every non-empty line matches `^[^:]+:\s*.*$`** (i.e. all lines are `key: value`) →
   **heuristic kv**. This reuses the exact same kv renderer as §2.1:
   - value parsed for a trailing percent/number → becomes a `meter` (inline bar).
   - key matching `/error|fail|err/i` → `status:"error"` (coral value).
3. **Otherwise** → **paragraph** (markdown).

So a plain `CPU: 78%\nMemory: 45%` message (no `card` tag) still renders as a kv table.
This heuristic is intentionally loose; the explicit `card`-tagged JSON envelope is the
recommended, unambiguous path.

> **Parity note:** the heuristic is a convenience. If Android wants to ship the explicit
> path only first, that's acceptable — but the **`card`-tagged JSON path is mandatory** for parity.

---

## 7. Card vs. detail — there is no detail

The web app has **no separate detail view** (the detail pane and `/:topic/:msgId` detail route
were removed). **The card renders the full content** — every kv row, all list items, full-height
charts, all section blocks. There is no "compact preview" and no "show more" affordance.
Tapping a card only **marks it read**. Android must do the same: the feed card is the complete,
final presentation of the message.

See [screens-layout.md](screens-layout.md) for the surrounding navigation model.
