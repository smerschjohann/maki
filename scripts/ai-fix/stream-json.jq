# Human-readable rendering of `maki --output-format stream-json` (one event
# per line, Claude Code wire shape). Unknown events and unparsable lines are
# printed instead of being dropped: the CI log is the only trace of a run,
# and a rendering bug must never take the pipeline down with it.
#
# Tool calls and their results arrive in separate events, all calls of a turn
# before any result, so the pending ids are tracked to label a result with the
# tool it answers.

def trunc($n): if length > $n then .[:$n] + "…" else . end;

def clamp_lines($n):
  split("\n") as $lines
  | if ($lines | length) > $n
    then ($lines[:$n] | join("\n")) + "\n⋮ \(($lines | length) - $n) more lines"
    else ($lines | join("\n"))
    end;

def clamp($n; $chars):
  clamp_lines($n) | if length > $chars then .[:$chars] + "\n⋮ truncated" else . end;

def indent($pad):
  split("\n") | map(if . == "" then . else $pad + . end) | join("\n");

def block($mark; $text; $lines; $chars; $pad):
  if ($text // "") == "" then ""
  else "\($mark)\n\($text | clamp($lines; $chars) | indent($pad))"
  end;

def items($value): if ($value | type) == "array" then $value[] else empty end;

def render_input($skip):
  if type != "object" then "    " + (tojson | trunc(200))
  else
    [ to_entries[]
      | select(.key != $skip)
      | .key as $key | .value as $value
      | if ($value | type) == "string" then
          if ($value | contains("\n"))
          then "    \($key):\n\($value | trunc(4000) | indent("      "))"
          else "    \($key): \($value | trunc(200))"
          end
        else "    \($key): \($value | tojson | trunc(200))"
        end
    ] | join("\n")
  end;

def tool_use($block):
  ($block.input // {}) as $input
  | ($input.description // "") as $hint
  | [ "▷ \($block.name // "?")\(if $hint == "" then "" else " — \($hint)" end)",
      ($input | render_input("description"))
    ] | map(select(. != "")) | join("\n");

def tool_result($block; $tool):
  ($block.content // "") as $content
  | ($content | if type == "array"
      then map(if type == "string" then . elif .type == "text" then .text else "[\(.type // "block")]" end) | join("\n")
      else tostring end) as $text
  | block("    ↳ \($tool) \(if $block.is_error then "error" else "ok" end)"; $text; 60; 6000; "        ");

def assistant:
  [ items((.message.content)?)
    | if .type == "text" then block("assistant"; .text; 200; 8000; "    ")
      elif .type == "thinking" then block("thinking"; .thinking; 30; 2000; "    ")
      elif .type == "redacted_thinking" then "thinking (redacted)"
      elif .type == "tool_use" then tool_use(.)
      else "▷ \(.type // "block"): \(tojson | trunc(300))"
      end
  ] | map(select(. != "")) | join("\n\n");

def user($pending):
  [ items((.message.content)?)
    | if .type == "tool_result" then tool_result(.; $pending[.tool_use_id] // "tool")
      elif .type == "text" then block("user"; .text; 100; 4000; "    ")
      else "↳ \(.type // "block"): \(tojson | trunc(300))"
      end
  ] | map(select(. != "")) | join("\n\n");

def system:
  if .subtype == "init" then
    "── maki \(.model // "?") · session \(.session_id // "?")\n"
    + "   cwd:   \(.cwd // "?")\n"
    + "   tools: \((.tools // []) | join(" ") | trunc(300))"
  elif .subtype == "notice" then "! \(.text // "")"
  elif .subtype == "api_retry" then
    "! retry \(.attempt // "?") in \(.retry_delay_ms // "?")ms: \(.error // "" | trunc(300))"
  else "! \(.subtype // "system"): \(del(.type, .subtype) | tojson | trunc(500))"
  end;

def result:
  "══ \(if .is_error then "error" else "done" end): \(.subtype // "?")"
  + " · \(.num_turns // "?") turns"
  + " · \((.duration_ms // 0) / 1000 | floor)s"
  + " · $\(.total_cost_usd // 0)"
  + (if .is_error and (.result // "") != ""
     then "\n\(.result | clamp(40; 4000) | indent("   "))"
     else "" end);

def parse:
  (if endswith("\r") then .[:-1] else . end) as $line
  | try ($line | fromjson) catch {type: "raw", value: $line};

def render($pending):
  if .type == "assistant" then assistant
  elif .type == "user" then user($pending)
  elif .type == "system" then system
  elif .type == "result" then result
  elif .type == "raw" then "? unparsable: \(.value | trunc(500))"
  else "? \(.type // "event"): \(tojson | trunc(500))"
  end;

def learn($event):
  if $event.type == "assistant" then
    reduce items(($event.message.content)?) as $block (.;
      if $block.type == "tool_use" and ($block.id? // null) != null
      then .[$block.id] = ($block.name // "?")
      else . end)
  else . end;

def forget($event):
  if $event.type == "user" then
    reduce items(($event.message.content)?) as $block (.;
      if $block.type == "tool_result" then del(.[$block.tool_use_id? // ""])
      else . end)
  else . end;

foreach inputs as $line (
  {pending: {}, text: ""};
  . as $prev
  | ($line | parse) as $event
  | {
      pending: ($prev.pending | learn($event) | forget($event)),
      text: (try ($event | render($prev.pending)) catch "? render failed: \(. | trunc(500))")
    };
  .text
)
| select(. != "")
