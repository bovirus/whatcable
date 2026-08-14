---
title: How to tell if a USB-C cable is Thunderbolt
slug: is-my-usb-c-cable-thunderbolt
date: 2026-07-30
summary: Every guide says look for the lightning bolt. Most cables don't have
  one. Three ways to find out what a USB-C cable really is, in order of how much
  they actually tell you.
tags:
  - thunderbolt
  - diagnostics
description: You can't tell by looking. Three ways to check whether the USB-C
  cable in your hand is actually Thunderbolt, on a Mac.
category: Guides
faqs:
  - q: Is Thunderbolt 4 the same as USB-C?
    a: >
      No. USB-C is the connector, the physical shape of the plug. Thunderbolt 4
      is one of several protocols that can run through that shape. Every
      Thunderbolt 4 cable is a USB-C cable. Almost no USB-C cables are
      Thunderbolt 4.
  - q: Are Thunderbolt and USB-C compatible?
    a: Yes, in both directions, but the results differ. A USB-C device in a
      Thunderbolt port works at USB speeds. A Thunderbolt device in a plain
      USB-C port works only if the device has a USB fallback mode, and then only
      at USB speeds.
  - q: Can I plug a USB-C cable into a Thunderbolt 4 port?
    a: Yes. It will negotiate down to whatever the cable supports. The port doesn't
      upgrade the cable, which is the single most common misunderstanding in
      this whole subject.
  - q: Is Thunderbolt 5 the same as USB-C?
    a: Same connector, different protocol, same relationship as every previous
      generation. A Thunderbolt 5 port accepts any USB-C cable. It only reaches
      Thunderbolt 5 speeds with a Thunderbolt 5 cable.
  - q: Do I need a Thunderbolt cable?
    a: Only if you're driving something that needs the bandwidth. Docks, external
      SSDs, high-resolution displays, eGPU enclosures. For charging a phone, a
      basic USB-C cable is fine and you'd be wasting money on anything else.
---


![A tangle of unmarked USB-C cables, none of them visibly different from each other](https://images.whatcable.uk/1785420463960-tangled-usb-c-cables.jpg "Tangled USB Cables")

# How to tell if a USB-C cable is Thunderbolt

You can't tell by looking. Not reliably.

The cable knows what it is. There's a chip inside the connector called an e-marker that declares its capabilities, and your Mac can read that declaration. The trick is getting it back out in a form you can use.

Three ways to do it, worst to best.

## Method 1: look at the connector (mostly useless)

![Two USB-C connectors side by side, one stamped with the Thunderbolt symbol and one unmarked](https://images.whatcable.uk/1785420708124-thunderbolt-and-usbc-cables.jpg "Two USB-C connectors side by side")

Every guide on the internet tells you to look for a lightning bolt symbol. It's the first answer on every page, and it's the weakest one.

Intel does require certification for the Thunderbolt mark. Computers, accessories and cables all have to pass their test suites before they can carry it. So when the symbol is there and genuine, it means something.

The problem is everything else:

* Most cables in your drawer have no markings at all
* The bolt often appears on the port rather than the cable, which tells you what your Mac can do, not what the cable can do
* Counterfeit marks exist, and marketplaces are full of them
* A cable can be genuinely capable and completely unmarked, because plenty of manufacturers don't bother certifying

If your cable has a bolt and a number stamped on the housing, you have your answer. If it doesn't, you've learned nothing. Which describes most cables.

## Method 2: System Information

macOS does expose this. It's buried, but it's there.

Apple menu > About This Mac > More Info > System Report. Then look under Hardware for Thunderbolt or Thunderbolt/USB4, depending on your Mac.

This works, with one significant catch: you need a Thunderbolt device plugged in at the other end. The pane reports on the link, and there's no Thunderbolt link without a Thunderbolt device. Plug in a phone or a basic hub and it tells you nothing useful about the cable.

The second catch is subtler. What you're looking at is the negotiated result of three things: your Mac's port, the cable, and the device. If it comes back slower than expected, System Information won't tell you which of the three is responsible. You're left swapping components one at a time until the number changes.

It's the free answer and it's better than guessing. It's just not a cable test.

## Method 3: read the e-marker

![WhatCable screenshot showing e-marker reading](https://images.whatcable.uk/1785421681570-whatcable-screenshot.png "WhatCable screenshot")

This is the actual answer.

An e-marker is a small chip in the cable's connector. It holds a description of what the cable can do: maximum current, data rate, whether the cable is active or passive, who made it. The USB-IF publishes the test methodology labs use to verify them.

The specification requires an e-marker under two conditions:

1. **Any cable carrying more than 3A.** That's the 100W and 240W cables.
2. **Any full-featured cable.** Meaning anything doing USB 3.x signalling or faster, regardless of how much power it carries.

Both conditions matter, and the second one is the useful one. Every Thunderbolt cable has an e-marker. So does every 10Gb/s cable, every USB4 cable, and every cable that charges above 60W.

Which means a cable with no e-marker at all is telling you something quite specific. It's a basic charging cable: USB 2.0 data at 480Mb/s, 60W or less. Not Thunderbolt, and not close.

And a cable with an e-marker is telling you exactly what it is, in its own words, regardless of what the packaging claimed or what the seller wrote in the listing.

One practical note before you go looking. The e-marker isn't read the moment the plug goes in. It's read during power negotiation, which means something has to be connected at the other end to trigger it. A cable hanging out of a port with nothing on the far end tells you nothing.

One more condition. macOS only reads the e-marker when the connection negotiates above 3A, or when the link is Thunderbolt. In practice: a charger above 60W will do it, and so will any Thunderbolt device. A low-power phone charger won't. Still an easier ask than the Thunderbolt pane in System Information, which wants an actual Thunderbolt device before it shows you anything at all.

WhatCable reads the e-marker and puts it in plain English. Plug the cable into a charger above 60W, look at the menu bar. Speed, power rating, active or passive, and whether the thing is genuinely Thunderbolt or a USB-C cable sitting in a Thunderbolt port. No menu diving, and no need to dig out a Thunderbolt dock just to identify a lead.

[Download WhatCable](/) free, open source, Apple Silicon.

## What the answer actually means

Once you've read the e-marker you'll want to know what it's telling you. The generations differ more than the marketing suggests.

| Cable                     | Max data              | Passive length at full speed | Power                    |
| ------------------------- | --------------------- | ---------------------------- | ------------------------ |
| Plain USB-C (no e-marker) | 480Mb/s               | n/a                          | 60W                      |
| USB-C 5Gb/s               | 5Gb/s                 | 2m                           | 60-100W                  |
| USB-C 10/20Gb/s           | 10-20Gb/s             | 1m                           | 60-100W                  |
| Thunderbolt 3             | 40Gb/s                | 0.5m                         | 100W                     |
| Thunderbolt 4             | 40Gb/s                | 2m                           | 100W, 240W on EPR models |
| Thunderbolt 5             | 80Gb/s, 120Gb/s boost | around 1m                    | 240W                     |



A few things worth pulling out of that table.

**Thunderbolt 3 passive cables fall off a cliff.** A passive TB3 cable holds full 40Gb/s at half a metre. At two metres, the same passive cable drops to 20Gb/s. Half the bandwidth, no warning, no error message. If you want 40Gb/s over two metres on TB3 you need an active cable, which is why the long ones cost so much more.

**Thunderbolt 4 fixed that.** The TB4 specification requires certified passive cables to hold 40Gb/s all the way to two metres. If you're buying a long cable and you have the choice, this is the generation where the certification earns its money.

**Thunderbolt 5 tightens it up again.** TB5 runs at 80Gb/s bidirectional as standard, with a 120Gb/s Bandwidth Boost mode that reallocates lanes to push more in one direction. Higher frequencies mean less tolerance for signal loss, so the passive limit comes back down to roughly a metre. Beyond that you need retimer chips in the connectors.

**Active cables aren't automatically better.** An active cable regenerates the signal, which buys you length. It doesn't buy you speed the cable wasn't already rated for. A long active TB3 cable is still a 40Gb/s cable.

For reference, Apple's own Thunderbolt 4 Pro Cable handles 40Gb/s and 100W. The Thunderbolt 5 Pro Cable handles 120Gb/s and 240W. Both are USB-C at both ends and look near enough identical in a drawer.

## The mistakes worth avoiding

**A 240W cable is not necessarily a fast cable.** EPR charging and high-speed data are separate capabilities. Plenty of 240W cables carry USB 2.0 data and nothing more. They'll charge a MacBook Pro at full tilt and make an external SSD crawl. If a cable is advertised only by wattage, assume the data side is basic.

**An eight-pound "Thunderbolt 5" cable isn't one.** TB5 signalling is unforgiving, so the cable has to be built to much tighter tolerances than a general-purpose USB-C lead. Anything past about a metre needs retimer silicon on top of that, and Intel certification costs money to obtain. Cheap plus TB5 means one of the two claims is false.

**USB4 40Gb/s is not the same as Thunderbolt certified.** They frequently behave identically. Thunderbolt 4 is built on top of USB4, but it makes mandatory a set of things USB4 leaves optional. An uncertified USB4 cable may do everything you need. It just hasn't been tested to prove it.

**In a daisy chain, the weakest cable sets the ceiling.** Chain a dock, a display and a drive together and every device downstream of your worst cable is limited by it. This is the failure mode that produces the most confused support requests, because the problem cable is often the one nowhere near the thing that's misbehaving.

- - -

*Still not sure what's in your drawer? [WhatCable](/) reads the cable, the port, the charger and the connected device, then tells you which one is the bottleneck. Free on Apple Silicon.*

*Related: [Thunderbolt vs USB-C: what the connector hides](/blog/thunderbolt-vs-usb-c)*
