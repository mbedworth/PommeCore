//
//  HelpCatalog.swift
//  PommeCore
//
//  The manual's content. See `HelpTopic.swift` for why it lives in a registry.
//
//  ## House rules for writing a topic
//
//  **Say what the radio does, not what the screen looks like.** A sentence
//  about a button moves when the button moves; a sentence about flood routing
//  stays true. Screens change far more often than the protocol does.
//
//  **State a threshold once, here, and never a second time in prose.** Where a
//  number is enforced in code, cite it as a `.fact` so the two sit next to
//  each other and a mismatch is visible.
//
//  **Mark firmware limits as firmware limits.** A user who knows a thing is
//  the radio's behaviour rather than the app's does not waste an evening
//  looking for the setting that turns it off.
//
//  **No feature names without the concept.** "Enable path reset" means
//  nothing to someone who has not met routing yet; that is what `related` is
//  for.
//

import Foundation

enum HelpCatalog {

    /// Every topic, in reading order within each chapter.
    static let topics: [HelpTopic] = concepts + using + troubleshooting

    static func topic(id: String) -> HelpTopic? {
        topics.first { $0.id == id }
    }

    static func topics(in chapter: HelpChapter) -> [HelpTopic] {
        topics.filter { $0.chapter == chapter }
    }

    // MARK: - How the Mesh Works

    private static let concepts: [HelpTopic] = [

        HelpTopic(
            id: "mesh-basics",
            chapter: .concepts,
            title: "What a Mesh Network Is",
            summary: "Your messages travel radio to radio, with no phone network and no internet.",
            symbol: "point.3.connected.trianglepath.dotted",
            body: [
                .paragraph("PommeCore talks to a small LoRa radio over Bluetooth, WiFi or USB. That radio is what reaches other people — not your phone. If there is no mobile signal and no internet anywhere in sight, the mesh still works."),
                .paragraph("Radios pass messages along for each other. A message that cannot reach its destination directly is carried by whatever radios sit in between, each one repeating it onward. Nobody needs to run a server and there is no account to sign in to."),
                .paragraph("The cost of that independence is bandwidth. LoRa is extraordinarily good at distance and extraordinarily slow — think text messages, not photographs. Everything else in this manual follows from that one fact."),
                .note("Range depends on terrain far more than on power. A hilltop radio with a clear view can beat a valley radio many times its strength.")
            ],
            related: ["routing-paths", "airtime"]
        ),

        HelpTopic(
            id: "routing-paths",
            chapter: .concepts,
            title: "Flood and Direct Routing",
            summary: "A new message is shouted to everyone; once a route is known it is sent along that route.",
            symbol: "arrow.triangle.branch",
            body: [
                .paragraph("When your radio does not yet know how to reach someone, it floods: the message goes out to every radio in earshot, each of which passes it on. That finds the destination without anyone configuring anything, but it uses the airtime of every radio it touches."),
                .paragraph("Once a message gets through, the route it took is remembered. Later messages are sent direct along that known path, which is faster and far quieter. This is why the second message to a new contact often arrives more quickly than the first."),
                .paragraph("Paths go stale. People move, radios are switched off, batteries die. When a known path stops working, the path is reset and the next message floods again to discover a new one."),
                .fact(label: "Auto", value: "No stored path. The next message floods to discover one."),
                .fact(label: "Flood", value: "Flooding deliberately, rather than because no path is known."),
                .note("You can reset a path yourself from a contact. It is the right first move when messages to someone that used to work have stopped arriving.")
            ],
            related: ["delivery", "message-not-delivered", "airtime"]
        ),

        HelpTopic(
            id: "infrastructure",
            chapter: .concepts,
            title: "Repeaters and Room Servers",
            summary: "Two kinds of always-on node: one extends range, the other stores messages.",
            symbol: "antenna.radiowaves.left.and.right",
            body: [
                .paragraph("A repeater is a radio left running somewhere useful — a roof, a hill, a mast. It takes part in carrying other people's messages and nothing else. Most of a mesh's usable range comes from a handful of well-placed repeaters."),
                .paragraph("A room server holds messages. People post to it and read what others posted, so a conversation survives everyone being out of range at different times. It is closer to a notice board than to a group chat."),
                .paragraph("Both are infrastructure rather than people, and PommeCore treats them that way: they are grouped separately from your contacts, they are judged active on a slower clock, and some of them can be administered remotely if you hold the password."),
                .note("A repeater's location is always shared exactly, never obscured. Routing depends on knowing where it is.")
            ],
            related: ["contact-status", "infrastructure-tidy", "privacy-location"]
        ),

        HelpTopic(
            id: "adverts",
            chapter: .concepts,
            title: "How Contacts Appear",
            summary: "Radios announce themselves with adverts — but your own radio only does so when you ask.",
            symbol: "dot.radiowaves.up.forward",
            body: [
                .paragraph("A radio makes itself known by sending an advert: a small packet carrying its name, public key and type. Hearing one is how a contact appears in your list without anyone exchanging anything by hand."),
                .paragraph("Repeaters and room servers advertise on a timer, because being findable is their job. A companion radio like yours does not: it sends an advert only when you ask it to. Nothing about your radio goes out over the air on its own."),
                .paragraph("That asymmetry matters when you are waiting to be found. If someone cannot see you, the fix is usually that you have not advertised, not that anything is broken."),
                .fact(label: "Repeater advert", value: "Every 60 to 240 minutes, to immediate neighbours."),
                .fact(label: "Repeater flood advert", value: "Every 3 hours at the earliest, across the mesh."),
                .fact(label: "Your radio", value: "Only when you ask. Never automatically.")
            ],
            related: ["missing-contacts", "privacy-location", "airtime"]
        ),

        HelpTopic(
            id: "airtime",
            chapter: .concepts,
            title: "Airtime Is the Scarce Resource",
            summary: "Every radio shares one slow channel, so restraint is what keeps a mesh usable.",
            symbol: "gauge.with.needle",
            body: [
                .paragraph("All the radios on a frequency share it. Only one can transmit at a time, and LoRa transmissions are long — a single message can occupy the channel for a noticeable fraction of a second. A busy mesh does not slow down gracefully; it starts losing messages."),
                .paragraph("Most regions also cap how much of each hour a transmitter may be active, and the radio enforces that itself. If you have sent a great deal very quickly, the radio may simply decline to transmit until its budget recovers."),
                .paragraph("This is why PommeCore has no button that polls every sensor at once, and why asking for telemetry is something you do per node. A convenience that quietly costs the whole mesh its airtime is not a convenience."),
                .note("Flooding uses the airtime of every radio that hears it, not just yours. It is the most expensive thing the mesh does.")
            ],
            related: ["routing-paths", "telemetry"]
        )
    ]

    // MARK: - Using PommeCore

    private static let using: [HelpTopic] = [

        HelpTopic(
            id: "connecting",
            chapter: .using,
            title: "Connecting Your Radio",
            summary: "Bluetooth, WiFi or USB — whichever your radio and platform support.",
            symbol: "cable.connector",
            body: [
                .paragraph("Bluetooth is the usual choice and works on every platform. The app reconnects to a radio it already knows by itself, including after the radio has been out of range or switched off, so an unexpected disconnection does not need any action from you."),
                .paragraph("WiFi suits a radio left at a fixed location on your own network. USB is a wired connection for a radio on the desk."),
                .paragraph("Bluetooth permission is asked for the first time you connect, not when the app starts, so you can look around before granting anything."),
                .fact(label: "Bluetooth", value: "iPhone, iPad, Mac."),
                .fact(label: "WiFi", value: "iPhone, iPad, Mac."),
                .fact(label: "USB Serial", value: "Mac only. iOS provides no API for it."),
                .note("A Mac disconnects cleanly before sleeping. Without that the radio keeps holding the old connection and refuses the next one, so let the disconnection happen rather than forcing it.")
            ],
            related: ["radio-wont-connect"]
        ),

        HelpTopic(
            id: "messages-vs-channels",
            chapter: .using,
            title: "Direct Messages and Channels",
            summary: "A direct message is to one person and confirmed; a channel is to everyone and is not.",
            symbol: "bubble.left.and.bubble.right",
            body: [
                .paragraph("A direct message is encrypted to one contact and nobody else can read it. The mesh tells you when it arrives, so a direct message is the right choice when it matters that it got there."),
                .paragraph("A channel is shared. Everyone holding the channel's key can read everything posted to it, which makes it the natural place for announcements and for talking to a group. Channels are sent and forgotten: there is no delivery confirmation at all, and a message shown as sent means it left your radio, not that anyone received it."),
                .paragraph("A channel is defined by its name and its key together. Two people with the same name but different keys are not on the same channel, which is usually what has happened when a channel looks right but nothing arrives."),
                .fact(label: "Direct message", value: "One recipient, encrypted, delivery confirmed."),
                .fact(label: "Channel", value: "Everyone with the key. No delivery confirmation."),
                .note("Share a channel by its QR code or link rather than by typing the key. Keys are long and a single wrong character fails silently.")
            ],
            related: ["delivery", "message-not-delivered"]
        ),

        HelpTopic(
            id: "delivery",
            chapter: .using,
            title: "Knowing a Message Arrived",
            summary: "Direct messages are acknowledged by the recipient's radio. Channels are not.",
            symbol: "checkmark.message",
            body: [
                .paragraph("When a direct message reaches its destination, the receiving radio sends back an acknowledgement and the message is marked delivered. That confirmation comes from the radio, so it means the message arrived — not that anybody has read it."),
                .paragraph("If no acknowledgement comes back, the app tries once more along the known path, and if that also fails it resets the path and floods. A message that eventually arrives by flooding usually looked stuck for a while first."),
                .paragraph("Delivery can take a long time without anything being wrong. The recipient's radio may be asleep, out of range, or waiting on its airtime budget. Slow is normal on a mesh; silent is the thing to investigate."),
                .fact(label: "Direct attempt", value: "One retry along the known path, about 30 seconds."),
                .fact(label: "Then", value: "The path is reset and the message floods."),
                .note("Channel messages are never acknowledged. This is how the protocol works and not something that can be switched on.")
            ],
            related: ["routing-paths", "message-not-delivered", "messages-vs-channels"]
        ),

        HelpTopic(
            id: "contact-status",
            chapter: .using,
            title: "What the Status Colours Mean",
            summary: "How recently a radio was last heard from — on a slower clock for infrastructure.",
            symbol: "circle.lefthalf.filled",
            body: [
                .paragraph("Each contact carries a colour for how recently the mesh last heard from it, counting adverts, delivered messages and received messages alike — whichever happened most recently."),
                .paragraph("Infrastructure is judged more leniently than people. A repeater that has said nothing for two hours is behaving normally; a person's radio that has said nothing for two hours may well be off."),
                .fact(label: "Green", value: "A person within the hour, infrastructure within six."),
                .fact(label: "Yellow", value: "A person within six hours, infrastructure within twelve."),
                .fact(label: "Grey", value: "A person within a day, infrastructure within two."),
                .fact(label: "Red", value: "Longer than that."),
                .note("A grey contact is not unreachable. It means nothing has been heard recently, which for a radio that only speaks when spoken to is unremarkable.")
            ],
            related: ["adverts", "infrastructure", "infrastructure-tidy"]
        ),

        HelpTopic(
            id: "infrastructure-tidy",
            chapter: .using,
            title: "Keeping the Contact List Tidy",
            summary: "Infrastructure folds away by type, and contacts that stopped answering can be cleaned up.",
            symbol: "rectangle.3.group",
            body: [
                .paragraph("Repeaters, room servers and sensors are collected into their own collapsed groups, one per type, below your contacts. Travel through a well-covered area and you can pick up a great many of them; folded away, they stay available without burying the people you actually talk to."),
                .paragraph("Optional cleanup removes contacts nothing has been heard from for a period you choose. Nothing is ever deleted without being shown to you first — the app proposes a list and you confirm it."),
                .paragraph("Cleanup also refuses to touch anything that looks deliberate. A contact you renamed, annotated, put in a group, exchanged messages with, or marked to keep is left alone however long it has been quiet."),
                .fact(label: "Off", value: "Nothing is ever proposed."),
                .fact(label: "Infrastructure only", value: "Repeaters and sensors. People are never proposed."),
                .fact(label: "Every contact", value: "Anything quiet for longer than the period, except what is protected."),
                .note("Marking a contact to keep exempts it permanently, and that mark syncs across your devices. Use it for the repeater you rely on but rarely hear from.")
            ],
            related: ["contact-status", "infrastructure"]
        ),

        HelpTopic(
            id: "telemetry",
            chapter: .using,
            title: "Telemetry and Sensors",
            summary: "Ask a node for its readings. Not every node will answer.",
            symbol: "thermometer.medium",
            body: [
                .paragraph("Many radios can report their own condition — battery, voltage, temperature — and some carry sensors beyond that. Readings are requested from one node at a time and kept on your device, so the dashboard has history to show even when nothing is in range."),
                .paragraph("Whether a node answers is the node's decision, not yours. A radio with telemetry sharing switched off simply does not reply, and there is no way to tell that apart from a radio that is out of range."),
                .paragraph("The dashboard reads from stored history and never polls on its own. Readings arrive because you asked for them, which keeps a screenful of sensors from becoming a burst of traffic across the mesh."),
                .fact(label: "History kept", value: "Seven days on the device."),
                .note("Detailed status can only be requested from infrastructure. An ordinary contact's radio will not answer a status request, and that is a firmware limit rather than a setting.")
            ],
            related: ["airtime", "infrastructure"]
        ),

        HelpTopic(
            id: "privacy-location",
            chapter: .using,
            title: "Location and Privacy",
            summary: "Your own position can be deliberately imprecise. A repeater's never is.",
            symbol: "location.slash",
            body: [
                .paragraph("Sharing a position is useful and is also the most sensitive thing the app transmits, so your own location can be blurred before it is sent. The mesh learns roughly where you are without learning exactly."),
                .paragraph("That blurring applies only to your own radio. Repeaters and room servers always report exact coordinates, because routing and coverage depend on knowing where they really are — and because they are fixed installations, not people."),
                .paragraph("Direct messages are encrypted to their recipient. Channel messages are readable by everyone holding the channel key, so treat a channel as public to its members and nothing narrower."),
                .note("Anything you put on a channel reaches every holder of that key, including people who joined long before you and are no longer around.")
            ],
            related: ["messages-vs-channels", "infrastructure"]
        )
    ]

    // MARK: - When Something Is Wrong

    private static let troubleshooting: [HelpTopic] = [

        HelpTopic(
            id: "message-not-delivered",
            chapter: .troubleshooting,
            title: "A Message Will Not Deliver",
            summary: "Usually a stale path, a sleeping radio, or a channel that was never acknowledged in the first place.",
            symbol: "exclamationmark.bubble",
            body: [
                .paragraph("First, check whether the message was ever going to be confirmed. Channel messages are not acknowledged at all, so one showing as sent tells you nothing about whether it arrived. Only direct messages report delivery."),
                .paragraph("For a direct message, give it time. The app retries along the known path and then floods, and a message that eventually arrives can look stuck for a minute or more while that plays out."),
                .bullets([
                    "Reset the path to that contact, then send again. A remembered route that no longer exists is the most common cause.",
                    "Check the contact's status colour. A radio nothing has been heard from in a day may simply be switched off.",
                    "Send your own advert, so the other radio knows how to answer you.",
                    "If every contact is failing rather than one, the problem is your own radio or its connection, not routing."
                ]),
                .note("A message to someone who has moved out of range is not lost, but nothing can deliver it until a route exists again.")
            ],
            related: ["routing-paths", "delivery", "contact-status"]
        ),

        HelpTopic(
            id: "radio-wont-connect",
            chapter: .troubleshooting,
            title: "The Radio Will Not Connect",
            summary: "Most often the radio is still holding a previous connection.",
            symbol: "bolt.horizontal.circle",
            body: [
                .paragraph("A MeshCore radio accepts one connection at a time. If something else still holds it — another device, another app, or this app on a computer that slept without disconnecting — a new connection is refused and the failure looks like a broken radio."),
                .bullets([
                    "Make sure nothing else is connected to the radio, including PommeCore on your other devices.",
                    "Power the radio off and on. That clears a connection it is still holding.",
                    "After a Mac wakes from sleep, allow a few seconds before expecting the radio back; the Bluetooth stack needs to settle first.",
                    "Check that Bluetooth permission was granted. It is requested on first connection, so it is easy to have dismissed."
                ]),
                .note("Quit any other MeshCore tool before connecting. A command-line client holds the radio just as firmly as the app does.")
            ],
            related: ["connecting"]
        ),

        HelpTopic(
            id: "missing-contacts",
            chapter: .troubleshooting,
            title: "Nobody Is Showing Up",
            summary: "An empty contact list usually means wrong radio settings, or that nobody has advertised yet.",
            symbol: "person.fill.questionmark",
            body: [
                .paragraph("Contacts appear when their adverts are heard. Hearing nothing at all points at the radio settings rather than at the mesh: radios only hear each other when frequency, bandwidth, spreading factor and coding rate all match exactly."),
                .paragraph("A single wrong value makes a radio deaf while looking perfectly healthy, which is why a preset shared by your local mesh is worth more than settings assembled by hand."),
                .bullets([
                    "Compare your radio settings against the preset your local mesh uses.",
                    "Send your own advert. Companion radios never advertise by themselves, so nobody can see you until you do.",
                    "Be patient near a repeater — its flood advert may be up to three hours away.",
                    "Check the frequency is one you are permitted to use where you are; the radio will not transmit outside it."
                ]),
                .note("Being able to hear others but not be heard is normal if you have never advertised. It is not a fault.")
            ],
            related: ["adverts", "mesh-basics"]
        )
    ]
}
