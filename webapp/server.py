#!/usr/bin/env python3
"""Local web front end for the DRishti-AI screening pipeline.

    python webapp/server.py                 # serve, assume a worker is running
    python webapp/server.py --start-matlab  # also launch the MATLAB worker
    python webapp/server.py --port 8500

Drag a fundus photograph onto the page; it is screened by the real pipeline and
the result comes back as plain-language JSON plus the Grad-CAM overlay.

HOW THE TWO HALVES TALK
-----------------------
This process never runs inference. It writes the upload into ``webapp/jobs``
and waits for ``src/app/drishtiServeLoop.m`` -- a MATLAB session kept warm --
to write a result back. The write ordering is the protocol: the image lands
first and the ``.request`` marker last, so the worker cannot pick up a job
whose image is still being written.

WHY NOT JUST CALL MATLAB PER REQUEST
------------------------------------
Measured on this machine, ``matlab -batch`` costs ~39 s cold against ~8 s in a
warm session -- nearly all of it one-off GPU and cuDNN setup. Spawning a
process per upload would make every drop feel broken.

BOUND TO LOOPBACK, DELIBERATELY
-------------------------------
Fundus images carry redistribution restrictions (project rule 2), so this
listens on 127.0.0.1 and not on every interface. Do not change that to
0.0.0.0 to reach it from another machine without thinking about whose retinas
are being served.

This file is the one piece of Python in the project that DOES need MATLAB, so
it lives in webapp/ rather than tools/ -- everything in tools/ must keep
running without it.
"""

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parent
JOB_DIR = HERE / "jobs"
INDEX = HERE / "index.html"
REPORT_DIR = PROJECT_ROOT / "reports" / "dashboard"

# Pillow is not a dependency and never will be: the worker decodes the image in
# MATLAB. These are the extensions imread handles, and the uppercase .JPG is not
# optional -- Messidor-2 is 40% uppercase and case-blind globbing has bitten
# this project before.
ALLOWED_EXT = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp"}
MAX_UPLOAD = 64 * 1024 * 1024
SCREEN_TIMEOUT = 300.0          # generous: a cold worker pays GPU init
WORKER_STALE_AFTER = 20.0       # idle heartbeat older than this: chip shows offline
# A BUSY worker cannot heartbeat at all -- MATLAB is single-threaded and a large
# photograph takes ~30 s inside runDrishtiPipeline. So staleness alone must never
# mean "dead", or the server abandons jobs that are running fine. Only a heartbeat
# this old, with the job still unclaimed, counts as genuinely gone.
WORKER_DEAD_AFTER = 240.0
CLAIM_GRACE = 25.0              # how long a live worker gets to pick a job up
JOB_TTL = 900.0                 # orphaned job files are swept after this


# --------------------------------------------------------------------- MATLAB

def find_matlab():
    """Locate matlab.exe: env var, then the Windows registry, then guesses."""
    env = os.environ.get("DRISHTI_MATLAB") or os.environ.get("MATLAB_EXE")
    if env and Path(env).is_file():
        return Path(env)

    exe = shutil.which("matlab")
    if exe:
        return Path(exe)

    if sys.platform == "win32":
        try:
            import winreg
            for root in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
                try:
                    key = winreg.OpenKey(root, r"SOFTWARE\MathWorks\MATLAB")
                except OSError:
                    continue
                with key:
                    i = 0
                    while True:
                        try:
                            ver = winreg.EnumKey(key, i)
                        except OSError:
                            break
                        i += 1
                        try:
                            with winreg.OpenKey(key, ver) as vk:
                                mroot, _ = winreg.QueryValueEx(vk, "MATLABROOT")
                            cand = Path(mroot) / "bin" / "matlab.exe"
                            if cand.is_file():
                                return cand
                        except OSError:
                            continue
        except ImportError:
            pass

    for guess in (r"C:\Program Files\MATLAB", r"D:\MATLAB"):
        p = Path(guess)
        if p.is_dir():
            for sub in sorted(p.iterdir(), reverse=True):
                cand = sub / "bin" / "matlab.exe"
                if cand.is_file():
                    return cand
    return None


def start_worker():
    """Launch the MATLAB worker in its own console, and leave it running."""
    exe = find_matlab()
    if exe is None:
        print("  ! Could not find matlab.exe. Set DRISHTI_MATLAB to its full path,")
        print("    or start the worker yourself:  matlab -batch \"drishtiServeLoop\"")
        return None
    print(f"  Starting MATLAB worker: {exe}")
    cmd = [str(exe), "-batch",
           "addpath(genpath('src')); addpath('config'); drishtiServeLoop"]
    return subprocess.Popen(cmd, cwd=str(PROJECT_ROOT))


def worker_status():
    """Read the worker heartbeat. Returns (alive, calibrated)."""
    alive, calibrated, _ = worker_detail()
    return alive, calibrated


def worker_detail():
    """(idle_and_alive, calibrated, heartbeat_age_seconds). Age is inf if absent."""
    hb = JOB_DIR / "worker.alive"
    try:
        data = json.loads(hb.read_text())
        age = time.time() - float(data.get("t", 0))
        return age < WORKER_STALE_AFTER, bool(data.get("calibrated", False)), age
    except Exception:
        return False, False, float("inf")


# Provenance fields the worker adds to the heartbeat when it is running on a
# site calibration. Forwarded verbatim - the server does not compute, round or
# reformat any of them, so the dashboard shows what was measured or nothing.
#
# calSensitivity and calSpecificity travel together on purpose. A chip that
# showed only the sensitivity a calibration bought, and not the specificity it
# spent, would describe half of a trade as if it were a win.
CALIBRATION_FIELDS = (
    "site", "calEvalSet", "calEvalN",
    "calSensitivity", "calSpecificity",
    "uncalSensitivity", "uncalSpecificity",
)


def calibration_detail():
    """Site-calibration provenance from the heartbeat, or {} when uncalibrated."""
    hb = JOB_DIR / "worker.alive"
    try:
        data = json.loads(hb.read_text())
    except Exception:
        return {}
    if not data.get("calibrated", False):
        return {}
    return {k: data[k] for k in CALIBRATION_FIELDS if k in data}


def sweep_orphans():
    """Remove job files left behind when a request timed out mid-flight.

    The worker finishes and writes its result even after the server has stopped
    waiting, so without this the folder slowly fills with results nobody read.
    """
    now = time.time()
    for f in JOB_DIR.glob("*"):
        if f.name == "worker.alive":
            continue
        try:
            if now - f.stat().st_mtime > JOB_TTL:
                f.unlink()
        except OSError:
            pass


# ---------------------------------------------------------------------- jobs

# --------------------------------------------------------- patient context
# Only these fields are accepted, and only in this shape. Everything else in the
# header is dropped rather than passed through.
PATIENT_FIELDS   = ("id", "age", "gender", "diabetesDuration")
SCREENING_FIELDS = ("centre", "camera", "technician")
FIELD_MAX = 48

# The report is HTML, and GENERATE_CLINICAL_REPORT interpolates these values with
# sprintf('%s') - no escaping. So an operator typing "<script>" into Patient ID
# would land executable markup in a clinical document that gets opened in a
# browser and printed to PDF. Rather than escape downstream in MATLAB, the
# value is constrained HERE, at the trust boundary, to a charset that cannot express
# markup at all: no < > " ' or &.
_SAFE = re.compile(r"[^A-Za-z0-9 ._/()\-+,:]")


def clean_meta(raw, allowed):
    """Whitelist, truncate and strip a patient/screening block from the client."""
    out = {}
    if not isinstance(raw, dict):
        return out
    for key in allowed:
        val = raw.get(key)
        if val is None:
            continue
        text = _SAFE.sub("", str(val)).strip()[:FIELD_MAX]
        if text:                       # an empty field is ABSENT, not blank:
            out[key] = text            # buildReportData prints "not recorded"
    return out


def read_patient_header(headers):
    """Decode the X-Patient-Meta header: base64 of a small JSON object.

    Base64 rather than raw JSON because these are free-text fields and a raw
    header value carrying a CR or LF would let a client inject extra HTTP
    headers. Base64 has no line breaks to exploit.
    """
    blob = headers.get("X-Patient-Meta")
    if not blob:
        return {}, {}
    try:
        payload = json.loads(base64.b64decode(blob).decode("utf-8"))
    except Exception:
        return {}, {}                  # malformed metadata must not fail a screening
    return (clean_meta(payload.get("patient"), PATIENT_FIELDS),
            clean_meta(payload.get("screening"), SCREENING_FIELDS))


# ---------------------------------------------------------------------------
# Is this actually a retina?
# ---------------------------------------------------------------------------
# The grader will return a confident ICDR grade for ANY image handed to it - a
# landscape, a document, a photograph of a face. That is how classifiers behave:
# softmax over five classes always sums to one. On a screening tool, "Grade 0 -
# no diabetic retinopathy" printed under a photograph of somebody's lunch is not
# a funny bug, it is a result that looks exactly like a real one.
#
# Module 1's quality gate does not catch this either. It asks "is this fundus
# photograph readable" - sharpness, illumination, field of view - not "is this a
# fundus photograph at all".
#
# THRESHOLDS ARE MEASURED, NOT GUESSED (the same rule as every other gate here).
# Profiled over 274 images across APTOS, IDRiD and DRIVE - Messidor-2 was NOT
# read, it is the spent holdout. Two signals, either one is sufficient:
#
#   retinal colour   R/B >= 1.10 and R/G >= 1.05. The retina is red; the lowest
#                    R/B seen on a real fundus image was 1.14.
#   circular FOV     a bright disc on a dark surround - >= 60% of corner pixels
#                    near black, with an illuminated centre.
#
# Either alone, because neither covers everything: APTOS contains genuinely
# near-greyscale fundus photographs that fail the colour test, and some images
# are cropped full-frame with no dark border and fail the geometry test.
# Measured result: 274/274 real fundus images accepted, and documents, skies,
# noise, blank frames and corrupt bytes all refused.
#
# It FAILS OPEN if Pillow/numpy are unavailable. This is a convenience guard in
# front of a clinical pipeline that has its own gates; a missing optional
# dependency must not take the screening tool offline.
RB_MIN, RG_MIN = 1.10, 1.05


def looks_like_retina(image_bytes):
    """(ok, reason). True if this plausibly is a colour fundus photograph."""
    try:
        import io
        import numpy as np
        from PIL import Image
    except ImportError:
        return True, "image check skipped (Pillow/numpy not installed)"

    try:
        im = Image.open(io.BytesIO(image_bytes))
        im.load()
    except Exception:
        return False, "That file could not be read as an image."

    im = im.convert("RGB")
    im.thumbnail((192, 192))
    a = np.asarray(im).astype("float32")
    lum = a.mean(2)

    fov = lum > max(12, lum.max() * 0.10)
    if fov.sum() < 50:
        return False, "That image is almost entirely dark - nothing to grade."

    r, g, b = (a[..., i][fov].mean() for i in range(3))
    rb, rg = r / (b + 1e-6), r / (g + 1e-6)
    retinal_colour = rb >= RB_MIN and rg >= RG_MIN

    h, w = lum.shape
    c = max(4, min(h, w) // 8)
    corners = np.concatenate([lum[:c, :c].ravel(), lum[:c, -c:].ravel(),
                              lum[-c:, :c].ravel(), lum[-c:, -c:].ravel()])
    dark_surround = float((corners < 25).mean())
    circular_fov = dark_surround >= 0.60 and lum[h // 3:2 * h // 3, w // 3:2 * w // 3].mean() > 30

    # A retina has structure - vessels, disc, texture. A flat colour field has
    # none, and skin tones are red-dominant enough to pass the colour test on
    # their own, so a uniform patch would otherwise slip through.
    structured = float(lum[fov].std()) >= 6.0
    if not structured:
        return False, ("That image has almost no detail in it - no vessels, no optic "
                       "disc. It does not look like a retinal photograph.")

    if retinal_colour or circular_fov:
        return True, "ok"
    return False, (
        "That does not look like a retinal photograph, so it was not graded. "
        "This tool screens colour fundus images only - handing it any other "
        "picture would still produce a confident-looking grade, which is exactly "
        "what a screening tool must never do."
    )


def submit(image_bytes, filename, patient=None, screening=None):
    """Write a job and block until the worker answers it."""
    ext = Path(filename or "").suffix.lower()
    if ext not in ALLOWED_EXT:
        return {"ok": False,
                "error": f"Unsupported file type '{ext or filename}'. "
                         f"Expected one of: {', '.join(sorted(ALLOWED_EXT))}."}

    # A held-out benchmark filename never even becomes a job. The worker checks
    # this too (assertNotHoldout); doing it here as well means the file is not
    # written to disk at all, and the user gets a real explanation.
    if "messidor" in (filename or "").lower():
        return {"ok": False,
                "error": "Refused: that filename looks like Messidor-2, the held-out "
                         "external benchmark. It was spent once on 2026-09-12 and must "
                         "not be read again (project rule 1)."}

    # Content check, after the cheap filename checks and before anything is
    # written to disk or handed to the worker.
    ok, why = looks_like_retina(image_bytes)
    if not ok:
        return {"ok": False, "error": why}

    sweep_orphans()
    job_id = uuid.uuid4().hex[:12]
    img_name = job_id + ext
    (JOB_DIR / img_name).write_bytes(image_bytes)

    # Marker written LAST: the worker keys off *.request, so ordering is what
    # guarantees it never opens a half-written image.
    req = {"image": img_name, "original": filename}
    # Operator-entered context. Omitted entirely when empty, so the worker and
    # the report distinguish "not recorded" from "recorded as blank".
    if patient:
        req["patient"] = patient
    if screening:
        req["screening"] = screening
    (JOB_DIR / f"{job_id}.request").write_text(json.dumps(req))

    result_path = JOB_DIR / f"{job_id}.result.json"
    claim_path = JOB_DIR / f"{job_id}.started"
    started = time.time()
    deadline = started + SCREEN_TIMEOUT
    claimed = False

    while time.time() < deadline:
        if result_path.is_file():
            try:
                result = json.loads(result_path.read_text())
            except json.JSONDecodeError:
                time.sleep(0.05)        # renamed but not yet flushed; retry
                continue
            return finish(result, job_id, img_name)

        # Once the worker has claimed the job it is demonstrably alive, and the
        # only thing left to do is wait. Do NOT consult the heartbeat after this
        # point: a busy MATLAB cannot write one, and treating that silence as
        # death is exactly the bug that abandoned 29-second jobs.
        if not claimed and claim_path.is_file():
            claimed = True

        if not claimed:
            _, _, age = worker_detail()
            if age > WORKER_DEAD_AFTER and time.time() - started > CLAIM_GRACE:
                cleanup(job_id, img_name)
                return {"ok": False,
                        "error": "The MATLAB inference worker is not running. Start it with "
                                 "matlab -batch \"drishtiServeLoop\" (or re-run this server "
                                 "with --start-matlab)."}
        time.sleep(0.15)

    cleanup(job_id, img_name)
    return {"ok": False,
            "error": f"Timed out after {SCREEN_TIMEOUT:.0f}s. The worker did "
                     f"{'claim' if claimed else 'not claim'} this job."}


PRINT_HOOK = """
<style>@media print{ @page{ margin:8mm; } body{ -webkit-print-color-adjust:exact;
  print-color-adjust:exact; } .noprint{ display:none !important; } }</style>
<div class="noprint" style="position:fixed;top:10px;right:12px;z-index:9999;
  font:13px system-ui;background:#2563eb;color:#fff;padding:8px 14px;border-radius:6px;
  box-shadow:0 2px 8px rgba(0,0,0,.25)">
  Choose <b>Save as PDF</b> in the print dialog
</div>
<script>window.addEventListener('load', () => setTimeout(() => window.print(), 400));</script>
"""


def serve_report(query):
    """Serve one generated clinical report, optionally with a print hook.

    The report is written by the MATLAB worker into reports/dashboard. The name
    is checked against a strict pattern rather than merely joined to the
    directory: this endpoint takes a filename straight off the query string, and
    a bare join would let ../ walk anywhere the server process can read.
    """
    q = urllib.parse.parse_qs(query)
    name = (q.get("f") or [""])[0]
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}_report\.html", name or ""):
        return None, "bad report name"
    path = REPORT_DIR / name
    if not path.is_file():
        return None, "report not found (it may have been cleaned up)"
    html = path.read_text(encoding="utf-8", errors="replace")
    if (q.get("print") or ["0"])[0] == "1":
        if "</body>" in html:
            html = html.replace("</body>", PRINT_HOOK + "</body>", 1)
        else:
            html = html + PRINT_HOOK
    return html, None


def finish(result, job_id, img_name):
    """Inline the overlay as a data URI and tidy the job folder."""
    overlay = result.get("overlay") or ""
    if overlay:
        p = JOB_DIR / overlay
        if p.is_file():
            result["overlayData"] = ("data:image/png;base64,"
                                     + base64.b64encode(p.read_bytes()).decode())
        result.pop("overlay", None)
    cleanup(job_id, img_name, overlay)
    return result


def cleanup(job_id, img_name, overlay=""):
    # The clinical report in reports/dashboard is deliberately NOT removed here:
    # the browser fetches it only when the user asks for the PDF, which is always
    # after this runs.
    for name in (img_name, f"{job_id}.request", f"{job_id}.started",
                 f"{job_id}.result.json", overlay):
        if not name:
            continue
        try:
            (JOB_DIR / name).unlink()
        except OSError:
            pass


# -------------------------------------------------------------------- server

class Handler(BaseHTTPRequestHandler):
    server_version = "DRishtiAI"

    def log_message(self, fmt, *args):
        if "/api/status" not in (self.path or ""):
            sys.stderr.write("  %s %s\n" % (self.command, self.path))

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            if not INDEX.is_file():
                return self._send(500, "index.html is missing", "text/plain")
            return self._send(200, INDEX.read_bytes(), "text/html; charset=utf-8")
        if self.path.startswith("/api/report"):
            _, _, query = self.path.partition("?")
            html, err = serve_report(query)
            if err:
                return self._send(404, f"<h3>{err}</h3>", "text/html; charset=utf-8")
            return self._send(200, html, "text/html; charset=utf-8")
        if self.path == "/api/status":
            alive, calibrated = worker_status()
            body = {"workerAlive": alive, "calibrated": calibrated}
            body.update(calibration_detail())
            return self._send(200, body)
        return self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if self.path != "/api/screen":
            return self._send(404, {"ok": False, "error": "not found"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            return self._send(400, {"ok": False, "error": "empty upload"})
        if length > MAX_UPLOAD:
            return self._send(413, {"ok": False,
                                    "error": f"File too large ({length/1e6:.0f} MB). Limit is 64 MB."})
        data = self.rfile.read(length)
        filename = self.headers.get("X-Filename") or "upload.png"
        patient, screening = read_patient_header(self.headers)
        try:
            return self._send(200, submit(data, filename, patient, screening))
        except Exception as exc:                      # never 500 at the browser
            return self._send(200, {"ok": False, "error": f"{type(exc).__name__}: {exc}"})


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=8420)
    ap.add_argument("--start-matlab", action="store_true",
                    help="also launch the MATLAB inference worker")
    args = ap.parse_args()

    JOB_DIR.mkdir(parents=True, exist_ok=True)

    proc = start_worker() if args.start_matlab else None

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}/"
    print("\n  ==========================================================")
    print("   DRishti-AI  -  browser dashboard")
    print("  ==========================================================")
    print(f"  {url}")
    alive, calibrated = worker_status()
    print(f"  MATLAB worker : {'running' if alive else 'NOT RUNNING'}"
          f"{'  (site-calibrated)' if calibrated else ''}")
    if not alive and proc is None:
        print("  Start it with:  matlab -batch \"drishtiServeLoop\"")
    print("  Loopback only - fundus images are not served to the network.")
    print("  Ctrl-C to stop.\n")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n  stopping.")
    finally:
        httpd.server_close()
        if proc is not None:
            proc.terminate()


if __name__ == "__main__":
    main()
