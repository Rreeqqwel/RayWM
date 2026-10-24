#!/usr/bin/env python3
"""Deterministic generators of the torture suite (stdlib only).

  gen.py input SEED COUNT WIDTH [HEIGHT]
      Arguments for raywm-test-input (one per line): random pointer motion,
      clicks, Super+drag moves/resizes, and the bindings of the shipped
      plugins (focus, swap, resize, split, float, fullscreen, maximize,
      minimize, workspaces, close; reload when SEED's stream says so).
      Never Super+Shift+E (quit), Super+Return (spawns a terminal) or Print.
  gen.py conf SEED OUT_DIR COUNT
      COUNT raywm.conf files (fuzz-NNNN.conf) mixing valid lines with every
      class of damage; prints one line per file: name and expectation
      ("valid", "invalid" or "any").

The same SEED always gives the same output (random.Random is specified to
be reproducible across platforms for a given seed and version 2 seeding).
"""
import os
import random
import sys

FOCUS_KEYS = ["h", "j", "k", "l"]


def chord(mods, key):
    out = []
    for m in mods:
        out += ["key", m, "down"]
    out += ["key", key, "down", "key", key, "up"]
    for m in reversed(mods):
        out += ["key", m, "up"]
    return out


def gen_input(seed, count, width, height=720):
    r = random.Random(seed)
    args = []
    for _ in range(count):
        k = r.randrange(100)
        x, y = r.randrange(width), r.randrange(height)
        if k < 25:
            args += ["move", str(x), str(y)]
        elif k < 35:
            args += ["move", str(x), str(y), "down", "left", "up", "left"]
        elif k < 42:
            # Super+drag (move) or Super+right drag (resize) across the layout.
            b = r.choice(["left", "right"])
            args += ["move", str(x), str(y), "key", "super", "down", "down", b]
            for _ in range(r.randrange(1, 6)):
                args += ["move", str(r.randrange(width)), str(r.randrange(height))]
            args += ["up", b, "key", "super", "up"]
        elif k < 60:
            args += chord(["super"], r.choice(FOCUS_KEYS + ["tab"]))
        elif k < 66:
            args += chord(["super", "shift"], r.choice(FOCUS_KEYS))   # swap
        elif k < 71:
            args += chord(["super", "ctrl"], r.choice(FOCUS_KEYS))    # resize split
        elif k < 74:
            args += chord(["super"], "t")                              # split direction
        elif k < 78:
            args += chord(["super", "shift"], "space")                 # float toggle
        elif k < 82:
            args += chord(["super"], r.choice(["f", "m"]))            # fullscreen, maximize
        elif k < 85:
            args += chord(["super"], "n") if r.randrange(2) else chord(["super", "shift"], "n")
        elif k < 91:
            args += chord(["super"], str(r.randrange(1, 4)))           # workspace 1..3
        elif k < 95:
            args += chord(["super", "shift"], str(r.randrange(1, 4)))  # move to workspace
        elif k < 97:
            args += chord(["super"], "q")                              # close focused
        elif k < 98:
            args += chord(["ctrl", "alt"], "r")                        # reload
        else:
            args += ["sleep", str(r.randrange(1, 40))]
    print("\n".join(args))


# ---- raywm.conf fuzzing ---------------------------------------------------------

KEYS = {
    "general": {"focus_new_windows": "bool", "terminal": "str", "xwayland": "bool"},
    "appearance": {"inner_gaps": (0, 500), "outer_gaps": (0, 500), "border_width": (0, 64),
                   "border_active": "color", "border_inactive": "optcolor"},
    "input": {"mouse_modifier": "mod", "focus_follows_mouse": "bool"},
}


def valid_value(r, kind):
    if kind == "bool":
        return r.choice(["true", "false", "yes", "no", "on", "off", "1", "0", "TRUE", "Off"])
    if kind == "str":
        return r.choice(["", "foot", "kitty -1", "'alacritty'", '"x y"', "a" * r.randrange(0, 257)])
    if kind == "mod":
        return r.choice(["super", "alt", "ctrl", "shift", "SUPER", "logo", "mod4", "mod1", "control", "win"])
    if kind in ("color", "optcolor"):
        c = "#" + "".join(r.choice("0123456789abcdefABCDEF") for _ in range(r.choice([6, 8])))
        return "none" if kind == "optcolor" and r.randrange(4) == 0 else c
    lo, hi = kind
    return str(r.choice([lo, hi, r.randrange(lo, hi + 1)]))


def invalid_value(r, kind):
    if kind == "bool":
        return r.choice(["maybe", "2", "tru", "", "yes please", "-1"])
    if kind == "str":
        return r.choice(['"unterminated', "'x\"", "a" * r.randrange(257, 5000), "x\x01y", "\x7f"])
    if kind == "mod":
        return r.choice(["hyper", "", "super+alt", "meta", "SUPER "*2])
    if kind in ("color", "optcolor"):
        return r.choice(["#12345", "#1234567", "red", "#gggggg", "123456", "#", "none" if kind == "color" else "#12", "##123456"])
    lo, hi = kind
    return r.choice([str(lo - 1), str(hi + 1), "99999999999999999999", "-99999999999", "8px", "0x10", "1e3", "", "+",
                     " 8 8", "٣"])


DAMAGE = ["truncated_header", "no_section", "garbage_line", "control", "bad_utf8", "random_bytes", "nul",
          "empty_key", "invalid_value", "huge_line", "crlf_mix", "deep_brackets"]


def gen_conf(seed, out_dir, count):
    r = random.Random(seed)
    os.makedirs(out_dir, exist_ok=True)
    for n in range(count):
        lines = []
        expect = "valid"
        damage = r.random() < 0.6
        if r.randrange(10) == 0:
            lines = []  # empty file
        for _ in range(r.randrange(0, 25)):
            sec = r.choice(list(KEYS) + ["future", "plugins"])
            lines.append(r.choice(["[%s]" % sec, "[ %s ]" % sec, "[%s]  " % sec]))
            for _ in range(r.randrange(0, 8)):
                if sec in KEYS:
                    key = r.choice(list(KEYS[sec]) + ["unknown_%d" % r.randrange(9)])
                    kind = KEYS[sec].get(key, "str")
                else:
                    key, kind = "k%d" % r.randrange(9), "str"
                sep = r.choice(["=", " = ", "  =\t"])
                lines.append(key + sep + valid_value(r, kind))
                if r.randrange(6) == 0:
                    lines.append(r.choice(["# comment", "; comment", "   # indented", "#[general]"]))
        text = "\n".join(lines).encode()
        if damage:
            d = r.choice(DAMAGE)
            pos = r.randrange(len(text) + 1)
            if d == "truncated_header":
                text += b"\n[general"
            elif d == "no_section":
                text = b"inner_gaps = 3\n" + text
            elif d == "garbage_line":
                text = text[:pos] + b"\nthis is not a setting\n" + text[pos:]
            elif d == "control":
                # In a setting (control bytes inside comments are not looked at).
                text += b"\n[general]\nterminal = a" + bytes([r.choice([1, 2, 7, 8, 11, 12, 27, 127])]) + b"b\n"
            elif d == "bad_utf8":
                text = text[:pos] + r.choice([b"\xff", b"\xc3", b"\xe2\x82", b"\xed\xa0\x80", b"\xf8\x88\x80\x80\x80"]) + text[pos:]
            elif d == "random_bytes":
                text = bytes(r.randrange(256) for _ in range(r.randrange(1, 4096)))
                expect = "any"
            elif d == "nul":
                text += b"\n[appearance]\ninner_gaps = 4\x00\n"
            elif d == "empty_key":
                text += b"\n[general]\n = true\n"
            elif d == "invalid_value":
                sec = r.choice(list(KEYS))
                key = r.choice(list(KEYS[sec]))
                text += ("\n[%s]\n%s = %s\n" % (sec, key, invalid_value(r, KEYS[sec][key]))).encode("utf-8", "surrogateescape")
            elif d == "huge_line":
                text += b"\n[general]\nterminal = " + b"x" * r.choice([300, 70000, 200000]) + b"\n"
            elif d == "crlf_mix":
                text = text.replace(b"\n", b"\r\n")
                expect = "keep"
            elif d == "deep_brackets":
                text += b"\n[[general]]\nxwayland = true\n"
                expect = "any"
            if expect == "valid":
                expect = "invalid"
            elif expect == "keep":
                expect = "valid"
        # A random byte file can still be valid (e.g. only comments): "any".
        name = "fuzz-%04d.conf" % n
        with open(os.path.join(out_dir, name), "wb") as f:
            f.write(text)
        print(name, expect)


def main(argv):
    if len(argv) >= 4 and argv[0] == "input":
        gen_input(int(argv[1]), int(argv[2]), int(argv[3]), int(argv[4]) if len(argv) > 4 else 720)
        return 0
    if len(argv) == 4 and argv[0] == "conf":
        gen_conf(int(argv[1]), argv[2], int(argv[3]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
