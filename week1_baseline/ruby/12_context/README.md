# Step 12 — Context Management

When you call an LLM directly you are responsible for the context window. There is no auto-compacting. This step adds proper token tracking, visual warnings, and automatic compaction so the agent never silently blows past the limit.

## What's new

### Accurate context tracking

`Context` now maintains two distinct token counts:

| Attribute | What it measures |
|-----------|-----------------|
| `context_window` | The model's maximum input token capacity (default 200,000 for Anthropic) |
| `current_tokens` | Tokens actually used in the most recent API call (`usage.input_tokens` from the response) |

Previously `token_budget` (8,192) was displayed as the limit — that was the *output* `max_tokens`, not the context window. And the cumulative session token sum was shown as usage, which grew without bound even after `/clear`. Both are fixed.

The Agent updates `current_tokens` after every API response (including mid-turn tool-use calls), so the display always reflects what the next call will actually send.

### Context colour coding

The progress and status lines now colour the context indicator based on how full the window is:

| Usage | Colour | Meaning |
|-------|--------|---------|
| < 70% | Grey | Normal |
| 70–84% | Yellow | Approaching limit |
| ≥ 85% | Red | Compaction imminent |

A `⚠` symbol also appears in the status bar at 85%+.

### Auto-compaction

At the start of each agent turn, if `current_tokens / context_window ≥ 0.85`, the Agent automatically compacts the context before making any API call:

```
[context compacted — 12 messages dropped to free space]
```

Compaction drops the oldest 40% of messages (keeping at least 2) and resets `current_tokens` to 0. The first API call after compaction will report the true new size.

### `Context#compact_messages!`

```ruby
dropped = context.compact_messages!(target_fraction: 0.60)
# => 12  (number of messages dropped)
```

### `/compact` command

Manual compaction from the REPL or TUI:

```
boukensha> /compact
(compacted context — 12 messages dropped)
```

### `Logger#compaction` event

```json
{"phase":"compaction","before":172000,"dropped":12,"context_window":200000}
```

Emitted whenever auto- or manual compaction runs. The TUI subscribes to this event to display the compaction notice in the conversation view.

### `Boukensha.run` / `Boukensha.repl` — `context_window:` keyword

`token_budget:` is replaced by `context_window:` (default `200_000`):

```ruby
Boukensha.repl(context_window: 128_000)  # for a smaller model
```

## Tests

The suite lives in `test/` and runs under minitest via rake:

```sh
mise exec -- rake test        # run everything
mise exec -- ruby -Itest -Ilib test/world_model_routing_test.rb   # one file
```

What's covered so far (grown out of the "stray map" debugging — see
[journal slice 12](../../../docs/journal/6_minotaur.md)):

| File | Guards |
|------|--------|
| `world_model_default_path_test.rb` | Map-path resolution: `BOUKENSHA_DIR` wins; otherwise **walk up to the nearest `.boukensha/world.json`** instead of forking a stray map at `Dir.pwd`. |
| `world_model_load_announce_test.rb` | The load-time log line (`world map: <path> (<n> rooms)`) and the loud warning when a *fresh/empty* map is started — the signal that catches a wrong launch directory. |
| `world_model_routing_test.rb` | `route_to` / `resolve_destination` over duplicate room names — resolve must pick the **reachable** twin, `route_to` nils the orphan. |

**Convention:** every test uses the `with_isolated_env` helper (in `test/test_helper.rb`),
which runs in a throwaway tmpdir with `BOUKENSHA_DIR` cleared and restores cwd + env
afterwards — so no test can ever read or mutate the real `.boukensha/world.json`. Follow
that pattern for any test that constructs a `WorldModel` (it saves on observe).

## Run the demo

gem uninstall boukensha

gem build boukensha.gemspec
gem install boukensha-0.12.0.gem

```sh
ruby examples/example.rb

# via the global executable:
BOUKENSHA_DIR=~/Sites/Claude-Code-Camp/.boukensha BOUKENSHA_PATH=~/Sites/Claude-Code-Camp/week1_baseline/12_context boukensha
