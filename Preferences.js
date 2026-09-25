// Language is stored by Omarchy in the foamy.monitor widget settings.
var norwegian = {
  "Displays": "Skjermer",
  "Your workspace": "Arbeidsområdet ditt",
  "Display": "Skjerm",
  "Advanced": "Avansert",
  "Wireless": "Trådløst",
  "Extended desktop": "Utvidet skrivebord",
  "Identify": "Identifiser",
  "Display mode": "Skjermmodus",
  "Extend": "Utvid",
  "Mirror other display": "Speil den andre skjermen",
  "Turn off": "Slå av",
  "Turn on": "Slå på",
  "Resolution": "Oppløsning",
  "Refresh rate": "Oppdateringsfrekvens",
  "Scale": "Skalering",
  "Orientation": "Retning",
  "Landscape": "Liggende",
  "Portrait": "Stående",
  "Landscape flipped": "Liggende, snudd",
  "Portrait flipped": "Stående, snudd",
  "Brightness": "Lysstyrke",
  "All changes saved": "Alle endringer er lagret",
  "Save": "Lagre",
  "Discard": "Forkast",
  "Keep these settings?": "Beholde disse innstillingene?",
  "Keep settings": "Behold innstillingene",
  "Revert": "Tilbakestill",
  "Plugin settings": "Plugininnstillinger",
  "Back": "Tilbake",
  "Language": "Språk",
  "System": "System",
  "Follows your system language.": "Følger systemspråket ditt.",
  "Pending display changes are preserved.": "Ventende skjermendringer er bevart.",
  "Appearance & scaling": "Utseende og skalering",
  "Text size": "Tekststørrelse",
  "Cursor size": "Pekerstørrelse",
  "GTK scale": "GTK-skalering",
  "Text and cursor size apply immediately. GTK scale is included in Save; reopen apps after keeping it.": "Tekst- og pekerstørrelse endres umiddelbart. GTK-skalering tas med ved lagring; åpne apper på nytt etterpå.",
  "Wireless displays": "Trådløse skjermer",
  "Scan": "Søk",
  "No receivers found": "Ingen mottakere funnet",
  "Scanning…": "Søker…",
  "Casting desktop": "Deler skrivebordet",
  "Ready to cast": "Klar til skjermdeling",
  "Cast": "Del skjerm",
  "Stop": "Stopp",
  "Keep at least one display enabled.": "Minst én skjerm må være aktiv.",
  "Reverting in": "Tilbakestilles om",
  "Display sections": "Skjermfaner",
  "Reading displays…": "Leser skjermer…",
  "Drag to arrange": "Dra for å plassere",
  "Identify displays": "Identifiser skjermer",
  "Off": "Av",
  "Disconnected": "Frakoblet",
  "Mirror %1": "Speil %1",
  "Unavailable": "Utilgjengelig",
  "%1 unsaved change": "%1 ulagret endring",
  "%1 unsaved changes": "%1 ulagrede endringer",
  "Reverting in %1 s": "Tilbakestilles om %1 s",
  "Saving…": "Lagrer…",
  "Applying…": "Bruker innstillinger…",
  "Reverting…": "Tilbakestiller…",
  "· changed": "· endret",
  "Built-in display": "Innebygd skjerm",
  "Unknown display": "Ukjent skjerm",
  "Invalid setting.": "Ugyldig innstilling.",
  "Could not save settings.": "Kunne ikke lagre innstillingene.",
  "Wireless display": "Trådløs skjerm",
  "Casting to %1": "Deler til %1",
  "Connecting to %1…": "Kobler til %1…",
  "Stopping…": "Stopper…",
  "Landscape · 0°": "Liggende · 0°",
  "Landscape · 90°": "Liggende · 90°",
  "Landscape · 180°": "Liggende · 180°",
  "Landscape · 270°": "Liggende · 270°",
  "Portrait · 0°": "Stående · 0°",
  "Portrait · 90°": "Stående · 90°",
  "Portrait · 180°": "Stående · 180°",
  "Portrait · 270°": "Stående · 270°",
  "Flipped · 0°": "Snudd · 0°",
  "Flipped · 90°": "Snudd · 90°",
  "Flipped · 180°": "Snudd · 180°",
  "Flipped · 270°": "Snudd · 270°",
  "Mirrored": "Speilet",
  "No connected displays": "Ingen tilkoblede skjermer",
  "No enabled display": "Ingen aktiv skjerm",
  "Displays changed. Discard the draft and try again": "Skjermene er endret. Forkast endringene og prøv igjen",
  "Keep at least one display enabled": "Minst én skjerm må være aktiv",
  "Choose an enabled, non-mirrored source display": "Velg en aktiv kildeskjerm som ikke er speilet",
  "Displays overlap. Adjust their arrangement": "Skjermene overlapper. Juster plasseringen",
  "The display did not accept these settings": "Skjermen godtok ikke disse innstillingene",
  "A display was disconnected during the test": "En skjerm ble koblet fra under testen",
  "monitors.lua changed during the test; try again": "monitors.lua ble endret under testen; prøv igjen",
  "Invalid display change": "Ugyldig skjermendring",
  "Display is disconnected": "Skjermen er frakoblet",
  "Unknown display setting": "Ukjent skjerminnstilling",
  "A display test is already running": "En skjermtest kjører allerede",
  "Display settings changed elsewhere. Discard the draft and try again": "Skjerminnstillingene er endret et annet sted. Forkast endringene og prøv igjen",
  "GTK scale changed elsewhere. Discard the draft and try again": "GTK-skaleringen er endret et annet sted. Forkast endringene og prøv igjen",
  "No unsaved changes": "Ingen ulagrede endringer",
  "monitors.lua must be a machine-local file outside Stow": "monitors.lua må være en maskinlokal fil utenfor Stow",
  "Fix Hyprland configuration errors before saving": "Rett feilene i Hyprland-konfigurasjonen før du lagrer",
  "This display test has ended": "Denne skjermtesten er avsluttet",
  "Could not read GTK scale": "Kunne ikke lese GTK-skaleringen",
  "Could not set brightness": "Kunne ikke endre lysstyrken",
  "Could not update advanced settings": "Kunne ikke oppdatere de avanserte innstillingene",
  "Wireless display scan failed": "Søk etter trådløse skjermer mislyktes"
}

function valid(key, value) {
  return key === "language" && ["system", "en", "nb"].indexOf(value) >= 0
}
function value(settings, key) {
  return key === "language" && settings && valid(key, settings[key]) ? settings[key] : "system"
}
function language(mode, locale) {
  if (mode === "en" || mode === "nb") return mode
  return /^(nb|nn|no)(_|-|$)/i.test(locale || "") ? "nb" : "en"
}
function text(label, lang) {
  if (lang !== "nb") return label
  if (norwegian[label]) return norwegian[label]
  // Keep command-specific detail while translating known recovery messages.
  var prefixes = [
    ["Please install ", "Installer "],
    ["Could not read display settings: ", "Kunne ikke lese skjerminnstillingene: "],
    ["Unsupported scale for ", "Skaleringen støttes ikke for "],
    ["Unsupported resolution or refresh rate for ", "Oppløsningen eller oppdateringsfrekvensen støttes ikke for "]
  ]
  for (var i = 0; i < prefixes.length; i++)
    if (label.indexOf(prefixes[i][0]) === 0) return prefixes[i][1] + label.slice(prefixes[i][0].length)
  return label
}
if (typeof module !== "undefined") module.exports = { valid: valid, value: value, language: language, text: text }
