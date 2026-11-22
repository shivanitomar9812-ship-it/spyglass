// Renders demo/social-preview.png (1280x640 link card) from a GIF frame with macOS graphics, no extra tools:
//   ffmpeg -i demo/spyglass-demo.gif -vf "select=eq(n\,3)" -frames:v 1 /tmp/frame.png
//   osascript -l JavaScript demo/social-card.js /tmp/frame.png out.png && sips -z 640 1280 out.png
ObjC.import('AppKit');
function run(argv) {
  const [framePath, outPath] = argv;
  const W = 1280, H = 640;
  const img = $.NSImage.alloc.initWithSize($.NSMakeSize(W, H));
  img.lockFocus;
  $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.169, 0.169, 0.169, 1).setFill; $.NSRectFill($.NSMakeRect(0, 0, W, H));
  const frame = $.NSImage.alloc.initWithContentsOfFile(framePath);
  const c = 6, sw = frame.size.width - 2 * c, sh = frame.size.height - 2 * c;   // trim the frame's edge line
  const fh = 560, fw = sw * fh / sh;
  frame.drawInRectFromRectOperationFraction($.NSMakeRect(W - fw - 60, 40, fw, fh), $.NSMakeRect(c, c, sw, sh), $.NSCompositingOperationSourceOver, 1);
  function text(s, x, yTop, size, bold, r, g, b) {
    const font = bold ? $.NSFont.boldSystemFontOfSize(size) : $.NSFont.systemFontOfSize(size);
    const color = $.NSColor.colorWithSRGBRedGreenBlueAlpha(r, g, b, 1);
    const attrs = $({ [ObjC.unwrap($.NSFontAttributeName)]: font, [ObjC.unwrap($.NSForegroundColorAttributeName)]: color });
    $.NSString.alloc.initWithUTF8String(s).drawAtPointWithAttributes($.NSMakePoint(x, H - yTop - size), attrs);
  }
  text('Spyglass', 72, 150, 88, true, 0.83, 0.95, 0.36);
  text('Every Claude Code session on your Mac,', 74, 280, 34, false, 1, 1, 1);
  text('in one floating panel.', 74, 326, 34, false, 1, 1, 1);
  text('Answer prompts and questions from the panel,', 74, 410, 25, false, 0.67, 0.67, 0.67);
  text('see plan usage, never miss what needs you.', 74, 446, 25, false, 0.67, 0.67, 0.67);
  text('macOS  ·  Claude Code plugin  ·  open source', 74, 548, 21, false, 0.47, 0.47, 0.47);
  img.unlockFocus;
  const rep = $.NSBitmapImageRep.imageRepWithData(img.TIFFRepresentation);
  rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $()).writeToFileAtomically(outPath, true);
}
