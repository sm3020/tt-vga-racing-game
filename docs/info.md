## How it works

A sync generator counts through the 640 by 480 pixels of each frame at 60 Hz. The design moves the car, scrolls the road and the traffic, and checks for crashes. The score bar at the top grows while you survive, and the traffic speeds up as it grows. A crash flashes the screen red and restarts the run.

## How to test

Use a 25.175 MHz clock and hold rst_n low for a few cycles, then raise it. The game appears on a monitor connected through a TinyVGA PMOD. Use ui[0] and ui[1] to steer and ui[2] to boost.

## External hardware

A TinyVGA PMOD, a VGA monitor, and three buttons or switches on ui[0], ui[1] and ui[2].
