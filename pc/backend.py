import threading
import time
from flask import Flask, jsonify, request, render_template
import serial
import io
import csv
from flask import Response

#serial config
USE_FAKE_SERIAL = False
FAKE_FILE = "fake_serial.txt"
FAKE_PERIOD_S = 1.0

SERIAL_PORT = "COM4"
SERIAL_BAUD = 57600
SERIAL_TIMEOUT_S = 1

app = Flask(__name__)
lock = threading.Lock()

t0 = time.time()

state = {
    "t": 0,
    "temp": None,
    "set": None,
    "connected": False,
    "status": "DISCONNECTED",   #DISCONNECTED / CONNECTING / CONNECTED
    "mode": "IDLE",             #IDLE / RUN / ABORT (or whatever firmware reports to the backend)
    "phase": "IDLE",            #IDLE / PREHEAT / SOAK / RAMP / REFLOW / COOLING
    "pwm": None,
    "last_line": "",
    "seq": 0,                   # increments ONLY when a valid sample is received
    "started": False,           # kept for compatibility (no longer gates telemetry)
}

#logging only after START detected
run_log = []
run_log_active = False       #becomes TRUE after START detected
run_log_lock = threading.Lock()

#time logging is START time relative (time since last START)
run_start_t = None

_ser = None
_ser_lock = threading.Lock()


def _now_s() -> int:
    return int(time.time() - t0)

#expected serial output temp=183.4,set=180.0,state=SOAK,pwm=20
def parse_line(line: str):
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
    global run_log_active, run_start_t

    #holds the previous state for START and ABORT detection
    with lock:
        prev_phase = state.get("phase", "IDLE")

        #telemetry is always live (no matter the state or ABORT)
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

        new_phase = state.get("phase", prev_phase)
        now_t = state["t"]
        now_temp = state.get("temp", None)  # ADDED: for log stop condition

    #begins logging when a START is detected run_log_active = TRUE
    if (not run_log_active) and (prev_phase == "IDLE") and (new_phase == "PREHEAT"):
        with run_log_lock:
            run_log.clear()
            run_start_t = now_t
            run_log_active = True

    #append the csv with the time relative time stamp (time from last START)
    if run_log_active:
        with run_log_lock:
            if run_start_t is None:
                run_start_t = now_t
            t_rel = max(0, now_t - run_start_t)
            run_log.append((t_rel, raw_line))

        #STOP logging ONLY when START is cleared condition is met:
        #state == IDLE AND temp <= 60
        try:
            if (new_phase == "IDLE") and (now_temp is not None) and (float(now_temp) <= 60.0):
                run_log_active = False
        except:
            pass


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

#fake serial reader (for testing only) forces CONNECTED status and reads from .txt file rather than serial
def fake_serial_reader():
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


#commands
@app.post("/api/start")
def api_start():
    global run_log_active, run_start_t
    
    #only allows START when IDLE -> PREHEAT and temp <= 60
    #has special case of when in COOLING and temp > 60 (TOO_HOT)

    print("START POST from:", request.remote_addr, "UA:", request.headers.get("User-Agent"))
    with lock:
        connected = state["connected"]
        phase = state["phase"]
        temp = state["temp"]

    if not connected:
        return jsonify(ok=False, reason="DISCONNECTED"), 200

    if phase == "COOLING" and temp is not None and temp > 60.0:
        return jsonify(ok=False, reason="COOLING_TOO_HOT", temp=temp), 200

    if phase != "IDLE":
        return jsonify(ok=False, reason="NOT_IDLE", phase=phase), 200

    if temp is None:
        return jsonify(ok=False, reason="NO_TEMP"), 200

    if temp > 60.0:
        return jsonify(ok=False, reason="TOO_HOT", temp=temp), 200

    if USE_FAKE_SERIAL:
        with lock:
            state["started"] = True
            state["mode"] = "RUN"
            state["phase"] = "PREHEAT"

        with run_log_lock:
            run_log.clear()
        run_start_t = _now_s()  #time is relative to the latest START detection
        run_log_active = True

        return jsonify(ok=True), 200

    ok = serial_send("CMD=START")
    with lock:
        state["started"] = ok

    if ok:
        with run_log_lock:
            run_log.clear()
        run_start_t = _now_s() 
        run_log_active = True

    return jsonify(ok=ok, reason=None if ok else "SERIAL_WRITE_FAIL"), 200


@app.post("/api/abort")
def api_abort():

    #will always try to ABORT if connected
    #helps choosing the right message to send on discord (state and temp dependent)

    with lock:
        connected = state["connected"]
        phase = state["phase"]

    if not connected:
        return jsonify(ok=False, reason="DISCONNECTED"), 200

    if USE_FAKE_SERIAL:
        with lock:
            state["started"] = False
            state["mode"] = "ABORT"
            state["pwm"] = 0
            if state["phase"] != "IDLE":
                state["phase"] = "COOLING"
        return jsonify(ok=True, phase=phase), 200

    ok = serial_send("CMD=ABORT")

    if ok:
        with lock:
            state["started"] = False
            state["pwm"] = 0
            if state["phase"] != "IDLE":
                state["phase"] = "COOLING"

    return jsonify(ok=ok, reason=None if ok else "SERIAL_WRITE_FAIL", phase=phase), 200


@app.post("/api/idle")
def api_idle():
    if USE_FAKE_SERIAL:
        with lock:
            state["mode"] = "IDLE"
            state["pwm"] = 0
            state["phase"] = "IDLE"
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


@app.get("/api/export")
def api_export():
    global run_start_t

    with run_log_lock:
        rows = list(run_log)

    buf = io.StringIO()
    writer = csv.writer(buf)

    #CSV header (for export)
    writer.writerow(["t", "temp", "set", "state", "pwm"])

    for (t_rel, line) in rows:
        parts = {}
        for field in line.split(","):
            if "=" in field:
                k, v = field.split("=", 1)
                parts[k.strip()] = v.strip()

        writer.writerow([
            t_rel,
            parts.get("temp", ""),
            parts.get("set", ""),
            parts.get("state", ""),
            parts.get("pwm", ""),
        ])

    data = buf.getvalue().encode("utf-8")

    return Response(
        data,
        mimetype="text/csv",
        headers={
            "Content-Disposition": "attachment; filename=run_log.csv"
        },
    )

if __name__ == "__main__":
    if USE_FAKE_SERIAL:
        threading.Thread(target=fake_serial_reader, daemon=True).start()
    else:
        threading.Thread(target=serial_reader, daemon=True).start()

    if USE_FAKE_SERIAL:
        app.run(host="127.0.0.1", port=5000, debug=True)
    else:
        app.run(host="127.0.0.1", port=5000, debug=True, use_reloader=False)