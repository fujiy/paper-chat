# Simulator bookmark-position repro

This local fixture lets you investigate PDF navigation on an iPad simulator
without signing in or contacting the PaperChat server.

## Run it

1. In Xcode, choose the `PaperChat` scheme and an iPad simulator.
2. Run the app with the Debug configuration.
3. On the sign-in screen, tap **Load Local Bookmark Test Data**.
4. In the Bookmarks inspector, tap the page 9 bookmark. Compare the page number
   at the top of the PDF with the bookmark's listed page number.
5. Compare the selection bookmark with the **Page 9 anchor control** in the
   Navigate inspector. Rotate the simulator to check another layout. The page
   bookmark should stay on page 9 and return near the same relative location;
   selection and outline jumps should land on their page 9 text anchor.
6. To test a position captured in the simulator, use **Add Bookmark → Current
   Page**, move to another page, then reopen the new **Local simulator
   bookmark**. This bookmark exists only in memory and never calls the server.
7. Use Search for `ANCHOR CONTROL ON PAGE 9` and tap its result. The page 9
   thumbnail is another page-based navigation control.

## Fixture details

The fixture creates a 12-page PDF in the app's temporary directory. Each page
has a large page label and repeated landmarks. It seeds a page 9 bookmark with
a page-relative position of 0.55 (55% from the top). The fixture opens the PDF
at 0.8x. A selection bookmark and outline anchor point to the text marker on
page 9, while search and thumbnail provide page-based controls.

## Investigation result

Before the fix, on the iPad Pro 13-inch (M5) simulator (iOS 26.3), tapping the
page 9 bookmark showed page 7 in portrait and landscape. The page 9 selection
bookmark also showed page 7, while the outline anchor, search result, and
thumbnail showed page 9. The cause was restoring an absolute scroll offset
that depends on device, zoom, and viewport dimensions. Selection bookmarks
also applied that offset after navigating to their saved text rectangle,
overriding the anchor.

Bookmarks now store `page_position` from 0 (top) to 1 (bottom) and resolve it
against the PDF page bounds. Selection bookmarks navigate only to their saved
normalized text rectangles. Existing page bookmarks are moved to the top of
their saved page because the old absolute offsets cannot be converted without
the source device and zoom; existing selection bookmarks retain their saved
rectangles and derive the new position from their first rectangle.

After the fix, page 9 stayed selected and the saved relative location was
visible in both portrait and landscape on the iPad Pro simulator. A local page
6 bookmark created at the current position also returned to page 6 at the
same relative location after navigating away. The selection bookmark
highlighted its page 9 text anchor in both orientations.

The fixture is compiled only for Debug builds running in the iOS simulator.
It does not authenticate, make API requests, or persist reading-position
changes to the server. Restart the app to return to the sign-in screen.
