---
title: Why is my MacBook charging so slow? A real diagnosis.
slug: why-is-my-macbook-charging-so-slow
date: 2026-05-21
summary: macOS now tells you when your charger is slow. It doesn't tell you why.
  Here's how to actually work out what's holding back your MacBook charging.
category: Guides
coverImage: https://images.whatcable.uk/1779372798303-macbook-magsafe.jpg
coverAlt: A MacBook connected to power with a MagSafe cable
ctaTitle: See what your Mac is actually receiving.
ctaText: WhatCable shows the charger, cable rating and live power state so you can identify the limiting part.
ctaHref: /
ctaLabel: Download WhatCable
tags:
  - charging
  - power-delivery
  - usb-pd
  - charging-cable
faqs:
  - q: Why is my MacBook Air charging so slow?
    a: The MBA minimum is 30W. If you're using a 20W iPhone adapter (very common
      pattern, since they look identical), you'll charge but it'll be slow under
      any real load. Swap to a 30W or higher adapter and a cable that's at least
      60W rated, and you should see normal speeds.
  - q: How do I make my MacBook charge faster?
    a: Match all three links in the chain. Adapter at or above Apple's minimum for
      your model. Cable rated for at least the adapter's wattage. A clean port
      that seats the connector firmly. Close anything heavy that's pulling
      power. If Optimised Charging is parking you at 80%, override it.
  - q: How long should it take to charge a MacBook Pro?
    a: With a properly matched adapter and cable, roughly 0 to 50% in half an hour
      on the 14" and 16" models, and full charge in around 2 hours.
      Significantly longer than that and something in the chain isn't delivering
      full capability.
---
In macOS Tahoe 26.4, Apple added a "Slow Charger" label. Plug in a charger that can't deliver full power and the menu bar tells you so.

What it doesn't tell you is why.

That's the gap. The OS confirms what you already suspected (yes, it's charging slowly) and then leaves you to guess whether the problem is the adapter, the cable, the port, the battery, or the laptop itself. Most of the time it's one of two things, and both are easy to confirm if you know where to look.

## The actual causes, in order of how often they happen

### 1. The adapter doesn't have enough watts for your Mac

This is the most common cause by a long way. Apple publishes minimum wattage figures for each MacBook and they're not suggestions, they're the floor for full-speed charging. Anything below the minimum and the Mac throttles down to whatever it can pull.

The rough numbers, from [Apple's adapter guide](https://support.apple.com/en-us/109509):

* **MacBook Air (M-series):** 30W minimum
* **MacBook Pro 14":** 70W for the base chip, 96W for Pro/Max
* **MacBook Pro 16":** 140W

A 30W adapter charging a 16" MBP will work, but it'll feel like it's not charging at all under load. Sometimes the battery still drains because the Mac is using more than the adapter can supply.

How to confirm: check the wattage printed on the adapter itself. If it's below the minimum, that's your answer.

### 2. The cable is rated below the adapter

This one trips up a lot of people because the adapter and the Mac are both capable, but the cable in the middle is the bottleneck.

USB-C cables carry an e-marker chip that declares what they can handle. A cable rated for 60W (3A at 20V) physically cannot pass 96W (4.7A at 20V) no matter what the adapter or the laptop ask for. The PD negotiation drops to whatever the weakest link supports.

The giveaway: you bought a 96W or 140W charger, the Mac is the right model, and charging is still slow. Nine times out of ten it's the cable. Especially if it's the cable that came in the box with something else, or a generic spare from a drawer.

How to confirm: this is where it gets fiddly without help. The cable's rating is usually not printed on the cable. You can't see the e-marker contents from the Finder or from System Information. We'll come back to this.

### 3. Optimised Battery Charging is holding at 80%

macOS learns your routine and parks the battery at 80% if it thinks you're about to leave it plugged in for hours. From its perspective this is a feature, since holding at 80% is much kinder to long-term battery health than sitting at 100% all day.

From your perspective it looks like the charger isn't doing its job.

How to confirm: System Settings → Battery → Battery Health → check the charging schedule. If Optimised Charging is on and the battery is sitting at exactly 80%, that's the cause. Click "Charge to Full Now" if you actually need it now.

### 4. The workload is outpacing the supply

If you're rendering video, compiling a large project, or running a sustained GPU load on a 14" or 16" MBP, you can genuinely draw more than the adapter delivers. The battery makes up the difference and the percentage creeps down despite being plugged in.

How to confirm: open Activity Monitor → Energy tab → look at Energy Impact. If you're maxing out CPU or GPU, you're not going to charge while doing it on a 30W or 70W adapter.

### 5. Dirty port, damaged cable, hardware fault

The boring causes, but they happen. A USB-C port full of pocket lint won't seat the connector properly and the contacts won't make. A cable that's been kinked too many times near the connector can lose one of its conductors and drop from 96W to 60W (or worse) without looking obviously broken.

How to confirm: try a different port on the same Mac. Try the same charger and cable on a different Mac if you can. If you get fast charging on a different port but not the original, the port's the problem. If you can't see anything obvious in the port, a wooden toothpick (never metal) is the safe tool for clearing lint.

If you're on an Intel Mac and you've exhausted everything else, an SMC reset is the next step. On Apple Silicon there's nothing to reset, it's all handled differently.

## How to actually check what's happening

The diagnostic question that matters: what is the cable, adapter, and Mac actually negotiating right now?

USB Power Delivery is a conversation. The adapter says "I can offer 5V/3A, 9V/3A, 15V/3A, 20V/4.7A." The Mac picks the highest its battery can accept. The cable's e-marker sets the ceiling on current. They agree on a contract, and that contract is what determines your charging speed.

macOS knows all of this. It reads the e-marker, it tracks the active PD contract, it knows what each port can do. It just doesn't surface any of it.

This is what [WhatCable](/) was built for. It sits in the menu bar and reads what macOS already has, then tells you in English:

* The cable's e-marker rating (max watts, max current, max data speed)
* The active PD contract (volts and amps being negotiated right now)
* What the port itself can do
* Where the bottleneck is, if there is one

![WhatCable showing the active PD contract at 20V and 2.99A (60W), alongside the cable's e-marker rating, confirming the cable is not the bottleneck](https://images.whatcable.uk/1779373950977-screenshot-2026-05-19-at-22-02-19.webp "WhatCable reading the active power contract and cable e-marker")

A healthy reading on a 16" MBP with a 140W adapter and a 240W USB4 cable: 28V at 5A, cable rated for 240W, port rated for 140W. Everything matches.

A throttled reading on the same setup but with a wrong cable: 20V at 3A, cable rated for 60W, port still rated for 140W. The cable is the bottleneck and you can see it.

That's the answer to "why is it slow." You can stop guessing.

- - -

If you want to see exactly what your own setup is negotiating, [WhatCable](/) reads the PD contract and the cable e-marker and shows it in the menu bar. The Slow Charger Indicator tells you there's a problem. WhatCable tells you which link in the chain caused it.
