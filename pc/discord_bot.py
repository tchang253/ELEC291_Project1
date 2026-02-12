import os
import io
import discord
from dotenv import load_dotenv
import aiohttp

load_dotenv()
TOKEN = os.getenv("DISCORD_TOKEN")
API_BASE = "http://127.0.0.1:5000"

TIMEOUT = aiohttp.ClientTimeout(total=1.5)

intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)

session: aiohttp.ClientSession | None = None

def fmt_state(latest: dict) -> str:
    # Adjust these keys to match your /api/latest JSON
    phase = latest.get("phase", "UNKNOWN")      # e.g. IDLE/PREHEAT/SOAK/REFLOW/COOLING/ABORTED
    #mode  = latest.get("mode")                 # optional, if you have it
    temp  = latest.get("temp")

    # if you want "MODE/PHASE", keep this, otherwise just phase
    state_label = f"{phase}"

    if temp is None:
        return f"{state_label} @ N/A"
    return f"{state_label} @ {temp:.1f}°C"

async def safe_get_latest():
    """Returns (ok, latest_or_error_string). ok=True means backend reachable."""
    assert session is not None
    try:
        async with session.get(API_BASE + "/api/latest") as resp:
            data = await resp.json()
            return True, data
    except Exception as e:
        return False, str(e)

async def safe_post(path: str):
    """Returns (ok, resp_json_or_error_string)."""
    assert session is not None
    try:
        async with session.post(API_BASE + path) as resp:
            data = await resp.json()
            return True, data
    except Exception as e:
        return False, str(e)

async def safe_get_bytes(path: str):
    """Returns (ok, bytes_or_error_string)."""
    assert session is not None
    try:
        async with session.get(API_BASE + path) as resp:
            data = await resp.read()
            return True, data
    except Exception as e:
        return False, str(e)

@client.event
async def on_ready():
    global session
    session = aiohttp.ClientSession(timeout=TIMEOUT)
    print(f"✅ Logged in as {client.user}")

@client.event
async def on_message(message):
    if message.author == client.user:
        return

    # require mention
    if client.user not in message.mentions:
        return

    # strip mention(s)
    content = message.content
    for m in message.mentions:
        content = content.replace(m.mention, "")
    cmd = content.strip().lower()

    # --- Case 3: backend unreachable ---
    ok, latest_or_err = await safe_get_latest()
    if not ok:
        await message.channel.send("⚠️ Warning: Could not communicate with backend, please check connection.")
        return

    latest = latest_or_err
    connected = bool(latest.get("connected", False))

    # --- Case 1: backend reachable but MCU disconnected ---
    if not connected:
        await message.channel.send("⚠️ Warning: Currently disconnected, please check connection.")
        return

    # --- Case 2: backend reachable and connected ---
    if cmd == "status":
        await message.channel.send(fmt_state(latest))
        return

    if cmd == "start":
        # Pre-check (NO POST unless allowed)
        phase = str(latest.get("phase", "")).strip().upper()
        temp = latest.get("temp", None)
        temp_val = None if temp is None else float(temp)

        # Block if cycle already underway (phase not IDLE)
        if phase != "IDLE":
            # Special message if cooling and still hot
            if phase == "COOLING" and temp_val is not None and temp_val > 60.0:
                await message.channel.send("⚠️ Warning: START command cannot be sent, please wait until temp <= 60°C")
            else:
                await message.channel.send("⚠️ Warning: START command cannot be sent, please wait until cycle complete.")
            return

        # Block if IDLE but still too hot
        if temp_val is not None and temp_val > 60.0:
            await message.channel.send("⚠️ Warning: START command cannot be sent, please wait until cycle complete.")
            return

        # ONLY if allowed do we POST
        ok2, resp_or_err = await safe_post("/api/start")
        if not ok2:
            await message.channel.send("⚠️ Warning: Could not communicate with backend, please check connection.")
            return

        resp = resp_or_err
        if not resp.get("ok", False):
            reason = resp.get("reason", "UNKNOWN")
            if reason == "COOLING_TOO_HOT":
                await message.channel.send("⚠️ Warning: START command cannot be sent, please wait until temp <= 60°C")
                return
            await message.channel.send("⚠️ Warning: START command cannot be sent, please wait until cycle complete.")
            return

        await message.channel.send("START command sent, transitioning to PREHEAT.")
        return

    if cmd == "abort":
        ok2, resp_or_err = await safe_post("/api/abort")
        if not ok2:
            await message.channel.send("⚠️ Warning: Could not communicate with backend, please check connection.")
            return

        resp = resp_or_err
        phase_before = resp.get("phase", "IDLE")

        if phase_before in ("PREHEAT", "SOAK", "RAMP", "REFLOW"):
            await message.channel.send("ABORT command sent, heating ceased. Returning to IDLE.")
        elif phase_before == "COOLING":
            await message.channel.send("ABORT command sent, already in COOLING. Returning to IDLE.")
        else:
            await message.channel.send("ABORT command sent, already in IDLE.")
        return

    if cmd == "export":
        ok_bytes, data_or_err = await safe_get_bytes("/api/export")
        if not ok_bytes:
            await message.channel.send("⚠️ Warning: Could not communicate with backend, please check connection.")
            return

        await message.channel.send(
            file=discord.File(fp=io.BytesIO(data_or_err), filename="run_log.csv")
        )
        return

    if cmd == "help":
        await message.channel.send(
            "Commands:\n"
            "- `@ovencontroller status` → show current state + temp\n"
            "- `@ovencontroller start`  → start cycle (only when IDLE and ≤ 60°C)\n"
            "- `@ovencontroller abort`  → abort heating / force cooldown\n"
            "- `@ovencontroller export` → export run log (.csv) since last START\n"
            "- `@ovencontroller help`   → show this message"
        )
        return

    # Optional: help text for unknown commands
    await message.channel.send("Commands: `status`, `start`, `abort`, `export`, `help`")

client.run(TOKEN)