// The panel's pinned launchers when the session makes its panel (Plasma runs
// the look-and-feel's setup script for each applet it adds): Konsole, the
// file manager and the browser, in place of the task manager's default
// System Settings and Discover (Discover is not in the image).
applet.currentConfigGroup = ["General"];
applet.writeConfig("launchers", ["applications:org.kde.konsole.desktop", "preferred://filemanager", "preferred://browser"]);
