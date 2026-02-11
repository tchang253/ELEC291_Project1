import threading
import time
from flask import Flask, jsonify, request, render_template
import serial

# ---- config ----
USE_FAKE_SERIAL = False
FAKE_FILE = "fake_serial.txt"
FAKE_PERIOD_S = 1.0

SERIAL_PORT = "COM4"
SERIAL_BAUD = 57600
SERIAL_TIMEOUT_S = 1
# --------------

app = Flask(__name__)
lock = threading.Lock()

t0 = time.time()

state = {
    "t": 0,
    "temp": None,
    "set": None,
    "connected": False,
    "status": "DISCONNECTED",   # DISCONNECTED / CONNECTING / CONNECTED
    "mode": "IDLE",             # IDLE / RUN / ABORT (or whatever firmware reports)
    "phase": "AMBIENT",         # AMBIENT / RAMP / SOAK / REFLOW / COOL (firmware reports as state=...)
    "pwm": None,
    "last_line": "",
    "seq": 0,                   # increments ONLY when a valid sample is received
    "started": False,           # kept for compatibility (no longer gates telemetry)
}

_ser = None
_ser_lock = threading.Lock()


def _now_s() -> int:
    return int(time.time() - t0)


def parse_line(line: str):
    """
    Expected line:
      temp=183.4,set=180.0,state=SOAK,pwm=20
    Must contain temp=...
    """
    s = line.strip()
    if not s:
        return None

    out = {}
    for part in s.split(","):
        if "=" not in part:
            continue
        k, v = part.split("=", 1)
        k = k.strip()
        v = v.strip()

        if k == "temp":
            try:
                out["temp"] = float(v)
            except:
                return None
        elif k == "set":
            try:
                out["set"] = float(v)
            except:
                pass
        elif k == "state":
            out["phase"] = v.strip().upper()
        elif k == "pwm":
            try:
                out["pwm"] = int(float(v))
            except:
                pass
        elif k == "mode":
            out["mode"] = v

    return out if "temp" in out else None


def serial_send(line: str) -> bool:
    global _ser
    with _ser_lock:
        if _ser is None:
            return False
        try:
            _ser.write((line.strip() + "\n").encode("ascii", errors="ignore"))
            return True
        except:
            return False


def _apply_parsed_sample(parsed: dict, raw_line: str):
    """Update state from a parsed sample. Called by both readers."""
    with lock:
        # Telemetry is ALWAYS applied (no START/ABORT gating)
        state["t"] = _now_s()
        state["last_line"] = raw_line
        state["temp"] = parsed["temp"]
        if "set" in parsed:
            state["set"] = parsed["set"]
        if "phase" in parsed:
            state["phase"] = parsed["phase"]
        if "pwm" in parsed:
            state["pwm"] = parsed["pwm"]
        if "mode" in parsed:
            state["mode"] = parsed["mode"]

        state["seq"] += 1


def serial_reader():
    global _ser

    while True:
        try:
            with lock:
                state["connected"] = False
                state["status"] = "CONNECTING"

            ser = serial.Serial(SERIAL_PORT, SERIAL_BAUD, timeout=SERIAL_TIMEOUT_S)

            with _ser_lock:
                _ser = ser

            with lock:
                state["connected"] = True
                state["status"] = "CONNECTED"

            try:
                ser.reset_input_buffer()
            except:
                pass

            while True:
                raw = ser.readline()
                if not raw:
                    continue

                line = raw.decode("ascii", errors="ignore").strip()
                if not line:
                    continue

                parsed = parse_line(line)
                if not parsed:
                    # still record last_line so you can debug weird firmware prints
                    with lock:
                        state["t"] = _now_s()
                        state["last_line"] = line
                    continue

                _apply_parsed_sample(parsed, line)

        except Exception as e:
            with _ser_lock:
                try:
                    if _ser is not None:
                        _ser.close()
                except:
                    pass
                _ser = None

            with lock:
                state["connected"] = False
                state["status"] = "DISCONNECTED"
                state["pwm"] = None
                state["last_line"] = f"(error: {e})"
                # NOTE: do NOT touch state["started"] here (telemetry behavior independent)

            time.sleep(1)


def fake_serial_reader():
    # Fake mode: treat as "connected" and stream samples from a file at FAKE_PERIOD_S
    with lock:
        state["connected"] = True
        state["status"] = "CONNECTED"

    while True:
        try:
            with open(FAKE_FILE, "r") as f:
                for line in f:
                    s = line.strip()
                    if not s:
                        continue

                    parsed = parse_line(s)
                    if not parsed:
                        with lock:
                            state["t"] = _now_s()
                            state["last_line"] = s
                        continue

                    _apply_parsed_sample(parsed, s)
                    time.sleep(FAKE_PERIOD_S)

            # loop forever for testing
        except Exception as e:
            with lock:
                state["connected"] = False
                state["status"] = "DISCONNECTED"
                state["last_line"] = f"(fake error: {e})"
                # NOTE: do NOT touch state["started"] here

            time.sleep(1)

            with lock:
                state["connected"] = True
                state["status"] = "CONNECTED"


@app.route("/")
def index():
    return render_template("dashboard.html")


@app.get("/api/latest")
def api_latest():
    with lock:
        state["t"] = _now_s()
        return jsonify(state)


# ---- commands ----
@app.post("/api/start")
def api_start():
    # START should command the oven, but telemetry continues regardless
    with lock:
        state["started"] = True

    if USE_FAKE_SERIAL:
        with lock:
            state["mode"] = "RUN"
        return jsonify({"ok": True})

    ok = serial_send("CMD=START")
    if not ok:
        with lock:
            state["started"] = False
    return jsonify({"ok": ok})


@app.post("/api/abort")
def api_abort():
    # ABORT should command the oven, but telemetry continues regardless
    with lock:
        state["started"] = False

    if USE_FAKE_SERIAL:
        with lock:
            state["mode"] = "ABORT"
            state["pwm"] = 0
            state["phase"] = "COOL"
        return jsonify({"ok": True})

    ok = serial_send("CMD=ABORT")
    return jsonify({"ok": ok})


@app.post("/api/idle")
def api_idle():
    if USE_FAKE_SERIAL:
        with lock:
            state["mode"] = "IDLE"
            state["pwm"] = 0
            state["phase"] = "AMBIENT"
        return jsonify({"ok": True})

    ok = serial_send("CMD=IDLE")
    return jsonify({"ok": ok})


@app.post("/api/set")
def api_set():
    data = request.get_json(force=True)
    try:
        val = float(data["set"])
    except:
        return jsonify({"ok": False, "err": "bad set value"}), 400

    val = max(25.0, min(260.0, val))

    with lock:
        state["set"] = round(val, 1)

    if USE_FAKE_SERIAL:
        return jsonify({"ok": True, "set": state["set"]})

    ok = serial_send(f"SET={state['set']:.1f}")
    return jsonify({"ok": ok, "set": state["set"]})


if __name__ == "__main__":
    if USE_FAKE_SERIAL:
        threading.Thread(target=fake_serial_reader, daemon=True).start()
    else:
        threading.Thread(target=serial_reader, daemon=True).start()

    app.run(host="127.0.0.1", port=5000, debug=True, use_reloader=False)