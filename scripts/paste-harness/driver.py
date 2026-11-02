"""Usage: python3 -I driver.py <target> <methods,comma> <lengths,comma> <trials> [restoreSeconds]
targets: helium chrome safari textedit terminal iterm vscode (target must already be prepared by setup)."""
import json, os, subprocess, sys, time, urllib.request

H = os.path.dirname(os.path.abspath(__file__))
# Generated files (compiled injector, outputs, VS Code scratch folder) stay out of the repo.
WORK = os.environ.get("PASTE_HARNESS_WORK", os.path.join(os.environ.get("TMPDIR", "/tmp"), "paste-harness"))
OUT = os.path.join(WORK, "out"); os.makedirs(OUT, exist_ok=True)
INJECT = os.path.join(WORK, "inject")
BUNDLE = {"helium": "net.imput.helium", "chrome": "com.google.Chrome", "safari": "com.apple.Safari",
          "textedit": "com.apple.TextEdit", "terminal": "com.apple.Terminal", "iterm": "com.googlecode.iterm2",
          "vscode": "com.microsoft.VSCode"}
PORT = {"helium": 8765, "chrome": 8766, "safari": 8767}

BASE_SENT = ("Wczoraj rozmawiałem z zespołem o wdrożeniu nowej wersji aplikacji, "
             "ustaliliśmy, że testy (jednostkowe i end-to-end) muszą przejść przed piątkiem; "
             "pytanie brzmi: czy zdążymy? Zażółć gęślą jaźń. ")
def make_text(kind, i):
    tok = f"[T{i:04d}]"
    if kind == "short":  return f"{tok} Krótki test ąęśćżółń."
    if kind == "medium": return f"{tok} " + BASE_SENT * 2 + tok
    if kind == "long":   return f"{tok} " + BASE_SENT * 18 + tok             # ~3300 chars
    if kind == "multi":  return (f"{tok} Cześć Aniu,\n\nDzięki za wiadomość 👍 Oto plan:\n"
                                 "- punkt pierwszy\n- punkt drugi \"w cudzysłowie\"\n\nPozdrawiam,\nArtur " + tok)
    raise ValueError(kind)

def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.rstrip("\n")

def read_state(target):
    if target in PORT:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT[target]}/state") as r:
            s = json.load(r); return s["value"], s["events"]
    if target == "textedit":
        return osa('tell application "TextEdit" to get text of front document'), None
    if target in ("terminal", "iterm"):
        with open(os.path.join(OUT, f"{target}.raw"), "rb") as f:
            return f.read().decode("utf-8", "replace"), None
    if target == "vscode":
        with open(os.path.join(WORK, "vsc", "target.txt"), encoding="utf-8") as f:
            s = f.read(); return (s[:-1] if s.endswith("\n") else s), None

def norm(s): return s.replace("\r\n", "\n").replace("\r", "\n")

def main():
    if not os.path.exists(INJECT) or os.path.getmtime(INJECT) < os.path.getmtime(os.path.join(H, "inject.swift")):
        subprocess.run(["swiftc", "-O", os.path.join(H, "inject.swift"), "-o", INJECT], check=True)
    target, methods, kinds, trials = sys.argv[1], sys.argv[2].split(","), sys.argv[3].split(","), int(sys.argv[4])
    restore = sys.argv[5] if len(sys.argv) > 5 else "3"
    results = []; n = int(time.time()) % 10000
    for method in methods:
        for kind in kinds:
            for _ in range(trials):
                n += 1
                text = make_text(kind, n)
                tf = os.path.join(OUT, "text.txt"); open(tf, "w", encoding="utf-8").write(text)
                if target in ("helium", "chrome"):
                    app = {"helium": "Helium", "chrome": "Google Chrome"}[target]
                    url = osa(f'tell application "{app}" to get URL of active tab of front window')
                    if "127.0.0.1" not in url:
                        print("ABORTED: active tab is not the test page:", url); print_summary(results); sys.exit(2)
                if target == "iterm":
                    name = osa('tell application "iTerm2" to get name of current session of current window')
                    if "python" not in name.lower() and "reader" not in name.lower():
                        print("ABORTED: iTerm current window is not the reader:", name); print_summary(results); sys.exit(2)
                before, ev0 = read_state(target)
                t0 = time.time()
                p = subprocess.run([INJECT, method, BUNDLE[target], tf, restore],
                                   capture_output=True, text=True)
                dt = time.time() - t0
                if p.returncode == 2:
                    print("ABORTED: focus left target", p.stdout.strip()); print_summary(results); sys.exit(2)
                time.sleep(0.6)
                after, ev1 = read_state(target)
                b, a, t = norm(before), norm(after), norm(text)
                submitted = ev1 is not None and any(e["type"] == "submit" for e in ev1[len(ev0):])
                if submitted: res = "SUBMITTED"
                elif a == b + t: res = "OK"
                elif a == b: res = "NOTHING"
                elif a.count(f"[T{n:04d}]") > (2 if kind != 'short' else 1): res = "DUPLICATE"
                else: res = "DIFF"
                extra = ""
                if ev1 is not None and ev0 is not None:
                    new = ev1[len(ev0):]
                    extra = " events=" + ",".join(f"{e['type']}{':'+str(e.get('len')) if 'len' in e else ''}" for e in new)
                if res == "DIFF":
                    added = a[len(b):] if a.startswith(b) else a[-len(t) - 50:]
                    extra += f" | expected tail={t[-60:]!r} got tail={added[-60:]!r} len {len(added)} vs {len(t)}"
                line = f"{target:8} {method:9} {kind:6} #{n} {res:9} {dt:5.1f}s rc={p.returncode} {p.stdout.strip().replace(chr(10), '; ')}{extra}"
                print(line, flush=True)
                results.append((method, kind, res))
    print_summary(results)

def print_summary(results):
    from collections import Counter
    c = Counter((m, k, r) for m, k, r in results)
    print("SUMMARY:", dict(c))

main()
