# teach-extra-content — a plugin only this scenario loads

A test sometimes needs content the profile does not have: a test item, a scripted door, an
`.omwscripts` file. `CONTENT_EXTRA` in `scenario.conf` loads extra content files for one scenario,
on every client and in the server's required list, in one order.

```sh
bin/rig run scenarios/teach-extra-content     # about 2 minutes on software GL; exit 0 = pass
```

## What it teaches

- **`CONTENT_EXTRA=content/teach-token.omwaddon`** (paths relative to the scenario). Each file's
  directory becomes a client `data=` line and its name a `content=` line after the profile's files
  and before the probe; the server's `requiredDataFiles.json` gets the same name at the same
  position. TES3MP keys object state by content-file index, so a client whose list differs is
  refused at connect: `assert count server 'Client was allowed to connect' = 2` is the first proof
  the order matched. The content block each client booted with is in the run's
  `profiles/<p>/openmw.cfg`.
- **Keep the plugin in its own subdirectory** (`content/`): the whole directory becomes a data
  path, so anything else in it could shadow game assets.
- **Check the plugin's objects on every client** with the probe: `items` lists the items lying
  near the player (`nearby` lists actors, doors and containers). `probe-count … = 1` catches a
  reference loaded twice.

## Where the plugin comes from

`make-addon.py` writes `content/teach-token.omwaddon` field by field from the public ESM3 record
format: one `MISC` record `teach_token` using a mesh the example-suite already ships
(`marker_travel.dae`), and one reference to it on the floor of cell `0, -7` near the players. Its
master is `template.omwgame`. Nothing in it comes from any game, so it can live in a public repo.
Re-run `python3 make-addon.py` after editing it. For real work use OpenMW-CS or a converter such as
tes3conv; a plugin made from a commercial game's records is that game's content and belongs in
`scenarios/local/`.

## What a red means

- `login` `INFRA` with the client log naming a data-file mismatch: the plugin lists differ (a
  plugin missing on this box fails the conf check earlier and `bin/rig lint` names it).
- `wait probe a items "obj=teach_token"` FAIL: the client loaded the plugin but has no such item
  near a: the reference's cell or position is wrong, or the record failed to load (grep
  `client-a.log` for the plugin's name).
- `probe-count … = 1` FAIL with 2: the reference was loaded twice.

## Make it your own

Point `CONTENT_EXTRA` at your plugin, and assert that its objects exist on every client before the
steps that use them.
