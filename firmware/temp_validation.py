import serial
import csv

port = "COM4"
BAUD = 57600

ser = serial.Serial(port, BAUD, timeout = 1)

with open("temp.csv", "w", newline= "") as f:
    writer = csv.writer(f)

    while True:
        line = ser.readline().decode("utf-8", errors="ignore").strip()

        if not line:
            continue

        for field in line.split(","):
            if field.startswith("temp="):
                try:
                    temp = float((field.split("=")[1]))
                    print(temp)
                    writer.writerow([temp])
                    f.flush()
                except ValueError:
                    pass 