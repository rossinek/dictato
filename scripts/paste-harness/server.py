import http.server, json, sys

STATE = {"value": "", "events": []}
PAGE = """<!doctype html><meta charset=utf-8><title>paste-test</title>
<body style="font:14px system-ui;margin:20px">
<p>Paste test target &mdash; please do not type here.</p>
<textarea id=t autofocus style="width:95%;height:70vh"></textarea>
<script>
const t=document.getElementById('t'); let ev=[];
function rep(){fetch('/report',{method:'POST',body:JSON.stringify({value:t.value,events:ev})});}
t.addEventListener('paste',e=>{ev.push({type:'paste',len:(e.clipboardData.getData('text/plain')||'').length});rep();});
t.addEventListener('beforeinput',e=>{ev.push({type:'beforeinput',it:e.inputType,len:(e.data||'').length});});
t.addEventListener('input',e=>{ev.push({type:'input',it:e.inputType});rep();});
// Chat-like field: plain Enter submits, Shift+Enter inserts a line break.
t.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();ev.push({type:'submit'});rep();}});
window.addEventListener('blur',()=>{ev.push({type:'blur'});rep();});
setInterval(rep,1000);
</script>"""

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/state":
            body = json.dumps(STATE).encode()
            ctype = "application/json"
        else:
            body = PAGE.encode(); ctype = "text/html; charset=utf-8"
        self.send_response(200); self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        STATE.update(json.loads(self.rfile.read(n)))
        self.send_response(204); self.end_headers()

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
