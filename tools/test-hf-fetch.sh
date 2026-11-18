#!/usr/bin/env bash
# tools/hf-fetch.sh's token handling, offline (#365): a made-up token never shows in a bash -x trace or with a
# .curlrc's verbose, goes to the Hugging Face endpoint and not to the host it redirects to, and without a
# token no header goes at all.
# A fake huggingface_hub module stands in for the listing and the token; two local servers stand in for
# huggingface.co and its CDN.
#
#   tools/test-hf-fetch.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
for x in python3 curl; do command -v $x >/dev/null || { echo "preflight: $x missing"; exit 1; }; done
mkdir -p "$HOME/scratch/SebType"
work=$(mktemp -d "$HOME/scratch/SebType/test-hf-fetch.XXXXXX")
trap 'kill $server 2>/dev/null; rm -rf "$work"' EXIT
mkdir "$work/fake"

cat > "$work/fake/huggingface_hub.py" <<'EOF'
import os
from types import SimpleNamespace
def get_token(): return os.environ.get("HF_TOKEN")
class HfApi:
    def list_repo_tree(self, *args, **kwargs): return [SimpleNamespace(path="a.txt", size=2)]
EOF
# hf-fetch.sh runs PYTHON -I, which would hide the fake module: this one drops -I.
cat > "$work/fake/python" <<EOF
#!/usr/bin/env bash
[[ \$1 == -I ]] && shift
PYTHONPATH="$work/fake" exec python3 "\$@"
EOF
chmod +x "$work/fake/python"
# The hub redirects every download to the CDN, on another port (another host to curl); each logs the
# Authorization it got.
cat > "$work/fake/servers.py" <<'EOF'
import http.server, sys, threading
log = open(sys.argv[1], "a", buffering=1)
def serve(name, redirect):
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            log.write(f"{name} {self.headers.get('Authorization')}\n")
            if redirect:
                self.send_response(302); self.send_header("Location", redirect() + self.path); self.end_headers()
            else:
                self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
        def log_message(self, *a): pass
    s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s.server_address[1]
cdn = serve("cdn", None)
hub = serve("hub", lambda: f"http://localhost:{cdn}")
print(hub, flush=True)
threading.Event().wait()
EOF
python3 -I "$work/fake/servers.py" "$work/requests.log" > "$work/port" & server=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s $work/port ]] && break; sleep 0.5; done
export HF_ENDPOINT=http://127.0.0.1:$(cat "$work/port")
token=hf_madeUp$RANDOM$RANDOM

fail=0
check() { # name condition...
  local name=$1; shift
  if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fail=1; fi
}
HF_TOKEN=$token bash -x "$here/hf-fetch.sh" "$work/fake/python" "$work/out1" org/ds rev '*' 2> "$work/trace1"
check token-download [ "$(cat "$work/out1/a.txt" 2>/dev/null)" = ok ]
check token-not-in-trace bash -c '! grep -qF "$1" "$2"' - "$token" "$work/trace1"
check token-to-hub grep -qx "hub Bearer $token" "$work/requests.log"
check token-not-to-cdn bash -c '! grep -q "^cdn Bearer" "$1"' - "$work/requests.log"
# A user's .curlrc that turns on verbose must not print the header either.
mkdir "$work/curlhome" && echo verbose > "$work/curlhome/.curlrc"
HF_TOKEN=$token CURL_HOME=$work/curlhome "$here/hf-fetch.sh" "$work/fake/python" "$work/out3" org/ds rev '*' 2> "$work/stderr3"
check token-not-in-curlrc-verbose bash -c '! grep -qF "$1" "$2"' - "$token" "$work/stderr3"
: > "$work/requests.log"
env -u HF_TOKEN "$here/hf-fetch.sh" "$work/fake/python" "$work/out2" org/ds rev '*' 2> "$work/trace2"
check no-token-download [ "$(cat "$work/out2/a.txt" 2>/dev/null)" = ok ]
check no-token-no-header bash -c '! grep -q Bearer "$1"' - "$work/requests.log"
exit $fail
