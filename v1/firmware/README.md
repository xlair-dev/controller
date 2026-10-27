# v1 firmware

| Pico                 | Board |
| -------------------- | ----- |
| 36 / 3V3(OUT)        | VDD   |
| 33 / AGND            | GND   |
| 31 / GP26 (I2C1 SDA) | SDA   |
| 32 / GP27 (I2C1 SCL) | SCL   |

| Pico | GPIO | `BUTTONS` bit |
| ---- | ---- | ------------- |
| 27   | GP21 | 0             |
| 26   | GP20 | 1             |
| 25   | GP19 | 2             |
| 24   | GP18 | 3             |

## Setup

```
zig build run-setup
```

## Firmware

```
zig build run
```

With sensitivity (0-3):

```
zig build run -Dsensitivity=N
```

see: [PROTOCOL.md](./PROTOCOL.md)
