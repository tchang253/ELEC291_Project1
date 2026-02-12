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
    phase = latest.get("phase", "UNKNOWN")     #IDLE / PREHEAT / SOAK / RAMP / REFLOW/ COOLING 
    temp  = latest.get("temp")

    state_label = f"{phase}"

    if temp is None:
        return f"{state_label} @ N/A"
    return f"{state_label} @ {temp:.1f}°C"

async def safe_get_latest():
    #ok = backend is reacheable
    assert session is not None
    try:
        async with session.get(API_BASE + "/api/latest") as resp:
            data = await resp.json()
            return True, data
    except Exception as e:
        return False, str(e)

async def safe_post(path: str):

    #returns (ok, resp_json_or_error_string)

    assert session is not None
    try:
        async with session.post(API_BASE + path) as resp:
            data = await resp.json()
            return True, data
    except Exception as e:
        return False, str(e)

async def safe_get_bytes(path: str):
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

    #require mention in chat
    if client.user not in message.mentions:
        return

    #strip the mention message
    content = message.content
    for m in message.mentions:
        content = content.replace(m.mention, "")
    cmd = content.strip().lower()

    #case 3: the backend is unreachable (bot can still respond)
    ok, latest_or_err = await safe_get_latest()
    if not ok:
        await message.channel.send("⚠️ Warning: Could not communicate with backend, please check connection.")
        return

    latest = latest_or_err
    connected = bool(latest.get("connected", False))

    #case 2: the backend is reachable but it is disconnected from the MCU
    if not connected:
        await message.channel.send("⚠️ Warning: Currently disconnected, please check connection.")
        return

    #case 1: the backend is reachable and the MCU is connected 
    if cmd == "status":
        await message.channel.send(fmt_state(latest))
        return

    if cmd == "start":
        #checking if START is allowed
        phase = str(latest.get("phase", "")).strip().upper()
        temp = latest.get("temp", None)
        temp_val = None if temp is None else float(temp)

        #block POST START command when cycle is already underway (requirements not met)
        if phase != "IDLE":
            #message for the case where it is in COOLING and temp > 60
            if phase == "COOLING" and temp_val is not None and temp_val > 60.0:
                await message.channel.send("⚠️ Warning: START command cannot be sent, please wait until temp <= 60°C")
            else:
                await message.channel.send("⚠️ Warning: START command cannot be sent, please wait until cycle complete.")
            return

        #block START in IDLE and if temp > 60
        if temp_val is not None and temp_val > 60.0:
            await message.channel.send("⚠️ Warning: START command cannot be sent, please wait until cycle complete.")
            return

        #message if the bot sends a POST
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