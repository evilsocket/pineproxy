PineProxy
==

Copyleft of **Simone 'evilsocket' Margaritelli**.  
http://www.evilsocket.net/

---

**PineProxy** is a ruby self contained, low resource consuming HTTP transparent proxy
designed for the [WiFi Pineapple MKV](https://www.wifipineapple.com) board.  
It's based on the **dnsspoof** infusion by Whistle Master.

REQUIREMENTS
===

In order to install ruby and make it work on your WiFi Pineapple, execute the
following commands:

    opkg update
    opkg install ruby --dest usb
    opkg install ruby-gems --dest usb
    opkg install ruby-core --dest usb
    opkg install ruby-enc --dest usb

    # fix the ruby gem import error
    ln -s /sd/usr/lib/ruby /usr/lib/ruby

MOTIVATIONS
===

Since the great [mitmproxy](https://mitmproxy.org) does not run on the pineapple due to missing python dependencies, I thought about making a simple version of it
without *weird* dependecies.

NOTES
===

This software is still under heavy development, use at your own risk.
