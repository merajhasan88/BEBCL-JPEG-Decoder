#!/bin/bash
# Program the EP2C5T144C8 over a USB-Blaster with the current jpeg_fpga.sof (volatile, SRAM).
#   ./program.sh            -> program
#   ./program.sh --jic      -> also write the EPCS4 configuration flash (permanent)
# Runs as root here, so no udev rule is needed; on a normal user account add
#   SUBSYSTEM=="usb", ATTR{idVendor}=="09fb", ATTR{idProduct}=="6001", MODE="0666"
# to /etc/udev/rules.d/51-usbblaster.rules.
set -e
export PATH=/root/altera/13.0sp1/quartus/bin:$PATH
cd "$(dirname "$0")"
echo "== cables / devices seen by jtagconfig:"
jtagconfig || { echo "no USB-Blaster found (check the cable, lsusb should list 09fb:6001)"; exit 1; }
jtagconfig | grep -qi "EP2C5" || { echo "EP2C5 not detected on the JTAG chain - is the board powered?"; exit 1; }
echo "== programming output_files/jpeg_fpga.sof"
quartus_pgm -m jtag -o "p;output_files/jpeg_fpga.sof"
echo "LEDs: 0 = heartbeat, 1 = ON when the decoded frame's checksum matches the golden image, 2 = error"
if [ "$1" = "--jic" ]; then
  echo "== converting to a JIC for the EPCS4 and programming it (permanent)"
  quartus_cpf -c -d EPCS4 -s EP2C5T144 output_files/jpeg_fpga.sof output_files/jpeg_fpga.jic
  quartus_pgm -m jtag -o "ipv;output_files/jpeg_fpga.jic"
fi
