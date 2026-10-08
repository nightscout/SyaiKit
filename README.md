# SyaiKit

Trio/Loop CGM Driver for Syai Ultra.

**Currently Supported Models:**

- Syai Ultra (X1), firmware V1.6 and V1.7
- Syai Ultra (X1), firmware V1.8 and V2.0 (supported, but not yet tested)

> Note: In some countries an older sensor sold under the **Syai Tag** name
> (model number currently unknown) may still be available. This is **not
> tested and may not be supported**. Compatibility depends entirely on its
> firmware version. If you have one, please open a GitHub issue with the
> firmware/device version shown in the official Syai app so it can be looked
> into.

## Account required

Syai sensors are read through your own Syai account, the same one you'd use
in the official Syai app. You'll be asked to log in during setup. Trio talks
to the sensor and your account directly. The official Syai app doesn't need
to be involved once you're paired, and shouldn't be connected to the sensor
at the same time as Trio (see Troubleshooting below).

During setup you'll also be asked whether to share the same usage data with
Syai that their own app would normally send. Keeping this on helps if you
ever need warranty or support from Syai; you can change this later in
Settings → Account → Data Sharing.

## Troubleshooting

In case an issue is not covered by the FAQ below please reach out on Trio Discord or open a GitHub issue.

Please make sure to attach your logs when you file a report. You can find
them by going to the Syai settings menu and pressing the "Share Syai logs"
button.

## Frequently Asked Questions

**Q: There is a gap in my readings, what is happening?**

A: The sensor's Bluetooth connection can drop occasionally; Trio reconnects
automatically and backfills what it missed. If Settings shows a sensor error
instead, the sensor itself has reported a fault and will need to be
replaced.

**Q: Can I use the official Syai app alongside Trio?**

A: No. The sensor can only talk to one device at a time. It is not possible to run the Syai app along side Trio.

## More Information

For more information please join the Trio Discord: https://discord.triodocs.org/

## Position and disclaimer

SyaiKit is an **independent, community-driven open-source project**. It is
not affiliated with, endorsed by, or supported by Syai Health Technology Pte.
Ltd. The goal is interoperability with a device you already own, under your
own account. 

**This is experimental software under active development.** Automated
insulin dosing is a safety-critical activity. Use at your own risk, keep a
working fallback therapy available, and never dose on readings you have
reason to doubt.

## License

MIT — see [LICENSE](LICENSE).
