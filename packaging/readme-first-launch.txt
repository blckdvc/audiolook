audiolook — first launch
========================

1) Drag "audiolook" into your Applications folder (the icon is right next to this file).

2) First launch
   (the app is not signed with a paid Apple account, so macOS blocks it once):

   - macOS 13 / 14:
       Right-click audiolook in Applications  ›  Open  ›  Open.

   - macOS 15 (Sequoia):
       Double-click once (it will be blocked), then go to
       System Settings  ›  Privacy & Security,
       scroll to the bottom and click "Open Anyway", then confirm.

   - If it still won't open ("damaged" / "cannot be verified"):
       open the Terminal app and paste this line, then press Return:

       xattr -dr com.apple.quarantine /Applications/audiolook.app

   Only needed once: audiolook then opens normally.

3) Using it
   audiolook lives in the MENU BAR (no Dock icon).
   Select an audio file in the Finder and it opens on its own.
   The interface follows your system language (English, or French on a French macOS).

Enjoy!
