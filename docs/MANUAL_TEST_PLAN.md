# ClashMax Manual Test Plan

Line items that automation cannot reach, each signed off by hand before the roadmap item
it belongs to is called done. The recurring failure mode this file exists to stop is named
in [`ROADMAP.md`](ROADMAP.md) §4 D3: *"tests pass, never seen by eye."*

Sign off by filling in the table at the bottom of the item: date, build, and what was
actually observed. "Suite is green" is not a sign-off — every item here is written so that
the observation, not the test result, is the evidence.

Related by-hand gates that already have their own documents: [`TUN_SMOKE_TEST.md`](TUN_SMOKE_TEST.md)
for installed-bundle routing, [`MENU_BAR_RICH_PANEL_QA.md`](MENU_BAR_RICH_PANEL_QA.md) for
the menu bar panel.

---

## A1 — A domainless connection is diagnosed and repaired end to end

Covers [`ROADMAP.md`](ROADMAP.md) A1e. The claim under test is the whole point of A1: a
connection opened straight to an IP carries no domain, a `DOMAIN-SUFFIX` rule written for
it therefore never fires, and ClashMax can now say so and fix it in one click.

Automation already covers the mechanical half — the generated `sniffer` block is validated
by the bundled core across 5 config sources x 3 routing modes x 3 DNS modes x 3 sniffer
modes in `CoreRuntimePreflightTests`, and the classifier has one test per cause in
`SnifferDiagnosticsTests`. What no test can show is whether the user is told the right
thing at the moment they are confused.

### Setup

1. Run in **TUN mode**. This is where the case exists: under System Proxy an app that
   speaks to the proxy hands over a hostname, so the domainless connection never appears.
2. Add a rule that can only match on a name, above whatever currently wins, e.g.
   `DOMAIN-SUFFIX,example.com,<some proxy group>`.
3. Turn sniffing **off** for the first half of the run (Connections → the fix button will
   turn it back on; to start from off, either use a profile that ships `sniffer: {enable: false}`
   or apply a `Sniffer Off` snippet).
4. Generate the traffic without letting the client resolve a name through the proxy:

   ```sh
   IP=$(dig +short example.com | tail -1); openssl s_client -connect "$IP:443" -servername example.com </dev/null
   ```

   The name is resolved outside the tunnel and the IP is dialed directly, while the SNI
   still carries the name — exactly the shape of an app with a hardcoded IP. Resolve it
   rather than pasting a literal: example.com has changed addresses before.

### Steps and what to look for

1. **Connections page.** Find the row for that connection. Its Host column shows the
   destination IP, not `example.com`, and the chain shows the rule that actually won —
   not the `DOMAIN-SUFFIX` rule.
2. Select the row. Below **Why This Rule**, the **Domain Visibility** section reads
   *"No domain, sniffing is off"*, and the reason names the destination and states that
   `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD` and `GEOSITE` rules cannot match it.
   **Match Without Domain** names the rule that did win.
3. Press **Turn On Sniffing**. The apply outcome appears in place of the button, and the
   runtime apply banner reports the same outcome. The core is not restarted.
4. Re-select the same, still-open connection. The verdict now reads *"No domain, opened
   before the current settings"* — an `.info`, not a failure. The settings changed after
   the connection was opened, so they say nothing about it. **This is the regression
   guard**: if this row instead claims sniffing covers it and still recovered no name, the
   fix has manufactured a false verdict about the row it just repaired.
5. Run the `openssl` command again. On the **new** connection: the Host column now shows
   `example.com`, the chain shows the `DOMAIN-SUFFIX` rule, and Domain Visibility is a
   pass — with **Match On Domain** and **Match Without Domain** side by side, which is the
   before/after the user came to see.
6. **Routing page.** From the connection's row menu choose **Open in Routing**. Under the
   connection explanation, after **Local Result**, the same verdict appears as **Domain
   Visibility** / **Reason** / **Suggested Fix** rows, carrying the values frozen at
   hand-off (they must not change if the connection has since closed).
7. Repeat step 2 with the app language set to **Simplified Chinese**. Every string in the
   section is translated; nothing renders in English.

### Sign-off

| Date | Build | Observed |
| --- | --- | --- |
|  |  |  |

---

## B5 — A stale geo database is named, and refreshing it is honest about what happened

Covers [`ROADMAP.md`](ROADMAP.md) B5. The claim under test is that ClashMax can now say
*"your `GEOIP,CN` rules have been matching a four-month-old snapshot"* — and, harder, that
after pressing the button it reports what actually changed on disk rather than echoing a
status code back at the user.

This is the item where automation is least persuasive. Every branch of
`GeoDatabaseDiagnosticsBuilder` has a test, but a test cannot show that the panel is looking
at the *right directory* on a real install, and the whole feature is a claim about files.

### Setup

1. A profile whose rules include at least one `GEOIP,` and one `GEOSITE,` rule. Most
   subscriptions ship both; confirm on the Routing page rather than assuming.
2. Start the core and let it come up. On first start with geo rules it downloads the
   databases, so a genuinely fresh install shows the "current" state, not the interesting one.
3. To reach the stale state without waiting months, backdate the files by hand:

   ```sh
   touch -t 202604010000 ~/Library/Application\ Support/ClashMax/Runtime/GeoSite.dat ~/Library/Application\ Support/ClashMax/Runtime/geoip.metadb
   ```

### Steps and what to look for

1. **Routing page → inspector → Geo Databases.** With automatic updates off, the headline
   reads *"Geo databases are out of date"* as a **warn**, and the reason names how long ago
   the oldest database in use was written. Confirm the age it reports matches the `touch`
   above — a panel reading the wrong directory would say "not downloaded" instead.
2. Check the **Database** fact names the file the current `geodata-mode` actually uses:
   `geoip.metadb` with the mode off, `GeoIP.dat` with it on. Toggle the mode in
   Settings → Geo Databases → Configure and confirm the named file changes with it. This is
   the trap the implementation exists to avoid: measuring the age of a file the core is not
   reading.
3. Press **Update Now**. While it runs the button becomes a spinner and *"Downloading through
   the core; this can take a while."* appears next to it. The core downloads through its own
   rules, so this genuinely can take tens of seconds.
4. On success the status line reads **"Updated <file names>."**, naming the files that were
   actually rewritten, and the headline flips to *"Geo databases are current"*. Verify against
   the filesystem — the `ls -la` timestamps must match:

   ```sh
   ls -la ~/Library/Application\ Support/ClashMax/Runtime/ | grep -iE 'geo|asn'
   ```
5. **Press Update Now a second time, immediately.** This is the regression guard. The core
   sends `If-None-Match`, gets a 304, writes nothing, and still answers `204`. The panel must
   read **"The geo databases were already current."** — not "Updated". A build that reports
   the second press as a fresh download is reporting a status code, which is the exact defect
   this criterion was written against.
6. **Failure path.** Point one source at a host that cannot resolve (Settings → Geo
   Databases → Configure → Sources) and press Update Now. The headline becomes *"Geo database
   update failed"*, and the reason quotes the core's own message rather than "HTTP 500".
   Confirm with `ls -la` that the existing files are **untouched** — same timestamps, same
   sizes as step 4.
7. Restore defaults in the popover, save, and confirm the runtime YAML carries the settings:

   ```sh
   grep -A6 'geox-url' ~/Library/Application\ Support/ClashMax/Runtime/config.yaml
   ```

   The sub-keys must read `geoip` / `geosite` / `mmdb` / `asn`. If they ever render as
   `geo-ip` / `geo-site`, the core will silently ignore them and keep its built-in URLs.
8. Turn **Update Automatically** on, save, and confirm `geo-auto-update: true` and
   `geo-update-interval` land in the same file.
9. Repeat step 1 with the app language set to **Simplified Chinese**. Every string in the
   panel and the popover is translated; nothing renders in English.

### Sign-off

| Date | Build | Observed |
| --- | --- | --- |
|  |  |  |

---

## A3 — A stale fake-ip table is diagnosed, and flushing it is offered only when it means something

Covers [`ROADMAP.md`](ROADMAP.md) A3. The claim under test is that the flush action appears
as a *fix for a named problem* rather than as a button that is always there, and that it is
disabled — with an explanation — whenever the core holds no fake-ip table at all.

### Setup

Run in **TUN mode** with **Fake IP DNS** on. That is the only configuration where the
feature has any meaning, and step 2 checks that the app says so in the others.

### Steps and what to look for

1. **Routing page → inspector → Fake IP.** With the core running in fake-ip mode and nothing
   having changed since it started, the headline reads *"Fake IP is active"* as a **pass**,
   the facts show **Enhanced Mode: fake-ip** and the **Fake IP Range**, and **Flush Fake IP
   Cache** is enabled.
2. Turn Fake IP DNS **off** and reapply. The headline becomes *"Not in fake-ip mode"* as an
   **info**, the reason names the actual `enhanced-mode` value, and the flush button is
   **visible but disabled**, with the reason as its tooltip on hover. Confirm it is not
   hidden — the criterion is that a user who goes looking for the control finds it and finds
   out why it will not fire.
3. Stop the core. The headline becomes *"No fake-ip table"*; the button stays disabled.
4. Turn Fake IP DNS back on, start the core, and **switch networks** — join a different
   Wi-Fi, or toggle Wi-Fi off and on. The headline becomes *"Fake-ip mappings may be stale"*
   as a **warn**, a **Network Changed** fact appears with the relative time, and the recovery
   line offers the flush.
5. Press **Flush Fake IP Cache**. The headline returns to *"Fake IP is active"*, a **Last
   Flush** fact appears, and the Network Changed fact is gone — the flush is what made the
   table known-good again. Browse to any site and confirm traffic still works; a flushed
   table re-allocates on the next query rather than breaking anything.
6. Update the active subscription (Profiles → update). The headline becomes *"Fake-ip
   mappings may be stale"* again, this time with a **Profile Updated** fact. This branch
   matters more than the network one for the ~1600-node case: a subscription update replaces
   the node list under mappings that still point at the old one.
7. Repeat step 1 with the app language set to **Simplified Chinese**. Every string in the
   panel is translated; nothing renders in English.

### Sign-off

| Date | Build | Observed |
| --- | --- | --- |
|  |  |  |

---

## A6 — Whole-group delay testing on a group of 1000+ nodes

Covers [`ROADMAP.md`](ROADMAP.md) A6, whose third acceptance criterion **is** this
measurement — the item is not closed until the number below exists. Automation covers which
units get built; it cannot produce a wall-clock figure, and the whole point of routing a
batch through `/group/{name}/delay` is that the figure gets smaller.

### Setup

A profile with a selector group of **1000 or more** nodes (the maintainer's own runs ~1600),
Settings → delay test mode left at **Mihomo URL** — `.nativePing` deliberately never
promotes to the group endpoint, since it does not go through the core at all.

### Steps and what to look for

1. On the Proxies page, run **Test All** on the large group. Time it end to end, by hand or
   by watching the batch strip.
2. Record, in the table below: node count, wall-clock duration, how many nodes came back with
   a delay, and how many were recorded as failures.
3. **Scroll the list while the batch runs.** Issues #10, #11 and #18 all originate in this
   screen; the scroll must stay smooth, which is what the coalesced batch publishing from #11
   is for.
4. **Cancel a run mid-flight.** The batch status must read *cancelled*, and the tested count
   must exclude the cancelled nodes — the #18 semantics have to survive the change of
   transport, and a group request that is cancelled in flight is the case most likely to
   break them.
5. Check that some nodes are reported as **failures** rather than silently missing. The core
   *omits* a node that failed its probe from the response instead of reporting an error, so a
   build that treats absence as "no data" would quietly show fewer nodes than it tested. Every
   node in the group must end the run with a state.
6. Press **Copy Diagnostics** and confirm the counts in the copied text agree with what the
   strip shows.

### Transport-level measurement (done 2026-08-29)

Steps 1-2 above ask for a wall-clock figure. Almost all of that figure is transport, and the
transport half can be measured without a GUI, so it was — directly against the bundled core
v1.19.30, no app involved. This does **not** retire steps 3-6, which are UI behaviour.

Rig: two bundled-core instances. One is a plain forwarding proxy (`mode: direct`,
`mixed-port: 18081`); the other holds a 1200-member `select` group split into three
populations that mirror a real airport list — 400 reachable (pointed at the forwarding
proxy), 400 instantly refused (`127.0.0.1:19999`, nothing listening), 400 black-holed
(`10.255.255.1:8080`, full timeout). Probe `https://www.gstatic.com/generate_204`, timeout
5000 ms, per-node fan-out driven at concurrency 6 to match
`AppModel.proxyDelayBatchConcurrencyLimit`. DNS/TLS to the probe host warmed first so neither
path pays the first-connection cost.

| Path | Wall clock | Result |
| --- | --- | --- |
| `GET /group/Bench/delay` | **5.00 s** (best of 3; median 5.01 s) | 400 delays returned, 800 omitted |
| 1200 x `GET /proxies/<name>/delay`, concurrency 6 | **350.88 s** | 400 succeeded, 800 failed |

**70x, or 346 seconds saved on 1200 nodes.** Three things this pins down:

- The group endpoint collapses to **exactly one timeout window** — 5.00 s against a 5000 ms
  timeout, with 400 of its members black-holed. The core runs the whole group concurrently
  and does not impose a smaller internal wave, which is the assumption A6's design rests on.
- The per-node figure is the concurrency arithmetic playing out: 400 timeouts / 6 at a time
  x 5 s is ~333 s, and the measurement came in at 351 s.
- **800 members were omitted from the group response, not reported as failures.** This is the
  documented behaviour reproduced at scale, and it is why the mapping back to per-node state
  has to treat absence as `.failure(.timeout, ...)` explicitly. A build that read the response
  as a dictionary lookup would show 400 results for a group of 1200 and call it done.

Reproduce with `script/bench_group_delay.py`, which is the rig above committed: it writes both
configs into a temp directory, starts the two cores on loopback, measures, and tears them down.

```bash
script/bench_group_delay.py
```

Needs the bundled core in place (`script/install_mihomo_core.sh`), or `--core PATH`. `--nodes`,
`--concurrency` and `--timeout-ms` override the parameters above; `--keep` leaves the working
directory for inspection. The absolute numbers move with the machine and the network; the ratio
is the claim.

### Sign-off

Still open: steps 3-6 (scroll smoothness during a batch, cancel semantics, every node ending
with a state in the UI, Copy Diagnostics counts). Those need the app in front of a person.

| Date | Build | Nodes | Duration | Succeeded / failed | Observed |
| --- | --- | --- | --- | --- | --- |
| 2026-08-29 | core v1.19.30, no app | 1200 | 5.00 s group / 350.88 s per-node | 400 / 800 | Transport only — see above. UI steps 3-6 not run. |

---

## B3 — Every Shortcuts action reports what actually happened

Covers [`ROADMAP.md`](ROADMAP.md) B3. The claim under test is that no action reports success
for something that did not happen: each one runs inside the app against the live model and
waits for the operation it started, then shows either a result sentence or a specific error.
`ClashMaxIntentExecutorTests` covers every branch against a scripted controller; what it cannot
show is that Shortcuts.app actually reaches the running app, resolves the parameters, and
displays the text.

### Setup

An installed, signed build in `/Applications` (Shortcuts indexes installed apps; a DerivedData
build may not appear). At least two profiles, one of them a subscription; a profile with a
`select` group of several nodes; the TUN helper **not** installed for steps 6-7, then
installed for step 8. Open Shortcuts.app and search for "ClashMax": ten actions should be
listed — Start, Stop, Restart, Toggle System Proxy, Set ClashMax Routing Mode, Toggle ClashMax
TUN, Select ClashMax Profile, Select ClashMax Node, Update ClashMax Subscriptions, Apply
ClashMax Network Policy.

### Steps and what to look for

1. **Start ClashMax** with the app stopped. The action takes a few seconds and shows
   *"ClashMax is running in System Proxy mode."* — not an instant success. Run it again:
   *"ClashMax is already running."*
2. **Restart ClashMax**: *"ClashMax restarted."*, and the dashboard's uptime resets.
3. **Stop ClashMax**: *"ClashMax stopped."*; the menu bar icon goes idle before the action
   finishes, not after.
4. **Quit ClashMax**, then run **Start ClashMax** from Shortcuts. The app launches without
   being brought to the front, and the action still reports the real result.
5. **Toggle System Proxy** set to *Turn On* while running in System Proxy mode:
   *"System Proxy is on."*, and System Settings → Network → Proxies agrees. Switch the routing
   mode to TUN in the app and run it again: the action **fails** with *"System Proxy can only
   be changed in System Proxy routing mode…"*.
6. With the helper not installed, **Toggle ClashMax TUN** → *Turn On*. The action fails with
   the same instruction the helper setup sheet shows for that step (install / approve in Login
   Items / move to Applications), and the routing mode in the app is **unchanged**.
7. **Select ClashMax Node** with ClashMax stopped: fails with *"ClashMax is not running. Start
   it before selecting a node."* Start it, edit the action: the Proxy Group picker lists only
   `select` groups, and the Node picker lists that group's nodes. Run it: *"Selected X in Y."*,
   and the Proxies page shows the new selection.
8. Install and approve the helper. **Toggle ClashMax TUN** → *Turn On* while running: the action
   waits through the restart and reports *"Switched to TUN and restarted ClashMax."* *Turn Off*
   returns to System Proxy routing with the matching sentence.
9. **Set ClashMax Routing Mode** → NE Proxy while stopped: *"Routing mode set to NE Proxy. It
   takes effect the next time ClashMax starts."*
10. **Select ClashMax Profile**: the picker lists every profile by name. Pick the inactive one
    while running: *"Switched to <name> and restarted ClashMax."*; pick it again: *"<name> is
    already the active profile."*
11. **Update ClashMax Subscriptions** with one subscription URL made unreachable: the action
    **fails** and its message names the profile that failed and why, after listing the ones
    that updated.
12. **Apply ClashMax Network Policy** on a Wi-Fi network with no saved policy: *"No saved policy
    matches <SSID>."* With Location Services denied for ClashMax: the action fails with the
    Location Services explanation instead of a success.
13. An old shortcut built on **Open URLs → `clashmax://start`** still starts the app — the URL
    scheme is kept for those.
14. Repeat steps 1, 6 and 7 with the system language set to **Simplified Chinese**. Action
    names, parameter names and every result or error sentence are in Chinese. (Siri phrases
    are English-only; that is a known gap, not a failure of this item.)

### Sign-off

| Date | Build | Observed |
| --- | --- | --- |
|  |  |  |

---

## A5 — The diagnostic bundle shows exactly what it writes

Covers [`ROADMAP.md`](ROADMAP.md) A5. `DiagnosticBundleTests` proves at the byte level that no
planted secret survives and that the saved file equals the previewed text. What it cannot show is
whether a person, looking at the sheet, can actually review it — and whether a real profile on a
real machine leaks something no fixture thought of.

### Setup

A running ClashMax with a **subscription** profile (its URL carries a token), at least one saved
network policy, Wi-Fi connected, and a public-IP result on the dashboard.

### Steps and what to look for

1. **Help → Export Diagnostic Bundle…** with the main window closed. The main window opens and the
   sheet appears over it; it shows *Collecting diagnostics…* briefly, then the text.
2. The text is monospaced, selectable, scrolls both ways, and ⌘F finds text in it. With a large
   subscription (1000+ nodes) the sheet stays responsive while scrolling the YAML.
3. Search the sheet (⌘F) for: the subscription URL's host and token, the Wi-Fi name, your public IP,
   one node's password, and the controller secret shown in Settings → External Control. **None is
   found.** The proxy node names and the domains in the log section are still there — the header
   says so.
4. Every section has content: stop the core and export again; the running-core lines say no core is
   running rather than being blank.
5. **Copy**, paste into a text editor: identical to the sheet. **Save…** to the Desktop: the file
   name is `clashmax-diagnostics-<date>-<time>.txt`, `ls -l` shows `-rw-------`, and the content is
   identical to the sheet.
6. The same button on the **Status** page opens the same sheet.
7. With the system language set to Simplified Chinese, the sheet's title, description, buttons and
   footer are Chinese. The bundle body keeps English labels; a few values (the routing mode name,
   the DNS panel's verdict) follow the app language, exactly as in Copy Diagnostics.

### Sign-off

| Date | Build | Observed |
| --- | --- | --- |
|  |  |  |

---

## B1 — Route an app from the picker and see it take effect

Covers [`ROADMAP.md`](ROADMAP.md) B1. The rule the picker writes was probed against the bundled
core and its generation is covered by `AppProcessRuleTests`; what no test can show is the picker
itself, the Connections entrance, and the rule winning for a real app's real traffic.

### Setup

ClashMax running in **System Proxy** routing with a profile that has at least two policies (e.g. a
`Proxy` group and `DIRECT`). Google Chrome (or any Electron app) installed.

### Steps and what to look for

1. **Routing → a rules snippet → Add rule… → Rule Type: PROCESS-PATH-REGEX.** *Choose App…* and the
   coverage notes appear under the value. Open it: installed apps are listed with icons, names and
   bundle IDs, search narrows the list, and the list appeared without the window stalling.
2. Pick **Google Chrome**. The value becomes `^/Applications/Google Chrome\.app/`. Add it with policy
   `DIRECT`, save the snippet, and confirm the apply banner reports a hot reload.
3. Browse in Chrome. **Connections**: Chrome's rows — including ones whose process column says
   *Google Chrome Helper* — show the new rule in the chain and route `DIRECT`.
4. On one of those helper rows, open the menu: it says **Route Google Chrome Through…** (the app, not
   the helper). Pick a different policy and **Add Rule**. The verdict says *Your rule is the one that
   matches* and names the probe process; new Chrome connections now take that policy.
5. *Choose…* in the picker opens a file panel at /Applications and accepts an app from elsewhere.
6. Switch routing to **NE Proxy** and open *Choose App…* again: the notes now say process rules see
   the extension, not the app, flagged as blocking.
7. Optional, with the helper installed: repeat step 3 in **TUN** routing and record whether the rule
   matches there — this is the one case the roadmap entry could not measure.
8. With the system language set to Simplified Chinese, the picker, the notes and the menu item are
   in Chinese.

### Sign-off

| Date | Build | Observed |
| --- | --- | --- |
|  |  |  |

---

## C1 — Import a subscription and read its audit report

Covers [`ROADMAP.md`](ROADMAP.md) C1 and the prompt half of C3. `SubscriptionAuditTests` runs the
real normalizer over every key family; what no test shows is the sheet itself, the decision buttons,
and the marker and notification after a background update.

### Setup

Serve three small YAML profiles from a local web server (e.g. `python3 -m http.server` in a folder),
so they can be edited between updates: one clean (`proxies`, `proxy-groups`, `rules` only), one with
`external-controller: 0.0.0.0:9090`, `secret`, `allow-lan: true` and `port: 7890`, and one with a
`listeners:` entry that has no `listen` (so it binds every interface) and no `authentication`.

### Steps and what to look for

1. **Add Subscription** with the clean one. The sheet opens on its own and says there is nothing
   security-sensitive. **Done** closes it.
2. Add the second one. The sheet lists the four keys under *What it tried to change*; all four appear
   under *What ClashMax overrode*, each with what ClashMax used instead; the controller and secret
   rows are marked Danger and say what would have happened. No secret value appears anywhere.
3. Add the third one. An orange box asks about the listener, names its endpoint, and says that
   anyone on the network could use the proxy. **Start** the profile and confirm from another device
   (or `lsof -nP -iTCP:<port> -sTCP:LISTEN`) that the port is **not** open. **Allow…** asks for
   confirmation with the same consequence; after allowing, the port opens, the report shows the
   listener under *What it let through*, and Routing → Inbound Listeners reports it.
4. Profile menu → **Audit Report…** reopens the same report. On a profile imported before this
   build, it runs the audit first.
5. Edit the clean profile on the server to add a `listeners:` entry with no `listen`, and wait for
   (or force) an **automatic** update. No sheet appears; a notification says the subscription needs
   review, the profile row shows an orange shield, the Status page has an *Open Audit Report* item,
   and the new listener's port is **not** open. Opening the report clears the marker and the item.
6. Run the same update **manually** from the profile menu: a notice appears in the window instead of
   a notification, and still no sheet.
7. With the system language set to Simplified Chinese, the sheet, the buttons, every item and the
   notification are in Chinese.

### Sign-off

| Date | Build | Observed |
| --- | --- | --- |
|  |  |  |
