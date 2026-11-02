import os, sys, tty
out = open(sys.argv[1], "ab", buffering=0)
tty.setraw(0)
print("raw reader running", file=sys.stderr)
while True:
    b = os.read(0, 4096)
    if not b: break
    out.write(b)
