# Remote Access

- Status: Implemented (v0). Verified end to end through the staging room on 2026-10-28; the
  production room isn't deployed yet.
- Scope: working in a Mac's Local Code threads from an iPhone or iPad, over a connection the two
  devices open directly. What goes over that connection is in
  [Remote Access Services](RemoteAccessServices.md).

## Context and decision

Local Code's models are too large for a phone, but the same person's Mac can run them. Remote Access
lets an iPhone or iPad work in the threads of a Mac signed in to the same Local Code account, as on
the Mac. The threads stay on the Mac. In code it's `DeviceLink`.

- **The Local Code account is the group.** Every device signed in to an account joins its room. There
  are no pairing codes and no iCloud Keychain. A new device waits until one already on the account
  allows it.
- **A room only introduces devices.** `Cloudflare/local-code-room`, one Durable Object per account,
  keeps the signed device records and hosts' statuses, relays setup messages, and hands out STUN and
  TURN servers. It never sees what devices say to each other.
- **Devices talk over a WebRTC data channel.** libdatachannel, vendored with Mbed TLS for DTLS
  ([`UPSTREAM.md`](../../../Vendors/libdatachannel/UPSTREAM.md)), finds a path (same network,
  through NAT, or through Cloudflare's TURN relay) and carries one ordered, reliable channel. gRPC
  runs over it, and the Mac never listens on the network.
- **DTLS is the only transport encryption.** Each side's certificate fingerprint is in its signed,
  sealed session description, and a peer whose certificate doesn't match, or that presents none,
  is refused.
- **Devices find each other only through the room.** There are no manual addresses and no Bonjour,
  in any build.

## Overview

```text
 iPhone or iPad                                       Mac (Local Code, Serve on)
 ┌────────────────────────────┐                       ┌────────────────────────────────┐
 │ MacThreadController        │                       │ ThreadsService → ThreadsHub    │
 │   MacConnection            │                       │   (ChatWorkflow: the Mac's     │
 │   LinkClient (gRPC)        │   data channel        │    threads, agent and model)   │
 │   LinkPump ◀───────────────┼── "devicelink/2" ─────┼─▶ LinkPump → LinkServer (gRPC) │
 │   Connector                │   DTLS + SCTP over ICE│   Connector, LinkHost          │
 │   RoomClient               │   (local, direct or   │   RoomClient                   │
 └─────────────┬──────────────┘    TURN relay)        └───────────────┬────────────────┘
               │  WebSocket: signed records and status,               │
               │  sealed setup messages, ICE servers                  │
               └──────────────▶ room.getlocalcode.app ◀───────────────┘
                                one Durable Object per account
                                (checks sign-in with user-accounts;
                                 issues Cloudflare TURN credentials)
```

| Layer | Code | Responsibility |
| --- | --- | --- |
| Data channels | [`Libraries/DataChannel`](../../../Libraries/DataChannel), [`Vendors/libdatachannel`](../../../Vendors/libdatachannel/UPSTREAM.md) | Swift wrapper over libdatachannel's C API. |
| Identity | `DeviceIdentity`, `DeviceKeyStore`, `SignedRecords` in [`Libraries/DeviceLink`](../../../Libraries/DeviceLink) | Device keys, signed device records and host statuses. |
| Setup messages | `SetupMessages` | Signing, sealing and opening offers, answers and candidates. |
| Room | [`Cloudflare/local-code-room`](../../../Cloudflare/local-code-room/README.md), `RoomClient`, `RoomTransport` | The device list, host statuses, message relay and ICE servers. |
| Connections | `Connector` | Opening and accepting data channels through the room. |
| Services | `LinkPump`, `LinkTransport`, `ThreadsHub`, `MacConnection`, `ThreadFiles`, `Protos/v2` | gRPC over a link and the Threads service ([Remote Access Services](RemoteAccessServices.md)). |
| App | `Apps/LocalCode/Sources/DeviceLink`, `ChatWorkflow+Threads.swift`, `ChatWorkflow+MacThreads.swift`, the drawer, Activities | Serving the Mac's threads, showing them on the phone, and the device list. |

## Identity and trust

Each device has two P-256 keys, one for signing and one for key agreement, in the Secure Enclave
where there is one (software keys in the Keychain on the simulator). Its device ID is the hex of the
first 16 bytes of SHA-256 over its signing public key.

- **Records.** A device registers a `DeviceRecord` (public keys, name, platform and role) signed with
  its key, and a host's `HostStatus` is signed the same way. The room stores them unread; every
  device checks the signature, and that the ID matches the key, before using one.
- **Setup messages** (offers, answers and candidates) are signed by the sender and sealed to the
  recipient: an ephemeral P-256 key agreement, HKDF-SHA256 and AES-256-GCM, with the account, sender
  and recipient bound in. Each sender numbers its messages with a rising microsecond clock, and a
  recipient refuses replays and anything outside a 120-second window. The room can't read or change
  them, and doesn't learn the devices' addresses from them.
- **The account is the boundary.** The room checks each device's Local Code sign-in with the
  user-accounts service, and it controls the device list. So a device new to the account waits: it
  sees no other device until one on the account allows it. The account's first device is let in by
  itself. A Mac asks about each new phone or iPad (**Allow**, **Don't Allow**, **Not Now**).
- **Disconnecting is reversible.** Any device can disconnect another, which stays on the list so it
  can be let back. A device can't disconnect or allow itself. A disconnected device stays out until
  another device allows it and its user taps **Connect**, and a Mac closes its links at once.
- **DTLS** uses libdatachannel's self-signed certificate, checked against the fingerprint in the
  sealed description. Refusing a peer that presents no certificate is a local patch; it and the other
  local changes are in [`UPSTREAM.md`](../../../Vendors/libdatachannel/UPSTREAM.md).

## Room

Devices connect to `wss://room.getlocalcode.app/v1/room?device=<device ID>` with their Local Code
access token. Debug builds use `room-staging.getlocalcode.app`, a separate deployment with separate
rooms. Frames, limits and storage are in the [room's README](../../../Cloudflare/local-code-room/README.md).

- **`RoomClient`** publishes the room's state (the connection, and verified devices with their
  status) as a `CurrentValueSubject`. It pings every 30 seconds, and reconnects after a drop with
  backoff (1 to 30 seconds, plus jitter) and at once when the network changes. A phone reconnects
  when the app becomes active. A Mac doesn't: an iPad app on a Mac becomes active on every click
  into its window. A host sends its latest status on every connect.
- **Online** means the connection keeps pinging. While devices are connected, the room closes
  connections that have been silent for 90 seconds, so a device that vanished shows as offline.
- **ICE servers** come from the room: Cloudflare STUN always, and Cloudflare Realtime TURN
  credentials, each valid for 6 hours. Only answers with TURN count against the limit of 200 per
  account per day; past it, the room offers STUN alone until the next UTC day, and when Cloudflare
  gives no credentials, STUN alone for a minute. Devices reuse an answer for
  `ttl - min(600, ttl / 2)` seconds.

## Connections

The phone opens connections; the Mac only accepts them, and only from devices on its verified list.
`Connector.connect(to:)` gets ICE servers, creates a peer connection and a data channel labelled
`devicelink/2`, and sends its sealed offer and candidates through the room. An attempt that hasn't
opened within 10 seconds fails. Accepted links log the selected pair's candidate types (host, srflx,
prflx or relay), and failed attempts log how far they got, never addresses. gRPC then runs over the
link ([Remote Access Services](RemoteAccessServices.md#transport)).

## App

**Mac.** Serving is offered only when the app runs on a Mac (`isiOSAppOnMac`), since iPhones and
iPads suspend apps in the background. Activities has **Serve to my devices**, the connection status,
and the account's phones and iPads. A rail icon shows whether the Mac is serving, waiting for a device,
or answering. While serving, a `ProcessInfo` activity keeps the app working in the background. The
Mac serves its own projects and threads, with its own model, memory, skills and settings. Its name is
its host name, since an iPad app on a Mac only sees "iPad".

**Phone.** The drawer lists each online Mac's projects after the phone's own. A Mac's thread opens in
the chat as the Mac shows it: history, queue and running turn. Sending, the queue, steering and Stop
work as on the Mac, and a new thread in a Mac's project starts on the Mac. The composer shows
"*model* on *Mac*" with the Mac's status. A thread keeps its own model; the model selector offers the Mac's
downloaded models, under the Mac's name, and moves the thread to the one picked. Files the thread made
open from its messages. When the
app goes to the background its links close; turns go on on the Mac, and the phone picks up where it
left off. iPhones don't download local models, so a Mac or a cloud model runs their conversations:
Where Models Run's Remote Access runs the phone's own threads on a Mac's model, the agent and its
tools staying on the phone ([Inference](RemoteAccessServices.md#inference)). Remote Access has no
settings of its own: the model selector has a section for each online Mac with its models, saying
which Mac is answering, so a thread can go to another. Where Models Run on an iPhone is never
unspecified ([Threads](RemoteAccessServices.md#threads)).

**Device list.** Activities lists the devices this one works with: on a phone or iPad, the
account's Macs, the one Remote Access runs on with the model it picked; on a Mac, the account's
phones and iPads. Devices waiting to join or disconnected show on every device. Each is online,
offline, waiting to join, or disconnected; "Answering" follows "Online" for a Mac running a turn,
and, on a Mac, for a device watching one. Each device's menu has the actions that apply:

| Device | Actions |
| --- | --- |
| Online or offline | **Disconnect** (asks first) |
| Waiting to join | **Allow**, **Don't Allow** |
| Disconnected | **Reconnect**; it's in once its user taps **Connect** |

## Privacy and logging

The room learns which devices an account has, their names and platforms, a host's models and load,
and when devices send setup messages and how large they are. It doesn't learn the devices' candidate
addresses or anything said over a link. Like any server it sees the address a device connects from,
and it doesn't log it. Logs on devices and in the room hold states, counts, outcomes, call names,
status codes and candidate types: never account, device or project IDs, addresses, paths, tokens or
message contents.

## Limits

- **UDP only.** libjuice relays over UDP, so TURN over TCP or TLS on port 443 isn't available, and
  networks that block UDP can't connect.
- **Our room and a Local Code account are required.** The app has the room's address built in, the
  room admits a device only with a Local Code sign-in, and the ICE servers come from it. A network
  with no route to the room gets no Remote Access, even with both devices on one Wi-Fi network.
  Self-hosting would need a room the operator runs, its own sign-in, and a way to point the app at it.
- **The Mac must keep Local Code open** with Serve on. One model serves every turn, and the thread
  open on the Mac goes first.
- **Not in v0:** the phone's own tools and projects working with a Mac, interactions a tool asks for
  partway through a turn, and renaming or deleting a Mac's threads from the phone.

## Verification

### Automated

```sh
bazel test //Libraries/DataChannel:DataChannelTests //Libraries/DeviceLink:DeviceLinkTests --test_output=errors --local_test_jobs=1
bazel test //Libraries/DataChannel:DataChannelIOSTests //Libraries/DeviceLink:DeviceLinkIOSTests --test_output=errors --local_test_jobs=1
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
unzip -p bazel-bin/Apps/LocalCode/LocalCode.ipa Payload/LocalCode.app/LocalCode > LocalCode.bin
nm -m LocalCode.bin | grep -E ' _p?poll$'
bazel run --macos_minimum_os=15.0 //Apps/LocalCode:AgentSchedulerHarness -- --scenario background-progress
swift build --target DeviceLink
(cd Cloudflare/local-code-room && npm ci && npm run verify)
```

- **The DeviceLink tests** run a phone and a Mac in one process, through a stand-in room, over real
  libdatachannel links. They cover trust (records, statuses, sealed messages, replays), connection
  setup and refusals, a tampered fingerprint, gRPC over links, the Threads service with a fake
  engine, the phone's connection, and the room client's reconnects, waiting and disconnecting. Relay
  tests connect a phone and a Mac relay-only through a local libjuice TURN server. On macOS they run
  as a `macos_unit_test` built for macOS 15, since NIO and gRPC need it.
- **The `nm` check** should print nothing. OpenSSH's compatibility layer is built with
  `BROKEN_POLL`, and its `pselect`-based `poll` and `ppoll` are renamed to `openssh_poll` and
  `openssh_ppoll`. Under their own names they replaced the system `poll` for libjuice too, with one
  that reports no errors or hangups and fails on descriptors past `FD_SETSIZE`.
- **The scheduler harness's `background-progress` scenario** checks that a background turn reports
  progress only while another device watches its thread.
- **The room's tests** run the Worker and Durable Object in Miniflare.

### End to end

Through the staging room, with an iPhone 17 Pro simulator and this Mac's Local Code build, on
2026-10-26 and 2026-10-28. On 2026-10-28 the simulator ran with `-DeviceLinkRelayOnly YES`, so every
link went through Cloudflare's TURN relay. After each run, the DeviceLink logs on both sides are
checked for anything that looks like an ID, an address, a path or message text.

| Check | Result |
| --- | --- |
| The room hands out TURN | 2 STUN and 2 TURN servers per attempt |
| The phone links through the relay alone | All attempts but one linked within about a second; one timed out after 10 seconds and its retry linked |
| The Mac's projects in the phone's drawer; a new thread from the phone | Listed; the thread started on the Mac |
| A turn answered over the relay | Qwen's answer streamed back in 23 seconds, on one link |
| Stop from the phone | The turn ended on both devices |
| A model picked in the phone's model selector | Selected on the Mac, and its status brought the choice back |
| A send to a thread whose last message went unanswered | Both went as one message |
| The Mac's app is killed mid-turn | The phone relinked a second after the Mac rejoined, and cleared the turn |
| The Mac's app is killed with the phone idle | Composer icon gray within 5 seconds; back 4 seconds after the Mac restarts |
| A Wi-Fi roam drops both room connections | Both rejoined within 35 seconds; the link stayed up |
| The staging room is redeployed mid-run | The run finished; links don't go through the room |
| Disconnect the Mac from the phone | The Mac shows "Disconnected by another device"; the phone lists it as Disconnected |
| A device that vanished without closing its connection | Shown offline after the room's sweep |
| An iPhone's model picker | Lists no undownloaded local models and starts no downloads |

Not yet tested end to end: a physical iPhone or an iPad, a new device waiting to be allowed and the
Mac's prompt, a thread continued back and forth between the devices, the queue and steering, images
and files from the phone, going over the day's TURN limit, Wi-Fi to cellular, Mac sleep and wake, two
phones or two Macs, and networks in mainland China.
