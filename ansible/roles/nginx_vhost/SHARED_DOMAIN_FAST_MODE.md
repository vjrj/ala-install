# nginx_vhost fast-mode vs. shared-domain vhosts — analysis & proposal

**Audience:** ALA `ala-install` maintainers.
**Where this lives:** branch `docker-compose-min-pr` (the `la-docker-compose`
integration branch). Proposed here for discussion — **not** a PR.

## TL;DR

`nginx_vhost_fast_mode` (introduced in
[ala-install#863](https://github.com/AtlasOfLivingAustralia/ala-install/pull/863),
biocache-service vhost generation 137s → 27s) is **correct for single-role
vhosts but silently wrong for shared domains** — one subdomain served by several
roles at different paths (e.g. `spatial.<domain>`: spatial-hub `/`,
spatial-service `/ws …`, geoserver `/geoserver`, geonetwork `/geonetwork`; or the
`auth.<domain>` CAS cluster). #863's own default comment already notes this:
*"it does not work for CAS or other services that use the same subdomains"*.

Two independent mechanisms cause the breakage, and they interact with a
7-year-old detail of the fragment naming. This document explains both and
proposes a fix that **keeps the fast-mode performance win** while making the
standard (fragment) path correct on shared domains, so the optimization can be
disabled automatically exactly where it is unsafe.

## Background: the two rendering modes

`nginx_vhost` can build a vhost two ways:

- **Fragment mode (default, `fast_mode:false`)** — writes one file per
  `location` sub-part into `vhost_fragments/<hostname>/`, then `assemble`s the
  whole directory (alphabetical by filename) into
  `sites-available/<hostname>.conf`. Because the fragment directory is shared and
  never cleared between calls (in docker-compose `nginx_vhost_fragments_to_clear`
  is empty), **multiple role calls to the same hostname MERGE** — this is how a
  shared domain is assembled from independent roles (this is what production
  `spatial.*` VMs do today, ~8 locations).
- **Fast mode (`fast_mode:true`)** — renders the whole server block in one pass
  via `nginx_vhost.j2` and **overwrites** `sites-available/<hostname>.conf`.

## Mechanism 1 — fast mode overwrites the whole `.conf` per call

A single `nginx_vhost` call is *stateless*: it does not know another role will
target the same hostname. In fast mode each call rewrites the entire `.conf`, so
on a shared domain **only the last-registered role survives**. Observed on the
demo: only `/geonetwork` (last registered) returned 200; `/ws`, `/geoserver`,
`/webportal`, `/alaspatial`, `/layers*` all 404. This is intrinsic — fast mode
can never serve a shared domain, regardless of any naming fix.

## Mechanism 2 — fragment-name collision (the trap after you turn fast mode off)

The per-location fragment filename has been, since 2018 (commit `990509286`):

```
http_70_location_{{ item.sort_label | default(item.path | basename) }}_{70_start|73_content|74_cors|75_end}
```

`sort_label` has **always** taken precedence over the path basename — but it was
dormant, because no role set `sort_label`. #863's fast template sorts locations
with `nginx_paths | sort(attribute='sort_label')` **and no default**, so to use
fast mode, `sort_label` was added to ~23 roles, each numbering **from `"1"`
independently**.

Consequence: with `sort_label` now populated, the 2018 fragment naming uses it,
and on a shared domain the per-role labels collide:

- spatial-hub `/webportal` `"1"` vs spatial-service `/files` `"1"`
- geoserver `/geoserver` `"2"` vs geonetwork `/geonetwork` `"2"`

`assemble` writes fragments by filename, so colliding names **silently overwrite
each other** and locations disappear. So even after correctly setting
`fast_mode:false` for a shared domain (mechanism 1), the vhost is still missing
locations (mechanism 2).

## Constraints any fix must respect

- **Duplicate basenames within one role** must stay distinct. Example:
  `biocache3-service` has `/webportal/wms/reflect`, `/ogc/wms/reflect`,
  `/mapping/wms/reflect` — all basename `reflect`. Naming by basename alone would
  collide them. (`sort_label` currently disambiguates; biocache uses fast mode so
  it never actually hits fragment naming, but the role is generic.)
- **Regex/`^~`/`=` locations are order-dependent** (nginx matches regex locations
  in file order). Roles with regex locations that also set `sort_label`:
  bie-hub (`~ …/(.*)$`), ecodata (4), sds (`~* /location/`), biocollect (`= /`).
  All are single-role and/or fast-mode; **no shared-domain fragment-mode vhost
  uses regex** — but a fix should still preserve ordering for these.
- **VMs** (bare-metal, usually one role per host) and the **CAS cluster** (a
  shared `auth.*` domain that works today in fragment mode) must not regress.

## Proposed fix (implemented on this branch)

### (c) Decouple the fragment filename from the `sort_label` collision

Keep `sort_label` as the **ordering** key (so fast mode and any labeled role are
unaffected) and append the **normalized path** as a **uniqueness** suffix — the
full path is inherently unique per location, within and across roles:

```diff
- dest: ".../http_70_location_{{ item.sort_label | default(item.path | basename) }}_70_start"
+ dest: ".../http_70_location_{{ item.sort_label | default(item.path | basename) }}_{{ item.path | regex_replace('[^A-Za-z0-9]+', '_') }}_70_start"
```

(applied to all 8 fragment tasks: http/https × `70_start`/`73_content`/`74_cors`/`75_end`.)

- Roles that set `sort_label` (biocache, bie-hub, ecodata…) keep **identical
  ordering** — the label is still the primary sort key; the path suffix only
  breaks ties.
- Shared domains stop colliding: `geoserver` vs `geonetwork`, `/webportal` vs
  `/files` now yield distinct fragment names because their paths differ.
- Within-role duplicate basenames (`…/reflect` ×3) get distinct names from their
  distinct full paths.
- The `_70_start/_73_content/_74_cors/_75_end` suffix still keeps each location's
  four parts contiguous and correctly ordered after `assemble`.

This makes the standard path correct for shared domains **without** hand-tuned
per-service `sort_label`s and **without** touching fast mode.

### (b) Make fast mode tolerate a missing `sort_label`

`sort(attribute='sort_label')` raises `AnsibleUndefinedVariable` when any path
lacks `sort_label` (this bit the demo when a role omitted it). Make it graceful —
labeled paths sorted first, unlabeled kept last:

```diff
- {% for item in nginx_paths | sort(attribute='sort_label') %}
+ {% for item in (nginx_paths | selectattr('sort_label', 'defined') | sort(attribute='sort_label')) + (nginx_paths | rejectattr('sort_label', 'defined') | list) %}
```

For a fully-labeled role this is byte-identical to the previous output; for a
partially/unlabeled role it no longer errors.

### Automatic selection (downstream, in la-docker-compose)

Because mechanism 1 is intrinsic, a shared domain must use fragment mode. A
stateless role call can't detect "shared" on its own, but the orchestration layer
can. `la-docker-compose`'s `docker-services-desc.yaml` already clusters services
via `parentService`/`isSubService` (spatial-hub + spatial-service + geoserver +
geonetwork; cas + userdetails + apikey…). It computes the set of clusters with >1
enabled member and derives `nginx_vhost_fast_mode: "{{ <service> not in
shared_cluster }}"` — so fast mode is **auto-disabled exactly on shared
domains**, no per-service flag. Single-role vhosts keep the fast-mode speedup.

### Ideal native option (for maintainers to consider)

The cleanest upstream form would let fast mode itself be safe on shared domains:
have fast mode emit a **per-appname location fragment** into
`vhost_fragments/<hostname>/` (with the server-block skeleton written by
idempotent, fixed-named fragments) and always run `assemble`. Then one template
render per role (keeping most of #863's win) merges 1..N roles order-independently
with no `fast_mode` flag at all. This is a larger refactor of the role, so it is
not implemented here — flagging it as the direction that would fully unify the
two modes.

## Compatibility

- **Performance:** fast mode and its `sort_label` requirement are unchanged for
  single-role vhosts — the 137s→27s win stands.
- **VMs:** fragment-mode output for labeled roles is byte-identical (ordering
  preserved); the only change is a longer, unique fragment *filename*.
- **CAS / multi-role auth domain:** already fragment mode; now also collision-proof.

## Verification

- Offline simulation of the spatial shared vhost: 0 fragment-name collisions
  (including the historical `/webportal`↔`/files` "1" and `/geoserver`↔
  `/geonetwork` "2" cases); every location's 4 fragments contiguous and ordered.
- Offline render of the hardened fast-mode loop: identical to `sort(...)` when all
  paths are labeled; no error when some/none are.
- End-to-end: regenerate configs and assert `spatial.<domain>.conf` contains
  `/ws /layers /webportal /alaspatial /files /layers-service /geoserver
  /geonetwork /`; multi-host CI green; live `nginx -T` + gatus checks.
