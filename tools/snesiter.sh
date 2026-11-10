#!/bin/sh
# snesiter.sh IMAGE.bin SECONDS [K V ...] - one SNES measurement on the board.
# From the ROM menu, the ROM monitor or a disk build monitor (520,833 baud):
# the disk build on the card started (ROM monitor, dboot 3ee080), IMAGE
# (a disk build) uploaded over the protocol with a 1 KB window and run from
# RAM, its monitor taken, the settings given (snesopt K V, plus seconds and
# profile), Super Mario World run for SECONDS, the reports and the profile
# printed. VM=N in the environment selects video mode N (2: 512x240, 59.98 Hz).
# One logger: sermon_loop.sh, stopped only around the protocol.
cd ~/seattle
IMG=$1; SECS=$2; shift 2
GAME="/snes/Super Mario World (USA).sfc"
R="rcsrc/tools/remote/remote -S /dev/cu.usbserial-ABARV5R6 -b 520833 -t 3000 -W 1"
proto() { pkill -f sermon_loop.sh; pkill -f sermon.py; sleep 1; "$@"; (nohup sh sermon_loop.sh > /dev/null 2>&1 &); sleep 1.5; }
monitor() {   # wait for "press a key", take the monitor
  S0=$1
  for i in $(seq 1 60); do tail -c +$S0 console.log | grep -aq "press a key within" && break; sleep 0.25; done
  K=$(stat -f %z console.log); for i in $(seq 1 25); do printf " " > tx; sleep 0.2; tail -c +$K console.log | grep -aq "help for commands" && break; done
  tail -c +$K console.log | grep -aq "help for commands"
}
# the ROM menu or its monitor, or a disk build monitor (all at 520,833): the
# ROM monitor taken (m; an unknown command at a monitor already open), then
# the disk build started from the card
./sea baud 520833 >/dev/null; sleep 0.5
printf m > tx; sleep 2; printf "\r" > tx; sleep 0.5
S=$(stat -f %z console.log); python3 mtype.py "3=dboot 3ee080" >/dev/null 2>&1
monitor $S || { echo "snesiter: no disk build monitor"; exit 1; }
S=$(stat -f %z console.log)
proto sh -c "$R -q -v run $IMG 2>&1 | tail -1"
monitor $S || { echo "snesiter: the uploaded build gave no monitor"; exit 1; }
# VM=N: the video mode word of the ROM menu (0xA07F0024 = 0x564D0000 | N) for the run
[ -n "$VM" ] && proto sh -c "$R poke 0x007f0024 0x564d000$VM 2>&1 | tail -1"
printf "\r" > tx; sleep 0.3
python3 mtype.py "3=snesopt" >/dev/null 2>&1
python3 mtype.py "3=snesopt seconds $SECS" >/dev/null 2>&1
python3 mtype.py "3=snesopt profile on" >/dev/null 2>&1
while [ $# -ge 2 ]; do python3 mtype.py "3=snesopt $1 $2" >/dev/null 2>&1; shift 2; done
S=$(stat -f %z console.log)
python3 mtype.py "3=snes $GAME" >/dev/null 2>&1
sleep $((SECS + 8))
for i in $(seq 1 30); do tail -c +$S console.log | grep -aq "snes: profile" && break; sleep 1; done
sleep 3
tail -c +$S console.log | tr -d "\r" | grep -a "snes\|^.\{9\} *[0-9a-f]\{8\} " | cut -c10-230
