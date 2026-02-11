import os
import discord
from dotenv import load_dotenv

load_dotenv()

TOKEN = os.getenv("DISCORD_TOKEN")
if not TOKEN:
    raise RuntimeError("DISCORD_TOKEN not found. Check your .env file.")

intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)

@client.event
async def on_ready():
    print(f"✅ Logged in as {client.user} (id={client.user.id})")

@client.event
async def on_message(message):
    if message.author == client.user:
        return

    # Debug: see exactly what Discord is sending
    print("RAW:", message.content)

    # Require the bot to be mentioned
    if client.user not in message.mentions:
        return

    # Remove the mention(s) from the message and parse the rest
    content = message.content
    for m in message.mentions:
        content = content.replace(m.mention, "")
    cmd = content.strip().lower()

    if cmd == "ping":
        await message.channel.send("pong")

    elif cmd == "start":
        await message.channel.send("START received, cycle transitioning to PREHEAT. (dummy)")

    elif cmd == "abort":
        await message.channel.send("ABORT received, heating ceased. (dummy)")

    elif cmd == "status":
        await message.channel.send("REFLOW @ 123.4°C (dummy)")

client.run(TOKEN)