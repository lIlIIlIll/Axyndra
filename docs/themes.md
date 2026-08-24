# Themes

`Axyndra` ships with `axyndra`, `dark`, `light`, and `mono`. Run `/theme` to open
the theme selector, or `/theme <name>` to switch directly. The selected name is
saved in `$AXYNDRA_HOME/config.yml` as `theme: <name>`.

Custom themes live in `$AXYNDRA_HOME/themes/*.json`. Theme files use `vars` for
reusable colors, and `colors` may refer
to those variables. Colors can be `#RRGGBB`, an integer from 0 to 255, or an
empty string for the terminal default.

```json
{
  "name": "my-theme",
  "vars": {
    "accentColor": "#febc38",
    "userBg": "#221d1a"
  },
  "colors": {
    "accent": "accentColor",
    "error": "#fc3a4b",
    "warning": "#e4c00f",
    "success": "#89d281",
    "muted": "#777d88",
    "text": "",
    "thinkingText": "#777d88",
    "selectedBg": "#31363f",
    "toolPendingBg": "#1d2129",
    "toolTitle": "",
    "mdLink": "#0088fa",
    "userMessageBg": "userBg",
    "userMessageText": ""
  }
}
```

Restarting is unnecessary: opening `/theme` reloads the custom theme directory.
The names `axyndra`, `dark`, `light`, and `mono` are reserved for built-in themes.
