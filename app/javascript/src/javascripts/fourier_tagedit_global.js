// Hang formant's tag-edit grammar on `window` for the Modulation post page.
//
// That page is one inline <script> in an ERB template with no bundler step of
// its own, so it cannot `import`. The pack imports every file in this
// directory (packs/application.js, require.context), which is what delivers
// the canon module; this hangs its exports somewhere the inline script can
// reach them.
//
// The global lives HERE and not in canon: Technetium imports the same file and
// has no use for a global, and canon that knows about one surface's loader is
// canon that has started to belong to that surface.
import * as FourierTagEdit from "./fourier_tagedit.js";

window.FourierTagEdit = FourierTagEdit;
