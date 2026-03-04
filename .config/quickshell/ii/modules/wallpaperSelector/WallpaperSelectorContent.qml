import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Qt5Compat.GraphicalEffects as GE
import Quickshell
import Quickshell.Io

MouseArea {
    id: root
    property int horizontalJump: 1
    property real previewCellAspectRatio: screenAspectRatio
    readonly property real stripPadding: 2
    readonly property int visibleItems: 3
    readonly property int loopCopies: 9
    readonly property real desiredItemWidth: Math.max(110, (Appearance.sizes.wallpaperSelectorWidth * 1.2 - stripPadding * 2 - (visibleItems - 1)) / visibleItems)
    readonly property real desiredItemHeight: desiredItemWidth / previewCellAspectRatio
    readonly property real preferredHeight: desiredItemHeight + stripPadding * 2
    property bool useDarkMode: Appearance.m3colors.darkmode
    property string _lastThumbnailSizeName: ""
    property string _lastPreviewAppliedPath: ""
    property string _pendingPreviewPath: ""
    property bool _closeOnNextWallpaperChange: false
    property real _wheelPixelRemainder: 0
    property real _wheelAngleRemainder: 0
    property bool _wheelNavigationActive: false
    readonly property bool livePreviewEnabled: Config.options?.wallpaperSelector?.livePreview ?? true
    readonly property string foldersRootPath: {
        let p = FileUtils.trimFileProtocol(String(Wallpapers.defaultFolder ?? `${Directories.home}/Wallpapers`))
        if (p.length > 1) p = p.replace(/\/+$/, "")
        return p
    }
    property string folderStripParentPath: ""
    property var folderStripPaths: []
    property int folderStripIndex: 0
    readonly property string currentAppliedWallpaperPath: FileUtils.trimFileProtocol(String(effectiveCurrentWallpaperPath() ?? ""))

    // Multi-monitor support — capture focused monitor at open time
    property string _lockedTarget: ""
    property string _capturedMonitor: ""
    readonly property bool multiMonitorActive: Config.options?.background?.multiMonitor?.enable ?? false

    readonly property string selectedMonitor: {
        if (!multiMonitorActive) return ""
        if (_lockedTarget) return _lockedTarget
        return _capturedMonitor
    }
    readonly property real screenAspectRatio: {
        let screen = null;
        if (selectedMonitor) {
            screen = Quickshell.screens.find(s => s.name === selectedMonitor) ?? null;
        }
        if (!screen) {
            screen = Quickshell.screens[0] ?? null;
        }
        const width = screen?.width ?? 16;
        const height = screen?.height ?? 9;
        return height > 0 ? width / height : (16 / 9);
    }

    Component.onCompleted: {
        // Read target monitor from GlobalStates (set before opening, no timing issues)
        const gsTarget = GlobalStates.wallpaperSelectorTargetMonitor ?? ""
        if (gsTarget && WallpaperListener.screenNames.includes(gsTarget)) {
            _lockedTarget = gsTarget
        } else {
            // Fallback: check Config (for settings UI "Change" button via IPC)
            const configTarget = Config.options?.wallpaperSelector?.targetMonitor ?? ""
            if (configTarget && WallpaperListener.screenNames.includes(configTarget)) {
                _lockedTarget = configTarget
            } else if (CompositorService.isNiri) {
                // Last resort: capture focused monitor (may be stale if overlay already took focus)
                _capturedMonitor = NiriService.currentOutput ?? ""
            } else if (CompositorService.isHyprland) {
                _capturedMonitor = Hyprland.focusedMonitor?.name ?? ""
            }
        }
        root.syncFolderStripsWithCurrentDirectory()
        Qt.callLater(() => wallpaperGridBackground.forceActiveFocus())
    }

    function updateThumbnails() {
        const totalImageMargin = (Appearance.sizes.wallpaperSelectorItemMargins + Appearance.sizes.wallpaperSelectorItemPadding) * 2
        const thumbnailSizeName = Images.thumbnailSizeNameForDimensions(grid.itemWidth - totalImageMargin, grid.itemHeight - totalImageMargin)
        root._lastThumbnailSizeName = thumbnailSizeName
        Wallpapers.generateThumbnail(thumbnailSizeName)
    }

    function normalizePath(path) {
        let p = FileUtils.trimFileProtocol(String(path ?? ""))
        if (p.length > 1) p = p.replace(/\/+$/, "")
        return p
    }

    function refreshFolderStripPaths() {
        const currentDir = normalizePath(Wallpapers.effectiveDirectory)
        const rootDir = normalizePath(root.foldersRootPath)
        const paths = []
        if (rootDir.length > 0) paths.push(rootDir)
        for (let i = 0; i < folderStripModel.count; ++i) {
            const path = normalizePath(folderStripModel.get(i, "filePath"))
            if (path && path.length > 0 && path !== rootDir) paths.push(path)
        }
        root.folderStripPaths = paths
        const idx = paths.indexOf(currentDir)
        if (idx >= 0) {
            root.folderStripIndex = idx
            return
        }
        // Keep current directory stable while FolderListModel is still loading.
        // Auto-resetting to root here causes "first keypress does nothing" behavior.
        if (paths.length <= 0) {
            root.folderStripIndex = 0
            return
        }
        const rootPrefix = rootDir.endsWith("/") ? rootDir : (rootDir + "/")
        const insideRoot = currentDir === rootDir || currentDir.startsWith(rootPrefix)
        if (currentDir.length === 0 || !insideRoot) {
            root.folderStripIndex = 0
            Wallpapers.setDirectory(paths[0], true)
            return
        }
        root.folderStripIndex = Math.max(0, Math.min(root.folderStripIndex, paths.length - 1))
    }

    function syncFolderStripsWithCurrentDirectory() {
        const targetParent = normalizePath(root.foldersRootPath)
        if (targetParent.length === 0) return
        if (root.folderStripParentPath !== targetParent) {
            root.folderStripParentPath = targetParent
            folderStripModel.folder = Qt.resolvedUrl(targetParent)
        } else {
            refreshFolderStripPaths()
        }
    }

    function switchFolder(delta) {
        const paths = root.folderStripPaths
        const count = paths.length
        if (count <= 0) return
        if (!delta || delta === 0) return
        root.rememberCurrentFolderStop()

        const currentDir = normalizePath(Wallpapers.effectiveDirectory)
        const resolvedIndex = paths.indexOf(currentDir)
        const baseIndex = resolvedIndex >= 0 ? resolvedIndex : root.folderStripIndex
        const step = delta < 0 ? -1 : 1

        let nextIndex = ((baseIndex + step) % count + count) % count
        let targetPath = normalizePath(paths[nextIndex])

        // In case of stale index state, ensure one keypress always moves to another folder.
        if (count > 1 && targetPath === currentDir) {
            nextIndex = ((nextIndex + step) % count + count) % count
            targetPath = normalizePath(paths[nextIndex])
        }

        root.folderStripIndex = nextIndex
        Wallpapers.setDirectory(targetPath, true)
    }

    Connections {
        target: Wallpapers
        function onDirectoryChanged() {
            root.syncFolderStripsWithCurrentDirectory()
            root.updateThumbnails()
        }
        function onThumbnailGenerated(directory) {
            if (root.normalizePath(directory) !== root.normalizePath(Wallpapers.effectiveDirectory)) return
            Wallpapers.preloadThumbnailsForFolders(root.folderStripPaths, root.folderStripIndex, root._lastThumbnailSizeName || "large", 1, false)
        }
    }

    Connections {
        target: Wallpapers.folderModel
        function onFolderChanged() {
            Qt.callLater(() => {
                if (grid && grid.sourceCount > 0) grid.resetForCurrentDirectory();
            })
        }
        function onCountChanged() {
            Qt.callLater(() => {
                if (grid && grid.sourceCount > 0) grid.resetForCurrentDirectory();
            })
        }
    }

    function handleFilePasting(event) {
        event.accepted = false
    }

    FolderListModel {
        id: folderStripModel
        folder: Qt.resolvedUrl(root.folderStripParentPath || root.foldersRootPath)
        showDirs: true
        showFiles: false
        showDotAndDotDot: false
        showOnlyReadable: true
        sortField: FolderListModel.Name
        sortReversed: false
        onCountChanged: root.refreshFolderStripPaths()
        onFolderChanged: root.refreshFolderStripPaths()
    }

    function applyMainWallpaperPreview(normalizedPath, needsThumbnail) {
        if (root.multiMonitorActive && root.selectedMonitor && root.selectedMonitor.length > 0) {
            Wallpapers.updatePerMonitorConfig(normalizedPath, root.selectedMonitor);
            return;
        }

        Config.setNestedValue("background.wallpaperPath", normalizedPath);
        if (needsThumbnail) {
            Wallpapers.generateThumbnail("large");
            const thumbnailPath = Wallpapers.getExpectedThumbnailPath(normalizedPath, "large");
            Config.setNestedValue("background.thumbnailPath", thumbnailPath);
        } else {
            Config.setNestedValue("background.thumbnailPath", "");
        }
    }

    function selectWallpaperPath(filePath, closeSelector = true) {
        if (filePath && filePath.length > 0) {
            const normalizedPath = FileUtils.trimFileProtocol(String(filePath))
            // Check Config first (set by settings.qml via IPC), then GlobalStates
            const configTarget = Config.options?.wallpaperSelector?.selectionTarget;
            let target = (configTarget && configTarget !== "main") ? configTarget : GlobalStates.wallpaperSelectionTarget;
            
            // Check if it's a video or GIF that needs thumbnail generation
            const lowerPath = normalizedPath.toLowerCase();
            const isVideo = lowerPath.endsWith(".mp4") || lowerPath.endsWith(".webm") || lowerPath.endsWith(".mkv") || lowerPath.endsWith(".avi") || lowerPath.endsWith(".mov");
            const isGif = lowerPath.endsWith(".gif");
            const needsThumbnail = isVideo || isGif;
            
            switch (target) {
                case "backdrop":
                    Config.setNestedValue("background.backdrop.useMainWallpaper", false);
                    Config.setNestedValue("background.backdrop.wallpaperPath", normalizedPath);
                    // Generate and set thumbnail for video/GIF
                    if (needsThumbnail) {
                        Wallpapers.generateThumbnail("large"); // Ensure generation is triggered
                        const thumbnailPath = Wallpapers.getExpectedThumbnailPath(normalizedPath, "large");
                        Config.setNestedValue("background.backdrop.thumbnailPath", thumbnailPath);
                    }
                    // If using backdrop for colors, regenerate theme colors
                    if (closeSelector && Config.options?.appearance?.wallpaperTheming?.useBackdropForColors) {
                        Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--noswitch"])
                    }
                    break;
                case "waffle":
                    Config.setNestedValue("waffles.background.useMainWallpaper", false);
                    Config.setNestedValue("waffles.background.wallpaperPath", normalizedPath);
                    // Generate and set thumbnail for video/GIF (used as fallback/preview)
                    if (needsThumbnail) {
                        Wallpapers.generateThumbnail("large");
                        const thumbnailPath = Wallpapers.getExpectedThumbnailPath(normalizedPath, "large");
                        Config.setNestedValue("waffles.background.thumbnailPath", thumbnailPath);
                    }
                    break;
                case "waffle-backdrop":
                    Config.setNestedValue("waffles.background.backdrop.useMainWallpaper", false);
                    Config.setNestedValue("waffles.background.backdrop.wallpaperPath", normalizedPath);
                    // Generate and set thumbnail for video/GIF
                    if (needsThumbnail) {
                        Wallpapers.generateThumbnail("large");
                        const thumbnailPath = Wallpapers.getExpectedThumbnailPath(normalizedPath, "large");
                        Config.setNestedValue("waffles.background.backdrop.thumbnailPath", thumbnailPath);
                    }
                    break;
                default: // "main"
                    if (closeSelector) {
                        Wallpapers.select(normalizedPath, root.useDarkMode, root.selectedMonitor);
                    } else {
                        applyMainWallpaperPreview(normalizedPath, needsThumbnail);
                    }
                    break;
            }
            if (closeSelector) {
                // Reset GlobalStates only (Config resets on its own via defaults)
                root._closeOnNextWallpaperChange = true;
                GlobalStates.wallpaperSelectionTarget = "main";
            }
        }
    }

    function normalizedIndex(index, count) {
        if (count <= 0)
            return 0;
        let result = index % count;
        if (result < 0)
            result += count;
        return result;
    }

    function currentWallpaperIndexInFolder() {
        const count = Wallpapers.folderModel.count;
        const currentPath = effectiveCurrentWallpaperPath();
        if (count <= 0 || !currentPath)
            return 0;
        for (let i = 0; i < count; ++i) {
            const path = Wallpapers.folderModel.get(i, "filePath");
            if (path === currentPath)
                return i;
        }
        return 0;
    }

    function rememberedWallpaperIndexInFolder() {
        const count = Wallpapers.folderModel.count;
        if (count <= 0)
            return 0;
        if (!folderModelMatchesCurrentDirectory())
            return 0;
        const rememberedPath = FileUtils.trimFileProtocol(String(Wallpapers.rememberedSelectorWallpaper(Wallpapers.effectiveDirectory) ?? ""));
        if (!rememberedPath || rememberedPath.length === 0)
            return currentWallpaperIndexInFolder();
        for (let i = 0; i < count; ++i) {
            const path = FileUtils.trimFileProtocol(String(Wallpapers.folderModel.get(i, "filePath") ?? ""));
            if (path === rememberedPath)
                return i;
        }
        return currentWallpaperIndexInFolder();
    }

    function rememberCurrentFolderStop() {
        if (!grid)
            return;
        const count = Wallpapers.folderModel.count;
        if (count <= 0)
            return;
        if (!folderModelMatchesCurrentDirectory())
            return;
        const sourceIndex = root.normalizedIndex(grid.logicalIndex, count);
        const filePath = Wallpapers.folderModel.get(sourceIndex, "filePath");
        const isDir = Wallpapers.folderModel.get(sourceIndex, "fileIsDir");
        if (isDir || !filePath)
            return;
        if (!directoryContainsFile(Wallpapers.effectiveDirectory, filePath))
            return;
        Wallpapers.rememberSelectorWallpaper(Wallpapers.effectiveDirectory, filePath);
    }

    function directoryContainsFile(directoryPath, filePath) {
        const dir = normalizePath(directoryPath);
        const file = normalizePath(filePath);
        if (!dir || !file || file.length === 0)
            return false;
        const prefix = dir.endsWith("/") ? dir : (dir + "/");
        return file.startsWith(prefix);
    }

    function folderModelMatchesCurrentDirectory() {
        const count = Wallpapers.folderModel.count;
        if (count <= 0)
            return false;
        const currentDir = normalizePath(Wallpapers.effectiveDirectory);
        if (!currentDir || currentDir.length === 0)
            return false;
        const samplePath = Wallpapers.folderModel.get(0, "filePath");
        if (!samplePath)
            return false;
        return directoryContainsFile(currentDir, samplePath);
    }

    function effectiveCurrentWallpaperPath() {
        const globalPath = Config.options?.background?.wallpaperPath ?? "";
        const multiMonitor = Config.options?.background?.multiMonitor?.enable ?? false;
        if (!multiMonitor)
            return globalPath;
        const monitor = root.selectedMonitor || WallpaperListener.getFocusedMonitor();
        if (!monitor)
            return globalPath;
        const monitorData = WallpaperListener.effectivePerMonitor?.[monitor];
        return monitorData?.path ?? globalPath;
    }

    function _applyScrollStep(direction) {
        if (!grid || Wallpapers.folderModel.count <= 0)
            return;
        grid.moveSelection(direction);
    }

    function _consumeScroll(value, threshold, pixelSource) {
        if (pixelSource) {
            root._wheelPixelRemainder += value;
            while (Math.abs(root._wheelPixelRemainder) >= threshold) {
                root._applyScrollStep(root._wheelPixelRemainder > 0 ? -1 : 1);
                root._wheelPixelRemainder += root._wheelPixelRemainder > 0 ? -threshold : threshold;
            }
            return;
        }
        root._wheelAngleRemainder += value;
        while (Math.abs(root._wheelAngleRemainder) >= threshold) {
            root._applyScrollStep(root._wheelAngleRemainder > 0 ? -1 : 1);
            root._wheelAngleRemainder += root._wheelAngleRemainder > 0 ? -threshold : threshold;
        }
    }

    Timer {
        id: previewApplyDebounce
        interval: 120
        repeat: false
        onTriggered: {
            if (!root._pendingPreviewPath || root._pendingPreviewPath.length === 0)
                return;
            if (root._pendingPreviewPath === root._lastPreviewAppliedPath)
                return;
            root._lastPreviewAppliedPath = root._pendingPreviewPath;
            root.selectWallpaperPath(root._pendingPreviewPath, false);
        }
    }

    Timer {
        id: wheelNavigationIdle
        interval: 220
        repeat: false
        onTriggered: {
            root._wheelNavigationActive = false;
        }
    }

    acceptedButtons: Qt.LeftButton | Qt.BackButton | Qt.ForwardButton

    onClicked: mouse => {
        const localPos = mapToItem(wallpaperGridBackground, mouse.x, mouse.y);
        const outside = (localPos.x < 0 || localPos.x > wallpaperGridBackground.width
                || localPos.y < 0 || localPos.y > wallpaperGridBackground.height);
        if (outside) {
            GlobalStates.wallpaperSelectorOpen = false;
        } else {
            mouse.accepted = false;
        }
    }

    onPressed: event => {
        if (event.button === Qt.BackButton) {
            event.accepted = true;
        } else if (event.button === Qt.ForwardButton) {
            event.accepted = true;
        } else {
            event.accepted = false;
        }
    }

    function handleWheelNavigation(event) {
        if (!GlobalStates.wallpaperSelectorOpen || Wallpapers.folderModel.count <= 0) {
            event.accepted = false;
            return;
        }
        root._wheelNavigationActive = true;
        wheelNavigationIdle.restart();

        const pixelDominant = Math.abs(event.pixelDelta.y) >= Math.abs(event.pixelDelta.x)
            ? event.pixelDelta.y
            : -event.pixelDelta.x;
        if (pixelDominant !== 0) {
            root._consumeScroll(pixelDominant, 36, true);
            event.accepted = true;
            return;
        }

        const angleDominant = Math.abs(event.angleDelta.y) >= Math.abs(event.angleDelta.x)
            ? event.angleDelta.y
            : -event.angleDelta.x;
        if (angleDominant !== 0) {
            root._consumeScroll(angleDominant, 120, false);
            event.accepted = true;
            return;
        }

        event.accepted = false;
    }

    onWheel: event => {
        root.handleWheelNavigation(event);
    }

    Keys.onPressed: event => {
        if (event.isAutoRepeat && (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Escape) {
            GlobalStates.wallpaperSelectorOpen = false;
            event.accepted = true;
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_V) { // Intercept Ctrl+V to handle "paste to go to" in pickers
            root.handleFilePasting(event);
        } else if (event.modifiers & Qt.AltModifier && event.key === Qt.Key_Up) {
            event.accepted = true;
        } else if (event.modifiers & Qt.AltModifier && event.key === Qt.Key_Left) {
            event.accepted = true;
        } else if (event.modifiers & Qt.AltModifier && event.key === Qt.Key_Right) {
            event.accepted = true;
        } else if (event.key === Qt.Key_Left) {
            grid.moveSelection(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right) {
            grid.moveSelection(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Up) {
            root.switchFolder(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Down) {
            root.switchFolder(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            grid.activateCurrent();
            event.accepted = true;
        }
    }

    implicitHeight: mainLayout.implicitHeight
    implicitWidth: mainLayout.implicitWidth

    StyledRectangularShadow {
        target: wallpaperGridBackground
        visible: !Appearance.inirEverywhere
    }
    GlassBackground {
        id: wallpaperGridBackground
        anchors {
            fill: parent
            margins: Appearance.sizes.elevationMargin
        }
        focus: true
        Keys.forwardTo: [root]
        border.width: (Appearance.inirEverywhere || Appearance.auroraEverywhere) ? 1 : 1
        border.color: Appearance.angelEverywhere ? Appearance.angel.colCardBorder
            : Appearance.inirEverywhere ? Appearance.inir.colBorder 
            : Appearance.auroraEverywhere ? Appearance.aurora.colTooltipBorder : Appearance.colors.colLayer0Border
        fallbackColor: Appearance.colors.colLayer0
        inirColor: Appearance.inir.colLayer0
        auroraTransparency: Appearance.aurora.overlayTransparentize
        radius: Appearance.angelEverywhere ? Appearance.angel.roundingLarge
            : Appearance.inirEverywhere ? Appearance.inir.roundingLarge 
            : (Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1)

        property int calculatedRows: 1

        implicitWidth: mainLayout.implicitWidth
        implicitHeight: mainLayout.implicitHeight

        Item {
            id: mainLayout
            anchors.fill: parent
            RowLayout {
                anchors.fill: parent
                spacing: 8

                Item {
                    id: folderStripRegion
                    visible: false
                    Layout.fillHeight: true
                    Layout.preferredWidth: 0
                    Layout.leftMargin: 2

                    ListView {
                        id: folderStripList
                        anchors.fill: parent
                        anchors.topMargin: root.stripPadding
                        anchors.bottomMargin: root.stripPadding
                        spacing: 6
                        clip: true
                        interactive: root.folderStripPaths.length > 10
                        model: root.folderStripPaths

                        delegate: MouseArea {
                            id: folderStripItem
                            required property int index
                            required property string modelData
                            readonly property string folderName: {
                                const trimmed = String(modelData ?? "").replace(/\/+$/, "")
                                const parts = trimmed.split("/")
                                return parts.length > 0 ? parts[parts.length - 1] : trimmed
                            }
                            width: folderStripList.width
                            height: 24
                            hoverEnabled: true
                            onClicked: {
                                root.rememberCurrentFolderStop()
                                root.folderStripIndex = index
                                Wallpapers.setDirectory(modelData, true)
                            }

                            RowLayout {
                                anchors.fill: parent
                                spacing: 8

                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    Layout.preferredWidth: 6
                                    Layout.preferredHeight: parent.height
                                    radius: width / 2
                                    color: index === root.folderStripIndex
                                        ? Appearance.colors.colPrimary
                                        : (folderStripItem.containsMouse
                                            ? ColorUtils.transparentize(Appearance.colors.colSecondaryContainer)
                                            : ColorUtils.transparentize(Appearance.colors.colOutline))
                                    opacity: index === root.folderStripIndex ? 1 : 0.75
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignVCenter
                                    text: folderName
                                    elide: Text.ElideRight
                                    color: index === root.folderStripIndex
                                        ? Appearance.colors.colOnLayer0
                                        : ColorUtils.transparentize(Appearance.colors.colOnLayer1)
                                    font.pixelSize: Appearance.font.pixelSize.small
                                }
                            }
                        }
                    }
                }

                Item {
                    id: gridDisplayRegion
                    Layout.fillHeight: true
                    Layout.fillWidth: true

                    StyledIndeterminateProgressBar {
                        id: indeterminateProgressBar
                        visible: Wallpapers.thumbnailGenerationRunning && value == 0
                        anchors {
                            bottom: parent.top
                            left: parent.left
                            right: parent.right
                            leftMargin: 4
                            rightMargin: 4
                        }
                    }

                    StyledProgressBar {
                        visible: Wallpapers.thumbnailGenerationRunning && value > 0
                        value: Wallpapers.thumbnailGenerationProgress
                        anchors.fill: indeterminateProgressBar
                    }

                    ListView {
                        id: grid
                        visible: Wallpapers.folderModel.count > 0
                        readonly property int sourceCount: Wallpapers.folderModel.count
                        readonly property int loopedCount: sourceCount > 0 ? sourceCount * root.loopCopies : 0
                        property int logicalIndex: 0
                        property bool suppressIndexHandlers: false
                        property real itemHeight: Math.min(root.desiredItemHeight, Math.max(50, height))
                        property real itemWidth: itemHeight * root.previewCellAspectRatio

                        anchors.fill: parent
                        anchors.margins: root.stripPadding
                        orientation: ListView.Horizontal
                        spacing: 1
                        interactive: true
                        clip: true
                        cacheBuffer: Math.max(itemWidth * 8, 800)
                        boundsBehavior: Flickable.StopAtBounds
                        highlightRangeMode: ListView.StrictlyEnforceRange
                        preferredHighlightBegin: Math.max(0, (width - itemWidth) / 2)
                        preferredHighlightEnd: Math.max(0, (width + itemWidth) / 2)
                        highlightMoveDuration: 240
                        snapMode: ListView.SnapToItem

                    function centerBlockIndex() {
                        if (sourceCount <= 0 || loopedCount <= 0)
                            return 0;
                        const segment = sourceCount;
                        return Math.floor(loopedCount / (2 * segment)) * segment;
                    }

                    function displayIndexForLogical(index) {
                        if (sourceCount <= 0 || loopedCount <= 0)
                            return 0;
                        const normalized = root.normalizedIndex(index, sourceCount);
                        return centerBlockIndex() + normalized;
                    }

                    function syncLogicalFromCurrent() {
                        if (sourceCount <= 0 || loopedCount <= 0)
                            return;
                        logicalIndex = root.normalizedIndex(currentIndex, sourceCount);
                    }

                    function recenterLoopIfNeeded() {
                        if (sourceCount <= 0 || loopedCount <= 0)
                            return;
                        if (moving || flicking || dragging)
                            return;
                        const segment = sourceCount;
                        const margin = segment * 2;
                        if (currentIndex > margin && currentIndex < loopedCount - margin)
                            return;
                        const target = displayIndexForLogical(logicalIndex);
                        if (target === currentIndex)
                            return;
                        suppressIndexHandlers = true;
                        currentIndex = target;
                        positionViewAtIndex(currentIndex, ListView.Center);
                        suppressIndexHandlers = false;
                    }

                    function moveSelection(delta) {
                        if (sourceCount <= 0 || loopedCount <= 0)
                            return;
                        const step = delta < 0 ? -1 : 1;
                        // Keep index in the middle copy to preserve headroom for "infinite" navigation.
                        const segment = sourceCount;
                        const margin = segment * 2;
                        if (currentIndex <= margin || currentIndex >= loopedCount - margin - 1) {
                            const midTarget = displayIndexForLogical(logicalIndex);
                            suppressIndexHandlers = true;
                            currentIndex = midTarget;
                            positionViewAtIndex(currentIndex, ListView.Center);
                            suppressIndexHandlers = false;
                        }
                        if (step < 0)
                            decrementCurrentIndex();
                        else
                            incrementCurrentIndex();
                    }

                        function resetForCurrentDirectory() {
                            if (sourceCount <= 0 || loopedCount <= 0)
                                return;
                            if (!root.folderModelMatchesCurrentDirectory()) {
                                resetRetry.restart();
                                return;
                            }
                            logicalIndex = root.rememberedWallpaperIndexInFolder();
                            const target = displayIndexForLogical(logicalIndex);
                            suppressIndexHandlers = true;
                            currentIndex = target;
                            positionViewAtIndex(currentIndex, ListView.Center);
                            suppressIndexHandlers = false;
                        }

                        Timer {
                            id: resetRetry
                            interval: 30
                            repeat: false
                            onTriggered: grid.resetForCurrentDirectory()
                        }

                        function activateCurrent() {
                            if (sourceCount <= 0)
                                return;
                            const sourceIndex = root.normalizedIndex(logicalIndex, sourceCount);
                            const filePath = Wallpapers.folderModel.get(sourceIndex, "filePath");
                            root.selectWallpaperPath(filePath);
                        }

                    function applyPreviewCurrent() {
                        if (sourceCount <= 0)
                            return;
                        const sourceIndex = root.normalizedIndex(logicalIndex, sourceCount);
                        const filePath = Wallpapers.folderModel.get(sourceIndex, "filePath");
                        const isDir = Wallpapers.folderModel.get(sourceIndex, "fileIsDir");
                        if (isDir || !filePath)
                            return;
                        const normalized = FileUtils.trimFileProtocol(String(filePath));
                        if (normalized === root._lastPreviewAppliedPath)
                            return;
                        root._pendingPreviewPath = normalized;
                        previewApplyDebounce.restart();
                    }

                    Component.onCompleted: {
                        root.updateThumbnails();
                        if (sourceCount <= 0)
                            return;
                        resetForCurrentDirectory();
                    }

                    onCurrentIndexChanged: {
                        if (suppressIndexHandlers)
                            return;
                        syncLogicalFromCurrent();
                        recenterLoopIfNeeded();
                        root.rememberCurrentFolderStop();
                        if (root.livePreviewEnabled) {
                            applyPreviewCurrent();
                        } else {
                            previewApplyDebounce.stop();
                            root._pendingPreviewPath = "";
                        }
                    }
                    onMovementEnded: recenterLoopIfNeeded()
                    onFlickEnded: recenterLoopIfNeeded()
                    onSourceCountChanged: {
                        if (sourceCount <= 0)
                            return;
                        resetForCurrentDirectory();
                    }

                    model: loopedCount
                    delegate: WallpaperDirectoryItem {
                        required property int index
                        readonly property int sourceIndex: root.normalizedIndex(index, grid.sourceCount)
                        readonly property string normalizedFilePath: FileUtils.trimFileProtocol(String(fileModelData.filePath ?? ""))
                        readonly property string normalizedCurrentPath: root.currentAppliedWallpaperPath
                        readonly property bool isAppliedWallpaper: !fileModelData.fileIsDir && normalizedFilePath.length > 0 && normalizedFilePath === normalizedCurrentPath
                        fileModelData: ({
                            filePath: Wallpapers.folderModel.get(sourceIndex, "filePath"),
                            fileName: Wallpapers.folderModel.get(sourceIndex, "fileName"),
                            fileIsDir: Wallpapers.folderModel.get(sourceIndex, "fileIsDir"),
                            fileUrl: Wallpapers.folderModel.get(sourceIndex, "fileUrl")
                        })
                        width: grid.itemWidth
                        height: grid.itemHeight
                        colBackground: (index === grid.currentIndex) ? Appearance.colors.colPrimary : ColorUtils.transparentize(Appearance.colors.colPrimaryContainer)
                        colText: (index === grid.currentIndex) ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer0
                        borderWidth: isAppliedWallpaper ? 1 : 0
                        borderColor: isAppliedWallpaper ? Appearance.colors.colSecondary : "transparent"

                        onEntered: {}

                        onActivated: {
                            root.selectWallpaperPath(fileModelData.filePath);
                        }
                    }

                        layer.enabled: true
                        layer.effect: GE.OpacityMask {
                            maskSource: GE.LinearGradient {
                                width: gridDisplayRegion.width
                                height: gridDisplayRegion.height
                                start: Qt.point(0, 0)
                                end: Qt.point(width, 0)
                                gradient: Gradient {
                                    GradientStop {
                                        position: 0.0
                                        color: "#00ffffff"
                                    }
                                    GradientStop {
                                        position: 0.08
                                        color: "#ffffffff"
                                    }
                                    GradientStop {
                                        position: 0.92
                                        color: "#ffffffff"
                                    }
                                    GradientStop {
                                        position: 1.0
                                        color: "#00ffffff"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Connections {
        target: GlobalStates
        function onWallpaperSelectorOpenChanged() {
            if (GlobalStates.wallpaperSelectorOpen) {
                Qt.callLater(() => wallpaperGridBackground.forceActiveFocus());
            }
        }
    }

    Connections {
        target: Wallpapers
        function onChanged() {
            if (root._closeOnNextWallpaperChange) {
                root._closeOnNextWallpaperChange = false;
                GlobalStates.wallpaperSelectorOpen = false;
            }
        }
    }
}
