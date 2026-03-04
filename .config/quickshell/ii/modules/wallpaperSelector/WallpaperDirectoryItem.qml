import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services

MouseArea {
    id: root

    required property var fileModelData
    property bool isDirectory: fileModelData.fileIsDir
    property bool useThumbnail: Images.isValidMediaByName(fileModelData.fileName)
    property int previewVersion: 0
    property alias colBackground: background.color
    property alias colText: wallpaperItemName.color
    property alias borderColor: background.border.color
    property alias borderWidth: background.border.width
    property alias radius: background.radius
    property alias margins: background.anchors.margins
    property alias padding: wallpaperItemColumnLayout.anchors.margins
    onFileModelDataChanged: {
        previewVersion = 0
        Wallpapers.ensureMenuPreview(fileModelData.filePath)
    }

    signal activated()

    margins: Appearance.sizes.wallpaperSelectorItemMargins / 3
    padding: Appearance.sizes.wallpaperSelectorItemPadding / 3
    hoverEnabled: true
    onClicked: root.activated()

    Rectangle {
        id: background

        anchors.fill: parent
        radius: Appearance.rounding.normal
        border.width: 0
        border.color: "transparent"

        ColumnLayout {
            id: wallpaperItemColumnLayout

            anchors.fill: parent
            spacing: 0

            Item {
                id: wallpaperItemImageContainer

                Layout.fillHeight: true
                Layout.fillWidth: true

                Loader {
                    id: thumbnailShadowLoader

                    active: thumbnailImageLoader.active && thumbnailImageLoader.item.status === Image.Ready
                    anchors.fill: thumbnailImageLoader

                    sourceComponent: StyledRectangularShadow {
                        target: thumbnailImageLoader
                        anchors.fill: undefined
                        radius: Appearance.rounding.small
                    }

                }

                Loader {
                    id: thumbnailImageLoader

                    anchors.fill: parent
                    active: root.useThumbnail

                    sourceComponent: StyledImage {
                        id: thumbnailImage
                        source: {
                            const base = Wallpapers.menuPreviewUrl(fileModelData.filePath)
                            if (!base || base.length === 0) return ""
                            return `${base}?pv=${root.previewVersion}`
                        }
                        cache: true
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        clip: true
                        sourceSize.width: wallpaperItemImageContainer.width
                        sourceSize.height: wallpaperItemImageContainer.height
                        layer.enabled: Appearance.effectsEnabled

                        Component.onCompleted: Wallpapers.ensureMenuPreview(fileModelData.filePath)

                        Connections {
                            target: Wallpapers
                            function onMenuPreviewReady(filePath, previewPath) {
                                if (FileUtils.trimFileProtocol(String(filePath ?? "")) !== FileUtils.trimFileProtocol(String(fileModelData.filePath ?? "")))
                                    return
                                root.previewVersion += 1
                            }
                        }

                        layer.effect: OpacityMask {
                            maskSource: Rectangle {
                                width: wallpaperItemImageContainer.width
                                height: wallpaperItemImageContainer.height
                                radius: Appearance.rounding.small
                            }
                        }
                    }

                }

                Loader {
                    id: iconLoader

                    active: !root.useThumbnail
                    anchors.fill: parent

                    sourceComponent: DirectoryIcon {
                        fileModelData: root.fileModelData
                        sourceSize.width: wallpaperItemColumnLayout.width
                        sourceSize.height: wallpaperItemColumnLayout.height
                    }

                }

            }

            StyledText {
                id: wallpaperItemName

                visible: false
                height: 0
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                font.pixelSize: Appearance.font.pixelSize.smaller
                text: ""

                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }

            }

        }

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }

    }

}
