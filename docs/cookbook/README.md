# Cookbook — one file per headless-action recipe
Read when: looking for a way to drive the game headlessly, or adding a recipe you calibrated.

Each recipe is a technique, *why* it works, and the dead ends that look like the technique failing.
The mechanics are engine-general; examples are stated abstractly or against the free example-suite
content.

- **This directory is the catalog.** One file per recipe, named by its ID `KB-<n>-<slug>`. List the
  directory to browse; no index is kept. Cite a recipe by its full ID.
- **Confidence tags** (line 4 of every recipe):
  - **VALIDATED** — seen to work and verified from a log line or a screenshot.
  - **PARTIAL** — works in the cases tried; known gaps are stated.
  - **THEORY** — reasoned from engine behaviour, not yet run.
  - **METHOD NOTE** — a working rule for headless debugging, not a technique.
  A recipe may tag one part differently from the rest; the tag sits next to that part.
- **Numbers are never reused or renumbered.** KB-7 and KB-10 were merged into KB-6 and KB-9 and are
  retired.
- To add a recipe, follow [CONTRIBUTING.md](../../CONTRIBUTING.md#adding-a-capability-or-recipe).
