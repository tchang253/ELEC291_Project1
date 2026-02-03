# Project 1 - Reflow Oven Controller
## Overview 
Firmware (assembly) runs the oven controller (FSM + temperature sensing + heater control + LCD + UART data transfer)
A PC-side Python app/script logs/displays the temperature live and can provide basic controls (setting temperature, start/abort)
## Structure
├── firmware/ # MCU firmware (assembly)
├── pc/ # Python GUI + logger
├── data/ # Validation & sample runs
├── docs/ # Report + diagrams
├── hardware/ # Pinouts / schematics
└── README.md
