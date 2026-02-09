import threading
import time
from flask import Flask, jsonify, request, render_template

import serial

app = Flask(__name__)
lock = threading.Lock()

#serial config
SERIAL_PORT = "COM3"
SERIAL_BAUD = 115200
SERIAL_TIMEOUT_S = 1

t0 = time.time()

# Shared state for the dashboard
state = {
    "t": 0,                  # seconds since backend started (always increases)
    "temp": None,            # °C
    "set": None,             # °C (last requested or controller-reported)
    "connected": False,      # True/False for UI
    "status": "DISCONNECTED",# CONNECTED/DISCONNECTED/CONNECTING
    "mode": "IDLE",          # controller mode (firmware should report if you want)
    "phase": "AMBIENT",      # controller state/phase (firmware prints as state=...)
    "pwm": None,             # 0..100
    "last_line": "",         # last raw line seen (debug)
}

# Serial handle shared between threads
_ser = None
_ser_lock = threading.Lock()


def _now_s() -> int:
    return int(time.time() - t0)


# Expected firmware format:
#   temp=183.4,set=180.0,state=SOAK,pwm=20
# (line MUST contain temp=...)
def parse_line(line: str):
    s = line.strip()
    if not s:
        return None

    out = {}
    parts = s.split(",")

    for p in parts:
        if "=" not in p:
            continue

        k, v = p.split("=", 1)
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
            out["phase"] = v
        elif k == "pwm":
            try:
                out["pwm"] = int(float(v))
            except:
                pass
        elif k == "mode":
            # optional if firmware provides it
            out["mode"] = v

    return out if "temp" in out else None


#sends a single line (with newline char) to the microcontroller
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

            # Optional: clear junk
            try:
                ser.reset_input_buffer()
            except:
                pass

            while True:
                raw = ser.readline()
                if not raw:
                    continue  # timeout — keep waiting

                line = raw.decode("ascii", errors="ignore").strip()
                if not line:
                    continue

                parsed = parse_line(line)

                with lock:
                    state["t"] = _now_s()
                    state["last_line"] = line

                    # If the line doesn't match our strict protocol, ignore it safely
                    if parsed:
                        if "temp" in parsed:
                            state["temp"] = parsed["temp"]
                        if "set" in parsed:
                            state["set"] = parsed["set"]
                        if "phase" in parsed:
                            state["phase"] = parsed["phase"]
                        if "pwm" in parsed:
                            state["pwm"] = parsed["pwm"]
                        if "mode" in parsed:
                            state["mode"] = parsed["mode"]

        except Exception as e:
            # Disconnect / can't open port. Clean up and retry.
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
                # Keep last known temp/set visible; clear phase/pwm if you want:
                state["phase"] = "AMBIENT"
                state["pwm"] = None
                state["last_line"] = f"(error: {e})"

            time.sleep(1)


@app.route("/")
def index():
    return render_template("dashboard.html")


@app.get("/api/latest")
def api_latest():
    #ensure that time advances
    with lock:
        state["t"] = _now_s()
        return jsonify(state)


@app.post("/api/start")
def api_start():
    ok = serial_send("CMD=START")  # firmware decides if allowed
    return jsonify({"ok": ok})


@app.post("/api/abort")
def api_abort():
    ok = serial_send("CMD=ABORT")
    return jsonify({"ok": ok})


@app.post("/api/idle")
def api_idle():
    ok = serial_send("CMD=IDLE")
    return jsonify({"ok": ok})


@app.post("/api/set")
def api_set():
    data = request.get_json(force=True)
    try:
        val = float(data["set"])
    except:
        return jsonify({"ok": False, "err": "bad set value"}), 400

    #safety temperature clamps
    if val < 25.0:
        val = 25.0
    if val > 260.0:
        val = 260.0

    with lock:
        state["set"] = round(val, 1)

    ok = serial_send(f"SET={state['set']:.1f}")
    return jsonify({"ok": ok, "set": state["set"]})


if __name__ == "__main__":
    threading.Thread(target=serial_reader, daemon=True).start()
    app.run(host="127.0.0.1", port=5000, debug=True)