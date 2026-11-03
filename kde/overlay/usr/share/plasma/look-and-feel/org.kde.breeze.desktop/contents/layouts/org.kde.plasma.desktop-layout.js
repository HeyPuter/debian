loadTemplate("org.kde.plasma.desktop.defaultPanel")

var desktopsArray = desktopsForActivity(currentActivity());
for( var j = 0; j < desktopsArray.length; j++) {
    desktopsArray[j].wallpaperPlugin = 'org.kde.image';
}

// The system tray's applets: those Plasma enables by default, without the
// camera indicator, which needs PipeWire (not in the image) and shows only
// its error
var trays = panels().reduce(function (a, p) { return a.concat(p.widgets("org.kde.plasma.systemtray")); }, []);
for (var i = 0; i < trays.length; i++) {
    var inner = desktopById(trays[i].readConfig("SystrayContainmentId"));
    if (!inner) continue;
    inner.currentConfigGroup = ["General"];
    inner.writeConfig("extraItems", ["org.kde.plasma.notifications", "org.kde.plasma.devicenotifier",
        "org.kde.plasma.keyboardlayout", "org.kde.plasma.mediacontroller", "org.kde.plasma.clipboard",
        "org.kde.plasma.manage-inputmethod"]);
    inner.writeConfig("knownItems", ["org.kde.plasma.notifications", "org.kde.plasma.devicenotifier",
        "org.kde.plasma.keyboardlayout", "org.kde.plasma.mediacontroller", "org.kde.plasma.clipboard",
        "org.kde.plasma.manage-inputmethod", "org.kde.plasma.cameraindicator"]);
    // Plasma's own "Software Renderer In Use" item (a video card with a
    // question mark) in the hidden part: the page draws Plasma in software
    // always, and the item's click does nothing
    inner.writeConfig("hiddenItems", ["plasmashell"]);
}
