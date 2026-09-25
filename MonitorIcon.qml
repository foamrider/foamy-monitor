import QtQuick
// Control paths match foamy-weather's settings and back buttons.

Image {
  id: root
  property string name: "settings"
  readonly property var paths: ({
    "monitor": '<rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/>',
    "scan": '<path d="M8 3H5a2 2 0 0 0-2 2v3m13-5h3a2 2 0 0 1 2 2v3M3 16v3a2 2 0 0 0 2 2h3m13-5v3a2 2 0 0 1-2 2h-3"/>',
    "refresh-cw": "<path d=\"M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8\"></path><path d=\"M21 3v5h-5\"></path><path d=\"M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16\"></path><path d=\"M8 16H3v5\"></path>",
    "refresh": '<path d="M20 7v5h-5M4 17v-5h5"/><path d="M6.1 6.1A8 8 0 0 1 20 12M4 12a8 8 0 0 0 13.9 5.9"/>',
    "external-link": '<path d="M15 3h6v6M10 14 21 3M21 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5"/>',
    "app-window": '<rect x="2" y="4" width="20" height="16" rx="2"/><path d="M2 8h20M6 4v4"/>',
    "check": '<path d="m20 6-11 11-5-5"/>',
    "arrow-left": '<path d="m12 19-7-7 7-7M5 12h14"/>',
    "chevron-down": '<path d="m6 9 6 6 6-6"/>',
    "chevron-right": '<path d="m9 6 6 6-6 6"/>',
    "settings": '<path d="m10 3-.6 2.3-2 .9-2.1-.7-2 3.5 1.6 1.7v2.6L3.3 15l2 3.5 2.1-.7 2 .9L10 21h4l.6-2.3 2-.9 2.1.7 2-3.5-1.6-1.7v-2.6L20.7 9l-2-3.5-2.1.7-2-.9L14 3Z"/><circle cx="12" cy="12" r="3"/>'
  })
  property color color: "white"
  property real strokeWidth: 1.7
  sourceSize.width: Math.ceil(width * 2)
  sourceSize.height: Math.ceil(height * 2)
  fillMode: Image.PreserveAspectFit
  // Inline SVG keeps the original stroke geometry and follows the active theme.
  source: "data:image/svg+xml;charset=utf-8," + encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="'
    + color.toString() + '" stroke-width="' + strokeWidth
    + '" stroke-linecap="round" stroke-linejoin="round">'
    + (paths[name] || paths.settings) + '</svg>')
}
