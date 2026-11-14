# Chess Lens

Look at a chess board, get the position. Chess Lens reads a board from a photo taken with Meta
glasses or a phone camera, shows it as an editable board, and hands it to an analysis board. It
has two modes: **Real board** for physical pieces on a table, and **Book or screen** for printed
and on-screen diagrams.

Separate from Fantasy Market; it only shares this repository.

## What it does

1. **Finds the board** in the photo, at an angle, with text and clutter around it.
2. **Reads the pieces** on the device. Photos are not uploaded.
3. **Shows the position** next to the photo. Squares it was unsure of are outlined; tap a square to
   fix it. Swap sides if the diagram was drawn from Black's point of view, set who is to move.
4. **Exports** the FEN, opens the position on Lichess, or saves it for later.

With Meta Ray-Ban Display glasses the loop is hands-free: pinch **Scan** in the lens, the glasses
take the photo, and the recognised board appears in the lens a moment later.

## What it reads

| Source | Mode | Status |
| --- | --- | --- |
| A physical board with real pieces | Real board | Reads real photos taken from above correctly; the view from a seat is untested (see below) |
| Printed diagrams (books, magazines, worksheets) | Book or screen | Supported; accuracy measured on synthetic photos |
| Diagrams on a screen (Lichess, Chess.com, videos, PDFs) | Book or screen | Supported; accuracy measured on synthetic photos |

### Real board

Real pieces are read by the model behind [ChessCam](https://www.chesscam.net), through its
[`@chesscam/recorder`](https://www.npmjs.com/package/@chesscam/recorder) library and LiteRT.js.
Chess Lens finds the board in the photo with its own board finder, hands the reader that region
(the board plus room for the pieces standing on it), and turns the answer into the same editable
position as the diagram mode. The reader works out which side is White by itself; **Swap sides**
and **Rotate** correct it when it is wrong.

What is and is not verified:

- **Six of six real photos read exactly right** (all 384 squares, positions from 5 to 32 pieces,
  about 0.4 s each), by `npm run test:real` in a headless browser on the GitHub runner. The photos
  are in `tests/real`.
- The board finder located the board in 40 of 40 real photos from the same source.
- Those photos are all taken **from directly above, of one board with one piece set**. Not tested:
  the view from a seat at the table, which is what glasses see and where pieces hide each other;
  other piece sets and boards; outdoor light. ChessCam is built for a phone on a stand beside the
  board, so a steep look down at the board is the safest bet: lean in until all four edges are in
  view.
- The reader has run in desktop Chromium only. It has not been run inside the iOS app's web view.

The model (about 24 MB) is under the **PolyForm Noncommercial License 1.0.0**: personal and other
non-commercial use only. It is not in this repository. A plain web deployment downloads it from
Hugging Face, and the runtime from jsDelivr, the first time Real board is used. The iOS builds
bundle both with `npm run vendor:offline`, checksum-pinned, so the app works without a connection.

Diagram accuracy is measured on synthetic photos only (see [Accuracy](#accuracy)). Nothing in
either mode has been tried on photos from real glasses yet.

## Layout

```
web/        The app. Static files, no build step. Runs in any browser and inside the iOS shell.
  core/     Recognition: board finder, square classifier, position logic. No DOM, runs in Node too.
  model/    Diagram classifier weights (float32) and manifest.
  vendor/   Third-party code for the real-board reader (built by tools/vendor.mjs).
ios/        SwiftUI shell: hosts web/ in a WKWebView and connects the glasses. See ios/README.md.
training/   Synthetic data generator, training and evaluation scripts.
tests/      Node tests for the core.
```

## Run the web app

```sh
cd chess-lens
npm install        # dev tools only; the app itself has no dependencies
npm run dev        # http://localhost:8787
npm test           # unit tests and diagram photos
npm run vendor:offline && npm run test:real   # real-board reader on real photos (needs Playwright)
```

Pick **Real board** or **Book or screen** at the top. Tap **Try sample** to scan a bundled photo,
**Choose photo** to pick a picture (including one the glasses saved to your camera roll), or
**Use phone camera** for a live viewfinder. The camera needs
HTTPS anywhere other than localhost; any static host works since there is nothing to build.

## Run it with glasses

The iOS shell is in [`ios/`](ios/README.md). It needs Xcode 26.4 or newer, the Meta AI app with
Developer Mode switched on for your glasses, and your Apple team for signing. Without glasses, the
**Simulated glasses** switch runs the whole flow against Meta's mock device, with the phone's back
camera standing in for the glasses camera and a preview of what the lens would show.

Recognition runs in the web view, so the phone app has to stay open and on screen while you scan.
The shell keeps the screen awake during a session.

## How the recognition works

- **Corners.** A ChESS detector finds the X-shaped junctions where four squares meet. Text, piece
  artwork and plain edges score low.
- **Lattice.** A projective grid is grown from a seed cell and refitted as it expands, so a tilted
  view is handled without knowing the camera. The 8×8 block is the one where squares alternate and
  the pattern stops at the edge.
- **Squares.** The board is flattened and cut into 64 overlapping 32-pixel crops.
- **Classifier.** A three-layer convolutional network (about 250k weights, 1 MB) labels each crop
  as empty or one of twelve pieces. Inference is plain JavaScript over typed arrays.
- **Position.** Each side gets exactly one king where the evidence allows. A material check
  re-reads surplus pieces: an unfamiliar font whose pawn looks like a bishop would otherwise give
  one side eight bishops. The side the diagram is drawn from is guessed from pawn direction, and
  impossible positions are reported rather than hidden.
- **Several diagrams in view.** Every board in the picture is found; the one nearest the middle is
  read, since that is the one being looked at.

## Accuracy

Measured on synthetic photos only: rendered diagrams dropped onto a page or screen, then given
perspective, uneven light, blur, sensor noise and JPEG artefacts. Positions use material a real game
can have. **Nothing here has been measured on photos from real glasses or a real phone yet.**

| Test photos | Board found | Whole position right | At most one square wrong | Squares right |
| --- | --- | --- | --- | --- |
| Piece styles the classifier was trained on (200) | 99.5% | 94.5% | 97.0% | 99.5% |
| Same, but a small diagram in a wide-angle 7 MP frame, 190 to 680 px across (80) | 97.5% | 83.8% | 93.8% | 98.3% |
| Five piece styles held out of training (200) | 100% | 47.5% | 68.0% | 98.4% |

The last row is what to expect from a piece design it has never seen, which includes some book
fonts and Chess.com's default set: usually a square or two to correct. About four in five of the
wrong squares in that row carry the dashed "uncertain" outline. The material check accounts for a
good part of that row (38% of positions right without it).

Board finder on its own: 299 of 300 single diagrams, the central diagram on 97 of 100 pages with
two diagrams, 57 of 60 small diagrams in wide-angle frames. Median corner error is under 1% of a
square.

A scan takes about half a second for a 1 MP photo and about one second for 7 MP (Node, 4 cloud
cores; a phone has not been timed). A board needs to be roughly 200 px across to be read reliably;
the result screen shows the size it found.

Reproduce with `training/eval_scan.mjs` and `training/eval_detect.mjs` on scenes from
`training/synth.py` (`--realistic`, `--wide`, `--two-boards`, `--sets`, `--exclude`).

## Retraining

```sh
# 1. Rasterise piece sets: lichess (lichess-org/lila, public/piece), pychess (pychess/pychess,
#    pieces) and any installed fonts that carry the Unicode chess symbols
node training/render_pieces.mjs <lila>/public/piece <pieces>
node training/render_pieces.mjs <pychess>/pieces <pieces> py-
python3 training/render_fonts.py <pieces>
# 2. Generate scenes, cut crops with the same code the app runs, train, export
python3 training/synth.py --pieces <pieces> --out <data>/train --count 8000 --seed 1 --exclude staunty,leipzig,governor,fresca,cooke
node training/make_crops.mjs <data>/train
python3 training/train.py --train <data>/train --val unseen=<data>/held-out seen=<data>/val --out web/model/pieces-v1
# 3. Measure
node training/eval_scan.mjs <data>/val --verbose
```

Python needs `numpy`, `opencv-python-headless`, `pillow` and `torch`. The shipped model saw 53
piece styles in about 11,000 scenes and trained for six epochs (about 45 minutes on 4 CPU cores).
The quickest way to raise the held-out row is more piece styles: add a set to step 1 and retrain.
`training/make_fixtures.py` rebuilds the photos in `tests/fixtures`.

## Licences of bundled material

- Real-board reader: `web/vendor/chesscam/` bundles @chesscam/recorder (MIT) and @litertjs/core
  (Apache 2.0); see `LICENSES.md` there. The model they run is PolyForm Noncommercial 1.0.0 and is
  fetched, not committed.
- UI piece images: "chessnut" by Alexis Luengas, Apache 2.0 (`web/pieces/NOTICE.md`).
- The classifier was trained on renders of the piece sets distributed with lichess.org and
  pychess, which carry a mix of licences (GPL, CC BY-NC-SA, and others), and of the DejaVu,
  FreeSerif and Unifont chess glyphs. Only the trained weights are in this repository, not the
  artwork. If you plan to distribute the app commercially, review that.
- `web/samples/real-board.jpg` is from the MIT-licensed Chess Board Dataset
  (`web/samples/NOTICE.md`).
- The sample page and the test photos are generated by `training/make_sample.py` and
  `training/make_fixtures.py` from sets that allow redistribution (chessnut: Apache 2.0; fantasy,
  spatial, celtic: MIT; rhosgfx: CC0).
