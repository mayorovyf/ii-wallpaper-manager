pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs.modules.common.models
import qs.modules.common.functions
import qs.services
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import "root:"
import "root:modules/common/functions/md5.js" as MD5

Singleton {
    id: root

    readonly property bool _debugWallpaperUrls: (Quickshell.env("INIR_DEBUG_WALLPAPER_URLS") ?? "") === "1"

    // Wallpaper path resolution for aurora/backdrop
    readonly property bool isWaffleFamily: (Config.options?.panelFamily ?? "ii") === "waffle"
    readonly property bool useBackdropWallpaper: isWaffleFamily
        ? (Config.options?.waffles?.background?.backdrop?.hideWallpaper ?? false)
        : (Config.options?.background?.backdrop?.hideWallpaper ?? false)

    // Resolve the "main" wallpaper path — multi-monitor aware
    // When multi-monitor is enabled, uses the focused monitor's wallpaper
    // so Aurora blur/glass on all panels matches what's actually on screen.
    readonly property string _resolvedMainWallpaperPath: {
        if (WallpaperListener.multiMonitorEnabled) {
            const focused = WallpaperListener.getFocusedMonitor()
            if (focused) {
                const data = WallpaperListener.effectivePerMonitor[focused]
                if (data && data.path) return data.path
            }
        }
        return Config.options?.background?.wallpaperPath ?? ""
    }

    readonly property bool useBackdropForColors: Config.options?.appearance?.wallpaperTheming?.useBackdropForColors ?? false

    readonly property string effectiveWallpaperPath: {
        if (useBackdropWallpaper || useBackdropForColors) {
            if (isWaffleFamily) {
                const wBackdrop = Config.options?.waffles?.background?.backdrop ?? {}
                const useBackdropOwn = !(wBackdrop.useMainWallpaper ?? true)
                if (useBackdropOwn && wBackdrop.wallpaperPath) return wBackdrop.wallpaperPath
                const wBg = Config.options?.waffles?.background ?? {}
                const useMainForWaffle = wBg.useMainWallpaper ?? true
                return useMainForWaffle ? _resolvedMainWallpaperPath : (wBg.wallpaperPath || _resolvedMainWallpaperPath)
            }
            const iiBackdrop = Config.options?.background?.backdrop ?? {}
            const useMain = iiBackdrop.useMainWallpaper ?? true
            const mainPath = _resolvedMainWallpaperPath
            return useMain ? mainPath : (iiBackdrop.wallpaperPath || mainPath)
        }
        if (isWaffleFamily) {
            const wBg = Config.options?.waffles?.background ?? {}
            const useMain = wBg.useMainWallpaper ?? true
            if (useMain) return _resolvedMainWallpaperPath
            return wBg.wallpaperPath || _resolvedMainWallpaperPath
        }
        return _resolvedMainWallpaperPath
    }

    readonly property string effectiveWallpaperUrl: {
        const path = root.effectiveWallpaperPath
        if (!path || path.length === 0) return ""
        // For videos, return image-safe URL (all consumers are Image/ColorQuantizer)
        if (root.isVideoFile(path)) {
            const _dep = root.videoFirstFrames // reactive binding
            const ff = root.videoFirstFrames[path]
            // Cache-bust so Image(cache:true) surfaces reload when the first frame appears.
            if (ff) return (ff.startsWith("file://") ? ff : "file://" + ff) + "?ff=1"
            const expected = root._videoThumbDir + "/" + MD5.hash(path) + ".jpg"
            root.ensureVideoFirstFrame(path)
            return "file://" + expected + "?ff=0"
        }
        return path.startsWith("file://") ? path : ("file://" + path)
    }

    onEffectiveWallpaperUrlChanged: {
        if (root._debugWallpaperUrls) {
            console.log("[Wallpapers] effectiveWallpaperPath=", root.effectiveWallpaperPath)
            console.log("[Wallpapers] effectiveWallpaperUrl=", root.effectiveWallpaperUrl)
        }
    }

    // ── Video first-frame system ──────────────────────────────────────────
    // Generates and caches first-frame JPGs for video wallpapers
    readonly property string _videoThumbDir: {
        const xdgCache = Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")
        return xdgCache + "/quickshell/video_thumbnails"
    }

    property var videoFirstFrames: ({})

    function isVideoFile(path: string): bool {
        if (!path) return false
        const lp = path.toLowerCase()
        return lp.endsWith(".mp4") || lp.endsWith(".webm") || lp.endsWith(".mkv") || lp.endsWith(".avi") || lp.endsWith(".mov")
    }

    function getVideoFirstFramePath(videoPath: string): string {
        if (!videoPath) return ""
        return root.videoFirstFrames[videoPath] ?? ""
    }

    property var _ffPending: ({})

    function ensureVideoFirstFrame(videoPath: string) {
        if (!videoPath || !isVideoFile(videoPath)) return
        if (root.videoFirstFrames[videoPath]) return
        if (root._ffPending[videoPath]) return

        // Check config thumbnailPath (global wallpaper match)
        const configWp = Config.options?.background?.wallpaperPath ?? ""
        const configThumb = Config.options?.background?.thumbnailPath ?? ""
        if (configWp === videoPath && configThumb) {
            const expected = root._videoThumbDir + "/" + MD5.hash(videoPath) + ".jpg"
            const thumbPath = FileUtils.trimFileProtocol(configThumb)
            if (thumbPath === expected) {
                _cacheFirstFrame(videoPath, expected)
                return
            }
        }

        // Queue async check → generate (with dedup)
        root._ffPending[videoPath] = true
        // Use md5 hash of full path to match switchwall.sh and avoid basename collisions
        const hash = MD5.hash(videoPath)
        const expectedPath = root._videoThumbDir + "/" + hash + ".jpg"
        root._ffQueue.push({ videoPath: videoPath, outputPath: expectedPath })
        if (!_ffCheckProc.running && !_ffGenProc.running) _processNextFF()
    }

    function _cacheFirstFrame(videoPath: string, imagePath: string) {
        const copy = Object.assign({}, root.videoFirstFrames)
        copy[videoPath] = imagePath
        root.videoFirstFrames = copy

        if (root._debugWallpaperUrls) {
            console.log("[Wallpapers] Cached first-frame:", videoPath, "->", imagePath)
        }
    }

    property var _ffQueue: []

    function _processNextFF() {
        if (root._ffQueue.length === 0) return
        const item = root._ffQueue.shift()
        _ffCheckProc._videoPath = item.videoPath
        _ffCheckProc._outputPath = item.outputPath
        _ffCheckProc.command = ["test", "-f", item.outputPath]
        _ffCheckProc.running = true
    }

    Process {
        id: _ffCheckProc
        property string _videoPath
        property string _outputPath
        onExited: (exitCode) => {
            if (exitCode === 0) {
                root._cacheFirstFrame(_ffCheckProc._videoPath, _ffCheckProc._outputPath)
                root._processNextFF()
            } else {
                _ffGenProc._videoPath = _ffCheckProc._videoPath
                _ffGenProc._outputPath = _ffCheckProc._outputPath
                _ffGenProc.command = ["bash", "-c",
                    "mkdir -p " + JSON.stringify(root._videoThumbDir) +
                    " && ffmpeg -y -i " + JSON.stringify(_ffCheckProc._videoPath) +
                    " -vframes 1 -q:v 2 " + JSON.stringify(_ffCheckProc._outputPath)]
                _ffGenProc.running = true
            }
        }
    }

    Process {
        id: _ffGenProc
        property string _videoPath
        property string _outputPath
        onExited: (exitCode) => {
            if (exitCode === 0) {
                root._cacheFirstFrame(_ffGenProc._videoPath, _ffGenProc._outputPath)
            }
            root._processNextFF()
        }
    }
    // ── End video first-frame system ──────────────────────────────────────

    property string thumbgenScriptPath: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/thumbnails/thumbgen-venv.sh`
    property string generateThumbnailsMagickScriptPath: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/thumbnails/generate-thumbnails-magick.sh`
    
    // Calculate standard Freedesktop thumbnail path
    // size: "normal" (128), "large" (256), "x-large" (512), "xx-large" (1024)
    function getExpectedThumbnailPath(filePath: string, size = "large"): string {
        if (!filePath) return ""
        // Ensure path is absolute and clean
        let cleanPath = FileUtils.trimFileProtocol(filePath)
        if (!cleanPath.startsWith("/")) cleanPath = Quickshell.env("PWD") + "/" + cleanPath
        
        // Encode URI path segments (similar to python urllib.parse.quote(p, safe=""))
        // JS encodeURIComponent encodes everything except A-Za-z0-9-_.!~*'()
        // We need to match Python's behavior for strict path encoding
        const parts = cleanPath.split("/")
        const encodedParts = parts.map(p => {
            // Manual encoding for characters that encodeURIComponent misses or handles differently if needed
            // But standard encodeURIComponent is usually close enough for file paths
            return encodeURIComponent(p).replace(/[!'()*]/g, function(c) {
                return '%' + c.charCodeAt(0).toString(16);
            });
        })
        const url = "file://" + encodedParts.join("/")
        
        const md5Hash = MD5.hash(url)
        const cacheDir = Quickshell.env("HOME") + "/.cache/thumbnails/" + size
        return cacheDir + "/" + md5Hash + ".png"
    }

    property alias directory: folderModel.folder
    readonly property string effectiveDirectory: FileUtils.trimFileProtocol(folderModel.folder.toString())
    property url defaultFolder: Qt.resolvedUrl(`${Directories.home}/Wallpapers`)
    property alias folderModel: folderModel
    property string searchQuery: ""
    readonly property list<string> extensions: ["jpg", "jpeg", "png", "webp", "avif", "bmp", "svg", "gif", "mp4", "webm", "mkv", "avi", "mov"]
    property list<string> wallpapers: []
    readonly property bool thumbnailGenerationRunning: thumbgenProc.running
    property real thumbnailGenerationProgress: 0

    function _normalizePath(path): string {
        if (!path) return ""
        const trimmed = FileUtils.trimFileProtocol(String(path))
        const stripped = trimmed.replace(/\/+$/, "")
        return stripped.length > 0 ? stripped : "/"
    }

    function _isPathInWallpaperRoot(path): bool {
        const rootPath = root._normalizePath(root.defaultFolder)
        const candidate = root._normalizePath(path)
        if (!rootPath || !candidate) return false
        if (candidate === rootPath) return true
        const rootPrefix = rootPath.endsWith("/") ? rootPath : (rootPath + "/")
        return candidate.startsWith(rootPrefix)
    }

    // Remember last focused wallpaper per directory for selector navigation.
    property var selectorRememberedWallpaperByDirectory: ({})

    function rememberSelectorWallpaper(directoryPath: string, filePath: string) {
        const dir = root._normalizePath(directoryPath)
        const file = FileUtils.trimFileProtocol(String(filePath ?? ""))
        if (!dir || dir.length === 0 || !file || file.length === 0) return
        const copy = Object.assign({}, root.selectorRememberedWallpaperByDirectory)
        copy[dir] = file
        root.selectorRememberedWallpaperByDirectory = copy
    }

    function rememberedSelectorWallpaper(directoryPath: string): string {
        const dir = root._normalizePath(directoryPath)
        if (!dir || dir.length === 0) return ""
        return root.selectorRememberedWallpaperByDirectory[dir] ?? ""
    }

    signal changed()
    signal folderChanged()
    signal thumbnailGenerated(directory: string)
    signal thumbnailGeneratedFile(filePath: string)
    signal menuPreviewReady(filePath: string, previewPath: string)

    function load() {}
    function refresh() {} // Compatibility - FolderListModel auto-refreshes

    readonly property string menuPreviewDir: FileUtils.trimFileProtocol(`${Directories.cache}/wallpaper-selector/previews`)
    property var menuPreviewMap: ({})
    property var _menuPreviewQueue: []
    property var _menuPreviewPending: ({})

    function _resetMenuPreviewWork() {
        root._menuPreviewQueue = []
        root._menuPreviewPending = ({})
        if (_menuPreviewProc.running) _menuPreviewProc.running = false
    }

    function _normalizePreviewSourcePath(path: string): string {
        return FileUtils.trimFileProtocol(String(path ?? ""))
    }

    function getMenuPreviewPath(filePath: string): string {
        const p = _normalizePreviewSourcePath(filePath)
        if (!p) return ""
        return `${menuPreviewDir}/${MD5.hash(p)}.jpg`
    }

    function _cacheMenuPreview(filePath: string, previewPath: string) {
        const mapCopy = Object.assign({}, root.menuPreviewMap)
        mapCopy[filePath] = previewPath
        root.menuPreviewMap = mapCopy

        const pendingCopy = Object.assign({}, root._menuPreviewPending)
        delete pendingCopy[filePath]
        root._menuPreviewPending = pendingCopy

        root.menuPreviewReady(filePath, previewPath)
    }

    function _processNextMenuPreview() {
        if (_menuPreviewProc.running) return
        if (root._menuPreviewQueue.length === 0) return

        const item = root._menuPreviewQueue.shift()
        if (!item || !item.filePath || !item.sourcePath || !item.outputPath) {
            Qt.callLater(root._processNextMenuPreview)
            return
        }

        _menuPreviewProc._filePath = item.filePath
        _menuPreviewProc._sourcePath = item.sourcePath
        _menuPreviewProc._outputPath = item.outputPath
        _menuPreviewProc.command = ["bash", "-c",
            "mkdir -p " + JSON.stringify(root.menuPreviewDir) +
            " && test -f " + JSON.stringify(item.outputPath) +
            " || magick " + JSON.stringify(item.sourcePath + "[0]") +
            " -auto-orient -resize 640x360^ -gravity center -extent 640x360 -quality 72 " +
            JSON.stringify(item.outputPath)]
        _menuPreviewProc.running = true
    }

    function ensureMenuPreview(filePath: string) {
        const normalized = _normalizePreviewSourcePath(filePath)
        if (!normalized) return

        let sourcePath = normalized
        if (isVideoFile(normalized)) {
            const ff = root.videoFirstFrames[normalized]
            if (!ff) {
                root.ensureVideoFirstFrame(normalized)
                return
            }
            sourcePath = ff
        }

        if (root.menuPreviewMap[normalized]) return
        if (root._menuPreviewPending[normalized]) return

        const outputPath = root.getMenuPreviewPath(normalized)
        const pendingCopy = Object.assign({}, root._menuPreviewPending)
        pendingCopy[normalized] = true
        root._menuPreviewPending = pendingCopy

        root._menuPreviewQueue.push({
            filePath: normalized,
            sourcePath: sourcePath,
            outputPath: outputPath
        })
        root._processNextMenuPreview()
    }

    function menuPreviewUrl(filePath: string): string {
        const normalized = _normalizePreviewSourcePath(filePath)
        if (!normalized) return ""

        const cached = root.menuPreviewMap[normalized]
        if (cached) return "file://" + cached

        const expected = root.getMenuPreviewPath(normalized)
        return "file://" + expected
    }

    Process {
        id: _menuPreviewProc
        property string _filePath: ""
        property string _sourcePath: ""
        property string _outputPath: ""
        onExited: exitCode => {
            if (exitCode === 0 && _menuPreviewProc._filePath && _menuPreviewProc._outputPath) {
                root._cacheMenuPreview(_menuPreviewProc._filePath, _menuPreviewProc._outputPath)
            } else if (_menuPreviewProc._filePath) {
                const pendingCopy = Object.assign({}, root._menuPreviewPending)
                delete pendingCopy[_menuPreviewProc._filePath]
                root._menuPreviewPending = pendingCopy
            }
            root._processNextMenuPreview()
        }
    }

    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", root.menuPreviewDir])
    }

    Process { id: applyProc }
    
    function openFallbackPicker(darkMode = Appearance.m3colors.darkmode) {
        applyProc.exec([Directories.wallpaperSwitchScriptPath, "--mode", (darkMode ? "dark" : "light")])
    }

    function apply(path, darkMode = Appearance.m3colors.darkmode, monitorName = "") {
        if (!path || path.length === 0) return

        if (monitorName !== "") {
            // Per-monitor: update config directly in QML to avoid race condition
            // (switchwall.sh and QML both write config.json — the 50ms write timer causes data loss)
            updatePerMonitorConfig(path, monitorName)
            root.changed()
            return
        }

        // Global wallpaper: use switchwall.sh for color generation + system theming
        // Kill any previous switchwall process to prevent race conditions
        // (old process finishing after new one would overwrite colors)
        if (applyProc.running) applyProc.running = false
        applyProc.exec([
            Directories.wallpaperSwitchScriptPath,
            "--image", path,
            "--mode", (darkMode ? "dark" : "light")
        ])
        root.changed()
    }

    function updatePerMonitorConfig(path: string, monitorName: string) {
        const currentArray = Config.options?.background?.wallpapersByMonitor ?? []
        const newArray = []
        for (const entry of currentArray) {
            if (entry && entry.monitor !== monitorName) {
                newArray.push(entry)
            }
        }

        let wsFirst = 1, wsLast = 10
        if (CompositorService.isNiri) {
            const range = detectNiriWorkspaceRange(monitorName)
            if (range) { wsFirst = range.first; wsLast = range.last }
        }

        newArray.push({
            monitor: monitorName,
            path: path,
            workspaceFirst: wsFirst,
            workspaceLast: wsLast
        })

        Config.setNestedValue("background.wallpapersByMonitor", newArray)
    }

    function updatePerMonitorBackdropConfig(backdropPath: string, monitorName: string) {
        const currentArray = Config.options?.background?.wallpapersByMonitor ?? []
        const newArray = []
        let found = false
        for (const entry of currentArray) {
            if (!entry) continue
            if (entry.monitor === monitorName) {
                found = true
                newArray.push(Object.assign({}, entry, { backdropPath: backdropPath }))
            } else {
                newArray.push(entry)
            }
        }
        if (!found) {
            // Monitor not in array yet — create entry with global wallpaper as main path
            let wsFirst = 1, wsLast = 10
            if (CompositorService.isNiri) {
                const range = detectNiriWorkspaceRange(monitorName)
                if (range) { wsFirst = range.first; wsLast = range.last }
            }
            newArray.push({
                monitor: monitorName,
                path: Config.options?.background?.wallpaperPath ?? "",
                workspaceFirst: wsFirst,
                workspaceLast: wsLast,
                backdropPath: backdropPath
            })
        }
        Config.setNestedValue("background.wallpapersByMonitor", newArray)
    }

    Process {
        id: selectProc
        property string filePath: ""
        property bool darkMode: Appearance.m3colors.darkmode
        property string monitorName: ""
        function select(filePath, darkMode = Appearance.m3colors.darkmode, monitorName = "") {
            selectProc.filePath = filePath
            selectProc.darkMode = darkMode
            selectProc.monitorName = monitorName
            selectProc.exec(["test", "-d", FileUtils.trimFileProtocol(filePath)])
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                setDirectory(selectProc.filePath)
                return
            }
            root.apply(selectProc.filePath, selectProc.darkMode, selectProc.monitorName)
        }
    }

    function select(filePath, darkMode = Appearance.m3colors.darkmode, monitorName = "") {
        selectProc.select(filePath, darkMode, monitorName)
    }

    function randomFromCurrentFolder(darkMode = Appearance.m3colors.darkmode, monitorName = "") {
        if (folderModel.count === 0) return
        const randomIndex = Math.floor(Math.random() * folderModel.count)
        const filePath = folderModel.get(randomIndex, "filePath")
        root.select(filePath, darkMode, monitorName)
    }

    function nextFromCurrentFolder(darkMode = Appearance.m3colors.darkmode, monitorName = "") {
        const count = folderModel.count
        if (count === 0) return

        let targetMonitor = monitorName
        const multiMonitor = Config.options?.background?.multiMonitor?.enable ?? false
        if (!targetMonitor && multiMonitor) {
            targetMonitor = WallpaperListener.getFocusedMonitor()
        }

        let currentPath = Config.options?.background?.wallpaperPath ?? ""
        if (targetMonitor) {
            currentPath = WallpaperListener.effectivePerMonitor?.[targetMonitor]?.path ?? currentPath
        }

        let currentIndex = -1
        for (let i = 0; i < count; ++i) {
            const path = folderModel.get(i, "filePath")
            if (path === currentPath) {
                currentIndex = i
                break
            }
        }

        const nextIndex = currentIndex >= 0 ? ((currentIndex + 1) % count) : 0
        const nextPath = folderModel.get(nextIndex, "filePath")
        root.select(nextPath, darkMode, targetMonitor)
    }

    // Detect workspace range for a monitor (Niri-specific)
    function detectNiriWorkspaceRange(monitorName: string): var {
        if (!CompositorService.isNiri) return null

        const workspaces = NiriService.workspaces ?? {}
        const outputWorkspaces = []

        for (const wsId in workspaces) {
            const ws = workspaces[wsId]
            if (ws && ws.output === monitorName) {
                outputWorkspaces.push(ws.idx)
            }
        }

        if (outputWorkspaces.length === 0) return null

        outputWorkspaces.sort((a, b) => a - b)
        return {
            first: outputWorkspaces[0],
            last: outputWorkspaces[outputWorkspaces.length - 1]
        }
    }

    function setDirectory(path, knownDirectory = false) {
        const normalizedPath = root._normalizePath(path)
        if (!normalizedPath || normalizedPath.length === 0) return

        // Keep selector scoped to wallpaper root and its subfolders.
        if (!root._isPathInWallpaperRoot(normalizedPath)) return

        const currentDir = root._normalizePath(root.effectiveDirectory)
        if (normalizedPath !== currentDir) {
            folderModel.folder = Qt.resolvedUrl(normalizedPath)
        }
    }
    function navigateUp() {}
    function navigateBack() {}
    function navigateForward() {}

    FolderListModelWithHistory {
        id: folderModel
        folder: Qt.resolvedUrl(root.defaultFolder)
        caseSensitive: false
        nameFilters: {
            const query = root.searchQuery.trim().toLowerCase()
            // Check if query is an extension filter (e.g., ".gif", ".mp4")
            if (query.startsWith(".")) {
                const ext = query.slice(1)
                if (root.extensions.includes(ext)) return [`*.${ext}`]
            }
            // Normal search: apply query to all extensions
            const searchParts = query.split(" ").filter(s => s.length > 0).map(s => `*${s}*`).join("")
            return root.extensions.map(ext => `*${searchParts}*.${ext}`)
        }
        showDirs: false
        showDotAndDotDot: false
        showOnlyReadable: true
        sortField: FolderListModel.Time
        sortReversed: false
        onCountChanged: {
            root.wallpapers = []
            for (let i = 0; i < folderModel.count; i++) {
                const isDir = folderModel.get(i, "fileIsDir")
                const path = folderModel.get(i, "filePath") || FileUtils.trimFileProtocol(folderModel.get(i, "fileURL"))
                if (!isDir && path && path.length) {
                    root.wallpapers.push(path)
                }
            }
        }
        onFolderChanged: {
            root._resetMenuPreviewWork()
            root.folderChanged()
        }
    }

    property string _pendingThumbnailSize: ""
    property string _pendingThumbnailDir: ""
    property string _activeThumbnailDir: ""
    property string _activeThumbnailSize: ""
    property bool _thumbgenQueued: false
    property string _lastThumbgenRequestKey: ""
    property var _thumbPreloadQueue: []
    property var _thumbPreloadSeen: ({})

    function _enqueueThumbnailPreload(directoryPath: string, size = "large") {
        if (!["normal", "large", "x-large", "xx-large"].includes(size)) return
        const dir = FileUtils.trimFileProtocol(String(directoryPath ?? ""))
        if (!dir || dir.length === 0) return
        const key = `${dir}|${size}`
        if (root._thumbPreloadSeen[key]) return
        const seen = Object.assign({}, root._thumbPreloadSeen)
        seen[key] = true
        root._thumbPreloadSeen = seen
        root._thumbPreloadQueue.push({ directory: dir, size: size, key: key })
        root._drainThumbnailPreloadQueue()
    }

    function _drainThumbnailPreloadQueue() {
        if (_thumbPreloadProc.running) return
        if (thumbgenProc.running || thumbgenFallbackProc.running) return
        if (thumbgenDebounce.running) return
        if (root._thumbPreloadQueue.length === 0) return
        const req = root._thumbPreloadQueue.shift()
        if (!req || !req.directory || !req.size) {
            Qt.callLater(root._drainThumbnailPreloadQueue)
            return
        }
        _thumbPreloadProc._key = req.key
        _thumbPreloadProc.command = [thumbgenScriptPath, "--size", req.size, "--only_images", "-d", req.directory]
        _thumbPreloadProc.running = true
    }

    function preloadThumbnailsForFolders(folderPaths, centerIndex = -1, size = "large", radius = 1, includeCenter = true) {
        if (!folderPaths || !Array.isArray(folderPaths) || folderPaths.length === 0) return
        const total = folderPaths.length
        if (centerIndex < 0 || centerIndex >= total) {
            for (let i = 0; i < total; i++) {
                _enqueueThumbnailPreload(folderPaths[i], size)
            }
            return
        }
        if (includeCenter) _enqueueThumbnailPreload(folderPaths[centerIndex], size)
        const maxRadius = Math.max(0, radius)
        for (let step = 1; step <= maxRadius; step++) {
            const prev = (centerIndex - step + total) % total
            const next = (centerIndex + step) % total
            _enqueueThumbnailPreload(folderPaths[prev], size)
            _enqueueThumbnailPreload(folderPaths[next], size)
        }
    }

    Process {
        id: _thumbPreloadProc
        property string _key: ""
        onExited: {
            if (_thumbPreloadProc._key && _thumbPreloadProc._key.length > 0) {
                const seen = Object.assign({}, root._thumbPreloadSeen)
                delete seen[_thumbPreloadProc._key]
                root._thumbPreloadSeen = seen
                _thumbPreloadProc._key = ""
            }
            root._drainThumbnailPreloadQueue()
        }
    }
    
    function generateThumbnail(size: string) {
        if (!["normal", "large", "x-large", "xx-large"].includes(size)) throw new Error("Invalid thumbnail size")
        const requestedDir = FileUtils.trimFileProtocol(root.directory)
        const requestKey = `${requestedDir}|${size}`
        if (requestKey === root._lastThumbgenRequestKey && (thumbgenProc.running || thumbgenDebounce.running)) return

        root._pendingThumbnailSize = size
        root._pendingThumbnailDir = requestedDir
        root._lastThumbgenRequestKey = requestKey

        // Interactive directory switch must preempt background preloading.
        if (_thumbPreloadProc.running) _thumbPreloadProc.running = false

        if (thumbgenProc.running) {
            // Directory changed while heavy generation is in progress:
            // abort stale generation and keep only newest request.
            root._thumbgenQueued = true
            thumbgenProc.running = false
            if (thumbgenFallbackProc.running) thumbgenFallbackProc.running = false
        }
        thumbgenDebounce.restart()
    }
    
    Timer {
        id: thumbgenDebounce
        interval: 300
        onTriggered: {
            if (thumbgenProc.running) {
                root._thumbgenQueued = true
                return
            }
            if (_thumbPreloadProc.running) {
                root._thumbgenQueued = true
                _thumbPreloadProc.running = false
                thumbgenDebounce.restart()
                return
            }
            if (!root._pendingThumbnailDir || root._pendingThumbnailDir.length === 0) return
            thumbgenProc.directory = root._pendingThumbnailDir
            thumbgenProc._size = root._pendingThumbnailSize
            root._activeThumbnailDir = root._pendingThumbnailDir
            root._activeThumbnailSize = root._pendingThumbnailSize
            root._thumbgenQueued = false
            thumbgenProc.command = [thumbgenScriptPath, "--size", root._pendingThumbnailSize, "--only_images", "--machine_progress", "-d", root._pendingThumbnailDir]
            root.thumbnailGenerationProgress = 0
            thumbgenProc.running = true
        }
    }

    Process {
        id: thumbgenProc
        property string directory
        property string _size: ""
        environment: ({
            "ILLOGICAL_IMPULSE_VIRTUAL_ENV": Quickshell.env("HOME") + "/.local/state/quickshell/.venv"
        })
        stdout: SplitParser {
            onRead: data => {
                let match = data.match(/PROGRESS (\d+)\/(\d+)/)
                if (match) root.thumbnailGenerationProgress = parseInt(match[1]) / parseInt(match[2])
                match = data.match(/FILE (.+)/)
                if (match) root.thumbnailGeneratedFile(match[1])
            }
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                // If a newer request is queued, skip fallback for stale directory.
                if (root._thumbgenQueued || root._pendingThumbnailDir !== root._activeThumbnailDir || root._pendingThumbnailSize !== root._activeThumbnailSize) {
                    thumbgenDebounce.restart()
                    return
                }
                thumbgenFallbackProc.command = [generateThumbnailsMagickScriptPath, "--size", thumbgenProc._size, "-d", FileUtils.trimFileProtocol(thumbgenProc.directory)]
                thumbgenFallbackProc._directory = root._activeThumbnailDir
                thumbgenFallbackProc.running = true
                return
            }
            root.thumbnailGenerated(root._activeThumbnailDir)
            if (root._thumbgenQueued || root._pendingThumbnailDir !== root._activeThumbnailDir || root._pendingThumbnailSize !== root._activeThumbnailSize) {
                thumbgenDebounce.restart()
            }
            root._drainThumbnailPreloadQueue()
        }
    }

    Process {
        id: thumbgenFallbackProc
        property string _directory: ""
        onExited: {
            if (_directory && _directory.length > 0) root.thumbnailGenerated(_directory)
            if (root._thumbgenQueued || root._pendingThumbnailDir !== root._activeThumbnailDir || root._pendingThumbnailSize !== root._activeThumbnailSize) {
                thumbgenDebounce.restart()
            }
            root._drainThumbnailPreloadQueue()
        }
    }

    // ── Auto wallpaper cycling ──────────────────────────────────────────
    readonly property bool autoWallpaperEnabled: Config.options?.background?.autoWallpaper?.enable ?? false
    readonly property int autoWallpaperInterval: Config.options?.background?.autoWallpaper?.intervalMinutes ?? 30
    readonly property bool autoWallpaperGenerateColors: Config.options?.background?.autoWallpaper?.generateColors ?? true
    readonly property string autoWallpaperFolder: Config.options?.background?.autoWallpaper?.folder ?? ""

    Timer {
        id: autoWallpaperTimer
        interval: root.autoWallpaperInterval * 60 * 1000
        running: root.autoWallpaperEnabled && !GlobalStates.screenLocked
        repeat: true
        onTriggered: root._cycleAutoWallpaper()
    }

    function _cycleAutoWallpaper() {
        // Use custom folder or current folder
        const customFolder = root.autoWallpaperFolder
        if (customFolder && customFolder.length > 0) {
            // Switch to custom folder temporarily, pick random, then switch back
            const previousFolder = root.effectiveDirectory
            _autoPickProc._previousFolder = previousFolder
            _autoPickProc._targetFolder = customFolder
            _autoPickProc.command = ["test", "-d", customFolder]
            _autoPickProc.running = true
            return
        }
        // Use current folder
        if (folderModel.count === 0) return
        _pickRandomAndApply()
    }

    function _pickRandomAndApply() {
        if (folderModel.count === 0) return
        const currentPath = Config.options?.background?.wallpaperPath ?? ""
        let attempts = 0
        let randomIndex, filePath
        // Try to pick a different wallpaper than the current one
        do {
            randomIndex = Math.floor(Math.random() * folderModel.count)
            filePath = folderModel.get(randomIndex, "filePath")
            attempts++
        } while (filePath === currentPath && attempts < 5 && folderModel.count > 1)

        if (!filePath) return

        if (root.autoWallpaperGenerateColors) {
            root.apply(filePath, Appearance.m3colors.darkmode)
        } else {
            // Just change wallpaper path without running color generation
            Config.setNestedValue("background.wallpaperPath", filePath)
        }
    }

    Process {
        id: _autoPickProc
        property string _previousFolder: ""
        property string _targetFolder: ""
        onExited: (exitCode) => {
            if (exitCode === 0) {
                // Folder exists, temporarily set it and pick random
                root.directory = Qt.resolvedUrl(_autoPickProc._targetFolder)
                // Wait for folder model to update before picking
                _autoPickFolderDelay.restart()
            }
        }
    }

    Timer {
        id: _autoPickFolderDelay
        interval: 500
        onTriggered: root._pickRandomAndApply()
    }
    // ── End auto wallpaper cycling ──────────────────────────────────────
}
