# A+ action panel review

These screenshots use Pairbar 2.0.0 (22) in `--preview-ui` mode. The fixture is
inert: Open/Switch, Pin, Close, Restart, and Remove do not reach the controller.
No real profiles or local profile data were used.

Run a built temporary bundle with `--preview-ui english light` for two profiles,
or `--preview-ui english light four` for Personal, Work, Studio, and Testing.
Replace `light` with `dark` for Dark appearance.

The native popover screenshots include its 13 pt chrome on each side. The
two-profile content remains 326 × 208 pt (352 × 234 px captured); the
four-profile content is 326 × 344 pt (352 × 370 px captured).

| Screenshot | State |
| --- | --- |
| `two-profiles-light.png` | Two profiles, normal |
| `two-work-actions-light.png` | Two profiles, Work actions |
| `four-profiles-light.png` | Four profiles, normal |
| `four-personal-actions-light.png` | Four profiles, Personal actions |
| `four-studio-actions-light.png` | Four profiles, Studio actions |
| `four-testing-actions-light.png` | Four profiles, Testing actions |
| `four-testing-actions-dark.png` | Four profiles, Testing actions in Dark |

The panel is anchored to the selected ellipsis. Its measured size is clamped
inside the content bounds; opening it does not resize the native popover or
move the rows. The lower-row panels open upward when they cannot fit lower.
