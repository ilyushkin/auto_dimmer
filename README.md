# Dimmer with Automatic Countdown for IKEA NYMANE Lamp
Automatic dimmer for the IKEA NYMANE lamp using the low-cost 8-bit AVR ATtiny13A microcontroller.

![Video](https://github.com/ilyushkin/auto_dimmer/blob/main/img/video.gif?raw=true)

If the button is held for more than 2 seconds, auto-dimming mode activates with a 20-minute countdown,
during which the lamp gradually dims from the current brightness to zero.
This is convenient for falling asleep without leaving the light on.
The logic is somewhat similar to the dimming-out functionality of the Philips Wake-up Light alarm clock, just without all the bells and whistles.

The project is based on the AVR ATtiny13A microcontroller and written in AVR assembly. It was a fun assembly side-project that begun during the COVID-19 lockdown, and I finally decided to publish it.

The PCB is designed to fit within the base of the IKEA NYMANE swing-arm wall lamp (art. No. 103.569.62) and replace the original basic dimmer that comes with the lamp.

The lamp is turned on and off by pressing the button, unlike the original version, where you had to turn the knob to power it on.
The main advantage of this approach is that the brightness setting is not reset every time the lamp is turned off.

Brightness is adjusted by rotating the potentiometer knob.

I decided to use the RV09 potentiometer because it was the easiest way to retain the brightness level between MCU power cycles.
For this reason, I chose not to use a rotary encoder (e.g., EC11 with an integrated button), as that would require storing the actual brightness level in EEPROM.

I used a simple linear potentiometer without an embedded button, as potentiometers with built-in buttons are rather rare, plus I already had the RV09 in stock.
Since the potentiometer lacks a button, the design includes a plastic inlay that fits inside the metal cap of the original control knob to make it pushable.
This inlay allows the entire knob to slide slightly along the potentiometer shaft and press the pushbutton through a plastic spring-loaded lever mounted next to the potentiometer on the PCB.

The microcontroller is powered by an unisolated power supply based on a capacitive voltage divider, as all parts of the lamp are double insulated.

To achieve this, I designed a 3D-printed internal plastic casing and reused the screws from the lamp's original internal plastic structure.

All plastic parts are also published on Thingiverse:
https://www.thingiverse.com/thing:6785874

Since there is no galvanic isolation, _the microcontroller should only be flashed when the mains power is off_.

For safety reasons, I used a 2.54mm ISP socket instead of a header, as the header can be accidentally touched when removing the lamp from the wall while it's still energized.

## Schematics
![Full Schematics](https://github.com/ilyushkin/auto_dimmer/blob/main/img/full_schematics.png?raw=true)

## Photos
![Photo 1](https://github.com/ilyushkin/auto_dimmer/blob/main/img/photo1.jpg?raw=true)
![Photo 2](https://github.com/ilyushkin/auto_dimmer/blob/main/img/photo2.jpg?raw=true)
![Photo 3](https://github.com/ilyushkin/auto_dimmer/blob/main/img/photo3.jpg?raw=true)
![Photo 4](https://github.com/ilyushkin/auto_dimmer/blob/main/img/photo4.jpg?raw=true)
![Photo 5](https://github.com/ilyushkin/auto_dimmer/blob/main/img/photo5.jpg?raw=true)
![Photo 6](https://github.com/ilyushkin/auto_dimmer/blob/main/img/photo6.jpg?raw=true)
![Photo 7](https://github.com/ilyushkin/auto_dimmer/blob/main/img/photo7.jpg?raw=true)
The original internals of the lamp: the basic DIAC-TRIAC dimmer on the left and the connector box on the right.
![Photo 8. The original internals of the lamp.](https://github.com/ilyushkin/auto_dimmer/blob/main/img/photo8.jpg?raw=true)



