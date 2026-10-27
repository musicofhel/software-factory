# GitHub Actions expressions (docs: actions/reference/workflows-and-actions/expressions), the subset
# the workflows use, evaluated in jq. Input: {ctx: {github, env, vars, secrets, inputs, steps, needs,
# job, runner, matrix}, status: {success, failure, cancelled}}. Entry points:
#   ev($src)    the value of one expression ("a == 'b' && c"); a leading `${{` / trailing `}}` is
#               stripped, as GitHub does for `if:`
#   tmpl($s)    a string with `${{ … }}` parts, each replaced by its value as GitHub prints it
#   truthy      GitHub's falsy set: false, 0, -0, "", null (and NaN)
# Anything outside the subset is an error, never a silent value: unknown syntax, an unknown function,
# hashFiles. `||` and `&&` return operand values, not booleans, as GitHub's do. `==` and `!=`
# compare strings case-insensitively and coerce mismatched types to numbers.

def truthy: . != false and . != null and . != 0 and . != "" and (if type == "number" then . == . else true end);

def tostr: if type == "string" then . elif . == null then "" elif type == "boolean" or type == "number" then tostring
           else tojson end;
def tonum: if type == "number" then . elif . == null then 0 elif . == true then 1 elif . == false then 0
           elif type == "string" then (if test("^\\s*$") then 0 else (tonumber? // nan) end) else nan end;

def tokens:
  [ scan("\\s*(\\|\\||&&|==|!=|<=|>=|[<>!()\\[\\],.*]|'(?:[^']|'')*'|-?[0-9]+(?:\\.[0-9]+)?|[A-Za-z_][A-Za-z0-9_-]*)\\s*")
    | .[0] ] as $t
  | if ($t | map(gsub("\\s"; "")) | join("")) != gsub("\\s"; "")
    then error("expr: cannot tokenize: \(.)") else $t | map(gsub("^\\s+|\\s+$"; "")) end;

# Recursive descent over [tokens, pos]. Every parser takes $T (tokens) and a position and returns
# [ast, newpos]. ASTs: {lit}, {path: [...]}, {op, l, r}, {not}, {call, args}.
def peek($T; $p): $T[$p] // null;
def pexpr($T; $p):
  def primary($p):
    peek($T; $p) as $k
    | if $k == null then error("expr: unexpected end")
      elif $k == "(" then pexpr($T; $p + 1) as [$e, $q] | if peek($T; $q) == ")" then [$e, $q + 1] else error("expr: ) expected") end
      elif $k == "!" then primary($p + 1) as [$e, $q] | [{not: $e}, $q]
      elif ($k | startswith("'")) then [{lit: ($k[1:-1] | gsub("''"; "'"))}, $p + 1]
      elif ($k | test("^-?[0-9]")) then [{lit: ($k | tonumber)}, $p + 1]
      elif $k == "true" then [{lit: true}, $p + 1]
      elif $k == "false" then [{lit: false}, $p + 1]
      elif $k == "null" then [{lit: null}, $p + 1]
      elif ($k | test("^[A-Za-z_]")) then
        if peek($T; $p + 1) == "(" then
          def args($p; $acc):
            if peek($T; $p) == ")" then [$acc, $p + 1]
            else pexpr($T; $p) as [$a, $q]
              | if peek($T; $q) == "," then args($q + 1; $acc + [$a])
                elif peek($T; $q) == ")" then [$acc + [$a], $q + 1]
                else error("expr: , or ) expected in \($k)()") end
            end;
          args($p + 2; []) as [$as, $q] | [{call: ($k | ascii_downcase), args: $as}, $q]
        else
          def path($p; $acc):
            if peek($T; $p) == "." and peek($T; $p + 1) == "*" then path($p + 2; $acc + [{star: true}])
            elif peek($T; $p) == "." and (peek($T; $p + 1) // "" | test("^[A-Za-z_]")) then path($p + 2; $acc + [{key: peek($T; $p + 1)}])
            elif peek($T; $p) == "[" then pexpr($T; $p + 1) as [$e, $q]
              | if peek($T; $q) == "]" then path($q + 1; $acc + [{index: $e}]) else error("expr: ] expected") end
            else [{path: $acc}, $p] end;
          path($p + 1; [{key: $k}])
        end
      else error("expr: unexpected token \($k)") end;
  def cmp($p):
    primary($p) as [$l, $q]
    | peek($T; $q) as $o
    | if $o != null and ($o | IN("==", "!=", "<", "<=", ">", ">=")) then primary($q + 1) as [$r, $s] | [{op: $o, l: $l, r: $r}, $s]
      else [$l, $q] end;
  def pand($p): cmp($p) as [$l, $q]
    | def more($l; $q): if peek($T; $q) == "&&" then cmp($q + 1) as [$r, $s] | more({op: "&&", l: $l, r: $r}; $s) else [$l, $q] end;
      more($l; $q);
  def por($p): pand($p) as [$l, $q]
    | def more($l; $q): if peek($T; $q) == "||" then pand($q + 1) as [$r, $s] | more({op: "||", l: $l, r: $r}; $s) else [$l, $q] end;
      more($l; $q);
  por($p);

def eq($a; $b):
  if ($a | type) == "string" and ($b | type) == "string" then ($a | ascii_downcase) == ($b | ascii_downcase)
  elif ($a | type) == ($b | type) then $a == $b
  else ($a | tonum) as $x | ($b | tonum) as $y | $x == $y end;

def evast($ast; $c; $st):
  def go($n):
    if $n | has("lit") then $n.lit
    elif $n | has("not") then (go($n.not) | truthy | not)
    elif $n | has("path") then
      reduce $n.path[] as $s ({v: $c, star: false};
        if $s | has("star") then .v = (if (.v | type) == "object" then [.v[]] elif (.v | type) == "array" then .v else [] end) | .star = true
        elif $s | has("key") then
          if .star then .v = [.v[] | if type == "object" then .[$s.key] else null end]
          else .v = (if (.v | type) == "object" then .v[$s.key] else null end) end
        else go($s.index) as $i
          | .v = (if (.v | type) == "object" and ($i | type) == "string" then .v[$i]
                  elif (.v | type) == "array" and ($i | type) == "number" then .v[$i] else null end) end)
      | .v
    elif $n | has("op") then
      if $n.op == "||" then go($n.l) as $l | if ($l | truthy) then $l else go($n.r) end
      elif $n.op == "&&" then go($n.l) as $l | if ($l | truthy) then go($n.r) else $l end
      else go($n.l) as $l | go($n.r) as $r
        | if $n.op == "==" then eq($l; $r) elif $n.op == "!=" then (eq($l; $r) | not)
          else ($l | tonum) as $x | ($r | tonum) as $y
          | if $n.op == "<" then $x < $y elif $n.op == "<=" then $x <= $y elif $n.op == ">" then $x > $y else $x >= $y end
          end
      end
    else [$n.args[] | go(.)] as $a
      | if $n.call == "contains" then
          if ($a[0] | type) == "array" then any($a[0][]; eq(.; $a[1]))
          else ($a[0] | tostr | ascii_downcase) | contains($a[1] | tostr | ascii_downcase) end
        elif $n.call == "startswith" then ($a[0] | tostr | ascii_downcase) | startswith($a[1] | tostr | ascii_downcase)
        elif $n.call == "endswith" then ($a[0] | tostr | ascii_downcase) | endswith($a[1] | tostr | ascii_downcase)
        elif $n.call == "fromjson" then ($a[0] | tostr | fromjson)
        elif $n.call == "tojson" then ($a[0] | tojson)
        elif $n.call == "join" then (if ($a[0] | type) == "array" then $a[0] | map(tostr) | join($a[1] // "," | tostr) else $a[0] | tostr end)
        elif $n.call == "format" then
          reduce range(1; $a | length) as $i ($a[0] | tostr; gsub("\\{\($i - 1)\\}"; $a[$i] | tostr))
        elif $n.call == "success" then $st.success
        elif $n.call == "failure" then $st.failure
        elif $n.call == "cancelled" then false
        elif $n.call == "always" then true
        else error("expr: function \($n.call)() is not simulated") end
    end;
  go($ast);

def strip: sub("^\\s*\\$\\{\\{"; "") | sub("\\}\\}\\s*$"; "");
def ev($src): . as $in | ($src | strip | tokens) as $T
  | pexpr($T; 0) as [$ast, $p]
  | if $p != ($T | length) then error("expr: trailing tokens in \($src)") else evast($ast; $in.ctx; $in.status) end;
# Does the expression call a status function? (If not, GitHub ANDs success() in front of an `if:`.)
def has_status($src): ($src | strip | tokens) | any(.[]; ascii_downcase | IN("success", "failure", "always", "cancelled"));
def tmpl($s): . as $in | $s | gsub("\\$\\{\\{(?<e>(?:[^}]|\\}(?!\\}))*)\\}\\}"; (.e as $e | $in | ev($e) | tostr));
