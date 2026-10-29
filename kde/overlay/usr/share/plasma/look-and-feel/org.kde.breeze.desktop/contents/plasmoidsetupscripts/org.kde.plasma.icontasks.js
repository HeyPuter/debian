// The panel's pinned launchers when the session makes its panel (Plasma runs
// the look-and-feel's setup script for each applet it adds): Konsole, the
// file manager and Kate, in place of the task manager's default System
// Settings and Discover (Discover is not in the image). No browser: none in
// the image runs (Debian's Chromium does not), and preferred://browser
// resolves to the text/html handler, Kate.
applet.currentConfigGroup = ["General"];
applet.writeConfig("launchers", ["applications:org.kde.konsole.desktop", "preferred://filemanager", "applications:org.kde.kate.desktop"]);
