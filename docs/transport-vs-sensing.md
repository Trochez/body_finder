# Transport vs. sensing in Body Finder

Body Finder separates **coordination transport** from **physical sensing**.

## Coordination transport

LAN connectivity (Wi-Fi or Ethernet) is used only to:

- discover and maintain session membership;
- elect a coordinator;
- exchange timestamps, capabilities, range observations, calibration state, and future anomaly measurements;
- move computation/logging traffic between nodes.

LAN heartbeat timing, Ethernet packets, IP latency, and ordinary session traffic are **not physical ranging measurements** and must never be converted into meters or body/anomaly evidence.

## Physical sensing and ranging

Only validated sensor/radio observations may contribute to physical geometry or anomaly detection. Examples include:

- UWB ranging where the public platform API exposes a valid measurement;
- Wi-Fi RTT/FTM where supported;
- BLE RSSI as a coarse, high-uncertainty fallback;
- compatible external ranging/sensing hardware;
- future validated RF/acoustic measurements with explicit evidence and uncertainty.

A node connected only by Ethernet can still act as a coordinator, logger, compute node, or relay, but its **sensing contribution is zero** unless that same device exposes another usable physical sensor/radio.

## Safety invariant

Transport-only nodes must not increase sensing confidence, observability, range-edge count, or body/anomaly evidence. They may improve network reliability and computation capacity only.
