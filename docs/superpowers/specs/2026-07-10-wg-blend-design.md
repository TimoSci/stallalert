# WG Blend Forecast Source — Design Spec

**Date:** 2026-07-10
**Status:** Approved design, pre-implementation
**Extends:** 2026-07-06-stallalert-design.md and successors

## Purpose

The user wants Windguru's WG model as the watch's default forecast source.
Empirical finding (probed 2026-07-10, documented in windguru-api-notes.md
addendum): WG is NOT a fetchable model — `id_model=100` errors `(wgmix)`;
Windguru's frontend computes it client-side as a coefficient-weighted blend
of constituent models (weights exposed via `q=forecast_spot`'s
`blend/model_koef`). Therefore: recreate the blend server-side, degrade
gracefully to AROME-FR 1.3 km, and let the user pick a source in Settings.

## Empirical inputs (probed live, 2026-07-10)

- `q=forecast_spot&id_spot=1189718` (cookie required) → tabs[0] is the WG
  tab: `id_model: 100`, `id_model_arr` (constituent models with rundefs),
  `blend/model_koef` (per-model weights, e.g. `"3": 1, "45": 0.9`).
- `q=forecast&id_model=100` → `{"message": "Data not available! (wgmix)"}`
  for both spot and custom coords — the blend is not servable.
- Constituents confirmed working for custom lat/lon at the home coords:
  3 (GFS 13 km), 117 (IFS-HRES 9 km), 52 (AROME-FR 1.3 km),
  104 (ICON-2I 2.2 km), 64 (Zephr-HD 2.6 km). Wave model 84 excluded.

## Decisions (made with the user)

| Decision | Choice |
|---|---|
| Approach | Recreate the WG blend server-side (approach A), NOT a picker-only or fixed mini-blend |
| Degradation | WG blend → AROME-FR 1.3 km (52) → GFS 13 km (3) → micro-GFS (existing cookie fallback), each honestly labeled via the existing opaque `model` field |
| Default | `wg` (the blend) when no `model` param sent |
| Settings | Watch Settings gains a Forecast-source picker (global preference, not per-spot), populated from the payload's `available_models` |
| Direct fallback | Stays micro-GFS (no on-watch blending — battery); blend is service-path-only |

## Server design

### Blend weights & constituents
- `Stallalert.Windguru.BlendConfig` (GenServer or persistent_term refresher):
  fetches `q=forecast_spot&id_spot=<home spot>` at boot + daily, extracts the
  WG tab's `model_koef` and constituent id list (wind models only; exclude
  the `id_model_wave`). Hardcoded snapshot fallback (captured 2026-07-10)
  when the fetch fails. Home spot id configurable via env `WG_SPOT_ID`
  (default 1189718).
- Per-location availability: constituents answering "outside grid" for a
  position are cached unavailable for 6 h (keyed by ~0.1° cell); weights are
  normalized over the models that delivered this cycle.

### Blend math (`Stallalert.Windguru.Blend`, pure, exhaustively tested)
- Common hourly grid: now → +48 h.
- Each constituent linearly interpolated onto grid points WITHIN its own
  horizon only (no extrapolation).
- Wind/gusts: koef-weighted arithmetic mean of interpolated values.
- Direction: koef-weighted VECTOR mean (sum of weighted unit vectors from
  each model's direction; atan2 back to degrees; undefined/zero-magnitude →
  fall back to highest-weight model's direction at that step).
- A grid step requires ≥ 2 contributing models, else it is dropped.
- Output: the standard normalized forecast map with
  `model: "WG blend (N models)"` where N = contributing model count.

### Fetching & caching
- Constituent forecasts fetched via the existing adapter path
  (browser headers + cookie), 2–3 s spacing, each cached under the existing
  15-min forecast TTL keyed (position-cell, model id). One model's failure
  never refetches the others.
- Ladder: < 2 constituents or blend error → serve AROME-FR (52); 52
  outside grid/failing → GFS (3); iapi entirely broken → existing micro
  fallback (unchanged). Each ladder transition logs one Logger.warning.

### API
- `/v1/conditions` gains optional `model` param: `wg` (default) | `52` |
  `104` | `117` | `64` | `3`. Unknown values → treated as `wg`.
- Payload additions: `forecast.model` continues to report the SERVED source
  (existing field, opaque); new `requested_model: "wg" | "52" | ...` echo;
  new `available_models: [{"id": "52", "name": "AROME-FR 1.3 km"}, ...]`
  from the availability cache (constituents + `wg` first; cheap, no extra
  HTTP).
- Forecast cache keys on the verbatim requested-model descriptor (the
  station-override lesson applied from day one: repeated identical requests
  cache-stable, any change invalidates immediately).

## Watch design

- Models: `Conditions` gains `availableModels: [AvailableModel]?`
  (`{id: String, name: String}`) and `requestedModel: String?` — optional,
  appended last, backward-compatible as established.
- Provider threading: `fetch(lat:lon:stationID:model:)` — same pattern as
  stationID; ServiceClient sends `model=` when the setting is non-default;
  DirectWindguruClient ignores it (micro-GFS regardless, honest label);
  FailoverProvider pass-through.
- Settings: `forecastModel: String` stored in Settings/UserDefaults
  (default `"wg"`); SettingsView gains a "Forecast source" picker listing
  "WG blend (default)" + the latest payload's availableModels.
- Session screen: small caption under the NEXT HOUR block showing the
  served model name ONLY when `forecast.model` ≠ what the requested source
  would nominally serve (i.e., degradation visible, normality silent).
  Concretely: show caption when `requestedModel == "wg"` and served model
  doesn't start with "WG blend", or when a specific model was requested and
  the served name differs from it.
- AlertPolicy/ForecastEngine: UNTOUCHED (they consume the normalized
  timeline regardless of source).

## Error handling

- Blend starvation mid-session → ladder to AROME/GFS with the caption
  appearing; alerts keep working (forecast timeline always present through
  the ladder).
- Old watch + new server: new payload fields optional-decoded → ignored;
  behavior unchanged (server default is wg — NOTE: this CHANGES the default
  forecast source for old clients too; accepted, it's the point).
- New watch + old server: `available_models` absent → picker shows only
  "WG blend (default)" + note; `model` param ignored by old server → served
  GFS labeled honestly; caption shows the degradation.
- Weights fetch failing at boot → hardcoded snapshot, log warning.

## Testing

- Blend unit tests: vector-mean correctness incl. 350°/10° seam, weight
  normalization with missing models, interpolation within-horizon-only,
  ≥2-model step rule, N-count labeling.
- Fixture-based end-to-end: constituent fixtures (captured per model) →
  known blended output.
- Ladder tests per level incl. cache-stability of repeated identical model
  requests and immediate invalidation on switch.
- Watch: decode, threading, picker, caption logic.
- Checklist: eyeball the served WG-blend numbers vs windguru.cz's WG tab
  for the home spot (expect close-but-not-identical: rundef timing and
  constituent-set drift make exact equality unrealistic); verify the
  caption appears when forcing AROME (travel/coverage simulation not
  required — force via settings picker + a blend-breaking condition is
  optional/manual).

## Out of scope

On-watch blending; per-spot model preferences; exposing constituent
weights in the UI; blending gusts differently from wind; wave/temperature
blending.
