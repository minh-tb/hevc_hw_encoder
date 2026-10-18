import re
import sys
import random

def parse_and_balance_line(line):
    # Match LHS = RHS;
    m = re.match(r'^(\s*[\w\[\]]+\s*=\s*)(.*?)(;.*)$', line)
    if not m:
        return line, False
    lhs, rhs, semi = m.group(1), m.group(2).strip(), m.group(3)

    raw_tokens = re.findall(r'[+-]?\s*32\'sd\d+\s*\*[^+-]+', rhs)
    if len(raw_tokens) not in (8, 16):
        return line, False

    clean_terms = []
    for t in raw_tokens:
        t = t.strip()
        sign = '-' if t.startswith('-') else '+'
        t_clean = t.lstrip('+-').strip()
        clean_terms.append((sign, t_clean))

    if len(clean_terms) not in (8, 16):
        return line, False

    def build_tree(items):
        if len(items) == 1:
            sign, val = items[0]
            return f"(-{val})" if sign == '-' else val
        if len(items) == 2:
            s0, v0 = items[0]
            s1, v1 = items[1]
            t0 = f"(-{v0})" if s0 == '-' else v0
            op = '-' if s1 == '-' else '+'
            return f"({t0} {op} {v1})"
        mid = len(items) // 2
        left = build_tree(items[:mid])
        right = build_tree(items[mid:])
        return f"({left} + {right})"

    balanced = build_tree(clean_terms)
    return f"{lhs}{balanced}{semi}\n", True

def eval_verilog_expr(expr, env):
    # replace 32'sd with regular numbers
    e = re.sub(r"32'sd(\d+)", r"\1", expr)
    # replace $signed({{16{src[k][15]}}, src[k]}) with src_k
    e = re.sub(r"\$signed\(\{\{16\{src\[\d+\]\[15\]\}\},\s*src\[(\d+)\]\}\)", r"src_\1", e)
    # replace o16[k] with o16_k
    e = re.sub(r"o16\[(\d+)\]", r"o16_\1", e)
    # replace o32[k] with o32_k
    e = re.sub(r"o32\[(\d+)\]", r"o32_\1", e)
    return eval(e, {}, env)

def main():
    path = "rtl/transform/transform_1d_core.v"
    with open(path, "r") as f:
        lines = f.readlines()

    modified_count = 0
    new_lines = []
    for i, line in enumerate(lines, 1):
        if 230 <= i <= 370:
            new_line, changed = parse_and_balance_line(line)
            if changed:
                modified_count += 1
                # Check equivalence
                rhs_old = line.split("=", 1)[1].rstrip(";\n")
                rhs_new = new_line.split("=", 1)[1].rstrip(";\n")
                for trial in range(100):
                    env = {f"src_{k}": random.randint(-5000, 5000) for k in range(32)}
                    env.update({f"o16_{k}": random.randint(-5000, 5000) for k in range(32)})
                    env.update({f"o32_{k}": random.randint(-5000, 5000) for k in range(32)})
                    v_old = eval_verilog_expr(rhs_old, env)
                    v_new = eval_verilog_expr(rhs_new, env)
                    assert v_old == v_new, f"Mismatch on line {i}: old={v_old}, new={v_new}"
                new_lines.append(new_line)
                continue
        new_lines.append(line)

    print(f"Verified {modified_count} lines across 100 random trials each. 100% MATCH!")

    if "--apply" in sys.argv:
        with open(path, "w") as f:
            f.writelines(new_lines)
        print("Successfully applied balanced adder trees to transform_1d_core.v!")

if __name__ == "__main__":
    main()
